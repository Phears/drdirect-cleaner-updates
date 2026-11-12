# DRDirect Imager engine: compressed whole-drive images (read-only), verify, and restore.
# Dot-sourced by 'DRDirect Imager.ps1' and by the test script. Windows PowerShell 5.1.

$script:DRImgSource = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public class DRImgJob
{
    public long Done;
    public long Total;
    public string Status = "";
    public string Error;
    public bool Ok;
    public string Hash;
    public byte[] Key;
    public bool UsedDirectIO;
    public volatile bool Cancel;
    public volatile bool Finished;

    const string Magic = "DRIMG002";
    const string Magic3 = "DRIMG003";
    const string Magic4 = "DRIMG004";
    const int Chunk = 4 * 1024 * 1024;
    const int Batch = 32;

    delegate void Work();

    void Go(Work w, string partialFile)
    {
        Thread t = new Thread(delegate() {
            try { w(); Ok = true; }
            catch (Exception ex) { Error = Cancel ? "Cancelled." : ex.Message; }
            if (!Ok && partialFile != null) { try { File.Delete(partialFile); } catch { } }
            Finished = true;
        });
        t.IsBackground = true;
        t.Start();
    }

    public static long ReadHeader(string file)
    {
        using (FileStream f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (BinaryReader br = new BinaryReader(f))
        {
            string m = Encoding.ASCII.GetString(br.ReadBytes(8));
            if (m != Magic && m != Magic3 && m != Magic4) throw new InvalidDataException("This is not a DRDirect image file.");
            bool v3 = (m == Magic3 || m == Magic4); bool lz = (m == Magic4);
            return br.ReadInt64();
        }
    }

    public static string ReadLabel(string file)
    {
        using (FileStream f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (BinaryReader br = new BinaryReader(f))
        {
            br.ReadBytes(8); br.ReadInt64(); br.ReadInt32(); br.ReadInt32();
            return br.ReadString();
        }
    }

    public void StartImage(string disk, string outFile, long size, string label)
    {
        Total = size; Status = "Imaging";
        Go(delegate() { DoImage(disk, outFile, size, label); }, outFile);
    }

    // Fast image: only the used parts of the drive (sel marks the 4 MB chunks that hold data) are read; everything
    // else is recorded as empty without being read. The checksum is over what is stored, so checking is fast too.
    public void StartSmartImage(string disk, string outFile, long size, string label, long[] data, long[] tail)
    {
        long nChunks = (size + Chunk - 1) / Chunk;
        bool[] sel = new bool[nChunks];
        for (int pass = 0; pass < 2; pass++)
        {
            long[] a = (pass == 0) ? data : tail;
            for (int i = 0; i + 1 < a.Length; i += 2)
            {
                long off = a[i], len = a[i + 1];
                if (len <= 0 || off >= size) continue;
                long end = Math.Min(off + len, size);
                for (long c = off / Chunk; c <= (end - 1) / Chunk; c++) sel[c] = true;
            }
        }
        long selBytes = 0;
        for (long c = 0; c < nChunks; c++) if (sel[c]) selBytes += Math.Min((long)Chunk, size - c * Chunk);
        Total = selBytes; Status = "Imaging";
        Go(delegate() { DoSmartImage(disk, outFile, size, label, sel); }, outFile);
    }

    class SmartItem { public long Idx; public int Len; public byte[] B; }

    static void WriteEmptyRecord(BinaryWriter bw, SHA256 outer, long idx, long size)
    {
        long pos = idx * Chunk;
        int len = (int)Math.Min((long)Chunk, size - pos);
        bw.Write(pos); bw.Write(len); bw.Write(0);
        byte[] z = new byte[32];
        outer.TransformBlock(BitConverter.GetBytes(pos), 0, 8, null, 0);
        outer.TransformBlock(BitConverter.GetBytes(len), 0, 4, null, 0);
        outer.TransformBlock(z, 0, 32, null, 0);
    }

    // Estimated bytes per second for the fast method with the given number of workers, from real used chunks of the drive.
    public static double MeasureQuick(string disk, long[] data, int workers, bool smallest = false)
    {
        long total = 0; for (int i = 1; i < data.Length; i += 2) total += data[i];
        if (total <= 0) return 500e6;
        int n = 32; byte[][] bufs = new byte[n][]; int got = 0; double readSec = 0;
        System.Diagnostics.Stopwatch sw = new System.Diagnostics.Stopwatch();
        using (FileStream src = new FileStream(disk, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096))
        {
            for (int s = 0; s < n; s++)
            {
                long target = (total / n) * s + (total / n) / 2;
                long off = 0, acc = 0;
                for (int i = 0; i + 1 < data.Length; i += 2) { if (acc + data[i + 1] > target) { off = data[i] + (target - acc); break; } acc += data[i + 1]; }
                off = (off / Chunk) * Chunk;
                byte[] b = new byte[Chunk];
                sw.Restart();
                try { src.Seek(off, SeekOrigin.Begin); ReadFull(src, b, Chunk); bufs[s] = b; got++; } catch (Exception) { }
                readSec += sw.Elapsed.TotalSeconds;
            }
        }
        if (got == 0) return 500e6;
        double readRate = (got * (double)Chunk) / Math.Max(readSec, 0.001);
        byte[] key = new byte[32];
        long done = 0;
        sw.Restart();
        ParallelOptions po = new ParallelOptions(); po.MaxDegreeOfParallelism = Math.Max(1, workers);
        Parallel.For(0, n, po, delegate(int i) {
            if (bufs[i] == null || IsZero(bufs[i], Chunk)) return;
            byte[] dst = new byte[Chunk + Chunk / 255 + 64];
            int cl;
            if (smallest) { byte[] dc = Deflate(bufs[i], Chunk, false); cl = dc.Length; Buffer.BlockCopy(dc, 0, dst, 0, Math.Min(cl, dst.Length)); }
            else cl = Lz4CompressInto(bufs[i], Chunk, dst);
            byte[] iv; byte[] ct = EncryptParts(key, dst, cl < Chunk ? cl : Chunk, out iv);
            using (SHA256CryptoServiceProvider hc = new SHA256CryptoServiceProvider()) { hc.ComputeHash(ct); }
            System.Threading.Interlocked.Add(ref done, (long)Chunk);
        });
        double compRate = done / Math.Max(sw.Elapsed.TotalSeconds, 0.001);
        if (done == 0) compRate = readRate * 4;
        return Math.Min(compRate, readRate * 2);
    }

    public int Workers = Environment.ProcessorCount;
    // MAX speed for Secure: blocks that do not shrink (photos, videos, zip files) are found from their first
    // 64 KB and stored as they are, and the search gives up sooner. Bigger file, same kind of image.
    public bool Lighter;
    public bool UsedDirectWrite;

    // Writes a file straight to the drive, past the Windows cache, in big aligned pieces. The last piece that is not a
    // whole 4 KB is added the normal way when the file is closed, so the file is byte for byte the same as before.
    class DirectOut : Stream
    {
        Microsoft.Win32.SafeHandles.SafeFileHandle h; IntPtr buf; int cap; int fill; long written; string path; bool done;
        public static DirectOut Open(string path, int cap)
        {
            Microsoft.Win32.SafeHandles.SafeFileHandle fh = CreateFileW(path, GENERIC_WRITE, 0, IntPtr.Zero, 2, NO_BUF, IntPtr.Zero);
            if (fh.IsInvalid) { fh.Dispose(); return null; }
            IntPtr b = VirtualAlloc(IntPtr.Zero, (UIntPtr)(ulong)cap, 0x3000, 4);
            if (b == IntPtr.Zero) { fh.Dispose(); return null; }
            DirectOut d = new DirectOut(); d.h = fh; d.buf = b; d.cap = cap; d.path = path;
            return d;
        }
        void Put(int n)
        {
            uint w;
            if (!WriteFile(h, buf, (uint)n, out w, IntPtr.Zero) || w != (uint)n)
                throw new IOException("Cannot write the image file (error " + System.Runtime.InteropServices.Marshal.GetLastWin32Error() + ").");
            written += n;
        }
        public override void Write(byte[] a, int off, int n)
        {
            while (n > 0)
            {
                int k = Math.Min(n, cap - fill);
                System.Runtime.InteropServices.Marshal.Copy(a, off, (IntPtr)(buf.ToInt64() + fill), k);
                fill += k; off += k; n -= k;
                if (fill == cap) { Put(fill); fill = 0; }
            }
        }
        protected override void Dispose(bool disposing)
        {
            if (done) { base.Dispose(disposing); return; }
            done = true;
            try
            {
                int aligned = fill & ~4095;
                if (aligned > 0) Put(aligned);
                int rest = fill - aligned;
                byte[] tail = new byte[rest];
                if (rest > 0) System.Runtime.InteropServices.Marshal.Copy((IntPtr)(buf.ToInt64() + aligned), tail, 0, rest);
                h.Dispose(); h = null;
                if (rest > 0)
                {
                    using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None, 4096))
                    { f.Seek(written, SeekOrigin.Begin); f.Write(tail, 0, rest); }
                }
            }
            finally
            {
                if (h != null) h.Dispose();
                if (buf != IntPtr.Zero) { VirtualFree(buf, UIntPtr.Zero, 0x8000); buf = IntPtr.Zero; }
                base.Dispose(disposing);
            }
        }
        public override void Flush() { }
        public override bool CanRead { get { return false; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return true; } }
        public override long Length { get { return written + fill; } }
        public override long Position { get { return written + fill; } set { throw new NotSupportedException(); } }
        public override int Read(byte[] b, int o, int c) { throw new NotSupportedException(); }
        public override long Seek(long o, SeekOrigin r) { throw new NotSupportedException(); }
        public override void SetLength(long v) { throw new NotSupportedException(); }
    }
    public double SecWait, SecComp, SecRead, SecBlocked, SecWrite;
    // Processor time split up (added over all threads, so bigger than the clock time): compress, lock, checksum.
    long tkPack, tkLock, tkSum;
    public double SecPack { get { return tkPack / (double)System.Diagnostics.Stopwatch.Frequency; } }
    public double SecLock { get { return tkLock / (double)System.Diagnostics.Stopwatch.Frequency; } }
    public double SecSum { get { return tkSum / (double)System.Diagnostics.Stopwatch.Frequency; } }

    void DoSmartImage(string disk, string outFile, long size, string label, bool[] sel)
    {
        long nChunks = sel.LongLength;
        SHA256 outer = SHA256.Create();
        if (Key == null) throw new InvalidOperationException("No PC lock key.");
        int work = Math.Max(1, Workers);
        System.Runtime.GCLatencyMode oldMode = System.Runtime.GCSettings.LatencyMode;
        try { System.Runtime.GCSettings.LatencyMode = System.Runtime.GCLatencyMode.SustainedLowLatency; } catch (Exception) { }
        try
        {
        // MAX writes the image straight to the drive in 16 MB pieces (no Windows cache); if the drive will not
        // open that way, or for the other speeds, it is written the normal way.
        Stream oDirect = Lighter ? DirectOut.Open(outFile, 16 << 20) : null;
        if (oDirect != null) UsedDirectWrite = true;
        using (Stream o = oDirect ?? new FileStream(outFile, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
        using (BinaryWriter bw = new BinaryWriter(o))
        {
            bw.Write(Encoding.ASCII.GetBytes(Quick ? Magic4 : Magic3));
            bw.Write(size);
            bw.Write(512);
            bw.Write(Chunk);
            bw.Write(label == null ? "" : label);
            bw.Write(KeyCheck(Key));
            if (Quick) bw.Write(1);
            bw.Flush();
            BlockingCollection<SmartItem[]> q = new BlockingCollection<SmartItem[]>(4);
            BlockingCollection<List<ArraySegment<byte>>> wq = new BlockingCollection<List<ArraySegment<byte>>>(6);
            Exception readErr = null; Exception writeErr = null;
            Thread wt = new Thread(delegate() {
                System.Diagnostics.Stopwatch w = new System.Diagnostics.Stopwatch();
                foreach (List<ArraySegment<byte>> segs in wq.GetConsumingEnumerable())
                {
                    if (writeErr == null)
                    {
                        try { w.Restart(); foreach (ArraySegment<byte> r in segs) o.Write(r.Array, r.Offset, r.Count); SecWrite += w.Elapsed.TotalSeconds; } catch (Exception ex) { writeErr = ex; }
                    }
                    foreach (ArraySegment<byte> r in segs) if (r.Array.Length == Chunk + 64) encPool.Add(r.Array);
                }
            });
            wt.IsBackground = true; wt.Start();
            Thread rd = new Thread(delegate() {
                ThreadLocal<FileStream> tls = null;
                try
                {
                    List<long> idxs = new List<long>();
                    for (long c = 0; c < nChunks; c++) if (sel[c]) idxs.Add(c);
                    tls = new ThreadLocal<FileStream>(delegate() { return new FileStream(disk, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096); }, true);
                    ParallelOptions po = new ParallelOptions(); po.MaxDegreeOfParallelism = Math.Max(2, Math.Min(8, work));
                    System.Diagnostics.Stopwatch rs = new System.Diagnostics.Stopwatch();
                    for (int bi = 0; bi < idxs.Count; bi += Batch)
                    {
                        if (Cancel) break;
                        int cnt = Math.Min(Batch, idxs.Count - bi);
                        SmartItem[] items = new SmartItem[cnt];
                        int first = bi;
                        rs.Restart();
                        Parallel.For(0, cnt, po, delegate(int k) {
                            long c = idxs[first + k];
                            long off = c * Chunk;
                            int want = (int)Math.Min((long)Chunk, size - off);
                            FileStream fs = tls.Value;
                            fs.Seek(off, SeekOrigin.Begin);
                            SmartItem it = new SmartItem(); it.Idx = c; it.Len = want; it.B = GetBuf();
                            ReadFull(fs, it.B, want);
                            items[k] = it;
                        });
                        SecRead += rs.Elapsed.TotalSeconds;
                        q.Add(items);
                    }
                }
                catch (Exception ex) { readErr = ex; }
                finally
                {
                    if (tls != null) { try { foreach (FileStream f in tls.Values) f.Dispose(); tls.Dispose(); } catch (Exception) { } }
                    q.CompleteAdding();
                }
            });
            rd.IsBackground = true; rd.Start();
            try
            {
                long nextChunk = 0; long done = 0; byte[] key = Key;
                ParallelOptions pc = new ParallelOptions(); pc.MaxDegreeOfParallelism = work;
                System.Diagnostics.Stopwatch sw = new System.Diagnostics.Stopwatch();
                IEnumerator<SmartItem[]> en = q.GetConsumingEnumerable().GetEnumerator();
                while (true)
                {
                    sw.Restart();
                    bool has = en.MoveNext();
                    SecWait += sw.Elapsed.TotalSeconds;
                    if (!has) break;
                    SmartItem[] batch = en.Current;
                    if (Cancel) throw new OperationCanceledException();
                    if (writeErr != null) throw writeErr;
                    int n = batch.Length;
                    byte[][] ivs = new byte[n][]; byte[][] cts = new byte[n][]; int[] ctl = new int[n]; int[] clen = new int[n]; bool[] zero = new bool[n]; byte[][] ch = new byte[n][];
                    sw.Restart();
                    Parallel.For(0, n, pc, delegate(int i) {
                        SmartItem it = batch[i];
                        if (IsZero(it.B, it.Len)) { zero[i] = true; return; }
                        long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
                        byte[] plain; int plainLen; bool packed;
                        if (Quick)
                        {
                            byte[] dst = lzDst; if (dst == null) { dst = new byte[Chunk + Chunk / 255 + 64]; lzDst = dst; }
                            bool skip = false;
                            if (Lighter && it.Len > 65536) { int probe = Lz4CompressInto(it.B, 65536, dst, 4); skip = probe > 65536 - 2048; }
                            if (skip) { packed = false; plain = it.B; plainLen = it.Len; }
                            else
                            {
                                int cl = Lz4CompressInto(it.B, it.Len, dst, Lighter ? 4 : 6);
                                packed = cl < it.Len; plain = packed ? dst : it.B; plainLen = packed ? cl : it.Len;
                            }
                        }
                        else
                        {
                            byte[] c = Deflate(it.B, it.Len, Fast);
                            packed = c.Length < it.Len; plain = packed ? c : it.B; plainLen = packed ? c.Length : it.Len;
                        }
                        clen[i] = plainLen;
                        long t1 = System.Diagnostics.Stopwatch.GetTimestamp();
                        byte[] iv; byte[] ct = GetEncBuf(); int ctLen = EncryptInto(key, plain, plainLen, ct, out iv);
                        ivs[i] = iv; cts[i] = ct; ctl[i] = ctLen;
                        long t2 = System.Diagnostics.Stopwatch.GetTimestamp();
                        SHA256CryptoServiceProvider hc = encSha; if (hc == null) { hc = new SHA256CryptoServiceProvider(); encSha = hc; }
                        if (Quick)
                        {
                            // fast images hash the stored (encrypted) bytes; older ones hash the raw chunk, as before
                            hc.Initialize(); hc.TransformBlock(iv, 0, iv.Length, null, 0); hc.TransformFinalBlock(ct, 0, ctLen); ch[i] = (byte[])hc.Hash.Clone();
                        }
                        else { ch[i] = hc.ComputeHash(it.B, 0, it.Len); }
                        long t3 = System.Diagnostics.Stopwatch.GetTimestamp();
                        Interlocked.Add(ref tkPack, t1 - t0); Interlocked.Add(ref tkLock, t2 - t1); Interlocked.Add(ref tkSum, t3 - t2);
                    });
                    SecComp += sw.Elapsed.TotalSeconds;
                    List<ArraySegment<byte>> segs = new List<ArraySegment<byte>>();
                    MemoryStream hs = new MemoryStream(4096);
                    BinaryWriter hw = new BinaryWriter(hs);
                    for (int i = 0; i < n; i++)
                    {
                        while (nextChunk < batch[i].Idx) { WriteEmptyRecord(hw, outer, nextChunk, size); nextChunk++; }
                        long pos = batch[i].Idx * Chunk; int len = batch[i].Len;
                        if (zero[i]) { WriteEmptyRecord(hw, outer, batch[i].Idx, size); }
                        else
                        {
                            hw.Write(pos); hw.Write(len);
                            hw.Write(clen[i]); hw.Write(ivs[i].Length + ctl[i]);
                            hw.Flush(); segs.Add(new ArraySegment<byte>(hs.ToArray())); hs.SetLength(0);
                            segs.Add(new ArraySegment<byte>(ivs[i])); segs.Add(new ArraySegment<byte>(cts[i], 0, ctl[i]));
                            outer.TransformBlock(BitConverter.GetBytes(pos), 0, 8, null, 0);
                            outer.TransformBlock(BitConverter.GetBytes(len), 0, 4, null, 0);
                            outer.TransformBlock(ch[i], 0, 32, null, 0);
                        }
                        nextChunk = batch[i].Idx + 1;
                        done += len;
                        bufPool.Add(batch[i].B); batch[i].B = null;
                    }
                    hw.Flush(); if (hs.Length > 0) { segs.Add(new ArraySegment<byte>(hs.ToArray())); }
                    sw.Restart();
                    wq.Add(segs);
                    SecBlocked += sw.Elapsed.TotalSeconds;
                    Done = done;
                }
                if (readErr != null) throw readErr;
                if (Cancel) throw new OperationCanceledException();
                MemoryStream tail = new MemoryStream();
                BinaryWriter tw = new BinaryWriter(tail);
                while (nextChunk < nChunks) { WriteEmptyRecord(tw, outer, nextChunk, size); nextChunk++; }
                outer.TransformFinalBlock(new byte[0], 0, 0);
                tw.Write(-1L);
                tw.Write(outer.Hash);
                tw.Flush();
                List<ArraySegment<byte>> last = new List<ArraySegment<byte>>(); last.Add(new ArraySegment<byte>(tail.ToArray()));
                wq.Add(last);
                Hash = Hex(outer.Hash);
            }
            finally
            {
                wq.CompleteAdding();
                wt.Join();
            }
            if (writeErr != null) throw writeErr;
            o.Flush();
        }
        }
        finally { try { System.Runtime.GCSettings.LatencyMode = oldMode; } catch (Exception) { } }
    }
    public void StartVerify(string file)
    {
        Total = ReadHeader(file); Status = "Checking";
        Go(delegate() { ReplayParallel(file, null); }, null);
    }

    public void StartRestore(string file, string disk)
    {
        Total = ReadHeader(file); Status = "Restoring";
        Go(delegate() { ReplayParallel(file, disk); }, null);
    }

    // Quick speed test (about 128 MB read, plus compressing it when compress is true), in bytes per second.
    public static double MeasureSpeed(string disk, long diskSize, bool compress)
    {
        int n = 32;
        byte[][] bufs = new byte[n][];
        long off = diskSize > (1L << 30) ? ((diskSize / 2) & ~4095L) : 0;
        int got = 0;
        System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
        using (FileStream src = new FileStream(disk, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096))
        {
            src.Seek(off, SeekOrigin.Begin);
            for (int i = 0; i < n; i++)
            {
                bufs[i] = new byte[Chunk];
                try { ReadFull(src, bufs[i], Chunk); got++; } catch (Exception) { break; }
            }
        }
        double readSec = sw.Elapsed.TotalSeconds;
        if (got == 0) return 500e6;
        double rate = ((double)got * Chunk) / Math.Max(readSec, 0.001);
        if (compress)
        {
            long nz = 0;
            int g = got;
            sw.Restart();
            Parallel.For(0, g, delegate(int i) {
                if (!IsZero(bufs[i], Chunk)) { Deflate(bufs[i], Chunk, false); System.Threading.Interlocked.Add(ref nz, (long)Chunk); }
            });
            double cs = sw.Elapsed.TotalSeconds;
            if (nz > 0) rate = Math.Min(rate, nz / Math.Max(cs, 0.001));
        }
        return rate;
    }

    class Item { public byte[] B; public int N; public long Off; }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(Microsoft.Win32.SafeHandles.SafeFileHandle h, uint code, ref long inBuf, int inSize, byte[] outBuf, int outSize, out int ret, IntPtr ov);

    // Files whose contents Windows rebuilds by itself, so an image leaves them out (about 14 GB on a typical PC).
    public static string[] SkipNames = new string[] { "hiberfil.sys", "pagefile.sys", "swapfile.sys" };

    // The clusters of one file as [first cluster, count] pairs; empty when the file does not exist or cannot be queried.
    static List<long[]> FileClusters(string path)
    {
        List<long[]> res = new List<long[]>();
        Microsoft.Win32.SafeHandles.SafeFileHandle h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (h.IsInvalid) return res;
        using (h)
        {
            byte[] buf = new byte[64 * 1024];
            long start = 0;
            while (true)
            {
                int ret;
                bool ok = DeviceIoControl(h, 0x90073, ref start, 8, buf, buf.Length, out ret, IntPtr.Zero);
                int err = ok ? 0 : System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                if (!ok && err != 234) break;
                int n = BitConverter.ToInt32(buf, 0);
                long prev = BitConverter.ToInt64(buf, 8);
                for (int i = 0; i < n; i++)
                {
                    long next = BitConverter.ToInt64(buf, 16 + i * 16);
                    long lcn = BitConverter.ToInt64(buf, 24 + i * 16);
                    if (lcn != -1) res.Add(new long[] { lcn, next - prev });
                    prev = next;
                }
                if (ok) break;
                start = prev;
            }
        }
        return res;
    }

    // Takes the excluded byte ranges [start, end) out of flat [offset, length, ...] used runs.
    static long[] SubtractRuns(List<long> runs, List<long[]> ex)
    {
        ex.Sort(delegate(long[] x, long[] y) { return x[0].CompareTo(y[0]); });
        List<long> o = new List<long>();
        for (int i = 0; i + 1 < runs.Count; i += 2)
        {
            long s = runs[i], e = s + runs[i + 1];
            foreach (long[] x in ex)
            {
                if (x[1] <= s || x[0] >= e) continue;
                if (x[0] > s) { o.Add(s); o.Add(x[0] - s); }
                if (x[1] > s) s = x[1];
                if (s >= e) break;
            }
            if (s < e) { o.Add(s); o.Add(e - s); }
        }
        return o.ToArray();
    }

    // After a copy or restore: blanks the first 4 KB of the hibernation file so Windows never tries to resume from a file whose contents were left out.
    // volDev is a volume path such as \\.\E: or \\?\Volume{...}. Returns true when the header was zeroed or there is no such file.
    public static bool ZeroFileHead(string volDev, string name)
    {
        volDev = volDev.TrimEnd('\\');
        List<long[]> cl = FileClusters(volDev + "\\" + name);
        if (cl.Count == 0) return true;
        long cluster;
        using (FileStream f = new FileStream(volDev, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096))
        {
            byte[] boot = new byte[512];
            ReadFull(f, boot, 512);
            int bps = BitConverter.ToUInt16(boot, 11);
            int spcB = boot[13];
            cluster = bps * (spcB <= 128 ? (long)spcB : (1L << (256 - spcB)));
        }
        Microsoft.Win32.SafeHandles.SafeFileHandle h = CreateFileW(volDev, GENERIC_READ | GENERIC_WRITE, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) return false;
        using (h)
        {
            long dummy = 0; int ret;
            DeviceIoControl(h, 0x90018, ref dummy, 0, null, 0, out ret, IntPtr.Zero);   // lock the volume
            IntPtr mem = System.Runtime.InteropServices.Marshal.AllocHGlobal(4096);
            try
            {
                byte[] z = new byte[4096];
                System.Runtime.InteropServices.Marshal.Copy(z, 0, mem, 4096);
                long np; uint w;
                if (!SetFilePointerEx(h, cl[0][0] * cluster, out np, 0)) return false;
                if (!WriteFile(h, mem, 4096, out w, IntPtr.Zero) || w != 4096) return false;
                FlushFileBuffers(h);
                return true;
            }
            finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(mem); DeviceIoControl(h, 0x9001C, ref dummy, 0, null, 0, out ret, IntPtr.Zero); }
        }
    }

    // Used areas of an NTFS volume as flat [offset, length, offset, length, ...] pairs, in bytes from the start of the disk.
    public static long[] GetUsedExtents(string volPath, long partOffset)
    {
        using (FileStream f = new FileStream(volPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096))
        {
            byte[] boot = new byte[512];
            ReadFull(f, boot, 512);
            if (boot[3] != 'N' || boot[4] != 'T' || boot[5] != 'F' || boot[6] != 'S') throw new InvalidDataException("Not NTFS.");
            int bps = BitConverter.ToUInt16(boot, 11);
            int spcB = boot[13];
            long spc = spcB <= 128 ? spcB : (1L << (256 - spcB));
            long cluster = bps * spc;
            if (cluster <= 0) throw new InvalidDataException("Bad cluster size.");
            long clusters = BitConverter.ToInt64(boot, 40) * bps / cluster;
            List<long> runs = new List<long>();
            long lcn = 0;
            long runStart = -1;
            byte[] buf = new byte[16 + 4 * 1024 * 1024];
            while (lcn < clusters)
            {
                long start = lcn;
                int ret;
                bool ok = DeviceIoControl(f.SafeFileHandle, 0x9006F, ref start, 8, buf, buf.Length, out ret, IntPtr.Zero);
                int err = ok ? 0 : System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                if (!ok && err != 234) throw new IOException("Cannot read the used-space map (error " + err + ").");
                long gotStart = BitConverter.ToInt64(buf, 0);
                long bits = (long)(ret - 16) * 8;
                long remaining = BitConverter.ToInt64(buf, 8);
                if (bits > remaining) bits = remaining;
                if (bits <= 0) break;
                long i = 0;
                while (i < bits)
                {
                    long c = gotStart + i;
                    if (c >= clusters) { i = bits; break; }
                    if ((i & 7) == 0 && i + 8 <= bits)
                    {
                        byte bt = buf[16 + (i >> 3)];
                        if (bt == 0xFF && runStart >= 0) { i += 8; continue; }
                        if (bt == 0x00 && runStart < 0) { i += 8; continue; }
                    }
                    bool used = (buf[16 + (i >> 3)] & (1 << (int)(i & 7))) != 0;
                    if (used) { if (runStart < 0) runStart = c; }
                    else if (runStart >= 0) { runs.Add(partOffset + runStart * cluster); runs.Add((c - runStart) * cluster); runStart = -1; }
                    i++;
                }
                lcn = gotStart + bits;
            }
            if (runStart >= 0) { runs.Add(partOffset + runStart * cluster); runs.Add((Math.Min(lcn, clusters) - runStart) * cluster); }
            // leave out the hibernation, page and swap files (Windows makes them again); if they cannot be found, nothing is left out
            List<long[]> ex = new List<long[]>();
            foreach (string nm in SkipNames)
                foreach (long[] c in FileClusters(volPath.TrimEnd('\\') + "\\" + nm))
                    ex.Add(new long[] { partOffset + c[0] * cluster, partOffset + (c[0] + c[1]) * cluster });
            if (ex.Count > 0) return SubtractRuns(runs, ex);
            return runs.ToArray();
        }
    }

    static List<long[]> Normalize(long[] flat, long diskSize)
    {
        List<long[]> v = new List<long[]>();
        for (int i = 0; i + 1 < flat.Length; i += 2)
        {
            long st = flat[i] & ~4095L;
            long en = (flat[i] + flat[i + 1] + 4095) & ~4095L;
            if (en > diskSize) en = diskSize;
            if (en > st) v.Add(new long[] { st, en });
        }
        v.Sort(delegate(long[] x, long[] y) { return x[0].CompareTo(y[0]); });
        List<long[]> m = new List<long[]>();
        foreach (long[] e in v)
        {
            if (m.Count > 0 && e[0] <= m[m.Count - 1][1] + (1 << 20)) { if (e[1] > m[m.Count - 1][1]) m[m.Count - 1][1] = e[1]; }
            else m.Add(new long[] { e[0], e[1] });
        }
        return m;
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(Microsoft.Win32.SafeHandles.SafeFileHandle h, long dist, out long newPos, uint method);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(Microsoft.Win32.SafeHandles.SafeFileHandle h, IntPtr buf, uint n, out uint read, IntPtr ov);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(Microsoft.Win32.SafeHandles.SafeFileHandle h, IntPtr buf, uint n, out uint written, IntPtr ov);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint type, uint prot);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint type);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushFileBuffers(Microsoft.Win32.SafeHandles.SafeFileHandle h);

    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000, NO_BUF = 0x20000000, SEQ = 0x08000000;

    // Direct, unbuffered copy with several workers at once, each on its own handles (like Miray-style tools).
    // Returns false if the fast path cannot be used (nothing was written); throws if it fails part way.
    bool FastCopy(string src, string dst, List<long[]> data, List<long[]> tail)
    {
        Microsoft.Win32.SafeHandles.SafeFileHandle t1 = CreateFileW(src, GENERIC_READ, 3, IntPtr.Zero, 3, NO_BUF | SEQ, IntPtr.Zero);
        Microsoft.Win32.SafeHandles.SafeFileHandle t2 = CreateFileW(dst, GENERIC_WRITE, 3, IntPtr.Zero, 3, NO_BUF, IntPtr.Zero);
        bool ok = !t1.IsInvalid && !t2.IsInvalid;
        t1.Dispose(); t2.Dispose();
        if (!ok) return false;
        const long PIECE = 8L * 1024 * 1024;
        RunPhase(src, dst, data, PIECE, Math.Max(2, Math.Min(6, Environment.ProcessorCount)));
        RunPhase(src, dst, tail, PIECE, 1);
        UsedDirectIO = true;
        return true;
    }

    void RunPhase(string src, string dst, List<long[]> extents, long piece, int workers)
    {
        List<long[]> tasks = new List<long[]>();
        foreach (long[] e in extents)
            for (long o = e[0]; o < e[1]; o += piece) tasks.Add(new long[] { o, Math.Min(piece, e[1] - o) });
        if (tasks.Count == 0) return;
        int[] next = new int[] { -1 };
        Exception[] fail = new Exception[1];
        Thread[] ts = new Thread[workers];
        for (int w = 0; w < workers; w++)
        {
            ts[w] = new Thread(delegate() {
                Microsoft.Win32.SafeHandles.SafeFileHandle hs = null, hd = null;
                IntPtr buf = IntPtr.Zero;
                try
                {
                    hs = CreateFileW(src, GENERIC_READ, 3, IntPtr.Zero, 3, NO_BUF | SEQ, IntPtr.Zero);
                    hd = CreateFileW(dst, GENERIC_WRITE, 3, IntPtr.Zero, 3, NO_BUF, IntPtr.Zero);
                    if (hs.IsInvalid || hd.IsInvalid) throw new IOException("Could not open the drive for direct copying.");
                    buf = VirtualAlloc(IntPtr.Zero, (UIntPtr)(ulong)piece, 0x3000, 4);
                    if (buf == IntPtr.Zero) throw new OutOfMemoryException("No memory for the copy buffer.");
                    while (true)
                    {
                        if (Cancel || fail[0] != null) break;
                        int i = System.Threading.Interlocked.Increment(ref next[0]);
                        if (i >= tasks.Count) break;
                        long off = tasks[i][0];
                        long len = tasks[i][1];
                        long np;
                        if (!SetFilePointerEx(hs, off, out np, 0)) throw new IOException("Cannot move on the source drive (error " + System.Runtime.InteropServices.Marshal.GetLastWin32Error() + ").");
                        long got = 0;
                        while (got < len)
                        {
                            uint r;
                            if (!ReadFile(hs, (IntPtr)(buf.ToInt64() + got), (uint)(len - got), out r, IntPtr.Zero))
                                throw new IOException("Cannot read the source drive at " + (off + got) + " (error " + System.Runtime.InteropServices.Marshal.GetLastWin32Error() + ").");
                            if (r == 0) throw new EndOfStreamException("The source drive ended earlier than expected.");
                            got += r;
                        }
                        if (!SetFilePointerEx(hd, off, out np, 0)) throw new IOException("Cannot move on the target drive (error " + System.Runtime.InteropServices.Marshal.GetLastWin32Error() + ").");
                        long put = 0;
                        while (put < len)
                        {
                            uint wr;
                            if (!WriteFile(hd, (IntPtr)(buf.ToInt64() + put), (uint)(len - put), out wr, IntPtr.Zero))
                                throw new IOException("Cannot write the target drive at " + (off + put) + " (error " + System.Runtime.InteropServices.Marshal.GetLastWin32Error() + ").");
                            if (wr == 0) throw new IOException("The target drive stopped accepting data.");
                            put += wr;
                        }
                        System.Threading.Interlocked.Add(ref Done, len);
                    }
                    if (hd != null && !hd.IsInvalid) FlushFileBuffers(hd);
                }
                catch (Exception ex) { fail[0] = ex; }
                finally
                {
                    if (buf != IntPtr.Zero) VirtualFree(buf, UIntPtr.Zero, 0x8000);
                    if (hs != null) hs.Dispose();
                    if (hd != null) hd.Dispose();
                }
            });
            ts[w].IsBackground = true;
            ts[w].Start();
        }
        foreach (Thread t in ts) t.Join();
        if (fail[0] != null) throw new IOException(fail[0].Message);
        if (Cancel) throw new OperationCanceledException();
    }

    public void StartClone(string srcDisk, string dstDisk, long size)
    {
        StartSmartClone(srcDisk, dstDisk, size, new long[] { 0, size }, new long[0]);
    }

    // Copies only the given areas (data first, then the partition layout last).
    // Reads and writes at the same time: a reader thread fills big buffers while this thread writes them out.
    public void StartSmartClone(string srcDisk, string dstDisk, long diskSize, long[] data, long[] tail)
    {
        List<long[]> ext = Normalize(data, diskSize);
        List<long[]> tl = Normalize(tail, diskSize);
        List<long[]> dataOnly = new List<long[]>(ext);
        ext.AddRange(tl);
        long total = 0;
        foreach (long[] e in ext) total += e[1] - e[0];
        Total = total; Status = "Copying";
        Go(delegate() {
            if (diskSize % 4096 == 0 && FastCopy(srcDisk, dstDisk, dataOnly, tl)) return;
            const int CC = 16 * 1024 * 1024;
            const int N = 6;
            BlockingCollection<byte[]> free = new BlockingCollection<byte[]>(N);
            BlockingCollection<Item> full = new BlockingCollection<Item>(N);
            for (int i = 0; i < N; i++) free.Add(new byte[CC]);
            Exception readErr = null;
            Thread rd = new Thread(delegate() {
                try
                {
                    using (FileStream src = new FileStream(srcDisk, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096, FileOptions.SequentialScan))
                    {
                        long at = -1;
                        foreach (long[] e in ext)
                        {
                            long pos = e[0];
                            while (pos < e[1] && !Cancel)
                            {
                                byte[] b = null;
                                while (!free.TryTake(out b, 200)) { if (Cancel) break; }
                                if (b == null) return;
                                int want = (int)Math.Min((long)CC, e[1] - pos);
                                if (at != pos) { src.Seek(pos, SeekOrigin.Begin); }
                                ReadFull(src, b, want);
                                full.Add(new Item { B = b, N = want, Off = pos });
                                pos += want;
                                at = pos;
                            }
                            if (Cancel) return;
                        }
                    }
                }
                catch (Exception ex) { readErr = ex; }
                finally { full.CompleteAdding(); }
            });
            rd.IsBackground = true;
            rd.Start();
            using (FileStream dst = new FileStream(dstDisk, FileMode.Open, FileAccess.Write, FileShare.ReadWrite, 4096))
            {
                long done = 0;
                long wat = -1;
                foreach (Item it in full.GetConsumingEnumerable())
                {
                    if (Cancel) break;
                    if (wat != it.Off) { dst.Seek(it.Off, SeekOrigin.Begin); }
                    dst.Write(it.B, 0, it.N);
                    wat = it.Off + it.N;
                    done += it.N;
                    Done = done;
                    free.Add(it.B);
                }
                if (readErr == null && !Cancel) dst.Flush();
            }
            rd.Join();
            if (readErr != null) throw new IOException(readErr.Message);
            if (Cancel) throw new OperationCanceledException();
        }, null);
    }

    static bool IsZero(byte[] b, int len)
    {
        for (int i = 0; i < len; i++) { if (b[i] != 0) return false; }
        return true;
    }

    // Smallest image by default; Fast trades size for speed.
    public bool Fast;
    public bool Quick;

    static byte[] Deflate(byte[] b, int len, bool fast)
    {
        MemoryStream ms = new MemoryStream(len);
        using (DeflateStream ds = new DeflateStream(ms, fast ? CompressionLevel.Fastest : CompressionLevel.Optimal, true)) { ds.Write(b, 0, len); }
        return ms.ToArray();
    }

    static void ReadFull(Stream s, byte[] buf, int want)
    {
        int got = 0;
        while (got < want)
        {
            int r = s.Read(buf, got, want - got);
            if (r <= 0) throw new EndOfStreamException("The drive or image ended earlier than expected.");
            got += r;
        }
    }

    [ThreadStatic] static int[] lzTable;

    static uint LzRead32(byte[] b, int i) { return (uint)(b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)); }
    static int LzHash(uint v) { return (int)((v * 2654435761u) >> 16); }

    // Fast block compressor (LZ4 style): quick to run, and still shrinks typical Windows data to about half.
    static int Lz4CompressInto(byte[] src, int n, byte[] dst) { return Lz4CompressInto(src, n, dst, 6); }

    // skipShift 6 is the normal search. 4 gives up four times sooner on data that does not repeat (MAX speed);
    // the output is still ordinary blocks that Check and Restore read the same way.
    static int Lz4CompressInto(byte[] src, int n, byte[] dst, int skipShift)
    {
        int[] table = lzTable;
        if (table == null) { table = new int[1 << 16]; lzTable = table; }
        Array.Clear(table, 0, table.Length);
        int ip = 0, anchor = 0, op = 0;
        int mfLimit = n - 12, matchLimit = n - 5;
        if (n >= 13)
        {
            int searchNb = 1 << 6;
            table[LzHash(LzRead32(src, 0))] = 1;
            ip = 1;
            while (ip < mfLimit)
            {
                int h = LzHash(LzRead32(src, ip));
                int refp1 = table[h]; table[h] = ip + 1;
                int step = searchNb >> skipShift;
                if (refp1 != 0 && ip - (refp1 - 1) <= 65535 && LzRead32(src, refp1 - 1) == LzRead32(src, ip))
                {
                    int refp = refp1 - 1;
                    while (ip > anchor && refp > 0 && src[ip - 1] == src[refp - 1]) { ip--; refp--; }
                    int litLen = ip - anchor;
                    int token = op++;
                    if (litLen >= 15) { dst[token] = 15 << 4; int rem = litLen - 15; while (rem >= 255) { dst[op++] = 255; rem -= 255; } dst[op++] = (byte)rem; }
                    else dst[token] = (byte)(litLen << 4);
                    Buffer.BlockCopy(src, anchor, dst, op, litLen); op += litLen;
                    int offset = ip - refp; dst[op++] = (byte)offset; dst[op++] = (byte)(offset >> 8);
                    int mp = ip + 4, rp = refp + 4;
                    while (mp < matchLimit && src[mp] == src[rp]) { mp++; rp++; }
                    int mlen = mp - ip - 4;
                    if (mlen >= 15) { dst[token] |= 15; int rem = mlen - 15; while (rem >= 255) { dst[op++] = 255; rem -= 255; } dst[op++] = (byte)rem; }
                    else dst[token] |= (byte)mlen;
                    ip = mp; anchor = ip; searchNb = 1 << 6;
                    if (ip - 2 >= 0 && ip - 2 < mfLimit) table[LzHash(LzRead32(src, ip - 2))] = ip - 1;
                    continue;
                }
                ip += step; searchNb++;
            }
        }
        int last = n - anchor;
        if (last >= 15) { dst[op++] = 15 << 4; int rem = last - 15; while (rem >= 255) { dst[op++] = 255; rem -= 255; } dst[op++] = (byte)rem; }
        else dst[op++] = (byte)(last << 4);
        Buffer.BlockCopy(src, anchor, dst, op, last); op += last;
        return op;
    }

    static byte[] Lz4Block(byte[] src, int n)
    {
        byte[] dst = new byte[n + n / 255 + 32];
        int len = Lz4CompressInto(src, n, dst);
        byte[] r = new byte[len]; Buffer.BlockCopy(dst, 0, r, 0, len);
        return r;
    }

    [ThreadStatic] static byte[] lzDst;
    static readonly ConcurrentBag<byte[]> bufPool = new ConcurrentBag<byte[]>();
    static byte[] GetBuf() { byte[] b; if (bufPool.TryTake(out b)) return b; return new byte[Chunk]; }

    // AES-256-CBC, returning the IV and the cipher text separately (no extra copies).
    // Image saving: locks one block into a reused buffer (no new memory per block). Same bytes as EncryptParts.
    [ThreadStatic] static Aes encAes;
    [ThreadStatic] static SHA256CryptoServiceProvider encSha;
    static readonly ConcurrentBag<byte[]> encPool = new ConcurrentBag<byte[]>();
    static byte[] GetEncBuf() { byte[] b; if (encPool.TryTake(out b)) return b; return new byte[Chunk + 64]; }
    static int EncryptInto(byte[] key, byte[] data, int len, byte[] dst, out byte[] iv)
    {
        Aes a = encAes;
        if (a == null) { a = Aes.Create(); a.KeySize = 256; a.Mode = CipherMode.CBC; a.Padding = PaddingMode.None; encAes = a; }
        a.Key = key; a.GenerateIV(); iv = a.IV;
        int full = len - (len % 16);
        int pad = 16 - (len % 16);
        byte[] last = new byte[16];
        Buffer.BlockCopy(data, full, last, 0, len - full);
        for (int i = len - full; i < 16; i++) last[i] = (byte)pad;
        using (ICryptoTransform t = a.CreateEncryptor(key, iv))
        {
            int w = 0;
            if (full > 0) w = t.TransformBlock(data, 0, full, dst, 0);
            w += t.TransformBlock(last, 0, 16, dst, full);
            return w;
        }
    }

    static byte[] EncryptParts(byte[] key, byte[] data, int len, out byte[] iv)
    {
        using (Aes a = Aes.Create())
        {
            a.KeySize = 256; a.Mode = CipherMode.CBC; a.Padding = PaddingMode.PKCS7;
            a.Key = key; a.GenerateIV(); iv = a.IV;
            using (ICryptoTransform t = a.CreateEncryptor()) { return t.TransformFinalBlock(data, 0, len); }
        }
    }

    static void Lz4Decode(byte[] c, int cLen, byte[] dst, int rawLen)
    {
        int ip = 0, op = 0;
        while (ip < cLen)
        {
            int token = c[ip++];
            int lit = token >> 4;
            if (lit == 15) { int s; do { s = c[ip++]; lit += s; } while (s == 255); }
            if (op + lit > rawLen || ip + lit > cLen) throw new InvalidDataException("The image file is damaged.");
            Buffer.BlockCopy(c, ip, dst, op, lit); ip += lit; op += lit;
            if (ip >= cLen) break;
            int offset = c[ip] | (c[ip + 1] << 8); ip += 2;
            int ml = token & 15;
            if (ml == 15) { int s; do { s = c[ip++]; ml += s; } while (s == 255); }
            ml += 4;
            int mp = op - offset;
            if (offset == 0 || mp < 0 || op + ml > rawLen) throw new InvalidDataException("The image file is damaged.");
            if (offset >= ml) { Buffer.BlockCopy(dst, mp, dst, op, ml); op += ml; }
            else { for (int k = 0; k < ml; k++) dst[op++] = dst[mp++]; }
        }
        if (op != rawLen) throw new InvalidDataException("The image file is damaged.");
    }

    // For tests only.
    public static byte[] TestLz4(byte[] src) { return Lz4Block(src, src.Length); }
    public static byte[] TestUnLz4(byte[] c, int rawLen) { byte[] dd = new byte[rawLen]; Lz4Decode(c, c.Length, dd, rawLen); return dd; }
    static void Inflate(byte[] c, byte[] dst, int rawLen) { Inflate(c, c.Length, dst, rawLen); }
    static void Inflate(byte[] c, int cLen, byte[] dst, int rawLen)
    {
        using (DeflateStream ds = new DeflateStream(new MemoryStream(c, 0, cLen), CompressionMode.Decompress)) { ReadFull(ds, dst, rawLen); }
    }

    // Restore: unlocks one block into a buffer that is reused (no new memory per block, so no stalls for memory clean-up). Returns the length.
    static int DecryptInto(Aes a, byte[] data, int len, byte[] dst)
    {
        if (len < 32 || ((len - 16) % 16) != 0) throw new InvalidDataException("The image file is damaged.");
        byte[] iv = new byte[16];
        Buffer.BlockCopy(data, 0, iv, 0, 16);
        int n;
        using (ICryptoTransform t = a.CreateDecryptor(a.Key, iv)) { n = t.TransformBlock(data, 16, len - 16, dst, 0); }
        if (n != len - 16) throw new InvalidDataException("The image file is damaged.");
        int pad = dst[n - 1];
        if (pad < 1 || pad > 16) throw new InvalidDataException("The image file is damaged.");
        for (int i = n - pad; i < n; i++) if (dst[i] != pad) throw new InvalidDataException("The image file is damaged.");
        return n - pad;
    }

    static byte[] KeyCheck(byte[] key)
    {
        byte[] tag = Encoding.ASCII.GetBytes("DRDirect Imager key check");
        byte[] all = new byte[key.Length + tag.Length];
        Buffer.BlockCopy(key, 0, all, 0, key.Length);
        Buffer.BlockCopy(tag, 0, all, key.Length, tag.Length);
        using (SHA256 h = SHA256.Create()) { return h.ComputeHash(all); }
    }

    static byte[] Encrypt(byte[] key, byte[] data, int len)
    {
        using (Aes a = Aes.Create())
        {
            a.KeySize = 256; a.Mode = CipherMode.CBC; a.Padding = PaddingMode.PKCS7;
            a.Key = key; a.GenerateIV();
            using (ICryptoTransform t = a.CreateEncryptor())
            {
                byte[] c = t.TransformFinalBlock(data, 0, len);
                byte[] r = new byte[16 + c.Length];
                Buffer.BlockCopy(a.IV, 0, r, 0, 16);
                Buffer.BlockCopy(c, 0, r, 16, c.Length);
                return r;
            }
        }
    }

    static byte[] Decrypt(byte[] key, byte[] data)
    {
        if (data.Length < 32) throw new InvalidDataException("The image file is damaged.");
        using (Aes a = Aes.Create())
        {
            a.KeySize = 256; a.Mode = CipherMode.CBC; a.Padding = PaddingMode.PKCS7;
            a.Key = key;
            byte[] iv = new byte[16];
            Buffer.BlockCopy(data, 0, iv, 0, 16);
            a.IV = iv;
            using (ICryptoTransform t = a.CreateDecryptor()) { return t.TransformFinalBlock(data, 16, data.Length - 16); }
        }
    }

    static string Hex(byte[] h)
    {
        StringBuilder sb = new StringBuilder();
        foreach (byte x in h) sb.Append(x.ToString("x2"));
        return sb.ToString();
    }

    void DoImage(string disk, string outFile, long size, string label)
    {
        byte[][] bufs = new byte[Batch][];
        int[] lens = new int[Batch];
        SHA256 sha = SHA256.Create();
        using (FileStream src = new FileStream(disk, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096))
        using (FileStream o = new FileStream(outFile, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
        using (BinaryWriter bw = new BinaryWriter(o))
        {
            bw.Write(Encoding.ASCII.GetBytes(Magic));
            bw.Write(size);
            bw.Write(512);
            bw.Write(Chunk);
            bw.Write(label == null ? "" : label);
            if (Key == null) throw new InvalidOperationException("No PC lock key.");
            bw.Write(KeyCheck(Key));
            long pos = 0;
            while (pos < size)
            {
                if (Cancel) throw new OperationCanceledException();
                int n = 0;
                long p = pos;
                while (n < Batch && p < size)
                {
                    int want = (int)Math.Min((long)Chunk, size - p);
                    if (bufs[n] == null) bufs[n] = new byte[Chunk];
                    ReadFull(src, bufs[n], want);
                    lens[n] = want;
                    sha.TransformBlock(bufs[n], 0, want, null, 0);
                    p += want; n++;
                }
                byte[][] comp = new byte[n][];
                byte[][] enc = new byte[n][];
                bool[] zero = new bool[n];
                byte[] key = Key;
                Parallel.For(0, n, delegate(int i) {
                    if (IsZero(bufs[i], lens[i])) { zero[i] = true; }
                    else { byte[] c = Deflate(bufs[i], lens[i], Fast); comp[i] = (c.Length < lens[i]) ? c : null; enc[i] = (comp[i] == null) ? Encrypt(key, bufs[i], lens[i]) : Encrypt(key, comp[i], comp[i].Length); }
                });
                for (int i = 0; i < n; i++)
                {
                    bw.Write(pos);
                    bw.Write(lens[i]);
                    if (zero[i]) { bw.Write(0); }
                    else if (comp[i] == null) { bw.Write(lens[i]); bw.Write(enc[i].Length); bw.Write(enc[i]); }
                    else { bw.Write(comp[i].Length); bw.Write(enc[i].Length); bw.Write(enc[i]); }
                    pos += lens[i];
                }
                Done = pos;
            }
            sha.TransformFinalBlock(new byte[0], 0, 0);
            bw.Write(-1L);
            bw.Write(sha.Hash);
            bw.Flush();
            Hash = Hex(sha.Hash);
        }
    }

    // How far through the image file a restore or check has read, so the time left can be worked out from the
    // part of the image still to read. Empty parts of the drive cost almost nothing, so counting the whole drive
    // made the time left look hours longer than it was.
    public long FileDone;
    public long FileTotal;

    class RBlock { public long Seq; public long Off; public int Raw; public int Comp; public byte[] Enc; public int EncLen; public byte[] Hash; }

    // Restore and check using every processor thread: one thread reads the image in order, all the others
    // decrypt, unpack and write their blocks at the same time, each on its own handle to the drive, and the
    // checksum is still added up in the original order so a damaged image is caught exactly as before.
    void ReplayParallel(string file, string disk)
    {
        FileTotal = new FileInfo(file).Length; FileDone = 0;
        using (FileStream f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, FileOptions.SequentialScan))
        using (BinaryReader br = new BinaryReader(f))
        {
            string m = Encoding.ASCII.GetString(br.ReadBytes(8));
            if (m != Magic && m != Magic3 && m != Magic4) throw new InvalidDataException("This is not a DRDirect image file.");
            bool v3 = (m == Magic3 || m == Magic4); bool lz = (m == Magic4);
            if (!v3) { br.Dispose(); f.Dispose(); ReplayClassic(file, disk); return; }
            long size = br.ReadInt64();
            br.ReadInt32();
            int chunk = br.ReadInt32();
            br.ReadString();
            byte[] kc = br.ReadBytes(32);
            if (lz) br.ReadInt32();
            bool same = Key != null && kc.Length == 32;
            if (same) { byte[] mine = KeyCheck(Key); for (int q = 0; q < 32; q++) if (mine[q] != kc[q]) same = false; }
            if (!same) throw new InvalidDataException("This image is locked to the PC that made it. It can only be opened on that PC.");

            int workers = Math.Max(2, Environment.ProcessorCount);
            BlockingCollection<RBlock> todo = new BlockingCollection<RBlock>(workers * 3);
            BlockingCollection<RBlock> finished = new BlockingCollection<RBlock>();
            // Reused buffers for the locked blocks read from the image file.
            BlockingCollection<byte[]> pool = new BlockingCollection<byte[]>();
            for (int q = 0; q < workers * 4 + 4; q++) pool.Add(new byte[chunk + 64]);
            Exception[] fail = new Exception[1];
            Thread[] ts = new Thread[workers];
            for (int w = 0; w < workers; w++)
            {
                ts[w] = new Thread(delegate() {
                    FileStream d = null;
                    Microsoft.Win32.SafeHandles.SafeFileHandle hd = null;
                    IntPtr nbuf = IntPtr.Zero;
                    byte[] raw = new byte[chunk];
                    byte[] plain = new byte[chunk + 64];
                    Aes aes = Aes.Create(); aes.KeySize = 256; aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.None; aes.Key = Key;
                    try
                    {
                        // Direct (unbuffered) writes straight to the drive, like the copy engine; falls back to a normal stream if the drive will not open that way.
                        if (disk != null)
                        {
                            hd = CreateFileW(disk, GENERIC_WRITE, 3, IntPtr.Zero, 3, NO_BUF, IntPtr.Zero);
                            if (!hd.IsInvalid) nbuf = VirtualAlloc(IntPtr.Zero, (UIntPtr)(ulong)chunk, 0x3000, 4);
                            if (hd.IsInvalid || nbuf == IntPtr.Zero) { hd.Dispose(); hd = null; nbuf = IntPtr.Zero; d = new FileStream(disk, FileMode.Open, FileAccess.Write, FileShare.ReadWrite, 1); }
                        }
                        using (SHA256CryptoServiceProvider hc = new SHA256CryptoServiceProvider())
                        foreach (RBlock b in todo.GetConsumingEnumerable())
                        {
                            if (Cancel || fail[0] != null) { if (b.Enc != null) { pool.Add(b.Enc); b.Enc = null; } continue; }
                            b.Hash = new byte[32];
                            if (b.Comp != 0)
                            {
                                int cl;
                                try { cl = DecryptInto(aes, b.Enc, b.EncLen, plain); }
                                catch (CryptographicException) { throw new InvalidDataException("The image file is damaged (bad block at " + b.Off + ")."); }
                                if (cl != b.Comp) throw new InvalidDataException("The image file is damaged (bad block at " + b.Off + ").");
                                byte[] src = raw;
                                if (b.Comp == b.Raw) src = plain; else if (lz) Lz4Decode(plain, b.Comp, raw, b.Raw); else Inflate(plain, b.Comp, raw, b.Raw);
                                b.Hash = lz ? hc.ComputeHash(b.Enc, 0, b.EncLen) : hc.ComputeHash(src, 0, b.Raw);
                                pool.Add(b.Enc); b.Enc = null;
                                long wt0 = System.Diagnostics.Stopwatch.GetTimestamp();
                                if (hd != null && (b.Raw % 4096) == 0)
                                {
                                    System.Runtime.InteropServices.Marshal.Copy(src, 0, nbuf, b.Raw);
                                    long np;
                                    if (!SetFilePointerEx(hd, b.Off, out np, 0)) throw new IOException("Cannot move on the target drive (error " + System.Runtime.InteropServices.Marshal.GetLastWin32Error() + ").");
                                    int put = 0;
                                    while (put < b.Raw)
                                    {
                                        uint wr;
                                        if (!WriteFile(hd, (IntPtr)(nbuf.ToInt64() + put), (uint)(b.Raw - put), out wr, IntPtr.Zero))
                                            throw new IOException("Cannot write the target drive at " + (b.Off + put) + " (error " + System.Runtime.InteropServices.Marshal.GetLastWin32Error() + ").");
                                        if (wr == 0) throw new IOException("The target drive stopped accepting data.");
                                        put += (int)wr;
                                    }
                                }
                                else if (disk != null)
                                {
                                    if (d == null) d = new FileStream(disk, FileMode.Open, FileAccess.Write, FileShare.ReadWrite, 1);
                                    d.Seek(b.Off, SeekOrigin.Begin); d.Write(src, 0, b.Raw);
                                }
                                lock (this) { SecWrite += (System.Diagnostics.Stopwatch.GetTimestamp() - wt0) / (double)System.Diagnostics.Stopwatch.Frequency; }
                            }
                            b.Enc = null;
                            System.Threading.Interlocked.Add(ref Done, (long)b.Raw);
                            finished.Add(b);
                        }
                        if (d != null) d.Flush(true);
                        if (hd != null) FlushFileBuffers(hd);
                    }
                    catch (Exception ex) { if (fail[0] == null) fail[0] = ex; }
                    finally
                    {
                        aes.Dispose();
                        if (d != null) d.Dispose();
                        if (nbuf != IntPtr.Zero) VirtualFree(nbuf, UIntPtr.Zero, 0x8000);
                        if (hd != null) hd.Dispose();
                    }
                });
                ts[w].IsBackground = true;
                ts[w].Start();
            }

            // The checksum, in the image's own order, on its own thread.
            SHA256 sha = SHA256.Create();
            long hashed = 0;
            Thread hasher = new Thread(delegate() {
                try
                {
                    Dictionary<long, RBlock> early = new Dictionary<long, RBlock>();
                    long want = 0;
                    foreach (RBlock b in finished.GetConsumingEnumerable())
                    {
                        early[b.Seq] = b;
                        RBlock nb;
                        while (early.TryGetValue(want, out nb))
                        {
                            early.Remove(want);
                            sha.TransformBlock(BitConverter.GetBytes(nb.Off), 0, 8, null, 0);
                            sha.TransformBlock(BitConverter.GetBytes(nb.Raw), 0, 4, null, 0);
                            sha.TransformBlock(nb.Hash, 0, 32, null, 0);
                            hashed++; want++;
                        }
                    }
                }
                catch (Exception ex) { if (fail[0] == null) fail[0] = ex; }
            });
            hasher.IsBackground = true;
            hasher.Start();

            long pos = 0, seq = 0;
            byte[] stored = null;
            try
            {
                while (true)
                {
                    if (Cancel) throw new OperationCanceledException();
                    if (fail[0] != null) break;
                    long rt0 = System.Diagnostics.Stopwatch.GetTimestamp();
                    long off = br.ReadInt64();
                    if (off == -1) break;
                    int rawLen = br.ReadInt32();
                    int compLen = br.ReadInt32();
                    if (off != pos || rawLen <= 0 || rawLen > chunk || compLen < 0 || compLen > rawLen)
                        throw new InvalidDataException("The image file is damaged (bad block at " + pos + ").");
                    RBlock b = new RBlock { Seq = seq++, Off = off, Raw = rawLen, Comp = compLen };
                    if (compLen != 0)
                    {
                        int encLen = br.ReadInt32();
                        if (encLen <= 0 || encLen > rawLen + 64) throw new InvalidDataException("The image file is damaged (bad block at " + pos + ").");
                        byte[] eb = null;
                        while (eb == null) { if (fail[0] != null || Cancel) break; pool.TryTake(out eb, 200); }
                        if (eb == null) break;
                        int got = 0;
                        while (got < encLen) { int r = f.Read(eb, got, encLen - got); if (r <= 0) break; got += r; }
                        if (got != encLen) { pool.Add(eb); throw new InvalidDataException("The image file is cut short."); }
                        b.Enc = eb; b.EncLen = encLen;
                    }
                    long rt1 = System.Diagnostics.Stopwatch.GetTimestamp();
                    while (!todo.TryAdd(b, 200)) { if (fail[0] != null || Cancel) break; }
                    long rt2 = System.Diagnostics.Stopwatch.GetTimestamp();
                    SecRead += (rt1 - rt0) / (double)System.Diagnostics.Stopwatch.Frequency;
                    SecBlocked += (rt2 - rt1) / (double)System.Diagnostics.Stopwatch.Frequency;
                    pos += rawLen;
                    FileDone = f.Position;
                }
                if (fail[0] == null && !Cancel) stored = br.ReadBytes(32);
            }
            finally
            {
                todo.CompleteAdding();
                foreach (Thread t in ts) t.Join();
                finished.CompleteAdding();
                hasher.Join();
            }
            if (fail[0] != null) throw new IOException(fail[0].Message);
            if (Cancel) throw new OperationCanceledException();
            FileDone = FileTotal;
            sha.TransformFinalBlock(new byte[0], 0, 0);
            if (pos != size || hashed != seq) throw new InvalidDataException("The image file is damaged (size does not match).");
            for (int i = 0; i < 32; i++)
                if (stored == null || stored.Length != 32 || stored[i] != sha.Hash[i])
                    throw new InvalidDataException("The image file is damaged (checksum does not match).");
            Hash = Hex(sha.Hash);
        }
    }

    // Older images (DRIMG002) hash every raw byte in order, so they keep the one-thread path.
    void ReplayClassic(string file, string disk)
    {
        if (disk == null) { Replay(file, null); return; }
        using (FileStream d = new FileStream(disk, FileMode.Open, FileAccess.Write, FileShare.ReadWrite, 4096, FileOptions.WriteThrough))
        { Replay(file, d); }
    }

    // Reads the whole image, checks every block and the final checksum.
    // With a target stream it also writes the data there (restore).
    void Replay(string file, Stream target)
    {
        using (FileStream f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
        using (BinaryReader br = new BinaryReader(f))
        {
            string m = Encoding.ASCII.GetString(br.ReadBytes(8));
            if (m != Magic && m != Magic3 && m != Magic4) throw new InvalidDataException("This is not a DRDirect image file.");
            bool v3 = (m == Magic3 || m == Magic4); bool lz = (m == Magic4);
            long size = br.ReadInt64();
            br.ReadInt32();
            int chunk = br.ReadInt32();
            br.ReadString();
            byte[] kc = br.ReadBytes(32);
            int method = lz ? br.ReadInt32() : 0;
            bool same = Key != null && kc.Length == 32;
            if (same) { byte[] mine = KeyCheck(Key); for (int q = 0; q < 32; q++) if (mine[q] != kc[q]) same = false; }
            if (!same) throw new InvalidDataException("This image is locked to the PC that made it. It can only be opened on that PC.");
            SHA256 sha = SHA256.Create();
            byte[] raw = new byte[chunk];
            byte[] zero = new byte[chunk];
            long pos = 0;
            while (true)
            {
                if (Cancel) throw new OperationCanceledException();
                long off = br.ReadInt64();
                if (off == -1) break;
                int rawLen = br.ReadInt32();
                int compLen = br.ReadInt32();
                if (off != pos || rawLen <= 0 || rawLen > chunk || compLen < 0 || compLen > rawLen)
                    throw new InvalidDataException("The image file is damaged (bad block at " + pos + ").");
                byte[] data; byte[] encBytes = null;
                if (compLen == 0) { data = zero; }
                else
                {
                    int encLen = br.ReadInt32();
                    if (encLen <= 0 || encLen > rawLen + 64) throw new InvalidDataException("The image file is damaged (bad block at " + pos + ").");
                    byte[] e = br.ReadBytes(encLen); encBytes = e;
                    if (e.Length != encLen) throw new InvalidDataException("The image file is cut short.");
                    byte[] c;
                    try { c = Decrypt(Key, e); }
                    catch (CryptographicException) { throw new InvalidDataException("The image file is damaged (bad block at " + pos + ")."); }
                    if (c.Length != compLen) throw new InvalidDataException("The image file is damaged (bad block at " + pos + ").");
                    if (compLen == rawLen) Buffer.BlockCopy(c, 0, raw, 0, rawLen); else if (lz) Lz4Decode(c, compLen, raw, rawLen); else Inflate(c, raw, rawLen);
                    data = raw;
                }
                if (v3)
                {
                    sha.TransformBlock(BitConverter.GetBytes(off), 0, 8, null, 0);
                    sha.TransformBlock(BitConverter.GetBytes(rawLen), 0, 4, null, 0);
                    byte[] chh = new byte[32];
                    if (compLen != 0) { if (lz) { using (SHA256CryptoServiceProvider hc = new SHA256CryptoServiceProvider()) chh = hc.ComputeHash(encBytes); } else { chh = SHA256.Create().ComputeHash(data, 0, rawLen); } }
                    sha.TransformBlock(chh, 0, 32, null, 0);
                    if (target != null) { if (compLen == 0) target.Seek(rawLen, SeekOrigin.Current); else target.Write(data, 0, rawLen); }
                }
                else
                {
                    sha.TransformBlock(data, 0, rawLen, null, 0);
                    if (target != null) target.Write(data, 0, rawLen);
                }
                pos += rawLen;
                Done = pos;
            }
            sha.TransformFinalBlock(new byte[0], 0, 0);
            byte[] stored = br.ReadBytes(32);
            if (pos != size) throw new InvalidDataException("The image file is damaged (size does not match).");
            for (int i = 0; i < 32; i++)
                if (stored.Length != 32 || stored[i] != sha.Hash[i])
                    throw new InvalidDataException("The image file is damaged (checksum does not match).");
            Hash = Hex(sha.Hash);
            if (target != null) target.Flush();
        }
    }
}
'@
if (-not ('DRImgJob' -as [type])) {
    # WinPE has no compiler, so the rescue USB carries this precompiled copy
    $dll = Join-Path $PSScriptRoot 'DRImgEngine.dll'
    if ($env:SystemDrive -eq 'X:' -and (Test-Path -LiteralPath $dll)) { Add-Type -Path $dll } else { Add-Type -Language CSharp -TypeDefinition $script:DRImgSource }
}

# Plain words for a drive, for messages: "your Windows drive (C:) - name, size" or "drive 1 (F:) - name, size".
function Get-DriveWords($d, [switch]$Cap) {
    $who = if ($d.IsWindows) { 'your Windows drive' } else { "drive $($d.Number)" }
    $ltr = if ($d.Letters) { " ($($d.Letters))" } else { '' }
    $t = "$who$ltr - $($d.Name), $(Format-ImgSize $d.Size)"
    if ($Cap) { $t = $t.Substring(0, 1).ToUpper() + $t.Substring(1) }
    $t
}

# The same PC ID the Cleaner uses: motherboard UUID + board serial (falls back like Get-PCID.ps1).
function Get-ImagerPcId {
    $placeholders = @('', 'none', 'unknown', 'invalid', 'n/a', 'na', 'not applicable', 'not specified', 'default string', 'to be filled by o.e.m.', 'to be filled by oem', 'filled by oem', 'system serial number', 'serial number', 'base board serial number')
    $clean = {
        param($v)
        if ($null -eq $v) { return '' }
        $c = ([string]$v).Trim().ToLowerInvariant()
        if ($placeholders -contains $c) { return '' }
        $cc = $c -replace '[-. ]', ''
        if ($cc -eq '' -or $cc -match '^f+$' -or $cc -match '^0+$') { return '' }
        $c
    }
    $uuid = & $clean (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID
    $board = & $clean (Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue).SerialNumber
    $bios = & $clean (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
    if ($uuid -and $board) { return "$uuid-$board" }
    if ($uuid) { return $uuid }
    if ($board) { return $board }
    if ($bios) { return $bios }
    try {
        $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
        $g = & $clean $key.OpenSubKey('SOFTWARE\Microsoft\Cryptography').GetValue('MachineGuid')
        if ($g) { return $g }
    } catch { }
    throw 'This PC does not report any usable ID, so images cannot be locked to it.'
}

# The lock key for images made on (and only openable on) this PC.
function Get-ImagerKey {
    $sha = [Security.Cryptography.SHA256]::Create()
    $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('DRDirect Imager lock v1|' + (Get-ImagerPcId)))
}

function New-ImagerJob {
    $j = New-Object DRImgJob
    $j.Key = Get-ImagerKey
    $j
}

function Format-Duration([double]$Seconds) {
    if ($Seconds -lt 60) { return ('{0:N0} sec' -f [Math]::Max($Seconds, 1)) }
    $t = [TimeSpan]::FromSeconds($Seconds)
    if ($t.TotalHours -ge 1) { return ('{0} h {1} min' -f [int][Math]::Floor($t.TotalHours), $t.Minutes) }
    '{0} min' -f [int][Math]::Ceiling($t.TotalMinutes)
}

function Format-ImgSize([double]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Get-ImagerDisks {
    foreach ($d in (Get-Disk | Sort-Object Number)) {
        $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter):" })
        [pscustomobject]@{
            Number   = [int]$d.Number
            Name     = [string]$d.FriendlyName
            Size     = [int64]$d.Size
            IsWindows = [bool]($d.IsBoot -or $d.IsSystem)
            Letters  = ($letters -join ' ')
            Path     = '\\.\PhysicalDrive' + $d.Number
        }
    }
}

function Get-DiskLetters([int]$DiskNumber) {
    @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter)" })
}

# Flushes cached writes so an image of a drive in use is as consistent as it can be.
function Sync-DiskVolumes([int]$DiskNumber) {
    foreach ($l in (Get-DiskLetters $DiskNumber)) { try { Write-VolumeCache -DriveLetter $l -ErrorAction Stop } catch { } }
}

# Returns a reason to refuse, or $null when the image can go ahead.
function Get-ImageBlockReason([int]$DiskNumber, [string]$OutFile) {
    if (-not (Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue)) { return 'That drive is no longer there.' }
    if ([string]::IsNullOrWhiteSpace($OutFile)) { return 'Choose where to save the image.' }
    $root = [IO.Path]::GetPathRoot($OutFile)
    if (-not $root -or $root.StartsWith('\\')) { return 'Save the image on a drive with a letter, such as D:.' }
    if ((Get-DiskLetters $DiskNumber) -contains $root.Substring(0, 1)) {
        return 'The image cannot be saved on the drive you are copying. Choose a different drive.'
    }
    if ($OutFile -notmatch '\.drimg$') { return 'The file name must end in .drimg' }
    $null
}

# The used areas of a drive, so SmartCopy can skip empty space. When it cannot tell which parts are used it STOPS with a message:
# it never falls back to copying the empty space. Result.Whole lists any partition that has to be copied whole (not NTFS).
function Get-SmartExtents([int]$DiskNumber, [int64]$DiskSize) {
    try {
        $wholeParts = New-Object 'System.Collections.Generic.List[string]'
        $data = New-Object 'System.Collections.Generic.List[long]'
        $tail = New-Object 'System.Collections.Generic.List[long]'
        $mb = 1MB
        $tail.Add(0); $tail.Add($mb)
        $tail.Add($DiskSize - $mb); $tail.Add($mb)
        foreach ($p in (Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop)) {
            $whole = $true
            $fs = $null
            $vol = $p.AccessPaths | Where-Object { $_ -match '^\\\\\?\\Volume\{' } | Select-Object -First 1
            if ($vol) {
                try { $fs = (Get-Volume -Path $vol -ErrorAction Stop).FileSystem } catch { }
                # An unknown file system (Get-Volume failed, as it can inside the rescue system) is treated as NTFS: if the used-space map
                # cannot be read, the copy stops. It never quietly copies the whole partition.
                if ($fs -eq 'NTFS' -or -not $fs) {
                    try {
                        $runs = [DRImgJob]::GetUsedExtents($vol.TrimEnd('\'), [int64]$p.Offset)
                        foreach ($r in $runs) { $data.Add($r) }
                        $data.Add([int64]$p.Offset + [int64]$p.Size - $mb); $data.Add($mb)   # backup boot sector
                        $whole = $false
                    } catch { throw ('Could not read which parts of partition {0} hold data, so nothing was copied. Open the Imager as administrator and try again. ({1})' -f $p.PartitionNumber, $_.Exception.Message) }
                }
            }
            if ($whole) {
                $data.Add([int64]$p.Offset); $data.Add([int64]$p.Size)
                $wholeParts.Add(('partition {0} ({1}, {2})' -f $p.PartitionNumber, $(if ($fs) { $fs } else { 'no file system' }), (Format-ImgSize $p.Size)))
            }
        }
        [pscustomobject]@{ Data = [long[]]$data.ToArray(); Tail = [long[]]$tail.ToArray(); Whole = [string[]]$wholeParts.ToArray() }
    }
    catch {
        if ($_.Exception.Message -like 'Could not read*') { throw }
        throw ('Could not read which parts of the drive hold data, so nothing was copied. ({0})' -f $_.Exception.Message)
    }
}

# After an image is saved: a small text file next to it says where the time went, so a slow run can be diagnosed.
# The exact time a job really took on this PC, measured by its stopwatch from start to finish. Never an estimate.
function Format-TookTime([double]$Seconds) {
    $t = [TimeSpan]::FromSeconds([Math]::Round([Math]::Max($Seconds, 0)))
    $h = [int][Math]::Floor($t.TotalHours)
    if ($h -ge 1) { return ('{0} h {1:00} min {2:00} sec' -f $h, $t.Minutes, $t.Seconds) }
    if ($t.Minutes -ge 1) { return ('{0} min {1:00} sec' -f $t.Minutes, $t.Seconds) }
    '{0} sec' -f $t.Seconds
}

function Write-ImagerTiming($Job, [double]$Seconds, [string]$ImageFile) {
    try {
        $sec = [Math]::Max($Seconds, 0.5)
        $done = [double]$Job.Done
        $rows = @(
            @('Reading the drive', [double]$Job.SecRead),
            @('Compressing and locking', [double]$Job.SecComp),
            @('Writing the image file', [double]$Job.SecWrite),
            @('Waiting for the drive to be read', [double]$Job.SecWait),
            @('Waiting for the file to be written', [double]$Job.SecBlocked)
        )
        $worst = $rows | Sort-Object { $_[1] } -Descending | Select-Object -First 1
        $verdict = switch ($worst[0]) {
            'Reading the drive' { 'The drive being copied is the slowest part.' }
            'Compressing and locking' { 'The processor is the slowest part (compressing and locking the data).' }
            'Writing the image file' { 'The drive the image is saved on is the slowest part.' }
            'Waiting for the file to be written' { 'The drive the image is saved on is the slowest part.' }
            default { 'Reading is the slowest part: the processor waits for the drive to deliver the data.' }
        }
        $size = 0; try { $size = (Get-Item -LiteralPath $ImageFile -ErrorAction Stop).Length } catch { }
        $lines = @(
            'DRDirect Imager - timing of this image',
            ('When:            {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
            ('Data read:       {0} (empty space is skipped)' -f (Format-ImgSize $done)),
            ('Image file:      {0}' -f (Format-ImgSize $size)),
            ('Total time:      {0:N0} seconds' -f $sec),
            ('Average speed:   {0}/s' -f (Format-ImgSize ($done / $sec))),
            ('Processor:       {0} threads, {1} used for compressing' -f [Environment]::ProcessorCount, $Job.Workers),
            '',
            'Seconds spent (the threads overlap, so these do not add up to the total):'
        ) + ($rows | ForEach-Object { '  {0,-38} {1,8:N1}' -f $_[0], $_[1] }) + @('', ('Slowest part: ' + $verdict))
        try {
            $lines += @('', 'Processor work, added up over all threads:',
                ('  {0,-38} {1,8:N1}' -f 'Compressing', [double]$Job.SecPack),
                ('  {0,-38} {1,8:N1}' -f 'Locking (encryption)', [double]$Job.SecLock),
                ('  {0,-38} {1,8:N1}' -f 'Checksum', [double]$Job.SecSum))
        } catch { }
        Set-Content -LiteralPath ($ImageFile + '.timing.txt') -Value $lines -Encoding UTF8
    } catch { }
}

# Returns a reason to refuse, or $null when the drive-to-drive copy can go ahead.
function Get-CloneBlockReason([int]$SrcNumber, [int]$DstNumber) {
    $a = Get-Disk -Number $SrcNumber -ErrorAction SilentlyContinue
    $b = Get-Disk -Number $DstNumber -ErrorAction SilentlyContinue
    if (-not $a -or -not $b) { return 'A chosen drive is no longer there.' }
    if ($SrcNumber -eq $DstNumber) { return 'Choose two different drives.' }
    if ($b.IsBoot -or $b.IsSystem) { return 'Windows is running from the drive you chose to copy onto, so it cannot be overwritten from inside Windows.' }
    if ($b.Size -lt $a.Size) {
        return ("The target is too small. The source is {0} and the target is {1}." -f (Format-ImgSize $a.Size), (Format-ImgSize $b.Size))
    }
    $null
}

# Returns a reason to refuse, or $null when the restore can go ahead.
function Get-RestoreBlockReason([int]$DiskNumber, [string]$ImageFile) {
    $d = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $d) { return 'That drive is no longer there.' }
    if ($d.IsBoot -or $d.IsSystem) {
        return 'Windows is running from this drive, so it cannot be overwritten from inside Windows. Restore it from the rescue USB instead.'
    }
    if (-not (Test-Path -LiteralPath $ImageFile -PathType Leaf)) { return 'Choose the image file to restore.' }
    try { $need = [DRImgJob]::ReadHeader($ImageFile) } catch { return $_.Exception.Message }
    if ($d.Size -lt $need) {
        return ("This drive is too small. The image needs {0} and the drive is {1}." -f (Format-ImgSize $need), (Format-ImgSize $d.Size))
    }
    $root = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $ImageFile).Path)
    if ($root -and (Get-DiskLetters $DiskNumber) -contains $root.Substring(0, 1)) {
        return 'The image file is stored on the drive you are restoring to. Copy it to another drive first.'
    }
    $null
}

# Wipes the partition table of a non-Windows drive so raw writes are not blocked by mounted volumes.
function Initialize-RestoreTarget([int]$DiskNumber) {
    $d = Get-Disk -Number $DiskNumber
    if ($d.IsBoot -or $d.IsSystem) { throw 'Refusing to wipe the Windows drive.' }
    if ($d.IsOffline) { Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop }
    if ($d.IsReadOnly) { Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction Stop }
    if ($d.PartitionStyle -ne 'RAW') {
        Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    }
}

function Complete-RestoreTarget([int]$DiskNumber) {
    try { Update-Disk -Number $DiskNumber -ErrorAction Stop } catch { }
    try { Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop } catch { }
    Start-Sleep -Seconds 2
    # The hibernation file is left out of images, so blank its header: Windows then starts normally instead of trying to resume.
    foreach ($p in (Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)) {
        $vol = $p.AccessPaths | Where-Object { $_ -match '^\\\\\?\\Volume\{' } | Select-Object -First 1
        if ($vol) { try { [void][DRImgJob]::ZeroFileHead($vol.TrimEnd('\'), 'hiberfil.sys') } catch { } }
    }
}

# ---------- Rescue stick locks: stick serial number and owner (master) password ----------
function Get-StickSerialHash([string]$DriveLetter) {
    # SHA-256 of the USB stick's own serial number; empty when the stick does not report one.
    try {
        $part = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
        $s = ([string]$disk.SerialNumber).Trim()
        if (-not $s) { return '' }
        return (([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s.ToLowerInvariant())) | ForEach-Object { $_.ToString('X2') }) -join '')
    } catch { return '' }
}

function Test-StickSerial([string]$DriveLetter, [string]$UsbIdFile) {
    # False only when the stick is clearly a copy: it reports a serial and that serial is not the one recorded when it was made.
    if (-not (Test-Path -LiteralPath $UsbIdFile)) { return $true }
    $want = ([string](Get-Content -LiteralPath $UsbIdFile -ErrorAction SilentlyContinue | Select-Object -First 1)).Trim().ToUpperInvariant()
    if (-not $want) { return $true }
    $have = Get-StickSerialHash $DriveLetter
    if (-not $have) { return $true }
    return ($have.ToUpperInvariant() -eq $want)
}

function New-OwnerRecord([string]$Password) {
    $salt = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt); $rng.Dispose()
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000)
    $hash = $kdf.GetBytes(32); $kdf.Dispose()
    return ((($salt | ForEach-Object { $_.ToString('X2') }) -join '') + ':' + (($hash | ForEach-Object { $_.ToString('X2') }) -join ''))
}

function Test-OwnerRecord([string]$Password, [string]$Record) {
    try {
        $parts = $Record.Trim().Split(':')
        if ($parts.Count -ne 2) { return $false }
        $salt = New-Object byte[] 16
        for ($i = 0; $i -lt 16; $i++) { $salt[$i] = [Convert]::ToByte($parts[0].Substring($i * 2, 2), 16) }
        $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000)
        $hash = $kdf.GetBytes(32); $kdf.Dispose()
        $mine = (($hash | ForEach-Object { $_.ToString('X2') }) -join '')
        return ($mine -eq $parts[1].ToUpperInvariant())
    } catch { return $false }
}
