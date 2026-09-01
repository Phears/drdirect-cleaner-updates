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
    [switch]$NoShow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The updater is a shared file rather than a copy of the same code, so the
# Cleaner and this window always agree on what counts as a newer version.
$script:DRUpdaterLoaded = $false
foreach ($updaterRoot in @(
        (Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Scripts'),
        $PSScriptRoot)) {
    if ([string]::IsNullOrWhiteSpace($updaterRoot)) { continue }
    $updaterPath = Join-Path $updaterRoot 'DRDirect Updater.ps1'
    if (Test-Path -LiteralPath $updaterPath -PathType Leaf) {
        try { . $updaterPath; $script:DRUpdaterLoaded = $true; break } catch { }
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

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

function Test-ProtectedPath {
    # Same rule as the scanner, enforced again at the point of deletion so a
    # Windows-owned file can never be removed even if it reaches the list.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
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
        '$WinREAgent', 'WpSystem', 'Package Cache', 'WindowsApps'
    )
    foreach ($seg in $appFolders) {
        if ($full -like "*\$seg\*") { return $true }
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

$ScanScript = {
    param($Roots, $MinBytes, $IncludeSub, $IncludeCloud, $Exts, $State)

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

    function Test-ProtectedPath {
        # Windows-owned locations. Files here are not the user's to remove, and the
        # component store (WinSxS) in particular backs Windows servicing - deleting
        # from it can break Windows Update even when the bytes match a user file.
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
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
            '$WinREAgent', 'WpSystem', 'Package Cache', 'WindowsApps'
        )
        foreach ($seg in $appFolders) {
            if ($full -like "*\$seg\*") { return $true }
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
                            if (-not $IncludeCloud) { continue }
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
        Title="DRDirect Duplicate Finder" Width="1180" Height="800"
        MinWidth="900" MinHeight="600" WindowState="Maximized"
        WindowStartupLocation="CenterScreen" Background="#F4F7FC"
        FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Ideal">
  <Window.Resources>
    <!-- Every button lifts on hover and presses in on click. -->
    <Style x:Key="Btn" TargetType="Button">
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

              <Border x:Name="shade" CornerRadius="6" Background="Black" Opacity="0"
                      Margin="0,2,0,-2" IsHitTestVisible="False"/>
              <Border x:Name="b" CornerRadius="6" Background="{TemplateBinding Background}"
                      Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
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
    <Style x:Key="Chip" TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Grid RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform x:Name="csc" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
              <Border x:Name="cb" CornerRadius="16" Background="White" BorderBrush="#C9D4E6"
                      BorderThickness="1.5" Padding="14,7">
                <ContentPresenter VerticalAlignment="Center"/>
              </Border>
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
          <GradientStop Color="#152C6B" Offset="0"/>
          <GradientStop Color="#2563EB" Offset="0.5"/>
          <GradientStop Color="#1B3FA8" Offset="1"/>
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
            <Border Width="40" Height="50" CornerRadius="5" Background="#8FB2FF"
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
            <TextBlock Text="DUPLICATE FINDER" Foreground="White" FontSize="40" FontWeight="Bold"/>
            <TextBlock Foreground="#CBDCFF" FontSize="15" Margin="0,2,0,0"
                       Text="Only files that are 100% identical. One copy is always kept."/>
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
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="Folder" VerticalAlignment="Center"
                     FontWeight="SemiBold" Foreground="#344054" Margin="0,0,10,0"/>
          <TextBox x:Name="TxtFolder" Grid.Column="1" Padding="8,7" VerticalContentAlignment="Center"
                   BorderBrush="#C9D4E6" Background="#FBFCFE"/>
          <Button x:Name="BtnBrowse" Grid.Column="2" Content="Browse" Style="{StaticResource GhostBtn}" Margin="10,0,0,0"/>
          <Button x:Name="BtnScan"   Grid.Column="3" Content="Scan for duplicates" Style="{StaticResource Btn}" Margin="10,0,0,0"/>
          <Button x:Name="BtnCancel" Grid.Column="4" Content="Stop" Style="{StaticResource GhostBtn}" Margin="10,0,0,0" Visibility="Collapsed"/>
          <Button x:Name="BtnUpdate" Grid.Column="5" Content="Check for updates" Style="{StaticResource GhostBtn}" Margin="10,0,0,0"/>
        </Grid>
        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
          <CheckBox x:Name="ChkSub" Content="Include subfolders" IsChecked="True" VerticalAlignment="Center" Foreground="#344054"/>
          <TextBlock Text="Ignore files smaller than" VerticalAlignment="Center" Margin="24,0,8,0" Foreground="#344054"/>
          <ComboBox x:Name="CmbMin" Width="120" VerticalContentAlignment="Center" SelectedIndex="1">
            <ComboBoxItem Content="1 KB"/>
            <ComboBoxItem Content="100 KB"/>
            <ComboBoxItem Content="1 MB"/>
            <ComboBoxItem Content="10 MB"/>
          </ComboBox>
          <CheckBox x:Name="ChkCloud" VerticalAlignment="Center" Margin="24,0,0,0" Foreground="#96500A"
                    Content="Include OneDrive / cloud files"
                    ToolTip="Off by default. Online-only files are not stored on this PC, so checking them forces OneDrive to download every one."/>
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

          <Border x:Name="EmptyState" Background="White" CornerRadius="10" BorderBrush="#DEE5F0"
                  BorderThickness="1" Padding="40" Margin="0,40,0,0">
            <StackPanel HorizontalAlignment="Center">
              <TextBlock x:Name="EmptyTitle" Text="No scan yet" FontSize="20" FontWeight="SemiBold"
                         Foreground="#344054" HorizontalAlignment="Center"/>
              <TextBlock x:Name="EmptyHint" Margin="0,8,0,0" Foreground="#667085" TextAlignment="Center"
                         Text="Pick a folder and press Scan. Every match is proved byte-for-byte before it is shown."/>
            </StackPanel>
          </Border>

          <ItemsControl x:Name="GroupList">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <Border Background="White" CornerRadius="10" BorderBrush="#F0B4B4" BorderThickness="2"
                        Margin="0,0,0,16">
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
        <StackPanel Grid.Column="0" VerticalAlignment="Center">
          <TextBlock x:Name="LblSummary" Text="Ready." FontWeight="SemiBold" Foreground="#1D2939"/>
          <ProgressBar x:Name="Bar" Height="6" Margin="0,8,16,0" Visibility="Collapsed"
                       Foreground="#2563EB" Background="#E3E8F0" BorderThickness="0"/>
        </StackPanel>
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
$win = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
foreach ($n in 'TxtFolder', 'BtnBrowse', 'BtnScan', 'BtnCancel', 'BtnUpdate', 'ChkSub', 'CmbMin', 'GroupList',
    'EmptyState', 'EmptyTitle', 'EmptyHint', 'LblSummary', 'Bar', 'BtnNone', 'BtnDelete', 'Scroller',
    'AckBox', 'ChkAck', 'ChkCloud', 'ChipAll', 'ChipPic', 'ChipVid', 'ChipAud', 'ChipDoc',
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
            [System.Windows.MessageBox]::Show('That file is no longer there.', 'Duplicate Finder', 'OK', 'Information') | Out-Null
            return
        }
        if ($InFolder) {
            Start-Process explorer.exe -ArgumentList "/select,`"$Path`""
        } else {
            Start-Process -FilePath $Path
        }
    } catch {
        [System.Windows.MessageBox]::Show("Could not open that file:`n$($_.Exception.Message)",
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
        WindowStartupLocation="CenterOwner" Background="#F4F7FC"
        FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Ideal">
  <Window.Resources>
    <Style x:Key="PBtn" TargetType="Button">
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
    <Style x:Key="PlaceBtn" TargetType="Button">
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
          <GradientStop Color="#152C6B" Offset="0"/>
          <GradientStop Color="#2563EB" Offset="0.5"/>
          <GradientStop Color="#1B3FA8" Offset="1"/>
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
    if ($env:OneDrive -and (Test-Path -LiteralPath $env:OneDrive)) {
        $places += @{ Icon = [char]0xE753; Name = 'OneDrive'; Path = $env:OneDrive }
    }

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
    $ui.AckBox.Visibility = if ($dupCount -gt 0) { 'Visible' } else { 'Collapsed' }
    # Nothing is removed until you have seen the files and ticked the acknowledgement.
    $ui.BtnDelete.IsEnabled = ($dupCount -gt 0) -and ($ui.ChkAck.IsChecked -eq $true)
}

function Get-MinBytes {
    switch ($ui.CmbMin.SelectedIndex) {
        0 { 1KB }
        1 { 100KB }
        2 { 1MB }
        3 { 10MB }
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
    if ($groups.Count -eq 0) {
        $ui.EmptyTitle.Text = 'No duplicates found'
        $ui.EmptyHint.Text = 'Nothing in that folder is an exact copy of anything else. Try a bigger folder, or lower the size filter.'
    }
    Update-Summary
}

$timer.Add_Tick({
        if ($state.ContainsKey('Status')) { $ui.LblSummary.Text = [string]$state['Status'] }
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
            return
        }
        Show-Results $state['Results']

        # Say plainly what was left out of the comparison, and why.
        $cloud = [int]$state['CloudSkipped']
        if ($cloud -gt 0) {
            $ui.CloudNote.Visibility = 'Visible'
            if ($ui.ChkCloud.IsChecked) {
                $ui.CloudNoteText.Text = "$cloud OneDrive / cloud files were included in this scan. Any that were online-only had to be downloaded to be compared."
            } else {
                $ui.CloudNoteText.Text = "$cloud OneDrive / cloud files were skipped - they are not stored on this PC, so checking them would download every one. Tick 'Include OneDrive / cloud files' above to compare them anyway."
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
$script:DRTrial = $false
if ($script:DRUpdaterLoaded) {
    try { $script:DRTrial = Test-DRTrialMode } catch { $script:DRTrial = $false }
}
if ($script:DRTrial) {
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
}

$ui.ChkAck.Add_Checked({ Update-Summary })
$ui.ChkAck.Add_Unchecked({ Update-Summary })

$ui.BtnUpdate.Add_Click({
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
            return
        }

        $answer = [Windows.MessageBox]::Show(
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
        if (-not (Test-Path -LiteralPath $root)) {
            [System.Windows.MessageBox]::Show("That folder does not exist:`n$root", 'Duplicate Finder',
                'OK', 'Warning') | Out-Null
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
            AddArgument(@($root)).
            AddArgument([long](Get-MinBytes)).
            AddArgument([bool]$ui.ChkSub.IsChecked).
            AddArgument([bool]$ui.ChkCloud.IsChecked).
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
        $shown = $targets | Select-Object -First 15
        $list = ($shown | ForEach-Object { '  ' + $_.FullPath }) -join $nl
        if ($targets.Count -gt $shown.Count) {
            $list += $nl + "  ...and $($targets.Count - $shown.Count) more"
        }

        $msg = "These $($targets.Count) files will be moved to the Recycle Bin:" + $nl + $nl +
        $list + $nl + $nl +
        "Frees $(Format-Size $bytes)." + $nl +
        'One copy of every file is kept - the green KEEP row is never touched.' + $nl +
        'They go to the Recycle Bin, so you can restore any of them.'

        $answer = [System.Windows.MessageBox]::Show($msg, 'Confirm removal', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }

        $ok = 0; $failed = 0; $blocked = 0
        foreach ($t in $targets) {
            if (Test-ProtectedPath $t.FullPath) {
                $t.RowNote = 'Skipped - Windows system file, not safe to remove'
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
        if ($blocked -gt 0) { $tail += "  -  $blocked skipped as Windows system files" }
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
    if (-not $NoShow) { $null = $win.ShowDialog() }
    return
}

$null = $win.ShowDialog()
