# DRDirect Cleaner Engine
# Non-interactive maintenance functions used by the WPF application.
# Compatible with Windows PowerShell 5.1.

Set-StrictMode -Version 2.0

$script:DRAppName = 'DRDirect PC Cleaner'
$script:DRLogRoot = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Logs'
$script:DRReportRoot = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Reports'

function New-DREvent {
    param(
        [string]$TaskId,
        [ValidateSet('Started','Progress','Completed','Warning','Failed','Information')]
        [string]$State,
        [string]$Message,
        [int]$Percent = -1,
        [hashtable]$Data
    )

    [pscustomobject]@{
        PSTypeName = 'DRDirect.CleanerEvent'
        Timestamp  = Get-Date
        TaskId     = $TaskId
        State      = $State
        Message    = $Message
        Percent    = $Percent
        Data       = $Data
    }
}

function Get-DRTaskCatalog {
    @(
        [pscustomobject]@{ Id='cleanup.windows-temp'; Category='Cleanup'; Name='Windows temporary files'; Description='Removes temporary files no longer needed by Windows or applications.'; Risk='Safe'; Duration='1-5 min'; RequiresAdmin=$true; DefaultSelected=$true; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false }
        [pscustomobject]@{ Id='cleanup.browser-cache'; Category='Cleanup'; Name='Browser caches'; Description='Clears cache files while preserving passwords, bookmarks, cookies, and active sessions.'; Risk='Safe'; Duration='1-5 min'; RequiresAdmin=$false; DefaultSelected=$true; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false }
        [pscustomobject]@{ Id='cleanup.recycle-bin'; Category='Cleanup'; Name='Recycle Bin'; Description='Permanently removes Recycle Bin contents from available fixed drives.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false }
        [pscustomobject]@{ Id='cleanup.hidden-recycle-folders'; Category='Cleanup'; Name='Hidden Recycle Bin folders'; Description='Removes hidden $Recycle.Bin folders from fixed drives so Windows can rebuild them.'; Risk='Advanced'; Duration='< 5 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false }
        [pscustomobject]@{ Id='cleanup.cookies'; Category='Cleanup'; Name='Cookies and website storage'; Description='Clears cookies and site storage. This can sign you out of websites and webmail.'; Risk='SignOut'; Duration='1-5 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false }
        [pscustomobject]@{ Id='cleanup.prefetch'; Category='Cleanup'; Name='Windows Prefetch'; Description='Clears the Prefetch cache. Windows rebuilds it and app launches may initially be slower.'; Risk='Advanced'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false }
        [pscustomobject]@{ Id='cleanup.disk-cleanup'; Category='Cleanup'; Name='Windows Disk Cleanup'; Description='Runs the Windows Disk Cleanup profile for the C: drive.'; Risk='Safe'; Duration='1-10 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$true }

        [pscustomobject]@{ Id='repair.restore-point'; Category='Repair'; Name='Create restore point'; Description='Creates a Windows restore point before repair operations when System Protection is available.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$true; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false }
        [pscustomobject]@{ Id='repair.dism-health'; Category='Repair'; Name='DISM RestoreHealth'; Description='Repairs the Windows component store using DISM RestoreHealth.'; Risk='Repair'; Duration='20-60 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false }
        [pscustomobject]@{ Id='repair.component-cleanup'; Category='Repair'; Name='DISM component cleanup'; Description='Removes superseded Windows component versions.'; Risk='Repair'; Duration='10-30 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false }
        [pscustomobject]@{ Id='repair.sfc'; Category='Repair'; Name='System File Checker'; Description='Scans protected Windows files and repairs damaged copies.'; Risk='Repair'; Duration='10-30 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false }
        [pscustomobject]@{ Id='repair.windows-update'; Category='Repair'; Name='Windows Update repair'; Description='Resets Windows Update services, caches, Winsock, and the WinHTTP proxy.'; Risk='Advanced'; Duration='5-15 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false }
        [pscustomobject]@{ Id='repair.network-reset'; Category='Repair'; Name='Network reset'; Description='Flushes the DNS cache, releases and renews the IP address, resets Winsock, the TCP/IP stack, and the WinHTTP proxy, restores TCP auto-tuning to normal, disables TCP heuristics, and clears the ARP cache. The connection drops briefly during renew, a restart is required afterward, and any static IP or manual DNS configuration may need to be re-entered.'; Risk='Advanced'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false }

        [pscustomobject]@{ Id='security.defender-update'; Category='Security'; Name='Update Defender intelligence'; Description='Downloads the latest available Microsoft Defender security intelligence.'; Risk='Safe'; Duration='1-5 min'; RequiresAdmin=$true; DefaultSelected=$true; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false }
        [pscustomobject]@{ Id='security.quick-scan'; Category='Security'; Name='Defender quick scan'; Description='Scans common threat locations without changing exclusions.'; Risk='Safe'; Duration='5-20 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$true }
        [pscustomobject]@{ Id='security.full-scan'; Category='Security'; Name='Defender full scan'; Description='Scans all accessible files. This may take several hours.'; Risk='Long'; Duration='1+ hours'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$true }
        [pscustomobject]@{ Id='security.remove-exclusions'; Category='Security'; Name='Remove Defender exclusions'; Description='Exports and removes all configured Defender exclusions. Never runs automatically.'; Risk='Advanced'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false }
        [pscustomobject]@{ Id='security.network-files'; Category='Security'; Name='Enable network-file scanning'; Description='Enables Microsoft Defender scanning of files accessed over the network.'; Risk='Advanced'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false }

        [pscustomobject]@{ Id='health.chkdsk'; Category='Health'; Name='CHKDSK disk check'; Description='Checks the C: file system for corruption while Windows keeps running. Reports what it finds, repairs what is safe to repair, and never schedules a restart.'; Risk='Safe'; Duration='5-30 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$true }
        [pscustomobject]@{ Id='health.drive-check'; Category='Health'; Name='Drive health check'; Description='Reads the health information your drives report about themselves, including estimated life left and read errors. Nothing is changed or deleted.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$true; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false }
    )
}

function Test-DRAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-DRFullPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    try { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $null }
}

function Test-DRSafeDeleteTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$AllowedRoot
    )

    $full = Get-DRFullPath -Path $Path
    $root = Get-DRFullPath -Path $AllowedRoot
    if (-not $full -or -not $root -or $full.Length -le $root.Length) { return $false }
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }

    $blocked = @(
        [System.IO.Path]::GetPathRoot($full),
        $env:SystemDrive,
        $env:USERPROFILE,
        $env:WINDIR,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData
    ) | Where-Object { $_ }

    foreach ($item in $blocked) {
        $blockedFull = Get-DRFullPath -Path $item
        if ($blockedFull -and $full.Equals($blockedFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-DRPathSize {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) { return [int64]$item.Length }
        $sum = (Get-ChildItem -LiteralPath $Path -File -Force -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return [int64]0 }
        return [int64]$sum
    } catch { return [int64]0 }
}

function Get-DRPatternMatches {
    param([string[]]$Patterns)
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($pattern in $Patterns) {
        Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue | ForEach-Object { $found.Add($_) }
    }
    return @($found | Sort-Object -Property FullName -Unique)
}

function Get-DRBrowserCachePatterns {
    @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Code Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\GPUCache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\DawnCache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\ShaderCache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Service Worker\CacheStorage",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Media Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Code Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\GPUCache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\DawnCache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\ShaderCache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Service Worker\CacheStorage",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Media Cache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Cache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Code Cache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\GPUCache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\DawnCache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\ShaderCache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Service Worker\CacheStorage",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Media Cache",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\Cache",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\Code Cache",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\GPUCache",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\DawnCache",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\ShaderCache",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\Service Worker\CacheStorage",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\Media Cache",
        "$env:LOCALAPPDATA\Chromium\User Data\*\Cache",
        "$env:LOCALAPPDATA\Chromium\User Data\*\Code Cache",
        "$env:LOCALAPPDATA\Chromium\User Data\*\GPUCache",
        "$env:LOCALAPPDATA\Chromium\User Data\*\DawnCache",
        "$env:LOCALAPPDATA\Chromium\User Data\*\ShaderCache",
        "$env:LOCALAPPDATA\Chromium\User Data\*\Service Worker\CacheStorage",
        "$env:LOCALAPPDATA\Chromium\User Data\*\Media Cache",
        "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2",
        "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\startupCache",
        "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\shader-cache",
        "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\thumbnails",
        "$env:APPDATA\Opera Software\Opera Stable\Cache",
        "$env:APPDATA\Opera Software\Opera Stable\Code Cache"
    )
}

function Get-DRCookiePatterns {
    @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Network\Cookies",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Network\Cookies-journal",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Local Storage",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Session Storage",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\IndexedDB",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Service Worker\Database",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Service Worker\ScriptCache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Shared Storage",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Network\Cookies",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Network\Cookies-journal",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Local Storage",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Session Storage",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\IndexedDB",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Service Worker\Database",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Service Worker\ScriptCache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Shared Storage",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Network\Cookies",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Local Storage",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Session Storage",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\IndexedDB",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Service Worker\Database",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Shared Storage",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\Network\Cookies",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\Local Storage",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\Session Storage",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\IndexedDB",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\Service Worker\Database",
        "$env:LOCALAPPDATA\Chromium\User Data\*\Network\Cookies",
        "$env:LOCALAPPDATA\Chromium\User Data\*\Local Storage",
        "$env:LOCALAPPDATA\Chromium\User Data\*\Session Storage",
        "$env:LOCALAPPDATA\Chromium\User Data\*\IndexedDB",
        "$env:APPDATA\Opera Software\Opera Stable\Network\Cookies",
        "$env:APPDATA\Opera Software\Opera Stable\Local Storage",
        "$env:APPDATA\Opera Software\Opera Stable\Session Storage",
        "$env:APPDATA\Opera Software\Opera Stable\IndexedDB",
        "$env:APPDATA\Opera Software\Opera Stable\Service Worker\Database",
        "$env:APPDATA\Mozilla\Firefox\Profiles\*\cookies.sqlite",
        "$env:APPDATA\Mozilla\Firefox\Profiles\*\cookies.sqlite-wal",
        "$env:APPDATA\Mozilla\Firefox\Profiles\*\cookies.sqlite-shm",
        "$env:APPDATA\Mozilla\Firefox\Profiles\*\webappsstore.sqlite",
        "$env:APPDATA\Mozilla\Firefox\Profiles\*\storage\default",
        "$env:APPDATA\Mozilla\Firefox\Profiles\*\storage\temporary",
        "$env:APPDATA\Mozilla\Firefox\Profiles\*\storage\permanent",
        "$env:APPDATA\Mozilla\Firefox\Profiles\*\serviceworker"
    )
}

function Get-DRAllowedRootForPath {
    param([string]$Path)
    foreach ($candidate in @($env:TEMP, (Join-Path $env:WINDIR 'Temp'), (Join-Path $env:WINDIR 'Prefetch'), $env:LOCALAPPDATA, $env:APPDATA)) {
        $fullCandidate = Get-DRFullPath -Path $candidate
        $fullPath = Get-DRFullPath -Path $Path
        if ($fullCandidate -and $fullPath -and ($fullPath.Equals($fullCandidate, [StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($fullCandidate + '\', [StringComparison]::OrdinalIgnoreCase))) {
            return $fullCandidate
        }
    }
    return $null
}

function Remove-DRSafeItem {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$LiteralPath,
        [Parameter(Mandatory=$true)][string]$AllowedRoot
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) { return $false }
    if (-not (Test-DRSafeDeleteTarget -Path $LiteralPath -AllowedRoot $AllowedRoot)) {
        throw "Safety blocked deletion outside the approved root: $LiteralPath"
    }
    if ($PSCmdlet.ShouldProcess($LiteralPath, 'Remove')) {
        Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop
    }
    return $true
}

function Clear-DRFolderContents {
    param(
        [Parameter(Mandatory=$true)][string]$FolderPath,
        [string]$TaskId,
        [string]$TestRoot
    )

    $effectivePath = if ($TestRoot) { $TestRoot } else { $FolderPath }
    if (-not (Test-Path -LiteralPath $effectivePath -PathType Container)) { return 0 }
    $removed = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $effectivePath -Force -ErrorAction SilentlyContinue)) {
        try {
            if (Remove-DRSafeItem -LiteralPath $item.FullName -AllowedRoot $effectivePath) { $removed++ }
        } catch {
            New-DREvent -TaskId $TaskId -State Warning -Message ("Skipped {0}: {1}" -f $item.Name, $_.Exception.Message)
        }
    }
    return $removed
}

function Get-DRAnalysis {
    [CmdletBinding()]
    param([string[]]$TaskId, [string]$TestRoot)

    $catalog = Get-DRTaskCatalog
    $wanted = if ($TaskId) { $TaskId } else { @($catalog | Where-Object SupportsAnalysis | ForEach-Object Id) }
    foreach ($id in $wanted) {
        $bytes = [int64]0
        $items = 0
        $detail = ''
        try {
            switch ($id) {
                'cleanup.windows-temp' {
                    $paths = if ($TestRoot) { @($TestRoot) } else { @($env:TEMP, (Join-Path $env:WINDIR 'Temp')) }
                    foreach ($path in $paths) { $bytes += Get-DRPathSize $path; $items += @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue).Count }
                    $detail = 'Windows and application temporary folders'
                }
                'cleanup.browser-cache' {
                    $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot) } else { @(Get-DRPatternMatches (Get-DRBrowserCachePatterns)) }
                    foreach ($match in $matches) { $bytes += Get-DRPathSize $match.FullName; $items++ }
                    $detail = 'Cache only; passwords, cookies, and sessions preserved'
                }
                'cleanup.cookies' {
                    $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot) } else { @(Get-DRPatternMatches (Get-DRCookiePatterns)) }
                    foreach ($match in $matches) { $bytes += Get-DRPathSize $match.FullName; $items++ }
                    $detail = 'May sign you out of websites and webmail'
                }
                'cleanup.prefetch' {
                    $path = if ($TestRoot) { $TestRoot } else { Join-Path $env:WINDIR 'Prefetch' }
                    $bytes = Get-DRPathSize $path; $items = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue).Count
                    $detail = 'Advanced; Windows rebuilds this cache'
                }
                'cleanup.recycle-bin' {
                    $detail = 'Size is calculated by Windows during cleanup'
                }
                'security.remove-exclusions' {
                    if (Get-Command Get-MpPreference -ErrorAction SilentlyContinue) {
                        $pref = Get-MpPreference
                        $items = @($pref.ExclusionPath).Count + @($pref.ExclusionProcess).Count + @($pref.ExclusionExtension).Count
                    }
                    $detail = "$items Defender exclusion(s) configured"
                }
            }
            [pscustomobject]@{ TaskId=$id; Bytes=$bytes; ItemCount=$items; Detail=$detail; Error=$null }
        } catch {
            [pscustomobject]@{ TaskId=$id; Bytes=[int64]0; ItemCount=0; Detail='Analysis unavailable'; Error=$_.Exception.Message }
        }
    }
}

function Find-DRMpCmdRun {
    $paths = @(
        "$env:ProgramFiles\Windows Defender\MpCmdRun.exe",
        "$env:ProgramFiles\Microsoft Defender\MpCmdRun.exe",
        "$env:ProgramData\Microsoft\Windows Defender\Platform\*\MpCmdRun.exe"
    )
    foreach ($path in $paths) {
        $found = Get-Item -Path $path -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return 'MpCmdRun.exe'
}

function Set-DRActiveChildProcess {
    param([int]$ProcessId)
    $file = $env:DRDIRECT_CHILD_PID_FILE
    if ([string]::IsNullOrWhiteSpace($file)) { return }
    try {
        if ($ProcessId -gt 0) { [System.IO.File]::WriteAllText($file, [string]$ProcessId) }
        elseif (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Start-DRHiddenProcess {
    # Runs a console program with no window of its own and hands back its exit code
    # and output. Nothing here writes to the screen, so the interface stays clean.
    param([string]$FilePath, [string[]]$Arguments, [switch]$Publish)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $exitCode = $null
    $text = ''
    try {
        [void]$process.Start()
        if ($Publish) { Set-DRActiveChildProcess -ProcessId $process.Id }
        # Read both pipes before waiting; a full pipe buffer would stall the child.
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $text = (($outTask.Result + "`r`n" + $errTask.Result)).Trim()
        $exitCode = $process.ExitCode
    } finally {
        if ($Publish) { Set-DRActiveChildProcess -ProcessId 0 }
        $process.Dispose()
    }

    # sfc.exe writes UTF-16, which arrives here padded with null characters.
    $text = ($text -replace "`0", '')
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $text }
}

function Format-DROutputForLog {
    param([string]$Text, [int]$Limit = 6000)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $lines = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match 'percent complete|% complete') { continue }
        $lines += $trimmed
    }
    if (@($lines).Count -eq 0) { return '' }
    $report = ($lines -join "`r`n")
    if ($report.Length -gt $Limit) { $report = $report.Substring(0, $Limit) + "`r`n... (output truncated)" }
    return $report
}

function Invoke-DRExternalCommand {
    param([string]$TaskId, [string]$FilePath, [string[]]$Arguments, [string]$TestRoot)
    if ($TestRoot) {
        New-DREvent -TaskId $TaskId -State Information -Message ("TEST MODE: would run {0} {1}" -f $FilePath, ($Arguments -join ' '))
        return 0
    }
    # The process id is published while it runs so a force-stop from the interface
    # has something to aim at.
    $result = Start-DRHiddenProcess -FilePath $FilePath -Arguments $Arguments -Publish

    $report = Format-DROutputForLog -Text $result.Output
    if ($report) {
        New-DREvent -TaskId $TaskId -State Information -Message ("{0} reported:`r`n{1}" -f [System.IO.Path]::GetFileName($FilePath), $report)
    }

    if ($null -eq $result.ExitCode) { throw "$FilePath did not report a result. It was most likely stopped before it finished." }
    if ($result.ExitCode -ne 0) { throw "$FilePath finished with exit code $($result.ExitCode)." }
    return $result.ExitCode
}

function Invoke-DRChkdsk {
    param([string]$TaskId, [string]$TestRoot)
    if ($TestRoot) {
        New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: CHKDSK was not run.'
        return
    }

    $result = Start-DRHiddenProcess -FilePath 'chkdsk.exe' -Arguments @('C:','/scan') -Publish

    # chkdsk writes a "percent complete" line for every step; keep only the summary lines.
    $report = Format-DROutputForLog -Text $result.Output
    if ($report) {
        New-DREvent -TaskId $TaskId -State Information -Message ("CHKDSK reported:`r`n{0}" -f $report)
    }

    switch ($result.ExitCode) {
        0 { New-DREvent -TaskId $TaskId -State Information -Message 'CHKDSK found no file system problems on C:.' }
        1 { New-DREvent -TaskId $TaskId -State Information -Message 'CHKDSK found problems on C: and repaired them online. No restart is needed.' }
        2 { New-DREvent -TaskId $TaskId -State Warning -Message 'CHKDSK found problems on C: that it cannot repair while Windows is running. They have been logged for offline repair. Run "chkdsk C: /spotfix" from an administrator command prompt and restart when prompted.' }
        3 { New-DREvent -TaskId $TaskId -State Warning -Message 'CHKDSK could not complete the scan of C:. This usually means the volume is unavailable or the disk is failing. Check Event Viewer and the drive health before relying on this result.' }
        default {
            if ($null -eq $result.ExitCode) {
                New-DREvent -TaskId $TaskId -State Warning -Message 'CHKDSK finished but did not report a result. This normally means the check was stopped before it ended. The report above, if present, still shows what it found.'
            } else {
                New-DREvent -TaskId $TaskId -State Warning -Message ("CHKDSK finished with an unexpected result code ({0}). The report above, if present, shows what it found." -f $result.ExitCode)
            }
        }
    }
}

function Invoke-DRWindowsUpdateReset {
    param([string]$TaskId, [string]$TestRoot)
    if ($TestRoot) {
        New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: Windows Update services and caches were not changed.'
        return
    }

    $marker = Join-Path $env:ProgramData 'DRDirect_PC_Cleaner_WindowsUpdateReset_LastRun.txt'
    if (Test-Path -LiteralPath $marker) {
        try {
            $lastRun = [datetime](Get-Content -LiteralPath $marker -ErrorAction Stop | Select-Object -First 1)
            if (((Get-Date) - $lastRun).TotalDays -lt 30) {
                New-DREvent -TaskId $TaskId -State Information -Message 'Windows Update repair was skipped because it already ran within the last 30 days.'
                return
            }
        } catch { }
    }

    $services = @('bits','wuauserv','appidsvc','cryptsvc')
    foreach ($service in $services) { Stop-Service -Name $service -Force -ErrorAction SilentlyContinue }
    try {
        $cacheFolders = @(
            (Join-Path $env:SystemRoot 'SoftwareDistribution'),
            (Join-Path $env:SystemRoot 'System32\catroot2'),
            (Join-Path $env:ALLUSERSPROFILE 'Microsoft\Network\Downloader')
        )
        foreach ($folder in $cacheFolders) { Clear-DRFolderContents -FolderPath $folder -TaskId $TaskId | Out-Null }
        & netsh.exe winsock reset | Out-Null
        & netsh.exe winhttp reset proxy | Out-Null
        foreach ($dll in @('atl.dll','urlmon.dll','mshtml.dll')) { & regsvr32.exe /s $dll }
        Get-Date | Out-File -LiteralPath $marker -Force
    } finally {
        foreach ($service in $services) { Start-Service -Name $service -ErrorAction SilentlyContinue }
    }
}

function Invoke-DRNetworkReset {
    param([string]$TaskId, [string]$TestRoot)
    if ($TestRoot) {
        New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: network settings were not changed.'
        return
    }

    # Record the current TCP heuristics setting before it is changed.
    try {
        $heuristics = ((& netsh.exe interface tcp show heuristics 2>&1) | Out-String).Trim()
        if ($heuristics) { New-DREvent -TaskId $TaskId -State Information -Message ("TCP heuristics before reset:`r`n{0}" -f $heuristics) }
    } catch { }

    $steps = @(
        @{ Name='Flush DNS resolver cache';         File='ipconfig.exe'; Args=@('/flushdns') }
        @{ Name='Release IP address';               File='ipconfig.exe'; Args=@('/release') }
        @{ Name='Renew IP address';                 File='ipconfig.exe'; Args=@('/renew') }
        @{ Name='Reset Winsock catalog';            File='netsh.exe';    Args=@('winsock','reset') }
        @{ Name='Reset IPv4 stack';                 File='netsh.exe';    Args=@('int','ip','reset') }
        @{ Name='Reset IPv6 stack';                 File='netsh.exe';    Args=@('int','ipv6','reset') }
        @{ Name='Clear WinHTTP proxy';              File='netsh.exe';    Args=@('winhttp','reset','proxy') }
        @{ Name='Restore TCP auto-tuning to normal'; File='netsh.exe';   Args=@('int','tcp','set','global','autotuninglevel=normal') }
        @{ Name='Disable TCP heuristics';           File='netsh.exe';    Args=@('interface','tcp','set','heuristics','disabled') }
        @{ Name='Clear ARP cache';                  File='arp.exe';      Args=@('-d','*') }
        @{ Name='Reload NetBIOS name cache';        File='nbtstat.exe';  Args=@('-R') }
    )

    $index = 0
    foreach ($step in $steps) {
        $index++
        try {
            $result = Start-DRHiddenProcess -FilePath $step.File -Arguments $step.Args
            if ($result.ExitCode -ne 0) {
                New-DREvent -TaskId $TaskId -State Warning -Message ("{0} reported exit code {1}." -f $step.Name, $result.ExitCode)
            } else {
                New-DREvent -TaskId $TaskId -State Progress -Message ("{0} completed." -f $step.Name) -Percent ([int](100 * $index / @($steps).Count))
            }
        } catch {
            New-DREvent -TaskId $TaskId -State Warning -Message ("{0} could not run: {1}" -f $step.Name, $_.Exception.Message)
        }
    }
    New-DREvent -TaskId $TaskId -State Information -Message 'All network components were reset successfully. One last step: please save your work and restart Windows. The new Winsock and TCP/IP settings only become active after a restart.'
    New-DREvent -TaskId $TaskId -State Information -Message 'RESTART REQUIRED'
}

function Get-DRDiskProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) { return $null }
    return $property.Value
}

function Get-DRDiskDriveLetters {
    param($Disk)
    try {
        $number = $Disk | Get-Disk -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Number
    } catch { return '' }
    if ($null -eq $number) { return '' }
    $letters = @(Get-Partition -DiskNumber $number -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } |
        ForEach-Object { $_.DriveLetter })
    if (-not $letters.Count) { return '' }
    return (($letters | Sort-Object | ForEach-Object { $_ + ':' }) -join ', ')
}

function Invoke-DRDriveHealth {
    param([string]$TaskId, [string]$TestRoot)
    if ($TestRoot) {
        New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: the drive health check was not run.'
        return
    }

    if (-not (Get-Command -Name 'Get-PhysicalDisk' -ErrorAction SilentlyContinue)) {
        New-DREvent -TaskId $TaskId -State Warning -Message 'This version of Windows does not provide the drive health information this check reads. Nothing was changed.'
        return
    }

    $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    if (-not $disks.Count) {
        New-DREvent -TaskId $TaskId -State Warning -Message 'No drives reported health information. This can happen with some USB and RAID controllers. Nothing was changed.'
        return
    }

    $concerns = 0
    foreach ($disk in $disks) {
        $name = Get-DRDiskProperty $disk 'FriendlyName'
        if (-not $name) { $name = 'Drive' }
        $letters = Get-DRDiskDriveLetters $disk
        if ($letters) { $name = '{0}  ({1})' -f $letters, $name }
        $media = Get-DRDiskProperty $disk 'MediaType'
        $health = Get-DRDiskProperty $disk 'HealthStatus'
        $sizeBytes = Get-DRDiskProperty $disk 'Size'

        $lines = New-Object System.Collections.Generic.List[string]
        if ($sizeBytes) { $lines.Add(('Size: {0:N0} GB' -f ($sizeBytes / 1GB))) }
        if ($media) { $lines.Add(('Type: {0}' -f $media)) }

        $counter = $null
        try { $counter = $disk | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $counter = $null }

        $wear = Get-DRDiskProperty $counter 'Wear'
        $temperature = Get-DRDiskProperty $counter 'Temperature'
        $hours = Get-DRDiskProperty $counter 'PowerOnHours'
        $readErrors = Get-DRDiskProperty $counter 'ReadErrorsUncorrected'

        if ($null -ne $hours) { $lines.Add(('Powered on for about {0:N0} days in total.' -f ($hours / 24))) }
        if ($null -ne $temperature -and $temperature -gt 0) { $lines.Add(('Temperature: {0} C' -f $temperature)) }
        # Wear is a write-life figure. It means something on a solid-state drive and
        # nothing on a spinning one, which does not wear out by being written to.
        $isSolidState = ($media -eq 'SSD')
        if ($null -ne $wear -and $isSolidState) {
            $left = 100 - $wear
            if ($left -lt 0) { $left = 0 }
            $lines.Add(('Estimated life remaining: {0}%' -f $left))
        }

        $verdict = ''
        if ($health -eq 'Healthy') {
            $verdict = 'Windows reports this drive as healthy.'
        } elseif ($health) {
            $concerns++
            $verdict = 'Windows reports this drive as "{0}". Back up anything important on it now and have the drive replaced.' -f $health
        } else {
            $verdict = 'This drive did not report a health status. That is normal for some external drives.'
        }

        if ($null -ne $readErrors -and $readErrors -gt 0) {
            $concerns++
            $lines.Add(('This drive has failed to read data {0} time(s) without being able to correct it. That is an early sign of a failing drive.' -f $readErrors))
        }
        if ($null -ne $wear -and $isSolidState -and $wear -ge 80) {
            $concerns++
            $lines.Add('This drive has used most of its rated write life. It still works, but plan to replace it.')
        }

        $lines.Add($verdict)
        $state = if ($health -and $health -ne 'Healthy') { 'Warning' } else { 'Information' }
        New-DREvent -TaskId $TaskId -State $state -Message ("{0}`r`n  {1}" -f $name, ($lines -join "`r`n  "))
    }

    if ($concerns -gt 0) {
        New-DREvent -TaskId $TaskId -State Warning -Message 'One or more drives need attention. Nothing was changed on this PC. Copy anything you cannot lose to another drive before doing anything else.'
    } else {
        New-DREvent -TaskId $TaskId -State Information -Message ('All {0} drive(s) reported normal health. Nothing was changed on this PC.' -f $disks.Count)
    }
}

function New-DRHardwareItem {
    param([string]$Section, [string]$Label, [string]$Value, [string]$Note = '')
    [pscustomobject]@{
        PSTypeName = 'DRDirect.HardwareItem'
        Section    = $Section
        Label      = $Label
        Value      = $Value
        Note       = $Note
    }
}

function Get-DRCimValue {
    param([string]$ClassName)
    try { return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop) } catch { return @() }
}

function Format-DRDriverNote {
    param([string]$Version, $Date)
    if (-not $Version -and -not $Date) { return '' }
    if (-not $Date) { return 'driver {0}' -f $Version }
    $when = [datetime]$Date
    $note = 'driver {0} from {1}' -f $Version, $when.ToString('MMMM yyyy')
    $age = [int]((Get-Date) - $when).TotalDays
    if ($age -gt 730) { return '{0} - over two years old' -f $note }
    if ($age -gt 365) { return '{0} - over a year old' -f $note }
    return $note
}

function Get-DRDriverLookup {
    # One pass over the signed-driver list, keyed by device, so each device below
    # can show the version and date Windows has for it.
    $lookup = @{}
    foreach ($driver in @(Get-DRCimValue 'Win32_PnPSignedDriver')) {
        $id = Get-DRDiskProperty $driver 'DeviceID'
        if (-not $id) { continue }
        if ($lookup.ContainsKey($id)) { continue }
        $lookup[$id] = Format-DRDriverNote (Get-DRDiskProperty $driver 'DriverVersion') (Get-DRDiskProperty $driver 'DriverDate')
    }
    return $lookup
}

function Get-DRHardwareInventory {
    [CmdletBinding()]
    param()

    $items = New-Object System.Collections.Generic.List[object]
    $drivers = Get-DRDriverLookup

    # This PC
    $system = @(Get-DRCimValue 'Win32_ComputerSystem') | Select-Object -First 1
    $product = @(Get-DRCimValue 'Win32_ComputerSystemProduct') | Select-Object -First 1
    $maker = Get-DRDiskProperty $system 'Manufacturer'
    $model = Get-DRDiskProperty $system 'Model'
    # Lenovo puts a type code in Model and the name people recognise in Version.
    $friendly = Get-DRDiskProperty $product 'Version'
    # Boards sold to builders leave these fields as placeholder text rather than a model.
    $placeholder = '^\s*(None|To Be Filled By O\.E\.M\.|System Version|System Product Name|Default string|Not Applicable|N/A)\s*$'
    if ($model -match $placeholder) { $model = '' }
    if ($friendly -match $placeholder) { $friendly = '' }
    if ($friendly -and $model) { $model = '{0} ({1})' -f $friendly, $model }
    elseif ($friendly) { $model = $friendly }
    $makeAndModel = (('{0} {1}' -f $maker, $model).Trim())
    if ($makeAndModel) {
        # With no usable model the board name is the only thing a customer can look up.
        if (-not $model) { $makeAndModel = '{0} - no model name reported, see the motherboard below' -f $maker }
        $items.Add((New-DRHardwareItem 'This PC' 'Make and model' $makeAndModel))
    }

    $os = @(Get-DRCimValue 'Win32_OperatingSystem') | Select-Object -First 1
    $osName = Get-DRDiskProperty $os 'Caption'
    $osBuild = Get-DRDiskProperty $os 'BuildNumber'
    if ($osName) {
        $items.Add((New-DRHardwareItem 'This PC' 'Windows' ('{0} (build {1})' -f $osName.Trim(), $osBuild)))
    }
    $installed = Get-DRDiskProperty $os 'InstallDate'
    if ($installed) {
        $items.Add((New-DRHardwareItem 'This PC' 'Windows installed' (([datetime]$installed).ToString('d MMMM yyyy'))))
    }

    # Processor
    foreach ($cpu in @(Get-DRCimValue 'Win32_Processor')) {
        $cpuName = Get-DRDiskProperty $cpu 'Name'
        if ($cpuName) { $cpuName = $cpuName.Trim() }
        $cores = Get-DRDiskProperty $cpu 'NumberOfCores'
        $threads = Get-DRDiskProperty $cpu 'NumberOfLogicalProcessors'
        $detail = ''
        if ($cores -and $threads) { $detail = '{0} cores, {1} threads' -f $cores, $threads }
        elseif ($cores) { $detail = '{0} cores' -f $cores }
        $items.Add((New-DRHardwareItem 'Processor' 'Processor' $cpuName $detail))
    }

    # Memory
    $sticks = @(Get-DRCimValue 'Win32_PhysicalMemory')
    $array = @(Get-DRCimValue 'Win32_PhysicalMemoryArray') | Select-Object -First 1
    $slots = Get-DRDiskProperty $array 'MemoryDevices'
    $totalBytes = Get-DRDiskProperty $system 'TotalPhysicalMemory'
    if ($totalBytes) {
        $note = ''
        if ($slots -and $sticks.Count) {
            $note = 'in {0} of {1} slots' -f $sticks.Count, $slots
            if ($sticks.Count -lt $slots) { $note = '{0} - room to add more' -f $note }
        }
        $items.Add((New-DRHardwareItem 'Memory' 'Installed memory' ('{0:N0} GB' -f ($totalBytes / 1GB)) $note))
    }
    foreach ($stick in $sticks) {
        $bank = Get-DRDiskProperty $stick 'DeviceLocator'
        if (-not $bank) { $bank = Get-DRDiskProperty $stick 'BankLabel' }
        if (-not $bank) { $bank = 'Memory stick' }
        $capacity = Get-DRDiskProperty $stick 'Capacity'
        $speed = Get-DRDiskProperty $stick 'ConfiguredClockSpeed'
        if (-not $speed) { $speed = Get-DRDiskProperty $stick 'Speed' }
        $value = ''
        if ($capacity -and $speed) { $value = '{0:N0} GB at {1} MHz' -f ($capacity / 1GB), $speed }
        elseif ($capacity) { $value = '{0:N0} GB' -f ($capacity / 1GB) }
        $items.Add((New-DRHardwareItem 'Memory' $bank $value))
    }

    # Graphics
    foreach ($video in @(Get-DRCimValue 'Win32_VideoController')) {
        $videoName = Get-DRDiskProperty $video 'Name'
        $driverVersion = Get-DRDiskProperty $video 'DriverVersion'
        $driverDate = Get-DRDiskProperty $video 'DriverDate'
        $note = Format-DRDriverNote $driverVersion $driverDate
        $items.Add((New-DRHardwareItem 'Graphics' 'Display adapter' $videoName $note))
    }

    # Network
    foreach ($adapter in @(Get-DRCimValue 'Win32_NetworkAdapter')) {
        if ((Get-DRDiskProperty $adapter 'PhysicalAdapter') -ne $true) { continue }
        if ((Get-DRDiskProperty $adapter 'NetEnabled') -ne $true) { continue }
        $note = ''
        $pnpId = Get-DRDiskProperty $adapter 'PNPDeviceID'
        if ($pnpId -and $drivers.ContainsKey($pnpId)) { $note = $drivers[$pnpId] }
        $items.Add((New-DRHardwareItem 'Network' 'Adapter' (Get-DRDiskProperty $adapter 'Name') $note))
    }

    # Sound
    foreach ($sound in @(Get-DRCimValue 'Win32_SoundDevice')) {
        $note = ''
        $pnpId = Get-DRDiskProperty $sound 'PNPDeviceID'
        if ($pnpId -and $drivers.ContainsKey($pnpId)) { $note = $drivers[$pnpId] }
        $items.Add((New-DRHardwareItem 'Sound' 'Sound device' (Get-DRDiskProperty $sound 'Name') $note))
    }

    # Motherboard and BIOS
    $board = @(Get-DRCimValue 'Win32_BaseBoard') | Select-Object -First 1
    $boardMaker = Get-DRDiskProperty $board 'Manufacturer'
    $boardModel = Get-DRDiskProperty $board 'Product'
    if ($boardModel) {
        $items.Add((New-DRHardwareItem 'Motherboard and BIOS' 'Motherboard' (('{0} {1}' -f $boardMaker, $boardModel).Trim())))
    }

    $bios = @(Get-DRCimValue 'Win32_BIOS') | Select-Object -First 1
    $biosVersion = Get-DRDiskProperty $bios 'SMBIOSBIOSVersion'
    $biosDate = Get-DRDiskProperty $bios 'ReleaseDate'
    if ($biosVersion) {
        $value = $biosVersion
        if ($biosDate) { $value = '{0}, dated {1}' -f $biosVersion, (([datetime]$biosDate).ToString('d MMMM yyyy')) }
        # Windows has no way of knowing what the newest BIOS is, so this never claims one is needed.
        $items.Add((New-DRHardwareItem 'Motherboard and BIOS' 'BIOS version' $value 'Windows cannot tell whether a newer BIOS exists. Check the manufacturer support page for the board above.'))
    }

    return $items.ToArray()
}

function Get-DRDriverUpdateStatus {
    [CmdletBinding()]
    param()

    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        # Drivers come from Microsoft Update, which the default service does not include.
        $searcher.ServerSelection = 3
        $searcher.ServiceID = '7971f918-a847-4430-9279-4a52d1efe18d'
        $result = $searcher.Search("IsInstalled=0 and Type='Driver'")
        $titles = @($result.Updates | ForEach-Object { $_.Title })
        return [pscustomobject]@{
            PSTypeName = 'DRDirect.DriverUpdateStatus'
            Available  = $titles.Count
            Titles     = $titles
            Error      = ''
        }
    } catch {
        return [pscustomobject]@{
            PSTypeName = 'DRDirect.DriverUpdateStatus'
            Available  = 0
            Titles     = @()
            Error      = $_.Exception.Message
        }
    }
}

function Invoke-DRTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$TestRoot,
        [string[]]$SelectedExclusion
    )

    $task = Get-DRTaskCatalog | Where-Object Id -eq $TaskId | Select-Object -First 1
    if (-not $task) { throw "Unknown maintenance task: $TaskId" }
    if ($task.RequiresAdmin -and -not $TestRoot -and -not (Test-DRAdministrator)) { throw "$($task.Name) requires administrator access." }

    New-DREvent -TaskId $TaskId -State Started -Message ("Starting {0}." -f $task.Name) -Percent 0
    try {
        switch ($TaskId) {
            'cleanup.windows-temp' {
                $paths = if ($TestRoot) { @($TestRoot) } else { @($env:TEMP, (Join-Path $env:WINDIR 'Temp')) }
                $count = 0
                foreach ($path in $paths) { $result = Clear-DRFolderContents -FolderPath $path -TaskId $TaskId -TestRoot $(if ($TestRoot) { $TestRoot } else { $null }); if ($result -is [int]) { $count += $result } }
                New-DREvent -TaskId $TaskId -State Information -Message "$count temporary item(s) removed."
            }
            'cleanup.browser-cache' {
                $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot) } else { @(Get-DRPatternMatches (Get-DRBrowserCachePatterns)) }
                $index = 0
                foreach ($match in $matches) {
                    $index++
                    Clear-DRFolderContents -FolderPath $match.FullName -TaskId $TaskId | Out-Null
                    New-DREvent -TaskId $TaskId -State Progress -Message ("Cleared browser cache {0} of {1}." -f $index, @($matches).Count) -Percent ([int](100 * $index / [Math]::Max(1,@($matches).Count)))
                }
            }
            'cleanup.cookies' {
                $matches = if ($TestRoot) { @(Get-ChildItem -LiteralPath $TestRoot -Force -ErrorAction SilentlyContinue) } else { @(Get-DRPatternMatches (Get-DRCookiePatterns)) }
                $index = 0
                foreach ($match in $matches) {
                    $index++
                    $allowed = if ($TestRoot) { $TestRoot } else { Get-DRAllowedRootForPath $match.FullName }
                    if (-not $allowed) { throw "No approved browser root for $($match.FullName)" }
                    Remove-DRSafeItem -LiteralPath $match.FullName -AllowedRoot $allowed | Out-Null
                    New-DREvent -TaskId $TaskId -State Progress -Message ("Removed website data {0} of {1}." -f $index, @($matches).Count) -Percent ([int](100 * $index / [Math]::Max(1,@($matches).Count)))
                }
            }
            'cleanup.prefetch' {
                Clear-DRFolderContents -FolderPath (Join-Path $env:WINDIR 'Prefetch') -TaskId $TaskId -TestRoot $TestRoot | Out-Null
            }
            'cleanup.recycle-bin' {
                if ($TestRoot) { Clear-DRFolderContents -FolderPath $TestRoot -TaskId $TaskId -TestRoot $TestRoot | Out-Null }
                else { Clear-RecycleBin -Force -ErrorAction Stop }
            }
            'cleanup.hidden-recycle-folders' {
                if ($TestRoot) { Clear-DRFolderContents -FolderPath $TestRoot -TaskId $TaskId -TestRoot $TestRoot | Out-Null }
                else {
                    $fixedDrives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
                    foreach ($drive in $fixedDrives) {
                        $root = $drive.DeviceID + '\'
                        $recyclePath = Join-Path $root '$Recycle.Bin'
                        if (Test-Path -LiteralPath $recyclePath) { Remove-DRSafeItem -LiteralPath $recyclePath -AllowedRoot $root | Out-Null }
                    }
                }
            }
            'cleanup.disk-cleanup' {
                # 'Update Cleanup' is deliberately absent. It compacts the WinSxS
                # component store, which is exactly what repair.component-cleanup
                # does through DISM. Only one process can hold the servicing stack,
                # so running both meant the second sat blocked for hours with no
                # output. DISM owns the component store; cleanmgr owns the rest.
                $cleanmgr = Join-Path $env:SystemRoot 'System32\cleanmgr.exe'
                if (-not $TestRoot) {
                    $items = @('BranchCache','Delivery Optimization Files','Device Driver Packages','Downloaded Program Files','Internet Cache Files','Old ChkDsk Files','Recycle Bin','RetailDemo Offline Content','Setup Log Files','System error memory dump files','System error minidump files','Temporary Files','Temporary Setup Files','Thumbnail Cache','Windows Error Reporting Files','Windows Defender')
                    foreach ($item in $items) {
                        $key = Join-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches' $item
                        if (Test-Path $key) { New-ItemProperty -Path $key -Name StateFlags0777 -Value 2 -PropertyType DWord -Force | Out-Null }
                    }
                }
                Invoke-DRExternalCommand -TaskId $TaskId -FilePath $cleanmgr -Arguments @('/d','C:','/sagerun:777') -TestRoot $TestRoot | Out-Null
            }
            'repair.restore-point' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: restore point was not created.' }
                else { Checkpoint-Computer -Description 'DRDirect PC Cleaner - Before Maintenance' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop }
            }
            'repair.dism-health' { Invoke-DRExternalCommand -TaskId $TaskId -FilePath 'DISM.exe' -Arguments @('/Online','/Cleanup-Image','/RestoreHealth') -TestRoot $TestRoot | Out-Null }
            'repair.component-cleanup' { Invoke-DRExternalCommand -TaskId $TaskId -FilePath 'DISM.exe' -Arguments @('/Online','/Cleanup-Image','/StartComponentCleanup') -TestRoot $TestRoot | Out-Null }
            'repair.sfc' { Invoke-DRExternalCommand -TaskId $TaskId -FilePath 'sfc.exe' -Arguments @('/scannow') -TestRoot $TestRoot | Out-Null }
            'repair.windows-update' { Invoke-DRWindowsUpdateReset -TaskId $TaskId -TestRoot $TestRoot }
            'repair.network-reset' { Invoke-DRNetworkReset -TaskId $TaskId -TestRoot $TestRoot }
            'security.defender-update' { Invoke-DRExternalCommand -TaskId $TaskId -FilePath (Find-DRMpCmdRun) -Arguments @('-SignatureUpdate') -TestRoot $TestRoot | Out-Null }
            'security.quick-scan' { Invoke-DRExternalCommand -TaskId $TaskId -FilePath (Find-DRMpCmdRun) -Arguments @('-Scan','-ScanType','1') -TestRoot $TestRoot | Out-Null }
            'security.full-scan' { Invoke-DRExternalCommand -TaskId $TaskId -FilePath (Find-DRMpCmdRun) -Arguments @('-Scan','-ScanType','2') -TestRoot $TestRoot | Out-Null }
            'security.network-files' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: Defender preferences were not changed.' }
                else { Set-MpPreference -DisableScanningNetworkFiles $false -ErrorAction Stop }
            }
            'security.remove-exclusions' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: Defender exclusions were not changed.' }
                else {
                    if (-not $SelectedExclusion -or @($SelectedExclusion).Count -eq 0) {
                        $preference = Get-MpPreference -ErrorAction Stop
                        $SelectedExclusion = @()
                        $SelectedExclusion += @($preference.ExclusionPath | ForEach-Object { 'Path:' + $_ })
                        $SelectedExclusion += @($preference.ExclusionProcess | ForEach-Object { 'Process:' + $_ })
                        $SelectedExclusion += @($preference.ExclusionExtension | ForEach-Object { 'Extension:' + $_ })
                    }
                    if (@($SelectedExclusion).Count -eq 0) {
                        New-DREvent -TaskId $TaskId -State Information -Message 'No Defender exclusions are configured.'
                        break
                    }
                    New-Item -Path $script:DRReportRoot -ItemType Directory -Force | Out-Null
                    $backup = Join-Path $script:DRReportRoot ('Defender_Exclusions_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.clixml')
                    Get-MpPreference | Select-Object ExclusionPath,ExclusionProcess,ExclusionExtension | Export-Clixml -LiteralPath $backup
                    foreach ($entry in $SelectedExclusion) {
                        $parts = $entry -split ':', 2
                        if (@($parts).Count -ne 2) { continue }
                        switch ($parts[0]) {
                            'Path' { Remove-MpPreference -ExclusionPath $parts[1] -ErrorAction Stop }
                            'Process' { Remove-MpPreference -ExclusionProcess $parts[1] -ErrorAction Stop }
                            'Extension' { Remove-MpPreference -ExclusionExtension $parts[1] -ErrorAction Stop }
                        }
                    }
                    New-DREvent -TaskId $TaskId -State Information -Message ("Original exclusions exported to {0}." -f $backup)
                }
            }
            'health.chkdsk' { Invoke-DRChkdsk -TaskId $TaskId -TestRoot $TestRoot }
            'health.drive-check' { Invoke-DRDriveHealth -TaskId $TaskId -TestRoot $TestRoot }
        }
        New-DREvent -TaskId $TaskId -State Completed -Message ("{0} completed." -f $task.Name) -Percent 100
    } catch {
        New-DREvent -TaskId $TaskId -State Failed -Message $_.Exception.Message
    }
}

function Invoke-DRPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$TaskId,
        [string]$TestRoot,
        [string[]]$SelectedExclusion
    )

    $events = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($id in $TaskId) {
        $index++
        foreach ($event in @(Invoke-DRTask -TaskId $id -TestRoot $TestRoot -SelectedExclusion $SelectedExclusion)) {
            $events.Add($event)
            Write-Output $event
        }
    }
    return
}

function Write-DRRunReport {
    param([object[]]$Events, [string[]]$TaskId, [datetime]$StartedAt)
    New-Item -Path $script:DRReportRoot -ItemType Directory -Force | Out-Null
    $path = Join-Path $script:DRReportRoot ('Maintenance_Report_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('DRDirect PC Cleaner - Maintenance Report')
    $lines.Add(('Computer: {0}' -f $env:COMPUTERNAME))
    $lines.Add(('User: {0}' -f $env:USERNAME))
    $lines.Add(('Started: {0}' -f $StartedAt))
    $lines.Add(('Finished: {0}' -f (Get-Date)))
    $lines.Add('')
    $lines.Add('Selected tasks:')
    foreach ($id in $TaskId) { $lines.Add('  - ' + $id) }
    $lines.Add('')
    $lines.Add('Events:')
    foreach ($event in $Events) { $lines.Add(('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}: {3}' -f $event.Timestamp, $event.State, $event.TaskId, $event.Message)) }
    [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($true))
    return $path
}
