<#
.SYNOPSIS
    Checks a public update feed for newer DRDirect scripts and installs them.

.DESCRIPTION
    The Cleaner's GUI and Engine are compiled into DRDirect PC Cleaner.exe by
    ps2exe, so they cannot be replaced while the app runs. The Duplicate Finder
    ships as a live .ps1 and can be, which is what this updater handles.

    Downloads land in the user's own AppData, never beside the exe, so no
    administrator rights and no write access to Program Files are needed. Every
    file is checked against the SHA-256 in the manifest before it is accepted -
    these scripts run elevated, so an unverified download is never written.

    Dot-source this file; it defines functions and performs no work on load.
#>

$script:DRUpdateFeed = 'https://raw.githubusercontent.com/Phears/drdirect-cleaner-updates/main'

# Scripts the feed is allowed to replace. Anything else in a manifest is
# ignored, so a bad or tampered manifest cannot drop new files onto the PC.
$script:DRUpdatableFiles = @('DRDirect Duplicate Finder.ps1', 'DRDirect Updater.ps1')

function Get-DRUpdateRoot {
    <# Updated scripts live beside the reports, under the user's AppData. #>
    $root = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Scripts'
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -Path $root -ItemType Directory -Force | Out-Null
    }
    return $root
}

function Get-DRInstalledVersion {
    <# Absent marker means nothing has been updated yet; the bundled copies win. #>
    $marker = Join-Path (Get-DRUpdateRoot) 'installed.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return [version]'0.0.0' }
    try {
        $data = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        return [version]$data.version
    } catch {
        # A corrupt marker should not wedge updates forever - treat it as none.
        return [version]'0.0.0'
    }
}

function Get-DRUpdateManifest {
    <# Returns the parsed manifest, or $null when the feed cannot be reached. #>
    try {
        # Older Windows PowerShell negotiates SSL3/TLS1.0 by default, which
        # GitHub refuses. Ask for TLS 1.2 explicitly.
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }

        # No credentials: the feed is public precisely so nothing has to be
        # embedded in the exe, where any recipient could extract it.
        $response = Invoke-WebRequest -Uri "$script:DRUpdateFeed/update_manifest.json" `
            -UseBasicParsing -TimeoutSec 15 -Headers @{ 'Cache-Control' = 'no-cache' }

        # A manifest written by PowerShell can start with a byte-order mark,
        # which ConvertFrom-Json refuses. Trim it before parsing.
        $text = [string]$response.Content
        $text = $text.TrimStart([char]0xFEFF, [char]0x200B).Trim()
        return ConvertFrom-Json -InputObject $text
    } catch {
        $script:DRLastUpdateError = $_.Exception.Message
        return $null
    }
}


function Test-DRUpdateAvailable {
    <#
    .SYNOPSIS
        Reports whether the feed offers a newer version than what is installed.
    #>
    $manifest = Get-DRUpdateManifest
    if (-not $manifest) {
        return [pscustomobject]@{
            Available = $false; Reachable = $false
            Version = $null; Installed = Get-DRInstalledVersion
            Message = 'Could not reach the update server. You are still running the version you have.'
        }
    }

    $installed = Get-DRInstalledVersion
    try { $offered = [version]$manifest.version } catch {
        return [pscustomobject]@{
            Available = $false; Reachable = $true
            Version = $null; Installed = $installed
            Message = 'The update server returned something unreadable. Nothing was changed.'
        }
    }

    if ($offered -gt $installed) {
        $note = if ($manifest.notes) { " $($manifest.notes)" } else { '' }
        return [pscustomobject]@{
            Available = $true; Reachable = $true
            Version = $offered; Installed = $installed; Manifest = $manifest
            Message = "Update $offered is available.$note"
        }
    }

    return [pscustomobject]@{
        Available = $false; Reachable = $true
        Version = $offered; Installed = $installed; Manifest = $manifest
        Message = 'You are up to date.'
    }
}

function Install-DRUpdate {
    <#
    .SYNOPSIS
        Downloads and verifies the scripts named in a manifest.
    .DESCRIPTION
        Every file is downloaded to a temporary name and hashed before it
        replaces anything. One bad hash abandons the whole update, so the PC is
        never left running a half-applied mix of old and new scripts.
    #>
    param([Parameter(Mandatory)] $Manifest)

    $root = Get-DRUpdateRoot
    $staged = @()

    try {
        foreach ($file in $Manifest.files) {
            if ($script:DRUpdatableFiles -notcontains $file.name) {
                # Not on the allow-list - skip rather than fail, so adding a new
                # file to the feed never breaks older copies of the app.
                continue
            }

            $temp = Join-Path $root ("{0}.downloading" -f $file.name)
            $url = "$script:DRUpdateFeed/$([uri]::EscapeDataString($file.name))"
            Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing -TimeoutSec 60

            $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
            if ($actual -ne $file.sha256.ToUpperInvariant()) {
                throw "'$($file.name)' did not match its published checksum and was discarded."
            }

            $staged += [pscustomobject]@{ Temp = $temp; Final = (Join-Path $root $file.name) }
        }

        if ($staged.Count -eq 0) { throw 'The update contained no files this version can use.' }

        # Everything verified - swap the files in as the last step.
        foreach ($item in $staged) {
            Move-Item -LiteralPath $item.Temp -Destination $item.Final -Force
        }

        @{ version = $Manifest.version.ToString(); installed = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'installed.json') -Encoding UTF8

        return [pscustomobject]@{
            Success = $true; Version = $Manifest.version
            Message = "Updated to $($Manifest.version). The new Duplicate Finder is used from now on."
        }
    } catch {
        # Clear part-downloads so the next attempt starts clean.
        foreach ($item in $staged) {
            Remove-Item -LiteralPath $item.Temp -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem -LiteralPath $root -Filter '*.downloading' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        return [pscustomobject]@{
            Success = $false; Version = $null
            Message = "Update failed: $($_.Exception.Message)"
        }
    }
}
# --- Trial mode -------------------------------------------------------------
# A single-use code opens the app in trial mode: one cleanup run, and one
# duplicate category. Both are recorded in the same licence.dat the launcher
# writes, so closing and reopening does not hand out a second go.

# Set by the Duplicate Finder before it loads this file. Each product keeps its
# own activation, so a code for one does not silently unlock the other.
# Tested this way because StrictMode treats reading an unset variable as an
# error, and the Cleaner never sets it - only the Duplicate Finder does.
if (-not (Get-Variable -Name 'DRProduct' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DRProduct = 'PC Cleaner'
}
$script:DRStateLeaf = if ($script:DRProduct -eq 'Duplicate Finder') { 'licence_finder.dat' } else { 'licence.dat' }
$script:DRLicenceState = Join-Path $env:LOCALAPPDATA (Join-Path 'DRDirect PC Cleaner' $script:DRStateLeaf)

# Copies sold before the split were activated into the shared file. Carry that
# activation across the first time this runs, so an update never turns someone's
# working program into one that asks for a code you can no longer issue. New
# installs have nothing to inherit and stay strictly separate.
if ($script:DRProduct -eq 'Duplicate Finder' -and -not (Test-Path -LiteralPath $script:DRLicenceState -PathType Leaf)) {
    $shared = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\licence.dat'
    if (Test-Path -LiteralPath $shared -PathType Leaf) {
        try {
            Copy-Item -LiteralPath $shared -Destination $script:DRLicenceState -ErrorAction Stop
        } catch { }
    }
}

function Get-DRLicenceState {
    try {
        if (Test-Path -LiteralPath $script:DRLicenceState -PathType Leaf) {
            return Get-Content -LiteralPath $script:DRLicenceState -Raw | ConvertFrom-Json
        }
    } catch { }
    return $null
}

function Save-DRLicenceState {
    param($State)
    try {
        $dir = Split-Path -Parent $script:DRLicenceState
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $State | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $script:DRLicenceState -Encoding UTF8
    } catch { }
}

function Test-DRTrialMode {
    <# True when this session was opened with a single-use trial code. #>
    $state = Get-DRLicenceState
    if (-not $state) { return $false }
    if (-not ($state.PSObject.Properties.Name -contains 'trial')) { return $false }
    return [bool]$state.trial
}

function Get-DRTrialValue {
    param([string]$Name)
    $state = Get-DRLicenceState
    if (-not $state -or -not $state.trial) { return $null }
    if ($state.trial.PSObject.Properties.Name -contains $Name) { return $state.trial.$Name }
    return $null
}

function Set-DRTrialValue {
    param([string]$Name, $Value)
    $state = Get-DRLicenceState
    if (-not $state) { return }
    if (-not $state.trial) { return }
    $state.trial | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    Save-DRLicenceState $state
}

function Get-DRDaysLeft {
    <#
    .SYNOPSIS
        Whole days until this copy's licence lapses, or $null when it is not a
        dated build (lifetime, or one of your own machines).
    .DESCRIPTION
        The launcher writes the effective end date into licence.dat on every
        start, so the Cleaner and the Duplicate Finder can both show a trial
        counting down without carrying the licence file themselves. A day that
        has begun still counts, so a 14-day trial reads "14 days left" on the
        first day and "1 day left" on the last.
    #>
    $state = Get-DRLicenceState
    if (-not $state) { return $null }
    if (-not ($state.PSObject.Properties.Name -contains 'expires')) { return $null }
    try {
        $end = [datetime]::ParseExact([string]$state.expires, 'yyyy-MM-dd', $null)
    } catch { return $null }
    return [int][math]::Floor(($end.Date - (Get-Date).Date).TotalDays)
}

# --- Activation -------------------------------------------------------------
# Shown from inside the Cleaner rather than before it opens, so an unactivated
# copy is never a dead end - it runs under trial limits until a code arrives.

function Test-DRNeedsActivation {
    $state = Get-DRLicenceState
    if (-not $state) { return $false }
    if ($state.PSObject.Properties.Name -notcontains 'needs_activation') { return $false }
    return [bool]$state.needs_activation
}

function Resolve-DRActivationUi {
    # $PSScriptRoot is empty inside a compiled exe, which silently broke this -
    # the button appeared to do nothing. Look where the program actually lives.
    $roots = New-Object System.Collections.Generic.List[string]
    if ($PSScriptRoot) { $roots.Add($PSScriptRoot) }
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe) { $roots.Add((Split-Path -Parent $exe)) }
    } catch { }
    try {
        $base = [AppDomain]::CurrentDomain.BaseDirectory
        if ($base) { $roots.Add($base) }
    } catch { }
    $roots.Add((Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Scripts'))

    foreach ($root in @($roots | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $candidate = Join-Path $root 'DRDirect Activation.ps1'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Show-DRActivation {
    <#
    .SYNOPSIS
        Opens the activation window and applies whatever code is entered.
    .OUTPUTS
        'activated', 'removed', or '' when nothing happened.
    #>
    param([string]$Reason = 'expired', [string]$Product = 'PC Cleaner')

    $ui = Resolve-DRActivationUi
    if (-not $ui) {
        # Never fail silently here - a button that does nothing is worse than
        # one that explains itself.
        try {
            Add-Type -AssemblyName PresentationFramework
            [Windows.MessageBox]::Show(
                'The activation window could not be found in this copy. Contact DRDirect.',
                'DRDirect', 'OK', 'Warning') | Out-Null
        } catch { }
        return ''
    }
    $result = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA `
        -File $ui -Reason $Reason -Product $Product -Detail 'Paste the code DRDirect sent you.'
    return ($result | Where-Object { $_ } | Select-Object -Last 1)
}

function Test-DRDuplicatesAllowed {
    <#
    .SYNOPSIS
        True when this copy is entitled to the Duplicate Finder.
    .DESCRIPTION
        It comes with six months or more. A build with no licence file at all
        never expires and is one of your own machines, so it gets everything.
    #>
    # The Duplicate Finder is licensed in its own right. If it has been activated
    # on this PC, the Cleaner offers it whatever the Cleaner's own licence said -
    # the person has paid for it separately.
    try {
        $finderState = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\licence_finder.dat'
        if (Test-Path -LiteralPath $finderState -PathType Leaf) {
            $fs = Get-Content -LiteralPath $finderState -Raw | ConvertFrom-Json
            $needs = $false
            if ($fs.PSObject.Properties.Name -contains 'needs_activation') { $needs = [bool]$fs.needs_activation }
            if (-not $needs) { return $true }
        }
    } catch { }

    # $PSScriptRoot is empty inside a compiled exe, and the file keeps its
    # per-product name, so look for both beside wherever this actually runs.
    $roots = New-Object System.Collections.Generic.List[string]
    if ($PSScriptRoot) { $roots.Add($PSScriptRoot) }
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe) { $roots.Add((Split-Path -Parent $exe)) }
    } catch { }
    try {
        $base = [AppDomain]::CurrentDomain.BaseDirectory
        if ($base) { $roots.Add($base) }
    } catch { }

    foreach ($root in @($roots | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        foreach ($name in 'licence_cleaner.json', 'licence.json') {
            $file = Join-Path $root $name
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            try {
                $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                if ($data.PSObject.Properties.Name -notcontains 'duplicates') { return $true }
                return [bool]$data.duplicates
            } catch {
                return $false
            }
        }
    }

    # No licence file at all - a build that never expires, one of your own.
    return $true
}
