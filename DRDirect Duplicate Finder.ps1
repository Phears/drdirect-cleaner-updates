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
            [System.Windows.MessageBox]::Show('That file is no longer there.', 'Duplicate Finder', 'OK', 'Information') | Out-Null
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
            try { [System.Windows.Window]::GetWindow($ui.BtnBack).WindowState = [System.Windows.WindowState]::Minimized } catch { }
            return
        }
    } catch {
        [System.Windows.MessageBox]::Show("Could not switch to the Cleaner: $($_.Exception.Message)",
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
            return
        }
    } catch { }
    [System.Windows.MessageBox]::Show('The DRDirect Cleaner is not open. Open it from its shortcut.',
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
            [System.Windows.MessageBox]::Show('This copy is activated. Nothing to do.',
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
            [Windows.MessageBox]::Show($check.Message, 'DRDirect Duplicate Finder',
                [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
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
        if ($root -and -not (Test-Path -LiteralPath $root)) {
            [System.Windows.MessageBox]::Show("That folder does not exist:`n$root", 'Duplicate Finder',
                'OK', 'Warning') | Out-Null
            return
        }
        $scanRoots = @(Get-DRScanRoots -Folder $root)
        if ($scanRoots.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Choose a folder, or tick a cloud service or a drive to scan.', 'Duplicate Finder',
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

        $answer = [System.Windows.MessageBox]::Show($msg, 'Confirm removal', 'YesNo', 'Warning')
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
            [System.Windows.MessageBox]::Show($detail, 'DRDirect Duplicate Finder', 'OK', 'Error') | Out-Null
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
