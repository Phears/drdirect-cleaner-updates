<#
    DRDirect Duplicate Finder
    ---------------------------------------------------------------
    Finds files that are 100% identical - same size, same SHA-256,
    and verified byte-for-byte - then keeps one copy of each set and
    sends the rest to the Recycle Bin.

    Nothing is deleted permanently. Nothing is removed unless you
    press the button.

    Run:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "DRDirect Duplicate Finder.ps1"
#>

[CmdletBinding()]
param(
    [string]$StartFolder,
    [switch]$TestMode,
    [switch]$ScanOnly,
    [switch]$NoShow,
    # Passed by the Cleaner when the copy is on a free try, so this window does
    # not have to work it out for itself and cannot silently get it wrong.
    [switch]$TrialMode,
    # Passed by the Cleaner. Its administrator path opens this window through
    # Explorer, which drops the launcher's hand-off, so this says who opened it.
    [switch]$FromCleaner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Only one window of this program at a time. A second click (or a double
# click that starts it twice) brings the open window forward and quits.
function Enter-DRSingleWindow {
    param([string]$MutexName, [string]$Title, [switch]$CheckOnly)
    $taken = $false
    try {
        if ($CheckOnly) {
            $existing = $null
            try { $taken = [Threading.Mutex]::TryOpenExisting($MutexName, [ref]$existing); if ($existing) { $existing.Dispose() } }
            catch [UnauthorizedAccessException] { $taken = $true }
        } else {
            $created = $false
            $script:DRSingleWindowMutex = New-Object Threading.Mutex($true, $MutexName, [ref]$created)
            $taken = -not $created
        }
    } catch { return }
    if (-not $taken) { return }
    try {
        if (-not ('DRSingleWindow' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class DRSingleWindow {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr w, int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr w);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr w);
}
'@
        }
        # The first copy may still be starting; give its window a few seconds.
        for ($i = 0; $i -lt 20; $i++) {
            $open = Get-Process -Name 'powershell', 'DRDirect*' -ErrorAction SilentlyContinue |
                Where-Object { $_.Id -ne $PID -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -eq $Title } |
                Select-Object -First 1
            if ($open) {
                if ([DRSingleWindow]::IsIconic($open.MainWindowHandle)) { [void][DRSingleWindow]::ShowWindow($open.MainWindowHandle, 9) }
                [void][DRSingleWindow]::SetForegroundWindow($open.MainWindowHandle)
                break
            }
            Start-Sleep -Milliseconds 250
        }
    } catch { }
    exit 0
}
if (-not $NoShow -and -not $ScanOnly) { Enter-DRSingleWindow -MutexName 'Global\DRDirectDuplicateFinderWindow' -Title 'DRDirect Duplicate Finder' }

# The updater is a shared file rather than a copy of the same code, so the
# Cleaner and this window always agree on what counts as a newer version.
# Declared before the updater arrives, inlined or from disk, because it decides
# which activation state file this product reads and writes.
$script:DRProduct = 'Duplicate Finder'
# <UPDATER-IMPORT>
# Replaced at build time with the contents of DRDirect Updater.ps1. Loading it
# from disk needed a path that ps2exe does not provide, so it is compiled in.
$script:DRUpdaterLoaded = $false
foreach ($updaterRoot in @($PSScriptRoot, (Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Scripts'))) {
    if ([string]::IsNullOrWhiteSpace($updaterRoot)) { continue }
    $updaterPath = Join-Path $updaterRoot 'DRDirect Updater.ps1'
    if (Test-Path -LiteralPath $updaterPath -PathType Leaf) {
        try { . $updaterPath; $script:DRUpdaterLoaded = $true; break } catch { }
    }
}
# </UPDATER-IMPORT>

# <LOCK-CONFIG>
# Replaced at build time with the PC IDs this copy is for. Left empty here so
# the script still runs from source while you are working on it.
$script:DRAllowedPcIds = @()
$script:DRIsTrialBuild = $false
# </LOCK-CONFIG>

# When this script is run from disk by the launcher rather than from inside the
# compiled exe, the block above is the unlocked source copy and says nothing.
# The launcher passes what it verified, so a free-try build stays a free-try
# build after an update instead of quietly becoming a full one.
if (-not $script:DRAllowedPcIds -or $script:DRAllowedPcIds.Count -eq 0) {
    $handedIds = [Environment]::GetEnvironmentVariable('DRDIRECT_ALLOWED_PC_IDS')
    if ($handedIds) {
        $script:DRAllowedPcIds = @($handedIds -split ',' |
            ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
        $script:DRIsTrialBuild =
            ([Environment]::GetEnvironmentVariable('DRDIRECT_TRIAL_BUILD') -eq '1')
    }
}

# This script is published in the public update feed, so a downloaded copy would
# otherwise open as the full Finder with no licence check at all. Only start
# when DRDirect opened it: the compiled exe, a launcher, the Cleaner, test mode,
# or the project folder the licence secret lives in.
$drStartedByDRDirect = [bool]($TestMode -or $FromCleaner -or $script:DRAllowedPcIds.Count -gt 0)
if (-not $drStartedByDRDirect) {
    $drHostName = ''
    try { $drHostName = [Diagnostics.Process]::GetCurrentProcess().ProcessName } catch { }
    $drStartedByDRDirect = @('powershell', 'pwsh', 'powershell_ise') -notcontains $drHostName.ToLowerInvariant()
}
if (-not $drStartedByDRDirect -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $drStartedByDRDirect = Test-Path -LiteralPath (Join-Path $PSScriptRoot 'licence_secret_finder.txt') -PathType Leaf
}
# An update lands here while the older Cleaner is still open, and that Cleaner
# opens this copy without saying who it is until it has been closed and reopened.
if (-not $drStartedByDRDirect -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot) -and
        -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $drUpdateFolder = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Scripts'
    $drStartedByDRDirect = [string]::Equals(
        [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\'),
        [IO.Path]::GetFullPath($drUpdateFolder).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase)
}
if (-not $drStartedByDRDirect) {
    $drRefusal = "This file is part of DRDirect Duplicate Finder and cannot be opened on its own." + [Environment]::NewLine + [Environment]::NewLine +
        "Open it from its shortcut, or from the DRDirect PC Cleaner. Don't have it? Contact DRDirect."
    if ($NoShow -or $ScanOnly) {
        Write-Error $drRefusal -ErrorAction Continue
    } else {
        try {
            Add-Type -AssemblyName PresentationFramework
            [Windows.MessageBox]::Show($drRefusal, 'DRDirect Duplicate Finder', 'OK', 'Information') | Out-Null
        } catch { Write-Error $drRefusal -ErrorAction Continue }
    }
    exit 2
}

function Get-DRPcIds {
    # Same identifiers the Cleaner's launcher checks.
    $ids = New-Object System.Collections.Generic.List[string]
    try {
        $uuid = [string](Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).UUID
        $serial = [string](Get-CimInstance Win32_BaseBoard -ErrorAction Stop).SerialNumber
        if ($uuid)   { $ids.Add($uuid.Trim().ToLowerInvariant()) }
        if ($serial) { $ids.Add($serial.Trim().ToLowerInvariant()) }
        if ($uuid -and $serial) {
            $ids.Add(("{0}-{1}" -f $uuid.Trim(), $serial.Trim()).ToLowerInvariant())
        }
    } catch { }
    return $ids
}

if ($script:DRAllowedPcIds.Count -gt 0) {
    $mine = Get-DRPcIds
    $allowed = $false
    foreach ($id in $mine) { if ($script:DRAllowedPcIds -contains $id) { $allowed = $true; break } }
    if (-not $allowed) {
        Add-Type -AssemblyName PresentationFramework
        [Windows.MessageBox]::Show(
            "This copy of the Duplicate Finder is not activated for this PC." + [Environment]::NewLine +
            [Environment]::NewLine + "Contact DRDirect for a copy for this machine.",
            'DRDirect Duplicate Finder', 'OK', 'Information') | Out-Null
        exit 2
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

$script:DRLangOff = [bool]($NoShow -or $ScanOnly); $script:DRLangShowErr = [bool]$TestMode

# ---------- French / English ----------
# Every text on screen keeps its English original; DRDirect.Lang shows it in the chosen language and can switch back
# and forth at any time (the button at the top right of the Dashboard). The choice is kept in the registry; before
# anyone has chosen, the Cleaner follows the Windows language. Messages (MessageBox) go through DRDirect.MsgBox.
$script:DRMsgBoxCode = @'
using System;
using System.Windows;
namespace DRDirect
{
    // MessageBox.Show with the text and title in the chosen language (Tr is set by the language part; English when it is not).
    public static class MsgBox
    {
        public static Func<string, string> Tr;
        static string T(string s) { Func<string, string> f = Tr; if (f == null || s == null) return s; try { return f(s); } catch { return s; } }
        public static MessageBoxResult Show(string text) { return MessageBox.Show(T(text)); }
        public static MessageBoxResult Show(string text, string title) { return MessageBox.Show(T(text), T(title)); }
        public static MessageBoxResult Show(string text, string title, MessageBoxButton b) { return MessageBox.Show(T(text), T(title), b); }
        public static MessageBoxResult Show(string text, string title, MessageBoxButton b, MessageBoxImage i) { return MessageBox.Show(T(text), T(title), b, i); }
        public static MessageBoxResult Show(string text, string title, MessageBoxButton b, MessageBoxImage i, MessageBoxResult r) { return MessageBox.Show(T(text), T(title), b, i, r); }
        public static MessageBoxResult Show(Window owner, string text) { return owner == null ? MessageBox.Show(T(text)) : MessageBox.Show(owner, T(text)); }
        public static MessageBoxResult Show(Window owner, string text, string title) { return owner == null ? MessageBox.Show(T(text), T(title)) : MessageBox.Show(owner, T(text), T(title)); }
        public static MessageBoxResult Show(Window owner, string text, string title, MessageBoxButton b) { return owner == null ? MessageBox.Show(T(text), T(title), b) : MessageBox.Show(owner, T(text), T(title), b); }
        public static MessageBoxResult Show(Window owner, string text, string title, MessageBoxButton b, MessageBoxImage i) { return owner == null ? MessageBox.Show(T(text), T(title), b, i) : MessageBox.Show(owner, T(text), T(title), b, i); }
        public static MessageBoxResult Show(Window owner, string text, string title, MessageBoxButton b, MessageBoxImage i, MessageBoxResult r) { return owner == null ? MessageBox.Show(T(text), T(title), b, i, r) : MessageBox.Show(owner, T(text), T(title), b, i, r); }
    }
}

'@
$script:DRLangCode = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Threading;

namespace DRDirect
{
    // French / English for the whole Cleaner. Every text keeps its English original; what is shown is the
    // French (or English) of it, so the language can be changed back and forth at any time.
    public static class Lang
    {
        public static bool French;
        static readonly Dictionary<string, string> exact = new Dictionary<string, string>(StringComparer.Ordinal);
        static readonly Dictionary<string, string> exactLoose = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        static readonly List<Pat> pats = new List<Pat>();
        static readonly List<KeyValuePair<string, string>> frags = new List<KeyValuePair<string, string>>();
        static readonly Dictionary<string, string> cache = new Dictionary<string, string>(StringComparer.Ordinal);
        static readonly object gate = new object();
        static bool fragsSorted;

        class Pat { public Regex Re; public string Fr; public int N; public string Lead; }

        // data: one "English<TAB>French" pair per line; \n inside a text is written as the two characters \n.
        // {0} {1} ... in the English mark parts that change (numbers, names); the French puts them where they belong.
        public static void Load(string data)
        {
            if (string.IsNullOrEmpty(data)) return;
            foreach (string raw in data.Split('\n'))
            {
                string line = raw.TrimEnd('\r');
                if (line.Length == 0 || line.StartsWith("#")) continue;
                int t = line.IndexOf('\t');
                if (t <= 0 || t == line.Length - 1) continue;
                Add(line.Substring(0, t).Replace("\\n", "\n"), line.Substring(t + 1).Replace("\\n", "\n"));
            }
        }

        static readonly Regex holder = new Regex(@"\{(\d)\}");
        static readonly Regex hasWords = new Regex("[A-Za-z]{2}");
        // sizes in French: Ko, Mo, Go, To
        static readonly Regex units = new Regex(@"(\d\s?|\d\u00A0)(KB|MB|GB|TB|bytes)\b");
        static string UnitFr(string u) { switch (u) { case "KB": return "Ko"; case "MB": return "Mo"; case "GB": return "Go"; case "TB": return "To"; default: return "octets"; } }

        public static void Add(string en, string fr)
        {
            lock (gate)
            {
                cache.Clear();
                en = en.Trim(); fr = fr.Trim();
                if (en.Length == 0) return;
                if (holder.IsMatch(en))
                {
                    StringBuilder sb = new StringBuilder("^");
                    int at = 0, n = 0;
                    foreach (Match m in holder.Matches(en))
                    {
                        sb.Append(Regex.Escape(en.Substring(at, m.Index - at)));
                        sb.Append("(?<p" + m.Groups[1].Value + ">.*?)");
                        at = m.Index + m.Length; n++;
                    }
                    sb.Append(Regex.Escape(en.Substring(at))).Append("$");
                    int lit = holder.Replace(en, "").Trim().Length;
                    if (lit < 3) return;   // a pattern that is nearly all blanks would match anything
                    Pat p = new Pat();
                    p.Re = new Regex(sb.ToString(), RegexOptions.Singleline | RegexOptions.CultureInvariant);
                    p.Fr = fr; p.N = n;
                    Match lead = holder.Match(en);
                    p.Lead = lead.Index > 0 ? en.Substring(0, Math.Min(lead.Index, 6)) : null;
                    pats.Add(p);
                }
                else
                {
                    exact[en] = fr;
                    exactLoose[en] = fr;
                    if (en.Length >= 12 && en.IndexOf('\n') < 0) { frags.Add(new KeyValuePair<string, string>(en, fr)); fragsSorted = false; }
                }
            }
        }

        // The text to show for an English text (the text itself when English is chosen or nothing matches).
        public static string T(string s)
        {
            if (!French || string.IsNullOrEmpty(s)) return s;
            if (!hasWords.IsMatch(s)) return s;   // numbers, sizes, times: nothing to translate
            lock (gate)
            {
                string r;
                if (cache.TryGetValue(s, out r)) return r;
                r = Translate(s, 0);
                r = units.Replace(r, delegate (Match m) { return m.Groups[1].Value + UnitFr(m.Groups[2].Value); });
                if (cache.Count > 20000) cache.Clear();
                cache[s] = r;
                return r;
            }
        }

        static string Translate(string s, int depth)
        {
            string r;
            if (Whole(s, depth, out r)) return r;
            if (s.IndexOf('\n') >= 0)
            {
                string[] lines = s.Split('\n');
                bool any = false;
                for (int i = 0; i < lines.Length; i++)
                {
                    string ln = lines[i]; bool cr = ln.EndsWith("\r"); if (cr) ln = ln.Substring(0, ln.Length - 1);
                    string tr;
                    if (Whole(ln, depth, out tr) || Frag(ln, out tr)) { lines[i] = tr + (cr ? "\r" : ""); any = true; }
                }
                if (any) return string.Join("\n", lines);
                return s;
            }
            if (Frag(s, out r)) return r;
            return s;
        }

        static bool Whole(string s, int depth, out string r)
        {
            r = s;
            string core = s.Trim();
            if (core.Length == 0) return false;
            int li = s.IndexOf(core, StringComparison.Ordinal);
            string lead = s.Substring(0, li), trail = s.Substring(li + core.Length);
            string fr;
            if (exact.TryGetValue(core, out fr)) { r = lead + fr + trail; return true; }
            if (exactLoose.TryGetValue(core, out fr))
            {
                // the same words in capitals (titles, buttons): the French in capitals too
                if (core == core.ToUpperInvariant() && Regex.IsMatch(core, "[A-Z]")) fr = fr.ToUpper(CultureInfo.GetCultureInfo("fr-CA"));
                r = lead + fr + trail; return true;
            }
            // a text ending in ... or : or . that is otherwise known
            foreach (string end in new string[] { "...", ":", ".", "?", "!" })
            {
                if (core.Length > end.Length + 2 && core.EndsWith(end) && exact.TryGetValue(core.Substring(0, core.Length - end.Length).TrimEnd(), out fr))
                { r = lead + fr + (fr.EndsWith(end) ? "" : (end == ":" || end == "?" || end == "!" ? " " + end : end)) + trail; return true; }
            }
            if (depth > 2) return false;
            foreach (Pat p in pats)
            {
                if (p.Lead != null && !core.StartsWith(p.Lead, StringComparison.Ordinal)) continue;
                Match m = p.Re.Match(core);
                if (!m.Success) continue;
                string o = p.Fr;
                for (int g = 0; g < 10; g++)
                {
                    Group gr = m.Groups["p" + g];
                    if (!gr.Success) continue;
                    string v = gr.Value, tv;
                    if (v.Length > 0 && Regex.IsMatch(v, "[A-Za-z]{2}")) { tv = Translate(v, depth + 1); } else tv = v;
                    o = o.Replace("{" + g + "}", tv);
                }
                r = lead + o + trail; return true;
            }
            return false;
        }

        // Known sentences inside a longer text (texts put together from pieces).
        static bool Frag(string s, out string r)
        {
            r = s;
            if (s.Length < 12) return false;
            if (s.IndexOf(":\\", StringComparison.Ordinal) >= 0 || s.IndexOf("\\", StringComparison.Ordinal) >= 0) return false;   // a file or folder path stays as it is
            if (!fragsSorted) { frags.Sort(delegate (KeyValuePair<string, string> a, KeyValuePair<string, string> b) { return b.Key.Length.CompareTo(a.Key.Length); }); fragsSorted = true; }
            string o = s; bool any = false;
            foreach (KeyValuePair<string, string> kv in frags)
            {
                if (kv.Key.Length > o.Length) continue;
                if (o.IndexOf(kv.Key, StringComparison.Ordinal) >= 0) { o = o.Replace(kv.Key, kv.Value); any = true; }
            }
            r = o; return any;
        }

        // ---------------- on screen ----------------
        class Rec { public string Orig; public string Shown; }
        static readonly ConditionalWeakTable<DependencyObject, Dictionary<DependencyProperty, Rec>> recs = new ConditionalWeakTable<DependencyObject, Dictionary<DependencyProperty, Rec>>();
        static readonly List<KeyValuePair<WeakReference, DependencyProperty>> live = new List<KeyValuePair<WeakReference, DependencyProperty>>();
        static bool hooked;
        public static event EventHandler Changed;

        public static void Hook()
        {
            if (hooked) return;
            hooked = true;
            // Loaded only reaches elements that have their own Loaded handler, so the first layout (SizeChanged, which
            // every element gets when it is first shown) is used to find each text; Loaded is kept for the rest.
            EventManager.RegisterClassHandler(typeof(FrameworkElement), FrameworkElement.SizeChangedEvent, new SizeChangedEventHandler(OnSized), true);
            EventManager.RegisterClassHandler(typeof(FrameworkElement), FrameworkElement.LoadedEvent, new RoutedEventHandler(OnLoaded), true);
            EventManager.RegisterClassHandler(typeof(ToolTip), ToolTip.OpenedEvent, new RoutedEventHandler(OnLoaded), true);
        }

        static void OnLoaded(object sender, RoutedEventArgs e)
        {
            try { Visit(sender as DependencyObject); } catch { }
        }

        static void OnSized(object sender, SizeChangedEventArgs e)
        {
            try { Visit(sender as DependencyObject); } catch { }
        }

        // Every text inside an element that is already on screen (used once for each window, as a safety net).
        public static void VisitTree(DependencyObject root)
        {
            if (root == null) return;
            try
            {
                Visit(root);
                int n = System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);
                for (int i = 0; i < n; i++) VisitTree(System.Windows.Media.VisualTreeHelper.GetChild(root, i));
            }
            catch { }
        }

        static void Visit(DependencyObject d)
        {
            if (d == null) return;
            TextBlock tb = d as TextBlock;
            if (tb != null)
            {
                // A text shown from a button's or list's own text (bound): change what is shown.
                if (System.Windows.Data.BindingOperations.IsDataBound(tb, TextBlock.TextProperty)) { Watch(tb, TextBlock.TextProperty); return; }
                // Otherwise the words live in the TextBlock's pieces (Runs), even a plain Text="..." has one.
                // Only the pieces are changed, so coloured parts keep their colours. When the program puts new
                // text in, the TextBlock's text changes and its new pieces are picked up here again.
                HookTextBlock(tb);
                VisitInlines(tb);
                return;
            }
            Dictionary<DependencyProperty, Rec> seen;
            if (recs.TryGetValue(d, out seen) && seen.Count > 0) return;
            TextBox tx = d as TextBox;
            if (tx != null) { if (tx.IsReadOnly) Watch(tx, TextBox.TextProperty); return; }
            Window w = d as Window;
            if (w != null) { Watch(w, Window.TitleProperty); return; }
            FrameworkElement fe = d as FrameworkElement;
            if (fe != null && fe.ToolTip is string) Watch(fe, FrameworkElement.ToolTipProperty);
        }

        static readonly ConditionalWeakTable<TextBlock, object> tbHooked = new ConditionalWeakTable<TextBlock, object>();
        static ConditionalWeakTable<TextBlock, object> tbPending = new ConditionalWeakTable<TextBlock, object>();
        static void HookTextBlock(TextBlock tb)
        {
            object o;
            if (tbHooked.TryGetValue(tb, out o)) return;
            tbHooked.Add(tb, new object());
            DependencyPropertyDescriptor dpd = DependencyPropertyDescriptor.FromProperty(TextBlock.TextProperty, typeof(TextBlock));
            if (dpd != null) dpd.AddValueChanged(tb, delegate (object s, EventArgs a)
            {
                if (applying) return;
                // The program may be in the middle of adding pieces (Inlines.Clear / Add): changing a piece now can break
                // its next Add. So the new pieces are translated just after, before the screen is drawn.
                object pend;
                if (tbPending.TryGetValue(tb, out pend)) return;
                tbPending.Add(tb, new object());
                try
                {
                    tb.Dispatcher.BeginInvoke(DispatcherPriority.Normal, new Action(delegate ()
                    {
                        tbPending.Remove(tb);
                        try { VisitInlines(tb); } catch { }
                    }));
                }
                catch { tbPending.Remove(tb); }
            });
        }

        static void VisitInlines(TextBlock tb)
        {
            List<Inline> list = new List<Inline>();
            foreach (Inline il in tb.Inlines) list.Add(il);
            foreach (Inline il in list) VisitInline(il);
        }

        static void VisitInline(Inline il)
        {
            Run r = il as Run;
            if (r != null) { Watch(r, Run.TextProperty); return; }
            Span sp = il as Span;
            if (sp != null) foreach (Inline c in sp.Inlines) VisitInline(c);
        }

        static void Watch(DependencyObject d, DependencyProperty dp)
        {
            Dictionary<DependencyProperty, Rec> map = recs.GetOrCreateValue(d);
            if (!map.ContainsKey(dp))
            {
                map[dp] = null;
                DependencyPropertyDescriptor dpd = DependencyPropertyDescriptor.FromProperty(dp, d.GetType());
                if (dpd != null) dpd.AddValueChanged(d, delegate (object s, EventArgs a) { try { Apply(d, dp); } catch { } });
                lock (live) { live.Add(new KeyValuePair<WeakReference, DependencyProperty>(new WeakReference(d), dp)); }
            }
            Apply(d, dp);
        }

        // While a text is being changed, the change it causes (the TextBlock noticing its piece changed) is ignored,
        // so it can never loop.
        [ThreadStatic] static bool applying;

        static void Apply(DependencyObject d, DependencyProperty dp)
        {
            if (applying) return;
            applying = true;
            try { ApplyNow(d, dp); } finally { applying = false; }
        }

        static void ApplyNow(DependencyObject d, DependencyProperty dp)
        {
            string cur = d.GetValue(dp) as string;
            if (cur == null) return;
            Dictionary<DependencyProperty, Rec> map = recs.GetOrCreateValue(d);
            Rec rec; map.TryGetValue(dp, out rec);
            string orig = (rec != null && cur == rec.Shown) ? rec.Orig : cur;
            string want = French ? T(orig) : orig;
            if (rec == null) { rec = new Rec(); map[dp] = rec; }
            rec.Orig = orig; rec.Shown = want;
            if (!string.Equals(want, cur, StringComparison.Ordinal)) d.SetCurrentValue(dp, want);
        }

        // Change the language now: every text already on screen follows at once.
        public static void Set(bool french)
        {
            French = french;
            lock (gate) { cache.Clear(); }
            List<KeyValuePair<WeakReference, DependencyProperty>> copy;
            lock (live) { live.RemoveAll(delegate (KeyValuePair<WeakReference, DependencyProperty> k) { return !k.Key.IsAlive; }); copy = new List<KeyValuePair<WeakReference, DependencyProperty>>(live); }
            foreach (KeyValuePair<WeakReference, DependencyProperty> k in copy)
            {
                DependencyObject d = k.Key.Target as DependencyObject;
                if (d == null) continue;
                try { if (d.CheckAccess()) Apply(d, k.Value); else d.Dispatcher.BeginInvoke(new Action(delegate () { try { Apply(d, k.Value); } catch { } })); } catch { }
            }
            EventHandler h = Changed; if (h != null) h(null, EventArgs.Empty);
        }
    }
}

'@
$script:DRLangData = @'
"DRDirect Clone & Backup is done. Your PC will {0} in 60 seconds."	« DRDirect Copie et sauvegarde a terminé. Votre PC va {0} dans 60 secondes. »
"Turn everything back on" is also picked, so it runs last and undoes the AI settings you turned off. Pick one or the other.	« Tout réactiver » est aussi coché : il passe en dernier et annule les réglages d’IA que vous avez désactivés. Choisissez l’un ou l’autre.
'Show available updates' only lists what is out of date. 'Update all apps' runs winget upgrade --all after you confirm. Progress is shown in a console window.	« Voir les mises à jour disponibles » liste seulement ce qui n’est pas à jour. « Mettre à jour toutes les applis » lance winget upgrade --all après votre confirmation. La progression s’affiche dans une fenêtre de console.
'{0}' did not match its published checksum and was discarded.	« {0} » ne correspondait pas à sa somme de contrôle publiée et a été rejeté.
(3 choices)	(3 choix)
(Test mode: nothing is read or written. This only shows the animation.)	(Mode test : rien n’est lu ni écrit. Seule l’animation est montrée.)
(becomes the Rescue USB)	(devient la clé USB de secours)
(every block is tested)	(chaque bloc est vérifié)
(from the Rescue USB {0})	(depuis la clé USB de secours {0})
(gets the copy)	(reçoit la copie)
(gets the image back)	(reçoit la sauvegarde)
(made first on this PC, from Microsoft's downloads)	(créé d’abord sur ce PC, à partir des téléchargements de Microsoft)
(one file, opens only on this PC)	(un seul fichier, s’ouvre seulement sur ce PC)
(only read, nothing changes)	(lecture seulement, rien ne change)
(starts this PC without Windows)	(démarre ce PC sans Windows)
(the dock or case hides it)	(la station d’accueil ou le boîtier le cache)
(what you saved before)	(ce que vous avez sauvegardé avant)
(you choose)	(vous choisissez)
, {0} could not be erased	, {0} n’ont pas pu être effacés
-  Do not unplug the USB stick or turn off the PC while it is being made.	-  Ne débranchez pas la clé USB et n’éteignez pas le PC pendant sa création.
-  Only USB sticks are offered. Your Windows drive and other drives inside the PC are never touched.	-  Seules les clés USB sont proposées. Votre disque Windows et les autres disques du PC ne sont jamais touchés.
-  Use an empty USB stick, or copy anything you want to keep off it first.	-  Utilisez une clé USB vide, ou copiez d’abord ailleurs ce que vous voulez garder.
-  Windows drive	-  disque Windows
-  {0} could not be removed (in use or protected)	-  {0} n’a pas pu être retiré (en cours d’utilisation ou protégé)
-  {0} skipped as Windows or program files	-  {0} ignoré(s) : fichiers de Windows ou de programmes
- In bad cases Windows may have trouble starting.	- Dans les pires cas, Windows peut avoir du mal à démarrer.
- No description was published for this version.	- Aucune description n’a été publiée pour cette version.
- The PC gets slower, and programs can freeze or crash.	- Le PC ralentit, et les programmes peuvent figer ou planter.
- The program: {0}	- Le programme : {0}
- Windows updates can fail to install, so the PC misses security fixes.	- Les mises à jour de Windows peuvent échouer, et le PC manque des correctifs de sécurité.
- YOU COULD LOSE DATA: files you are saving can fail to save or be damaged, and a crash while the drive is full can lose work you have not saved.	- VOUS POURRIEZ PERDRE DES DONNÉES : les fichiers en cours d’enregistrement peuvent ne pas s’enregistrer ou être endommagés, et un plantage quand le disque est plein peut faire perdre le travail non enregistré.
- now on	- maintenant activé
... (output truncated)	... (sortie tronquée)
...and {0} more	...et {0} de plus
0 bytes	0 octet
0 selected	0 sélectionné
1 day	1 jour
1 day left	1 jour restant
1 days ago	il y a 1 jour
1 hour	1 heure
1 min to start	1 min pour démarrer
1 thing needs attention	1 chose demande votre attention
1.  Performance Monitor  -  live line graphs	1.  Analyseur de performances  -  graphiques en direct
1.  Pick the USB stick	1.  Choisissez la clé USB
1.  Pick the backup file	1.  Choisissez le fichier de sauvegarde
1.  Pick the backup file to check	1.  Choisissez le fichier de sauvegarde à vérifier
1.  Pick the drive to copy	1.  Choisissez le disque à copier
1.  Pick the drive to save	1.  Choisissez le disque à sauvegarder
1. Accept Microsoft's licence terms.	1. Acceptez les termes de licence de Microsoft.
100 KB (recommended)	100 Ko (recommandé)
14 days left	14 jours restants
1st window	1re fenêtre
2.  Pick the drive that gets the copy	2.  Choisissez le disque qui reçoit la copie
2.  Pick the drive to put it back on	2.  Choisissez le disque où la remettre
2.  Resource Monitor  -  what is slowing the PC down	2.  Moniteur de ressources  -  ce qui ralentit le PC
2.  Where the backup goes (picked for you - Browse only to change it)	2.  Où va la sauvegarde (choisi pour vous - Parcourir seulement pour le changer)
2.  Yes, make the Rescue USB on {0}	2.  Oui, créer la clé USB de secours sur {0}
2.  Yes, make the Rescue system, erase and format {0} and make the Rescue USB	2.  Oui, créer le système de secours, effacer et formater {0} et créer la clé USB de secours
2. Choose USB flash drive.	2. Choisissez « Disque mémoire flash USB ».
2nd window	2e fenêtre
3.  Reliability Monitor  -  day-by-day crash chart	3.  Moniteur de fiabilité  -  graphique des plantages jour par jour
3.  Yes, put it back on {0}	3.  Oui, la remettre sur {0}
3.  Yes, put the copy on {0}	3.  Oui, mettre la copie sur {0}
3. Pick your USB stick.	3. Choisissez votre clé USB.
3D look	Effet 3D
4.  Health report  -  60-second check, warnings at the top	4.  Rapport de santé  -  vérification de 60 secondes, avertissements en haut
5.  Reset Reliability Monitor...	5.  Réinitialiser le Moniteur de fiabilité...
A MUCH DEEPER, BETTER CLEANING. It reduces how much companies and websites can track and check up on what you do on this PC.	UN NETTOYAGE BEAUCOUP PLUS PROFOND ET MEILLEUR. Il réduit ce que les entreprises et les sites Web peuvent suivre et surveiller de ce que vous faites sur ce PC.
A PHP program on this PC has a known security gap that has a free fix.	Un programme PHP sur ce PC a une faille de sécurité connue, avec un correctif gratuit.
A Windows restore point is saved first when possible, and the Cleaner keeps backups of the settings it changes. Your files, passwords and logins are not touched.	Un point de restauration Windows est créé d’abord quand c’est possible, et le Cleaner garde une copie des réglages qu’il change. Vos fichiers, mots de passe et connexions ne sont pas touchés.
A Windows restore point was saved before any change.	Un point de restauration Windows a été créé avant tout changement.
A chosen drive is no longer there.	Un disque choisi n’est plus là.
A deep drive test is a long test. Windows keeps running, but the PC may feel slower. Only tick it if you are ready to wait.	Un test approfondi du disque est long. Windows continue de fonctionner, mais le PC peut sembler plus lent. Cochez-le seulement si vous êtes prêt à attendre.
A drive reports a problem	Un disque signale un problème
A new version of DRDirect PC Cleaner is ready	Une nouvelle version de DRDirect Nettoyeur PC est prête
A partition does not fit on the target drive, so nothing was copied.	Une partition n’entre pas sur le disque cible, donc rien n’a été copié.
A partition would land on an uneven place on the target, so nothing was copied.	Une partition tomberait à un endroit mal aligné sur la cible, donc rien n’a été copié.
A proxy server is switched on: {0}. Normal at some workplaces, but spyware also uses this to watch your traffic.	Un serveur proxy est activé : {0}. C’est normal dans certains milieux de travail, mais les logiciels espions s’en servent aussi pour surveiller votre trafic.
A restart is a good idea.	Un redémarrage serait une bonne idée.
A restart is needed to finish. Click Restart now when you are ready. Windows will not restart by itself.	Un redémarrage est nécessaire pour terminer. Cliquez sur Redémarrer maintenant quand vous êtes prêt. Windows ne redémarrera pas tout seul.
A restart is waiting to finish installing updates.	Un redémarrage est en attente pour finir d’installer des mises à jour.
A restart is waiting to finish updates	Un redémarrage est en attente pour finir des mises à jour
A search is still running.	Une recherche est encore en cours.
A separate program. Contact DRDirect for a copy.	Un programme séparé. Contactez DRDirect pour en obtenir une copie.
AAC audio	Audio AAC
ADVANCED SCAN	ANALYSE AVANCÉE
AI is now off in Firefox. Close Firefox completely and open it again.	L’IA est maintenant désactivée dans Firefox. Fermez Firefox complètement et rouvrez-le.
AI is still on	L’IA est encore active
AI is turned off	L’IA est désactivée
AI model downloaded by {0}: {1}	Modèle d’IA téléchargé par {0} : {1}
AI models are still on this PC	Des modèles d’IA sont encore sur ce PC
AI settings are back to how they were for: {0}. Close and reopen those browsers. Removed apps come back with their own "Reinstall" button.	Les réglages d’IA sont revenus comme avant pour : {0}. Fermez et rouvrez ces navigateurs. Les applis retirées reviennent avec leur propre bouton « Réinstaller ».
AI websites are blocked	Les sites d’IA sont bloqués
AI websites are still open in	Les sites d’IA sont encore ouverts dans
AI websites in	Sites d’IA dans
AI websites: blocked in every browser	Sites d’IA : bloqués dans tous les navigateurs
AI websites: open in {0}	Sites d’IA : ouverts dans {0}
AIFF audio	Audio AIFF
ALAC audio	Audio ALAC
AND MORE!	ET PLUS ENCORE !
APE audio	Audio APE
ASF video	Vidéo ASF
ASKS FIRST	DEMANDE D’ABORD
AVI video	Vidéo AVI
About	À propos
About my PC	À propos de mon PC
About the DRDirect Uninstaller	À propos du désinstalleur DRDirect
About {0} to copy.{1}	Environ {0} à copier.{1}
Accept and install	Accepter et installer
Activate	Activer
Activated	Activé
Activated until {0}.	Activé jusqu’au {0}.
Activated. Close and reopen the Duplicate Finder.	Activé. Fermez puis rouvrez le Duplicate Finder.
Activated. Reopen the Duplicate Finder to use every category.	Activé. Rouvrez le Duplicate Finder pour utiliser toutes les catégories.
Activated. Restart the Cleaner to lift the limits.	Activé. Redémarrez le Cleaner pour lever les limites.
Activated. Restart the Cleaner to lift the trial limits.	Activé. Redémarrez le Cleaner pour lever les limites de l’essai.
Activation code	Code d’activation
Activation is not available in this copy.	L’activation n’est pas offerte dans cette copie.
Active	Actif
Adapter	Adaptateur
Add	Ajouter
Added: {0}	Ajouté : {0}
Adding Windows install or repair to the start-up menu...	Ajout de l’installation ou réparation de Windows au menu de démarrage...
Administrator	Administrateur
Administrator permission is required to restart Windows.	La permission d’administrateur est nécessaire pour redémarrer Windows.
Adobe Acrobat AI Assistant: {0}	Assistant IA d’Adobe Acrobat : {0}
Adobe Acrobat: turn AI Assistant back on	Adobe Acrobat : réactiver l’Assistant IA
Adobe Acrobat: turn off AI Assistant	Adobe Acrobat : désactiver l’Assistant IA
Advanced	Avancé
Advanced removal	Retrait avancé
Advanced removal of the ticked program	Retrait avancé du programme coché
Advanced removal...	Retrait avancé...
Advanced; Explorer restarts to rebuild it	Avancé ; l’Explorateur redémarre pour le refaire
Advanced; Windows rebuilds this cache	Avancé ; Windows refait ce cache
After the Recycle Bin is emptied, wipes the free space on SSD and NVMe drives so deleted files cannot be brought back, even with recovery programs. Files you still have are not touched. Hard drives are skipped.	Après le vidage de la Corbeille, nettoie l’espace libre des disques SSD et NVMe pour que les fichiers supprimés ne puissent pas être récupérés, même avec des programmes de récupération. Les fichiers que vous gardez ne sont pas touchés. Les disques durs sont ignorés.
Age in use: about {0} of running time ({1} hours).	Âge d’utilisation : environ {0} de fonctionnement ({1} heures).
Agree	D’accord
All	Tout
All Activated	Tout est activé
All Windows system files are fine. Nothing needed repairing.	Tous les fichiers système de Windows sont corrects. Rien n’avait besoin d’être réparé.
All checks finished. Nothing was changed. Click View results to choose what to clean.	Toutes les vérifications sont terminées. Rien n’a été changé. Cliquez sur Voir les résultats pour choisir quoi nettoyer.
All good. You can check again any time.	Tout va bien. Vous pouvez revérifier à tout moment.
All network components were reset successfully. One last step: please save your work and restart Windows. The new Winsock and TCP/IP settings only become active after a restart.	Tous les composants réseau ont été réinitialisés. Une dernière étape : enregistrez votre travail et redémarrez Windows. Les nouveaux réglages Winsock et TCP/IP ne s’appliquent qu’après un redémarrage.
All protection is on. Nothing was changed.	Toute la protection est active. Rien n’a été changé.
All users	Tous les utilisateurs
All {0} drive(s) are in great health	Les {0} disque(s) sont en très bonne santé
Allow the DRDirect Uninstaller through Controlled folder access?	Autoriser le désinstalleur DRDirect dans l’Accès contrôlé aux dossiers ?
Already installed.	Déjà installé.
Already off: the Claude website is blocked.	Déjà désactivé : le site Claude est bloqué.
Already on - the Cleaner has not turned it off on this PC.	Déjà activé - le Cleaner ne l’a pas désactivé sur ce PC.
Already on - the Cleaner has not turned it off.	Déjà activé - le Cleaner ne l’a pas désactivé.
Already removed from this PC.	Déjà retiré de ce PC.
Already uninstalled. Use Reinstall to put it back.	Déjà désinstallé. Utilisez Réinstaller pour le remettre.
Already-installed update installers	Installateurs de mises à jour déjà installées
Also delete my Duplicate Finder licence	Supprimer aussi ma licence du Duplicate Finder
Also delete my reports, licence and safe copies	Supprimer aussi mes rapports, ma licence et mes copies de sécurité
Also put {0} install or repair on this Rescue USB?	Mettre aussi l’installation ou la réparation de {0} sur cette clé USB de secours ?
Also scan drives	Analyser aussi les disques
Also: {0} install or repair, from {1}. Copying Windows takes a while.	Aussi : installation ou réparation de {0}, depuis {1}. La copie de Windows prend un moment.
An automatic proxy script is set: {0}	Un script de proxy automatique est défini : {0}
An error occurred	Une erreur s’est produite
Analysis complete	Analyse terminée
Analysis unavailable	Analyse non disponible
Analyzing this PC	Analyse de ce PC
Another Windows repair ({0}) was still running after {1} minutes, so System File Checker was not started. Restart the PC and run it again.	Une autre réparation Windows ({0}) tournait encore après {1} minutes, donc le Vérificateur des fichiers système n’a pas été lancé. Redémarrez le PC et relancez-le.
Another Windows repair ({0}) was still running after {1} minutes, so {2} was not started. Restart the PC and run it again.	Une autre réparation Windows ({0}) tournait encore après {1} minutes, donc {2} n’a pas été lancé. Redémarrez le PC et relancez-le.
Another free try: one cleanup run and one duplicate category.	Un autre essai gratuit : un nettoyage et une catégorie de doublons.
Any of the Windows firewall, Microsoft Defender real-time protection and Windows Update that is off will be switched back on.	Le pare-feu Windows, la protection en temps réel de Microsoft Defender et Windows Update seront réactivés s’ils sont désactivés.
Any size	Toute taille
App and PowerShell logs	Journaux des applis et de PowerShell
App caches	Caches des applis
App caches (Discord, Spotify, Slack, Teams, Steam)	Caches des applis (Discord, Spotify, Slack, Teams, Steam)
App is installed	L’appli est installée
App is removed	L’appli est retirée
Archives	Archives
Ask DRDirect for a new build.{0}	Demandez une nouvelle version à DRDirect.{0}
Asking Microsoft what drivers are available for this PC. This can take up to a minute.	Demande à Microsoft quels pilotes sont disponibles pour ce PC. Cela peut prendre jusqu’à une minute.
Asking Windows nicely to behave...	On demande gentiment à Windows de bien se tenir...
Asks Windows to release idle memory held by running programs, like PC Manager Boost. Nothing is closed and no data is lost; programs reload what they need.	Demande à Windows de libérer la mémoire inutilisée gardée par les programmes ouverts, comme le Boost de PC Manager. Rien n’est fermé et aucune donnée n’est perdue ; les programmes rechargent ce dont ils ont besoin.
At the same rate of use: very little wear so far, so many years left. Too early to give a closer figure.	Au même rythme d’utilisation : très peu d’usure jusqu’ici, donc de nombreuses années restantes. Trop tôt pour donner un chiffre plus précis.
At the same rate of use: {0}. This is only a rough guess.	Au même rythme d’utilisation : {0}. Ce n’est qu’une estimation approximative.
Attention	Attention
Audiobook	Livre audio
Auto	Auto
Automatic restart failed:	Le redémarrage automatique a échoué :
Available	Disponible
Average speed:   {0}/s	Vitesse moyenne :   {0}/s
BACKUP	SAUVEGARDE
BACKUP FILE	FICHIER DE SAUVEGARDE
BIOS version	Version du BIOS
Back	Retour
Back to simple view	Retour à la vue simple
Back to the Cleaner	Retour au Cleaner
Back to the top of the menu	Retour en haut du menu
Back to top	Retour en haut
Backup file	Fichier de sauvegarde
Backup file back onto a drive	Sauvegarde vers disque
Backup file saved:	Fichier de sauvegarde enregistré :
Battery	Pile
Battery health	Santé de la pile
Bitmap image	Image bitmap
Block AI websites	Bloquer les sites d’IA
Blocks the ChatGPT, Gemini, Copilot, Perplexity, DeepSeek, Grok and Meta AI websites in Edge, Chrome, Brave and Firefox. Claude is left open. Only browsers that are signed in are changed (Brave has no sign-in). The browsers will show "Managed by your organization" while this is on.	Bloque les sites ChatGPT, Gemini, Copilot, Perplexity, DeepSeek, Grok et Meta AI dans Edge, Chrome, Brave et Firefox. Claude reste ouvert. Seuls les navigateurs connectés sont changés (Brave n’a pas de connexion). Les navigateurs afficheront « Géré par votre organisation » tant que c’est actif.
Blocks the Claude website (claude.ai) in Edge, Chrome, Brave and Firefox. The Claude app stays installed and is never touched. Only browsers that are signed in are changed (Brave has no sign-in). Turn it back on any time.	Bloque le site de Claude (claude.ai) dans Edge, Chrome, Brave et Firefox. L’appli Claude reste installée et n’est jamais touchée. Seuls les navigateurs connectés sont changés (Brave n’a pas de connexion). Réactivez-le quand vous voulez.
Brave: turn Leo AI back on	Brave : réactiver Leo AI
Brave: turn off Leo AI	Brave : désactiver Leo AI
Brave: uninstall completely	Brave : désinstaller complètement
Broadcast video	Vidéo de diffusion
Broken programs only	Programmes brisés seulement
Browse	Parcourir
Browse for  ▾	Parcourir  ▾
Browse...	Parcourir...
Browser Assistant	Assistant de navigateur
Browser caches	Caches des navigateurs
Browser home page, search engine and forced extensions: nothing unusual.	Page d’accueil, moteur de recherche et extensions forcées des navigateurs : rien d’inhabituel.
Button error:	Erreur de bouton :
Byte-for-byte	Octet par octet
CAN BE UNDONE	PEUT ÊTRE ANNULÉ
CHECK IT	VÉRIFIER
CHKDSK could not complete the scan of C:. This usually means the volume is unavailable or the disk is failing. Check Event Viewer and the drive health before relying on this result.	CHKDSK n’a pas pu terminer l’analyse de C:. Cela veut souvent dire que le volume n’est pas disponible ou que le disque est en train de lâcher. Vérifiez l’Observateur d’événements et la santé du disque avant de vous fier à ce résultat.
CHKDSK disk check (deep drive test)	Vérification CHKDSK (test approfondi du disque)
CHKDSK finished but did not report a result. This normally means the check was stopped before it ended. The report above, if present, still shows what it found.	CHKDSK a fini sans donner de résultat. Cela veut normalement dire que la vérification a été arrêtée avant la fin. Le rapport ci-dessus, s’il y en a un, montre quand même ce qu’il a trouvé.
CHKDSK finished with an unexpected result code ({0}). The report above, if present, shows what it found.	CHKDSK a fini avec un code de résultat inattendu ({0}). Le rapport ci-dessus, s’il y en a un, montre ce qu’il a trouvé.
CHKDSK found no file system problems on C:.	CHKDSK n’a trouvé aucun problème de système de fichiers sur C:.
CHKDSK found problems on C: and repaired them online. No restart is needed.	CHKDSK a trouvé des problèmes sur C: et les a réparés en direct. Aucun redémarrage n’est nécessaire.
CHKDSK found problems on C: that it cannot repair while Windows is running. They have been logged for offline repair. Run "chkdsk C: /spotfix" from an administrator command prompt and restart when prompted.	CHKDSK a trouvé sur C: des problèmes qu’il ne peut pas réparer pendant que Windows tourne. Ils ont été notés pour une réparation hors ligne. Lancez « chkdsk C: /spotfix » dans une invite de commandes administrateur et redémarrez quand on vous le demande.
CHKDSK reported:	CHKDSK a signalé :
CHOOSE A FOLDER	CHOISIR UN DOSSIER
CLEANING THIS PC	NETTOYAGE DE CE PC
COPY FROM	COPIER DEPUIS
COPY ONTO	COPIER SUR
CSV data	Données CSV
CUSTOM SCAN	ANALYSE PERSONNALISÉE
Cache and logs only; synced files are not touched	Cache et journaux seulement ; les fichiers synchronisés ne sont pas touchés
Cache only; passwords, cookies, and sessions preserved	Cache seulement ; mots de passe, témoins (cookies) et sessions gardés
Camcorder video	Vidéo de caméscope
Cancel	Annuler
Cancel shut down	Annuler l’arrêt
Cancellation requested. The current Windows operation will finish safely.	Annulation demandée. L’opération Windows en cours va se terminer en toute sécurité.
Cancelled - your PC stays on.	Annulé - votre PC reste allumé.
Cannot move on the source drive (error	Impossible de se déplacer sur le disque source (erreur
Cannot move on the target drive (error	Impossible de se déplacer sur le disque cible (erreur
Cannot read the source drive at	Impossible de lire le disque source à
Cannot read the used-space map (error	Impossible de lire la carte de l’espace utilisé (erreur
Cannot tell - check it yourself	Impossible à dire - vérifiez vous-même
Cannot write the image file (error	Impossible d’écrire le fichier de sauvegarde (erreur
Cannot write the target drive at	Impossible d’écrire sur le disque cible à
Canon RAW photo	Photo RAW Canon
Capacity	Capacité
Caution	Prudence
Certificate	Certificat
Certificate check:	Vérification du certificat :
ChatGPT app	Appli ChatGPT
ChatGPT app: uninstall completely	Appli ChatGPT : désinstaller complètement
ChatGPT, Gemini, Copilot and other AI websites are now blocked in {0}, and Claude is left open. Close and reopen the browser. It will show "Managed by your organization" - that is what keeps them blocked. "Turn back on" removes it.	ChatGPT, Gemini, Copilot et les autres sites d’IA sont maintenant bloqués dans {0}, et Claude reste ouvert. Fermez et rouvrez le navigateur. Il affichera « Géré par votre organisation » - c’est ce qui les garde bloqués. « Réactiver » l’enlève.
Check	Vérifier
Check Defender exclusions	Vérifier les exclusions de Defender
Check a backup	Vérifier une sauvegarde
Check a backup file	Vérifier une sauvegarde
Check again	Revérifier
Check all	Tout cocher
Check complete	Vérification terminée
Check for Windows updates and install them now?	Chercher les mises à jour Windows et les installer maintenant ?
Check for driver updates	Chercher des mises à jour de pilotes
Check for problems the next time I start my computer	Rechercher les problèmes au prochain démarrage de l’ordinateur
Check for updates	Rechercher des mises à jour
Check my PC	Vérifier mon PC
Check my RAM	Vérifier ma RAM
Check my drives	Vérifier mes disques
Check my memory	Vérifier ma mémoire
Check my security and privacy	Vérifier ma sécurité et ma confidentialité
Check now	Vérifier maintenant
Check off	Décocher
Check power and heat	Vérifier l’alimentation et la chaleur
Check that the internet is on, then try again.	Vérifiez qu’Internet fonctionne, puis réessayez.
Checked today: all good. No need to check again for now.	Vérifié aujourd’hui : tout va bien. Pas besoin de revérifier pour le moment.
Checked today: something needs attention. Click to check again.	Vérifié aujourd’hui : quelque chose demande votre attention. Cliquez pour revérifier.
Checked: something needs attention. Click to check again.	Vérifié : quelque chose demande votre attention. Cliquez pour revérifier.
Checking	Vérification
Checking Windows system files: {0}% done	Vérification des fichiers système de Windows : {0} % fait
Checking Windows system files…	Vérification des fichiers système de Windows…
Checking behind the sofa for missing files...	On cherche les fichiers perdus derrière le divan...
Checking for updates...	Recherche de mises à jour...
Checking temporary files and browser caches…	Vérification des fichiers temporaires et des caches des navigateurs…
Checking temporary files, browser data, and maintenance settings. Nothing is being changed.	Vérification des fichiers temporaires, des données des navigateurs et des réglages d’entretien. Rien n’est changé.
Checking the download...	Vérification du téléchargement...
Checking your RAM is a long test. Windows has to restart to run it, so save your work first. Only tick it if you are ready to wait. The Cleaner never restarts the PC by itself.	La vérification de la RAM est un long test. Windows doit redémarrer pour le faire, alors enregistrez votre travail d’abord. Cochez-le seulement si vous êtes prêt à attendre. Le Cleaner ne redémarre jamais le PC de lui-même.
Checking…	Vérification…
Checks for Windows 10/11 updates and installs them, in its own window. A restart may be needed afterwards.	Cherche les mises à jour de Windows 10/11 et les installe, dans sa propre fenêtre. Un redémarrage peut être nécessaire ensuite.
Checks that the firewall, virus protection and Windows Update are all switched on. It only looks - nothing is changed.	Vérifie que le pare-feu, l’antivirus et Windows Update sont tous activés. Il ne fait que regarder - rien n’est changé.
Checks the C: file system for corruption while Windows keeps running. Reports what it finds, repairs what is safe to repair, and never schedules a restart.	Vérifie le système de fichiers de C: pendant que Windows tourne. Signale ce qu’il trouve, répare ce qui peut l’être sans risque, et ne programme jamais de redémarrage.
Checks your drives (SSD and NVMe too), memory, processor, heat, security, spyware, startup apps and large files in one go. Nothing is changed.	Vérifie d’un coup vos disques (SSD et NVMe aussi), la mémoire, le processeur, la chaleur, la sécurité, les logiciels espions, les applis au démarrage et les gros fichiers. Rien n’est changé.
Checksum	Somme de contrôle
Chipset, LAN, Wi-Fi, audio and BIOS drivers come from the maker, not Windows Update. This opens their page in your browser. Nothing is downloaded or installed.	Les pilotes du chipset, du réseau, du Wi-Fi, du son et du BIOS viennent du fabricant, pas de Windows Update. Ceci ouvre leur page dans votre navigateur. Rien n’est téléchargé ni installé.
Choose No to do it later. Nothing changes unless you choose Yes.	Choisissez Non pour le faire plus tard. Rien ne change sauf si vous choisissez Oui.
Choose No to restart later yourself. Nothing restarts unless you choose Yes.	Choisissez Non pour redémarrer plus tard vous-même. Rien ne redémarre sauf si vous choisissez Oui.
Choose a drive to copy from and a drive to copy onto.	Choisissez un disque à copier et un disque qui reçoit la copie.
Choose a folder	Choisir un dossier
Choose a folder, or tick a cloud service or a drive to scan.	Choisissez un dossier, ou cochez un service infonuagique ou un disque à analyser.
Choose a level, or select individual tasks below.	Choisissez un niveau, ou sélectionnez des tâches une par une ci-dessous.
Choose cleanup level	Choisir le niveau de nettoyage
Choose one of the program's files	Choisissez un des fichiers du programme
Choose programs	Choisir des programmes
Choose the drive to restore onto.	Choisissez le disque sur lequel restaurer.
Choose the drive to secure.	Choisissez le disque à sauvegarder.
Choose the folder of the program you want to remove	Choisissez le dossier du programme à retirer
Choose the image file to restore.	Choisissez le fichier de sauvegarde à restaurer.
Choose the installer of the program you want to install	Choisissez l’installateur du programme à installer
Choose the program's folder	Choisissez le dossier du programme
Choose the record of the program you want to remove completely	Choisissez le relevé du programme à retirer complètement
Choose the {0} ISO file	Choisissez le fichier ISO de {0}
Choose two different drives.	Choisissez deux disques différents.
Choose where to save the image.	Choisissez où enregistrer la sauvegarde.
Chrome: turn Gemini and AI Mode back on	Chrome : réactiver Gemini et le mode IA
Chrome: turn off Gemini and AI Mode	Chrome : désactiver Gemini et le mode IA
Chrome: uninstall completely	Chrome : désinstaller complètement
Claude app	Appli Claude
Claude app: uninstall completely	Appli Claude : désinstaller complètement
Claude is OFF - claude.ai blocked in your browsers	Claude est DÉSACTIVÉ - claude.ai bloqué dans vos navigateurs
Claude is OFF - website blocked	Claude est DÉSACTIVÉ - site bloqué
Claude is ON - claude.ai is open in your browsers	Claude est ACTIVÉ - claude.ai est ouvert dans vos navigateurs
Claude is ON - website open	Claude est ACTIVÉ - site ouvert
Claude is left alone. Bookmarks, passwords and chats stay in their accounts.	Claude n’est pas touché. Les favoris, mots de passe et conversations restent dans leurs comptes.
Claude website: turn back on	Site de Claude : réactiver
Claude website: turn off	Site de Claude : désactiver
Clean	Nettoyer
Clean my PC	Nettoyer mon PC
Cleaning history	Historique des nettoyages
Cleaning time - press here	Durée du nettoyage - appuyez ici
Cleanup	Nettoyage
Clear ARP cache	Vider le cache ARP
Clear WinHTTP proxy	Effacer le proxy WinHTTP
Clear all filters	Effacer tous les filtres
Clear all history	Effacer tout l’historique
Clear it now?	L’effacer maintenant ?
Clear my ticks	Effacer mes coches
Cleared browser cache {0} of {1}.	Cache de navigateur {0} sur {1} vidé.
Cleared {0} developer cache folder(s).	{0} dossier(s) de cache de développement vidé(s).
Cleared {0} game launcher cache folder(s).	{0} dossier(s) de cache de lanceurs de jeux vidé(s).
Cleared {0} graphics shader cache folder(s).	{0} dossier(s) de cache de shaders graphiques vidé(s).
Cleared {0} {1} cache location(s). Synced files were not touched.	{0} emplacement(s) de cache {1} vidé(s). Les fichiers synchronisés n’ont pas été touchés.
Clears already-installed update installers cached under SoftwareDistribution\Download. Windows re-downloads only what it needs next time.	Vide les installateurs de mises à jour déjà installées, gardés dans SoftwareDistribution\Download. Windows retélécharge seulement ce dont il a besoin la prochaine fois.
Clears cache files while preserving passwords, bookmarks, cookies, and active sessions.	Vide les fichiers de cache en gardant les mots de passe, favoris, témoins (cookies) et sessions ouvertes.
Clears cached thumbnail images. Windows rebuilds them the next time you browse those files.	Vide les miniatures en cache. Windows les refait la prochaine fois que vous parcourez ces fichiers.
Clears saved graphics files from DirectX and the NVIDIA, AMD and Intel drivers. Games rebuild them by themselves, so the first launch afterwards can be choppy for a few seconds.	Vide les fichiers graphiques enregistrés par DirectX et les pilotes NVIDIA, AMD et Intel. Les jeux les refont eux-mêmes, donc le premier lancement ensuite peut saccader quelques secondes.
Clears taskbar jump lists and the Recent Items list. Files you pinned inside an app's jump list are removed too. Taskbar icons and Quick Access folders are kept.	Vide les listes de raccourcis de la barre des tâches et la liste des éléments récents. Les fichiers épinglés dans la liste d’une appli sont aussi retirés. Les icônes de la barre des tâches et les dossiers d’Accès rapide sont gardés.
Clears the Application and System event logs. Removes diagnostic history used for troubleshooting. The Security log is never touched.	Vide les journaux d’événements Application et Système. Retire l’historique de diagnostic utilisé pour le dépannage. Le journal Sécurité n’est jamais touché.
Clears the Microsoft Store and PowerShell logs, including the record of PowerShell commands that were run. Disk and driver logs are left alone so they can still help with troubleshooting.	Vide les journaux du Microsoft Store et de PowerShell, y compris l’historique des commandes PowerShell lancées. Les journaux des disques et pilotes sont gardés pour pouvoir encore aider au dépannage.
Clears the Microsoft Store cache. This fixes a Store that will not open or update. Your apps and purchases are not touched.	Vide le cache du Microsoft Store. Cela répare un Store qui ne s’ouvre pas ou ne se met pas à jour. Vos applis et achats ne sont pas touchés.
Clears the Prefetch cache. Windows rebuilds it and app launches may initially be slower.	Vide le cache Prefetch. Windows le refait et les applis peuvent démarrer un peu plus lentement au début.
Clears the download caches of npm, pip, NuGet, Yarn and Go. Your projects and installed packages are not touched. The next install or build downloads again, so it is slower once.	Vide les caches de téléchargement de npm, pip, NuGet, Yarn et Go. Vos projets et paquets installés ne sont pas touchés. La prochaine installation ou compilation retélécharge, donc elle est plus lente une fois.
Clears the icon cache and restarts Explorer to rebuild it. Fixes blank or wrong icons. The taskbar and desktop will flash off and back on and open folder windows will close. Do not run it while File Explorer is copying or moving files.	Vide le cache des icônes et redémarre l’Explorateur pour le refaire. Répare les icônes vides ou fausses. La barre des tâches et le bureau vont disparaître et revenir, et les fenêtres de dossiers ouvertes vont se fermer. Ne le lancez pas pendant que l’Explorateur copie ou déplace des fichiers.
Clears the list Windows keeps of program names it has shown you. Windows rebuilds it by itself, and no program is removed.	Vide la liste que Windows garde des noms de programmes qu’il vous a montrés. Windows la refait tout seul, et aucun programme n’est retiré.
Clears the list of documents you opened recently. The documents themselves are kept.	Vide la liste des documents ouverts récemment. Les documents eux-mêmes sont gardés.
Clears the local cache and logs Dropbox leaves on this PC. Your synced files are not touched.	Vide le cache local et les journaux que Dropbox laisse sur ce PC. Vos fichiers synchronisés ne sont pas touchés.
Clears the local cache and logs Google Drive leaves on this PC. Your synced files are not touched.	Vide le cache local et les journaux que Google Drive laisse sur ce PC. Vos fichiers synchronisés ne sont pas touchés.
Clears the local cache and logs MEGA leaves on this PC. Your synced files are not touched.	Vide le cache local et les journaux que MEGA laisse sur ce PC. Vos fichiers synchronisés ne sont pas touchés.
Clears the local cache and logs OneDrive leaves on this PC. Your synced files are not touched.	Vide le cache local et les journaux que OneDrive laisse sur ce PC. Vos fichiers synchronisés ne sont pas touchés.
Clears the local cache and logs iCloud leaves on this PC. Your synced files are not touched.	Vide le cache local et les journaux qu’iCloud laisse sur ce PC. Vos fichiers synchronisés ne sont pas touchés.
Clears the log of what Microsoft Defender found and scanned in the past. Defender stays on and keeps protecting this PC; only the history is removed.	Vide le journal de ce que Microsoft Defender a trouvé et analysé dans le passé. Defender reste actif et continue de protéger ce PC ; seul l’historique est retiré.
Clears the peer-to-peer Windows Update cache. Windows rebuilds it as needed.	Vide le cache pair à pair de Windows Update. Windows le refait au besoin.
Clears the temporary cache these apps keep on this PC. They rebuild it by themselves, so the first start afterwards can be a little slower. Logins, chats and downloaded music are not touched.	Vide le cache temporaire que ces applis gardent sur ce PC. Elles le refont elles-mêmes, donc le premier démarrage ensuite peut être un peu plus lent. Les connexions, conversations et musique téléchargée ne sont pas touchées.
Clears the web page caches kept by Steam and the Epic Games launcher. Games, saves and logins are not touched. The launchers rebuild these by themselves, so their store pages may load slowly once.	Vide les caches de pages Web gardés par Steam et le lanceur Epic Games. Les jeux, sauvegardes et connexions ne sont pas touchés. Les lanceurs les refont eux-mêmes, donc leurs pages de magasin peuvent charger lentement une fois.
Clears what you have typed into File Explorer's search box. Your files are untouched.	Efface ce que vous avez tapé dans la recherche de l’Explorateur de fichiers. Vos fichiers ne sont pas touchés.
Click here to see it working	Cliquez ici pour le voir travailler
Click to go to the progress page	Cliquez pour aller à la page de progression
Click to read a short, friendly note	Cliquez pour lire une courte note amicale
Click to see how long each scan takes on this PC	Cliquez pour voir combien de temps prend chaque analyse sur ce PC
Clipboard	Presse-papiers
Clone & Backup	Copie et sauvegarde
Clone & Backup could not open that screen:	Copie et sauvegarde n’a pas pu ouvrir cet écran :
Clone & Backup is not included in this copy of the Cleaner.	Copie et sauvegarde n’est pas inclus dans cette copie du Cleaner.
Close	Fermer
Close Chrome and Edge before running, so the AI model they downloaded can be deleted.	Fermez Chrome et Edge avant de lancer, pour que le modèle d’IA qu’ils ont téléchargé puisse être supprimé.
Close and reopen the program to start using it. No PC restart is needed.	Fermez et rouvrez le programme pour commencer à l’utiliser. Aucun redémarrage du PC n’est nécessaire.
Close first:	Fermez d’abord :
Close them now? (Yes = close them, No = remove anyway, Cancel = stop)	Les fermer maintenant ? (Oui = les fermer, Non = retirer quand même, Annuler = arrêter)
Close this icon	Fermer cette icône
Close your browsers first. Saved passwords and bookmarks are kept. This cannot be undone. DRDirect is not responsible for any sign-in or password you cannot get back.	Fermez d’abord vos navigateurs. Les mots de passe enregistrés et les favoris sont conservés. Ceci ne peut pas être annulé. DRDirect n’est pas responsable des connexions ou mots de passe que vous ne pourriez pas récupérer.
Close {0} first, then you can close the Cleaner.	Fermez d’abord {0}, puis vous pourrez fermer le Cleaner.
Code	Code
Color legend	Légende des couleurs
Columns	Colonnes
Compact browser databases	Compacter les bases de données des navigateurs
Compacted {0} database(s), {1} MB smaller.	{0} base(s) de données compactée(s), {1} Mo de moins.
Comparing {0} possible matches...	Comparaison de {0} correspondances possibles...
Completed	Terminé
Completely removes a program you installed with tracking. Everything is backed up first.	Retire complètement un programme installé avec suivi. Tout est sauvegardé d’abord.
Compressing	Compression
Compressing and locking	Compression et verrouillage
Confidence	Confiance
Confidence rating	Niveau de confiance
Confirm	Confirmer
Confirm removal	Confirmer le retrait
Confirm restart	Confirmer le redémarrage
Confirm shut down	Confirmer l’arrêt
Contact DRDirect for a copy for this machine.	Contactez DRDirect pour une copie pour cet ordinateur.
Contact DRDirect for a key to unlock the {0} on this machine.	Contactez DRDirect pour une clé qui débloque {0} sur cet ordinateur.
Contact DRDirect to be sent an activation code for this machine.	Contactez DRDirect pour recevoir un code d’activation pour cet ordinateur.
Contact DRDirect to buy it. They will send you the program and a code for this machine.	Contactez DRDirect pour l’acheter. On vous enverra le programme et un code pour cet ordinateur.
Contact DRDirect to continue using the {0} on this machine.	Contactez DRDirect pour continuer à utiliser {0} sur cet ordinateur.
Continue	Continuer
Continue?	Continuer ?
Controlled folder access	Accès contrôlé aux dossiers
Cookie cleanup can end active website and webmail sessions.	Le nettoyage des témoins (cookies) peut fermer vos sessions ouvertes sur les sites Web et les courriels.
Cookies and website traces	Témoins (cookies) et traces des sites Web
Copied whole, because they cannot be mapped:	Copiés en entier, car leur contenu ne peut pas être lu :
Copies marked to remove	Copies marquées à retirer
Copilot app	Appli Copilot
Copilot app: uninstall completely	Appli Copilot : désinstaller complètement
Copilot is now off in Edge. Close Edge completely and open it again.	Copilot est maintenant désactivé dans Edge. Fermez Edge complètement et rouvrez-le.
Copying	Copie
Copying Windows Setup failed (robocopy code {0}).	La copie de l’installation de Windows a échoué (code robocopy {0}).
Copying failed (robocopy code {0}). From: {1}  To: {2}	La copie a échoué (code robocopy {0}). De : {1}  Vers : {2}
Copying onto a smaller drive works only for drives with a GPT partition table (all Windows 11 PCs). This drive uses MBR.	La copie sur un disque plus petit fonctionne seulement pour les disques avec une table de partitions GPT (tous les PC Windows 11). Ce disque utilise MBR.
Copying the rescue system...	Copie du système de secours...
Copying {0} (this takes a while)...	Copie de {0} (cela prend un moment)...
Copying {0} Setup...	Copie de l’installation de {0}...
Copying {0} in parts (this takes a while)...	Copie de {0} en plusieurs parties (cela prend un moment)...
Copyright (c) 2026 DRDirect. All rights reserved.	Copyright (c) 2026 DRDirect. Tous droits réservés.
Could not add Windows to the {0} start-up menu.	Impossible d’ajouter Windows au menu de démarrage {0}.
Could not change Notepad's setting (code {0}).	Impossible de changer le réglage du Bloc-notes (code {0}).
Could not check	Vérification impossible
Could not check for updates: {0}	Impossible de rechercher des mises à jour : {0}
Could not clear the Defender history log: {0}	Impossible de vider l’historique de Defender : {0}
Could not clear {0}: {1}	Impossible de vider {0} : {1}
Could not clear:	Impossible d’effacer :
Could not delete	Suppression impossible
Could not delete the report.	Impossible de supprimer le rapport.
Could not download the Setup Wizard:	Impossible de télécharger l’Assistant d’installation :
Could not empty the clipboard: {0}	Impossible de vider le presse-papiers : {0}
Could not find the DRDirect Duplicate Finder beside the application.	Impossible de trouver DRDirect Duplicate Finder à côté de l’application.
Could not fully remove {0}: {1}	Impossible de retirer complètement {0} : {1}
Could not get the update:	Impossible d’obtenir la mise à jour :
Could not install winget:	Impossible d’installer winget :
Could not list the SSD drives: {0}	Impossible de lister les disques SSD : {0}
Could not open Notepad's settings (code {0}).	Impossible d’ouvrir les réglages du Bloc-notes (code {0}).
Could not open Notepad's settings (code {0}). Close Notepad and try again.	Impossible d’ouvrir les réglages du Bloc-notes (code {0}). Fermez le Bloc-notes et réessayez.
Could not open Windows Security: {0}	Impossible d’ouvrir Sécurité Windows : {0}
Could not open that file:	Impossible d’ouvrir ce fichier :
Could not open the DRDirect Uninstaller Program: {0}	Impossible d’ouvrir le programme de désinstallation DRDirect : {0}
Could not open the Microsoft Store: {0}	Impossible d’ouvrir le Microsoft Store : {0}
Could not open the drive for direct copying.	Impossible d’ouvrir le disque pour la copie directe.
Could not reach the update server. You are still running the version you have.	Impossible de joindre le serveur de mise à jour. Vous gardez la version que vous avez.
Could not read	Lecture impossible
Could not read the Store apps:	Impossible de lire les applications du Store :
Could not read the programs:	Impossible de lire les programmes :
Could not read which parts of partition {0} hold data, so nothing was copied. ({1})	Impossible de savoir quelles parties de la partition {0} contiennent des données, donc rien n’a été copié. ({1})
Could not read which parts of partition {0} hold data, so nothing was copied. Open the Imager as administrator and try again. ({1})	Impossible de savoir quelles parties de la partition {0} contiennent des données, donc rien n’a été copié. Ouvrez l’Imager en administrateur et réessayez. ({1})
Could not read which parts of the drive hold data, so nothing was copied. ({0})	Impossible de savoir quelles parties du disque contiennent des données, donc rien n’a été copié. ({0})
Could not read {0}: {1}	Impossible de lire {0} : {1}
Could not remove	Retrait impossible
Could not remove restore point '{0}' (code {1}).	Impossible de retirer le point de restauration « {0} » (code {1}).
Could not remove: {0}	Retrait impossible : {0}
Could not shred the free space on {0}: {1}	Impossible de nettoyer l’espace libre sur {0} : {1}
Could not start its uninstaller:	Impossible de lancer son programme de désinstallation :
Could not start the Duplicate Finder: {0}	Impossible de lancer le Duplicate Finder : {0}
Could not start the installer:	Impossible de lancer l’installateur :
Could not start the update window: {0}	Impossible d’ouvrir la fenêtre de mise à jour : {0}
Could not start the winget install: {0}	Impossible de lancer l’installation de winget : {0}
Could not start winget: {0}	Impossible de lancer winget : {0}
Could not switch to the Cleaner: {0}	Impossible de passer au Cleaner : {0}
Crazy Nutty 3D	3D complètement fou
Create a Rescue USB	Créer une clé USB de secours
Create or replace a Rescue USB	Créer ou remplacer
Create restore point	Créer un point de restauration
Creates a Windows restore point before repair operations when System Protection is available.	Crée un point de restauration Windows avant les réparations quand la Protection du système est disponible.
Current user	Utilisateur actuel
Custom	Personnalisé
Custom (items picked by hand)	Personnalisé (éléments choisis à la main)
Custom selection. Security and drive-health operations remain manual.	Sélection personnalisée. Les opérations de sécurité et de santé des disques restent manuelles.
Customize Copilot key on keyboard	Personnaliser la touche Copilot du clavier
DISM RestoreHealth	DISM RestoreHealth
DISM component cleanup	Nettoyage des composants DISM
DNG RAW photo	Photo RAW DNG
DRDirect App Updater	Mise à jour des applis DRDirect
DRDirect Clone & Backup	DRDirect Copie et sauvegarde
DRDirect Imager - timing of this image	DRDirect Imager - durée de cette sauvegarde
DRDirect PC Cleaner	DRDirect Nettoyeur PC
DRDirect PC Cleaner - Before Maintenance	DRDirect Nettoyeur PC - Avant l’entretien
DRDirect PC Cleaner - Clone & Backup	DRDirect Nettoyeur PC - Copie et sauvegarde
DRDirect PC Cleaner - Maintenance Report	DRDirect Nettoyeur PC - Rapport d’entretien
DRDirect PC Cleaner - Scan refused	DRDirect Nettoyeur PC - Analyse refusée
DRDirect PC Cleaner - Windows install USB	DRDirect Nettoyeur PC - Clé USB d’installation de Windows
DRDirect PC Cleaner - safety point before changes	DRDirect Nettoyeur PC - point de sécurité avant les changements
DRDirect PC Cleaner maintenance completed. Restarting to finish Windows maintenance.	L’entretien de DRDirect Nettoyeur PC est terminé. Redémarrage pour finir l’entretien de Windows.
DRDirect PC Cleaner maintenance completed. Shutting down as you asked.	L’entretien de DRDirect Nettoyeur PC est terminé. Arrêt du PC comme vous l’avez demandé.
DRDirect PC Cleaner update icon	Icône de mise à jour de DRDirect Nettoyeur PC
DRDirect PC Cleaner will now close and open again by itself.	DRDirect Nettoyeur PC va maintenant se fermer et se rouvrir tout seul.
DRDirect PC Cleaner: update ready ({0})	DRDirect Nettoyeur PC : mise à jour prête ({0})
DRDirect Pro Tech Uninstaller	Désinstalleur DRDirect Pro Tech
DRDirect Pro Tech\nUninstaller	Désinstalleur\nDRDirect Pro Tech
DRDirect Rescue USB - Warning	Clé USB de secours DRDirect - Avertissement
DRDirect Rescue system	Système de secours DRDirect
DRDirect Uninstaller	Désinstalleur DRDirect
DRDirect Uninstaller Program	Programme de désinstallation DRDirect
DRDirect Uninstaller is removing {0}	Le désinstalleur DRDirect retire {0}
DRDirect backup file (*.drimg)|*.drimg	Fichier de sauvegarde DRDirect (*.drimg)|*.drimg
DRDirect image (*.drimg)|*.drimg	Sauvegarde DRDirect (*.drimg)|*.drimg
DUPLICATE SETS	GROUPES DE DOUBLONS
DVD video	Vidéo DVD
Danger	Danger
Dashboard	Tableau de bord
Data read:       {0} (empty space is skipped)	Données lues :   {0} (l’espace vide est sauté)
Deep scan: looks for all of the program's leftover files, folders, services and settings in the registry and on the hard drive. System folders and drives are never touched. The extra accounts option also checks the other accounts' AppData folders (files and folders only).	Analyse approfondie : cherche tous les restes du programme (fichiers, dossiers, services et paramètres) dans le registre et sur le disque dur. Les dossiers système et les disques ne sont jamais touchés. L’option des autres comptes vérifie aussi les dossiers AppData des autres comptes (fichiers et dossiers seulement).
Deeper	Plus profond
Defender exclusions on this PC ({0}):	Exclusions de Defender sur ce PC ({0}) :
Defender exclusions: CHECK THESE	Exclusions de Defender : À VÉRIFIER
Defender exclusions: NO PROBLEMS FOUND	Exclusions de Defender : AUCUN PROBLÈME TROUVÉ
Defender full scan	Analyse complète de Defender
Defender history cleared. Defender is still on and protecting this PC.	Historique de Defender vidé. Defender est toujours actif et protège ce PC.
Defender quick scan	Analyse rapide de Defender
Delete	Supprimer
Delete downloaded AI models	Supprimer les modèles d’IA téléchargés
Delete selected	Supprimer la sélection
Delete this report?	Supprimer ce rapport ?
Deleted files and cleared caches cannot be brought back.	Les fichiers supprimés et les caches vidés ne peuvent pas être récupérés.
Deletes older System Restore snapshots, keeping only the most recent one. Reduces how far back you can roll back Windows.	Supprime les anciens points de restauration et garde seulement le plus récent. Réduit jusqu’où vous pouvez ramener Windows en arrière.
Deletes the AI model Chrome and Edge download in the background - often 2 to 4 GB. Close the browser first, and also pick "Turn off" on the Chrome or Edge row, or the browser downloads it again. Only browsers that are signed in are changed.	Supprime le modèle d’IA que Chrome et Edge téléchargent en arrière-plan - souvent 2 à 4 Go. Fermez d’abord le navigateur, et choisissez aussi « Désactiver » sur la ligne Chrome ou Edge, sinon le navigateur le retélécharge. Seuls les navigateurs connectés sont changés.
Delivery Optimization cache	Cache de l’Optimisation de la distribution
Delivery Optimization cache cmdlet is not available on this system.	La commande du cache de l’Optimisation de la distribution n’est pas disponible sur ce système.
Desktop	Bureau
Destructive actions always require final confirmation.	Les actions qui suppriment demandent toujours une confirmation finale.
Details	Détails
Developer caches	Caches de développement
Directional Aid for Users	Aide aux utilisateurs
Disable TCP heuristics	Désactiver l’heuristique TCP
Disabled	Désactivé
Disc image	Image disque
Disk {0}	Disque {0}
Disk {0} is not a USB flash drive. Nothing was changed.	Le disque {0} n’est pas une clé USB. Rien n’a été changé.
Display adapter	Carte graphique
DivX video	Vidéo DivX
Do you want to be able to put this backup back onto a SMALLER drive (for example a 500 GB)?	Voulez-vous pouvoir remettre cette sauvegarde sur un disque PLUS PETIT (par exemple un 500 Go) ?
Do you want to continue?	Voulez-vous continuer ?
Dock: {0} (the dock only passes the drive through; the drive inside is a separate disk)	Station d’accueil : {0} (la station ne fait que relier le disque ; le disque à l’intérieur est un disque séparé)
Docked drive	Disque dans une station d’accueil
Documents	Documents
Don't worry - this is often very easy to fix. A restart often sorts it.	Pas d’inquiétude - c’est souvent très facile à régler. Un redémarrage suffit souvent.
Done	Terminé
Done! The installer added {0} files and {1} settings.	Terminé ! L’installateur a ajouté {0} fichiers et {1} paramètres.
Done. No restart is needed.	Terminé. Aucun redémarrage n’est nécessaire.
Done. Notepad will now open with an empty page.	Terminé. Le Bloc-notes s’ouvrira maintenant sur une page vide.
Done. Nothing was left behind.	Terminé. Il ne reste rien.
Done. Put back {0} items.	Terminé. {0} éléments remis en place.
Done. Restart the PC, then open Reliability Monitor again. The chart can take up to 24 hours to redraw.	Terminé. Redémarrez le PC, puis rouvrez le Moniteur de fiabilité. Le graphique peut prendre jusqu’à 24 heures à se redessiner.
Done. The apps were removed.	Terminé. Les applications ont été retirées.
Download and install it now?	Le télécharger et l’installer maintenant ?
Download caches; tools fetch again when needed	Caches de téléchargement ; les outils retéléchargent au besoin
Download now	Télécharger maintenant
Downloading the Rescue system...	Téléchargement du système de secours...
Downloading the Rescue system... {0}%  ({1} of {2} MB)	Téléchargement du système de secours... {0} %  ({1} sur {2} Mo)
Downloading the Windows 11 Setup Wizard from Microsoft...	Téléchargement de l’Assistant d’installation de Windows 11 depuis Microsoft...
Downloading the new version. On a slow connection this can take a minute or two.	Téléchargement de la nouvelle version. Avec une connexion lente, cela peut prendre une minute ou deux.
Downloading winget from Microsoft...	Téléchargement de winget depuis Microsoft...
Downloads	Téléchargements
Downloads the latest available Microsoft Defender security intelligence.	Télécharge les dernières définitions de sécurité de Microsoft Defender.
Drive	Disque
Drive health check	Vérification de la santé des disques
Drive health checks are read-only and do not schedule repairs or restarts.	Les vérifications de santé des disques ne font que lire et ne programment ni réparation ni redémarrage.
Drive into a backup file	Disque en sauvegarde
Drive onto drive	Disque à disque
Drive {0}: is not on disk {1} any more. Nothing was changed.	Le lecteur {0}: n’est plus sur le disque {1}. Rien n’a été changé.
Driver	Pilote
Driver updates	Mises à jour de pilotes
Dropbox cache	Cache de Dropbox
Duplicate Finder opened in its own window, running as your normal user rather than as administrator.	Le Duplicate Finder s’est ouvert dans sa propre fenêtre, avec votre compte normal plutôt qu’en administrateur.
Duplicate Finder opened in its own window.	Le Duplicate Finder s’est ouvert dans sa propre fenêtre.
Duplicates	Doublons
Duplicates moved to the Recycle Bin.	Doublons déplacés dans la Corbeille.
EVERYTHING on the USB stick you pick will be erased.	TOUT ce qui est sur la clé USB choisie sera effacé.
EXACT DUPLICATE	DOUBLON EXACT
Easy	Facile
Edge is not signed in, so nothing was opened. Sign in to Edge first, then run this again.	Edge n’est pas connecté, donc rien n’a été ouvert. Connectez-vous d’abord à Edge, puis relancez ceci.
Edge is opening. Click the three dots at the top right, open Settings, search for "Copilot" and switch the Copilot button off.	Edge s’ouvre. Cliquez sur les trois points en haut à droite, ouvrez Paramètres, cherchez « Copilot » et désactivez le bouton Copilot.
Edge is opening. Click the three dots at the top right, open Settings, search for "Copilot" and switch the Copilot button on.	Edge s’ouvre. Cliquez sur les trois points en haut à droite, ouvrez Paramètres, cherchez « Copilot » et activez le bouton Copilot.
Edge is opening. Click the three dots at the top right, open Settings, search for "search engine" and pick Google under "Search engine used in the address bar".	Edge s’ouvre. Cliquez sur les trois points en haut à droite, ouvrez Paramètres, cherchez « moteur de recherche » et choisissez Google sous « Moteur de recherche utilisé dans la barre d’adresses ».
Edge is opening. Click the three dots at the top right, open Settings, search for "search engine" and pick Microsoft Bing under "Search engine used in the address bar".	Edge s’ouvre. Cliquez sur les trois points en haut à droite, ouvrez Paramètres, cherchez « moteur de recherche » et choisissez Microsoft Bing sous « Moteur de recherche utilisé dans la barre d’adresses ».
Edge was not found on this PC. Nothing was opened.	Edge n’a pas été trouvé sur ce PC. Rien n’a été ouvert.
Edge: hide the Copilot button	Edge : cacher le bouton Copilot
Edge: show the Copilot button again	Edge : réafficher le bouton Copilot
Edge: turn Copilot back on	Edge : réactiver Copilot
Edge: turn off Copilot	Edge : désactiver Copilot
Edge: uninstall completely	Edge : désinstaller complètement
Edge: use Bing again	Edge : réutiliser Bing
Edge: use Google instead of Bing	Edge : utiliser Google au lieu de Bing
Empties the drop-down list in the Windows Run box (Win+R). Your programs are untouched.	Vide la liste déroulante de la boîte Exécuter de Windows (Win+R). Vos programmes ne sont pas touchés.
Empties whatever you last copied. Nothing else is touched; copy again and it works as before.	Vide ce que vous avez copié en dernier. Rien d’autre n’est touché ; copiez de nouveau et tout fonctionne comme avant.
Enable network-file scanning	Activer l’analyse des fichiers réseau
Enabled	Activé
Enables Microsoft Defender scanning of files accessed over the network.	Active l’analyse par Microsoft Defender des fichiers ouverts par le réseau.
Enter the code DRDirect sent you.	Entrez le code que DRDirect vous a envoyé.
Enter the code first.	Entrez d’abord le code.
Enter the owner password:	Entrez le mot de passe du propriétaire :
Entry	Entrée
Erased website trace {0} of {1}.	Trace de site {0} sur {1} effacée.
Erased {0} website trace item(s){1}. Saved passwords and bookmarks were kept.	{0} trace(s) de sites effacée(s){1}. Les mots de passe enregistrés et les favoris ont été gardés.
Erases history, cookies and site data in every browser; passwords and bookmarks stay; signs you out	Efface l’historique, les témoins (cookies) et les données des sites dans tous les navigateurs ; les mots de passe et favoris restent ; vous déconnecte
Erasing the USB flash drive...	Effacement de la clé USB...
Error	Erreur
Even deeper 3D: bigger shadows and thicker raised edges. Turns the 3D look on too.	Encore plus de 3D : ombres plus grandes et bords en relief plus épais. Active aussi l’effet 3D.
Every part of the image is read and tested.	Chaque partie de la sauvegarde est lue et vérifiée.
Everything	Tout
Everything DRDirect has been removed from this PC. The program will close now.	Tout ce qui vient de DRDirect a été retiré de ce PC. Le programme va se fermer.
Everything in the Recycle Bin on your fixed drives	Tout ce qui est dans la Corbeille de vos disques fixes
Everything known about the highlighted program	Tout ce qu’on sait du programme en surbrillance
Everything looks good. Nothing was changed on this PC.	Tout semble bien. Rien n’a été changé sur ce PC.
Everything on that stick will be erased.	Tout ce qui est sur cette clé sera effacé.
Everything on the USB is erased. It starts this PC only.	Tout ce qui est sur la clé USB est effacé. Elle démarre seulement ce PC.
Everything the Cleaner can switch on is already on. Nothing was changed.	Tout ce que le Cleaner peut activer est déjà actif. Rien n’a été changé.
Excel spreadsheet	Feuille de calcul Excel
Exit	Quitter
Expert	Expert
Expired	Expiré
Export	Exporter
Export the list	Exporter la liste
Export the list...	Exporter la liste...
Extended	Étendu
FILES TICKED	FICHIERS COCHÉS
FIX & PROTECT	RÉPARER ET PROTÉGER
FIXING WINDOWS	RÉPARATION DE WINDOWS
FLAC audio	Audio FLAC
FREE SPACE	ESPACE LIBRE
FREE TRY	ESSAI GRATUIT
FREES SPACE	LIBÈRE DE L’ESPACE
Fail-safe with network	Mode sans échec avec réseau
Failed	Échoué
Fallback report error:	Erreur du rapport de secours :
Feeding the hamsters that run Windows...	On nourrit les hamsters qui font tourner Windows...
File Explorer search history	Historique de recherche de l’Explorateur de fichiers
File type	Type de fichier
Files and passwords stay safe unless you tick them.	Les fichiers et mots de passe restent protégés, sauf si vous les cochez.
Filtering	Filtrage
Find duplicate files	Trouver les fichiers en double
Find duplicate files, speed and space, security, drive and memory checks, Hibernate, app updates and more.	Fichiers en double, vitesse et espace, sécurité, vérification des disques et de la mémoire, veille prolongée, mises à jour des applis et plus encore.
Find large files	Trouver les gros fichiers
Finds files that are 100% identical - same size, same SHA-256, then verified byte-for-byte - and keeps one copy of each set.	Trouve les fichiers identiques à 100 % - même taille, même SHA-256, puis vérifiés octet par octet - et garde une copie de chaque groupe.
Finished. Click to see it	Terminé. Cliquez pour le voir
Finished. Removed {0} items.	Terminé. {0} éléments retirés.
Firefox: turn AI back on	Firefox : réactiver l’IA
Firefox: turn off AI	Firefox : désactiver l’IA
Firefox: uninstall completely	Firefox : désinstaller complètement
Firewall	Pare-feu
Firewall: OFF for {0} networks.	Pare-feu : DÉSACTIVÉ pour les réseaux {0}.
Firewall: Windows did not report whether its firewall is on.	Pare-feu : Windows n’a pas indiqué si son pare-feu est actif.
Firewall: on for all networks.	Pare-feu : actif pour tous les réseaux.
Firewall: {0} is protecting this PC.	Pare-feu : {0} protège ce PC.
First the Rescue system is made on this PC. Microsoft's Windows ADK and Windows PE add-on are downloaded from Microsoft (a big download - keep the internet on). Microsoft's own installers open: follow them and accept Microsoft's licence terms there. This happens only once on this PC.	D’abord, le système de secours est créé sur ce PC. Le Windows ADK et le module Windows PE sont téléchargés depuis Microsoft (gros téléchargement - gardez Internet allumé). Les installateurs de Microsoft s’ouvrent : suivez-les et acceptez-y les termes de licence de Microsoft. Cela n’arrive qu’une fois sur ce PC.
Fix Windows	Réparer Windows
Fix Windows problems	Réparer les problèmes de Windows
Fixed	Réglé
Flash video	Vidéo Flash
Flush DNS resolver cache	Vider le cache DNS
Folder	Dossier
Folder or file	Dossier ou fichier
Follow the installer. When it has finished, this carries on by itself.	Suivez l’installateur. Quand il aura fini, ceci continuera tout seul.
Follow the steps in its own uninstaller if one opens.	Suivez les étapes de son propre programme de désinstallation s’il s’ouvre.
Font cache reset	Réinitialisation du cache des polices
Font cache reset ({0} file(s) removed). Restart Windows so every program picks up the fresh cache.	Cache des polices réinitialisé ({0} fichier(s) retiré(s)). Redémarrez Windows pour que chaque programme utilise le nouveau cache.
For a program that is already gone, broken or will not uninstall. Type its name, then review the leftovers before anything is deleted.	Pour un programme déjà parti, brisé ou qui refuse de se désinstaller. Tapez son nom, puis vérifiez les restes avant que quoi que ce soit soit supprimé.
For experts	Pour experts
Force stop now	Forcer l’arrêt maintenant
Forced	Forcé
Forced Uninstall	Désinstallation forcée
Forced uninstall...	Désinstallation forcée...
Forced uninstaller	Désinstallation forcée
Free space on {0} {1}% ({2} of {3})	Espace libre sur {0} {1} % ({2} sur {3})
Free try - pick one category, then press Scan.	Essai gratuit - choisissez une catégorie, puis appuyez sur Analyser.
Free try - this is the category you picked.	Essai gratuit - c’est la catégorie que vous avez choisie.
Free try - you picked this category already.	Essai gratuit - vous avez déjà choisi cette catégorie.
Free up memory	Libérer de la mémoire
Free up memory (Boost)	Libérer de la mémoire (Boost)
Freed about {0} of memory from {1} program(s). Nothing was closed. Free memory is now {2} of {3}.	Environ {0} de mémoire libérés de {1} programme(s). Rien n’a été fermé. La mémoire libre est maintenant de {2} sur {3}.
Freed {0} by deleting the AI model downloaded by {1}. If "turn off" is not also done for that browser, it downloads the model again.	{0} libérés en supprimant le modèle d’IA téléchargé par {1}. Si « désactiver » n’est pas fait aussi pour ce navigateur, il retélécharge le modèle.
From:  {0}	De :  {0}
From: {0}	De : {0}
Full	Complet
Full cleanup: Safe plus Windows Disk Cleanup and game launcher caches.	Nettoyage complet : Sûr, plus le Nettoyage de disque Windows et les caches des lanceurs de jeux.
Full path to program's file or folder:	Chemin complet du fichier ou du dossier du programme :
Full scan	Analyse complète
Full scan:	Analyse complète :
Full scan: never - overdue	Analyse complète : jamais - en retard
Full scan: {0} - due in {1}	Analyse complète : {0} - prévue dans {1}
Full scan: {0} - next in {1}	Analyse complète : {0} - prochaine dans {1}
Full scan: {0} - overdue by {1}	Analyse complète : {0} - en retard de {1}
GIF image	Image GIF
Game launcher caches	Caches des lanceurs de jeux
Games rebuild these by themselves	Les jeux les refont eux-mêmes
Gemini and AI Mode are now off in Chrome. Close Chrome completely and open it again.	Gemini et le mode IA sont maintenant désactivés dans Chrome. Fermez Chrome complètement et rouvrez-le.
Gemini in Gmail, AI in Zoom, Copilot in Word and Excel, and the Edge Copilot button are settings the Cleaner cannot read, so they are not listed.	Gemini dans Gmail, l’IA dans Zoom, Copilot dans Word et Excel, et le bouton Copilot d’Edge sont des réglages que le Cleaner ne peut pas lire, donc ils ne sont pas listés.
Getting Microsoft's Windows ADK. Microsoft's installer opens - follow it (keep Deployment Tools ticked).	Téléchargement du Windows ADK de Microsoft. L’installateur de Microsoft s’ouvre - suivez-le (gardez « Outils de déploiement » coché).
Getting Microsoft's Windows PE add-on. Microsoft's installer opens - follow it.	Téléchargement du module Windows PE de Microsoft. L’installateur de Microsoft s’ouvre - suivez-le.
Getting the new version of the DRDirect Uninstaller Program.	Téléchargement de la nouvelle version du programme de désinstallation DRDirect.
Gmail settings are open in the web browser. Sign in if asked, tick the Smart features boxes, then click Save changes at the bottom of the page.	Les paramètres de Gmail sont ouverts dans le navigateur. Connectez-vous si on vous le demande, cochez les cases des fonctionnalités intelligentes, puis cliquez sur Enregistrer les modifications en bas de la page.
Gmail settings are open in the web browser. Sign in if asked, untick the Smart features boxes, then click Save changes at the bottom of the page.	Les paramètres de Gmail sont ouverts dans le navigateur. Connectez-vous si on vous le demande, décochez les cases des fonctionnalités intelligentes, puis cliquez sur Enregistrer les modifications en bas de la page.
Gmail, Zoom, Word and Excel and the Edge button cannot be read from here.	Gmail, Zoom, Word, Excel et le bouton Edge ne peuvent pas être lus d’ici.
Gmail: turn Gemini back on	Gmail : réactiver Gemini
Gmail: turn off Gemini	Gmail : désactiver Gemini
Go	Aller
Go all the way up to the top of the page	Remonter tout en haut de la page
Go back	Retour
Good	Bon
Google Drive cache	Cache de Google Drive
Graphics	Graphique
Graphics shader cache	Cache des shaders graphiques
Group	Groupe
Groups	Groupes
Groups of identical files	Groupes de fichiers identiques
Guided	Guidé
HEIC photo	Photo HEIC
HEIF photo	Photo HEIF
HERE IS WHAT WILL CHANGE	VOICI CE QUI VA CHANGER
HISTORY & UNDO	HISTORIQUE ET ANNULATION
Hardware	Matériel
Health	Santé
Health check	Vérification de santé
Healthy	En bonne santé
Help me write	Aide-moi à écrire
Here is what will change. Nothing has run yet.	Voici ce qui va changer. Rien n’a encore été fait.
Hibernate	Veille prolongée
Hibernate and Fast Startup are back on.	La veille prolongée et le démarrage rapide sont réactivés.
Hibernate and Fast Startup are off and the hibernation file was removed. Sleep still works. Use "Turn Hibernate back on" to undo this.	La veille prolongée et le démarrage rapide sont désactivés et le fichier de veille prolongée a été retiré. La mise en veille fonctionne toujours. Utilisez « Réactiver la veille prolongée » pour annuler.
Hibernate is already off on this PC	La veille prolongée est déjà désactivée sur ce PC
Hibernate saves your session to a file on C: so Windows can start fast. Turn it off to free several GB, or back on again. Pick one: they undo each other.	La veille prolongée enregistre votre session dans un fichier sur C: pour que Windows démarre vite. Désactivez-la pour libérer plusieurs Go, ou réactivez-la. Choisissez l’un des deux : ils s’annulent.
Hibernate was NOT turned on. It needs about {0} free on {1}, and only {2} is free. Use Sleep instead (Start, Power, Sleep): it needs no disk space and wakes up fast.	La veille prolongée N’A PAS été activée. Il faut environ {0} de libre sur {1}, et il n’y a que {2} de libre. Utilisez plutôt la mise en veille (Démarrer, Marche/Arrêt, Mettre en veille) : elle ne prend pas d’espace disque et se réveille vite.
Hibernation file (frees several GB)	Fichier de veille prolongée (libère plusieurs Go)
Hidden Recycle Bin folders	Dossiers cachés de la Corbeille
Hide programs published by Microsoft	Masquer les programmes publiés par Microsoft
Hide published by Microsoft	Masquer ceux de Microsoft
Highlight certified uninstallers	Surligner les désinstalleurs certifiés
Highlight certified, missing and special uninstallers	Surligner les désinstalleurs certifiés, manquants et spéciaux
Highlight missing uninstallers	Surligner les désinstalleurs manquants
Highlight special uninstallers	Surligner les désinstalleurs spéciaux
History	Historique
History refresh warning: {0}	Avertissement de mise à jour de l’historique : {0}
History, icons and autofill only - nothing is deleted	Historique, icônes et saisie automatique seulement - rien n’est supprimé
Hitting it with a very small hammer...	Petit coup de marteau, tout doucement...
Home	Accueil
Hosts file blocks {0} site(s). That is normal if you or a blocker added them.	Le fichier hosts bloque {0} site(s). C’est normal si vous ou un bloqueur les avez ajoutés.
Hosts file sends a site somewhere else: {0}	Le fichier hosts envoie un site ailleurs : {0}
Hosts file: no redirects to other addresses.	Fichier hosts : aucune redirection vers d’autres adresses.
I clear the junk, fix what is broken and give your PC a good tune-up, and I really am trying to make it last longer. I am not perfect, you know, but I am doing my best to keep it alive. But sometimes I have to say what nobody wants to hear: an old PC can only do so much.	Je vide les déchets, je répare ce qui est brisé et je donne une bonne mise au point à votre PC, et j’essaie vraiment de le faire durer plus longtemps. Je ne suis pas parfait, vous savez, mais je fais de mon mieux pour le garder en vie. Mais parfois je dois dire ce que personne ne veut entendre : un vieux PC a ses limites.
I have looked at these files and agree to remove the ticked duplicates	J’ai regardé ces fichiers et j’accepte de retirer les doublons cochés
I reviewed this plan and approve the selected changes.	J’ai lu ce plan et j’approuve les changements choisis.
I will restart myself, when I am ready	Je redémarrerai moi-même, quand je serai prêt
Icon cache	Cache des icônes
If it did not do the job, or you want your PC spotless, use DRDirect PC Cleaner for a deeper clean-up.	Si cela n’a pas suffi, ou si vous voulez un PC impeccable, utilisez DRDirect Nettoyeur PC pour un nettoyage plus profond.
If the Copilot button still shows on the toolbar, open Edge Settings, search for "Copilot" and switch the button off.	Si le bouton Copilot apparaît encore dans la barre d’outils, ouvrez les Paramètres d’Edge, cherchez « Copilot » et désactivez le bouton.
If you have not done a full scan for a while, please do one. A full scan reads every file, so it is a long scan. You can keep using the PC while it runs, but it may feel slower. Only tick it if you are ready to wait.	Si vous n’avez pas fait d’analyse complète depuis un moment, faites-en une. Une analyse complète lit chaque fichier, donc elle est longue. Vous pouvez continuer à utiliser le PC pendant ce temps, mais il peut sembler plus lent. Cochez-la seulement si vous êtes prêt à attendre.
If you press No, the red and blue lights stay on until the scan is done.	Si vous appuyez sur Non, les lumières rouge et bleue restent allumées jusqu’à ce que l’analyse soit faite.
Ignore files smaller than	Ignorer les fichiers de moins de
Image file:      {0}	Fichier :        {0}
Image:  {0}	Sauvegarde :  {0}
Imaging	Sauvegarde en cours
Improve inking and typing	Améliorer l’écriture manuscrite et la saisie
In 10 minutes after it finishes	10 minutes après la fin
In 5 minutes after it finishes	5 minutes après la fin
In it: accept the licence, choose USB flash drive, then pick your USB stick of 8 GB or more.	Dedans : acceptez la licence, choisissez « Disque mémoire flash USB », puis votre clé USB de 8 Go ou plus.
In use now: {0} of {1} ({2}%).	Utilisé maintenant : {0} sur {1} ({2} %).
Include OneDrive / Google Drive / iCloud files	Inclure les fichiers OneDrive / Google Drive / iCloud
Include cloud files from	Inclure les fichiers infonuagiques de
Include subfolders	Inclure les sous-dossiers
Included with a full code. The free try covers the Safe scan.	Inclus avec un code complet. L’essai gratuit couvre l’analyse Sûre.
Info	Info
Information	Information
Inking & typing personalization	Personnalisation de l’écriture manuscrite et de la saisie
Install Date	Date d’installation
Install a program (with tracking)...	Installer un programme (avec suivi)...
Install date	Date d’installation
Install folder	Dossier d’installation
Install it now? The Cleaner downloads Microsoft's own installer (about 20 MB) from aka.ms/getwinget, installs it, then continues.	L’installer maintenant ? Le Cleaner télécharge l’installateur de Microsoft (environ 20 Mo) depuis aka.ms/getwinget, l’installe, puis continue.
Install records (*.txt)|*.txt	Relevés d’installation (*.txt)|*.txt
Install these from Settings, Windows Update, Advanced options, Optional updates. This app does not install them.	Installez-les depuis Paramètres, Windows Update, Options avancées, Mises à jour facultatives. Cette appli ne les installe pas.
Install with tracking	Installer avec suivi
Installed	Installé
Installed (with warnings)	Installé (avec avertissements)
Installed in the last 30 days (check you recognise them):	Installés dans les 30 derniers jours (vérifiez que vous les reconnaissez) :
Installed memory	Mémoire installée
Installed on	Installé le
Installer	Installateur
Installing the update	Installation de la mise à jour
Installing winget from Microsoft in a console window. It then runs the update by itself.	Installation de winget depuis Microsoft dans une fenêtre de console. Il lance ensuite la mise à jour tout seul.
Installing winget...	Installation de winget...
Installs a program and records everything it adds, so it can be fully removed later.	Installe un programme et note tout ce qu’il ajoute, pour pouvoir le retirer complètement plus tard.
Installs the Recall feature in Windows again. Takes effect after a restart.	Réinstalle la fonction Recall dans Windows. S’applique après un redémarrage.
Invert the ticks	Inverser les coches
It also installs PowerShell 7 and Windows Terminal if this PC does not have them.	Il installe aussi PowerShell 7 et Windows Terminal si ce PC ne les a pas.
It cannot be undone.	Cela ne peut pas être annulé.
It cannot be undone. Files, programs, passwords and logins are not touched.	Cela ne peut pas être annulé. Les fichiers, programmes, mots de passe et connexions ne sont pas touchés.
It did not finish: {0}	Cela n’a pas pu se terminer : {0}
It erases every trace of the websites you have visited, in every browser, and wipes the free space so nothing can be recovered.	Cela efface toute trace des sites que vous avez visités, dans tous les navigateurs, et nettoie l’espace libre pour que rien ne puisse être récupéré.
It happens to every PC, and to all of us. As we get older, we get slower too. We all take longer to get going in the morning, we all forget things for no reason, and we all groan when someone asks too much at once.	Ça arrive à tous les PC, et à nous tous. En vieillissant, on ralentit aussi. On met tous plus de temps à démarrer le matin, on oublie tous des choses sans raison, et on râle tous quand on nous en demande trop à la fois.
It is done.	C’est fait.
It is installed, and has its own activation code. Open it now to enter that code?	Il est installé et a son propre code d’activation. L’ouvrir maintenant pour entrer ce code ?
It needs a {0} ISO file on this PC. Microsoft's Media Creation Tool can make one: choose ISO file in it.	Il faut un fichier ISO de {0} sur ce PC. L’outil de création de média de Microsoft peut en faire un : choisissez « Fichier ISO » dedans.
It passed last time. A week has gone by, so it is time to check again.	Tout allait bien la dernière fois. Une semaine a passé, il est temps de revérifier.
It ran for {0} before it stopped.	Cela a tourné {0} avant de s’arrêter.
It will show "Managed by your organization" - that is what keeps the AI off. "Turn back on" removes it.	Il affichera « Géré par votre organisation » - c’est ce qui garde l’IA désactivée. « Réactiver » l’enlève.
Item path	Chemin de l’élément
Items	Éléments
Its leftovers are still looked for next.	Ses restes seront quand même recherchés ensuite.
Its logs in {0}	Ses journaux dans {0}
Its settings, logs and the DRDirect Uninstaller in {0}	Ses réglages, journaux et le désinstalleur DRDirect dans {0}
Its uninstaller is missing ({0}). Use the Forced uninstaller to remove what is left of it.	Son programme de désinstallation est introuvable ({0}). Utilisez la désinstallation forcée pour retirer ce qui en reste.
JPEG photo	Photo JPEG
Jump lists and recent items	Listes de raccourcis et éléments récents
KEEP APPS CURRENT	GARDER LES APPLIS À JOUR
KEEP THIS ONE	GARDER CELUI-CI
Keep it somewhere safe. If you lose it or it breaks, come back here and make a new one.	Gardez-la en lieu sûr. Si vous la perdez ou si elle brise, revenez ici en créer une nouvelle.
Keep the 'DRDirect Uninstaller' folder in the same folder as the Cleaner, then try again.	Gardez le dossier « DRDirect Uninstaller » dans le même dossier que le Cleaner, puis réessayez.
Kind	Type
Known unwanted program installed: {0}	Programme indésirable connu installé : {0}
LAST CLEAN	DERNIER MÉNAGE
LONG CLEAN-UP	NETTOYAGE LONG
LONG REPAIR	RÉPARATION LONGUE
LONG SCAN	ANALYSE LONGUE
LONG TEST	TEST LONG
Last checked {0}	Dernière vérification : {0}
Last checked {0}. It needs to be checked again. Click to check.	Dernière vérification : {0}. Il faut revérifier. Cliquez pour vérifier.
Last checked {0}. It was fine. A week has gone by, so it is time to check again.	Dernière vérification : {0}. Tout allait bien. Une semaine a passé, il est temps de revérifier.
Last checked {0}: all good. You can check again any time.	Dernière vérification {0} : tout va bien. Vous pouvez revérifier à tout moment.
Last checked {0}: something needs attention. Click to check again.	Dernière vérification {0} : quelque chose demande votre attention. Cliquez pour revérifier.
Last done: {0}	Dernière fois : {0}
Last time these took	La dernière fois, cela a pris
Last time took	La dernière fois
Last time took ...	La dernière fois ...
Left behind by an earlier Windows Update fix	Laissé par une ancienne réparation de Windows Update
Left unticked on purpose. Before you tick it yourself on the Cleanup page, make sure you know all your email addresses and passwords, and keep them in a safe place. You may have to sign in again.	Laissé décoché exprès. Avant de le cocher vous-même dans la page Nettoyage, assurez-vous de connaître toutes vos adresses courriel et vos mots de passe, et gardez-les en lieu sûr. Vous devrez peut-être vous reconnecter.
Leftover removal	Retrait des restes
Legend	Légende
Leo AI is now off in Brave. Close Brave completely and open it again.	Leo AI est maintenant désactivé dans Brave. Fermez Brave complètement et rouvrez-le.
Life left: about {0}%	Vie restante : environ {0} %
Life left: not measured for spinning hard drives. Health status and error counts below are what matter.	Vie restante : non mesurée pour les disques durs à plateaux. L’état de santé et le nombre d’erreurs ci-dessous sont ce qui compte.
Life left: this drive does not report it.	Vie restante : ce disque ne l’indique pas.
List of files and/or registry keys left after uninstallation	Liste des fichiers et clés de registre restés après la désinstallation
List view settings	Réglages de l’affichage en liste
Listing available updates in a console window. Nothing is installed.	Liste des mises à jour disponibles dans une fenêtre de console. Rien n’est installé.
Listing files...	Liste des fichiers...
Listing files... {0} found	Liste des fichiers... {0} trouvés
Lists the 25 biggest files (over 100 MB) in your user folders so you can decide what to remove. Only looks - nothing is deleted.	Liste les 25 plus gros fichiers (plus de 100 Mo) de vos dossiers personnels pour que vous décidiez quoi retirer. Regarde seulement - rien n’est supprimé.
Lists the folders, programs and file types Microsoft Defender skips, and points out any that look risky. Nothing is removed - exclusions you added on purpose always stay.	Liste les dossiers, programmes et types de fichiers que Microsoft Defender ignore, et signale ceux qui semblent risqués. Rien n’est retiré - les exclusions ajoutées exprès restent toujours.
Lists the programs that start with Windows so you can see what slows sign-in. Only looks - nothing is changed.	Liste les programmes qui démarrent avec Windows pour voir ce qui ralentit l’ouverture de session. Regarde seulement - rien n’est changé.
Loading the list:	Chargement de la liste :
Logs	Journaux
Long	Long
Long-running Windows commands finish before the next task begins.	Les longues commandes Windows se terminent avant que la tâche suivante commence.
Look again	Regarder de nouveau
Look again, for example after fixing something. Nothing is changed.	Regarder de nouveau, par exemple après avoir réglé quelque chose. Rien n’est changé.
Look at what the Cleaner did before.	Voir ce que le Cleaner a fait avant.
Look for	Rechercher
Look for a newer version of the Cleaner	Chercher une version plus récente du Cleaner
Look for a newer version of the Cleaner.	Chercher une version plus récente du Cleaner.
Look for leftovers in all Windows accounts	Chercher des restes dans tous les comptes Windows
Looking at the drive...	Examen du disque...
Looking for Windows updates...	Recherche des mises à jour Windows...
Looking for leftovers	Recherche des restes
Looking for what was left behind. Please wait...	Recherche de ce qui est resté. Veuillez patienter...
Looking through your files.	Examen de vos fichiers.
Looks for PHP on this PC (XAMPP, WAMP, Laragon and similar) and tells you if it is open to the PHP2Shell flaw that is being attacked right now. Only looks - nothing is changed.	Cherche PHP sur ce PC (XAMPP, WAMP, Laragon et autres) et vous dit s’il est exposé à la faille PHP2Shell, attaquée en ce moment. Regarde seulement - rien n’est changé.
Looks for signs of a failing power supply or a PC that runs too hot: unexpected shutdowns, hardware errors, temperature and heat slowdowns in the last 30 days. Heat is also a common cause of lag in games. It can only point to a likely cause, such as dust or a tired power supply. Nothing is changed.	Cherche des signes d’alimentation défaillante ou d’un PC qui chauffe trop : arrêts inattendus, erreurs matérielles, température et ralentissements dus à la chaleur dans les 30 derniers jours. La chaleur est aussi une cause fréquente de ralentissement dans les jeux. Il ne peut qu’indiquer une cause probable, comme la poussière ou une alimentation fatiguée. Rien n’est changé.
Looks for signs of a failing power supply, dust or a PC that runs too hot	Cherche des signes d’alimentation défaillante, de poussière ou d’un PC qui chauffe trop
Looks for signs of spyware and adware and shows a list. Nothing is ever changed or removed, because some of these can be normal on your PC.	Cherche des signes de logiciels espions et publicitaires et en montre la liste. Rien n’est jamais changé ni retiré, car certains peuvent être normaux sur votre PC.
Lost it or broken later? Come back here and make a new one.	Perdue ou brisée plus tard ? Revenez ici en créer une nouvelle.
Lost it or broken? Make a new one here, any time.	Perdue ou brisée ? Créez-en une nouvelle ici, à tout moment.
MAX  -  fastest (bigger file)	MAX  -  le plus rapide (fichier plus gros)
MEDIUM SCAN	ANALYSE MOYENNE
MEGA cache	Cache de MEGA
MIDI music	Musique MIDI
MKV video	Vidéo MKV
MPEG video	Vidéo MPEG
MS Tools	Outils MS
Made a mistake? Click "Undo last removal" within {0} hours to put everything back.	Une erreur ? Cliquez sur « Annuler le dernier retrait » dans les {0} heures pour tout remettre en place.
Maintenance complete	Entretien terminé
Maintenance finished with warnings	Entretien terminé avec des avertissements
Maintenance finished, but the report could not be saved: {0}	Entretien terminé, mais le rapport n’a pas pu être enregistré : {0}
Maintenance finished. No report path was returned.	Entretien terminé. Aucun chemin de rapport n’a été retourné.
Maintenance progress	Progression de l’entretien
Make a Windows 11 install USB?	Créer une clé USB d’installation de Windows 11 ?
Make and model	Marque et modèle
Make my PC cleaner	Nettoyer mon PC
Makes a USB stick that can start this PC even when Windows will not start, so you can still copy, save or put back your drive.	Crée une clé USB qui peut démarrer ce PC même quand Windows ne démarre plus, pour pouvoir quand même copier, sauvegarder ou restaurer votre disque.
Makes a Windows 11 install USB with Microsoft's own Media Creation Tool. Needs a USB stick of at least 8 GB. Everything on that stick is erased.	Crée une clé USB d’installation de Windows 11 avec l’outil de création de média de Microsoft. Il faut une clé USB d’au moins 8 Go. Tout ce qui est sur cette clé est effacé.
Makes an exact copy of one drive on another drive: Windows, programs and files. Only the used parts are copied, so it is fast.	Fait une copie exacte d’un disque sur un autre : Windows, programmes et fichiers. Seules les parties utilisées sont copiées, donc c’est rapide.
Makes sure a backup file is complete and not damaged. Nothing is changed.	Vérifie qu’un fichier de sauvegarde est complet et non endommagé. Rien n’est changé.
Making a Rescue USB ERASES the USB stick you pick. Everything on it now (files, photos, documents) will be deleted and cannot be brought back.	Créer une clé USB de secours EFFACE la clé choisie. Tout ce qui s’y trouve (fichiers, photos, documents) sera supprimé et ne pourra pas être récupéré.
Making a Windows restore point first, so this can be undone...	Création d’un point de restauration Windows d’abord, pour pouvoir annuler...
Making the Rescue system failed (DISM code {0}). Nothing was changed on the USB.	La création du système de secours a échoué (code DISM {0}). Rien n’a été changé sur la clé USB.
Making the Rescue system failed (copype). Nothing was changed on the USB.	La création du système de secours a échoué (copype). Rien n’a été changé sur la clé USB.
Making the Rescue system: adding the DRDirect Rescue app...	Création du système de secours : ajout de l’appli de secours DRDirect...
Making the Rescue system: adding {0}...	Création du système de secours : ajout de {0}...
Making the Rescue system: saving it...	Création du système de secours : enregistrement...
Making the Rescue system: the base...	Création du système de secours : la base...
Manage large files	Gérer les gros fichiers
Managed by your organization	Géré par votre organisation
Manufacturer	Fabricant
Many startup programs can slow sign-in.	Beaucoup de programmes au démarrage peuvent ralentir l’ouverture de session.
Max 3D	3D maximum
Medium	Moyen
Memory	Mémoire
Memory (RAM): NO PROBLEMS FOUND	Mémoire (RAM) : AUCUN PROBLÈME TROUVÉ
Memory (RAM): PROBLEM FOUND	Mémoire (RAM) : PROBLÈME TROUVÉ
Memory (RAM): SERIOUS PROBLEM	Mémoire (RAM) : PROBLÈME GRAVE
Memory dump files	Fichiers de vidage de mémoire
Memory in use: {0}% ({1} free of {2})	Mémoire utilisée : {0} % ({1} libres sur {2})
Memory is almost full. Close programs you are not using, or use "Free up memory (Boost)".	La mémoire est presque pleine. Fermez les programmes que vous n’utilisez pas, ou utilisez « Libérer de la mémoire (Boost) ».
Memory is nearly full. Run "Free up memory" or close programs you are not using.	La mémoire est presque pleine. Lancez « Libérer de la mémoire » ou fermez les programmes que vous n’utilisez pas.
Memory stick	Barrette de mémoire
Memory test	Test de la mémoire
Memory test (Windows Memory Diagnostic)	Test de la mémoire (Diagnostic de mémoire Windows)
Menu error:	Erreur de menu :
Message	Message
Microsoft 365 Copilot app	Appli Microsoft 365 Copilot
Microsoft 365 Copilot app: uninstall completely	Appli Microsoft 365 Copilot : désinstaller complètement
Microsoft Defender is not available on this PC, so there are no Defender exclusions to check.	Microsoft Defender n’est pas disponible sur ce PC, donc il n’y a aucune exclusion de Defender à vérifier.
Microsoft Defender real-time protection	Protection en temps réel de Microsoft Defender
Microsoft Store cache	Cache du Microsoft Store
Microsoft has no newer drivers for this PC.	Microsoft n’a pas de pilotes plus récents pour ce PC.
Microsoft's Media Creation Tool could not be downloaded.	L’outil de création de média de Microsoft n’a pas pu être téléchargé.
Microsoft's Media Creation Tool could not be opened: {0}	L’outil de création de média de Microsoft n’a pas pu être ouvert : {0}
Microsoft's Media Creation Tool is opening (click Yes if Windows asks).	L’outil de création de média de Microsoft s’ouvre (cliquez sur Oui si Windows le demande).
Microsoft's Media Creation Tool is still downloading. It opens by itself when it is ready.	L’outil de création de média de Microsoft est encore en téléchargement. Il s’ouvrira tout seul quand il sera prêt.
Microsoft's Media Creation Tool only makes Windows 11 USBs for 64-bit Intel and AMD PCs, and this PC is not one.	L’outil de création de média de Microsoft ne crée des clés USB Windows 11 que pour les PC Intel et AMD 64 bits, et ce PC n’en est pas un.
Microsoft's Media Creation Tool will be downloaded from Microsoft and opened. In it:	L’outil de création de média sera téléchargé depuis Microsoft et ouvert. Dedans :
Microsoft's Windows ADK (Deployment Tools) was not installed, so the Rescue system could not be made. Nothing was changed on the USB.	Le Windows ADK de Microsoft (Outils de déploiement) n’a pas été installé, donc le système de secours n’a pas pu être créé. Rien n’a été changé sur la clé USB.
Microsoft's Windows PE add-on was not installed, so the Rescue system could not be made. Nothing was changed on the USB.	Le module Windows PE de Microsoft n’a pas été installé, donc le système de secours n’a pas pu être créé. Rien n’a été changé sur la clé USB.
Microsoft's licence terms for the updates are accepted, the same as Windows Update in Settings does.	Les termes de licence de Microsoft pour les mises à jour sont acceptés, comme le fait Windows Update dans Paramètres.
Microsoft's tool then downloads Windows, so it needs the internet.	L’outil de Microsoft télécharge ensuite Windows, donc il faut Internet.
Missing	Manquant
Missing control {0}	Contrôle manquant {0}
Missing uninstaller	Désinstalleur manquant
Model	Modèle
Model: unknown - this dock does not let Windows ask the drive inside its make and model.	Modèle : inconnu - cette station d’accueil ne laisse pas Windows demander au disque sa marque et son modèle.
More above	Plus haut
More below	Plus bas
More info - click here	Plus d’infos - cliquez ici
More options: choose how deep to clean, and see recent changes	Plus d’options : choisissez la profondeur du nettoyage et voyez les changements récents
More than one USB flash drive is plugged in. Pick the one to use.	Plus d’une clé USB est branchée. Choisissez celle à utiliser.
More tools below	Plus d’outils plus bas
Motherboard	Carte mère
Motherboard and BIOS	Carte mère et BIOS
Motherboard drivers	Pilotes de la carte mère
Move ticked duplicates to Recycle Bin	Mettre les doublons cochés dans la Corbeille
Moved to Recycle Bin	Mis dans la Corbeille
Moved {0} duplicates to the Recycle Bin, freeing {1}{2}	{0} doublons mis dans la Corbeille, {1} libérés{2}
Music	Musique
Music & audio	Musique et audio
My Games	Mes jeux
My goal is simple: to make Windows run better on every PC.	Mon but est simple : faire mieux fonctionner Windows sur chaque PC.
NEEDS UPDATE	MISE À JOUR NÉCESSAIRE
NEW RESCUE USB	NOUVELLE CLÉ USB DE SECOURS
NEW UPDATE	NOUVELLE MISE À JOUR
NO PROBLEMS FOUND	AUCUN PROBLÈME TROUVÉ
NO PROBLEMS FOUND: every PHP install found has the fix. Nothing was changed.	AUCUN PROBLÈME TROUVÉ : chaque installation de PHP trouvée a le correctif. Rien n’a été changé.
NO PROBLEMS REPORTED	AUCUN PROBLÈME SIGNALÉ
NVMe SSD speed	Vitesse du SSD NVMe
Name	Nom
Network	Réseau
Network reset	Réinitialisation du réseau
New update	Nouvelle mise à jour
Next	Suivant
Nikon RAW photo	Photo RAW Nikon
No	Non
No AI models on this PC	Aucun modèle d’IA sur ce PC
No AI that the Cleaner can switch off is still on.	Aucune IA que le Cleaner peut désactiver n’est encore active.
No AI that the Cleaner can switch off was found. Nothing was changed.	Aucune IA que le Cleaner peut désactiver n’a été trouvée. Rien n’a été changé.
No GPT partition table was found.	Aucune table de partitions GPT n’a été trouvée.
No NTFS partition was found on the source drive to make smaller.	Aucune partition NTFS à réduire n’a été trouvée sur le disque source.
No PC lock key.	Aucune clé de verrouillage du PC.
No PHP was found on this PC, so the PHP security flaw (PHP2Shell) cannot be used against it. Nothing was changed.	Aucun PHP n’a été trouvé sur ce PC, donc la faille de sécurité PHP (PHP2Shell) ne peut pas être utilisée contre lui. Rien n’a été changé.
No Steam or Epic launcher caches were found on this PC.	Aucun cache de lanceur Steam ou Epic n’a été trouvé sur ce PC.
No USB stick was found.	Aucune clé USB n’a été trouvée.
No additional tasks were started.	Aucune autre tâche n’a été lancée.
No component store corruption detected	Aucune corruption du magasin de composants détectée
No developer tool caches were found on this PC.	Aucun cache d’outils de développement n’a été trouvé sur ce PC.
No downloaded AI models were found. Nothing was deleted.	Aucun modèle d’IA téléchargé n’a été trouvé. Rien n’a été supprimé.
No drives reported health information. This can happen with some USB and RAID controllers. Nothing was changed.	Aucun disque n’a donné d’information de santé. Cela peut arriver avec certains contrôleurs USB et RAID. Rien n’a été changé.
No duplicates found	Aucun doublon trouvé
No exact duplicates found.	Aucun doublon exact trouvé.
No files over 100 MB were found in your user folders. Nothing was changed.	Aucun fichier de plus de 100 Mo n’a été trouvé dans vos dossiers personnels. Rien n’a été changé.
No font cache folder was found. Nothing was changed.	Aucun dossier de cache des polices n’a été trouvé. Rien n’a été changé.
No graphics shader caches were found on this PC.	Aucun cache de shaders graphiques n’a été trouvé sur ce PC.
No maintenance reports yet.	Aucun rapport d’entretien pour l’instant.
No memory for the copy buffer.	Pas assez de mémoire pour la copie.
No other drive to save on.	Aucun autre disque où enregistrer.
No overheating, no sudden shut-offs, no hardware problems, no programs crashing again and again, and no failed Windows updates in the last 30 days. Nothing to worry about.	Aucune surchauffe, aucun arrêt soudain, aucun problème matériel, aucun programme qui plante à répétition et aucune mise à jour Windows échouée dans les 30 derniers jours. Rien d’inquiétant.
No path given.	Aucun chemin donné.
No problems found. Nothing was changed on this PC.	Aucun problème trouvé. Rien n’a été changé sur ce PC.
No programs are set to start with Windows from the usual places. Nothing was changed.	Aucun programme n’est réglé pour démarrer avec Windows aux endroits habituels. Rien n’a été changé.
No restore point was saved (System Restore may be off). The Cleaner keeps its own backups of the settings it changes.	Aucun point de restauration n’a été créé (la Restauration du système est peut-être désactivée). Le Cleaner garde ses propres copies des réglages qu’il change.
No restore point:	Pas de point de restauration :
No scan yet	Aucune analyse encore
No steps are available on this PC.	Aucune étape n’est disponible sur ce PC.
No subfolders in here.	Aucun sous-dossier ici.
No supported web browser was found. Nothing was changed.	Aucun navigateur pris en charge n’a été trouvé. Rien n’a été changé.
No task events were returned.	Aucun événement de tâche n’a été retourné.
No: a normal backup (it can only go back onto a drive as big as this one).	Non : une sauvegarde normale (elle ne peut être remise que sur un disque aussi grand que celui-ci).
None	Aucun
None of these are installed on this PC. Install the app for a service and sign in - signing in on its website is not enough.	Aucun n’est installé sur ce PC. Installez l’application d’un service et connectez-vous - se connecter sur son site Web ne suffit pas.
Normal	Normal
Not a full path:	Pas un chemin complet :
Not checked	Non vérifié
Not checked yet	Pas encore vérifié
Not checked yet. Click to check.	Pas encore vérifié. Cliquez pour vérifier.
Not done	Pas fait
Not done yet	Pas encore fait
Not enough room on the USB for Windows: it needs {0} GB and has {1} GB. Use a USB of 16 GB or more.	Pas assez de place sur la clé USB pour Windows : il faut {0} Go et elle a {1} Go. Utilisez une clé de 16 Go ou plus.
Not included with this licence. Contact DRDirect for a code.	Non inclus avec cette licence. Contactez DRDirect pour un code.
Not installed on this PC:	Pas installé sur ce PC :
Not installed.	Non installé.
Not registered with Windows	Non enregistré dans Windows
Not removed, backup failed:	Pas retiré, la sauvegarde a échoué :
Not reported	Non indiqué
Not signed	Non signé
Not timed yet	Pas encore chronométré
Not timed yet - press here	Pas encore chronométré - appuyez ici
Not timed yet on this PC - the exact time shows after the first run.	Pas encore chronométré sur ce PC - la durée exacte s’affiche après la première fois.
Not verified	Non vérifié
Not yet	Pas encore
Notepad	Bloc-notes
Notepad already opens empty	Le Bloc-notes s’ouvre déjà vide
Notepad brings back old notes when it opens	Le Bloc-notes rouvre les anciennes notes à l’ouverture
Notepad is not set up on this PC	Le Bloc-notes n’est pas installé sur ce PC
Notepad is not set up on this PC. Nothing to change.	Le Bloc-notes n’est pas installé sur ce PC. Rien à changer.
Notepad opens empty	Le Bloc-notes s’ouvre vide
Notepad will bring back your last notes when it opens.	Le Bloc-notes rouvrira vos dernières notes à l’ouverture.
Nothing from "{0}" is left on this PC.	Il ne reste rien de « {0} » sur ce PC.
Nothing has been run on this PC yet. Analysis and cleanup results will be listed here.	Rien n’a encore été fait sur ce PC. Les résultats d’analyse et de nettoyage s’afficheront ici.
Nothing has moved for {0} min. The drive is not answering - it may have damaged areas, or a USB drive may have been unplugged.	Rien n’a bougé depuis {0} min. Le disque ne répond pas - il a peut-être des zones endommagées, ou un disque USB a été débranché.
Nothing has run yet.	Rien n’a encore été fait.
Nothing in that folder is an exact copy of anything else. Try a bigger folder, or lower the size filter.	Rien dans ce dossier n’est une copie exacte d’autre chose. Essayez un plus grand dossier, ou baissez le filtre de taille.
Nothing is ever deleted without your say-so	Rien n’est jamais supprimé sans votre accord
Nothing reported	Rien à signaler
Nothing suspicious was found. Nothing was changed. This sweep looks for signs of spyware and adware; keep using the Defender scans too.	Rien de suspect n’a été trouvé. Rien n’a été changé. Cette recherche cherche des signes de logiciels espions et publicitaires ; continuez aussi à faire les analyses Defender.
Nothing was changed on this PC.	Rien n’a été changé sur ce PC.
Nothing was changed on this PC. Copy anything you cannot lose to another drive before doing anything else.	Rien n’a été changé sur ce PC. Copiez sur un autre disque tout ce que vous ne pouvez pas perdre avant de faire quoi que ce soit d’autre.
Nothing was changed or removed. Some of these can be normal, so check each one yourself. If you do not recognise a program, remove it with the DRDirect Uninstaller, then run a Defender full scan.	Rien n’a été changé ni retiré. Certains peuvent être normaux, alors vérifiez chacun vous-même. Si vous ne reconnaissez pas un programme, retirez-le avec le désinstalleur DRDirect, puis faites une analyse complète Defender.
Nothing was changed.	Rien n’a été changé.
Nothing was changed. Open Microsoft's Windows 11 download page instead?	Rien n’a été changé. Ouvrir plutôt la page de téléchargement de Windows 11 de Microsoft ?
Nothing was removed.	Rien n’a été retiré.
OGG audio	Audio OGG
OGG video	Vidéo OGG
ONLY LOOKS	REGARDE SEULEMENT
OPENS A WINDOW - YOU FINISH IT	OUVRE UNE FENÊTRE - VOUS TERMINEZ
ORDERED PRESETS	PRÉRÉGLAGES DANS L’ORDRE
Off	Désactivé
Off by default. Online-only files are not kept on this PC, so ticking this downloads every one from {0} to compare it.	Désactivé par défaut. Les fichiers en ligne seulement ne sont pas gardés sur ce PC; cocher ceci les télécharge tous depuis {0} pour les comparer.
Old	Vieux
Old Windows Update backup folders	Anciens dossiers de sauvegarde de Windows Update
Old Windows copy; you cannot go back afterwards	Ancienne copie de Windows ; impossible de revenir en arrière ensuite
Old restore points	Anciens points de restauration
On	Activé
On your main drive	Sur votre disque principal
One click picks every "Turn off", "Remove" and "Delete" below that the Cleaner can do by itself. Claude is always left alone. Gmail, Word and the Edge button each open their own page, so pick those one by one. Nothing runs until you review and confirm.	Un clic choisit chaque « Désactiver », « Retirer » et « Supprimer » ci-dessous que le Cleaner peut faire lui-même. Claude n’est jamais touché. Gmail, Word et le bouton Edge ouvrent chacun leur propre page, alors choisissez-les un par un. Rien ne se fait avant que vous ayez vérifié et confirmé.
One click. We only do the safe things, and we ask you before anything starts.	Un clic. On fait seulement ce qui est sûr, et on vous demande avant de commencer.
One copy is always kept.	Une copie est toujours gardée.
One copy of every file is always kept. Removed duplicates go to the Recycle Bin, so nothing is deleted permanently. Windows system folders, program folders, and hard links are skipped.	Une copie de chaque fichier est toujours gardée. Les doublons retirés vont dans la Corbeille, donc rien n’est supprimé définitivement. Les dossiers système de Windows, les dossiers de programmes et les liens physiques sont ignorés.
One copy of every file is kept - the green KEEP row is never touched.	Une copie de chaque fichier est gardée - la ligne verte GARDER n’est jamais touchée.
One quick summary of memory use, free disk space, how long Windows has been running, startup programs and any restart waiting. Nothing is changed.	Un résumé rapide de la mémoire utilisée, de l’espace disque libre, du temps depuis le démarrage de Windows, des programmes au démarrage et de tout redémarrage en attente. Rien n’est changé.
OneDrive cache	Cache de OneDrive
Only files that are 100% identical.	Seulement les fichiers 100 % identiques.
Only looks - nothing is changed. Click Check now and the AI still switched on or installed is listed right here - handy after a Windows or browser update brings something back.	Regarde seulement - rien n’est changé. Cliquez sur Vérifier maintenant et l’IA encore active ou installée s’affiche ici - pratique quand une mise à jour de Windows ou d’un navigateur ramène quelque chose.
Only the data is copied, about {0}. Nothing blank is copied.	Seules les données sont copiées, environ {0}. Rien de vide n’est copié.
Only the used parts are read (about {0} of {1}).{2}	Seules les parties utilisées sont lues (environ {0} sur {1}).{2}
Only these selected operations will run, in the order shown.	Seules ces opérations choisies seront faites, dans l’ordre affiché.
Only useful for diagnosing a specific past crash	Utile seulement pour diagnostiquer un plantage passé précis
Only {0} is free. Windows needs room to breathe: a drive this full runs slower, and updates and saving files can fail. Please clean it out soon.	Il ne reste que {0} de libre. Windows a besoin d’espace pour respirer : un disque aussi plein ralentit, et les mises à jour et l’enregistrement de fichiers peuvent échouer. Faites-y du ménage bientôt.
Onto:    {0}	Vers :    {0}
Onto:  {0}	Vers :  {0}
Open	Ouvrir
Open Clean my PC now?	Ouvrir Nettoyer mon PC maintenant ?
Open Clone & Backup: SmartCopy, Secure, Restore and Rescue USB	Ouvrir Copie et sauvegarde : SmartCopy, Secure, Restauration et clé USB de secours
Open DRDirect PC Cleaner	Ouvrir DRDirect Nettoyeur PC
Open DRDirect PC Cleaner from its shortcut instead. Don't have it? Contact DRDirect.	Ouvrez plutôt DRDirect Nettoyeur PC depuis son raccourci. Vous ne l’avez pas ? Contactez DRDirect.
Open Duplicate Finder	Ouvrir le Duplicate Finder
Open Edge, click the profile picture at the top left and sign in.	Ouvrez Edge, cliquez sur la photo de profil en haut à gauche et connectez-vous.
Open Firefox, click the account button at the top right and sign in to a Mozilla account.	Ouvrez Firefox, cliquez sur le bouton du compte en haut à droite et connectez-vous à un compte Mozilla.
Open file	Ouvrir le fichier
Open it from its shortcut, or from the DRDirect PC Cleaner. Don't have it? Contact DRDirect.	Ouvrez-le depuis son raccourci, ou depuis DRDirect Nettoyeur PC. Vous ne l’avez pas ? Contactez DRDirect.
Open it from the DRDirect PC Cleaner and enter the key DRDirect gave you.	Ouvrez-le depuis DRDirect Nettoyeur PC et entrez la clé que DRDirect vous a donnée.
Open its folder	Ouvrir son dossier
Open reports folder	Ouvrir le dossier des rapports
Open the Cleaner as administrator and tick "Shred deleted files" to wipe the free space too.	Ouvrez le Cleaner en administrateur et cochez « Détruire les fichiers supprimés » pour nettoyer aussi l’espace libre.
Open the Cleaner as administrator first - clearing the logs needs it.	Ouvrez d’abord le Cleaner en administrateur - c’est nécessaire pour effacer les journaux.
Open the Cleaner from its own folder, or use its Remove programs button to open this window next time.	Ouvrez le Cleaner depuis son dossier, ou utilisez son bouton Retirer des programmes pour ouvrir cette fenêtre la prochaine fois.
Open the DRDirect Uninstaller Program to remove programs you no longer want	Ouvrir le programme de désinstallation DRDirect pour retirer les programmes dont vous ne voulez plus
Open the containing folder with this file highlighted	Ouvrir le dossier avec ce fichier en surbrillance
Open the {0} drivers page for this board	Ouvrir la page des pilotes {0} pour cette carte mère
Open this file so you can see exactly what it is	Ouvrir ce fichier pour voir exactement ce que c’est
Open {0}, click the profile picture at the top right and sign in.	Ouvrez {0}, cliquez sur la photo de profil en haut à droite et connectez-vous.
Opening Microsoft's download page instead. Click the first "Download now" button (Windows 11 Setup Wizard).	Ouverture de la page de téléchargement de Microsoft à la place. Cliquez sur le premier bouton « Télécharger maintenant » (Assistant d’installation de Windows 11).
Opening Microsoft's download page so you can install it by hand.	Ouverture de la page de téléchargement de Microsoft pour l’installer à la main.
Opening Windows Update in Settings instead.	Ouverture de Windows Update dans Paramètres à la place.
Opening the Cleaner...	Ouverture du Cleaner...
Opening the Duplicate Finder so you can enter its code.	Ouverture du Duplicate Finder pour entrer son code.
Opening the Windows ISO...	Ouverture de l’ISO de Windows...
Opens Edge so you can change its search engine from Bing to Google: Settings, search for "search engine", then pick Google under "Search engine used in the address bar". Edge keeps this choice to itself, so the last click is yours.	Ouvre Edge pour que vous changiez son moteur de recherche de Bing à Google : Paramètres, cherchez « moteur de recherche », puis choisissez Google sous « Moteur de recherche utilisé dans la barre d’adresses ». Edge garde ce choix pour lui, donc le dernier clic est le vôtre.
Opens Edge so you can pick Microsoft Bing as its search engine again.	Ouvre Edge pour que vous remettiez Microsoft Bing comme moteur de recherche.
Opens Edge so you can switch off the Copilot button on the toolbar: Settings, search for Copilot, switch the button off. The newest Edge keeps this switch to itself, so the last click is yours.	Ouvre Edge pour que vous désactiviez le bouton Copilot de la barre d’outils : Paramètres, cherchez Copilot, désactivez le bouton. Le plus récent Edge garde ce réglage pour lui, donc le dernier clic est le vôtre.
Opens Edge so you can switch the Copilot button back on.	Ouvre Edge pour que vous réactiviez le bouton Copilot.
Opens Gmail settings in the web browser: untick the Smart features boxes and click Save changes. Google keeps this switch in the Google account, so the last click is yours.	Ouvre les paramètres de Gmail dans le navigateur : décochez les cases des fonctionnalités intelligentes et cliquez sur Enregistrer les modifications. Google garde ce réglage dans le compte Google, donc le dernier clic est le vôtre.
Opens Gmail settings so you can tick Smart features again.	Ouvre les paramètres de Gmail pour que vous recochiez les fonctionnalités intelligentes.
Opens Microsoft PC Manager, or its Microsoft Store page if it is not installed	Ouvre Microsoft PC Manager, ou sa page du Microsoft Store s’il n’est pas installé
Opens Word so you can switch Copilot off: File > Options > Copilot, untick Enable Copilot, then OK. Do the same in Excel and PowerPoint. Office keeps this switch inside each app, so the last click is yours.	Ouvre Word pour que vous désactiviez Copilot : Fichier > Options > Copilot, décochez Activer Copilot, puis OK. Faites pareil dans Excel et PowerPoint. Office garde ce réglage dans chaque appli, donc le dernier clic est le vôtre.
Opens Word so you can tick Enable Copilot again.	Ouvre Word pour que vous recochiez Activer Copilot.
Opens Zoom so you can switch AI Companion back on.	Ouvre Zoom pour que vous réactiviez AI Companion.
Opens in its own window.	S’ouvre dans sa propre fenêtre.
Opens the Claude website again in the browsers where the Cleaner blocked it.	Rouvre le site de Claude dans les navigateurs où le Cleaner l’avait bloqué.
Opens the Copilot app in the Microsoft Store so you can install it again.	Ouvre l’appli Copilot dans le Microsoft Store pour que vous la réinstalliez.
Opens the Microsoft 365 Copilot app in the Microsoft Store so you can install it again.	Ouvre l’appli Microsoft 365 Copilot dans le Microsoft Store pour que vous la réinstalliez.
Opens the Windows memory test. It is the thorough way to find faulty RAM, but it needs a restart: Windows asks whether to restart now or at the next start, and the test can take 1 hour or more depending on your system. The Cleaner never restarts the PC by itself.	Ouvre le test de mémoire de Windows. C’est la façon complète de trouver de la RAM défectueuse, mais il faut redémarrer : Windows demande s’il faut redémarrer maintenant ou au prochain démarrage, et le test peut prendre 1 heure ou plus selon votre système. Le Cleaner ne redémarre jamais le PC de lui-même.
Opens the Windows page where Smart App Control is switched on or off. The Cleaner changes nothing itself.	Ouvre la page de Windows où l’on active ou désactive le Contrôle intelligent des applications. Le Cleaner ne change rien lui-même.
Opens the official Brave download page.	Ouvre la page officielle de téléchargement de Brave.
Opens the official ChatGPT download page.	Ouvre la page officielle de téléchargement de ChatGPT.
Opens the official Chrome download page.	Ouvre la page officielle de téléchargement de Chrome.
Opens the official Claude download page.	Ouvre la page officielle de téléchargement de Claude.
Opens the official Firefox download page.	Ouvre la page officielle de téléchargement de Firefox.
Opus audio	Audio Opus
Other things you can do	Autres choses que vous pouvez faire
Owner	Propriétaire
Owner password	Mot de passe du propriétaire
Owner tools	Outils du propriétaire
PC Cleaner	Nettoyeur PC
PC checkup	Bilan du PC
PDF document	Document PDF
PHP on this PC needs a security update	PHP sur ce PC a besoin d’une mise à jour de sécurité
PHP security check	Vérification de sécurité PHP
PNG image	Image PNG
PROBLEM FOUND	PROBLÈME TROUVÉ
PROBLEM FOUND: PHP on this PC is open to the PHP2Shell flaw (CVE-2026-109618 / CVE-2026-109619). Update to PHP 8.2.35, 8.3.36, 8.4.27 or 8.5.12 or newer, and keep any PHP web server off the internet until then. Nothing was changed.	PROBLÈME TROUVÉ : PHP sur ce PC est exposé à la faille PHP2Shell (CVE-2026-109618 / CVE-2026-109619). Mettez à jour vers PHP 8.2.35, 8.3.36, 8.4.27 ou 8.5.12 ou plus récent, et gardez tout serveur Web PHP hors d’Internet d’ici là. Rien n’a été changé.
PUT IT BACK ON	LA REMETTRE SUR
Packs the files your browsers keep their history, icons and autofill in, so they take less space and search faster. Nothing is deleted. Passwords and cookies are never touched. Close your browsers first - any that are open are skipped.	Compacte les fichiers où vos navigateurs gardent l’historique, les icônes et la saisie automatique, pour qu’ils prennent moins de place et cherchent plus vite. Rien n’est supprimé. Les mots de passe et témoins (cookies) ne sont jamais touchés. Fermez d’abord vos navigateurs - ceux qui sont ouverts sont ignorés.
Part of the DRDirect PC Cleaner.	Fait partie de DRDirect Nettoyeur PC.
Partly removed (in use?):	Retiré en partie (en cours d’utilisation ?) :
Past results	Résultats passés
Paste the code DRDirect sent you, then press Activate.	Collez le code que DRDirect vous a envoyé, puis appuyez sur Activer.
Paste the code DRDirect sent you.	Collez le code que DRDirect vous a envoyé.
Path	Chemin
Pause	Pause
Paused {0} startup program(s) so the Advanced scan runs on its own: {1}	{0} programme(s) au démarrage mis en pause pour que l’analyse Avancée tourne seule : {1}
Paused. Nothing is running now. Press Start to carry on, or Stop to end the scan here.	En pause. Rien ne tourne maintenant. Appuyez sur Démarrer pour continuer, ou sur Arrêter pour finir l’analyse ici.
Paused. Press Start to carry on with the next step.	En pause. Appuyez sur Démarrer pour passer à l’étape suivante.
Pauses after the step that is running now. Press Start to carry on.	Met en pause après l’étape en cours. Appuyez sur Démarrer pour continuer.
Pausing after this step...	Pause après cette étape...
Permanently delete all {0} maintenance report(s)?	Supprimer définitivement les {0} rapport(s) d’entretien ?
Permanently removes Recycle Bin contents from available fixed drives.	Supprime définitivement le contenu de la Corbeille des disques fixes disponibles.
Phone video	Vidéo de téléphone
Photoshop file	Fichier Photoshop
Pick a folder and press Scan. Every match is proved byte-for-byte before it is shown.	Choisissez un dossier et appuyez sur Analyser. Chaque correspondance est vérifiée octet par octet avant d’être affichée.
Pick a level to see its steps. Nothing has run yet, and you confirm before anything starts.	Choisissez un niveau pour voir ses étapes. Rien n’a encore été fait, et vous confirmez avant que quoi que ce soit commence.
Pick a program's folder and remove it, even if it isn't in the list.	Choisissez le dossier d’un programme et retirez-le, même s’il n’est pas dans la liste.
Pick what you want to do. Each one shows you the steps.	Choisissez ce que vous voulez faire. Chacun vous montre les étapes.
Pick where to look for duplicates. Subfolders are included.	Choisissez où chercher des doublons. Les sous-dossiers sont inclus.
Pictures	Images
Places	Emplacements
Plan stopped safely	Plan arrêté en toute sécurité
Playlist	Liste de lecture
Please close {0} and the DRDirect Uninstaller, then click Retry.	Fermez {0} et le désinstalleur DRDirect, puis cliquez sur Réessayer.
Please leave this window open - it is working.	Laissez cette fenêtre ouverte - elle travaille.
Please read first	À lire d’abord
Please read first  :)	À lire d’abord  :)
Please restart Windows manually from the Start menu.	Redémarrez Windows vous-même depuis le menu Démarrer.
Please wait until the cleaning is finished, then open Clone & Backup.	Attendez la fin du nettoyage, puis ouvrez Copie et sauvegarde.
Please wait, I am analyzing your system for better performance, to make DRDirect run better for you...	Un instant, j’analyse votre système pour de meilleures performances, afin que DRDirect fonctionne mieux pour vous...
Please wait...	Veuillez patienter...
Plug in a USB flash drive you do not need.	Branchez une clé USB dont vous n’avez pas besoin.
Plug in a USB stick (any size from 1 GB), then press Look again. A new one replaces a lost or broken Rescue USB.	Branchez une clé USB (de 1 Go ou plus), puis appuyez sur Regarder de nouveau. Une nouvelle remplace une clé de secours perdue ou brisée.
Plug in a USB stick of at least 8 GB, then press Windows install USB again.	Branchez une clé USB d’au moins 8 Go, puis appuyez de nouveau sur Clé USB d’installation de Windows.
Plug in the drive to copy onto.	Branchez le disque qui reçoit la copie.
Plug in the drive to restore onto.	Branchez le disque sur lequel restaurer.
Point here to see them all.	Pointez ici pour les voir tous.
Policies	Stratégies
Polishing the pixels...	On fait briller les pixels...
Power and heat check	Vérification de l’alimentation et de la chaleur
Power and heat: All good	Alimentation et chaleur : tout va bien
Power and heat: Please check this soon	Alimentation et chaleur : à vérifier bientôt
Power and heat: Something to check	Alimentation et chaleur : quelque chose à vérifier
Power cut while working: {0} time(s).  Spare cells left: {1}%.	Coupures de courant en fonctionnement : {0} fois.  Cellules de réserve restantes : {1} %.
Preparing {0} (this takes a while)...	Préparation de {0} (cela prend un moment)...
Preparing…	Préparation…
Press Browse to pick the backup file.	Appuyez sur Parcourir pour choisir le fichier de sauvegarde.
Press Cancel to keep your PC on.	Appuyez sur Annuler pour garder votre PC allumé.
Press Enter to close	Appuyez sur Entrée pour fermer
Press Enter to close this window	Appuyez sur Entrée pour fermer cette fenêtre
Press Show all tools	Appuyez sur Afficher tous les outils
Press Show all tools.	Appuyez sur Afficher tous les outils.
Previous Windows installation (Windows.old)	Ancienne installation de Windows (Windows.old)
Problem found: one or more drives need attention	Problème trouvé : un ou plusieurs disques demandent votre attention
Processor	Processeur
Processor work, added up over all threads:	Travail du processeur, additionné sur tous les fils :
Processor:       {0} threads, {1} used for compressing	Processeur :     {0} fils, {1} pour la compression
Product	Produit
Program	Programme
Program component	Composant de programme
Program name cache (MUICache)	Cache des noms de programmes (MUICache)
Program's exact name:	Nom exact du programme :
Programs	Programmes
Programs starting with Windows: {0}	Programmes qui démarrent avec Windows : {0}
Progress	Progression
Properties	Propriétés
Protected mode	Mode protégé
Protection is on, drives are fine and there is room to spare.	La protection est active, les disques vont bien et il reste de la place.
Proxy settings: none set.	Réglages de proxy : aucun.
Publisher	Éditeur
Put back the {0} items that were removed for "{1}"?	Remettre en place les {0} éléments retirés pour « {1} » ?
Puts a backup file back onto a drive, so the drive is just like it was when you saved it.	Remet un fichier de sauvegarde sur un disque, pour que le disque soit comme au moment de la sauvegarde.
Puts back what the last cleanup removed. This only works for 24 hours.	Remet en place ce que le dernier nettoyage a retiré. Ça ne fonctionne que pendant 24 heures.
Puts the Adobe Acrobat AI settings back exactly as they were.	Remet les réglages d’IA d’Adobe Acrobat exactement comme avant.
Puts the Brave AI settings back exactly as they were.	Remet les réglages d’IA de Brave exactement comme avant.
Puts the Chrome AI settings back exactly as they were.	Remet les réglages d’IA de Chrome exactement comme avant.
Puts the Edge AI settings back exactly as they were.	Remet les réglages d’IA d’Edge exactement comme avant.
Puts the Firefox AI settings back exactly as they were.	Remet les réglages d’IA de Firefox exactement comme avant.
Puts the Start menu search settings back exactly as they were.	Remet les réglages de recherche du menu Démarrer exactement comme avant.
Puts the Windows AI settings back exactly as they were.	Remet les réglages d’IA de Windows exactement comme avant.
Puts the ads and suggestions settings back exactly as they were before "Windows 11: turn off ads and suggestions" changed them. Does nothing if that option was never run.	Remet les réglages de publicités et suggestions exactement comme avant que « Windows 11 : désactiver les publicités et suggestions » les change. Ne fait rien si cette option n’a jamais été lancée.
Puts the telemetry services, scheduled tasks and policies back exactly as they were before "Turn off Windows telemetry" changed them. Does nothing if that option was never run.	Remet les services de télémétrie, les tâches planifiées et les stratégies exactement comme avant que « Désactiver la télémétrie de Windows » les change. Ne fait rien si cette option n’a jamais été lancée.
Puts the typing settings back exactly as they were before "Stop sending typing data to Microsoft" changed them. Does nothing if that option was never run.	Remet les réglages de saisie exactement comme avant que « Arrêter d’envoyer les données de saisie à Microsoft » les change. Ne fait rien si cette option n’a jamais été lancée.
Putting everything back...	Remise en place de tout...
Question	Question
Questionable	Douteux
Queued and archived crash reports	Rapports de plantage en attente et archivés
Quick	Rapide
Quick scan	Analyse rapide
Quick scan refused - ignored for 3 days	Analyse rapide refusée - ignorée pendant 3 jours
Quick scan:	Analyse rapide :
Quick scan: never - overdue	Analyse rapide : jamais - en retard
Quick scan: {0} - due in {1}	Analyse rapide : {0} - prévue dans {1}
Quick scan: {0} - next in {1}	Analyse rapide : {0} - prochaine dans {1}
Quick scan: {0} - overdue by {1}	Analyse rapide : {0} - en retard de {1}
QuickTime video	Vidéo QuickTime
Quiet uninstall	Désinstallation silencieuse
RAR archive	Archive RAR
RAW photo	Photo RAW
RECLAIM SPACE	RÉCUPÉRER DE L’ESPACE
RESCUE SYSTEM	SYSTÈME DE SECOURS
RESTART REQUIRED	REDÉMARRAGE NÉCESSAIRE
Read	Lecture
Read each item first. DRDirect is not responsible for what you tick unread.	Lisez chaque élément d’abord. DRDirect n’est pas responsable de ce que vous cochez sans lire.
Read head parked {0} times.	Tête de lecture rangée {0} fois.
Read me: a short, friendly note	À lire : une courte note amicale
Read the list of programs again	Relire la liste des programmes
Reading is the slowest part: the processor waits for the drive to deliver the data.	La lecture est la partie la plus lente : le processeur attend que le disque livre les données.
Reading the Windows Store apps...	Lecture des applications du Windows Store...
Reading the drive	Lecture du disque
Reading the programs on this PC...	Lecture des programmes de ce PC...
Reads the health information your drives report about themselves, including estimated life left and read errors. Nothing is changed or deleted.	Lit les informations de santé que vos disques donnent sur eux-mêmes, y compris la vie restante estimée et les erreurs de lecture. Rien n’est changé ni supprimé.
Ready	Prêt
Ready to copy onto the smaller drive?	Prêt à copier sur le disque plus petit ?
Ready to copy?	Prêt à copier ?
Ready to create the Rescue USB on {0}?	Prêt à créer la clé USB de secours sur {0} ?
Ready to restore?	Prêt à restaurer ?
RealMedia video	Vidéo RealMedia
Rebuilds the Windows font cache. It fixes missing, blank or wrong-looking fonts. Fonts themselves are not touched. A restart is recommended afterwards.	Refait le cache des polices de Windows. Cela répare les polices manquantes, vides ou mal affichées. Les polices elles-mêmes ne sont pas touchées. Un redémarrage est conseillé ensuite.
Rebuilt automatically as you browse files	Refait automatiquement quand vous parcourez les fichiers
Recall could not be installed: {0}	Recall n’a pas pu être installé : {0}
Recall could not be uninstalled: {0}	Recall n’a pas pu être désinstallé : {0}
Recall is not installed on this PC. Nothing was changed.	Recall n’est pas installé sur ce PC. Rien n’a été changé.
Recall was installed again. Restart Windows to finish.	Recall a été réinstallé. Redémarrez Windows pour terminer.
Recall was uninstalled. Restart Windows to finish. Its "Reinstall" button brings it back.	Recall a été désinstallé. Redémarrez Windows pour terminer. Son bouton « Réinstaller » le ramène.
Recall, Click to Do and the AI in Paint and Notepad: {0}	Recall, Click to Do et l’IA dans Paint et le Bloc-notes : {0}
Recall, Click to Do, and the AI in Paint and Notepad are now off. They are gone after the restart.	Recall, Click to Do et l’IA dans Paint et le Bloc-notes sont maintenant désactivés. Ils disparaissent après le redémarrage.
Recent documents list	Liste des documents récents
Recovered once removed	Récupéré une fois retiré
Recovery	Récupération
Recycle Bin	Corbeille
Recycle Bin contents will be permanently removed.	Le contenu de la Corbeille sera supprimé définitivement.
Reference code:	Code de référence :
Refusing to delete a drive root:	Refus de supprimer la racine d’un disque :
Refusing to wipe the Windows drive.	Refus d’effacer le disque Windows.
Registry	Registre
Registry entry	Entrée de registre
Regular cleanup: temporary files, browser caches, Recycle Bin, Prefetch, old Windows Update leftovers, and caches Windows rebuilds by itself.	Nettoyage régulier : fichiers temporaires, caches des navigateurs, Corbeille, Prefetch, restes d’anciennes mises à jour Windows et caches que Windows refait tout seul.
Reinstall	Réinstaller
Reinstall Brave	Réinstaller Brave
Reinstall Chrome	Réinstaller Chrome
Reinstall Firefox	Réinstaller Firefox
Reinstall the ChatGPT app	Réinstaller l’appli ChatGPT
Reinstall the Claude app	Réinstaller l’appli Claude
Reinstall the Copilot app	Réinstaller l’appli Copilot
Reinstall the Microsoft 365 Copilot app	Réinstaller l’appli Microsoft 365 Copilot
Release IP address	Libérer l’adresse IP
Reload NetBIOS name cache	Recharger le cache des noms NetBIOS
Reload uninstallers	Recharger les désinstalleurs
Reminder: this PC has not been restarted since the last clean, and Windows may still be finishing the changes.	Rappel : ce PC n’a pas été redémarré depuis le dernier nettoyage, et Windows termine peut-être encore les changements.
Removable	Amovible
Remove	Retirer
Remove everything DRDirect from this PC?	Retirer tout ce qui vient de DRDirect de ce PC ?
Remove from a folder...	Retirer depuis un dossier...
Remove from the list only	Retirer de la liste seulement
Remove selected programs	Retirer les programmes choisis
Remove the ChatGPT app	Retirer l’appli ChatGPT
Remove the Claude app	Retirer l’appli Claude
Remove the ticked programs	Retirer les programmes cochés
Remove the ticked programs without questions	Retirer les programmes cochés sans questions
Remove these {0} apps?	Retirer ces {0} applications ?
Remove these {0} programs {1}?	Retirer ces {0} programmes {1} ?
Remove this copy	Retirer cette copie
Remove ticked apps	Retirer les applications cochées
Remove tracked install	Retirer une installation suivie
Remove tracked install...	Retirer une installation suivie...
Remove {0} from this PC?	Retirer {0} de ce PC ?
Removed website data {0} of {1}.	Données de site {0} sur {1} retirées.
Removed {0} old Windows Update backup folder(s).	{0} ancien(s) dossier(s) de sauvegarde de Windows Update retiré(s).
Removed {0} older restore point(s); the most recent one was kept.	{0} ancien(s) point(s) de restauration retiré(s) ; le plus récent a été gardé.
Removes SoftwareDistribution.old and catroot2.old, copies left behind by an earlier Windows Update fix. Windows no longer uses them. The Windows Update folders in use are never touched.	Retire SoftwareDistribution.old et catroot2.old, des copies laissées par une ancienne réparation de Windows Update. Windows ne s’en sert plus. Les dossiers de Windows Update utilisés ne sont jamais touchés.
Removes hidden $Recycle.Bin folders from fixed drives so Windows can rebuild them.	Retire les dossiers cachés $Recycle.Bin des disques fixes pour que Windows les refasse.
Removes queued and archived crash reports waiting to be sent to Microsoft.	Retire les rapports de plantage en attente d’envoi à Microsoft et ceux archivés.
Removes saved crash dump files (Memory.dmp and Minidump). These are only useful for diagnosing a specific past crash.	Retire les fichiers de vidage de plantage (Memory.dmp et Minidump). Ils ne servent qu’à diagnostiquer un plantage passé précis.
Removes superseded Windows component versions.	Retire les anciennes versions remplacées des composants Windows.
Removes temporary files no longer needed by Windows or applications.	Retire les fichiers temporaires dont Windows ou les applications n’ont plus besoin.
Removes the ChatGPT app, including a regular installed copy. Chats saved in the account are not deleted.	Retire l’appli ChatGPT, y compris une copie installée normalement. Les conversations enregistrées dans le compte ne sont pas supprimées.
Removes the Claude app, including a regular installed copy. Chats saved in the account are not deleted.	Retire l’appli Claude, y compris une copie installée normalement. Les conversations enregistrées dans le compte ne sont pas supprimées.
Removes the Copilot app for every account and stops Windows adding it to new accounts.	Retire l’appli Copilot pour tous les comptes et empêche Windows de l’ajouter aux nouveaux comptes.
Removes the Microsoft 365 Copilot app for every account. Word, Excel and your documents are not touched.	Retire l’appli Microsoft 365 Copilot pour tous les comptes. Word, Excel et vos documents ne sont pas touchés.
Removes the Recall feature from Windows altogether. Takes effect after a restart.	Retire complètement la fonction Recall de Windows. S’applique après un redémarrage.
Removes the old copy of Windows kept after a big Windows update, using Windows Disk Cleanup. It can free 10-30 GB. You can NOT go back to the earlier Windows afterwards. Windows removes it by itself after about 10 days anyway.	Retire l’ancienne copie de Windows gardée après une grosse mise à jour, avec le Nettoyage de disque de Windows. Cela peut libérer 10 à 30 Go. Vous ne pourrez PAS revenir à l’ancien Windows ensuite. Windows la retire de lui-même après environ 10 jours de toute façon.
Removes the ticked programs quietly, without asking for each one.	Retire les programmes cochés en silence, sans demander pour chacun.
Removing	Retrait
Removing leftovers	Retrait des restes
Removing programs	Retrait des programmes
Removing the leftovers. Everything is backed up first...	Retrait des restes. Tout est sauvegardé d’abord...
Removing what "{0}" added. Everything is backed up first...	Retrait de ce que « {0} » a ajouté. Tout est sauvegardé d’abord...
Removing {0}  ({1} of {2})...	Retrait de {0}  ({1} sur {2})...
Renew IP address	Renouveler l’adresse IP
Repair	Réparer
Repairs the Windows component store using DISM RestoreHealth.	Répare le magasin de composants de Windows avec DISM RestoreHealth.
Reports are stored locally and include selected tasks, timestamps, results, warnings, and errors.	Les rapports sont gardés sur ce PC et contiennent les tâches choisies, les heures, les résultats, les avertissements et les erreurs.
Rescue USB	USB secours
Reset IPv4 stack	Réinitialiser la pile IPv4
Reset IPv6 stack	Réinitialiser la pile IPv6
Reset Reliability Monitor	Réinitialiser le Moniteur de fiabilité
Reset Winsock catalog	Réinitialiser le catalogue Winsock
Resets Windows Update services, caches, Winsock, and the WinHTTP proxy.	Réinitialise les services et caches de Windows Update, Winsock et le proxy WinHTTP.
Restart failed:	Le redémarrage a échoué :
Restart it yourself when you are ready.	Redémarrez-le vous-même quand vous êtes prêt.
Restart later	Redémarrer plus tard
Restart now	Redémarrer maintenant
Restart now? Save your open work first.	Redémarrer maintenant ? Enregistrez d’abord votre travail ouvert.
Restart the PC to finish installing the updates.	Redémarrez le PC pour finir d’installer les mises à jour.
Restart when done	Redémarrer à la fin
Restore	Restaurer
Restore TCP auto-tuning to normal	Remettre le réglage automatique TCP à la normale
Restore point made: DRDirect Uninstaller is removing {0}	Point de restauration créé : le désinstalleur DRDirect retire {0}
Restore typing settings	Rétablir les réglages de saisie
Restoring	Restauration
Results	Résultats
Retry	Réessayer
Return to dashboard	Retour au tableau de bord
Review maintenance plan	Revoir le plan d’entretien
Review selected plan	Revoir le plan choisi
Rich text	Texte enrichi
Right away (10 seconds after it finishes)	Tout de suite (10 secondes après la fin)
Run	Lancer
Run 'PHP security check' under Health to see which one.	Lancez « Vérification de sécurité PHP » sous Santé pour voir lequel.
Run Defender operations independently. Existing exclusions are never removed automatically.	Faites les opérations Defender séparément. Les exclusions existantes ne sont jamais retirées automatiquement.
Run box history	Historique de la boîte Exécuter
Run selected tasks	Lancer les tâches choisies
Run this command	Lancer cette commande
Running	En cours
Running for	En cours depuis
Running maintenance plan	Plan d’entretien en cours
Runs one Microsoft Defender full scan and nothing else. It can take a long time.	Lance une seule analyse complète de Microsoft Defender, rien d’autre. Cela peut être long.
Runs the Windows Disk Cleanup profile for the C: drive.	Lance le Nettoyage de disque de Windows pour le disque C:.
Runs the advanced uninstall options on the ticked program.	Lance les options de désinstallation avancées sur le programme coché.
SAFE SCAN	ANALYSE SÛRE
SAVE THIS DRIVE	SAUVEGARDER CE DISQUE
SEARCHING IN	RECHERCHE DANS
SELECTED SCAN	ANALYSE CHOISIE
SERIOUS PROBLEM	PROBLÈME GRAVE
SHA-256 {0}...  -  verified byte-for-byte	SHA-256 {0}...  -  vérifié octet par octet
SIGNS YOU OUT	VOUS DÉCONNECTE
SPACE TO FREE	ESPACE À LIBÉRER
SSD speed	Vitesse du SSD
START HERE	COMMENCEZ ICI
STEP 1	ÉTAPE 1
STEP 2	ÉTAPE 2
STEP 3	ÉTAPE 3
SVG graphic	Graphique SVG
Safe	Sûr
Safe steps plus more cleanup. Cookies stay off.	Les étapes Sûres plus un nettoyage plus poussé. Les témoins (cookies) restent décochés.
Safety	Sécurité
Safety blocked deletion outside the approved root: {0}	Par sécurité, la suppression hors du dossier autorisé a été bloquée : {0}
Same SHA-256	Même SHA-256
Same size	Même taille
Save	Enregistrer
Save a Windows restore point (safety net)	Créer un point de restauration Windows (filet de sécurité)
Save all open work before restarting. Restart this PC now?	Enregistrez tout votre travail ouvert avant de redémarrer. Redémarrer ce PC maintenant ?
Save all open work before shutting down. Shut down this PC now?	Enregistrez tout votre travail ouvert avant d’éteindre. Éteindre ce PC maintenant ?
Save the image on a drive with a letter, such as D:.	Enregistrez la sauvegarde sur un disque avec une lettre, comme D:.
Saved Games	Parties enregistrées
Saves a Windows restore point before anything changes, so Windows itself can go back. If Windows cannot make one, the Cleaner says so and carries on with its own backups.	Crée un point de restauration Windows avant tout changement, pour que Windows puisse revenir en arrière. Si Windows ne peut pas en créer un, le Cleaner le dit et continue avec ses propres copies.
Saves a whole drive into one backup file that you can put back later. The drive itself is not changed.	Enregistre un disque entier dans un seul fichier de sauvegarde que vous pourrez remettre plus tard. Le disque lui-même n’est pas changé.
Saving the Rescue system to this PC...	Enregistrement du système de secours sur ce PC...
Scan all Windows accounts for leftovers	Chercher des restes dans tous les comptes Windows
Scan all of {0} as well. {1} free of {2}.	Analyser aussi tout {0}. {1} libres sur {2}.
Scan complete	Analyse terminée
Scan failed: {0}	L’analyse a échoué : {0}
Scan for duplicates	Chercher des doublons
Scan now?	Analyser maintenant ?
Scan stopped.	Analyse arrêtée.
Scan:      Windows Defender {0} scan	Analyse :  analyse {0} de Windows Defender
Scanning	Analyse en cours
Scans all accessible files. This may take several hours.	Analyse tous les fichiers accessibles. Cela peut prendre plusieurs heures.
Scans common threat locations without changing exclusions.	Analyse les endroits habituels des menaces sans changer les exclusions.
Scans protected Windows files and repairs damaged copies.	Analyse les fichiers protégés de Windows et répare les copies endommagées.
Scans refused in the last 30 days: {0} (quick {1}, full {2}). Last:	Analyses refusées dans les 30 derniers jours : {0} (rapides {1}, complètes {2}). Dernière :
Scheduled task "{0}" runs from an unusual place: {1}	La tâche planifiée « {0} » se lance d’un endroit inhabituel : {1}
Scheduled tasks (not Microsoft): none run from unusual places.	Tâches planifiées (hors Microsoft) : aucune ne se lance d’un endroit inhabituel.
Scroll down	Défiler vers le bas
Scroll down for more tools	Défilez vers le bas pour plus d’outils
Scroll up	Défiler vers le haut
Search	Recherche
Search AI items (Copilot, Edge...)	Chercher des éléments d’IA (Copilot, Edge...)
Search engine used in the address bar	Moteur de recherche utilisé dans la barre d’adresses
Search for this board's drivers	Chercher les pilotes de cette carte mère
Seconds spent (the threads overlap, so these do not add up to the total):	Secondes passées (les fils travaillent en même temps, donc la somme ne donne pas le total) :
Secure	Secure
Secure can take a long time, and if the battery runs out the image is lost. Please plug in the charger and keep the lid open until it is done.	Secure peut être long, et si la pile se vide, la sauvegarde est perdue. Branchez le chargeur et gardez l’écran ouvert jusqu’à la fin.
Secure {0} into:	Sauvegarder {0} dans :
Security	Sécurité
Security alert - PHP	Alerte de sécurité - PHP
Security checkup	Bilan de sécurité
See all	Tout voir
See past results	Voir les résultats passés
See what is new and update	Voir les nouveautés et mettre à jour
See what the Cleaner did, open the reports, and undo changes to settings	Voir ce que le Cleaner a fait, ouvrir les rapports et annuler les changements de réglages
Select cleanup items after reviewing the estimated impact. Passwords, bookmarks, personal documents, and active sessions remain protected unless cookie cleanup is explicitly selected.	Choisissez les éléments à nettoyer après avoir vu l’effet prévu. Les mots de passe, favoris, documents personnels et sessions ouvertes restent protégés, sauf si le nettoyage des témoins (cookies) est expressément choisi.
Select down to...	Sélectionner jusqu’à...
Select exactly what you want to run. Nothing starts until you review and confirm the plan.	Choisissez exactement ce que vous voulez faire. Rien ne commence avant que vous ayez vérifié et confirmé le plan.
Select none	Ne rien sélectionner
Select using checkboxes	Sélectionner avec des cases à cocher
Selected tasks:	Tâches choisies :
Serial number: not reported	Numéro de série : non indiqué
Serial number: {0}	Numéro de série : {0}
Serious: this needs attention now. Click to check again.	Grave : cela demande votre attention maintenant. Cliquez pour revérifier.
Service	Service
Services not checked:	Services non vérifiés :
Setting up the stick...	Préparation de la clé...
Settings	Paramètres
Settings changes can be undone.	Les changements de réglages peuvent être annulés.
Settings is open at Text input. Under "Customize Copilot key on keyboard", choose Copilot.	Paramètres est ouvert à Saisie de texte. Sous « Personnaliser la touche Copilot du clavier », choisissez Copilot.
Settings is open at Text input. Under "Customize Copilot key on keyboard", choose Search.	Paramètres est ouvert à Saisie de texte. Sous « Personnaliser la touche Copilot du clavier », choisissez Rechercher.
Setup	Installation
Shortcuts	Raccourcis
Shortcuts to documents you opened, not the documents	Raccourcis vers les documents ouverts, pas les documents eux-mêmes
Show Windows updates	Afficher les mises à jour Windows
Show advanced options	Afficher les options avancées
Show all tools	Afficher tous les outils
Show available updates	Voir les mises à jour disponibles
Show each item	Afficher chaque élément
Show each item - change just one thing	Afficher chaque élément - changer une seule chose
Show in folder	Afficher dans le dossier
Show in the registry	Afficher dans le registre
Show items in groups	Afficher les éléments par groupes
Show me	Montrer
Show me first	Me montrer d’abord
Show only broken programs	Afficher seulement les programmes brisés
Show protected items	Afficher les éléments protégés
Show system components	Afficher les composants système
Show unregistered applications	Afficher les applications non enregistrées
Shows about how long a Safe, Medium and Advanced scan would take on this PC	Montre combien de temps environ prendraient les analyses Sûre, Moyenne et Avancée sur ce PC
Shows here after your first clean	S’affiche ici après votre premier nettoyage
Shows only programs whose uninstaller is missing. Click again to show everything.	Affiche seulement les programmes dont le désinstalleur manque. Cliquez de nouveau pour tout afficher.
Shows or hides installed Windows updates in the list.	Affiche ou masque les mises à jour Windows installées dans la liste.
Shows the extra buttons. Click again to hide them.	Affiche les boutons de plus. Cliquez de nouveau pour les masquer.
Shows the memory installed in this PC (size, type, speed), how much is in use, and whether Windows has recorded memory errors in the last 30 days. Only looks - nothing is changed.	Montre la mémoire installée dans ce PC (taille, type, vitesse), combien est utilisée, et si Windows a noté des erreurs de mémoire dans les 30 derniers jours. Regarde seulement - rien n’est changé.
Shows which folders, programs and file types Defender skips, and marks any that look risky. Nothing is ever removed - exclusions you added on purpose, like a work or tools folder, always stay.	Montre quels dossiers, programmes et types de fichiers Defender ignore, et signale ceux qui semblent risqués. Rien n’est jamais retiré - les exclusions ajoutées exprès, comme un dossier de travail ou d’outils, restent toujours.
Shred deleted files	Détruire les fichiers supprimés
Shred deleted files (SSD and NVMe)	Détruire les fichiers supprimés (SSD et NVMe)
Shredded for good on SSD drive(s) {0}. Deleted files there cannot be brought back.	Détruits pour de bon sur le(s) disque(s) SSD {0}. Les fichiers supprimés là ne peuvent plus être récupérés.
Shut down my PC when it finishes	Éteindre mon PC à la fin
Shut down my PC when it finishes (60 seconds, you can cancel)	Éteindre mon PC à la fin (60 secondes, vous pouvez annuler)
Shut down now	Éteindre maintenant
Shut down when done	Éteindre à la fin
Shutting down…	Arrêt en cours…
Sign in to the browser first.	Connectez-vous d’abord au navigateur.
Signed in	Connecté
Size	Taille
Size: {0}  (nothing is missing - Windows counts in 1,024s, so it shows {1} GB)	Taille : {0}  (rien ne manque - Windows compte par 1 024, donc il affiche {1} Go)
Skip	Passer
Skipped - Windows or program file, not safe to remove	Ignoré - fichier de Windows ou de programme, risqué à retirer
Skipped a registry entry:	Entrée de registre ignorée :
Skipped {0}: close it and run this again.	{0} ignoré : fermez-le et relancez ceci.
Skipped: Microsoft Defender does not run in Safe Mode. Restart Windows normally to scan.	Ignoré : Microsoft Defender ne fonctionne pas en mode sans échec. Redémarrez Windows normalement pour analyser.
Skipped: Notepad is open. Close Notepad and run this again.	Ignoré : le Bloc-notes est ouvert. Fermez-le et relancez ceci.
Skipped: Windows cannot make a restore point in Safe Mode. Restart Windows normally to make one.	Ignoré : Windows ne peut pas créer de point de restauration en mode sans échec. Redémarrez Windows normalement pour en créer un.
Slowest part:	Partie la plus lente :
Smallest file  -  slower	Plus petit fichier  -  plus lent
Smart App Control	Contrôle intelligent des applications
SmartCopy	SmartCopy
SmartCopy, Secure, Restore and Rescue USB: copy or back up a whole drive	SmartCopy, Secure, Restauration et clé USB de secours : copier ou sauvegarder un disque entier
So if a PC still crawls after a clean, it is nobody's fault. It may simply be ready to retire to a quiet life on a shelf, with a gold watch and a farewell cake. Give it a good send-off, and when the new one arrives, I will keep that one running nicely too.	Alors si un PC se traîne encore après un nettoyage, ce n’est la faute de personne. Il est peut-être simplement prêt pour une retraite tranquille sur une tablette, avec une montre en or et un gâteau d’adieu. Faites-lui de beaux adieux, et quand le nouveau arrivera, je le garderai en forme lui aussi.
Software	Logiciel
Some apps could not be removed:	Certaines applications n’ont pas pu être retirées :
Some apps may close or restart during their update. Save your work first.	Certaines applis peuvent se fermer ou redémarrer pendant leur mise à jour. Enregistrez votre travail d’abord.
Some damaged Windows system files could not be repaired. Run "DISM RestoreHealth", restart, then run System File Checker again.	Certains fichiers système endommagés de Windows n’ont pas pu être réparés. Lancez « DISM RestoreHealth », redémarrez, puis relancez le Vérificateur des fichiers système.
Some damaged Windows system files were found and repaired. Restart the PC to finish.	Des fichiers système endommagés de Windows ont été trouvés et réparés. Redémarrez le PC pour terminer.
Some items open Gmail, Word, Edge, Settings, the Microsoft Store or a download page at the right place. The last click there is yours - the steps show when it runs.	Certains éléments ouvrent Gmail, Word, Edge, Paramètres, le Microsoft Store ou une page de téléchargement au bon endroit. Le dernier clic là-bas est le vôtre - les étapes s’affichent quand ça se lance.
Some of it could not be removed:	Une partie n’a pas pu être retirée :
Something is already running.	Quelque chose est déjà en cours.
Something went wrong:	Un problème est survenu :
Sony RAW photo	Photo RAW Sony
Sorry, this PC is not strong enough to run 2 at the same time right now.{0}{1}Please wait until {2} is finished and closed.	Désolé, ce PC n’est pas assez puissant pour en faire tourner 2 en même temps pour l’instant.{0}{1}Attendez que {2} soit terminé et fermé.
Sorry, this PC is not strong enough to run all 3 at the same time.{0}{1}Try 2. If that does not work, do one at a time, that will work.	Désolé, ce PC n’est pas assez puissant pour faire tourner les 3 en même temps.{0}{1}Essayez 2. Si ça ne marche pas, faites-les un à la fois, ça marchera.
Sound	Son
Sound device	Périphérique audio
Sounds: a soft chime when a clean finishes, and a small tick when you point at a button	Sons : un doux carillon à la fin d’un nettoyage, et un petit clic quand vous pointez un bouton
Source	Source
Space	Espace
Space is low. Run the Cleanup tasks and the large files list.	L’espace est bas. Lancez les tâches de nettoyage et la liste des gros fichiers.
Speed	Vitesse
Speed and space	Vitesse et espace
Speed test: about {0} MB/s writing ({1}).	Test de vitesse : environ {0} Mo/s en écriture ({1}).
Speed test: not possible on {0}: (full, locked or read-only).	Test de vitesse : impossible sur {0}: (plein, verrouillé ou en lecture seule).
Speed test: this drive has no drive letter, so it was skipped.	Test de vitesse : ce disque n’a pas de lettre, donc il a été ignoré.
Spyware and adware sweep	Recherche de logiciels espions et publicitaires
Start anyway?	Commencer quand même ?
Start now?	Commencer maintenant ?
Start?	Commencer ?
Started	Commencé
Started the {0} paused startup program(s) again.	Les {0} programme(s) au démarrage mis en pause ont été relancés.
Starting the Windows 11 Setup Wizard. Click "Accept and install" in its window.	Lancement de l’Assistant d’installation de Windows 11. Cliquez sur « Accepter et installer » dans sa fenêtre.
Starting the system file check…	Lancement de la vérification des fichiers système…
Starting {0}…	Lancement de {0}…
Starts with Windows from an unusual place: {0}  ({1})	Démarre avec Windows depuis un endroit inhabituel : {0}  ({1})
Startup	Démarrage
Startup apps	Applis au démarrage
Startup programs: all start from normal places.	Programmes au démarrage : tous démarrent d’endroits normaux.
Status	État
Steam and Epic web caches; launchers rebuild them	Caches Web de Steam et Epic ; les lanceurs les refont
Step 1 of 3: recording what is on your PC now.	Étape 1 sur 3 : relevé de ce qui est sur votre PC maintenant.
Step 3 of 3: checking what the installer added.	Étape 3 sur 3 : vérification de ce que l’installateur a ajouté.
Stop	Arrêter
Stop / allow Wand pop-ups	Bloquer / permettre les fenêtres de Wand
Stop after current task	Arrêter après la tâche en cours
Stop it and close the Duplicate Finder? (No = keep it running in the background)	L’arrêter et fermer le Duplicate Finder ? (Non = la laisser continuer en arrière-plan)
Stop now?	Arrêter maintenant ?
Stop now? The target drive will be left only partly written.	Arrêter maintenant ? Le disque cible ne sera écrit qu’en partie.
Stop sending typing data	Arrêter d’envoyer les données de saisie
Stop sending typing data to Microsoft	Arrêter d’envoyer les données de saisie à Microsoft
Stop starting with Windows	Ne plus démarrer avec Windows
Stop waiting for this one	Ne plus attendre celui-ci
Stopped	Arrêté
Stopped: {0}	Arrêté : {0}
Stopping after current task…	Arrêt après la tâche en cours…
Stopping the current operation. Windows will tidy up after it; the scan can be run again at any time.	Arrêt de l’opération en cours. Windows fera le ménage après ; l’analyse peut être relancée à tout moment.
Stops the Start menu search box from sending what you type to Bing and showing web and AI results. Searching your own files and apps still works. Takes effect after you sign out and back in.	Empêche la recherche du menu Démarrer d’envoyer ce que vous tapez à Bing et d’afficher des résultats Web et d’IA. La recherche de vos fichiers et applis fonctionne toujours. S’applique après vous être déconnecté et reconnecté.
Store cache only; apps and purchases are kept	Cache du Store seulement ; les applis et achats sont gardés
Success	Réussi
Summary	Résumé
Switch On or Off AI	Activer ou désactiver l’IA
Switch between the simple view and every tool	Passer de la vue simple à tous les outils
Switch off AI	Désactiver l’IA
Switch off AI in Windows and web browsers	Désactiver l’IA dans Windows et les navigateurs Web
Switch to the DRDirect Cleaner. Use its Remove programs button to come back here.	Passer au Cleaner DRDirect. Utilisez son bouton Retirer des programmes pour revenir ici.
Switched on and off {0} times.	Allumé et éteint {0} fois.
Switched on and off: this drive does not report how many times.	Allumé et éteint : ce disque n’indique pas combien de fois.
Switches "SdbinstMergeDbTask" back on, exactly as Windows has it by default. Does nothing if it is already on.	Réactive « SdbinstMergeDbTask », exactement comme Windows l’a par défaut. Ne fait rien s’il est déjà actif.
Switches Hibernate and Fast Startup back on. Needs free space on C: about the size of your memory. If there is not enough room, the Cleaner leaves it off and tells you to use Sleep instead.	Réactive la veille prolongée et le démarrage rapide. Il faut sur C: environ autant d’espace libre que de mémoire. S’il n’y a pas assez de place, le Cleaner la laisse désactivée et vous conseille la mise en veille à la place.
Switches off "SdbinstMergeDbTask", a Windows task that only helps very old programs run. Some PCs protect it; if so, the Cleaner tells you and leaves it alone. Nothing is deleted, and "Turn the compatibility task back on" undoes it.	Désactive « SdbinstMergeDbTask », une tâche Windows qui aide seulement de très vieux programmes à fonctionner. Certains PC la protègent ; dans ce cas, le Cleaner vous le dit et la laisse tranquille. Rien n’est supprimé, et « Réactiver la tâche de compatibilité » l’annule.
Switches off Recall (the snapshots of your screen), Click to Do, and the AI tools in Paint and Notepad. Takes effect after the restart. "Turn back on" undoes it.	Désactive Recall (les captures de votre écran), Click to Do et les outils d’IA dans Paint et le Bloc-notes. S’applique après le redémarrage. « Réactiver » l’annule.
Switches the Windows firewall, Microsoft Defender real-time protection and Windows Update back on if any of them are off. When another antivirus or firewall is in charge, that part is left alone.	Réactive le pare-feu Windows, la protection en temps réel de Microsoft Defender et Windows Update s’ils sont désactivés. Quand un autre antivirus ou pare-feu s’en occupe, cette partie n’est pas touchée.
Sync	Synchro
System	Système
System File Checker	Vérificateur des fichiers système
System File Checker could not start the Windows Modules Installer service. Restart the PC and run it again.	Le Vérificateur des fichiers système n’a pas pu démarrer le service Programme d’installation des modules Windows. Redémarrez le PC et relancez-le.
System File Checker did not report a result. It was most likely stopped before it finished.	Le Vérificateur des fichiers système n’a pas donné de résultat. Il a sans doute été arrêté avant la fin.
System File Checker finished with exit code {0}.	Le Vérificateur des fichiers système a fini avec le code de sortie {0}.
System File Checker finished.	Le Vérificateur des fichiers système a fini.
System File Checker made no progress{0} for {1} minutes, so the Cleaner stopped waiting for it. Windows was most likely busy installing an update. Restart the PC and run it again.	Le Vérificateur des fichiers système n’a pas avancé{0} pendant {1} minutes, donc le Cleaner a arrêté de l’attendre. Windows installait sans doute une mise à jour. Redémarrez le PC et relancez-le.
System File Checker {0}, so the Cleaner stopped it. Windows is most likely busy installing an update. Let Windows Update finish (Settings > Windows Update), restart the PC, then run System File Checker again. Nothing was changed.	Le Vérificateur des fichiers système {0}, donc le Cleaner l’a arrêté. Windows installe sans doute une mise à jour. Laissez Windows Update finir (Paramètres > Windows Update), redémarrez le PC, puis relancez le Vérificateur des fichiers système. Rien n’a été changé.
System error memory dump files	Fichiers de vidage mémoire d’erreurs système
System error minidump files	Fichiers minidump d’erreurs système
TCP heuristics before reset:	Heuristique TCP avant la réinitialisation :
TEST MODE is active. External Windows operations are simulated and file deletion is limited to the supplied test folder.	Le MODE TEST est actif. Les opérations Windows externes sont simulées et la suppression de fichiers est limitée au dossier de test fourni.
TEST MODE: nothing was changed.	MODE TEST : rien n’a été changé.
TEST MODE: nothing was opened.	MODE TEST : rien n’a été ouvert.
TEST MODE: nothing was uninstalled.	MODE TEST : rien n’a été désinstallé.
TEST MODE: restart was not performed.	MODE TEST : le redémarrage n’a pas été fait.
TEST MODE: the automatic restart was not performed.	MODE TEST : le redémarrage automatique n’a pas été fait.
TEST MODE: would run {0} {1}	MODE TEST : lancerait {0} {1}
TEST MODE: {0} settings were not changed.	MODE TEST : les réglages de {0} n’ont pas été changés.
TEST MODE: {0} was not changed.	MODE TEST : {0} n’a pas été changé.
THIS PC	CE PC
TIFF image	Image TIFF
TO PREVENT LOSING DATA, YOU NEED TO CLEAN SOME SPACE OUT OF {0}: NOW. Click	POUR ÉVITER DE PERDRE DES DONNÉES, VOUS DEVEZ LIBÉRER DE L’ESPACE SUR {0}: MAINTENANT. Cliquez sur
TOTAL SETS: {0}	TOTAL DES GROUPES : {0}
TOTAL THIS SESSION	TOTAL DE CETTE SESSION
TRIAL - 1 DAY LEFT	ESSAI - 1 JOUR RESTANT
TRIAL - {0} DAYS LEFT	ESSAI - {0} JOURS RESTANTS
TRIAL ENDS TODAY	L’ESSAI FINIT AUJOURD’HUI
Take "{0}" off the list of installed programs, without running its uninstaller?	Retirer « {0} » de la liste des programmes installés, sans lancer son désinstalleur ?
Takes a few seconds. Nothing is changed.	Prend quelques secondes. Rien n’est changé.
Takes out only the AI websites the Cleaner blocked.	Retire seulement les sites d’IA que le Cleaner a bloqués.
Taskbar jump lists and Recent Items	Listes de raccourcis de la barre des tâches et éléments récents
Telemetry settings are back to how they were before the Cleaner changed them. Restart Windows so the services start again.	Les réglages de télémétrie sont revenus comme avant que le Cleaner les change. Redémarrez Windows pour que les services redémarrent.
Temperature	Température
Temperature, life left and error counts are not available for this drive (some USB and RAID drives do not report them).	La température, la vie restante et le nombre d’erreurs ne sont pas disponibles pour ce disque (certains disques USB et RAID ne les indiquent pas).
Temporary cache only; logins and chats are kept	Cache temporaire seulement ; les connexions et conversations sont gardées
Test mode: the DRDirect Uninstaller Program would open here.	Mode test : le programme de désinstallation DRDirect s’ouvrirait ici.
Test version of the new DRDirect Uninstaller.	Version d’essai du nouveau désinstalleur DRDirect.
Text file	Fichier texte
Text file (*.txt)|*.txt	Fichier texte (*.txt)|*.txt
That ISO has no Windows image in it.	Cet ISO ne contient pas d’image Windows.
That ISO is not a Windows install ISO.	Cet ISO n’est pas un ISO d’installation de Windows.
That ISO is not for 64-bit Intel and AMD PCs.	Cet ISO n’est pas pour les PC Intel et AMD 64 bits.
That ISO is {0}, but this PC has {1}. Use a {2} ISO.	Cet ISO est {0}, mais ce PC a {1}. Utilisez un ISO de {2}.
That code is not correct for this PC. Check it and try again.	Ce code n’est pas bon pour ce PC. Vérifiez-le et réessayez.
That drive is no longer there.	Ce disque n’est plus là.
That file is no longer there.	Ce fichier n’est plus là.
That file or folder was not found.	Ce fichier ou ce dossier est introuvable.
That folder does not exist:	Ce dossier n’existe pas :
That is a Windows or system folder. It is never removed.	C’est un dossier de Windows ou du système. Il n’est jamais retiré.
That is a lot of startup programs and can slow sign-in. Turn the ones you do not need off in Windows Settings > Apps > Startup. Nothing was changed.	Cela fait beaucoup de programmes au démarrage et peut ralentir l’ouverture de session. Désactivez ceux dont vous n’avez pas besoin dans Paramètres Windows > Applications > Démarrage. Rien n’a été changé.
That is the Windows drive. Nothing was changed.	C’est le disque Windows. Rien n’a été changé.
That key is not correct for this PC. Check it and try again.	Cette clé n’est pas bonne pour ce PC. Vérifiez-la et réessayez.
That password is not right.	Ce mot de passe n’est pas le bon.
The AI Assistant is now off in Adobe Acrobat and Reader. Close Acrobat completely and open it again. Acrobat may say some settings are managed by your organization - that is what keeps the AI off. "Turn back on" removes it.	L’Assistant IA est maintenant désactivé dans Adobe Acrobat et Reader. Fermez Acrobat complètement et rouvrez-le. Acrobat peut dire que certains réglages sont gérés par votre organisation - c’est ce qui garde l’IA désactivée. « Réactiver » l’enlève.
The AI apps you picked will be uninstalled. They can be installed again from the Microsoft Store.	Les applis d’IA choisies seront désinstallées. Elles peuvent être réinstallées depuis le Microsoft Store.
The AI model {0} downloaded could not be fully deleted, probably because {0} is open. Close {0} completely, then run this again.	Le modèle d’IA téléchargé par {0} n’a pas pu être supprimé complètement, sans doute parce que {0} est ouvert. Fermez {0} complètement, puis relancez ceci.
The Advanced scan is set to shut this PC down when it finishes, after a 60 second countdown you can cancel. Pick another choice below if you do not want that.	L’analyse Avancée est réglée pour éteindre ce PC à la fin, après un compte à rebours de 60 secondes que vous pouvez annuler. Choisissez une autre option ci-dessous si vous ne le voulez pas.
The ChatGPT app	L’appli ChatGPT
The Claude app	L’appli Claude
The Claude website is now blocked in {0}. Close and reopen the browser. The Claude app was never touched, and "Turn back on" opens the website again.	Le site de Claude est maintenant bloqué dans {0}. Fermez et rouvrez le navigateur. L’appli Claude n’a jamais été touchée, et « Réactiver » rouvre le site.
The Claude website is open again in {0}. Close and reopen the browser. The Claude app was never touched.	Le site de Claude est de nouveau ouvert dans {0}. Fermez et rouvrez le navigateur. L’appli Claude n’a jamais été touchée.
The Claude website was not blocked by the Cleaner, so there was nothing to put back.	Le site de Claude n’avait pas été bloqué par le Cleaner, donc il n’y avait rien à remettre.
The Cleaner never removes exclusions. Yours stay exactly as they are.	Le Cleaner ne retire jamais d’exclusions. Les vôtres restent exactement comme elles sont.
The Copilot app	L’appli Copilot
The DRDirect Cleaner is not open, and this window does not know where it is kept.	Le Cleaner DRDirect n’est pas ouvert, et cette fenêtre ne sait pas où il se trouve.
The DRDirect Cleaner is not open. Open it from its shortcut.	Le Cleaner DRDirect n’est pas ouvert. Ouvrez-le depuis son raccourci.
The DRDirect Uninstaller Program was not found beside the Cleaner.	Le programme de désinstallation DRDirect n’a pas été trouvé à côté du Cleaner.
The DRDirect Uninstaller could not start:	Le désinstalleur DRDirect n’a pas pu démarrer :
The DRDirect Uninstaller needs a key.	Le désinstalleur DRDirect a besoin d’une clé.
The DRDirect folder is not where it should be, so nothing was removed.	Le dossier DRDirect n’est pas où il devrait être, donc rien n’a été retiré.
The Duplicate Finder is not included with this licence, and is not installed on this PC.	Le Duplicate Finder n’est pas inclus avec cette licence et n’est pas installé sur ce PC.
The Duplicate Finder is not included with this licence.	Le Duplicate Finder n’est pas inclus avec cette licence.
The Duplicate Finder is not included with this licence. Contact DRDirect for a code.	Le Duplicate Finder n’est pas inclus avec cette licence. Contactez DRDirect pour un code.
The Duplicate Finder is not included with this licence. Contact DRDirect to buy it.	Le Duplicate Finder n’est pas inclus avec cette licence. Contactez DRDirect pour l’acheter.
The Microsoft 365 Copilot app	L’appli Microsoft 365 Copilot
The PC could not be restarted from here: {0}	Le PC n’a pas pu être redémarré d’ici : {0}
The PC is kept awake until it is done. On a laptop, keep the lid open.{0}	Le PC reste éveillé jusqu’à la fin. Sur un portable, gardez l’écran ouvert.{0}
The Rescue USB app could not be downloaded right now, so the USB was not touched.	L’appli de la clé USB de secours n’a pas pu être téléchargée pour l’instant, donc la clé n’a pas été touchée.
The Rescue USB has no start-up menu to add Windows to.	La clé USB de secours n’a pas de menu de démarrage où ajouter Windows.
The Rescue USB is ready on drive {0}.	La clé USB de secours est prête sur le lecteur {0}.
The Rescue USB is ready. (Test mode: nothing was written.)	La clé USB de secours est prête. (Mode test : rien n’a été écrit.)
The Rescue app file '{0}' is missing on this PC. Check for updates in the Cleaner, then try again. Nothing was changed on the USB.	Le fichier « {0} » de l’appli de secours manque sur ce PC. Recherchez des mises à jour dans le Cleaner, puis réessayez. Rien n’a été changé sur la clé USB.
The Rescue part works as usual.	La partie secours fonctionne comme d’habitude.
The Rescue system could not be saved from the USB (robocopy code {0}). Nothing was changed.	Le système de secours n’a pas pu être enregistré depuis la clé USB (code robocopy {0}). Rien n’a été changé.
The Rescue system on the USB is not complete. Nothing was changed.	Le système de secours sur la clé USB n’est pas complet. Rien n’a été changé.
The USB holds {0} file(s), about {1}. Copy anything you want to keep first.	La clé USB contient {0} fichier(s), environ {1}. Copiez d’abord ce que vous voulez garder.
The USB is erased and formatted. Everything on it now will be deleted.{0}	La clé USB est effacée et formatée. Tout ce qui s’y trouve sera supprimé.{0}
The Windows ISO file was not found.	Le fichier ISO de Windows est introuvable.
The Windows component store is healthy. Nothing needed repairing.	Le magasin de composants de Windows est en bon état. Rien n’avait besoin d’être réparé.
The Windows firewall	Le pare-feu Windows
The Windows memory test has not been run on this PC yet (it is in Fix Windows). Only that test can prove RAM is fault-free.	Le test de mémoire de Windows n’a pas encore été fait sur ce PC (il est dans Réparer Windows). Seul ce test peut prouver que la RAM est sans défaut.
The Windows memory test is open. Choose "Restart now" or "Check for problems the next time I start my computer". Save your work first. The result appears after Windows starts again.	Le test de mémoire de Windows est ouvert. Choisissez « Redémarrer maintenant » ou « Rechercher les problèmes au prochain démarrage de l’ordinateur ». Enregistrez d’abord votre travail. Le résultat apparaît après le redémarrage de Windows.
The activation window could not be found in this copy. Contact DRDirect.	La fenêtre d’activation est introuvable dans cette copie. Contactez DRDirect.
The app	L’appli
The backup file is complete and not damaged.	Le fichier de sauvegarde est complet et non endommagé.
The backup has no partitions.	La sauvegarde n’a pas de partitions.
The backup may not fit on {0}: (about {1} needed, {2} free). Free some space or plug in a bigger drive.	La sauvegarde n’entrera peut-être pas sur {0}: (environ {1} nécessaires, {2} libres). Libérez de l’espace ou branchez un plus grand disque.
The browsers you picked will show "Managed by your organization" - that is what keeps their AI off. "Turn back on" removes it.	Les navigateurs choisis afficheront « Géré par votre organisation » - c’est ce qui garde leur IA désactivée. « Réactiver » l’enlève.
The check could not finish: {0}	La vérification n’a pas pu se terminer : {0}
The check failed: {0} is missing on the USB.	La vérification a échoué : {0} manque sur la clé USB.
The compatibility task is already off. Nothing was changed.	La tâche de compatibilité est déjà désactivée. Rien n’a été changé.
The compatibility task is already on. Nothing was changed.	La tâche de compatibilité est déjà active. Rien n’a été changé.
The compatibility task is now {0}.	La tâche de compatibilité est maintenant {0}.
The countdown has finished. Windows is restarting now.	Le compte à rebours est terminé. Windows redémarre maintenant.
The countdown has finished. Windows is shutting down now.	Le compte à rebours est terminé. Windows s’éteint maintenant.
The data does not fit. {0} holds {1} of data (plus {2} in the other partitions), and the target only has room for {3} on {0}. Use a bigger target drive.	Les données n’entrent pas. {0} contient {1} de données (plus {2} dans les autres partitions), et la cible n’a de place que pour {3} pour {0}. Utilisez un disque cible plus grand.
The download was not complete or was changed on the way. Nothing was changed on the USB. Please try again.	Le téléchargement n’était pas complet ou a été modifié en chemin. Rien n’a été changé sur la clé USB. Réessayez.
The downloaded file is not signed by Microsoft.	Le fichier téléchargé n’est pas signé par Microsoft.
The downloaded file was not signed by Microsoft, so it was deleted and NOT opened.	Le fichier téléchargé n’était pas signé par Microsoft, donc il a été supprimé et N’A PAS été ouvert.
The drive being copied is the slowest part.	Le disque copié est la partie la plus lente.
The drive has been copied.	Le disque a été copié.
The drive has been restored.	Le disque a été restauré.
The drive is smaller than the one the backup came from, and the backup fits: it is put back, and the main partition is then grown to fill the drive.	Le disque est plus petit que celui d’où vient la sauvegarde, et la sauvegarde entre : elle est remise, puis la partition principale est agrandie pour remplir le disque.
The drive or image ended earlier than expected.	Le disque ou la sauvegarde s’est terminé plus tôt que prévu.
The drive the image is saved on is the slowest part.	Le disque où la sauvegarde est enregistrée est la partie la plus lente.
The embedded maintenance engine could not be located beside the application.	Le moteur d’entretien intégré est introuvable à côté de l’application.
The fast engine could not be prepared for the Rescue system. Nothing was changed on the USB.	Le moteur rapide n’a pas pu être préparé pour le système de secours. Rien n’a été changé sur la clé USB.
The file name must end in .drimg	Le nom du fichier doit finir par .drimg
The firewall is off	Le pare-feu est désactivé
The free try covers the Safe scan. Contact DRDirect for a code to unlock the rest.	L’essai gratuit couvre l’analyse Sûre. Contactez DRDirect pour un code qui débloque le reste.
The full sweep. Cookies are never ticked, so nobody gets signed out.	Le grand ménage. Les témoins (cookies) ne sont jamais cochés, donc personne n’est déconnecté.
The hibernation file; Hibernate and Fast Startup stop until turned back on	Le fichier de veille prolongée ; la veille prolongée et le démarrage rapide s’arrêtent jusqu’à leur réactivation
The image cannot be saved on the drive you are copying. Choose a different drive.	La sauvegarde ne peut pas être enregistrée sur le disque que vous copiez. Choisissez un autre disque.
The image file is cut short.	Le fichier de sauvegarde est incomplet.
The image file is damaged (bad block at	Le fichier de sauvegarde est endommagé (bloc défectueux à
The image file is damaged (bad block at 0).	Le fichier de sauvegarde est endommagé (bloc défectueux à 0).
The image file is damaged (checksum does not match).	Le fichier de sauvegarde est endommagé (la somme de contrôle ne correspond pas).
The image file is damaged (size does not match).	Le fichier de sauvegarde est endommagé (la taille ne correspond pas).
The image file is damaged.	Le fichier de sauvegarde est endommagé.
The image file is stored on the drive you are restoring to. Copy it to another drive first.	Le fichier de sauvegarde est sur le disque que vous restaurez. Copiez-le d’abord sur un autre disque.
The installer has finished	L’installateur a terminé
The job is still running. Press Stop first, or wait until it is done.	Le travail est encore en cours. Appuyez d’abord sur Arrêter, ou attendez qu’il soit fini.
The last Windows memory test ({0}) found no errors.	Le dernier test de mémoire de Windows ({0}) n’a trouvé aucune erreur.
The last Windows memory test ({0}) reported a problem. Replace or reseat the RAM, and back up anything important.	Le dernier test de mémoire de Windows ({0}) a signalé un problème. Remplacez ou réinstallez la RAM, et sauvegardez tout ce qui est important.
The maintenance task ended without a final status.	La tâche d’entretien s’est terminée sans état final.
The memory check only looks. The Windows memory test needs a restart that Windows asks about, and this app never restarts the PC by itself.	La vérification de la mémoire ne fait que regarder. Le test de mémoire de Windows demande un redémarrage que Windows vous propose, et cette appli ne redémarre jamais le PC d’elle-même.
The name is too short to search for safely. Type the program's full name.	Le nom est trop court pour chercher sans risque. Tapez le nom complet du programme.
The name of the program you are installing:	Le nom du programme que vous installez :
The official {0} download page is open in the web browser. Download it and run the installer.	La page officielle de téléchargement de {0} est ouverte dans le navigateur. Téléchargez-le et lancez l’installateur.
The official {0} download page is open in the web browser. Download the app and run the installer.	La page officielle de téléchargement de {0} est ouverte dans le navigateur. Téléchargez l’appli et lancez l’installateur.
The operation had already moved on. It will stop at the end of this task.	L’opération était déjà passée à la suite. Elle s’arrêtera à la fin de cette tâche.
The partition table is not normal.	La table de partitions n’est pas normale.
The previous Windows installation used {0}; about {1} was freed.	L’ancienne installation de Windows prenait {0} ; environ {1} ont été libérés.
The processor is the slowest part (compressing and locking the data).	Le processeur est la partie la plus lente (compression et verrouillage des données).
The program "{0}" crashed or froze {1} times in the last 30 days.	Le programme « {0} » a planté ou figé {1} fois dans les 30 derniers jours.
The rescue file is missing. Nothing was changed.	Le fichier de secours manque. Rien n’a été changé.
The result is shown below. Nothing was changed on this PC.	Le résultat est affiché ci-dessous. Rien n’a été changé sur ce PC.
The safest steps only.	Seulement les étapes les plus sûres.
The scan was overdue. The Cleaner asked to run it and the customer chose not to. Nothing was scanned.	L’analyse était en retard. Le Cleaner a proposé de la faire et le client a refusé. Rien n’a été analysé.
The scan will pause when the step running now has finished. Press the button again to carry on without pausing.	L’analyse se mettra en pause quand l’étape en cours sera finie. Appuyez de nouveau sur le bouton pour continuer sans pause.
The source drive ended earlier than expected.	Le disque source s’est terminé plus tôt que prévu.
The source drive has no partitions.	Le disque source n’a pas de partitions.
The source drive's partition table is not normal.	La table de partitions du disque source n’est pas normale.
The target drive stopped accepting data.	Le disque cible n’accepte plus de données.
The target drive was only partly written. Run it again before using that drive.	Le disque cible n’a été écrit qu’en partie. Relancez-le avant d’utiliser ce disque.
The target is smaller, and the data fits: only the data is copied ({0} of {1}). {2} is made smaller to fit for the copy, then put back to its full size.	La cible est plus petite, et les données entrent : seules les données sont copiées ({0} sur {1}). {2} est réduit le temps de la copie, puis remis à sa pleine taille.
The target is too small. The source is {0} and the target is {1}.	La cible est trop petite. La source fait {0} et la cible fait {1}.
The taskbar did not come back by itself. Press Ctrl+Shift+Esc, choose Run new task, type explorer and press Enter.	La barre des tâches n’est pas revenue toute seule. Appuyez sur Ctrl+Maj+Échap, choisissez Exécuter une nouvelle tâche, tapez explorer et appuyez sur Entrée.
The two drives use different sector sizes, so the copy cannot be made smaller. Use a target as big as the source.	Les deux disques n’ont pas la même taille de secteur, donc la copie ne peut pas être réduite. Utilisez une cible aussi grande que la source.
The update contained no files this version can use.	La mise à jour ne contenait aucun fichier utilisable par cette version.
The update could not be installed: {0}	La mise à jour n’a pas pu être installée : {0}
The update did not finish. Nothing was changed.	La mise à jour n’a pas fini. Rien n’a été changé.
The update server returned something unreadable. Nothing was changed.	Le serveur de mise à jour a renvoyé quelque chose d’illisible. Rien n’a été changé.
The update was not signed by DRDirect and was refused.	La mise à jour n’était pas signée par DRDirect et a été refusée.
The updates could not be downloaded. Check that the internet is on.	Les mises à jour n’ont pas pu être téléchargées. Vérifiez qu’Internet fonctionne.
The window closed unexpectedly: {0}	La fenêtre s’est fermée de façon inattendue : {0}
The {0} biggest file(s) in your folders:	Les {0} plus gros fichier(s) de vos dossiers :
The {0} needs a key	{0} a besoin d’une clé
The {0} service could not be switched off: {1}	Le service {0} n’a pas pu être désactivé : {1}
The {0} start-up menu of the Rescue USB is not the usual one.	Le menu de démarrage {0} de la clé USB de secours n’est pas l’habituel.
Then, if this PC ever will not start, the same USB can run Windows Startup Repair or reinstall {0}.	Ainsi, si ce PC ne démarre plus un jour, la même clé USB pourra lancer la Réparation du démarrage de Windows ou réinstaller {0}.
There are more tools here	Il y a d’autres outils ici
There are no exclusions. Defender scans everything.	Il n’y a aucune exclusion. Defender analyse tout.
There are no reports to delete.	Il n’y a aucun rapport à supprimer.
There is a new update	Il y a une nouvelle mise à jour
There is no AI app or browser here that can be uninstalled.	Il n’y a ici aucune appli d’IA ni navigateur qui puisse être désinstallé.
There is no other drive to save the backup on. Plug in an external drive (USB), then come back to Secure.	Il n’y a aucun autre disque où enregistrer la sauvegarde. Branchez un disque externe (USB), puis revenez à Secure.
There is no previous Windows installation on this PC (Windows.old). Nothing was changed.	Il n’y a pas d’ancienne installation de Windows sur ce PC (Windows.old). Rien n’a été changé.
There is nothing to undo. A removal can only be undone for {0} hours.	Il n’y a rien à annuler. Un retrait ne peut être annulé que pendant {0} heures.
There was nothing to put back: the Cleaner has not changed any AI settings on this PC.	Il n’y avait rien à remettre : le Cleaner n’a changé aucun réglage d’IA sur ce PC.
There was nothing to restore: the Cleaner has not changed the Windows 11 ads and suggestions on this PC.	Il n’y avait rien à rétablir : le Cleaner n’a pas changé les publicités et suggestions de Windows 11 sur ce PC.
There was nothing to restore: the Cleaner has not changed the typing settings on this PC.	Il n’y avait rien à rétablir : le Cleaner n’a pas changé les réglages de saisie sur ce PC.
There was nothing to restore: the Cleaner has not turned off telemetry on this PC.	Il n’y avait rien à rétablir : le Cleaner n’a pas désactivé la télémétrie sur ce PC.
There were no old Windows Update backup folders on this PC.	Il n’y avait aucun ancien dossier de sauvegarde de Windows Update sur ce PC.
There were no older restore points to remove.	Il n’y avait aucun ancien point de restauration à retirer.
These are only listed. Nothing was changed or deleted - check each one yourself before removing it.	Ils sont seulement listés. Rien n’a été changé ni supprimé - vérifiez chacun vous-même avant de le retirer.
These checks only look at the PC and show what is using space or slowing it down. Nothing is changed or deleted.	Ces vérifications ne font que regarder le PC et montrer ce qui prend de la place ou le ralentit. Rien n’est changé ni supprimé.
These could let a virus hide. If you did not add them, remove them in Windows Security > Virus & threat protection > Manage settings > Exclusions:	Ils pourraient permettre à un virus de se cacher. Si vous ne les avez pas ajoutés, retirez-les dans Sécurité Windows > Protection contre les virus et menaces > Gérer les paramètres > Exclusions :
These problems should be checked by a technician.	Ces problèmes devraient être vérifiés par un technicien.
These programs are still running from the files being removed:	Ces programmes fonctionnent encore à partir des fichiers à retirer :
These {0} files will be moved to the Recycle Bin:	Ces {0} fichiers seront mis dans la Corbeille :
They go to the Recycle Bin, so you can restore any of them.	Ils vont dans la Corbeille, vous pouvez donc les récupérer.
This PC	Ce PC
This PC does not have the Rescue system yet. Clone & Backup makes it first, from Microsoft's free Windows ADK and Windows PE add-on (downloaded from Microsoft, needs the internet), then erases and formats the USB and makes the Rescue USB.	Ce PC n’a pas encore le système de secours. Copie et sauvegarde le crée d’abord, à partir du Windows ADK et du module Windows PE gratuits de Microsoft (téléchargés depuis Microsoft, il faut Internet), puis efface et formate la clé USB et crée la clé USB de secours.
This PC does not report any usable ID, so images cannot be locked to it.	Ce PC ne donne aucun identifiant utilisable, donc les sauvegardes ne peuvent pas y être verrouillées.
This PC is activated. Everything is unlocked.	Ce PC est activé. Tout est débloqué.
This PC runs Windows 11 version {0}. Microsoft stopped sending security updates for this version on {1}, so Windows Update can get stuck on old updates.	Ce PC a Windows 11 version {0}. Microsoft a cessé d’envoyer des mises à jour de sécurité pour cette version le {1}, donc Windows Update peut rester bloqué sur de vieilles mises à jour.
This backup cannot be put on a smaller drive: {0} Use a drive as big as the one it was made from.	Cette sauvegarde ne peut pas être mise sur un disque plus petit : {0} Utilisez un disque aussi grand que celui d’origine.
This backup does not fit on this drive. Its biggest partition is {0} and the drive is {1}. Make the backup again with Secure and answer Yes to "fit a smaller drive", or use a bigger drive.	Cette sauvegarde n’entre pas sur ce disque. Sa plus grande partition fait {0} et le disque fait {1}. Refaites la sauvegarde avec Secure en répondant Oui à « disque plus petit », ou utilisez un disque plus grand.
This backup was made by an older version and cannot be put on a smaller drive.	Cette sauvegarde a été faite par une ancienne version et ne peut pas être mise sur un disque plus petit.
This battery does not tell Windows how worn it is.	Cette pile n’indique pas à Windows son niveau d’usure.
This can take a few minutes. Please wait...	Ça peut prendre quelques minutes. Veuillez patienter...
This copy cannot be activated here. Contact DRDirect.	Cette copie ne peut pas être activée ici. Contactez DRDirect.
This copy has reached the end of its licence	Cette copie a atteint la fin de sa licence
This copy is activated. Enter a new code here to extend it.	Cette copie est activée. Entrez un nouveau code ici pour la prolonger.
This copy is activated. Nothing to do.	Cette copie est activée. Rien à faire.
This copy is not activated for this PC	Cette copie n’est pas activée pour ce PC
This copy of DRDirect PC Cleaner has been blocked. Please contact your software provider.	Cette copie de DRDirect Nettoyeur PC a été bloquée. Contactez votre fournisseur de logiciel.
This copy of DRDirect PC Cleaner needs attention. Please contact your software provider.	Cette copie de DRDirect Nettoyeur PC demande votre attention. Contactez votre fournisseur de logiciel.
This copy of the Duplicate Finder is not activated for this PC.	Cette copie du Duplicate Finder n’est pas activée pour ce PC.
This deletes the settings, reports, licence and the program file itself.	Ceci supprime les réglages, rapports, la licence et le fichier du programme lui-même.
This drive did not report a health status. That is normal for some external drives.	Ce disque n’a pas donné d’état de santé. C’est normal pour certains disques externes.
This drive has failed to read data {0} time(s) without being able to correct it. That is an early sign of a failing drive.	Ce disque n’a pas réussi à lire des données {0} fois sans pouvoir corriger. C’est un premier signe d’un disque qui lâche.
This drive has failed to write data {0} time(s) without being able to correct it. That is an early sign of a failing drive.	Ce disque n’a pas réussi à écrire des données {0} fois sans pouvoir corriger. C’est un premier signe d’un disque qui lâche.
This drive has logged {0} data error(s) of its own. That is an early sign of a failing drive.	Ce disque a noté lui-même {0} erreur(s) de données. C’est un premier signe d’un disque qui lâche.
This drive has used most of its rated write life. It still works, but plan to replace it.	Ce disque a utilisé la plus grande partie de sa durée d’écriture prévue. Il fonctionne encore, mais prévoyez de le remplacer.
This drive is too small. The image needs {0} and the drive is {1}.	Ce disque est trop petit. La sauvegarde a besoin de {0} et le disque fait {1}.
This file is part of DRDirect Duplicate Finder and cannot be opened on its own.	Ce fichier fait partie de DRDirect Duplicate Finder et ne peut pas être ouvert seul.
This file is part of DRDirect PC Cleaner and cannot be opened on its own.	Ce fichier fait partie de DRDirect Nettoyeur PC et ne peut pas être ouvert seul.
This image is locked to the PC that made it. It can only be opened on that PC.	Cette sauvegarde est verrouillée au PC qui l’a faite. Elle ne peut être ouverte que sur ce PC.
This is a DRDirect Rescue USB. It holds hidden boot files. Please do not change anything on it.	Ceci est une clé USB de secours DRDirect. Elle contient des fichiers de démarrage cachés. Ne changez rien dessus.
This is a RAID set. Windows sees the combined drive the RAID controller presents, not the disks behind it.	C’est un ensemble RAID. Windows voit le disque combiné présenté par le contrôleur RAID, pas les disques derrière.
This is a long clean-up. It can look stuck for a while, so please let it finish. Only tick it if you are ready to wait.	C’est un long nettoyage. Il peut sembler bloqué un moment, alors laissez-le finir. Cochez-le seulement si vous êtes prêt à attendre.
This is a long repair. It can look stuck for a while, so please let it finish. You can keep using the PC, but it may feel slower. Only tick it if you are ready to wait.	C’est une longue réparation. Elle peut sembler bloquée un moment, alors laissez-la finir. Vous pouvez continuer à utiliser le PC, mais il peut sembler plus lent. Cochez-la seulement si vous êtes prêt à attendre.
This is a long scan. It can sit at the same percentage for a while, so please let it finish. Only tick it if you are ready to wait.	C’est une longue analyse. Elle peut rester au même pourcentage un moment, alors laissez-la finir. Cochez-la seulement si vous êtes prêt à attendre.
This is not a DRDirect image file.	Ce n’est pas un fichier de sauvegarde DRDirect.
This is not an install record made by the DRDirect Uninstaller.	Ce n’est pas un relevé d’installation fait par le désinstalleur DRDirect.
This is only a reminder, and nothing is wrong with your files. Update PHP to 8.2.35, 8.3.36, 8.4.27 or 8.5.12 (or newer) when you can.	C’est seulement un rappel, et vos fichiers n’ont aucun problème. Mettez PHP à jour vers 8.2.35, 8.3.36, 8.4.27 ou 8.5.12 (ou plus récent) quand vous le pouvez.
This laptop is running on its battery.	Ce portable fonctionne sur sa pile.
This note is kept for good and cannot be deleted.	Cette note est gardée pour de bon et ne peut pas être supprimée.
This only happens once after an update and can take up to a minute. Please wait...	Cela n’arrive qu’une fois après une mise à jour et peut prendre jusqu’à une minute. Patientez...
This only removes the report files. It does not undo any maintenance that was already run.	Cela retire seulement les fichiers de rapport. Cela n’annule aucun entretien déjà fait.
This page switches off the AI built into Windows and your browsers. Nothing is deleted and every change can be undone. Start with "What AI is on this PC?", then use "Turn off all AI". To change just one thing, open "Show each item" at the bottom.	Cette page désactive l’IA intégrée à Windows et à vos navigateurs. Rien n’est supprimé et chaque changement peut être annulé. Commencez par « Quelle IA est sur ce PC ? », puis utilisez « Désactiver toute l’IA ». Pour changer une seule chose, ouvrez « Afficher chaque élément » en bas.
This program has no uninstaller. Use the Forced uninstaller to remove what is left of it.	Ce programme n’a pas de désinstalleur. Utilisez la désinstallation forcée pour retirer ce qui en reste.
This puts back every AI and browser setting the Cleaner changed on this PC, using the backups it saved.	Ceci remet chaque réglage d’IA et de navigateur que le Cleaner a changé sur ce PC, avec les copies qu’il a gardées.
This removes:	Ceci retire :
This runs 'winget upgrade --all' and updates every app winget can update on this PC.	Ceci lance « winget upgrade --all » et met à jour chaque appli que winget peut mettre à jour sur ce PC.
This task is not on this PC, so there is nothing to change.	Cette tâche n’est pas sur ce PC, donc il n’y a rien à changer.
This user	Cet utilisateur
This version of Windows does not offer the previous-installation cleanup, so Windows.old was left alone.	Cette version de Windows n’offre pas le nettoyage de l’ancienne installation, donc Windows.old n’a pas été touché.
This version of Windows does not provide the drive health information this check reads. Nothing was changed.	Cette version de Windows ne fournit pas les informations de santé des disques que cette vérification lit. Rien n’a été changé.
This will remove {0} files and {1} settings that "{2}" added.	Ceci retirera {0} fichiers et {1} paramètres que « {2} » a ajoutés.
This will run now:	Ceci va être fait maintenant :
This will uninstall ALL of these from this PC:	Ceci va désinstaller TOUT ceci de ce PC :
This wipes the crash reports and Windows event logs on THIS PC, so Reliability Monitor starts again with a clean chart.	Ceci efface les rapports de plantage et les journaux d’événements de Windows sur CE PC, pour que le Moniteur de fiabilité reparte avec un graphique propre.
Thumbnail cache	Cache des miniatures
Tick (or click on) one program in the list first.	Cochez (ou cliquez sur) un programme dans la liste d’abord.
Tick all	Tout cocher
Tick every item below, except the cookie item that signs you out	Cocher tous les éléments ci-dessous, sauf celui des témoins (cookies) qui vous déconnecte
Tick the apps you want to remove first.	Cochez d’abord les applications à retirer.
Tick the programs you want to remove in the list, then click here.	Cochez les programmes à retirer dans la liste, puis cliquez ici.
Tightening the bolts...	On resserre les boulons...
Time	Heure
Time taken: {0}	Durée : {0}
Time taken: {0} min {1} sec	Durée : {0} min {1} s
Time to clean. Do a Safe clean, or pick your own.	C’est le temps de nettoyer. Faites un nettoyage Sûr, ou choisissez le vôtre.
Tip: Windows is running from {0}, so it is copied while in use. For a perfect copy, start the PC from the Rescue USB.	Conseil : Windows tourne sur {0}, donc il est copié pendant qu’il sert. Pour une copie parfaite, démarrez le PC avec la clé USB de secours.
Tip: Windows is running from {0}, so the image is made while it is in use. For a perfect image, make it from the Rescue USB.	Conseil : Windows tourne sur {0}, donc la sauvegarde est faite pendant qu’il sert. Pour une sauvegarde parfaite, faites-la depuis la clé USB de secours.
Tip: remove the program with the normal Remove button first, then use this to clean up what is left.	Conseil : retirez d’abord le programme avec le bouton Retirer normal, puis utilisez ceci pour nettoyer ce qui reste.
To check those disks, open the RAID controller program (for example Intel Rapid Storage, MegaRAID or the motherboard RAID tool).	Pour vérifier ces disques, ouvrez le programme du contrôleur RAID (par exemple Intel Rapid Storage, MegaRAID ou l’outil RAID de la carte mère).
To make another Rescue USB, use the Rescue USB button in DRDirect Clone & Backup. Copying these files is not enough.	Pour créer une autre clé USB de secours, utilisez le bouton Clé USB de secours dans DRDirect Copie et sauvegarde. Copier ces fichiers ne suffit pas.
To make it fit, Windows first makes {0} smaller ({1} to {2}). Nothing is deleted. This can take a few minutes. When the copy is done, {3} is put back to its full size.{4}	Pour que ça entre, Windows réduit d’abord {0} ({1} à {2}). Rien n’est supprimé. Cela peut prendre quelques minutes. Après la copie, {3} est remis à sa pleine taille.{4}
To remove this program completely later, click "Remove tracked install" and choose this record:	Pour retirer complètement ce programme plus tard, cliquez sur « Retirer une installation suivie » et choisissez ce relevé :
To start a rescue, restart the PC from this USB. To use the app inside Windows, open DRDirect Clone & Backup.bat.	Pour lancer un secours, redémarrez le PC sur cette clé USB. Pour utiliser l’appli dans Windows, ouvrez DRDirect Clone & Backup.bat.
To turn any off, use Windows Settings > Apps > Startup. Nothing was changed.	Pour en désactiver, utilisez Paramètres Windows > Applications > Démarrage. Rien n’a été changé.
Today	Aujourd’hui
Too small:	Trop petite :
Total	Total
Total time it took:	Durée totale :
Total time it took: {0}:{1}:{2}	Durée totale : {0}:{1}:{2}
Total time:      {0} seconds	Durée totale :   {0} secondes
Total written so far: {0}.  Total read: {1}.	Total écrit jusqu’ici : {0}.  Total lu : {1}.
Trial - 1 day left	Essai - 1 jour restant
Trial - {0} days left	Essai - {0} jours restants
Trial ends today	L’essai finit aujourd’hui
Turn Hibernate back on	Réactiver la veille prolongée
Turn Hibernate off to free several GB, or back on	Désactiver la veille prolongée pour libérer plusieurs Go, ou la réactiver
Turn Windows 11 extras back on	Réactiver les extras de Windows 11
Turn back on	Réactiver
Turn everything back on	Tout réactiver
Turn off	Désactiver
Turn off Windows telemetry	Désactiver la télémétrie de Windows
Turn off all AI	Désactiver toute l’IA
Turn off all AI the Cleaner can switch off ({0} items)? Claude is left alone.	Désactiver toute l’IA que le Cleaner peut désactiver ({0} éléments) ? Claude n’est pas touché.
Turn off the Windows compatibility task	Désactiver la tâche de compatibilité de Windows
Turn protection back on	Réactiver la protection
Turn telemetry back on	Réactiver la télémétrie
Turn the compatibility task back on	Réactiver la tâche de compatibilité
Turn the raised 3D look of the Cleaner on or off	Activer ou désactiver l’effet 3D en relief du Cleaner
Turning it off and on again, in our heads...	On l’éteint et on le rallume, dans notre tête...
Turns every Windows and browser AI setting and website block on this page back on, exactly as it was before, and the "Managed by your organization" message goes away. Apps, and the switches in Gmail, Word and Edge, come back with their own "Reinstall" or "Turn back on" button.	Remet chaque réglage d’IA de Windows et des navigateurs et chaque blocage de site de cette page exactement comme avant, et le message « Géré par votre organisation » disparaît. Les applis, et les réglages de Gmail, Word et Edge, reviennent avec leur propre bouton « Réinstaller » ou « Réactiver ».
Turns off "Improve inking and typing" and typing personalization, so Windows stops collecting what you type and write to tune its suggestions. Your current settings are saved first, and "Restore typing settings" puts them back.	Désactive « Améliorer l’écriture manuscrite et la saisie » et la personnalisation de la saisie, pour que Windows arrête de recueillir ce que vous tapez et écrivez pour ajuster ses suggestions. Vos réglages actuels sont gardés d’abord, et « Rétablir les réglages de saisie » les remet.
Turns off Gemini in Chrome, the AI Mode button, "Help me write", and the AI tab and history features. Passwords, bookmarks and sign-ins are not touched. Chrome will show "Managed by your organization" while this is on.	Désactive Gemini dans Chrome, le bouton du mode IA, « Aide-moi à écrire » et les fonctions d’IA des onglets et de l’historique. Les mots de passe, favoris et connexions ne sont pas touchés. Chrome affichera « Géré par votre organisation » tant que c’est actif.
Turns off Hibernate and Fast Startup and deletes the hibernation file, which is usually 3 to 12 GB. Sleep keeps working. You can switch Hibernate back on with the row below.	Désactive la veille prolongée et le démarrage rapide et supprime le fichier de veille prolongée, qui fait souvent 3 à 12 Go. La mise en veille continue de fonctionner. Vous pouvez réactiver la veille prolongée avec la ligne ci-dessous.
Turns off Leo, the AI assistant built into Brave. Passwords, bookmarks and sign-ins are not touched. Brave will show "Managed by your organization" while this is on.	Désactive Leo, l’assistant d’IA intégré à Brave. Les mots de passe, favoris et connexions ne sont pas touchés. Brave affichera « Géré par votre organisation » tant que c’est actif.
Turns off the AI chatbot sidebar, AI link previews and AI tab groups. Passwords, bookmarks and sign-ins are not touched. Firefox settings will say the browser is managed by your organization while this is on.	Désactive le panneau de clavardage IA, les aperçus de liens IA et les groupes d’onglets IA. Les mots de passe, favoris et connexions ne sont pas touchés. Les paramètres de Firefox diront que le navigateur est géré par votre organisation tant que c’est actif.
Turns off the Copilot sidebar, Copilot reading the page, Copilot on the new tab page, and AI writing help. Passwords, bookmarks and sign-ins are not touched. Edge will show "Managed by your organization" while this is on.	Désactive le panneau Copilot, la lecture de la page par Copilot, Copilot sur la page Nouvel onglet et l’aide à l’écriture par IA. Les mots de passe, favoris et connexions ne sont pas touchés. Edge affichera « Géré par votre organisation » tant que c’est actif.
Turns the Windows pop-ups from Wand off, or back on. Wand itself keeps working normally.	Désactive ou réactive les fenêtres Windows de Wand. Wand continue de fonctionner normalement.
Type the program's name, pick its file or folder, or do both.	Tapez le nom du programme, choisissez son fichier ou son dossier, ou faites les deux.
Type: {0} in a USB dock or case	Type : {0} dans une station d’accueil ou un boîtier USB
Typing settings are back to how they were before the Cleaner changed them.	Les réglages de saisie sont revenus comme avant que le Cleaner les change.
UPDATE	MISE À JOUR
USB FLASH DRIVE	CLÉ USB
USB stick(s) big enough (8 GB or more):	Clé(s) USB assez grande(s) (8 Go ou plus) :
Unavailable	Non disponible
Unblock AI websites	Débloquer les sites d’IA
Unchecked	Non coché
Undo last removal	Annuler le dernier retrait
Uninstall	Désinstaller
Uninstall all AI	Désinstaller toute l’IA
Uninstall command	Commande de désinstallation
Uninstall command (you can change it before running it):	Commande de désinstallation (vous pouvez la changer avant de la lancer) :
Uninstall completely	Désinstaller complètement
Uninstall quietly	Désinstaller en silence
Uninstaller	Désinstalleur
Uninstaller missing	Désinstalleur manquant
Uninstaller name	Nom du désinstalleur
Uninstalls Brave from this PC.	Désinstalle Brave de ce PC.
Uninstalls Chrome from this PC. Bookmarks and passwords stay in your Google account.	Désinstalle Chrome de ce PC. Les favoris et mots de passe restent dans votre compte Google.
Uninstalls Firefox from this PC. Bookmarks and passwords stay in your Mozilla account.	Désinstalle Firefox de ce PC. Les favoris et mots de passe restent dans votre compte Mozilla.
Uninstalls the ChatGPT app. Chats saved in the ChatGPT account are not deleted, and the app can be installed again.	Désinstalle l’appli ChatGPT. Les conversations enregistrées dans le compte ChatGPT ne sont pas supprimées, et l’appli peut être réinstallée.
Uninstalls the Claude app. Chats saved in the Claude account are not deleted, and the app can be installed again.	Désinstalle l’appli Claude. Les conversations enregistrées dans le compte Claude ne sont pas supprimées, et l’appli peut être réinstallée.
Uninstalls the Microsoft 365 Copilot app (the Copilot chat and Office start page). Word, Excel, Outlook and your documents are not touched. It can be installed again from the Microsoft Store.	Désinstalle l’appli Microsoft 365 Copilot (le clavardage Copilot et la page d’accueil Office). Word, Excel, Outlook et vos documents ne sont pas touchés. Elle peut être réinstallée depuis le Microsoft Store.
Uninstalls the Microsoft Copilot app for every account on this PC. It can be installed again from the Microsoft Store.	Désinstalle l’appli Microsoft Copilot pour tous les comptes de ce PC. Elle peut être réinstallée depuis le Microsoft Store.
Unknown	Inconnu
Unknown maintenance task: {0}	Tâche d’entretien inconnue : {0}
Unregistered	Non enregistré
Unregistered application	Application non enregistrée
Unregistered applications	Applications non enregistrées
Unregistered scan:	Analyse des non enregistrés :
Unspecified	Non précisé
Untick all	Tout décocher
Untick every item below	Décocher tous les éléments ci-dessous
Unverified	Non vérifié
Unverified certificate	Certificat non vérifié
Up	Monter
Up to date	À jour
Update	Mise à jour
Update Cleanup	Nettoyage des mises à jour
Update Defender intelligence	Mettre à jour les définitions de Defender
Update all apps	Mettre à jour toutes les applis
Update every app with winget, in a colour PowerShell window	Mettre à jour chaque appli avec winget, dans une fenêtre PowerShell en couleur
Update failed: {0}	La mise à jour a échoué : {0}
Update my apps	Mettre à jour mes applis
Update the Cleaner	Mettre à jour le Cleaner
Update this program	Mettre à jour ce programme
Update {0} is available.	La mise à jour {0} est disponible.
Updated to {0}.	Mis à jour vers {0}.
Updated to {0}. Close and reopen this window to use it.	Mis à jour vers {0}. Fermez puis rouvrez cette fenêtre pour l’utiliser.
Updates are not available in this copy.	Les mises à jour ne sont pas offertes dans cette copie.
Updates available	Mises à jour disponibles
Updates the apps installed on this PC using Windows Package Manager (winget). Your files and settings are not touched.	Met à jour les applis installées sur ce PC avec le Gestionnaire de paquets Windows (winget). Vos fichiers et réglages ne sont pas touchés.
Updating apps in a colour PowerShell window. Close it when it says it has finished.	Mise à jour des applis dans une fenêtre PowerShell en couleur. Fermez-la quand elle dit qu’elle a fini.
Updating apps in a console window. Close it when it says it has finished.	Mise à jour des applis dans une fenêtre de console. Fermez-la quand elle dit qu’elle a fini.
Updating the Uninstaller	Mise à jour du désinstalleur
Upgrade to the newest Windows 11 now? The Cleaner downloads Microsoft's own Windows 11 Setup Wizard and starts it. Your files and programs are kept. It takes about an hour and the PC restarts a few times, so keep it plugged in.	Passer au plus récent Windows 11 maintenant ? Le Cleaner télécharge l’Assistant d’installation de Windows 11 de Microsoft et le lance. Vos fichiers et programmes sont gardés. Cela prend environ une heure et le PC redémarre quelques fois, alors gardez-le branché.
Use "Check for driver updates" above. This asks Microsoft what drivers are available for this PC and installs nothing.	Utilisez « Chercher des mises à jour de pilotes » plus haut. Cela demande à Microsoft quels pilotes sont disponibles pour ce PC et n’installe rien.
Use this folder	Utiliser ce dossier
Use this only for a program that is already gone. The entry is backed up first, so Undo can put it back.	Utilisez ceci seulement pour un programme déjà parti. L’entrée est sauvegardée d’abord, pour qu’Annuler puisse la remettre.
Valid	Valide
Value	Valeur
Verified	Vérifié
Verified certificate	Certificat vérifié
Version	Version
Version {0}	Version {0}
Version {0}  (you have {1})	Version {0}  (vous avez {1})
Version {0} is ready. Click here, then press Check for updates.	La version {0} est prête. Cliquez ici, puis appuyez sur Rechercher des mises à jour.
Version {0} is ready. Click to see what changed and install it.	La version {0} est prête. Cliquez pour voir ce qui a changé et l’installer.
Very good	Très bon
Video stream	Flux vidéo
Videos	Vidéos
View results	Voir les résultats
Virus	Virus
Virus protection is off	La protection antivirus est désactivée
Virus protection: Microsoft Defender real-time protection is OFF.	Protection antivirus : la protection en temps réel de Microsoft Defender est DÉSACTIVÉE.
Virus protection: Microsoft Defender real-time protection is on.	Protection antivirus : la protection en temps réel de Microsoft Defender est active.
Virus protection: no active antivirus was found on this PC.	Protection antivirus : aucun antivirus actif n’a été trouvé sur ce PC.
Virus protection: {0} is protecting this PC.	Protection antivirus : {0} protège ce PC.
Voice recording	Enregistrement vocal
Vulnerable	Vulnérable
WARNING - Rescue USB	AVERTISSEMENT - Clé USB de secours
WAV audio	Audio WAV
WINDOWS HEALTH	SANTÉ DE WINDOWS
WMA audio	Audio WMA
WMV video	Vidéo WMV
Wait for it to finish, then try again. Starting another now would cancel the progress you can see.	Attendez la fin, puis réessayez. En lancer un autre maintenant annulerait la progression en cours.
Waiting	En attente
Waiting for another Windows repair to finish first…	Attente de la fin d’une autre réparation Windows…
Waiting for programs to close	En attente de la fermeture des programmes
Waiting for the drive to be read	Attente de la lecture du disque
Waiting for the file to be written	Attente de l’écriture du fichier
Wand pop-ups	Fenêtres de Wand
Wand pop-ups are now turned off.	Les fenêtres de Wand sont maintenant désactivées.
Wand pop-ups are turned back on.	Les fenêtres de Wand sont réactivées.
Wand still works normally. Messages inside the Wand window itself are not affected.	Wand fonctionne toujours normalement. Les messages dans la fenêtre de Wand ne changent pas.
Warning	Avertissement
Web and Bing results are now off in Start search. Sign out and back in for it to take effect. "Turn back on" removes it.	Les résultats Web et Bing sont maintenant désactivés dans la recherche du menu Démarrer. Déconnectez-vous et reconnectez-vous pour que ça s’applique. « Réactiver » l’enlève.
Web and Bing results in Start search: {0}	Résultats Web et Bing dans la recherche Démarrer : {0}
WebM video	Vidéo WebM
WebP image	Image WebP
Well-known junk programs: none found.	Programmes indésirables connus : aucun trouvé.
What AI is on this PC?	Quelle IA est sur ce PC ?
What Advanced does	Ce que fait Avancé
What Medium does	Ce que fait Moyen
What Safe mode does	Ce que fait le mode Sûr
What do you want to do?	Que voulez-vous faire ?
What is inside this PC, and where there is room to improve it. Nothing here is changed or installed.	Ce qu’il y a dans ce PC, et où il peut être amélioré. Rien n’est changé ni installé ici.
What is on the USB now will be replaced. It starts this PC only.	Ce qui est sur la clé USB sera remplacé. Elle démarre seulement ce PC.
What is on {0} now will be replaced by the copy.	Ce qui est sur {0} sera remplacé par la copie.
What is on {0} now will be replaced.	Ce qui est sur {0} sera remplacé.
What is on {0} now will be replaced.{1}	Ce qui est sur {0} sera remplacé.{1}
What to do: clean the dust out of the fans, and keep the vents clear.	Quoi faire : nettoyez la poussière des ventilateurs et gardez les grilles d’aération dégagées.
What to do: make sure the power cable is pushed in firmly at both ends. If it keeps happening, the power supply may need checking.	Quoi faire : vérifiez que le câble d’alimentation est bien enfoncé aux deux bouts. Si ça continue, l’alimentation devra peut-être être vérifiée.
What to do: run "Check my RAM" and "Check my drives". If they keep coming back, have the PC looked at.	Quoi faire : lancez « Vérifier ma RAM » et « Vérifier mes disques ». Si ça revient, faites examiner le PC.
What to do: run "Check my RAM" and "Fix Windows". If it keeps happening, have the PC looked at.	Quoi faire : lancez « Vérifier ma RAM » et « Réparer Windows ». Si ça continue, faites examiner le PC.
What to do: run "Fix Windows" (Windows Update repair), then restart and check for updates again.	Quoi faire : lancez « Réparer Windows » (réparation de Windows Update), puis redémarrez et recherchez de nouveau les mises à jour.
What to do: switch the PC off and blow the dust out of the fans with compressed air.	Quoi faire : éteignez le PC et soufflez la poussière des ventilateurs avec de l’air comprimé.
What to do: update that program, or uninstall it and install it again.	Quoi faire : mettez ce programme à jour, ou désinstallez-le et réinstallez-le.
Whatever you last copied	Ce que vous avez copié en dernier
When Notepad starts	Au démarrage du Bloc-notes
When everything has finished, Windows needs to restart or shut down. Choose below which, and when. You get a countdown first, and you can cancel it or go sooner.	Quand tout est fini, Windows doit redémarrer ou s’éteindre. Choisissez ci-dessous lequel, et quand. Un compte à rebours s’affiche d’abord, et vous pouvez l’annuler ou devancer.
When should Windows restart or shut down after the clean?	Quand Windows doit-il redémarrer ou s’éteindre après le nettoyage ?
When the clean-up finishes, restart Windows:	À la fin du nettoyage, redémarrer Windows :
When the window opens	À l’ouverture de la fenêtre
When you open Notepad, you get a clean, empty page. Old notes will not pop up anymore. Your saved files are not touched.	Quand vous ouvrez le Bloc-notes, vous avez une page vide et propre. Les anciennes notes ne réapparaîtront plus. Vos fichiers enregistrés ne sont pas touchés.
Whispering encouragement to your PC...	On murmure des encouragements à votre PC...
Why your {0}: drive needs space	Pourquoi votre disque {0}: a besoin d’espace
Window closed	Fenêtre fermée
Window opening	Ouverture de la fenêtre
Windows 11 ads and suggestions are back to how they were before the Cleaner changed them.	Les publicités et suggestions de Windows 11 sont revenues comme avant que le Cleaner les change.
Windows 11 ads and suggestions are off. Sign out and back in to see the full effect. Your previous settings were saved; "Turn Windows 11 extras back on" puts them back.	Les publicités et suggestions de Windows 11 sont désactivées. Déconnectez-vous et reconnectez-vous pour voir tout l’effet. Vos anciens réglages ont été gardés ; « Réactiver les extras de Windows 11 » les remet.
Windows 11: turn off ads and suggestions	Windows 11 : désactiver les publicités et suggestions
Windows Defender history log	Historique de Windows Defender
Windows Disk Cleanup	Nettoyage de disque de Windows
Windows Disk Cleanup finished with exit code {0}.	Le Nettoyage de disque de Windows a fini avec le code de sortie {0}.
Windows Disk Cleanup stopped doing anything for {0} minutes, so the Cleaner closed it and carried on with the rest of the scan. Nothing was harmed. Restarting the PC usually clears this.	Le Nettoyage de disque de Windows n’a rien fait pendant {0} minutes, donc le Cleaner l’a fermé et a continué le reste de l’analyse. Rien n’a été abîmé. Redémarrer le PC règle généralement ça.
Windows Disk Cleanup was already open on this PC, so the Cleaner did not start a second one. Close Disk Cleanup and run this step again.	Le Nettoyage de disque de Windows était déjà ouvert sur ce PC, donc le Cleaner n’en a pas lancé un deuxième. Fermez le Nettoyage de disque et relancez cette étape.
Windows Disk Cleanup was still running after {0} minutes, so the Cleaner closed it and carried on with the rest of the scan. Nothing was harmed.	Le Nettoyage de disque de Windows tournait encore après {0} minutes, donc le Cleaner l’a fermé et a continué le reste de l’analyse. Rien n’a été abîmé.
Windows Error Reporting queue	File d’attente du Rapport d’erreurs Windows
Windows Event Logs	Journaux d’événements Windows
Windows ISO file (*.iso)|*.iso	Fichier ISO de Windows (*.iso)|*.iso
Windows Search: turn off web and Bing results	Recherche Windows : désactiver les résultats Web et Bing
Windows Search: turn web and Bing results back on	Recherche Windows : réactiver les résultats Web et Bing
Windows Store apps	Applications du Windows Store
Windows Store apps...	Applications du Windows Store...
Windows Update could not be started: {0}	Windows Update n’a pas pu être lancé : {0}
Windows Update could not finish:	Windows Update n’a pas pu finir :
Windows Update download cache	Cache de téléchargement de Windows Update
Windows Update is busy or waiting for a restart, so its download cache was left alone. Try again after restarting.	Windows Update est occupé ou attend un redémarrage, donc son cache de téléchargement n’a pas été touché. Réessayez après avoir redémarré.
Windows Update needs a look	Windows Update est à vérifier
Windows Update repair	Réparation de Windows Update
Windows Update repair was skipped because it already ran within the last 30 days.	La réparation de Windows Update a été sautée car elle a déjà été faite dans les 30 derniers jours.
Windows Update: automatic updates are turned off by a policy setting. The Cleaner does not change policies.	Windows Update : les mises à jour automatiques sont désactivées par une stratégie. Le Cleaner ne change pas les stratégies.
Windows Update: on, but the last update was installed {0} days ago. Open Settings > Windows Update and install what is waiting.	Windows Update : actif, mais la dernière mise à jour a été installée il y a {0} jours. Ouvrez Paramètres > Windows Update et installez ce qui attend.
Windows Update: on.	Windows Update : actif.
Windows Update: on. Last update installed {0}.	Windows Update : actif. Dernière mise à jour installée {0}.
Windows Update: switched OFF, so this PC is not getting security fixes.	Windows Update : DÉSACTIVÉ, donc ce PC ne reçoit pas les correctifs de sécurité.
Windows already saved a restore point in the last day, so it did not make another. That one still protects this PC.	Windows a déjà créé un point de restauration dans la dernière journée, donc il n’en a pas fait d’autre. Celui-là protège toujours ce PC.
Windows and application temporary folders	Dossiers temporaires de Windows et des applications
Windows cannot make {0} small enough for the target. The smallest it allows now is {1}, and the target has room for {2}. Some Windows files that cannot be moved (often the page file or hibernation file) sit far into the drive. Nothing was copied and nothing was changed.	Windows ne peut pas réduire {0} assez pour la cible. Le minimum qu’il permet maintenant est {1}, et la cible a de la place pour {2}. Certains fichiers Windows qui ne peuvent pas être déplacés (souvent le fichier d’échange ou de veille prolongée) sont loin dans le disque. Rien n’a été copié ni changé.
Windows cannot tell whether a newer BIOS exists. Check the manufacturer support page for the board above.	Windows ne peut pas savoir s’il existe un BIOS plus récent. Vérifiez la page de soutien du fabricant pour la carte mère ci-dessus.
Windows could not be copied in parts (DISM code {0}).	Windows n’a pas pu être copié en plusieurs parties (code DISM {0}).
Windows could not be prepared (DISM code {0}).	Windows n’a pas pu être préparé (code DISM {0}).
Windows could not download the files it needs to repair itself ({0}). Check the internet connection and that Windows Update works, then run {1} again.	Windows n’a pas pu télécharger les fichiers dont il a besoin pour se réparer ({0}). Vérifiez la connexion Internet et que Windows Update fonctionne, puis relancez {1}.
Windows could not reach the update service. Check the internet connection and try again.	Windows n’a pas pu joindre le service de mise à jour. Vérifiez la connexion Internet et réessayez.
Windows could not run System File Checker right now. Restart the PC and run it again.	Windows n’a pas pu lancer le Vérificateur des fichiers système pour l’instant. Redémarrez le PC et relancez-le.
Windows could not turn Hibernate off (exit code {0}).	Windows n’a pas pu désactiver la veille prolongée (code de sortie {0}).
Windows could not turn Hibernate on (exit code {0}).	Windows n’a pas pu activer la veille prolongée (code de sortie {0}).
Windows did not answer. Try again in a moment.	Windows n’a pas répondu. Réessayez dans un moment.
Windows did not list the memory sticks. Some PCs hide this.	Windows n’a pas listé les barrettes de mémoire. Certains PC cachent cette information.
Windows did not make {0} small enough. Nothing was copied.	Windows n’a pas assez réduit {0}. Rien n’a été copié.
Windows did not provide a Local AppData folder.	Windows n’a pas fourni de dossier AppData local.
Windows did not return any hardware details on this PC.	Windows n’a donné aucun détail sur le matériel de ce PC.
Windows does not allow Edge to be uninstalled.	Windows ne permet pas de désinstaller Edge.
Windows does not allow Edge to be uninstalled. Use "Turn off" for its AI instead.	Windows ne permet pas de désinstaller Edge. Utilisez plutôt « Désactiver » pour son IA.
Windows does not let Edge be uninstalled. Turn its AI off instead.	Windows ne permet pas de désinstaller Edge. Désactivez plutôt son IA.
Windows found damage in its component store and repaired it. Restart the PC to finish.	Windows a trouvé des dommages dans son magasin de composants et les a réparés. Redémarrez le PC pour terminer.
Windows has a repair waiting for a restart, so System File Checker cannot run yet. Restart the PC and run it again.	Windows a une réparation qui attend un redémarrage, donc le Vérificateur des fichiers système ne peut pas encore tourner. Redémarrez le PC et relancez-le.
Windows has an update or repair waiting for a restart ({0}). Restart the PC and run {1} again.	Windows a une mise à jour ou une réparation qui attend un redémarrage ({0}). Redémarrez le PC et relancez {1}.
Windows has been running for {0} day(s) {1} hour(s).	Windows tourne depuis {0} jour(s) {1} heure(s).
Windows has recorded no memory hardware errors in the last 30 days.	Windows n’a noté aucune erreur matérielle de mémoire dans les 30 derniers jours.
Windows install or repair	Installation ou réparation de Windows
Windows installed	Windows installé
Windows is making {0} smaller for the backup. This can take a few minutes - please wait...	Windows réduit {0} pour la sauvegarde. Cela peut prendre quelques minutes - patientez...
Windows is making {0} smaller so the copy fits. This can take a few minutes - please wait...	Windows réduit {0} pour que la copie entre. Cela peut prendre quelques minutes - patientez...
Windows is running from the drive you chose to copy onto, so it cannot be overwritten from inside Windows.	Windows tourne sur le disque choisi pour recevoir la copie, donc il ne peut pas être écrasé depuis Windows.
Windows is running from this drive, so it cannot be overwritten from inside Windows. Restore it from the rescue USB instead.	Windows tourne sur ce disque, donc il ne peut pas être écrasé depuis Windows. Restaurez-le plutôt depuis la clé USB de secours.
Windows is up to date. Nothing to install.	Windows est à jour. Rien à installer.
Windows needs room to breathe. A drive that is nearly full stops working properly, and without free space things start to go wrong. If it stays this full:	Windows a besoin d’espace pour respirer. Un disque presque plein ne fonctionne plus bien, et sans espace libre les problèmes commencent. S’il reste aussi plein :
Windows no longer collects typing and handwriting to tune its suggestions. Your previous settings were saved; "Restore typing settings" puts them back.	Windows ne recueille plus la saisie et l’écriture manuscrite pour ajuster ses suggestions. Vos anciens réglages ont été gardés ; « Rétablir les réglages de saisie » les remet.
Windows noted {0} hardware hiccup(s) in the last 30 days.	Windows a noté {0} petit(s) problème(s) matériel(s) dans les 30 derniers jours.
Windows only shares temperature, life left, age and power-on counts with an administrator. Open the Cleaner as administrator to see them.	Windows ne partage la température, la vie restante, l’âge et le nombre de mises sous tension qu’avec un administrateur. Ouvrez le Cleaner en administrateur pour les voir.
Windows ransomware protection (Controlled folder access) is on, so it will stop the DRDirect Uninstaller from removing leftovers in folders like Documents and Desktop.	La protection contre les rançongiciels de Windows (Accès contrôlé aux dossiers) est active : elle empêchera le désinstalleur DRDirect de retirer les restes dans des dossiers comme Documents et Bureau.
Windows recorded {0} hardware error(s) mentioning memory in the last 30 days. That can mean faulty or badly seated RAM. Run the "Memory test" in Fix Windows to check it properly.	Windows a noté {0} erreur(s) matérielle(s) liée(s) à la mémoire dans les 30 derniers jours. Cela peut vouloir dire de la RAM défectueuse ou mal installée. Lancez le « Test de la mémoire » dans Réparer Windows pour bien la vérifier.
Windows repairs are separate from cleanup. Creating a restore point is recommended before repair operations.	Les réparations de Windows sont séparées du nettoyage. Il est conseillé de créer un point de restauration avant les réparations.
Windows reports this drive as "{0}". Back up anything important on it now and have the drive replaced.	Windows indique ce disque comme « {0} ». Sauvegardez maintenant tout ce qui est important dessus et faites remplacer le disque.
Windows reports this drive as healthy.	Windows indique que ce disque est en bonne santé.
Windows reports this drive status as: {0}.	Windows indique l’état de ce disque : {0}.
Windows restart scheduled for 5 seconds. Save any remaining work now.	Redémarrage de Windows prévu dans 5 secondes. Enregistrez maintenant le travail qui reste.
Windows shut down scheduled for 5 seconds. Save any remaining work now.	Arrêt de Windows prévu dans 5 secondes. Enregistrez maintenant le travail qui reste.
Windows still has this task in its old state. It is protected, and this PC would not let it be changed. Nothing else was affected.	Windows garde cette tâche dans son ancien état. Elle est protégée, et ce PC n’a pas permis de la changer. Rien d’autre n’a été touché.
Windows stopped and restarted on its own {0} time(s) in the last 30 days.	Windows s’est arrêté et redémarré tout seul {0} fois dans les 30 derniers jours.
Windows telemetry is off: {0} service(s) and {1} scheduled task(s) switched off, and the data-collection policies set (Windows, Edge, Chrome, Brave, Firefox, NVIDIA, Office). Your previous settings were saved; "Turn telemetry back on" puts them back.	La télémétrie de Windows est désactivée : {0} service(s) et {1} tâche(s) planifiée(s) désactivé(s), et les stratégies de collecte de données réglées (Windows, Edge, Chrome, Brave, Firefox, NVIDIA, Office). Vos anciens réglages ont été gardés ; « Réactiver la télémétrie » les remet.
Windows temporary files	Fichiers temporaires de Windows
Windows took too long to save a restore point, so the Cleaner stopped waiting and carried on. Nothing was changed by this step.	Windows a pris trop de temps à créer un point de restauration, donc le Cleaner a arrêté d’attendre et a continué. Rien n’a été changé par cette étape.
Windows updates	Mises à jour Windows
Windows was NOT added:	Windows N’A PAS été ajouté :
Windows will restart in {0} to finish the repairs. Save your work. Click Restart now to go sooner, or Restart later to cancel.	Windows va redémarrer dans {0} pour finir les réparations. Enregistrez votre travail. Cliquez sur Redémarrer maintenant pour devancer, ou Redémarrer plus tard pour annuler.
Windows will shut down in {0} because the clean is done. Save your work. Click Shut down now to go sooner, or Cancel shut down to stop it.	Windows va s’éteindre dans {0} car le nettoyage est fini. Enregistrez votre travail. Cliquez sur Éteindre maintenant pour devancer, ou Annuler l’arrêt pour l’arrêter.
Windows would not let go of {0} because the Cleaner is not running as administrator. Close it and open it with Run as administrator.	Windows n’a pas voulu libérer {0} car le Cleaner ne tourne pas en administrateur. Fermez-le et ouvrez-le avec Exécuter en tant qu’administrateur.
Windows would not let go of {0}. Close File Explorer windows and run it again.	Windows n’a pas voulu libérer {0}. Fermez les fenêtres de l’Explorateur de fichiers et relancez-le.
Windows would not switch off {0} item(s): {1}. Windows protects some of its own tasks; the rest of the list is done.	Windows n’a pas voulu désactiver {0} élément(s) : {1}. Windows protège certaines de ses propres tâches ; le reste de la liste est fait.
Windows' own Windows Update does the work, in a separate window that shows each update.	C’est le Windows Update de Windows qui fait le travail, dans une fenêtre séparée qui montre chaque mise à jour.
Windows: put Recall back	Windows : remettre Recall
Windows: remove the Copilot app	Windows : retirer l’appli Copilot
Windows: remove the Microsoft 365 Copilot app	Windows : retirer l’appli Microsoft 365 Copilot
Windows: turn Recall and the AI in Paint and Notepad back on	Windows : réactiver Recall et l’IA dans Paint et le Bloc-notes
Windows: turn off Recall and AI in Paint and Notepad	Windows : désactiver Recall et l’IA dans Paint et le Bloc-notes
Windows: uninstall Recall completely	Windows : désinstaller complètement Recall
Wipes free space on SSD and NVMe drives; files you keep are not touched	Nettoie l’espace libre des disques SSD et NVMe ; les fichiers gardés ne sont pas touchés
Word and Excel: turn Copilot back on	Word et Excel : réactiver Copilot
Word and Excel: turn off Copilot	Word et Excel : désactiver Copilot
Word document	Document Word
Word is not installed on this PC. Nothing was opened.	Word n’est pas installé sur ce PC. Rien n’a été ouvert.
Word is opening. Click File > Options > Copilot, tick Enable Copilot and click OK, then close and reopen Word. Do the same in Excel and PowerPoint.	Word s’ouvre. Cliquez sur Fichier > Options > Copilot, cochez Activer Copilot et cliquez sur OK, puis fermez et rouvrez Word. Faites pareil dans Excel et PowerPoint.
Word is opening. Click File > Options > Copilot, untick Enable Copilot and click OK, then close and reopen Word. Do the same in Excel and PowerPoint.	Word s’ouvre. Cliquez sur Fichier > Options > Copilot, décochez Activer Copilot et cliquez sur OK, puis fermez et rouvrez Word. Faites pareil dans Excel et PowerPoint.
Writing the image file	Écriture du fichier de sauvegarde
X days left	X jours restants
YOU MAKE THE LAST CLICK	VOUS FAITES LE DERNIER CLIC
YOU WILL BE SIGNED OUT of every website. Before you tick it, make sure you have ALL the details to get back in: your email accounts, your Google account, your Microsoft and Apple accounts, and every other password you use.	VOUS SEREZ DÉCONNECTÉ de tous les sites Web. Avant de cocher, assurez-vous d’avoir TOUS les renseignements pour vous reconnecter : vos comptes courriel, votre compte Google, vos comptes Microsoft et Apple, et tous vos autres mots de passe.
Yes	Oui
Yes below to open Clean my PC and clear junk files, then use Find large files, or move photos and videos to another drive. Try to keep at least 20% of the drive free.	Oui ci-dessous pour ouvrir Nettoyer mon PC et vider les fichiers inutiles, puis utilisez Trouver les gros fichiers, ou déplacez photos et vidéos sur un autre disque. Essayez de garder au moins 20 % du disque libre.
Yes, go ahead with	Oui, allez-y avec
Yes, review and run	Oui, vérifier et lancer
Yes: Windows makes {0} smaller just for the backup (this can take a few minutes, nothing is deleted), and puts it back to its full size when the backup is done.	Oui : Windows réduit {0} seulement pour la sauvegarde (cela peut prendre quelques minutes, rien n’est supprimé), et le remet à sa pleine taille après la sauvegarde.
Yesterday	Hier
You are still running the version you have.	Vous gardez la version que vous avez.
You are up to date.	Vous êtes à jour.
You can keep using the PC. If an update needs a restart, the window says so - nothing restarts by itself.	Vous pouvez continuer à utiliser le PC. Si une mise à jour demande un redémarrage, la fenêtre le dit - rien ne redémarre tout seul.
You can still restart sooner, or cancel the restart, from the progress page.	Vous pouvez encore redémarrer plus tôt, ou annuler le redémarrage, depuis la page de progression.
You do not have a Rescue USB yet. Make one now and keep it somewhere safe.	Vous n’avez pas encore de clé USB de secours. Créez-en une maintenant et gardez-la en lieu sûr.
You saved 0 bytes	Vous avez économisé 0 octet
You saved {0}	Vous avez économisé {0}
Your PC got too warm and slowed itself down {0} times in the last 30 days.	Votre PC a trop chauffé et a ralenti de lui-même {0} fois dans les 30 derniers jours.
Your PC is running hot right now ({0} C).	Votre PC chauffe en ce moment ({0} °C).
Your PC turned off by itself {0} times in the last 30 days.	Votre PC s’est éteint tout seul {0} fois dans les 30 derniers jours.
Your PC will {0} in 60 seconds.	Votre PC va {0} dans 60 secondes.
Your Windows {0} scan is overdue. It was last done: {1}.	Votre analyse {0} de Windows est en retard. Dernière fois : {1}.
Your choice: one click uninstalls every AI app and browser listed below that can be removed. Claude is always left alone, and Edge cannot be removed by Windows. You are asked to confirm first.	À vous de choisir : un clic désinstalle chaque appli d’IA et navigateur listé ci-dessous qui peut être retiré. Claude n’est jamais touché, et Windows ne permet pas de retirer Edge. On vous demande de confirmer d’abord.
Your last Rescue USB was made on {0} ({1}).	Votre dernière clé USB de secours a été créée le {0} ({1}).
Your own files and any duplicates you kept are not touched, and neither is the DRDirect PC Cleaner. Your Duplicate Finder licence is kept unless you tick the box below.	Vos fichiers et les doublons que vous avez gardés ne sont pas touchés, ni DRDirect Nettoyeur PC. Votre licence du Duplicate Finder est gardée sauf si vous cochez la case ci-dessous.
Your own files, browsers and logins are not touched. Your reports, licence and the Uninstaller's safe copies are kept unless you tick the box below.	Vos fichiers, navigateurs et connexions ne sont pas touchés. Vos rapports, votre licence et les copies de sécurité du désinstalleur sont gardés sauf si vous cochez la case ci-dessous.
Your recent changes	Vos changements récents
Your {0}: drive is {1}% full	Votre disque {0}: est plein à {1} %
Your {0}: drive is {1}% full ({2}).	Votre disque {0}: est plein à {1} % ({2}).
Zip archive	Archive Zip
Zoom is not installed on this PC. Nothing was opened.	Zoom n’est pas installé sur ce PC. Rien n’a été ouvert.
Zoom is opening. Click Settings (the gear, bottom left) > General, scroll to AI and click Manage, and tick the features you want back on.	Zoom s’ouvre. Cliquez sur Paramètres (l’engrenage, en bas à gauche) > Général, descendez jusqu’à IA et cliquez sur Gérer, puis cochez les fonctions que vous voulez réactiver.
Zoom: turn AI Companion back on	Zoom : réactiver AI Companion
Zoom: turn off AI Companion	Zoom : désactiver AI Companion
[Windows drive]	[disque Windows]
_Basic operations	_Opérations de base
_Quick filters	_Filtres rapides
a Windows program that malware often hides behind	un programme Windows derrière lequel les logiciels malveillants se cachent souvent
a file type programs and scripts use	un type de fichier utilisé par les programmes et les scripts
a whole drive or a system folder	un disque entier ou un dossier système
all done	tout est fait
and	et
are both inside	sont tous les deux inclus
at least 8 GB	au moins 8 Go
back on	réactivé
cannot check	impossible de vérifier
cleanup jobs done	tâches de nettoyage faites
close these programs	fermer ces programmes
could not open:	n’a pas pu ouvrir :
every file type - the most thorough, and the slowest	tous les types de fichiers - le plus complet, et le plus lent
everything off	tout désactivé
first, then run this again. Nothing was erased.	d’abord, puis relancez ceci. Rien n’a été effacé.
for life	à vie
iCloud cache	Cache d’iCloud
less than a day	moins d’un jour
less than an hour ago	il y a moins d’une heure
more than 10 years	plus de 10 ans
nd window	e fenêtre
never scanned	jamais analysé
no file system	aucun système de fichiers
no letter	pas de lettre
no time limit	sans limite de temps
normal hard drive speed	vitesse normale d’un disque dur
not installed	non installé
not responding	ne répond pas
nothing to do	rien à faire
on this PC.	sur ce PC.
one after the other	un après l’autre
only looks	regarde seulement
only one window	une seule fenêtre
partition {0}	partition {0}
please wait	patientez
put it back	la remettre
quietly, without asking for each one	en silence, sans demander pour chacun
restart	redémarrer
roughly {0} more month(s)	environ {0} mois de plus
roughly {0} more year(s)	environ {0} an(s) de plus
security and privacy	sécurité et confidentialité
showed no progress for {0} minutes	n’a pas avancé pendant {0} minutes
shut down	s’éteindre
slow (old hard drive, eMMC or USB)	lent (vieux disque dur, eMMC ou USB)
st window	re fenêtre
stayed at {0}% for {1} minutes	est resté à {0} % pendant {1} minutes
switched off	désactivé
switched on	activé
the Duplicate Finder	le Duplicate Finder
the USB	la clé USB
the Uninstaller	le désinstalleur
the cleaning	le nettoyage
to clean up your PC  →  3 Choices.	pour nettoyer votre PC  →  3 choix.
today	aujourd’hui
today, {0}	aujourd’hui, {0}
too old, no official fix - move to a newer PHP	trop vieux, pas de correctif officiel - passez à un PHP plus récent
turn back on	réactiver
until {0}	jusqu’au {0}
update ready	mise à jour prête
version not recognised - check it yourself	version non reconnue - vérifiez vous-même
waiting its turn	attend son tour
was still not finished after {0} minutes	n’était toujours pas fini après {0} minutes
winget (Windows Package Manager) is not installed on this PC.	winget (Gestionnaire de paquets Windows) n’est pas installé sur ce PC.
winget is installed.	winget est installé.
winget is not installed, so apps were not updated.	winget n’est pas installé, donc les applis n’ont pas été mises à jour.
worn - it runs out sooner than when new	usée - elle se vide plus vite qu’à l’état neuf
worn out - consider replacing the battery	très usée - pensez à remplacer la pile
yesterday	hier
yesterday, {0}	hier, {0}
your Windows drive	votre disque Windows
{0}   Please do not remove the USB.   Running for {1}	{0}   Ne retirez pas la clé USB.   En cours depuis {1}
{0}  ({1} free)	{0}  ({1} libres)
{0} - due in	{0} - prévu dans
{0} - next in	{0} - prochaine dans
{0} - no model name reported, see the motherboard below	{0} - aucun nom de modèle indiqué, voir la carte mère ci-dessous
{0} - over a year old	{0} - plus d’un an
{0} - over two years old	{0} - plus de deux ans
{0} - overdue by	{0} - en retard de
{0} - room to add more	{0} - de la place pour en ajouter
{0} AI item(s) are on or installed. Pick "Turn off" for them on the AI Remover page. Nothing was changed.	{0} élément(s) d’IA actif(s) ou installé(s). Choisissez « Désactiver » pour eux dans la page de retrait de l’IA. Rien n’a été changé.
{0} AI item(s) still on - pick "Turn off" for them on this page.	{0} élément(s) d’IA encore actif(s) - choisissez « Désactiver » pour eux sur cette page.
{0} Defender exclusion(s) configured	{0} exclusion(s) de Defender réglée(s)
{0} GB at {1} MHz	{0} Go à {1} MHz
{0} IDENTICAL COPIES  -  {1} each	{0} COPIES IDENTIQUES  -  {1} chacune
{0} PHP install(s) found:	{0} installation(s) de PHP trouvée(s) :
{0} Windows update(s) failed to install and have not installed since:	{0} mise(s) à jour de Windows n’ont pas pu s’installer et ne se sont pas installées depuis :
{0} built-in AI: {1}	IA intégrée de {0} : {1}
{0} can be reclaimed across {1} set{2}.	{0} peuvent être récupérés dans {1} groupe(s).
{0} check{1} finished. Nothing was changed on this PC.	{0} vérification(s) terminée(s). Rien n’a été changé sur ce PC.
{0} cloud files were included in this scan. Any that were online-only had to be downloaded to be compared.	{0} fichiers infonuagiques ont été inclus dans cette analyse. Ceux qui étaient en ligne seulement ont dû être téléchargés pour être comparés.
{0} cloud files were skipped - they are not stored on this PC, so checking them would download every one. Tick 'Include OneDrive / Google Drive / iCloud files' above to compare them anyway.	{0} fichiers infonuagiques ont été ignorés - ils ne sont pas sur ce PC, et les vérifier les téléchargerait tous. Cochez « Inclure les fichiers OneDrive / Google Drive / iCloud » plus haut pour les comparer quand même.
{0} could not be confirmed as Microsoft's, so it was not run. Nothing was changed on the USB.	{0} n’a pas pu être confirmé comme venant de Microsoft, donc il n’a pas été lancé. Rien n’a été changé sur la clé USB.
{0} could not be removed: {1}	{0} n’a pas pu être retiré : {1}
{0} could not be switched on: {1}	{0} n’a pas pu être activé : {1}
{0} could not be uninstalled: {1}	{0} n’a pas pu être désinstallé : {1}
{0} could not run: {1}	{0} n’a pas pu être lancé : {1}
{0} days	{0} jours
{0} days ago	il y a {0} jours
{0} did not report a result. It was most likely stopped before it finished.	{0} n’a pas donné de résultat. Il a sans doute été arrêté avant la fin.
{0} did nothing{1} for {2} minutes (no processor or disk work), so the Cleaner stopped it. Windows was most likely busy with an update or waiting for a restart. Restart the PC, let Windows Update finish, then run it again. Nothing was changed.	{0} n’a rien fait{1} pendant {2} minutes (aucun travail du processeur ou du disque), donc le Cleaner l’a arrêté. Windows était sans doute occupé par une mise à jour ou attendait un redémarrage. Redémarrez le PC, laissez Windows Update finir, puis relancez-le. Rien n’a été changé.
{0} driver update(s) are available for this PC.	{0} mise(s) à jour de pilotes disponible(s) pour ce PC.
{0} drives report a problem	{0} disques signalent un problème
{0} duplicate sets found  -  {1} files ticked  -  {2} will be freed	{0} groupes de doublons trouvés  -  {1} fichiers cochés  -  {2} seront libérés
{0} duplicate {1} moved to the Recycle Bin. One copy of each was kept.	{0} doublon(s) mis dans la Corbeille. Une copie de chacun a été gardée.
{0} entry(s) in the Run box	{0} entrée(s) dans la boîte Exécuter
{0} file types - much faster than scanning everything	{0} types de fichiers - beaucoup plus rapide que de tout analyser
{0} finished with error {1}.	{0} a fini avec l’erreur {1}.
{0} finished with exit code {1}.	{0} a fini avec le code de sortie {1}.
{0} finished.	{0} a fini.
{0} finished. Restart the PC to complete it.	{0} a fini. Redémarrez le PC pour terminer.
{0} free on {1}:	{0} libres sur {1}:
{0} has a forced setting: {1} = {2}	{0} a un réglage forcé : {1} = {2}
{0} has an extension that cannot be removed: {1}	{0} a une extension qui ne peut pas être retirée : {1}
{0} has been removed from this PC.	{0} a été retiré de ce PC.
{0} has no silent uninstaller: Settings > Apps > Installed apps > {1} > Uninstall.	{0} n’a pas de désinstallation silencieuse : Paramètres > Applications > Applications installées > {1} > Désinstaller.
{0} has to be removed by hand: Settings > Apps > Installed apps > {1} > Uninstall.	{0} doit être retiré à la main : Paramètres > Applications > Applications installées > {1} > Désinstaller.
{0} has to be uninstalled by hand: Settings > Apps > Installed apps.	{0} doit être désinstallé à la main : Paramètres > Applications > Applications installées.
{0} holds {1} on a {2} partition.	{0} contient {1} sur une partition de {2}.
{0} hours	{0} heures
{0} hours ago	il y a {0} heures
{0} install or repair is on the USB too.	L’installation ou la réparation de {0} est aussi sur la clé USB.
{0} is almost full	{0} est presque plein
{0} is back on.	{0} est réactivé.
{0} is not installed on this PC. Install the {1} app for Windows and sign in, then reopen the Duplicate Finder. Signing in on the website is not enough - the app is what puts the files on this PC.	{0} n’est pas installé sur ce PC. Installez l’application {1} pour Windows et connectez-vous, puis rouvrez le Duplicate Finder. Se connecter sur le site Web ne suffit pas - c’est l’application qui met les fichiers sur ce PC.
{0} is not installed on this PC. Nothing was changed.	{0} n’est pas installé sur ce PC. Rien n’a été changé.
{0} is not set - nothing was deleted.	{0} n’est pas défini - rien n’a été supprimé.
{0} is not set up on this PC, so there was nothing to clear.	{0} n’est pas installé sur ce PC, donc il n’y avait rien à vider.
{0} is not signed in, so AI websites were not blocked there. Sign in to {1} first, then run this again.	{0} n’est pas connecté, donc les sites d’IA n’y ont pas été bloqués. Connectez-vous d’abord à {1}, puis relancez ceci.
{0} is not signed in, so its AI model was not deleted. Sign in to {1} first, then run this again.	{0} n’est pas connecté, donc son modèle d’IA n’a pas été supprimé. Connectez-vous d’abord à {1}, puis relancez ceci.
{0} is not signed in, so nothing was changed. Sign in to {1} first, then run this again.	{0} n’est pas connecté, donc rien n’a été changé. Connectez-vous d’abord à {1}, puis relancez ceci.
{0} is not signed in, so the Claude website was not blocked there. Sign in to {1} first, then run this again.	{0} n’est pas connecté, donc le site de Claude n’y a pas été bloqué. Connectez-vous d’abord à {1}, puis relancez ceci.
{0} is not signed in. {1} Then click Check again.	{0} n’est pas connecté. {1} Puis cliquez sur Revérifier.
{0} is open in the Microsoft Store. Click Get or Install.	{0} est ouvert dans le Microsoft Store. Cliquez sur Obtenir ou Installer.
{0} is still installed. Close it and run this again, or use Settings > Apps > Installed apps.	{0} est encore installé. Fermez-le et relancez ceci, ou utilisez Paramètres > Applications > Applications installées.
{0} is still installed. Close it if it is open and run this again, or remove it in Settings > Apps > Installed apps.	{0} est encore installé. Fermez-le s’il est ouvert et relancez ceci, ou retirez-le dans Paramètres > Applications > Applications installées.
{0} is still off. It may be controlled by a policy or by another program.	{0} est toujours désactivé. Il est peut-être contrôlé par une stratégie ou un autre programme.
{0} is still running; nothing was removed.	{0} tourne encore ; rien n’a été retiré.
{0} items could not be put back.	{0} éléments n’ont pas pu être remis en place.
{0} items could not be removed (they may be in use). Restart the PC and run the Forced uninstaller again to finish them.	{0} éléments n’ont pas pu être retirés (ils sont peut-être utilisés). Redémarrez le PC et relancez la désinstallation forcée pour les finir.
{0} items could not be removed, for example {1}	{0} éléments n’ont pas pu être retirés, par exemple {1}
{0} location(s)	{0} emplacement(s)
{0} min left	{0} min restantes
{0} never - overdue	{0} jamais - en retard
{0} of these notes were removed from the Cleaning history.	{0} de ces notes ont été retirées de l’historique des nettoyages.
{0} of {1}   -   {2}/s   -   running for {3}	{0} sur {1}   -   {2}/s   -   en cours depuis {3}
{0} on the source drive is still smaller than before. To give it its space back: Disk Management, right-click {0}, Extend Volume. ({1})	{0} sur le disque source est encore plus petit qu’avant. Pour lui redonner son espace : Gestion des disques, clic droit sur {0}, Étendre le volume. ({1})
{0} past search(es)	{0} recherche(s) passée(s)
{0} program(s) start with Windows:	{0} programme(s) démarrent avec Windows :
{0} programs	{0} programmes
{0} refused	{0} refusée
{0} refused - ignored for {1}	{0} refusée - ignorée pendant {1}
{0} refused - never scanned	{0} refusée - jamais analysé
{0} remembered program name(s)	{0} nom(s) de programme mémorisé(s)
{0} report(s) could not be deleted. They may be open in another program.	{0} rapport(s) n’ont pas pu être supprimés. Ils sont peut-être ouverts dans un autre programme.
{0} reported exit code {1}.	{0} a donné le code de sortie {1}.
{0} requires administrator access.	{0} demande l’accès administrateur.
{0} selected	{0} sélectionné(s)
{0} selected here, {1} in total	{0} sélectionné(s) ici, {1} en tout
{0} selected task(s) finished.	{0} tâche(s) choisie(s) terminée(s).
{0} skipped in Safe Mode.	{0} ignoré en mode sans échec.
{0} task{1} finished. Your PC has been cleaned up.	{0} tâche(s) terminée(s). Votre PC a été nettoyé.
{0} temporary item(s) removed.	{0} élément(s) temporaire(s) retiré(s).
{0} thing(s) could be improved. Nothing was changed on this PC.	{0} chose(s) pourraient être améliorée(s). Rien n’a été changé sur ce PC.
{0} thing(s) need attention. Nothing was changed.	{0} chose(s) demandent votre attention. Rien n’a été changé.
{0} thing(s) need attention. Tick "Turn protection back on" to fix them. Nothing was changed.	{0} chose(s) demandent votre attention. Cochez « Réactiver la protection » pour les régler. Rien n’a été changé.
{0} things need attention	{0} choses demandent votre attention
{0} uninstallers in total, {1} GB	{0} désinstalleurs au total, {1} Go
{0} was removed, but these could not be deleted. You can delete them yourself:	{0} a été retiré, mais ceci n’a pas pu être supprimé. Vous pouvez le supprimer vous-même :
{0} was removed. Its "Reinstall" button brings it back.	{0} a été retiré. Son bouton « Réinstaller » le ramène.
{0} was still not finished after {1} minutes, so the Cleaner stopped it. Restart the PC, let Windows Update finish, then run it again.	{0} n’était toujours pas fini après {1} minutes, donc le Cleaner l’a arrêté. Redémarrez le PC, laissez Windows Update finir, puis relancez-le.
{0} was uninstalled.	{0} a été désinstallé.
{0} was uninstalled. Its "Reinstall" button brings it back.	{0} a été désinstallé. Son bouton « Réinstaller » le ramène.
{0}% of its original capacity	{0} % de sa capacité d’origine
{0}% of telemetry is turned off ({1} of {2} switches). Restart Windows so it all takes effect.	{0} % de la télémétrie est désactivée ({1} réglages sur {2}). Redémarrez Windows pour que tout s’applique.
{0}, {1} charge cycles	{0}, {1} cycles de charge
{0}: getting ready…	{0} : préparation…
{0}X  -  fast	{0}X  -  rapide
{0}X  -  gentle (the PC stays responsive)	{0}X  -  doux (le PC reste réactif)
{0}X  -  very fast (every CPU thread)	{0}X  -  très rapide (tous les fils du processeur)
↗  Open Edge to change it	↗  Ouvrir Edge pour le changer
↗  Open Edge to change it back	↗  Ouvrir Edge pour le remettre
↗  Open Edge to hide it	↗  Ouvrir Edge pour le cacher
↗  Open Edge to show it	↗  Ouvrir Edge pour l’afficher
↗  Open Word to turn off	↗  Ouvrir Word pour désactiver
↗  Open Word to turn on	↗  Ouvrir Word pour activer
↩  Undo last removal	↩  Annuler le dernier retrait
↩  Undo last removal  ({0})	↩  Annuler le dernier retrait  ({0})
↺  Turn all back on	↺  Tout réactiver
↺  Undo all AI changes	↺  Annuler tous les changements d’IA
↻  Check again	↻  Revérifier
⇄   Clone & Backup	⇄   Copie et sauvegarde
⊘   Switch On or Off AI	⊘   Activer ou désactiver l’IA
⌂   Dashboard	⌂   Tableau de bord
⌂  Back to the Cleaner	⌂  Retour au Cleaner
⌕  Check now	⌕  Vérifier maintenant
⏭️  PowerShell 7 - already current, kept as it is	⏭️  PowerShell 7 - déjà à jour, gardé tel quel
⏭️  {0} - installed by its own installer, so it updates itself. Nothing to uninstall, kept current one	⏭️  {0} - installé par son propre installateur, il se met donc à jour lui-même. Rien à désinstaller, version actuelle gardée
⏭️  {0} - installed from the Microsoft Store, so the Store updates it. Nothing to do	⏭️  {0} - installé depuis le Microsoft Store, c’est donc le Store qui le met à jour. Rien à faire
⏭️  {0} - newer version does not apply to this PC, kept current one	⏭️  {0} - la nouvelle version ne s’applique pas à ce PC, version actuelle gardée
⏭️  {0} - not needed on this PC	⏭️  {0} - pas nécessaire sur ce PC
⏭️  {0} - version {1} is already installed, winget just has not caught up	⏭️  {0} - la version {1} est déjà installée, winget n’est simplement pas à jour
⏰ PowerShell 7 timed out after {0}m - skipped	⏰ PowerShell 7 a dépassé le délai après {0} min - sauté
⏰ {0} timed out after {1}m - skipped	⏰ {0} a dépassé le délai après {1} min - sauté
⏱ Check here first!  Every time, to see how long it takes	⏱ Vérifiez ici d’abord ! Chaque fois, voyez le temps qu’il faut
▤   About my PC	▤   À propos de mon PC
▦   Check my RAM	▦   Vérifier ma RAM
▰   Check my drives	▰   Vérifier mes disques
▲   Back to the top	▲   Retour en haut
▲   More above	▲   Plus haut
▶  Check it	▶  Le vérifier
▶  Make a new Rescue USB	▶  Créer une nouvelle clé USB de secours
▶  Make the Rescue USB	▶  Créer la clé USB de secours
▶  Put it back	▶  Le remettre
▶  Save the backup	▶  Enregistrer la sauvegarde
▶  Start the copy	▶  Lancer la copie
▼   More below	▼   Plus bas
▼   More tools below	▼   Plus d’outils plus bas
◈   Speed and space	◈   Vitesse et espace
○  Standard user session	○  Session d’utilisateur standard
●  Administrator session	●  Session d’administrateur
●  Protected mode	●  Mode protégé
◐   Maintenance progress	◐   Progression de l’entretien
◷   Cleaning history	◷   Historique
☐  Clear my ticks	☐  Effacer mes coches
☑  Tick all	☑  Tout cocher
☾   Hibernate	☾   Veille prolongée
⚒   Fix Windows 10/11	⚒   Réparer Windows 10/11
⚠  Broken programs	⚠  Programmes brisés
⚠  SIGNS YOU OUT	⚠  VOUS DÉCONNECTE
⚡   Check power and heat	⚡   Vérifier l’alimentation et la chaleur
⚡  Remove quietly	⚡  Retirer en silence
⚡  Uninstall quietly	⚡  Désinstaller en silence
⛨   Downloading the tool...	⛨   Téléchargement de l’outil...
⛨   Full scan only	⛨   Analyse complète seulement
⛨   Smart App Control	⛨   Contrôle intelligent des applications
⛨   Windows Update	⛨   Windows Update
⛨   Windows repair USB	⛨   Clé USB de réparation Windows
✅ PowerShell 7 is now installed through winget and up to date	✅ PowerShell 7 est maintenant installé avec winget et à jour
✅ no problems	✅ aucun problème
✅ {0} upgraded	✅ {0} mis à jour
✓  Settings changes can be undone.   ✓  Files and passwords stay safe unless you tick them.	✓  Les changements de réglages peuvent être annulés.   ✓  Les fichiers et mots de passe restent protégés, sauf si vous les cochez.
✓  Turn back on	✓  Réactiver
✔  Check this backup now	✔  Vérifier cette sauvegarde maintenant
✔  You are all done!	✔  C’est terminé !
✕  Turn off	✕  Désactiver
✕  Turn off all AI	✕  Désactiver toute l’IA
✦   Clean my PC	✦   Nettoyer mon PC
⟳  Reload uninstallers	⟳  Recharger les désinstalleurs
⧉   Find duplicate files	⧉   Trouver les fichiers en double
⬅  Back to simple view	⬅  Retour à la vue simple
⬆  Windows updates	⬆  Mises à jour Windows
⭳   Update my apps	⭳   Mettre à jour mes applis
＋  Show all tools	＋  Afficher tous les outils
－  Show fewer tools	－  Afficher moins d’outils
🎉 Done in {0}s	🎉 Fait en {0} s
💥 PowerShell 7 failed (exit code {0})	💥 PowerShell 7 a échoué (code de sortie {0})
💥 winget not found. Install "App Installer" from the Microsoft Store.	💥 winget introuvable. Installez « Programme d’installation d’application » depuis le Microsoft Store.
💥 {0} could not be installed (exit code {1})	💥 {0} n’a pas pu être installé (code de sortie {1})
💥 {0} failed (exit code {1})	💥 {0} a échoué (code de sortie {1})
💥 {0} problems	💥 {0} problèmes
💪  Forced uninstaller	💪  Désinstallation forcée
📁  Remove from a folder	📁  Retirer depuis un dossier
📄  Properties	📄  Propriétés
📦 {0} packages to upgrade:	📦 {0} paquets à mettre à jour :
🔄  Refresh the list	🔄  Actualiser la liste
🔎 Checking for upgrades...	🔎 Recherche des mises à jour...
🔑  Activate this product	🔑  Activer ce produit
🔔  Allow Wand pop-ups	🔔  Permettre les fenêtres de Wand
🔕  Stop Wand pop-ups	🔕  Bloquer les fenêtres de Wand
🔧  Show advanced options	🔧  Afficher les options avancées
🗑  Remove selected programs	🗑  Retirer les programmes choisis
🗑  Uninstall	🗑  Désinstaller
🗑  Uninstall all AI	🗑  Désinstaller toute l’IA
🗑  Uninstall completely	🗑  Désinstaller complètement
😎 Everything is already up to date!	😎 Tout est déjà à jour !
🛠  Advanced removal	🛠  Retrait avancé
🧰 {0} is not installed - installing it...	🧰 {0} n’est pas installé - installation...
🧰 {0} was not installed through winget - bringing it under winget...	🧰 {0} n’a pas été installé avec winget - passage sous winget...
🧹  Remove tracked install	🧹  Retirer une installation suivie
🪟  Windows Store apps	🪟  Applications du Windows Store
'@
try { if (-not ('DRDirect.MsgBox' -as [type])) { Add-Type -ReferencedAssemblies 'PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml' -TypeDefinition $script:DRMsgBoxCode -ErrorAction Stop } } catch { }
function Get-DRLanguageSaved {
    try { return [string](Get-ItemProperty -LiteralPath 'HKCU:\Software\DRDirect\PC Cleaner' -Name 'Language' -ErrorAction Stop).Language } catch { return $null }
}
$script:DROrigCulture = [Threading.Thread]::CurrentThread.CurrentCulture
$script:DROrigUICulture = [Threading.Thread]::CurrentThread.CurrentUICulture
function Set-DRCultureFor([bool]$French) {
    # dates and numbers follow the chosen language too (this PC's own settings when they already match)
    try {
        $want = if ($French) { 'fr' } else { 'en' }
        $c = if ($script:DROrigCulture.TwoLetterISOLanguageName -eq $want) { $script:DROrigCulture } elseif ($French) { [Globalization.CultureInfo]::GetCultureInfo('fr-CA') } else { [Globalization.CultureInfo]::GetCultureInfo('en-CA') }
        $u = if ($script:DROrigUICulture.TwoLetterISOLanguageName -eq $want) { $script:DROrigUICulture } else { $c }
        [Threading.Thread]::CurrentThread.CurrentCulture = $c
        [Threading.Thread]::CurrentThread.CurrentUICulture = $u
    } catch { }
}
function Set-DRLanguage([bool]$French, [switch]$Save) {
    if (-not ('DRDirect.Lang' -as [type])) { return }
    Set-DRCultureFor $French
    [DRDirect.Lang]::Set($French)
    if ($Save) {
        try {
            $k = 'HKCU:\Software\DRDirect\PC Cleaner'
            if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
            Set-ItemProperty -LiteralPath $k -Name 'Language' -Value $(if ($French) { 'fr' } else { 'en' })
        } catch { }
    }
}
try {
    if (-not ('DRDirect.Lang' -as [type])) { Add-Type -ReferencedAssemblies 'PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml' -TypeDefinition $script:DRLangCode -ErrorAction Stop }
    [DRDirect.Lang]::Load($script:DRLangData)
    [DRDirect.MsgBox]::Tr = [Delegate]::CreateDelegate([Func[string, string]], [DRDirect.Lang].GetMethod('T'))
    $drSavedLang = Get-DRLanguageSaved
    # before anyone has chosen: French when Windows' language or its date and number format is French
    $drFrench = if ($drSavedLang) { $drSavedLang -eq 'fr' } else { ([Globalization.CultureInfo]::InstalledUICulture.TwoLetterISOLanguageName -eq 'fr') -or ($script:DROrigCulture.TwoLetterISOLanguageName -eq 'fr') -or ($script:DROrigUICulture.TwoLetterISOLanguageName -eq 'fr') }
    if ($script:DRLangOff) { $drFrench = $false }
    [DRDirect.Lang]::French = $drFrench
    Set-DRCultureFor $drFrench
    [DRDirect.Lang]::Hook()
} catch {
    # The Cleaner carries on in English; the reason is kept for DRDirect, and shown in test mode.
    $script:DRLangError = $_.Exception.Message
    try {
        $ld = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Logs'
        if (-not (Test-Path -LiteralPath $ld)) { New-Item -ItemType Directory -Path $ld -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $ld 'language-error.txt') -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "`r`n" + ($_ | Out-String)) -Encoding UTF8
    } catch { }
    if ($script:DRLangShowErr) { try { [System.Windows.MessageBox]::Show("French / English could not start:`n`n$($script:DRLangError)", 'DRDirect Duplicate Finder - test mode') | Out-Null } catch { } }
}


# Two paths can be names for one file (hard links). Windows does this heavily in
# WinSxS. Those are not duplicates - the bytes exist once, so removing a name
# frees nothing. This asks Windows for the underlying file record.
if (-not ('DRD.FileId' -as [type])) {
    $linkCs = @'
using System;
using System.Runtime.InteropServices;

namespace DRD {
    public static class FileId {
        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess,
            uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(IntPtr hFile,
            out BY_HANDLE_FILE_INFORMATION lpFileInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        // "volumeSerial:fileIndex" - equal strings mean the same bytes on disk.
        public static string Get(string path) {
            IntPtr h = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
            if (h == new IntPtr(-1)) { return ""; }
            try {
                BY_HANDLE_FILE_INFORMATION info;
                if (!GetFileInformationByHandle(h, out info)) { return ""; }
                return info.VolumeSerialNumber.ToString("X8") + ":"
                     + info.FileIndexHigh.ToString("X8") + info.FileIndexLow.ToString("X8");
            } finally {
                CloseHandle(h);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $linkCs -Language CSharp
}

# ---------------------------------------------------------------- models

if (-not ('DRD.DupFile' -as [type])) {
    $csharp = @'
using System;
using System.Collections.ObjectModel;
using System.ComponentModel;

namespace DRD {
    public class DupFile : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        void Raise(string n) {
            var h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(n));
        }

        public string FullPath { get; set; }
        public string FileName { get; set; }
        public string Folder   { get; set; }
        public string SizeText { get; set; }
        public string Modified { get; set; }
        public long   Size     { get; set; }
        public bool   IsKeeper { get; set; }

        // Red and moving means it is going. Green and still means it is safe.
        public string RoleText {
            get {
                if (_removed) return "REMOVED";
                if (IsKeeper) return "KEEP THIS ONE";
                return _selected ? "EXACT DUPLICATE" : "SAFE - KEEPING";
            }
        }

        bool _selected;
        public bool IsSelected {
            get { return _selected; }
            set { if (_selected != value) { _selected = value; Raise("IsSelected"); Raise("RoleText"); } }
        }

        bool _removed;
        public bool IsRemoved {
            get { return _removed; }
            set {
                if (_removed != value) {
                    _removed = value;
                    Raise("IsRemoved"); Raise("RowNote"); Raise("RoleText");
                }
            }
        }

        string _note = "";
        public string RowNote {
            get { return _removed ? "Moved to Recycle Bin" : _note; }
            set { _note = value; Raise("RowNote"); }
        }
    }

    public class DupGroup {
        public string HeaderText { get; set; }
        public string SizeText   { get; set; }
        public string WasteText  { get; set; }
        public string HashText   { get; set; }
        public string KindText   { get; set; }
        public long   Waste      { get; set; }

        // All copies in a set are identical, so one preview describes them all.
        public object Preview    { get; set; }
        public bool   HasPreview { get; set; }
        public string NoPreviewGlyph { get; set; }
        public ObservableCollection<DupFile> Files { get; set; }
        public DupGroup() { Files = new ObservableCollection<DupFile>(); }
    }
}
'@
    Add-Type -TypeDefinition $csharp
}

if (-not ('DRD.Thumbs' -as [type])) {
    # Windows' own thumbnail service - the same picture Explorer shows.
    # Covers video frames, PDF first pages and document previews, and falls
    # back to the file-type icon when no thumbnail exists.
    $shell = @'
using System;
using System.Runtime.InteropServices;

namespace DRD {
    public static class Thumbs {
        [StructLayout(LayoutKind.Sequential)]
        struct SIZE { public int cx; public int cy; }

        [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"),
         InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IShellItemImageFactory {
            void GetImage(SIZE size, int flags, out IntPtr phbm);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName(
            string path, IntPtr pbc, ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory ppv);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteObject(IntPtr hObject);

        // RESIZETOFIT, and allow an icon when the file has no real thumbnail.
        const int SIIGBF_RESIZETOFIT = 0x00;

        public static IntPtr GetBitmap(string path, int size) {
            var iid = new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b");
            IShellItemImageFactory factory;
            SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out factory);
            var sz = new SIZE { cx = size, cy = size };
            IntPtr hbm;
            factory.GetImage(sz, SIIGBF_RESIZETOFIT, out hbm);
            Marshal.ReleaseComObject(factory);
            return hbm;
        }
    }
}
'@
    Add-Type -TypeDefinition $shell
}

# ---------------------------------------------------------------- helpers

$script:DRProgramFolderCache = @{}

function Test-ProtectedPath {
    # Same rule as the scanner, enforced again at the point of deletion so a
    # Windows-owned file can never be removed even if it reaches the list.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # The account's own registry files sit loose in the root of the user folder,
    # where no folder rule catches them. Windows holds them open, and several are
    # byte-identical, so they surfaced as duplicates and failed with File In Use.
    $name = [System.IO.Path]::GetFileName($Path)
    if ($name -match '(?i)^(ntuser\.(dat|ini|pol)|usrclass\.dat|desktop\.ini)') { return $true }
    if ($name -match '(?i)\.(regtrans-ms|blf)$') { return $true }
    $full = $Path.TrimEnd('\') + '\'

    $roots = @(
        $env:SystemRoot,
        ${env:ProgramFiles},
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        (Join-Path $env:SystemDrive 'Recovery'),
        (Join-Path $env:SystemDrive '$Recycle.Bin'),
        (Join-Path $env:SystemDrive 'System Volume Information')
    )

    foreach ($r in $roots) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if ($full.StartsWith($r.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }

    # These exist on EVERY volume, not just the system drive.
    if ($full -match '(?i)\\\$Recycle\.Bin\\') { return $true }
    if ($full -match '(?i)\\System Volume Information\\') { return $true }
    if ($full -match '(?i)^[A-Z]:\\Recovery\\') { return $true }
    if ($full -match '(?i)^[A-Z]:\\Config\.Msi\\') { return $true }

    # Folders where software manages its own files. The bytes may match, but
    # each copy is expected at its own path - removing one breaks the app,
    # the repo, or the game install. Not the user's loose files.
    $appFolders = @(
        'AppData', 'node_modules', '.git', '.svn', '.hg',
        '__pycache__', 'site-packages', 'steamapps', 'Windows.old',
        '$WinREAgent', 'WpSystem', 'Package Cache', 'WindowsApps',
        'My Games', 'Saved Games', 'WindowsPowerShell', 'PowerShell'
    )
    foreach ($seg in $appFolders) {
        if ($full -like "*\$seg\*") { return $true }
    }
    # A folder or file named with a leading dot (.claude, .vscode, .npmrc) is
    # where a program keeps its own settings, never the person's loose files.
    if ($full -match '\\\.[^\\.][^\\]*\\') { return $true }

    # Programs need their own files at their own paths. A matching .dll or .exe
    # elsewhere does not make this copy spare - removing it breaks the program.
    $programExts = @('.exe', '.dll', '.sys', '.ocx', '.drv', '.cpl', '.scr', '.com', '.efi',
        '.msi', '.msp', '.msix', '.appx', '.mui', '.winmd', '.node', '.pyd', '.jar',
        '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.vbs', '.ini', '.cfg', '.config')
    $leaf = [System.IO.Path]::GetExtension($Path.TrimEnd(''))
    if ($leaf -and $programExts -contains $leaf.ToLowerInvariant()) { return $true }

    # A folder holding a program (.exe) beside its libraries (.dll) is an app,
    # installed or portable, wherever it lives. A folder with a .git folder at
    # its top is a code project, where every source file is needed at its own
    # path. Either way the same goes for every folder beneath it - nothing
    # inside belongs to the person's loose files.
    $dir = if ([System.IO.Directory]::Exists($Path)) { $Path.TrimEnd('') } else { [System.IO.Path]::GetDirectoryName($Path.TrimEnd('')) }
    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        if (-not $script:DRProgramFolderCache.ContainsKey($dir)) {
            $isApp = $false
            # The person's own folders hold whatever they put there - a setup .exe
            # in Downloads, NTUSER.DAT in the profile. They are never an app folder.
            $personal = @($env:USERPROFILE, $env:PUBLIC, (Join-Path $env:USERPROFILE 'Downloads'),
                [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
                [Environment]::GetFolderPath('MyPictures'), [Environment]::GetFolderPath('MyMusic'),
                [Environment]::GetFolderPath('MyVideos'), $env:OneDrive) |
                Where-Object { $_ } | ForEach-Object { $_.TrimEnd('') }
            if ($dir.Length -gt 3 -and $personal -notcontains $dir) { try {
                $isApp = [System.IO.Directory]::Exists([System.IO.Path]::Combine($dir, '.git')) -or
                         [System.IO.File]::Exists([System.IO.Path]::Combine($dir, '.git'))
                if (-not $isApp -and [System.IO.Directory]::EnumerateFiles($dir, '*.exe').GetEnumerator().MoveNext()) {
                    # A program beside its libraries or its own settings and data is a
                    # portable app. An .exe on its own (a setup in Downloads) is not.
                    foreach ($mark in '*.dll', '*.ini', '*.cfg', '*.config', '*.dat', '*.json', '*.xml') {
                        foreach ($hit in [System.IO.Directory]::EnumerateFiles($dir, $mark)) {
                            # desktop.ini is only the folder's icon and view settings
                            if ([System.IO.Path]::GetFileName($hit) -ne 'desktop.ini') { $isApp = $true; break }
                        }
                        if ($isApp) { break }
                    }
                }
            } catch { } }
            $script:DRProgramFolderCache[$dir] = $isApp
        }
        if ($script:DRProgramFolderCache[$dir]) { return $true }
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }

    return $false
}

function Get-SizeUnit {
    # Picks the unit for a final total once, so a count-up animation can hold it.
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return @{ Divisor = 1TB; Format = '{0:N2} TB' } }
    if ($Bytes -ge 1GB) { return @{ Divisor = 1GB; Format = '{0:N2} GB' } }
    if ($Bytes -ge 1MB) { return @{ Divisor = 1MB; Format = '{0:N1} MB' } }
    if ($Bytes -ge 1KB) { return @{ Divisor = 1KB; Format = '{0:N0} KB' } }
    return @{ Divisor = 1; Format = '{0:N0} bytes' }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

# ---------------------------------------------------------------- scan job

function Get-DRCloudServices {
    <#
        .SYNOPSIS
            The cloud folders that actually exist on this PC, by service name.
        .DESCRIPTION
            One entry per service, each holding every folder found for it. Used
            for the shortcuts in the folder picker and for deciding which
            online-only files a scan is allowed to pull down.
    #>
    $known = [ordered]@{
        'iCloud'        = @('iCloudDrive', 'iCloud Drive', 'iCloudPhotos', 'iCloud Photos', 'Pictures\iCloud Photos')
        'Google Drive'  = @('Google Drive', 'My Drive')
        'OneDrive'      = @()
        'Dropbox'       = @('Dropbox')
        'MEGA'          = @('MEGA', 'MEGAsync')
        'Box'           = @('Box', 'Box Sync')
        'pCloud'        = @('pCloud Drive', 'pCloudDrive')
        'Sync'          = @('Sync')
        'Nextcloud'     = @('Nextcloud')
        'Proton Drive'  = @('Proton Drive', 'ProtonDrive')
        'Tresorit'      = @('Tresorit')
        'Creative Cloud'= @('Creative Cloud Files')
        'Amazon Drive'  = @('Amazon Drive')
        'Yandex Disk'   = @('YandexDisk', 'Yandex.Disk')
        'Jottacloud'    = @('Jottacloud')
        'Icedrive'      = @('Icedrive')
        'Koofr'         = @('Koofr')
        'IDrive'        = @('IDrive-Sync')
        'MediaFire'     = @('MediaFire')
        'SpiderOak'     = @('SpiderOak Hive')
    }

    $found = [ordered]@{}
    function Add-Found {
        param($Name, $Path)
        if (-not $Path) { return }
        try { if (-not (Test-Path -LiteralPath $Path)) { return } } catch { return }
        if (-not $found.Contains($Name)) { $found[$Name] = New-Object System.Collections.Generic.List[string] }
        $full = try { (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { $Path }
        if (-not $found[$Name].Contains($full)) { $found[$Name].Add($full) }
    }

    # OneDrive publishes its own locations; personal and work are separate folders.
    foreach ($v in @($env:OneDrive, $env:OneDriveConsumer)) { Add-Found 'OneDrive' $v }
    Add-Found 'OneDrive for Business' $env:OneDriveCommercial

    foreach ($name in $known.Keys) {
        foreach ($leaf in $known[$name]) { Add-Found $name (Join-Path $env:USERPROFILE $leaf) }
    }

    # Some clients mount a virtual drive instead of a folder in the profile.
    try {
        foreach ($disk in @(Get-CimInstance Win32_LogicalDisk -ErrorAction Stop)) {
            $label = [string]$disk.VolumeName
            if ([string]::IsNullOrWhiteSpace($label)) { continue }
            foreach ($name in $known.Keys) {
                if ($label -like ("*" + $name + "*")) {
                    Add-Found $name ($disk.DeviceID + [IO.Path]::DirectorySeparatorChar)
                }
            }
        }
    } catch { }

    return $found
}

$ScanScript = {
    param($Roots, $MinBytes, $IncludeSub, $CloudRoots, $Exts, $State)

    # OneDrive / cloud "online-only" files are placeholders - the bytes are not
    # on this PC. Reading one forces a full download, so they are left alone
    # unless you explicitly ask for them.
    function Test-CloudPlaceholder {
        param($File)
        $a = [int]$File.Attributes
        $offline = 0x1000      # FILE_ATTRIBUTE_OFFLINE
        $recallOpen = 0x40000    # FILE_ATTRIBUTE_RECALL_ON_OPEN
        $recallData = 0x400000   # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
        $reparse = 0x400       # FILE_ATTRIBUTE_REPARSE_POINT
        return (($a -band ($offline -bor $recallOpen -bor $recallData -bor $reparse)) -ne 0)
    }

    function Get-Sha256 {
        param([string]$Path)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            return [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '')
        } finally {
            if ($fs) { $fs.Dispose() }
            $sha.Dispose()
        }
    }

    function Test-SameBytes {
        param([string]$A, [string]$B)
        $fa = $null; $fb = $null
        try {
            $fa = [System.IO.File]::Open($A, 'Open', 'Read', 'ReadWrite')
            $fb = [System.IO.File]::Open($B, 'Open', 'Read', 'ReadWrite')
            if ($fa.Length -ne $fb.Length) { return $false }
            $size = 65536
            $ba = New-Object byte[] $size
            $bb = New-Object byte[] $size
            while ($true) {
                $ra = $fa.Read($ba, 0, $size)
                $null = $fb.Read($bb, 0, $size)
                if ($ra -eq 0) { return $true }
                for ($i = 0; $i -lt $ra; $i++) {
                    if ($ba[$i] -ne $bb[$i]) { return $false }
                }
            }
        } catch {
            return $false
        } finally {
            if ($fa) { $fa.Dispose() }
            if ($fb) { $fb.Dispose() }
        }
    }

    $programFolderCache = @{}

    function Test-ProtectedPath {
        # Windows-owned locations. Files here are not the user's to remove, and the
        # component store (WinSxS) in particular backs Windows servicing - deleting
        # from it can break Windows Update even when the bytes match a user file.
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        # The account's own registry files sit loose in the root of the user folder,
        # where no folder rule catches them. Windows holds them open, and several are
        # byte-identical, so they surfaced as duplicates and failed with File In Use.
        $name = [System.IO.Path]::GetFileName($Path)
        if ($name -match '(?i)^(ntuser\.(dat|ini|pol)|usrclass\.dat|desktop\.ini)') { return $true }
        if ($name -match '(?i)\.(regtrans-ms|blf)$') { return $true }
        $full = $Path.TrimEnd('\') + '\'

        $roots = @(
            $env:SystemRoot,
            ${env:ProgramFiles},
            ${env:ProgramFiles(x86)},
            $env:ProgramData,
            (Join-Path $env:SystemDrive 'Recovery'),
            (Join-Path $env:SystemDrive '$Recycle.Bin'),
            (Join-Path $env:SystemDrive 'System Volume Information')
        )

        foreach ($r in $roots) {
            if ([string]::IsNullOrWhiteSpace($r)) { continue }
            if ($full.StartsWith($r.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }

        # These exist on EVERY volume, not just the system drive, so match them
        # wherever they appear - D:\$Recycle.Bin is no more deletable than C:\.
        if ($full -match '(?i)\\\$Recycle\.Bin\\') { return $true }
        if ($full -match '(?i)\\System Volume Information\\') { return $true }
        if ($full -match '(?i)^[A-Z]:\\Recovery\\') { return $true }
        if ($full -match '(?i)^[A-Z]:\\Config\.Msi\\') { return $true }

        # Folders where software manages its own files. The bytes may match, but
        # each copy is expected at its own path - removing one breaks the app,
        # the repo, or the game install. Not the user's loose files.
        $appFolders = @(
            'AppData', 'node_modules', '.git', '.svn', '.hg',
            '__pycache__', 'site-packages', 'steamapps', 'Windows.old',
            '$WinREAgent', 'WpSystem', 'Package Cache', 'WindowsApps',
            'My Games', 'Saved Games', 'WindowsPowerShell', 'PowerShell'
        )
        foreach ($seg in $appFolders) {
            if ($full -like "*\$seg\*") { return $true }
        }
        # A folder or file named with a leading dot (.claude, .vscode, .npmrc) is
        # where a program keeps its own settings, never the person's loose files.
        if ($full -match '\\\.[^\\.][^\\]*\\') { return $true }

        # Programs need their own files at their own paths. A matching .dll or .exe
        # elsewhere does not make this copy spare - removing it breaks the program.
        $programExts = @('.exe', '.dll', '.sys', '.ocx', '.drv', '.cpl', '.scr', '.com', '.efi',
            '.msi', '.msp', '.msix', '.appx', '.mui', '.winmd', '.node', '.pyd', '.jar',
            '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.vbs', '.ini', '.cfg', '.config')
        $leaf = [System.IO.Path]::GetExtension($Path.TrimEnd(''))
        if ($leaf -and $programExts -contains $leaf.ToLowerInvariant()) { return $true }

        # A folder holding a program (.exe) beside its libraries (.dll) is an app,
        # installed or portable, wherever it lives. A folder with a .git folder at
        # its top is a code project, where every source file is needed at its own
        # path. Either way the same goes for every folder beneath it - nothing
        # inside belongs to the person's loose files.
        $dir = if ([System.IO.Directory]::Exists($Path)) { $Path.TrimEnd('') } else { [System.IO.Path]::GetDirectoryName($Path.TrimEnd('')) }
        while (-not [string]::IsNullOrWhiteSpace($dir)) {
            if (-not $programFolderCache.ContainsKey($dir)) {
                $isApp = $false
                # The person's own folders hold whatever they put there - a setup .exe
                # in Downloads, NTUSER.DAT in the profile. They are never an app folder.
                $personal = @($env:USERPROFILE, $env:PUBLIC, (Join-Path $env:USERPROFILE 'Downloads'),
                    [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
                    [Environment]::GetFolderPath('MyPictures'), [Environment]::GetFolderPath('MyMusic'),
                    [Environment]::GetFolderPath('MyVideos'), $env:OneDrive) |
                    Where-Object { $_ } | ForEach-Object { $_.TrimEnd('') }
                if ($dir.Length -gt 3 -and $personal -notcontains $dir) { try {
                    $isApp = [System.IO.Directory]::Exists([System.IO.Path]::Combine($dir, '.git')) -or
                             [System.IO.File]::Exists([System.IO.Path]::Combine($dir, '.git'))
                    if (-not $isApp -and [System.IO.Directory]::EnumerateFiles($dir, '*.exe').GetEnumerator().MoveNext()) {
                        # A program beside its libraries or its own settings and data is a
                        # portable app. An .exe on its own (a setup in Downloads) is not.
                        foreach ($mark in '*.dll', '*.ini', '*.cfg', '*.config', '*.dat', '*.json', '*.xml') {
                            foreach ($hit in [System.IO.Directory]::EnumerateFiles($dir, $mark)) {
                                # desktop.ini is only the folder's icon and view settings
                                if ([System.IO.Path]::GetFileName($hit) -ne 'desktop.ini') { $isApp = $true; break }
                            }
                            if ($isApp) { break }
                        }
                    }
                } catch { } }
                $programFolderCache[$dir] = $isApp
            }
            if ($programFolderCache[$dir]) { return $true }
            $dir = [System.IO.Path]::GetDirectoryName($dir)
        }

        return $false
    }

    try {
        $State['Status'] = 'Listing files...'
        $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]

        foreach ($root in $Roots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            if (Test-ProtectedPath $root) {
                $State['ProtectedSkipped'] = [int]$State['ProtectedSkipped'] + 1
                continue
            }
            $stack = New-Object System.Collections.Generic.Stack[string]
            $stack.Push($root)
            while ($stack.Count -gt 0) {
                if ($State['Cancel']) { return }
                $dir = $stack.Pop()
                try {
                    $di = New-Object System.IO.DirectoryInfo $dir
                    foreach ($f in $di.EnumerateFiles()) {
                        if ($f.Length -lt $MinBytes) { continue }
                        if (Test-ProtectedPath $f.FullName) {
                            $State['ProtectedSkipped'] = [int]$State['ProtectedSkipped'] + 1
                            continue
                        }
                        # empty filter means every type
                        if ($Exts -and $Exts.Count -gt 0 -and -not $Exts.Contains($f.Extension.ToLowerInvariant())) { continue }
                        if (Test-CloudPlaceholder $f) {
                            $State['CloudSkipped'] = [int]$State['CloudSkipped'] + 1
                            # Only pull a file down if its own service was ticked.
                            # Anything not under a ticked folder stays untouched.
                            $allowed = $false
                            if ($CloudRoots) {
                                foreach ($cr in $CloudRoots) {
                                    if ($f.FullName.StartsWith($cr, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
                                }
                            }
                            if (-not $allowed) { continue }
                        }
                        $files.Add($f)
                    }
                    if ($IncludeSub) {
                        foreach ($sd in $di.EnumerateDirectories()) {
                            if ($sd.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                            if (Test-ProtectedPath $sd.FullName) { continue }
                            $stack.Push($sd.FullName)
                        }
                    }
                } catch { }
                $State['Status'] = "Listing files... $($files.Count) found"
            }
        }

        # Stage 1 - two files can only be identical if they are the same size.
        $bySize = @{}
        foreach ($f in $files) {
            $len = $f.Length
            if (-not $bySize.ContainsKey($len)) {
                $bySize[$len] = New-Object System.Collections.Generic.List[System.IO.FileInfo]
            }
            $bySize[$len].Add($f)
        }

        $candidateSizes = @($bySize.Keys | Where-Object { $bySize[$_].Count -gt 1 })
        $totalToHash = 0
        foreach ($k in $candidateSizes) { $totalToHash += $bySize[$k].Count }

        $State['Total'] = $totalToHash
        $State['Progress'] = 0
        $State['Status'] = "Comparing $totalToHash possible matches..."

        $results = New-Object System.Collections.Generic.List[object]

        foreach ($size in ($candidateSizes | Sort-Object -Descending)) {
            if ($State['Cancel']) { break }

            # Stage 2 - identical content means an identical SHA-256.
            $byHash = @{}
            foreach ($f in $bySize[$size]) {
                if ($State['Cancel']) { break }
                $State['Progress'] = [int]$State['Progress'] + 1
                $State['Status'] = "Verifying: $($f.Name)"
                try { $h = Get-Sha256 -Path $f.FullName } catch { continue }
                if (-not $byHash.ContainsKey($h)) {
                    $byHash[$h] = New-Object System.Collections.Generic.List[System.IO.FileInfo]
                }
                $byHash[$h].Add($f)
            }

            foreach ($h in $byHash.Keys) {
                $set = $byHash[$h]
                if ($set.Count -lt 2) { continue }

                # Stage 3 - prove it byte-for-byte before calling it a duplicate.
                $keeper = $set | Sort-Object CreationTimeUtc, { $_.FullName.Length } | Select-Object -First 1
                $confirmed = New-Object System.Collections.Generic.List[System.IO.FileInfo]
                $confirmed.Add($keeper)
                $keeperId = ''
                try { $keeperId = [DRD.FileId]::Get($keeper.FullName) } catch { }
                foreach ($f in $set) {
                    if ($f.FullName -eq $keeper.FullName) { continue }

                    # A hard link is the same bytes under another name - deleting it
                    # frees nothing, so it is not a duplicate worth listing.
                    if ($keeperId) {
                        $fid = ''
                        try { $fid = [DRD.FileId]::Get($f.FullName) } catch { }
                        if ($fid -and $fid -eq $keeperId) {
                            $State['LinkSkipped'] = [int]$State['LinkSkipped'] + 1
                            continue
                        }
                    }

                    if (Test-SameBytes -A $keeper.FullName -B $f.FullName) { $confirmed.Add($f) }
                }
                if ($confirmed.Count -lt 2) { continue }

                $results.Add([pscustomobject]@{
                        Hash   = $h
                        Size   = [long]$size
                        Files  = @($confirmed)
                        Keeper = $keeper.FullName
                    })
            }
        }

        $State['Results'] = $results
    } catch {
        $State['Error'] = $_.Exception.Message
    } finally {
        $State['Done'] = $true
    }
}

if ($ScanOnly) {
    # Headless run - used by tests and by anyone who just wants the list.
    $st = [hashtable]::Synchronized(@{ Cancel = $false; Done = $false; Progress = 0; Total = 0 })
    & $ScanScript @($StartFolder) 1KB $true $false $null $st
    if ($st['Error']) { throw $st['Error'] }
    foreach ($r in $st['Results']) {
        Write-Host ("SET  {0} copies  {1}  keep={2}" -f $r.Files.Count, (Format-Size $r.Size), $r.Keeper)
        foreach ($f in $r.Files) {
            $tag = if ($f.FullName -eq $r.Keeper) { 'KEEP     ' } else { 'DUPLICATE' }
            Write-Host ("     {0} {1}" -f $tag, $f.FullName)
        }
    }
    $found = $st['Results']
    $setCount = if ($null -eq $found) { 0 } else { $found.Count }
    Write-Host "TOTAL SETS: $setCount"
    return
}

# ---------------------------------------------------------------- ui

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DRDirect Duplicate Finder" Width="960" Height="640"
        MinWidth="820" MinHeight="540"
        WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Ideal">
  <Window.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#EEF3FB" Offset="0"/>
      <GradientStop Color="#CBD8EA" Offset="1"/>
    </LinearGradientBrush>
  </Window.Background>
  <Window.Resources>
    <DropShadowEffect x:Key="DR3DButton" Color="#0A1A4A" Direction="270" ShadowDepth="11" BlurRadius="18" Opacity="0.7"/><Visibility x:Key="DR3DParts">Visible</Visibility>
    <!-- Every button lifts on hover and presses in on click. -->
    <Style x:Key="Btn" TargetType="Button"><Setter Property="Effect" Value="{DynamicResource DR3DButton}"/>
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform>
                <ScaleTransform x:Name="sc" ScaleX="1" ScaleY="1"/>
              </Grid.RenderTransform>

              <Border CornerRadius="6" Background="#B3000A30" Margin="0,8,0,-8" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"/>
              <Border x:Name="shade" CornerRadius="6" Background="Black" Opacity="0"
                      Margin="0,2,0,-2" IsHitTestVisible="False"/>
              <Border x:Name="b" CornerRadius="6" Background="{TemplateBinding Background}"
                      Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Border CornerRadius="6" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}" BorderThickness="0,0,0,4" BorderBrush="#55000000"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#A6FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="0.55"/></LinearGradientBrush></Border.Background></Border>
              <Border x:Name="glow" CornerRadius="6" Background="White" Opacity="0"
                      IsHitTestVisible="False"/>
            </Grid>

            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="MouseEnter">
                <BeginStoryboard>
                  <Storyboard>
                    <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX"
                                     To="1.05" Duration="0:0:0.13"/>
                    <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY"
                                     To="1.05" Duration="0:0:0.13"/>
                    <DoubleAnimation Storyboard.TargetName="glow" Storyboard.TargetProperty="Opacity"
                                     To="0.16" Duration="0:0:0.13"/>
                    <DoubleAnimation Storyboard.TargetName="shade" Storyboard.TargetProperty="Opacity"
                                     To="0.18" Duration="0:0:0.13"/>
                  </Storyboard>
                </BeginStoryboard>
              </EventTrigger>

              <EventTrigger RoutedEvent="MouseLeave">
                <BeginStoryboard>
                  <Storyboard>
                    <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX"
                                     To="1" Duration="0:0:0.18"/>
                    <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY"
                                     To="1" Duration="0:0:0.18"/>
                    <DoubleAnimation Storyboard.TargetName="glow" Storyboard.TargetProperty="Opacity"
                                     To="0" Duration="0:0:0.18"/>
                    <DoubleAnimation Storyboard.TargetName="shade" Storyboard.TargetProperty="Opacity"
                                     To="0" Duration="0:0:0.18"/>
                  </Storyboard>
                </BeginStoryboard>
              </EventTrigger>

              <EventTrigger RoutedEvent="PreviewMouseLeftButtonDown">
                <BeginStoryboard>
                  <Storyboard>
                    <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX"
                                     To="0.95" Duration="0:0:0.06"/>
                    <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY"
                                     To="0.95" Duration="0:0:0.06"/>
                    <DoubleAnimation Storyboard.TargetName="shade" Storyboard.TargetProperty="Opacity"
                                     To="0" Duration="0:0:0.06"/>
                  </Storyboard>
                </BeginStoryboard>
              </EventTrigger>

              <EventTrigger RoutedEvent="PreviewMouseLeftButtonUp">
                <BeginStoryboard>
                  <Storyboard>
                    <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX"
                                     To="1.05" Duration="0:0:0.22">
                      <DoubleAnimation.EasingFunction>
                        <BackEase EasingMode="EaseOut" Amplitude="0.6"/>
                      </DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                    <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY"
                                     To="1.05" Duration="0:0:0.22">
                      <DoubleAnimation.EasingFunction>
                        <BackEase EasingMode="EaseOut" Amplitude="0.6"/>
                      </DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                  </Storyboard>
                </BeginStoryboard>
              </EventTrigger>

              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Background" Value="#98A2B3"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#E3E8F0"/>
      <Setter Property="Foreground" Value="#1E40AF"/>
    </Style>
    <!-- file-type chips: pick what you are hunting for -->
    <Style x:Key="Chip" TargetType="ToggleButton"><Setter Property="Effect" Value="{DynamicResource DR3DButton}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Grid RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform x:Name="csc" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
              <Border CornerRadius="16" Background="#B3000A30" Margin="0,8,0,-8" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"/>
              <Border x:Name="cb" CornerRadius="16" Background="White" BorderBrush="#C9D4E6"
                      BorderThickness="1.5" Padding="14,7">
                <ContentPresenter VerticalAlignment="Center"/>
              </Border>
              <Border CornerRadius="16" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}" BorderThickness="0,0,0,4" BorderBrush="#55000000"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#A6FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="0.55"/></LinearGradientBrush></Border.Background></Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="cb" Property="Background" Value="#2563EB"/>
                <Setter TargetName="cb" Property="BorderBrush" Value="#1E40AF"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <EventTrigger RoutedEvent="MouseEnter">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="csc" Storyboard.TargetProperty="ScaleX" To="1.07" Duration="0:0:0.13"/>
                  <DoubleAnimation Storyboard.TargetName="csc" Storyboard.TargetProperty="ScaleY" To="1.07" Duration="0:0:0.13"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="MouseLeave">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="csc" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.18"/>
                  <DoubleAnimation Storyboard.TargetName="csc" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.18"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TinyBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#E8F0FF"/>
      <Setter Property="Foreground" Value="#1E40AF"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#C63C3C"/>
      <Setter Property="Padding" Value="22,11"/>
      <Setter Property="FontSize" Value="15"/>
      <Style.Triggers>
        <!-- Breathes gently once it is armed, so you can see it is ready. -->
        <Trigger Property="IsEnabled" Value="True">
          <Trigger.EnterActions>
            <BeginStoryboard x:Name="pulse">
              <Storyboard>
                <DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.82"
                                 Duration="0:0:0.9" AutoReverse="True" RepeatBehavior="Forever"/>
              </Storyboard>
            </BeginStoryboard>
          </Trigger.EnterActions>
          <Trigger.ExitActions>
            <StopStoryboard BeginStoryboardName="pulse"/>
          </Trigger.ExitActions>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Border Grid.Row="0" ClipToBounds="True">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#08301D" Offset="0"/>
          <GradientStop Color="#15A05C" Offset="0.5"/>
          <GradientStop Color="#0B6B3C" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>

      <Grid>
        <!-- slow light sweep across the banner -->
        <Rectangle Width="260" HorizontalAlignment="Left" IsHitTestVisible="False" Opacity="0.13">
          <Rectangle.Fill>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#00FFFFFF" Offset="0"/>
              <GradientStop Color="#FFFFFFFF" Offset="0.5"/>
              <GradientStop Color="#00FFFFFF" Offset="1"/>
            </LinearGradientBrush>
          </Rectangle.Fill>
          <Rectangle.RenderTransform>
            <TransformGroup>
              <SkewTransform AngleX="-22"/>
              <TranslateTransform x:Name="Sheen" X="-400"/>
            </TransformGroup>
          </Rectangle.RenderTransform>
          <Rectangle.Triggers>
            <EventTrigger RoutedEvent="Loaded">
              <BeginStoryboard>
                <Storyboard>
                  <DoubleAnimation Storyboard.TargetName="Sheen" Storyboard.TargetProperty="X"
                                   From="-400" To="2800" Duration="0:0:5.5"
                                   RepeatBehavior="Forever"/>
                </Storyboard>
              </BeginStoryboard>
            </EventTrigger>
          </Rectangle.Triggers>
        </Rectangle>

        <Grid Margin="30,24,30,26">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <!-- two stacked sheets with a magnifier over them -->
          <Grid Grid.Column="0" Width="74" Height="74" Margin="0,0,22,0" VerticalAlignment="Center">
            <Border Width="40" Height="50" CornerRadius="5" Background="#8FE3B8"
                    HorizontalAlignment="Left" VerticalAlignment="Top" Margin="4,2,0,0" Opacity="0.75"/>
            <Border Width="40" Height="50" CornerRadius="5" Background="White"
                    HorizontalAlignment="Left" VerticalAlignment="Top" Margin="13,10,0,0">
              <StackPanel Margin="7,9,7,0">
                <Rectangle Height="3" Fill="#9DB8F0" RadiusX="1.5" RadiusY="1.5" Margin="0,0,0,4"/>
                <Rectangle Height="3" Fill="#C3D3F7" RadiusX="1.5" RadiusY="1.5" Margin="0,0,6,4"/>
                <Rectangle Height="3" Fill="#C3D3F7" RadiusX="1.5" RadiusY="1.5" Margin="0,0,2,0"/>
              </StackPanel>
            </Border>
            <Canvas HorizontalAlignment="Right" VerticalAlignment="Bottom" Width="40" Height="40">
              <Ellipse Canvas.Left="2" Canvas.Top="2" Width="26" Height="26"
                       Stroke="#FFD98A" StrokeThickness="4.5"/>
              <Rectangle Canvas.Left="24" Canvas.Top="24" Width="14" Height="5"
                         Fill="#FFD98A" RadiusX="2.5" RadiusY="2.5">
                <Rectangle.RenderTransform>
                  <RotateTransform Angle="45"/>
                </Rectangle.RenderTransform>
              </Rectangle>
            </Canvas>
          </Grid>

          <StackPanel Grid.Column="1" VerticalAlignment="Center">
            <TextBlock Foreground="White" FontSize="34" FontWeight="Bold"><Run Text="DRDirect" Foreground="#9DBBFF"/><Run Text=" Duplicate Finder"/></TextBlock>
            <Border x:Name="TrialBadge" Background="#FFD166" CornerRadius="4" Padding="10,3"
                    HorizontalAlignment="Left" Margin="0,6,0,0" Visibility="Collapsed">
              <TextBlock x:Name="TrialBadgeText" Text="FREE TRY" Foreground="#7A4A00" FontSize="11" FontWeight="Bold"/>
            </Border>
            <TextBlock Foreground="#E8F1FF" FontSize="16" Margin="0,6,0,0"><Run Text="Only files that are 100% identical."/><Run Text="  One copy is always kept." Foreground="#9DBBFF" FontSize="24" FontWeight="Bold"/></TextBlock>
            <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
              <Image x:Name="DRLogo" Width="48" Height="48" RenderOptions.BitmapScalingMode="HighQuality"/>
              <TextBlock x:Name="VersionText" Foreground="#FFE14D" FontSize="14" FontWeight="SemiBold"
                         VerticalAlignment="Center" Margin="8,0,0,0"/>
            </StackPanel>
          </StackPanel>

          <!-- the three checks that earn the word 'identical' -->
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Border Background="#33FFFFFF" BorderBrush="#55FFFFFF" BorderThickness="1"
                    CornerRadius="8" Padding="14,10" Margin="0,0,10,0">
              <StackPanel>
                <TextBlock Text="STEP 1" Foreground="#9DBBFF" FontSize="10" FontWeight="Bold"/>
                <TextBlock Text="Same size" Foreground="White" FontSize="15" FontWeight="SemiBold"/>
              </StackPanel>
            </Border>
            <Border Background="#33FFFFFF" BorderBrush="#55FFFFFF" BorderThickness="1"
                    CornerRadius="8" Padding="14,10" Margin="0,0,10,0">
              <StackPanel>
                <TextBlock Text="STEP 2" Foreground="#9DBBFF" FontSize="10" FontWeight="Bold"/>
                <TextBlock Text="Same SHA-256" Foreground="White" FontSize="15" FontWeight="SemiBold"/>
              </StackPanel>
            </Border>
            <Border Background="#FFD98A" CornerRadius="8" Padding="14,10">
              <StackPanel>
                <TextBlock Text="STEP 3" Foreground="#8A5A0B" FontSize="10" FontWeight="Bold"/>
                <TextBlock Text="Byte-for-byte" Foreground="#5C3B00" FontSize="15" FontWeight="Bold"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </Grid>
      </Grid>
    </Border>

    <!-- controls -->
    <Border Grid.Row="1" Background="White" BorderBrush="#DEE5F0" BorderThickness="0,0,0,1" Padding="22,14">
      <StackPanel>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="Folder" VerticalAlignment="Center"
                     FontWeight="SemiBold" Foreground="#344054" Margin="0,0,10,0"/>
          <TextBox x:Name="TxtFolder" Grid.Column="1" Padding="8,7" VerticalContentAlignment="Center"
                   BorderBrush="#C9D4E6" Background="#FBFCFE"/>
          <Button x:Name="BtnBrowse" Grid.Column="2" Content="Browse" Style="{StaticResource GhostBtn}" Margin="10,0,0,0"/>
          <Button x:Name="BtnScan"   Grid.Column="3" Content="Scan for duplicates" Style="{StaticResource Btn}" Margin="10,0,0,0"/>
          <Button x:Name="BtnCancel" Grid.Column="4" Content="Stop" Style="{StaticResource GhostBtn}" Margin="10,0,0,0" Visibility="Collapsed"/>
          <Button x:Name="BtnUpdate" Grid.Column="5" Content="Check for updates" Style="{StaticResource GhostBtn}" Margin="10,0,0,0"/>
          <Button x:Name="BtnActivate" Grid.Column="6" Content="Activate" Style="{StaticResource GhostBtn}" Margin="10,0,0,0"/>
        </Grid>
        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
          <CheckBox x:Name="ChkSub" Content="Include subfolders" IsChecked="True" VerticalAlignment="Center" Foreground="#344054"/>
          <TextBlock Text="Ignore files smaller than" VerticalAlignment="Center" Margin="24,0,8,0" Foreground="#344054"/>
          <ComboBox x:Name="CmbMin" Width="170" VerticalContentAlignment="Center" SelectedIndex="0">
            <ComboBoxItem Content="100 KB (recommended)"/>
            <ComboBoxItem Content="Any size"/>
          </ComboBox>
        </StackPanel>
        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
          <TextBlock Text="Include cloud files from" VerticalAlignment="Center" FontWeight="SemiBold"
                     Foreground="#344054" Margin="0,0,12,0"/>
          <CheckBox x:Name="ChkCloudICloud"   Content="iCloud"    VerticalAlignment="Center" Margin="0,0,14,0" Foreground="#344054"/>
          <CheckBox x:Name="ChkCloudGoogle"   Content="Google Drive" VerticalAlignment="Center" Margin="0,0,14,0" Foreground="#344054"/>
          <CheckBox x:Name="ChkCloudOneDrive" Content="OneDrive"  VerticalAlignment="Center" Margin="0,0,14,0" Foreground="#344054"/>
          <CheckBox x:Name="ChkCloudDropbox"  Content="Dropbox"   VerticalAlignment="Center" Margin="0,0,14,0" Foreground="#344054"/>
          <CheckBox x:Name="ChkCloudMega"     Content="MEGA"      VerticalAlignment="Center" Margin="0,0,14,0" Foreground="#344054"/>
          <TextBlock x:Name="LblCloudHint" VerticalAlignment="Center" Foreground="#96500A" FontSize="12" TextWrapping="Wrap" MaxWidth="420"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
          <TextBlock Text="Also scan drives" VerticalAlignment="Center" FontWeight="SemiBold"
                     Foreground="#344054" Margin="0,0,12,0"/>
          <WrapPanel x:Name="DrivePanel" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
          <TextBlock Text="Look for" VerticalAlignment="Center" FontWeight="SemiBold"
                     Foreground="#344054" Margin="0,0,12,0"/>
          <ToggleButton x:Name="ChipAll" Style="{StaticResource Chip}" Content="Everything"/>
          <ToggleButton x:Name="ChipPic" Style="{StaticResource Chip}" Content="Pictures"/>
          <ToggleButton x:Name="ChipVid" Style="{StaticResource Chip}" Content="Videos"/>
          <ToggleButton x:Name="ChipAud" Style="{StaticResource Chip}" Content="Music &amp; audio"/>
          <ToggleButton x:Name="ChipDoc" Style="{StaticResource Chip}" Content="Documents"/>
          <ToggleButton x:Name="ChipArc" Style="{StaticResource Chip}" Content="Archives"/>
          <TextBlock x:Name="LblChips" VerticalAlignment="Center" Margin="8,0,0,0"
                     Foreground="#667085" FontSize="12"/>
        </StackPanel>

        <Border x:Name="CloudNote" Background="#FFF4E3" BorderBrush="#F0C88A" BorderThickness="1"
                CornerRadius="6" Padding="12,8" Margin="0,10,0,0" Visibility="Collapsed">
          <TextBlock x:Name="CloudNoteText" Foreground="#96500A" TextWrapping="Wrap" FontSize="13"/>
        </Border>
      </StackPanel>
    </Border>

    <!-- results -->
    <Grid Grid.Row="2">
      <ScrollViewer x:Name="Scroller" VerticalScrollBarVisibility="Auto" Padding="22,18">
        <StackPanel>

          <!-- Result of a clean-up: how much room you got back. -->
          <Border x:Name="SavedPanel" Visibility="Collapsed" Opacity="0" Background="#E7F6EF"
                  BorderBrush="#16835B" BorderThickness="2" CornerRadius="10"
                  Padding="24,20" Margin="0,0,0,18">
            <Border.RenderTransform>
              <TranslateTransform x:Name="SavedShift" Y="-14"/>
            </Border.RenderTransform>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>

              <Border Grid.Column="0" Width="54" Height="54" CornerRadius="27" Background="#16835B"
                      Margin="0,0,18,0" RenderTransformOrigin="0.5,0.5">
                <Border.RenderTransform>
                  <ScaleTransform x:Name="TickPop" ScaleX="0.4" ScaleY="0.4"/>
                </Border.RenderTransform>
                <TextBlock Text="&#10003;" Foreground="White" FontSize="30" FontWeight="Bold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>

              <StackPanel Grid.Column="1" VerticalAlignment="Center">
                <TextBlock x:Name="SavedBig" Text="You saved 0 bytes" FontSize="26" FontWeight="Bold"
                           Foreground="#0F5F42"/>
                <TextBlock x:Name="SavedSub" FontSize="13" Foreground="#16835B" Margin="0,3,0,0"
                           Text="Duplicates moved to the Recycle Bin."/>
              </StackPanel>

              <Border Grid.Column="2" Background="#16835B" CornerRadius="6" Padding="14,10"
                      VerticalAlignment="Center">
                <StackPanel>
                  <TextBlock Text="TOTAL THIS SESSION" Foreground="#C7EBDC" FontSize="10" FontWeight="Bold"/>
                  <TextBlock x:Name="SavedSession" Text="0 bytes" Foreground="White"
                             FontSize="17" FontWeight="Bold" HorizontalAlignment="Right"/>
                </StackPanel>
              </Border>
            </Grid>
          </Border>

          <!-- A quiet 'done' beat when a scan finishes: the tick draws itself in. -->
          <Border x:Name="ScanDone" Visibility="Collapsed" Opacity="0" Margin="0,0,0,14"
                  Padding="16,13" Background="#F3FAF6" BorderBrush="#BCE3D0" BorderThickness="1" CornerRadius="12"
                  RenderTransformOrigin="0.5,0.5">
            <Border.RenderTransform><ScaleTransform x:Name="ScanDoneScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <Grid Width="34" Height="34" Margin="0,0,13,0">
                <Ellipse Stroke="#16835B" StrokeThickness="2.5"/>
                <Path x:Name="ScanDoneTick" Stroke="#16835B" StrokeThickness="3"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                      StrokeDashArray="9 100" StrokeDashOffset="9" Data="M9,17.5 L14,22.5 L25,11"/>
              </Grid>
              <StackPanel VerticalAlignment="Center">
                <TextBlock Text="Scan complete" Foreground="#16835B" FontSize="14" FontWeight="SemiBold"/>
                <TextBlock x:Name="ScanDoneSub" Foreground="#667085" FontSize="12"/>
              </StackPanel>
            </StackPanel>
          </Border>

          <UniformGrid x:Name="StatStrip" Columns="3" Margin="0,0,0,4" Visibility="Collapsed">
            <Border Background="White" CornerRadius="12" BorderBrush="#7C5CD6" BorderThickness="5,1,1,1" Padding="18" Margin="0,0,12,0">
              <Border.Effect><DropShadowEffect Color="#6B82A6" BlurRadius="22" ShadowDepth="4" Direction="270" Opacity="0.20"/></Border.Effect>
              <StackPanel>
                <TextBlock Text="DUPLICATE SETS" Foreground="#7C5CD6" FontSize="11" FontWeight="Bold"/>
                <TextBlock x:Name="StatSets" Text="0" FontSize="27" FontWeight="SemiBold" Margin="0,8,0,0"/>
                <TextBlock Text="Groups of identical files" Foreground="#667085" FontSize="12"/>
              </StackPanel>
            </Border>
            <Border Background="White" CornerRadius="12" BorderBrush="#0E9C86" BorderThickness="5,1,1,1" Padding="18" Margin="0,0,12,0">
              <Border.Effect><DropShadowEffect Color="#6B82A6" BlurRadius="22" ShadowDepth="4" Direction="270" Opacity="0.20"/></Border.Effect>
              <StackPanel>
                <TextBlock Text="FILES TICKED" Foreground="#0E9C86" FontSize="11" FontWeight="Bold"/>
                <TextBlock x:Name="StatFiles" Text="0" FontSize="27" FontWeight="SemiBold" Margin="0,8,0,0"/>
                <TextBlock Text="Copies marked to remove" Foreground="#667085" FontSize="12"/>
              </StackPanel>
            </Border>
            <Border Background="White" CornerRadius="12" BorderBrush="#D97706" BorderThickness="5,1,1,1" Padding="18">
              <Border.Effect><DropShadowEffect Color="#6B82A6" BlurRadius="22" ShadowDepth="4" Direction="270" Opacity="0.20"/></Border.Effect>
              <StackPanel>
                <TextBlock Text="SPACE TO FREE" Foreground="#D97706" FontSize="11" FontWeight="Bold"/>
                <TextBlock x:Name="StatSpace" Text="0 bytes" FontSize="27" FontWeight="SemiBold" Margin="0,8,0,0"/>
                <TextBlock Text="Recovered once removed" Foreground="#667085" FontSize="12"/>
              </StackPanel>
            </Border>
          </UniformGrid>

          <Border x:Name="EmptyState" Background="White" CornerRadius="16" BorderBrush="#15A05C"
                  BorderThickness="0,5,0,0" Padding="48" Margin="0,40,0,0">
            <Border.Effect><DropShadowEffect Color="#6B82A6" BlurRadius="30" ShadowDepth="6" Direction="270" Opacity="0.24"/></Border.Effect>
            <StackPanel HorizontalAlignment="Center">
              <Border Width="82" Height="82" CornerRadius="41" HorizontalAlignment="Center" Margin="0,0,0,22">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#15A05C" Offset="0"/>
                    <GradientStop Color="#0B6B3C" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
                <TextBlock Text="&#9906;" Foreground="White" FontSize="40" FontWeight="Bold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <TextBlock x:Name="EmptyTitle" Text="No scan yet" FontSize="26" FontWeight="SemiBold"
                         Foreground="#1D2939" HorizontalAlignment="Center"/>
              <TextBlock x:Name="EmptyHint" Margin="0,10,0,0" Foreground="#667085" TextAlignment="Center"
                         MaxWidth="460" TextWrapping="Wrap"
                         Text="Pick a folder and press Scan. Every match is proved byte-for-byte before it is shown."/>
              <Border Background="#EAF7F0" BorderBrush="#BCE3D0" BorderThickness="1" CornerRadius="20"
                      Padding="16,8" Margin="0,22,0,0" HorizontalAlignment="Center">
                <TextBlock Text="Nothing is ever deleted without your say-so" Foreground="#0F5F42"
                           FontSize="12" FontWeight="SemiBold"/>
              </Border>
            </StackPanel>
          </Border>

          <!-- While a scan runs: a magnifier sweeping a circle, so it is obvious
               the program is looking rather than stuck. -->
          <Border x:Name="ScanBusy" Background="White" CornerRadius="10" BorderBrush="#DEE5F0"
                  BorderThickness="1" Padding="40" Margin="0,40,0,0" Visibility="Collapsed">
            <Border.Effect><DropShadowEffect Color="#6B82A6" BlurRadius="26" ShadowDepth="5" Direction="270" Opacity="0.22"/></Border.Effect>
            <StackPanel HorizontalAlignment="Center">
              <Grid Width="120" Height="120" HorizontalAlignment="Center">
                <Ellipse Width="104" Height="104" Stroke="#D6F0E2" StrokeThickness="10"/>
                <Grid x:Name="SweepHost" Width="120" Height="120" RenderTransformOrigin="0.5,0.5">
                  <Grid.RenderTransform>
                    <RotateTransform x:Name="SweepSpin" Angle="0"/>
                  </Grid.RenderTransform>
                  <TextBlock Text="&#128269;" FontSize="38" HorizontalAlignment="Center"
                             VerticalAlignment="Top" Margin="0,-4,0,0"/>
                </Grid>
              </Grid>
              <TextBlock x:Name="ScanBusyTitle" Text="Searching..." FontSize="20" FontWeight="SemiBold"
                         Foreground="#0B6B3C" HorizontalAlignment="Center" Margin="0,14,0,0"/>
              <TextBlock x:Name="ScanBusyHint" Margin="0,8,0,0" Foreground="#667085" TextAlignment="Center"
                         Text="Looking through your files."/>
            </StackPanel>
          </Border>

          <ItemsControl x:Name="GroupList">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <Border Background="White" CornerRadius="10" BorderBrush="#F0B4B4" BorderThickness="2"
                        Margin="0,0,0,16">
                  <Border.Effect><DropShadowEffect Color="#6B82A6" BlurRadius="22" ShadowDepth="4" Direction="270" Opacity="0.20"/></Border.Effect>
                  <StackPanel>
                    <Border Background="#FDECEC" CornerRadius="8,8,0,0" Padding="16,12">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <!-- what the file actually is -->
                        <Border Grid.Column="0" Width="76" Height="76" CornerRadius="6" Background="White"
                                BorderBrush="#F0B4B4" BorderThickness="1" Margin="0,0,14,0">
                          <Grid>
                            <Image Source="{Binding Preview}" Stretch="Uniform" Margin="3"
                                   RenderOptions.BitmapScalingMode="HighQuality"/>
                            <TextBlock x:Name="glyph" Text="{Binding NoPreviewGlyph}" FontSize="13" FontWeight="Bold"
                                       Foreground="#8A94A6" HorizontalAlignment="Center" VerticalAlignment="Center"
                                       Visibility="Collapsed"/>
                          </Grid>
                        </Border>

                        <StackPanel Grid.Column="1" VerticalAlignment="Center">
                          <TextBlock Text="{Binding HeaderText}" FontSize="17" FontWeight="Bold" Foreground="#990F17"/>
                          <TextBlock Text="{Binding KindText}" FontSize="13" Foreground="#96500A" Margin="0,2,0,0"/>
                          <TextBlock Text="{Binding HashText}" FontSize="11" Foreground="#A86412"
                                     FontFamily="Consolas" Margin="0,4,0,0"/>
                        </StackPanel>
                        <Border Grid.Column="2" Background="#C63C3C" CornerRadius="5" Padding="12,6" VerticalAlignment="Center">
                          <TextBlock Text="{Binding WasteText}" Foreground="White" FontWeight="Bold"/>
                        </Border>
                      </Grid>
                    </Border>

                    <ItemsControl ItemsSource="{Binding Files}" Margin="0,4,0,6">
                      <ItemsControl.ItemTemplate>
                        <DataTemplate>
                          <Border x:Name="row" Padding="16,10" Margin="8,2" CornerRadius="6" Background="#FFF9F9">
                            <Grid>
                              <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="150"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                              </Grid.ColumnDefinitions>

                              <CheckBox x:Name="cb" Grid.Column="0" VerticalAlignment="Center" Margin="0,0,12,0"
                                        IsChecked="{Binding IsSelected}"/>

                              <Grid Grid.Column="1" HorizontalAlignment="Left" VerticalAlignment="Center">
                                <!-- halo only exists on rows that are actually being removed -->
                                <Border x:Name="halo" CornerRadius="6" Background="#C63C3C" Opacity="0"
                                        Margin="-4" IsHitTestVisible="False"
                                        RenderTransformOrigin="0.5,0.5">
                                  <Border.RenderTransform>
                                    <ScaleTransform x:Name="haloScale" ScaleX="1" ScaleY="1"/>
                                  </Border.RenderTransform>
                                </Border>
                                <Border x:Name="badge" Background="#C63C3C" CornerRadius="4"
                                        Padding="8,4" RenderTransformOrigin="0.5,0.5">
                                  <Border.RenderTransform>
                                    <ScaleTransform x:Name="badgeScale" ScaleX="1" ScaleY="1"/>
                                  </Border.RenderTransform>
                                  <TextBlock Text="{Binding RoleText}" Foreground="White"
                                             FontSize="11" FontWeight="Bold"/>
                                </Border>
                              </Grid>

                              <StackPanel Grid.Column="2" Margin="14,0,0,0">
                                <TextBlock Text="{Binding FileName}" FontWeight="SemiBold" Foreground="#1D2939"
                                           TextTrimming="CharacterEllipsis"/>
                                <TextBlock Text="{Binding Folder}" FontSize="12" Foreground="#667085"
                                           TextTrimming="CharacterEllipsis"/>
                              </StackPanel>

                              <StackPanel Grid.Column="3" HorizontalAlignment="Right">
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,0,4">
                                  <Button x:Name="btnView" Tag="view" Content="Open file"
                                          Style="{StaticResource TinyBtn}" Margin="0,0,6,0"
                                          ToolTip="Open this file so you can see exactly what it is"/>
                                  <Button x:Name="btnFolder" Tag="folder" Content="Show in folder"
                                          Style="{StaticResource TinyBtn}"
                                          ToolTip="Open the containing folder with this file highlighted"/>
                                </StackPanel>
                                <TextBlock Text="{Binding SizeText}" HorizontalAlignment="Right"
                                           Foreground="#344054" FontWeight="SemiBold"/>
                                <TextBlock Text="{Binding Modified}" HorizontalAlignment="Right"
                                           FontSize="12" Foreground="#667085"/>
                                <TextBlock Text="{Binding RowNote}" HorizontalAlignment="Right"
                                           FontSize="12" Foreground="#16835B" FontWeight="SemiBold"/>
                              </StackPanel>
                            </Grid>
                          </Border>
                          <DataTemplate.Triggers>

                            <!-- Ticked duplicate: red, pulsing, with a spreading halo.
                                 This is the only state that moves. -->
                            <MultiDataTrigger>
                              <MultiDataTrigger.Conditions>
                                <Condition Binding="{Binding IsKeeper}"   Value="False"/>
                                <Condition Binding="{Binding IsSelected}" Value="True"/>
                                <Condition Binding="{Binding IsRemoved}"  Value="False"/>
                              </MultiDataTrigger.Conditions>
                              <MultiDataTrigger.EnterActions>
                                <BeginStoryboard x:Name="dangerPulse">
                                  <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="badgeScale" Storyboard.TargetProperty="ScaleX"
                                                     From="1" To="1.09" Duration="0:0:0.75"
                                                     AutoReverse="True" RepeatBehavior="Forever"/>
                                    <DoubleAnimation Storyboard.TargetName="badgeScale" Storyboard.TargetProperty="ScaleY"
                                                     From="1" To="1.09" Duration="0:0:0.75"
                                                     AutoReverse="True" RepeatBehavior="Forever"/>
                                    <DoubleAnimation Storyboard.TargetName="badge" Storyboard.TargetProperty="Opacity"
                                                     From="1" To="0.72" Duration="0:0:0.75"
                                                     AutoReverse="True" RepeatBehavior="Forever"/>
                                    <DoubleAnimation Storyboard.TargetName="haloScale" Storyboard.TargetProperty="ScaleX"
                                                     From="1" To="1.3" Duration="0:0:1.5" RepeatBehavior="Forever"/>
                                    <DoubleAnimation Storyboard.TargetName="haloScale" Storyboard.TargetProperty="ScaleY"
                                                     From="1" To="1.5" Duration="0:0:1.5" RepeatBehavior="Forever"/>
                                    <DoubleAnimation Storyboard.TargetName="halo" Storyboard.TargetProperty="Opacity"
                                                     From="0.35" To="0" Duration="0:0:1.5" RepeatBehavior="Forever"/>
                                  </Storyboard>
                                </BeginStoryboard>
                              </MultiDataTrigger.EnterActions>
                              <MultiDataTrigger.ExitActions>
                                <!-- Untick it and it stops dead, then settles green. -->
                                <StopStoryboard BeginStoryboardName="dangerPulse"/>
                                <BeginStoryboard>
                                  <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="badgeScale" Storyboard.TargetProperty="ScaleX"
                                                     To="1" Duration="0:0:0.2"/>
                                    <DoubleAnimation Storyboard.TargetName="badgeScale" Storyboard.TargetProperty="ScaleY"
                                                     To="1" Duration="0:0:0.2"/>
                                    <DoubleAnimation Storyboard.TargetName="badge" Storyboard.TargetProperty="Opacity"
                                                     To="1" Duration="0:0:0.2"/>
                                    <DoubleAnimation Storyboard.TargetName="halo" Storyboard.TargetProperty="Opacity"
                                                     To="0" Duration="0:0:0.2"/>
                                  </Storyboard>
                                </BeginStoryboard>
                              </MultiDataTrigger.ExitActions>
                            </MultiDataTrigger>

                            <!-- Unticked duplicate: safe now, so green and still. -->
                            <MultiDataTrigger>
                              <MultiDataTrigger.Conditions>
                                <Condition Binding="{Binding IsKeeper}"   Value="False"/>
                                <Condition Binding="{Binding IsSelected}" Value="False"/>
                                <Condition Binding="{Binding IsRemoved}"  Value="False"/>
                              </MultiDataTrigger.Conditions>
                              <Setter TargetName="row"   Property="Background" Value="#E7F6EF"/>
                              <Setter TargetName="badge" Property="Background" Value="#16835B"/>
                            </MultiDataTrigger>

                            <DataTrigger Binding="{Binding IsKeeper}" Value="True">
                              <Setter TargetName="row"   Property="Background" Value="#E7F6EF"/>
                              <Setter TargetName="badge" Property="Background" Value="#16835B"/>
                              <Setter TargetName="cb"    Property="Visibility" Value="Hidden"/>
                            </DataTrigger>

                            <DataTrigger Binding="{Binding IsRemoved}" Value="True">
                              <Setter TargetName="row"   Property="Background" Value="#F2F4F7"/>
                              <Setter TargetName="row"   Property="Opacity"    Value="0.55"/>
                              <Setter TargetName="badge" Property="Background" Value="#98A2B3"/>
                              <Setter TargetName="cb"    Property="Visibility" Value="Hidden"/>
                            </DataTrigger>
                          </DataTemplate.Triggers>
                        </DataTemplate>
                      </ItemsControl.ItemTemplate>
                    </ItemsControl>
                  </StackPanel>
                </Border>
                <DataTemplate.Triggers>
                  <DataTrigger Binding="{Binding HasPreview}" Value="False">
                    <Setter TargetName="glyph" Property="Visibility" Value="Visible"/>
                  </DataTrigger>
                </DataTemplate.Triggers>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
        </StackPanel>
      </ScrollViewer>
    </Grid>

    <!-- footer -->
    <Border Grid.Row="3" Background="White" BorderBrush="#DEE5F0" BorderThickness="0,1,0,0" Padding="22,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Grid Grid.Column="0" VerticalAlignment="Center">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto" MinWidth="170"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="LblSummary" Grid.Row="0" Grid.Column="0" Text="Ready." FontWeight="Bold" FontSize="17"
                     Foreground="#1D2939" VerticalAlignment="Center" RenderTransformOrigin="0,0.5">
            <TextBlock.RenderTransform>
              <ScaleTransform x:Name="SummaryScale" ScaleX="1" ScaleY="1"/>
            </TextBlock.RenderTransform>
          </TextBlock>
          <Button x:Name="BtnBack" Grid.Row="0" Grid.Column="1" Style="{StaticResource Btn}" Margin="10,0,0,0" VerticalAlignment="Center" Padding="16,9" Foreground="White" FontWeight="Bold" FontSize="15"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#2EE6C8" Offset="0"/><GradientStop Color="#00A892" Offset="0.55"/><GradientStop Color="#00705F" Offset="1"/></LinearGradientBrush></Button.Background><StackPanel Orientation="Horizontal"><Viewbox Width="44" Height="44" VerticalAlignment="Center" Margin="0,-10,10,-10" IsHitTestVisible="False"><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="DbChrome" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FFFFFF" Offset="0"/><GradientStop Color="#A9B8CF" Offset="0.2"/><GradientStop Color="#4A5A73" Offset="0.45"/><GradientStop Color="#E8EEF8" Offset="0.65"/><GradientStop Color="#6B7A92" Offset="0.85"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush><RadialGradientBrush x:Key="DbOrb" GradientOrigin="0.32,0.25" Center="0.4,0.4" RadiusX="0.75" RadiusY="0.75"><GradientStop Color="#E4F3FF" Offset="0"/><GradientStop Color="#6FAEFF" Offset="0.25"/><GradientStop Color="#1F5FE0" Offset="0.65"/><GradientStop Color="#061F66" Offset="1"/></RadialGradientBrush><LinearGradientBrush x:Key="DbGold" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF4B8" Offset="0"/><GradientStop Color="#F2B91C" Offset="0.45"/><GradientStop Color="#9A6000" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="DbGloss" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#E6FFFFFF" Offset="0"/><GradientStop Color="#1AFFFFFF" Offset="0.6"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="7" ShadowDepth="4" Direction="270" Opacity="0.6"/></Canvas.Effect><Ellipse Canvas.Left="5" Canvas.Top="9" Width="54" Height="54" Fill="#2A3548"/><Ellipse Canvas.Left="5" Canvas.Top="5" Width="54" Height="54" Fill="{StaticResource DbChrome}"/><Ellipse Canvas.Left="10" Canvas.Top="10" Width="44" Height="44" Fill="{StaticResource DbOrb}" Stroke="#8FE6FF" StrokeThickness="1"/><Path Data="M32,15 L14,31 h5 v14 h10 v-9 h6 v9 h10 v-14 h5 z" Fill="#7A4A00"><Path.RenderTransform><TranslateTransform Y="3"/></Path.RenderTransform></Path><Path Data="M32,15 L14,31 h5 v14 h10 v-9 h6 v9 h10 v-14 h5 z" Fill="{StaticResource DbGold}" Stroke="#FFF6B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Path Data="M32,15 L14,31 h8 l10,-9 l10,9 h8 z" Fill="{StaticResource DbGloss}" Opacity="0.7"/><Ellipse Canvas.Left="11" Canvas.Top="11" Width="26" Height="12" Fill="{StaticResource DbGloss}"><Ellipse.RenderTransform><RotateTransform Angle="-25" CenterX="13" CenterY="6"/></Ellipse.RenderTransform></Ellipse></Canvas></Viewbox><TextBlock Text="Back to the Cleaner" VerticalAlignment="Center" Foreground="White"/></StackPanel></Button>
          <ProgressBar x:Name="Bar" Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Height="6" Margin="0,8,16,0"
                       Visibility="Collapsed" Foreground="#2563EB" Background="#E3E8F0" BorderThickness="0"/>
        </Grid>
        <Border Grid.Column="1" x:Name="AckBox" Background="#FEF3E2" BorderBrush="#F0C88A" BorderThickness="1"
                CornerRadius="6" Padding="12,8" Margin="0,0,12,0" VerticalAlignment="Center"
                Visibility="Collapsed">
          <CheckBox x:Name="ChkAck" VerticalContentAlignment="Center" Foreground="#96500A" FontWeight="SemiBold">
            <TextBlock TextWrapping="Wrap" MaxWidth="300"
                       Text="I have looked at these files and agree to remove the ticked duplicates"/>
          </CheckBox>
        </Border>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <Button x:Name="BtnNone" Content="Untick all" Style="{StaticResource GhostBtn}"
                  Margin="0,0,10,0" IsEnabled="False"/>
          <Button x:Name="BtnDelete" Content="Move ticked duplicates to Recycle Bin"
                  Style="{StaticResource DangerBtn}" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
# Same "3D look" switch as the Cleaner's Dashboard: off there means flat here.
function Set-DR3DFromCleaner {
    param($Window)
    try {
        $v = Get-ItemProperty -LiteralPath 'HKCU:\Software\DRDirect\PC Cleaner' -Name 'Buttons3D' -ErrorAction Stop
        if ([int]$v.Buttons3D -eq 0) { $Window.Resources['DR3DButton'] = $null; $Window.Resources['DR3DParts'] = [Windows.Visibility]::Collapsed }
    } catch { }
}
$win = [Windows.Markup.XamlReader]::Load($reader)
Set-DR3DFromCleaner $win
# Small screens (a 15 inch laptop): shrink everything to fit instead of opening
# a window bigger than the screen. Big screens are left exactly as they were.
try {
    $drArea = [Windows.SystemParameters]::WorkArea
    $drFit = [Math]::Max(0.6, [Math]::Min(1.0, [Math]::Min($drArea.Height / 900.0, $drArea.Width / 1300.0)))
    if ($drFit -lt 0.99) {
        $win.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform($drFit, $drFit)
        $win.MinWidth = [Math]::Floor($win.MinWidth * $drFit)
        $win.MinHeight = [Math]::Floor($win.MinHeight * $drFit)
        $win.Width = [Math]::Min($win.Width, $drArea.Width * 0.92)
        $win.Height = [Math]::Min($win.Height, $drArea.Height * 0.92)
    }
} catch { }


# As the compiled exe the taskbar icon comes from the exe; as the updated script
# (hosted by powershell.exe) nothing sets one, so Windows shows the PowerShell
# icon. Give the window its own DRDirect icon and a stable app identity so both
# ways look the same.
try {
    $iconB64 = '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'
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.StreamSource = New-Object System.IO.MemoryStream (,[Convert]::FromBase64String($iconB64))
        $bmp.EndInit()
        $bmp.Freeze()
        $win.Icon = $bmp
    } catch { }
    if (-not ([System.Management.Automation.PSTypeName]'DRDirect.AppIdFinder').Type) {
        Add-Type -Namespace DRDirect -Name AppIdFinder -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@ -ErrorAction Stop
    }
    [void][DRDirect.AppIdFinder]::SetCurrentProcessExplicitAppUserModelID('DRDirect.DuplicateFinder')
} catch { }

# Never open larger than the visible screen, or the title bar and its buttons
# land off the top of a small or scaled display. Clamp to the work area.
try {
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($win.MinHeight -gt $wa.Height) { $win.MinHeight = $wa.Height }
    if ($win.MinWidth  -gt $wa.Width)  { $win.MinWidth  = $wa.Width }
    if ($win.Height -gt $wa.Height) { $win.Height = $wa.Height }
    if ($win.Width  -gt $wa.Width)  { $win.Width  = $wa.Width }
    $win.MaxHeight = $wa.Height
    $win.MaxWidth  = $wa.Width
} catch { }

$ui = @{}
foreach ($n in 'TxtFolder', 'BtnBrowse', 'BtnScan', 'BtnCancel', 'BtnUpdate', 'BtnActivate', 'SummaryScale', 'ChkSub', 'CmbMin', 'GroupList',
    'VersionText', 'DRLogo', 'EmptyState', 'EmptyTitle', 'EmptyHint', 'StatStrip', 'StatSets', 'StatFiles', 'StatSpace', 'ScanDone', 'ScanDoneScale', 'ScanDoneTick', 'ScanDoneSub', 'ScanBusy', 'SweepSpin', 'ScanBusyHint', 'LblSummary', 'Bar', 'BtnBack', 'BtnNone', 'BtnDelete', 'Scroller',
    'TrialBadge', 'TrialBadgeText', 'AckBox', 'ChkAck', 'ChkCloudICloud', 'ChkCloudGoogle', 'ChkCloudOneDrive', 'ChkCloudDropbox', 'ChkCloudMega', 'LblCloudHint', 'DrivePanel', 'ChipAll', 'ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc',
    'ChipArc', 'LblChips', 'CloudNote', 'CloudNoteText', 'SavedPanel', 'SavedBig', 'SavedSub', 'SavedSession', 'SavedShift', 'TickPop') {
    $ui[$n] = $win.FindName($n)
}

$groups = New-Object System.Collections.ObjectModel.ObservableCollection[DRD.DupGroup]
$ui.GroupList.ItemsSource = $groups

if ($StartFolder) {
    $ui.TxtFolder.Text = $StartFolder
} else {
    $ui.TxtFolder.Text = [Environment]::GetFolderPath('UserProfile')
}

$state = [hashtable]::Synchronized(@{})
$script:runspace = $null
$script:handle = $null
$script:ps = $null

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)

function Set-Busy {
    param([bool]$Busy)

    # The sweeping magnifier only spins while a scan is actually running.
    try {
        if ($Busy) {
            $ui.EmptyState.Visibility = 'Collapsed'
            if ($ui.ScanDone) { $ui.ScanDone.Visibility = 'Collapsed' }
            $ui.ScanBusy.Visibility = 'Visible'
            $spin = New-Object Windows.Media.Animation.DoubleAnimation(0, 360,
                (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(1400))))
            $spin.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $ui.SweepSpin.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $spin)
        } else {
            $ui.SweepSpin.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
            $ui.ScanBusy.Visibility = 'Collapsed'
        }
    } catch { }

    $ui.BtnScan.IsEnabled = -not $Busy
    $ui.BtnBrowse.IsEnabled = -not $Busy
    $ui.BtnDelete.IsEnabled = (-not $Busy) -and ($groups.Count -gt 0)
    $ui.BtnNone.IsEnabled = (-not $Busy) -and ($groups.Count -gt 0)
    $ui.BtnCancel.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $ui.Bar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
}

$ImageExt = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.ico', '.webp')

# What each chip covers. Tick several and they add together.
$TypeSets = @{
    Pic = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.heif',
        '.ico', '.svg', '.raw', '.cr2', '.cr3', '.nef', '.arw', '.orf', '.rw2', '.dng', '.psd')
    Vid = @('.mp4', '.m4v', '.mov', '.avi', '.mkv', '.wmv', '.webm', '.flv', '.mpg', '.mpeg',
        '.m2v', '.3gp', '.3g2', '.mts', '.m2ts', '.ts', '.vob', '.ogv', '.divx', '.rm',
        '.rmvb', '.asf', '.f4v', '.mxf')
    Aud = @('.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.oga', '.opus', '.wma', '.aiff',
        '.aif', '.alac', '.ape', '.mid', '.midi', '.amr', '.m4b', '.wv')
    Doc = @('.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.rtf', '.csv',
        '.odt', '.ods', '.odp', '.epub', '.mobi', '.pages', '.numbers')
    Arc = @('.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso', '.cab', '.tgz')
}

$KindMap = @{
    # pictures
    '.jpg' = 'JPEG photo'; '.jpeg' = 'JPEG photo'; '.png' = 'PNG image'; '.gif' = 'GIF image'
    '.bmp' = 'Bitmap image'; '.tif' = 'TIFF image'; '.tiff' = 'TIFF image'; '.webp' = 'WebP image'
    '.heic' = 'HEIC photo'; '.heif' = 'HEIF photo'; '.ico' = 'Icon'; '.svg' = 'SVG graphic'
    '.raw' = 'RAW photo'; '.cr2' = 'Canon RAW photo'; '.nef' = 'Nikon RAW photo'
    '.arw' = 'Sony RAW photo'; '.dng' = 'DNG RAW photo'; '.psd' = 'Photoshop file'

    # video
    '.mp4' = 'MP4 video'; '.m4v' = 'MP4 video'; '.mov' = 'QuickTime video'; '.avi' = 'AVI video'
    '.mkv' = 'MKV video'; '.wmv' = 'WMV video'; '.webm' = 'WebM video'; '.flv' = 'Flash video'
    '.mpg' = 'MPEG video'; '.mpeg' = 'MPEG video'; '.m2v' = 'MPEG video'; '.3gp' = 'Phone video'
    '.3g2' = 'Phone video'; '.mts' = 'Camcorder video'; '.m2ts' = 'Camcorder video'
    '.ts' = 'Video stream'; '.vob' = 'DVD video'; '.ogv' = 'OGG video'; '.divx' = 'DivX video'
    '.rm' = 'RealMedia video'; '.rmvb' = 'RealMedia video'; '.asf' = 'ASF video'
    '.f4v' = 'Flash video'; '.mxf' = 'Broadcast video'

    # audio
    '.mp3' = 'MP3 audio'; '.m4a' = 'AAC audio'; '.aac' = 'AAC audio'; '.wav' = 'WAV audio'
    '.flac' = 'FLAC audio'; '.ogg' = 'OGG audio'; '.oga' = 'OGG audio'; '.opus' = 'Opus audio'
    '.wma' = 'WMA audio'; '.aiff' = 'AIFF audio'; '.aif' = 'AIFF audio'; '.alac' = 'ALAC audio'
    '.ape' = 'APE audio'; '.mid' = 'MIDI music'; '.midi' = 'MIDI music'; '.amr' = 'Voice recording'
    '.m4b' = 'Audiobook'; '.m3u' = 'Playlist'

    # documents
    '.pdf' = 'PDF document'; '.doc' = 'Word document'; '.docx' = 'Word document'
    '.xls' = 'Excel spreadsheet'; '.xlsx' = 'Excel spreadsheet'; '.csv' = 'CSV data'
    '.ppt' = 'PowerPoint'; '.pptx' = 'PowerPoint'; '.txt' = 'Text file'; '.rtf' = 'Rich text'
    '.epub' = 'eBook'; '.mobi' = 'eBook'

    # everything else
    '.zip' = 'Zip archive'; '.rar' = 'RAR archive'; '.7z' = 'Archive'; '.tar' = 'Archive'
    '.gz' = 'Archive'; '.iso' = 'Disc image'; '.exe' = 'Program'; '.msi' = 'Installer'
    '.dll' = 'Program component'; '.bak' = 'Backup file'
}

function Get-Kind {
    param([string]$Ext)
    $e = $Ext.ToLowerInvariant()
    if ($KindMap.ContainsKey($e)) { return $KindMap[$e] }
    if ($e) { return "$($e.TrimStart('.').ToUpperInvariant()) file" }
    return 'File'
}

function Get-Thumb {
    # A small preview so you can see at a glance what the set actually is.
    # Pictures are decoded directly; everything else - video frames, album art,
    # PDF pages, documents - comes from Windows' own thumbnail service.
    param([string]$Path, [string]$Ext)

    if ($ImageExt -contains $Ext) {
        try {
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.UriSource = New-Object System.Uri $Path
            $bi.DecodePixelWidth = 150
            $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreColorProfile
            $bi.EndInit()
            $bi.Freeze()
            return $bi
        } catch { }
    }

    $hbm = [IntPtr]::Zero
    try {
        $hbm = [DRD.Thumbs]::GetBitmap($Path, 150)
        if ($hbm -eq [IntPtr]::Zero) { return $null }
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
            $hbm, [IntPtr]::Zero, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $src.Freeze()
        return $src
    } catch {
        return $null
    } finally {
        if ($hbm -ne [IntPtr]::Zero) { [void][DRD.Thumbs]::DeleteObject($hbm) }
    }
}

function Open-Selected {
    # Opening a file is read-only - it just shows you what you are about to remove.
    param([string]$Path, [switch]$InFolder)
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            [DRDirect.MsgBox]::Show('That file is no longer there.', 'Duplicate Finder', 'OK', 'Information') | Out-Null
            return
        }
        # "Open file" must always do something visible and never run a program.
        # Only genuinely viewable files (documents, images, media) are opened; and
        # if opening one fails, we still reveal it. Everything else - scripts,
        # programs, archives, packages, unknown types - is shown in its folder, so
        # the button works for every file and can never execute anything.
        $openable = @(
            '.txt','.md','.log','.csv','.tsv','.rtf','.pdf',
            '.doc','.docx','.xls','.xlsx','.ppt','.pptx','.odt','.ods','.odp',
            '.jpg','.jpeg','.png','.gif','.bmp','.webp','.tif','.tiff','.svg','.heic','.ico',
            '.mp3','.wav','.flac','.aac','.ogg','.m4a','.wma',
            '.mp4','.mov','.avi','.mkv','.webm','.wmv','.m4v',
            '.html','.htm','.xml','.json')
        $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
        $reveal = { Start-Process explorer.exe -ArgumentList "/select,`"$Path`"" }
        if (-not $InFolder -and $openable -contains $ext) {
            try { Start-Process -FilePath $Path } catch { & $reveal }
        } else {
            & $reveal
        }
    } catch {
        [DRDirect.MsgBox]::Show("Could not open that file:`n$($_.Exception.Message)",
            'Duplicate Finder', 'OK', 'Warning') | Out-Null
    }
}

$script:SessionFreed = 0L

function Show-Saved {
    # Slides in a green result panel and counts the freed space up to its total.
    param([long]$Bytes, [int]$Count)

    $script:SessionFreed += $Bytes
    $ui.SavedSub.Text = "$Count duplicate $(if ($Count -eq 1) { 'file' } else { 'files' }) moved to the Recycle Bin. One copy of each was kept."
    $ui.SavedSession.Text = Format-Size $script:SessionFreed
    $ui.SavedPanel.Visibility = 'Visible'
    $ui.Scroller.ScrollToTop()

    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'

    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 1, ([TimeSpan]::FromMilliseconds(320))
    $ui.SavedPanel.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation -14, 0, ([TimeSpan]::FromMilliseconds(380))
    $slide.EasingFunction = $ease
    $ui.SavedShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)

    $back = New-Object System.Windows.Media.Animation.BackEase
    $back.EasingMode = 'EaseOut'
    $back.Amplitude = 0.9
    foreach ($p in @([System.Windows.Media.ScaleTransform]::ScaleXProperty,
            [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
        $pop = New-Object System.Windows.Media.Animation.DoubleAnimation 0.4, 1, ([TimeSpan]::FromMilliseconds(520))
        $pop.EasingFunction = $back
        $ui.TickPop.BeginAnimation($p, $pop)
    }

    # Count the headline figure up rather than snapping to it. The unit is fixed
    # from the final total first - letting Format-Size pick per frame made the text
    # flip bytes -> KB -> MB mid-count, which reads as flicker.
    $unit = Get-SizeUnit $Bytes
    $steps = 26
    $i = 0
    $countTimer = New-Object System.Windows.Threading.DispatcherTimer
    $countTimer.Interval = [TimeSpan]::FromMilliseconds(28)
    $countTimer.Add_Tick({
            $i++
            if ($i -ge $steps) {
                $ui.SavedBig.Text = "You saved $(Format-Size $Bytes)"
                $countTimer.Stop()
                return
            }
            $t = $i / $steps
            $eased = 1 - [Math]::Pow(1 - $t, 3)
            $shown = $unit.Format -f (($Bytes * $eased) / $unit.Divisor)
            $ui.SavedBig.Text = "You saved $shown"
        }.GetNewClosure())
    $countTimer.Start()
}

function Show-FolderPicker {
    # The stock Windows folder tree looks nothing like the rest of the app,
    # so this is our own picker in the same style.
    param([string]$Start, [switch]$BuildOnly)

    $pxaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Choose a folder" Width="960" Height="660" MinWidth="760" MinHeight="520"
        WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Ideal">
  <Window.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#EEF3FB" Offset="0"/>
      <GradientStop Color="#CBD8EA" Offset="1"/>
    </LinearGradientBrush>
  </Window.Background>

  <Window.Resources>
    <DropShadowEffect x:Key="DR3DButton" Color="#0A1A4A" Direction="270" ShadowDepth="11" BlurRadius="18" Opacity="0.7"/><Visibility x:Key="DR3DParts">Visible</Visibility>
    <Style x:Key="PBtn" TargetType="Button"><Setter Property="Effect" Value="{DynamicResource DR3DButton}"/>
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform x:Name="sc" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
              <Border x:Name="b" CornerRadius="6" Background="{TemplateBinding Background}"
                      Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Border CornerRadius="6" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}" BorderThickness="0,0,0,4" BorderBrush="#55000000"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#A6FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="0.55"/></LinearGradientBrush></Border.Background></Border>
              <Border x:Name="glow" CornerRadius="6" Background="White" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="MouseEnter">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1.05" Duration="0:0:0.13"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1.05" Duration="0:0:0.13"/>
                  <DoubleAnimation Storyboard.TargetName="glow" Storyboard.TargetProperty="Opacity" To="0.16" Duration="0:0:0.13"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="MouseLeave">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.18"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.18"/>
                  <DoubleAnimation Storyboard.TargetName="glow" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.18"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="PreviewMouseLeftButtonDown">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="0.95" Duration="0:0:0.06"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="0.95" Duration="0:0:0.06"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="PreviewMouseLeftButtonUp">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1.05" Duration="0:0:0.22">
                    <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.6"/></DoubleAnimation.EasingFunction>
                  </DoubleAnimation>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1.05" Duration="0:0:0.22">
                    <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.6"/></DoubleAnimation.EasingFunction>
                  </DoubleAnimation>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Background" Value="#98A2B3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PGhost" TargetType="Button" BasedOn="{StaticResource PBtn}">
      <Setter Property="Background" Value="#E3E8F0"/>
      <Setter Property="Foreground" Value="#1E40AF"/>
    </Style>

    <!-- shortcuts down the left -->
    <Style x:Key="PlaceBtn" TargetType="Button"><Setter Property="Effect" Value="{DynamicResource DR3DButton}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#1D2939"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="pb" CornerRadius="6" Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}" Margin="0,1">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="pb" Property="Background" Value="#E8F0FF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Padding="24,18" ClipToBounds="True">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#08301D" Offset="0"/>
          <GradientStop Color="#15A05C" Offset="0.5"/>
          <GradientStop Color="#0B6B3C" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <StackPanel Orientation="Horizontal">
        <Path Data="M2,5 L9,5 L11.5,8 L22,8 A1.6,1.6 0 0 1 23.6,9.6 L23.6,19.5 A1.6,1.6 0 0 1 22,21.1 L2,21.1 A1.6,1.6 0 0 1 0.4,19.5 L0.4,6.6 A1.6,1.6 0 0 1 2,5 Z"
              Fill="#FFD98A" Stretch="Uniform" Width="38" Height="38"
              VerticalAlignment="Center" Margin="0,0,16,0"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="CHOOSE A FOLDER" Foreground="White" FontSize="26" FontWeight="Bold"/>
          <TextBlock Text="Pick where to look for duplicates. Subfolders are included."
                     Foreground="#CBDCFF" FontSize="13" Margin="0,2,0,0"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <Border Grid.Row="1" Background="White" BorderBrush="#DEE5F0" BorderThickness="0,0,0,1" Padding="20,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="BtnUp" Grid.Column="0" Style="{StaticResource PGhost}" Margin="0,0,12,0">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE74A;" FontFamily="Segoe MDL2 Assets" FontSize="13"
                       VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock Text="Up" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
        <TextBox x:Name="TxtPath" Grid.Column="1" Padding="10,8" VerticalContentAlignment="Center"
                 BorderBrush="#C9D4E6" Background="#FBFCFE" FontSize="13"/>
      </Grid>
    </Border>

    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="250"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#FBFCFE" BorderBrush="#DEE5F0" BorderThickness="0,0,1,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="10,12">
          <StackPanel x:Name="Places"/>
        </ScrollViewer>
      </Border>

      <Grid Grid.Column="1">
        <ListBox x:Name="FolderList" BorderThickness="0" Background="Transparent" Padding="12"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled">
          <ListBox.ItemContainerStyle>
            <Style TargetType="ListBoxItem">
              <Setter Property="Padding" Value="10,9"/>
              <Setter Property="Margin" Value="0,1"/>
              <Setter Property="Cursor" Value="Hand"/>
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="ListBoxItem">
                    <Border x:Name="lb" CornerRadius="6" Background="Transparent"
                            Padding="{TemplateBinding Padding}">
                      <ContentPresenter/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="lb" Property="Background" Value="#EEF3FC"/>
                      </Trigger>
                      <Trigger Property="IsSelected" Value="True">
                        <Setter TargetName="lb" Property="Background" Value="#2563EB"/>
                        <Setter Property="Foreground" Value="White"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
            </Style>
          </ListBox.ItemContainerStyle>
          <ListBox.ItemTemplate>
            <DataTemplate>
              <StackPanel Orientation="Horizontal">
                <Path Data="M2,5 L9,5 L11.5,8 L22,8 A1.6,1.6 0 0 1 23.6,9.6 L23.6,19.5 A1.6,1.6 0 0 1 22,21.1 L2,21.1 A1.6,1.6 0 0 1 0.4,19.5 L0.4,6.6 A1.6,1.6 0 0 1 2,5 Z"
                      Fill="#E8A33D" Stretch="Uniform" Width="20" Height="20"
                      VerticalAlignment="Center" Margin="0,0,12,0"/>
                <TextBlock Text="{Binding Name}" VerticalAlignment="Center" FontSize="14"/>
              </StackPanel>
            </DataTemplate>
          </ListBox.ItemTemplate>
        </ListBox>

        <TextBlock x:Name="EmptyMsg" Text="No subfolders in here." Foreground="#98A2B3"
                   HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
      </Grid>
    </Grid>

    <Border Grid.Row="3" Background="White" BorderBrush="#DEE5F0" BorderThickness="0,1,0,0" Padding="20,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,16,0">
          <TextBlock Text="SEARCHING IN" Foreground="#98A2B3" FontSize="10" FontWeight="Bold"/>
          <TextBlock x:Name="LblChosen" Foreground="#1D2939" FontWeight="SemiBold"
                     TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <Button x:Name="BtnCancelPick" Grid.Column="1" Content="Cancel" Style="{StaticResource PGhost}" Margin="0,0,10,0"/>
        <Button x:Name="BtnUse" Grid.Column="2" Content="Use this folder" Style="{StaticResource PBtn}"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    # WPF event handlers do not run inside this function's scope, so anything
    # they touch has to live at script scope.
    $script:PickerWin = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$pxaml)))
    $pw = $script:PickerWin
    Set-DR3DFromCleaner $pw

    $p = @{}
    foreach ($n in 'BtnUp', 'TxtPath', 'Places', 'FolderList', 'EmptyMsg',
        'LblChosen', 'BtnCancelPick', 'BtnUse') {
        $p[$n] = $pw.FindName($n)
    }
    $script:PickerUI = $p
    $script:PickerResult = $null

    $current = if ($Start -and (Test-Path -LiteralPath $Start)) { $Start } else { [Environment]::GetFolderPath('UserProfile') }

    $script:PickerGoto = {
        param([string]$Path)
        if (-not $Path) { return }
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $u = $script:PickerUI
        $script:PickerCurrent = (Resolve-Path -LiteralPath $Path).Path
        $u.TxtPath.Text = $script:PickerCurrent
        $u.LblChosen.Text = $script:PickerCurrent
        $items = New-Object System.Collections.ObjectModel.ObservableCollection[object]
        try {
            Get-ChildItem -LiteralPath $script:PickerCurrent -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::System) } |
            Sort-Object Name |
            ForEach-Object { $items.Add([pscustomobject]@{ Name = $_.Name; Path = $_.FullName }) }
        } catch { }
        $u.FolderList.ItemsSource = $items
        $u.EmptyMsg.Visibility = if ($items.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    }
    $goto = $script:PickerGoto

    # left-hand shortcuts: your own folders first, then the drives
    $places = @(
        @{ Icon = [char]0xE80F; Name = 'Home'; Path = [Environment]::GetFolderPath('UserProfile') }
        @{ Icon = [char]0xE7F4; Name = 'Desktop'; Path = [Environment]::GetFolderPath('Desktop') }
        @{ Icon = [char]0xE8A5; Name = 'Documents'; Path = [Environment]::GetFolderPath('MyDocuments') }
        @{ Icon = [char]0xE896; Name = 'Downloads'; Path = (Join-Path $env:USERPROFILE 'Downloads') }
        @{ Icon = [char]0xEB9F; Name = 'Pictures'; Path = [Environment]::GetFolderPath('MyPictures') }
        @{ Icon = [char]0xE8D6; Name = 'Music'; Path = [Environment]::GetFolderPath('MyMusic') }
        @{ Icon = [char]0xE714; Name = 'Videos'; Path = [Environment]::GetFolderPath('MyVideos') }
    )
    # Cloud shortcuts, from the shared detector so the picker and the include
    # checkboxes can never disagree about what is installed.
    try {
        $cloudFound = Get-DRCloudServices
        foreach ($name in $cloudFound.Keys) {
            $places += @{ Icon = [char]0xE753; Name = $name; Path = $cloudFound[$name][0] }
        }
    } catch { }

    function Add-Place {
        param($Icon, $Name, $Path, $Sub)
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $pw.FindResource('PlaceBtn')
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $ic = New-Object System.Windows.Controls.TextBlock
        $ic.Text = [string]$Icon
        $ic.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
        $ic.FontSize = 16
        $ic.Foreground = $pw.FindResource([System.Windows.SystemColors]::HighlightBrushKey)
        $ic.Foreground = [System.Windows.Media.Brushes]::SteelBlue
        $ic.VerticalAlignment = 'Center'
        $ic.Margin = '0,0,12,0'
        $tx = New-Object System.Windows.Controls.TextBlock
        $tx.Text = $Name
        $tx.VerticalAlignment = 'Center'
        $sp.Children.Add($ic) | Out-Null
        $sp.Children.Add($tx) | Out-Null
        if ($Sub) {
            $tx.Text = $Name
            $tx.FontWeight = 'SemiBold'
        }
        $b.Content = $sp
        $b.Tag = $Path
        $b.Add_Click({ & $script:PickerGoto $this.Tag })
        $p.Places.Children.Add($b) | Out-Null
    }

    foreach ($pl in $places) {
        if ($pl.Path -and (Test-Path -LiteralPath $pl.Path)) {
            Add-Place -Icon $pl.Icon -Name $pl.Name -Path $pl.Path
        }
    }

    $sep = New-Object System.Windows.Controls.TextBlock
    $sep.Text = 'THIS PC'
    $sep.FontSize = 10
    $sep.FontWeight = 'Bold'
    $sep.Foreground = [System.Windows.Media.Brushes]::Gray
    $sep.Margin = '12,16,0,6'
    $p.Places.Children.Add($sep) | Out-Null

    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        $label = if ($d.VolumeLabel) { "$($d.Name.TrimEnd('\')) $($d.VolumeLabel)" } else { $d.Name.TrimEnd('\') }
        $free = Format-Size $d.AvailableFreeSpace
        Add-Place -Icon ([char]0xEDA2) -Name "$label  ($free free)" -Path $d.RootDirectory.FullName
    }

    $p.FolderList.Add_MouseDoubleClick({
            $sel = $script:PickerUI.FolderList.SelectedItem
            if ($sel) { & $script:PickerGoto $sel.Path }
        })
    $p.FolderList.Add_SelectionChanged({
            $sel = $script:PickerUI.FolderList.SelectedItem
            if ($sel) { $script:PickerUI.LblChosen.Text = $sel.Path }
        })
    $p.BtnUp.Add_Click({
            $parent = Split-Path -Parent $script:PickerCurrent
            if ($parent) { & $script:PickerGoto $parent }
        })
    $p.TxtPath.Add_KeyDown({
            if ($_.Key -eq 'Return') { & $script:PickerGoto $script:PickerUI.TxtPath.Text.Trim() }
        })
    $p.BtnCancelPick.Add_Click({ $script:PickerWin.DialogResult = $false })
    $p.BtnUse.Add_Click({
            # A highlighted subfolder wins; otherwise take the folder we are in.
            $sel = $script:PickerUI.FolderList.SelectedItem
            $script:PickerResult = if ($sel) { $sel.Path } else { $script:PickerCurrent }
            $script:PickerWin.DialogResult = $true
        })

    & $goto $current
    if ($BuildOnly) { Write-Host 'TestMode: folder picker built OK.'; return $null }
    $pw.Owner = $win
    if ($pw.ShowDialog()) { return $script:PickerResult }
    return $null
}

function Show-DRSummaryFlash {
    <#
        Answers where the person is looking. The line is easy to miss otherwise,
        so it swells briefly and settles - enough to catch the eye without
        turning into something that nags.
    #>
    try {
        $pop = New-Object Windows.Media.Animation.DoubleAnimation
        $pop.From = 1
        $pop.To = 1.12
        $pop.Duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(260))
        $pop.AutoReverse = $true
        $pop.RepeatBehavior = New-Object Windows.Media.Animation.RepeatBehavior (3)
        $pop.EasingFunction = New-Object Windows.Media.Animation.SineEase -Property @{ EasingMode = 'EaseInOut' }
        $ui.SummaryScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $pop)
        $ui.SummaryScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $pop)
    } catch { }
}

function Update-Summary {
    $dupCount = 0
    $recoverable = 0L
    foreach ($g in $groups) {
        foreach ($f in $g.Files) {
            if ((-not $f.IsKeeper) -and $f.IsSelected -and (-not $f.IsRemoved)) {
                $dupCount++
                $recoverable += $f.Size
            }
        }
    }
    if ($groups.Count -eq 0) {
        $ui.LblSummary.Text = 'No exact duplicates found.'
    } else {
        $ui.LblSummary.Text = "$($groups.Count) duplicate sets found  -  $dupCount files ticked  -  $(Format-Size $recoverable) will be freed"
    }

    # The same three numbers, read at a glance instead of out of one sentence.
    if ($ui.StatStrip) {
        $ui.StatSets.Text = [string]@($groups).Count
        $ui.StatFiles.Text = [string]$dupCount
        $ui.StatSpace.Text = Format-Size $recoverable
        $ui.StatStrip.Visibility = if (@($groups).Count -gt 0) { 'Visible' } else { 'Collapsed' }
    }
    $ui.AckBox.Visibility = if ($dupCount -gt 0) { 'Visible' } else { 'Collapsed' }
    # Nothing is removed until you have seen the files and ticked the acknowledgement.
    $ui.BtnDelete.IsEnabled = ($dupCount -gt 0) -and ($ui.ChkAck.IsChecked -eq $true)
}

# The five services offered as checkboxes, and the boxes that control them.
$script:DRCloudBoxes = [ordered]@{
    'iCloud'       = 'ChkCloudICloud'
    'Google Drive' = 'ChkCloudGoogle'
    'OneDrive'     = 'ChkCloudOneDrive'
    'Dropbox'      = 'ChkCloudDropbox'
    'MEGA'         = 'ChkCloudMega'
}

function Initialize-DRCloudBoxes {
    <#
        .SYNOPSIS
            Enables the checkbox for each cloud service that is set up on this PC.
        .DESCRIPTION
            A service only has a folder here once its app is installed and signed
            in. Offering a tick box for one that is not would promise a scan that
            cannot happen, so those stay switched off and say why.
    #>
    $found = try { Get-DRCloudServices } catch { [ordered]@{} }
    $script:DRCloudRoots = @{}
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($name in $script:DRCloudBoxes.Keys) {
        $box = $ui[$script:DRCloudBoxes[$name]]
        if (-not $box) { continue }

        $roots = @()
        foreach ($k in $found.Keys) {
            # "OneDrive" also matches "OneDrive for Business".
            if ($k -eq $name -or $k -like ($name + ' *')) { $roots += @($found[$k]) }
        }

        if ($roots.Count -gt 0) {
            $script:DRCloudRoots[$name] = $roots
            $box.IsEnabled = $true
            $box.Tag = $name
            $box.ToolTip = "Off by default. Online-only files are not kept on this PC, so ticking this downloads every one from $name to compare it." +
                           [Environment]::NewLine + ($roots -join [Environment]::NewLine)
        } else {
            $box.IsChecked = $false
            $box.IsEnabled = $false
            $box.Opacity = 0.45
            $box.ToolTip = "$name is not installed on this PC. Install the $name app for Windows and sign in, then reopen the Duplicate Finder. Signing in on the website is not enough - the app is what puts the files on this PC."
            $missing.Add($name)
        }
    }

    if ($ui.LblCloudHint) {
        # "Signed in" is not the test - a website login puts nothing on this PC.
        # The service's own Windows app has to be installed and syncing before
        # there are any files here to compare.
        $ui.LblCloudHint.Text = if ($missing.Count -eq 0) { '' }
            elseif ($missing.Count -eq $script:DRCloudBoxes.Count) {
                'None of these are installed on this PC. Install the app for a service and sign in - signing in on its website is not enough.'
            } else {
                'Not installed on this PC: ' + ($missing -join ', ')
            }
    }
}

function Set-DRCloudFolderTarget {
    <#
        .SYNOPSIS
            Points the scan at a service's folder when its box is ticked.
        .DESCRIPTION
            Ticking a cloud service is a statement of intent: those are the files
            the person wants looked at. If the folder box is still somewhere that
            has nothing to do with that service, move it there rather than run a
            scan that can only come back empty. An existing choice inside that
            service is left alone.
    #>
    param([string]$Service)

    if (-not $script:DRCloudRoots.ContainsKey($Service)) { return }
    $roots = @($script:DRCloudRoots[$Service])
    if ($roots.Count -eq 0) { return }

    $current = [string]$ui.TxtFolder.Text
    foreach ($r in $roots) {
        if ($current -and $current.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return }
    }

    $target = $roots[0]
    # Google Drive mounts a whole drive; the person's own files live in My Drive.
    $myDrive = Join-Path $target 'My Drive'
    if ((Test-Path -LiteralPath $myDrive) -and ($target -match '^[A-Za-z]:\?$')) { $target = $myDrive }

    $ui.TxtFolder.Text = $target
}

function Initialize-DRDriveBoxes {
    <#
        .SYNOPSIS
            One tick box per drive on this PC, so other drives can be scanned too.
        .DESCRIPTION
            Off by default. A ticked drive is scanned alongside the folder and any
            ticked cloud services; the same protected-location rules apply to it.
    #>
    $script:DRDriveBoxes = New-Object System.Collections.Generic.List[object]
    if (-not $ui.DrivePanel) { return }
    $ui.DrivePanel.Children.Clear()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $d.IsReady) { continue }
            if ($d.DriveType -notin 'Fixed', 'Removable', 'Network') { continue }
            $letter = $d.Name.TrimEnd('\')
            $label = if ($d.VolumeLabel) { "$letter $($d.VolumeLabel)" } else { $letter }
            $box = New-Object System.Windows.Controls.CheckBox
            $box.Content = $label
            $box.Tag = $d.RootDirectory.FullName
            $box.VerticalAlignment = 'Center'
            $box.Margin = '0,0,14,0'
            $box.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#344054'))
            $box.ToolTip = "Scan all of $letter as well. $(Format-Size $d.TotalFreeSpace) free of $(Format-Size $d.TotalSize)."
            $ui.DrivePanel.Children.Add($box) | Out-Null
            $script:DRDriveBoxes.Add($box)
        } catch { }
    }
}

function Get-DRScanRoots {
    <#
        Everything the person asked to be scanned: the folder box, each ticked
        cloud service and each ticked drive. A folder already inside another
        one on the list is dropped so no file is counted twice.
    #>
    param([string]$Folder)
    $all = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Folder)) { $all.Add($Folder) }
    foreach ($r in @(Get-TickedCloudRoots)) {
        # Google Drive mounts a whole drive; the person's own files live in My Drive.
        $myDrive = Join-Path $r 'My Drive'
        if (($r -match '^[A-Za-z]:\?$') -and (Test-Path -LiteralPath $myDrive)) { $r = $myDrive }
        $all.Add($r)
    }
    foreach ($box in $script:DRDriveBoxes) {
        if ($box.IsChecked -eq $true) { $all.Add([string]$box.Tag) }
    }

    $full = @($all | Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') + '\' } |
        Sort-Object Length)
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($p in $full) {
        $inside = $false
        if ($ui.ChkSub.IsChecked) {
            foreach ($k in $keep) { if ($p.StartsWith($k, [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break } }
        } else {
            foreach ($k in $keep) { if ($p -ieq $k) { $inside = $true; break } }
        }
        if (-not $inside) { $keep.Add($p) }
    }
    # Drive roots stay as "D:\"; every other folder goes back without the slash.
    return @($keep | ForEach-Object { if ($_ -match '^[A-Za-z]:\\$') { $_ } else { $_.TrimEnd('\') } })
}

function Get-TickedCloudRoots {
    <# Folders for the ticked services only. Nothing else is ever downloaded. #>
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:DRCloudBoxes.Keys) {
        $box = $ui[$script:DRCloudBoxes[$name]]
        if (-not $box -or -not $box.IsChecked) { continue }
        if (-not $script:DRCloudRoots.ContainsKey($name)) { continue }
        foreach ($r in $script:DRCloudRoots[$name]) { $roots.Add($r) }
    }
    return @($roots)
}

function Get-MinBytes {
    # Two choices only: skip the small stuff, or take everything. Anything
    # under 100KB is noise - a thousand duplicate icons free a couple of
    # megabytes and bury the photos and videos worth finding.
    switch ($ui.CmbMin.SelectedIndex) {
        0 { 100KB }
        1 { 1 }
        default { 100KB }
    }
}

function Show-Results {
    param($Results)
    $groups.Clear()
    $sorted = @($Results | Sort-Object { - ($_.Size * ($_.Files.Count - 1)) })
    foreach ($r in $sorted) {
        $g = New-Object DRD.DupGroup
        $waste = $r.Size * ($r.Files.Count - 1)
        $g.HeaderText = "$($r.Files.Count) IDENTICAL COPIES  -  $(Format-Size $r.Size) each"
        $g.SizeText = Format-Size $r.Size
        $g.WasteText = "$(Format-Size $waste) wasted"
        $g.HashText = "SHA-256 $($r.Hash.Substring(0,32))...  -  verified byte-for-byte"
        $g.Waste = $waste

        $first = $r.Files[0]
        $ext = [System.IO.Path]::GetExtension($first.Name)
        $g.KindText = "$(Get-Kind $ext)  -  $($first.Name)"
        $g.NoPreviewGlyph = if ($ext) { $ext.TrimStart('.').ToUpperInvariant() } else { 'FILE' }
        $thumb = Get-Thumb -Path $first.FullName -Ext $ext.ToLowerInvariant()
        if ($thumb) { $g.Preview = $thumb; $g.HasPreview = $true }
        foreach ($f in $r.Files) {
            $d = New-Object DRD.DupFile
            $d.FullPath = $f.FullName
            $d.FileName = $f.Name
            $d.Folder = $f.DirectoryName
            $d.Size = $f.Length
            $d.SizeText = Format-Size $f.Length
            $d.Modified = $f.LastWriteTime.ToString('dd MMM yyyy HH:mm')
            $d.IsKeeper = ($f.FullName -eq $r.Keeper)
            $d.IsSelected = -not $d.IsKeeper
            $d.add_PropertyChanged({ Update-Summary })
            $g.Files.Add($d)
        }
        $groups.Add($g)
    }
    $ui.ChkAck.IsChecked = $false
    $ui.EmptyState.Visibility = if ($groups.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    if (($groups.Count -eq 0) -and $ui.ScanDone) { $ui.ScanDone.Visibility = 'Collapsed' }
    if ($groups.Count -eq 0) {
        $ui.EmptyTitle.Text = 'No duplicates found'
        $ui.EmptyHint.Text = 'Nothing in that folder is an exact copy of anything else. Try a bigger folder, or lower the size filter.'
    }
    Update-Summary

    # A gentle reveal once the results are in: the numbers count up, the strip and
    # list ease in, and a tick draws itself. Nothing here changes what is shown.
    if ($groups.Count -gt 0) {
        $revealBytes = [long]0
        foreach ($g in $groups) {
            foreach ($f in $g.Files) { if (-not $f.IsKeeper) { $revealBytes += $f.Size } }
        }
        $revealFiles = 0
        foreach ($g in $groups) { $revealFiles += ($g.Files.Count - 1) }
        Invoke-DRScanReveal -Sets $groups.Count -Files $revealFiles -Bytes $revealBytes
    }
}

# Counts the three headline numbers up from zero, eases the summary strip and the
# results list into view, then draws the 'Scan complete' tick with a small bounce.
function Invoke-DRScanReveal {
    param([int]$Sets, [int]$Files, [long]$Bytes)
    if (-not $ui.StatStrip) { return }
  try {
    Add-Type -AssemblyName PresentationCore | Out-Null
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'

    # Fade + slide the summary strip and the results list.
    foreach ($el in @($ui.StatStrip, $ui.GroupList)) {
        if (-not $el) { continue }
        $tt = New-Object System.Windows.Media.TranslateTransform
        $tt.Y = 18
        $el.RenderTransform = $tt
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, ([Windows.Duration]([TimeSpan]::FromMilliseconds(450))))
        $slide = New-Object System.Windows.Media.Animation.DoubleAnimation(18, 0, ([Windows.Duration]([TimeSpan]::FromMilliseconds(600))))
        $slide.EasingFunction = $ease
        $fade.EasingFunction = $ease
        $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
    }

    # Count the three numbers up from zero (Text is not a double, so drive it by timer).
    # Values are captured into the tick via GetNewClosure so the built (StrictMode)
    # exe never trips over an unset script-scope variable.
    $revealStart = [DateTime]::Now
    $rSets = [int]$Sets
    $rFiles = [int]$Files
    $rBytes = [long]$Bytes
    $countTimer = New-Object System.Windows.Threading.DispatcherTimer
    $countTimer.Interval = [TimeSpan]::FromMilliseconds(16)
    $countTimer.Add_Tick({
            $t = ([DateTime]::Now - $revealStart).TotalMilliseconds / 1200
            if ($t -ge 1) { $t = 1 }
            $e = 1 - [math]::Pow(1 - $t, 3)
            $ui.StatSets.Text = [string][int][math]::Round($rSets * $e)
            $ui.StatFiles.Text = [string][int][math]::Round($rFiles * $e)
            $ui.StatSpace.Text = Format-Size ([long][math]::Round($rBytes * $e))
            if ($t -ge 1) { $this.Stop() }
        }.GetNewClosure())
    $countTimer.Start()

    # The 'Scan complete' tick: fade the badge in, draw the tick, then a soft bounce.
    if ($ui.ScanDone) {
        $s = if ($Sets -ne 1) { 's' } else { '' }
        $ui.ScanDoneSub.Text = "$(Format-Size $Bytes) can be reclaimed across $Sets set$s."
        $ui.ScanDone.Visibility = 'Visible'

        $badgeFade = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, ([Windows.Duration]([TimeSpan]::FromMilliseconds(260))))
        $badgeFade.EasingFunction = $ease
        $ui.ScanDone.BeginAnimation([Windows.UIElement]::OpacityProperty, $badgeFade)

        $draw = New-Object System.Windows.Media.Animation.DoubleAnimation(9, 0, ([Windows.Duration]([TimeSpan]::FromMilliseconds(340))))
        $draw.BeginTime = [TimeSpan]::FromMilliseconds(220)
        $draw.EasingFunction = $ease
        $ui.ScanDoneTick.BeginAnimation([System.Windows.Shapes.Shape]::StrokeDashOffsetProperty, $draw)

        $bounce = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $bk = New-Object System.Windows.Media.Animation.CubicEase; $bk.EasingMode = 'EaseOut'
        $bounce.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.0, ([Windows.Media.Animation.KeyTime][TimeSpan]::FromMilliseconds(520)))))
        $bounce.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.05, ([Windows.Media.Animation.KeyTime][TimeSpan]::FromMilliseconds(640)), $bk)))
        $bounce.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.0, ([Windows.Media.Animation.KeyTime][TimeSpan]::FromMilliseconds(760)), $bk)))
        $ui.ScanDoneScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $bounce)
        $ui.ScanDoneScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $bounce.Clone())
    }
  } catch { }
}

$timer.Add_Tick({
        if ($state.ContainsKey('Status')) {
            $ui.LblSummary.Text = [string]$state['Status']
            # Say the same thing next to the spinner, where they are looking.
            try { $ui.ScanBusyHint.Text = [string]$state['Status'] } catch { }
        }
        if ($state.ContainsKey('Total') -and [int]$state['Total'] -gt 0) {
            $ui.Bar.IsIndeterminate = $false
            $ui.Bar.Maximum = [int]$state['Total']
            $ui.Bar.Value = [int]$state['Progress']
        } else {
            $ui.Bar.IsIndeterminate = $true
        }

        if (-not $state['Done']) { return }

        $timer.Stop()
        try { $script:ps.EndInvoke($script:handle) } catch { }
        try { $script:ps.Dispose(); $script:runspace.Close() } catch { }

        Set-Busy $false
        $ui.Bar.Visibility = 'Collapsed'

        if ($state.ContainsKey('Error') -and $state['Error']) {
            $ui.LblSummary.Text = "Scan failed: $($state['Error'])"
            return
        }
        if ($state['Cancel']) {
            $ui.LblSummary.Text = 'Scan stopped.'
            if ($ui.StatStrip) { $ui.StatStrip.Visibility = 'Collapsed' }
            if ($ui.ScanDone) { $ui.ScanDone.Visibility = 'Collapsed' }
            return
        }
        Show-Results $state['Results']

        # Say plainly what was left out of the comparison, and why.
        $cloud = [int]$state['CloudSkipped']
        if ($cloud -gt 0) {
            $ui.CloudNote.Visibility = 'Visible'
            if (@(Get-TickedCloudRoots).Count -gt 0) {
                $ui.CloudNoteText.Text = "$cloud cloud files were included in this scan. Any that were online-only had to be downloaded to be compared."
            } else {
                $ui.CloudNoteText.Text = "$cloud cloud files were skipped - they are not stored on this PC, so checking them would download every one. Tick 'Include OneDrive / Google Drive / iCloud files' above to compare them anyway."
            }
        }
    })

# The Open file / Show in folder buttons live inside a template, so catch their
# clicks as they bubble up and use the row they came from.
$ui.GroupList.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler] {
        param($sender, $e)
        $btn = $e.OriginalSource -as [System.Windows.Controls.Button]
        if (-not $btn) { return }
        $row = $btn.DataContext -as [DRD.DupFile]
        if (-not $row) { return }
        switch ([string]$btn.Tag) {
            'view' { Open-Selected -Path $row.FullPath }
            'folder' { Open-Selected -Path $row.FullPath -InFolder }
        }
    })

function Get-ChosenExts {
    # Empty set = no filtering at all, which is what "Everything" means.
    $set = New-Object System.Collections.Generic.HashSet[string]
    if ($ui.ChipAll.IsChecked) { return , $set }
    $map = @{ ChipPic = 'Pic'; ChipVid = 'Vid'; ChipAud = 'Aud'; ChipDoc = 'Doc'; ChipArc = 'Arc' }
    foreach ($name in $map.Keys) {
        if ($ui[$name].IsChecked) {
            foreach ($e in $TypeSets[$map[$name]]) { [void]$set.Add($e) }
        }
    }
    return , $set
}

$script:ChipLock = $false

function Update-Chips {
    # Reads back what is ticked and says what it means for the scan.
    if ($script:ChipLock) { return }
    $picked = @(@('ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc', 'ChipArc') |
        Where-Object { $ui[$_].IsChecked })

    if ($ui.ChipAll.IsChecked -or $picked.Count -eq 0) {
        $script:ChipLock = $true
        $ui.ChipAll.IsChecked = $true
        foreach ($c in 'ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc', 'ChipArc') { $ui[$c].IsChecked = $false }
        $script:ChipLock = $false
        $ui.LblChips.Text = 'every file type - the most thorough, and the slowest'
    } else {
        $count = (Get-ChosenExts).Count
        $ui.LblChips.Text = "$count file types - much faster than scanning everything"
    }
}

foreach ($chip in 'ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc', 'ChipArc') {
    # Picking a type turns off Everything.
    $ui[$chip].Add_Checked({
            if ($script:ChipLock) { return }
            $script:ChipLock = $true
            $ui.ChipAll.IsChecked = $false
            $script:ChipLock = $false
            Update-Chips
        })
    $ui[$chip].Add_Unchecked({ Update-Chips })
}

$ui.ChipAll.Add_Checked({ Update-Chips })
$ui.ChipAll.Add_Unchecked({ Update-Chips })
$ui.ChipAll.IsChecked = $true
Update-Chips

# A trial looks through one category, not everything. Once a category has been
# scanned it stays fixed, so closing and reopening does not hand out another.
$script:DRTrial = [bool]$TrialMode
if (-not $script:DRTrial -and $script:DRUpdaterLoaded) {
    try { $script:DRTrial = Test-DRTrialMode } catch { $script:DRTrial = $false }
}
if ($script:DRTrial) {
    $ui.TrialBadge.Visibility = 'Visible'
    $script:ChipLock = $true
    $ui.ChipAll.IsChecked = $false
    $ui.ChipAll.IsEnabled = $false
    $ui.ChipAll.Opacity = 0.4

    $taken = Get-DRTrialValue 'category'
    $map = @{ Pic = 'ChipPic'; Vid = 'ChipVid'; Aud = 'ChipAud'; Doc = 'ChipDoc'; Arc = 'ChipArc' }
    foreach ($c in 'ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc', 'ChipArc') { $ui[$c].IsChecked = $false }

    if ($taken -and $map.ContainsKey($taken)) {
        # Already chosen on an earlier run - lock to it.
        $ui[$map[$taken]].IsChecked = $true
        foreach ($c in 'ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc', 'ChipArc') {
            if ($c -ne $map[$taken]) { $ui[$c].IsEnabled = $false; $ui[$c].Opacity = 0.4 }
        }
        $ui.LblChips.Text = 'Free try - you picked this category already.'
    } else {
        $ui[$map['Pic']].IsChecked = $true
        $ui.LblChips.Text = 'Free try - pick one category, then press Scan.'
    }
    $script:ChipLock = $false

    # Only one may be ticked at a time while on trial.
    foreach ($chip in 'ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc', 'ChipArc') {
        $ui[$chip].Add_Checked({
                if ($script:ChipLock) { return }
                $script:ChipLock = $true
                $chosen = $this.Name
                foreach ($c in 'ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc', 'ChipArc') {
                    if ($c -ne $chosen) { $ui[$c].IsChecked = $false }
                }
                $script:ChipLock = $false
            })
    }

    # Reaching for a second category is the try running out.
    foreach ($chip in 'ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc', 'ChipArc') {
        $ui[$chip].Add_MouseDoubleClick({ })
    }
    $ui.ChipAll.Add_MouseLeftButtonDown({
            if ($script:DRTrial) {
                $_.Handled = $true
                if ((Show-DRActivation 'expired' 'Duplicate Finder') -eq 'activated') {
                    $ui.LblChips.Text = 'Activated. Reopen the Duplicate Finder to use every category.'
                }
            }
        })
}

# Trial countdown: the same "X days left" the Cleaner shows, in the badge here.
# A timed trial with full access still counts down, so this runs whether or not
# this session is a limited free try.
try {
    $left = if ($script:DRUpdaterLoaded) { Get-DRDaysLeft } else { $null }
    if ($null -ne $left -and $left -ge 0 -and $left -le 21) {
        $ui.TrialBadgeText.Text =
            if     ($left -eq 0) { 'TRIAL ENDS TODAY' }
            elseif ($left -eq 1) { 'TRIAL - 1 DAY LEFT' }
            else                 { "TRIAL - $left DAYS LEFT" }
        $ui.TrialBadge.Visibility = 'Visible'
    }
} catch { }

$ui.ChkAck.Add_Checked({ Update-Summary })
$ui.ChkAck.Add_Unchecked({ Update-Summary })

# Activated copies grey the button out; a copy waiting for a code pulses blue,
# because that is the one moment someone needs to find it.
function Update-DRActivateLook {
    try {
        $needs = $false
        if ($script:DRUpdaterLoaded) { $needs = Test-DRNeedsActivation }
        if ($needs) {
            $ui.BtnActivate.IsEnabled = $true
            $ui.BtnActivate.Opacity = 1
            $ui.BtnActivate.ToolTip = 'Enter the code DRDirect sent you.'
            $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x1D,0x4E,0xD8))
            $ui.BtnActivate.Background = $brush
            $ui.BtnActivate.Foreground = [Windows.Media.Brushes]::White
            $blink = New-Object Windows.Media.Animation.ColorAnimation
            $blink.From = [Windows.Media.Color]::FromRgb(0x1D,0x4E,0xD8)
            $blink.To   = [Windows.Media.Color]::FromRgb(0x9D,0xC2,0xFF)
            $blink.Duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(750))
            $blink.AutoReverse = $true
            $blink.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $brush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $blink)
        } else {
            # Left readable and clickable. This is where someone goes to hand
            # over a code before their licence lapses, so hiding it until the
            # copy has already expired is exactly the wrong way round. It says
            # "nothing to do" when pressed, which is an answer, not a dead end.
            $ui.BtnActivate.IsEnabled = $true
            $ui.BtnActivate.Opacity = 1
            $ui.BtnActivate.ToolTip = 'This copy is activated. Enter a new code here to extend it.'
            try {
                $ui.BtnActivate.ClearValue([Windows.Controls.Control]::BackgroundProperty)
                $ui.BtnActivate.ClearValue([Windows.Controls.Control]::ForegroundProperty)
            } catch { }
        }
    } catch { }
}

$ui.BtnBack.Add_Click({
    # Brings the Cleaner's window forward, then steps aside (its Open Duplicate Finder button brings this one back).
    try {
        if (-not ('DRBackToCleaner' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DRBackToCleaner {
    private delegate bool EnumProc(IntPtr window, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int max);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);

    // The Cleaner's main window is found by its exact title, whatever its rights; a minimised one counts too.
    public static IntPtr Find(string title, uint ownProcess) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr window, IntPtr lParam) {
            if (!IsWindowVisible(window)) return true;
            StringBuilder text = new StringBuilder(256);
            GetWindowText(window, text, text.Capacity);
            if (text.ToString() != title) return true;
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId == ownProcess) return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@
        }
        $cleaner = [DRBackToCleaner]::Find('DRDirect PC Cleaner', [uint32]$PID)
        if ($cleaner -ne [IntPtr]::Zero) {
            if ([DRBackToCleaner]::IsIconic($cleaner)) { [void][DRBackToCleaner]::ShowWindow($cleaner, 9) }
            [void][DRBackToCleaner]::SetForegroundWindow($cleaner)
            # Close rather than hide: on a less powerful PC the Cleaner only allows a few tools open at once,
            # and a hidden Duplicate Finder would still count. The Cleaner's button opens it again.
            $win = [System.Windows.Window]::GetWindow($ui.BtnBack)
            if ($script:handle -and -not $script:handle.IsCompleted) {
                $answer = [DRDirect.MsgBox]::Show($win, ('A search is still running.' + [Environment]::NewLine + [Environment]::NewLine +
                    'Stop it and close the Duplicate Finder? (No = keep it running in the background)'), 'DRDirect Duplicate Finder', 'YesNo', 'Question')
                if ($answer -ne 'Yes') { try { $win.WindowState = [System.Windows.WindowState]::Minimized } catch { }; return }
                try { $script:ps.Stop() } catch { }
            }
            try { $win.Close() } catch { }
            return
        }
    } catch {
        [DRDirect.MsgBox]::Show("Could not switch to the Cleaner: $($_.Exception.Message)",
            'DRDirect Duplicate Finder', 'OK', 'Information') | Out-Null
        return
    }
    # The Cleaner is closed: start it again from where the Cleaner last said it lives.
    try {
        $cleanerExe = [string](Get-ItemProperty -LiteralPath 'HKCU:\Software\DRDirect\PC Cleaner' -Name 'CleanerExe' -ErrorAction Stop).CleanerExe
        if ($cleanerExe -and (Test-Path -LiteralPath $cleanerExe -PathType Leaf)) {
            # A PyInstaller copy started from inside another one takes itself for its child and fails its parent check.
            $env:PYINSTALLER_RESET_ENVIRONMENT = '1'
            # Through Explorer, so the Cleaner asks for administrator rights itself rather than inheriting this window's.
            Start-Process -FilePath 'explorer.exe' -ArgumentList $cleanerExe | Out-Null
            $ui.LblSummary.Text = 'Opening the Cleaner...'
            if (-not ($script:handle -and -not $script:handle.IsCompleted)) {
                try { [System.Windows.Window]::GetWindow($ui.BtnBack).Close() } catch { }
            }
            return
        }
    } catch { }
    [DRDirect.MsgBox]::Show('The DRDirect Cleaner is not open. Open it from its shortcut.',
        'DRDirect Duplicate Finder', 'OK', 'Information') | Out-Null
})

$ui.BtnActivate.Add_Click({
    # Always available, so a code can be handed over before anything expires.
    if (-not $script:DRUpdaterLoaded) {
        $ui.LblSummary.Text = 'Activation is not available in this copy.'
        return
    }
    # Nothing to activate? Say so, rather than showing an end-of-licence notice
    # to someone whose licence is perfectly good.
    try {
        if (-not (Test-DRNeedsActivation)) {
            [DRDirect.MsgBox]::Show('This copy is activated. Nothing to do.',
                'DRDirect Duplicate Finder', 'OK', 'Information') | Out-Null
            Update-DRActivateLook
            return
        }
    } catch { }

    if ((Show-DRActivation 'expired' 'Duplicate Finder') -eq 'activated') {
        $ui.LblSummary.Text = 'Activated. Close and reopen the Duplicate Finder.'
        Update-DRActivateLook
    }
})

$ui.BtnUpdate.Add_Click({
    # Same here: Update doubles as the place to enter an activation code.
    if ($script:DRUpdaterLoaded) {
        try {
            if (Test-DRNeedsActivation) {
                if ((Show-DRActivation 'expired' 'Duplicate Finder') -eq 'activated') {
                    $ui.LblSummary.Text = 'Activated. Reopen the Duplicate Finder to use every category.'
                }
                return
            }
        } catch { }
    }

    if (-not $script:DRUpdaterLoaded) {
        $ui.LblSummary.Text = 'Updates are not available in this copy.'
        return
    }

    $ui.BtnUpdate.IsEnabled = $false
    $original = $ui.LblSummary.Text
    $ui.LblSummary.Text = 'Checking for updates...'
    try {
        $check = Test-DRUpdateAvailable
        if (-not $check.Available) {
            $ui.LblSummary.Text = $check.Message
            Show-DRSummaryFlash
            # The summary line already tends to say this, so pressing the button
            # looked like it did nothing. Answer where the person is looking.
            [DRDirect.MsgBox]::Show($check.Message, 'DRDirect Duplicate Finder',
                [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
            return
        }

        $answer = [DRDirect.MsgBox]::Show(
            ($check.Message + [Environment]::NewLine + [Environment]::NewLine + 'Download and install it now?'),
            'DRDirect Duplicate Finder',
            [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) {
            $ui.LblSummary.Text = $original
            return
        }

        $result = Install-DRUpdate -Manifest $check.Manifest
        if ($result.Success) {
            # This window is running the old script, so the new one starts
            # being used the next time the Duplicate Finder is opened.
            $ui.LblSummary.Text = "Updated to $($result.Version). Close and reopen this window to use it."
        } else {
            $ui.LblSummary.Text = $result.Message
        }
    }
    catch { $ui.LblSummary.Text = "Could not check for updates: $($_.Exception.Message)" }
    finally { $ui.BtnUpdate.IsEnabled = $true }
})

$ui.BtnBrowse.Add_Click({
        $picked = Show-FolderPicker -Start $ui.TxtFolder.Text
        if ($picked) { $ui.TxtFolder.Text = $picked }
    })

$ui.BtnScan.Add_Click({
        # The first trial scan fixes which category the free try covers.
        if ($script:DRTrial -and -not (Get-DRTrialValue 'category')) {
            $chosen = @('ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc', 'ChipArc') |
                Where-Object { $ui[$_].IsChecked } | Select-Object -First 1
            if ($chosen) {
                $short = @{ ChipPic = 'Pic'; ChipVid = 'Vid'; ChipAud = 'Aud'
                            ChipDoc = 'Doc'; ChipArc = 'Arc' }[$chosen]
                Set-DRTrialValue 'category' $short
                foreach ($c in 'ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc', 'ChipArc') {
                    if ($c -ne $chosen) { $ui[$c].IsEnabled = $false; $ui[$c].Opacity = 0.4 }
                }
                $ui.LblChips.Text = 'Free try - this is the category you picked.'
            }
        }

        $root = $ui.TxtFolder.Text.Trim()
        if ($root -and -not (Test-Path -LiteralPath $root)) {
            [DRDirect.MsgBox]::Show("That folder does not exist:`n$root", 'Duplicate Finder',
                'OK', 'Warning') | Out-Null
            return
        }
        $scanRoots = @(Get-DRScanRoots -Folder $root)
        if ($scanRoots.Count -eq 0) {
            [DRDirect.MsgBox]::Show('Choose a folder, or tick a cloud service or a drive to scan.', 'Duplicate Finder',
                'OK', 'Information') | Out-Null
            return
        }

        $groups.Clear()
        $ui.EmptyState.Visibility = 'Collapsed'
        $ui.SavedPanel.Visibility = 'Collapsed'
        $ui.CloudNote.Visibility = 'Collapsed'
        $state.Clear()
        $state['Cancel'] = $false
        $state['Done'] = $false
        $state['Progress'] = 0
        $state['Total'] = 0
        $state['Status'] = 'Starting...'

        Set-Busy $true
        $ui.Bar.IsIndeterminate = $true

        $script:runspace = [runspacefactory]::CreateRunspace()
        $script:runspace.ApartmentState = 'MTA'
        $script:runspace.ThreadOptions = 'ReuseThread'
        $script:runspace.Open()
        $script:ps = [powershell]::Create()
        $script:ps.Runspace = $script:runspace
        $null = $script:ps.AddScript($ScanScript).
            AddArgument($scanRoots).
            AddArgument([long](Get-MinBytes)).
            AddArgument([bool]$ui.ChkSub.IsChecked).
            AddArgument((Get-TickedCloudRoots)).
            AddArgument((Get-ChosenExts)).
            AddArgument($state)
        $script:handle = $script:ps.BeginInvoke()
        $timer.Start()
    })

$ui.BtnCancel.Add_Click({
        $state['Cancel'] = $true
        $ui.LblSummary.Text = 'Stopping...'
    })

$ui.BtnNone.Add_Click({
        foreach ($g in $groups) {
            foreach ($f in $g.Files) { if (-not $f.IsKeeper) { $f.IsSelected = $false } }
        }
        Update-Summary
    })

$ui.BtnDelete.Add_Click({
        $targets = New-Object System.Collections.Generic.List[object]
        foreach ($g in $groups) {
            foreach ($f in $g.Files) {
                if ((-not $f.IsKeeper) -and $f.IsSelected -and (-not $f.IsRemoved)) { $targets.Add($f) }
            }
        }
        if ($targets.Count -eq 0) { return }

        $bytes = 0L
        foreach ($t in $targets) { $bytes += $t.Size }
        $nl = [Environment]::NewLine
        # Show exactly which paths are going, so the confirmation is informed.
        # @() matters: one ticked file gives a bare object, and .Count on it throws.
        $shown = @($targets | Select-Object -First 15)
        $list = ($shown | ForEach-Object { '  ' + $_.FullPath }) -join $nl
        if ($targets.Count -gt $shown.Count) {
            $list += $nl + "  ...and $($targets.Count - $shown.Count) more"
        }

        $msg = "These $($targets.Count) files will be moved to the Recycle Bin:" + $nl + $nl +
        $list + $nl + $nl +
        "Frees $(Format-Size $bytes)." + $nl +
        'One copy of every file is kept - the green KEEP row is never touched.' + $nl +
        'They go to the Recycle Bin, so you can restore any of them.'

        $answer = [DRDirect.MsgBox]::Show($msg, 'Confirm removal', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }

        $ok = 0; $failed = 0; $blocked = 0
        foreach ($t in $targets) {
            if (Test-ProtectedPath $t.FullPath) {
                $t.RowNote = 'Skipped - Windows or program file, not safe to remove'
                $t.IsSelected = $false
                $blocked++
                continue
            }
            try {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $t.FullPath,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
                $t.IsRemoved = $true
                $t.IsSelected = $false
                $ok++
            } catch {
                $t.RowNote = "Could not remove: $($_.Exception.Message)"
                $failed++
            }
        }

        $ui.ChkAck.IsChecked = $false
        Update-Summary

        # Only count what actually went.
        $freed = 0L
        foreach ($t in $targets) { if ($t.IsRemoved) { $freed += $t.Size } }
        if ($ok -gt 0) { Show-Saved -Bytes $freed -Count $ok }

        $tail = if ($failed -gt 0) { "  -  $failed could not be removed (in use or protected)" } else { '' }
        if ($blocked -gt 0) { $tail += "  -  $blocked skipped as Windows or program files" }
        $ui.LblSummary.Text = "Moved $ok duplicates to the Recycle Bin, freeing $(Format-Size $freed)$tail"
    })

$win.Add_Closed({
        $state['Cancel'] = $true
        try { $timer.Stop() } catch { }
    })

if ($TestMode) {
    Write-Host 'TestMode: window built OK.'
    $null = Show-FolderPicker -Start ([Environment]::GetFolderPath('UserProfile')) -BuildOnly
    # exercise the chip handlers the way a click does
    $ui.ChipPic.IsChecked = $true
    Write-Host "TestMode: pictures only -> $($ui.LblChips.Text) [$((Get-ChosenExts).Count) exts]"
    $ui.ChipVid.IsChecked = $true
    Write-Host "TestMode: + videos      -> $((Get-ChosenExts).Count) exts"
    $ui.ChipPic.IsChecked = $false
    $ui.ChipVid.IsChecked = $false
    Write-Host "TestMode: none ticked   -> all=$($ui.ChipAll.IsChecked) [$((Get-ChosenExts).Count) exts]"
    Initialize-DRCloudBoxes
    Initialize-DRDriveBoxes
    Write-Host "TestMode: drive boxes   -> $(($script:DRDriveBoxes | ForEach-Object { $_.Content }) -join ', ')"
    if ($script:DRDriveBoxes.Count -gt 0) { $script:DRDriveBoxes[0].IsChecked = $true }
    Write-Host "TestMode: scan roots    -> $((Get-DRScanRoots -Folder $env:USERPROFILE) -join ' | ')"
    if ($script:DRDriveBoxes.Count -gt 0) { $script:DRDriveBoxes[0].IsChecked = $false }
    Update-DRActivateLook
    if (-not $NoShow) {
        try {
            $null = $win.ShowDialog()
        } catch {
            # Say where it broke. "An error occurred" tells nobody anything, and
            # this window runs on machines we cannot poke at.
            $detail = "$($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)"
            try {
                $log = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Logs\DuplicateFinder_Error.log'
                New-Item -Path (Split-Path -Parent $log) -ItemType Directory -Force | Out-Null
                Add-Content -LiteralPath $log -Value ("[{0}] {1}" -f (Get-Date), $detail)
            } catch { }
            [DRDirect.MsgBox]::Show($detail, 'DRDirect Duplicate Finder', 'OK', 'Error') | Out-Null
        }
    }
    return
}

# Work out which cloud services are signed in before the window is shown, so the
# tick boxes are already right the first time anyone looks at them.
# Which version is running should never be a question.
try {
    $shown = if ($script:DRUpdaterLoaded) { Get-DRInstalledVersion } else { $null }
    # <BUILD-VERSION>
    $script:DRBuildVersion = ''
    # </BUILD-VERSION>
    # The version the update system recorded wins, because it is the one
    # actually running. A copy that has never updated falls back to the
    # number stamped in at build time, so the label is never a guess.
    $ui.VersionText.Text = if ($shown -and "$shown" -ne '0.0.0') { "Version $shown" }
    # The DRDirect logo beside the version, the same one the Cleaner shows.
    try {
        $drLogoBytes = [Convert]::FromBase64String('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')
        $drLogoStream = New-Object System.IO.MemoryStream (, $drLogoBytes)
        $drLogoBmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $drLogoBmp.BeginInit()
        $drLogoBmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $drLogoBmp.StreamSource = $drLogoStream
        $drLogoBmp.EndInit()
        $drLogoBmp.Freeze()
        $ui.DRLogo.Source = $drLogoBmp
    } catch { }
                           elseif ($script:DRBuildVersion) { "Version $script:DRBuildVersion" }
                           else { 'Version 1.0' }
} catch { }

# List the Duplicate Finder in Windows' installed programs, with the same version
# as the label above. The shared code is in the updater.
if (-not $TestMode -and (Get-Command Register-DRInstalledProduct -ErrorAction SilentlyContinue)) {
    try {
        $listedVersion = ($ui.VersionText.Text -replace '^Version\s+', '').Trim()
        Register-DRInstalledProduct -Product 'Duplicate Finder' -Version $listedVersion
    } catch { }
}

try { Initialize-DRCloudBoxes } catch { }
try { Initialize-DRDriveBoxes } catch { }

$null = $win.ShowDialog()
