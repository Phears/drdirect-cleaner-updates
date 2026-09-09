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

# raw.githubusercontent.com is a cache. For several minutes after a release it
# still serves the previous files, and it ignores cache-busting query strings.
# That is worse than a delay: the manifest and the scripts can come from
# different points in time, so a fresh manifest arrives with stale files, the
# checksums disagree, and a perfectly good update is discarded. The API's
# contents endpoint always returns what the branch holds right now.
$script:DRUpdateFeed = 'https://api.github.com/repos/Phears/drdirect-cleaner-updates/contents'
$script:DRUpdateRef = '?ref=main'
$script:DRUpdateHeaders = @{ Accept = 'application/vnd.github.raw'; 'User-Agent' = 'DRDirect-Updater'; 'Cache-Control' = 'no-cache' }

# Scripts the feed is allowed to replace. Anything else in a manifest is
# ignored, so a bad or tampered manifest cannot drop new files onto the PC.
$script:DRUpdatableFiles = @(
    'DRDirect Duplicate Finder.ps1',
    'DRDirect PC Cleaner GUI.ps1',
    'DRDirect Cleaner Engine.ps1',
    'DRDirect Updater.ps1'
)

# The public half of the update signing key. The private half never leaves the
# build PC. A manifest that does not verify against this is not ours, however
# well-formed it looks and wherever it was read from.
$script:DRUpdatePublicKey = 'MIIBCgKCAQEAtU+5ZVc6ySGCbWTLIiyP2UBRQ/6tx87XjGSJDk9JPvH1uGrNnT0E2INH+I9BDZxFeLeFqe6kmmmBjzvg/jCxjTDwsoO5Y/YL1P8KFhBsiJYtTVD2B2sRfXvdRJRIKUqA+HfeijIKfxzssnozB66ydqC4Dh0NNRFIoB9ZVaSTkOC+Xf+ZwjyOMEftoYdEs9H7TtyxcrDTGSHxqs4ThKHSEf1eoUq6CYoH6pP6yzmfUYU8zSBrZU8d6AAB2xyi1o3yWkLdkfivJlq2arm4LnEDKBZxPHOULCM1ZwBqTIPLyjKUOVfpZvpmgJ0XGrkgz+gI8BwkIsUiBLRbmMKOZ4reLQIDAQAB'

function ConvertFrom-DRPkcs1PublicKey {
    <#
    .SYNOPSIS
        Turns a base64 PKCS#1 RSAPublicKey into RSAParameters.
    .DESCRIPTION
        The DER is SEQUENCE { INTEGER modulus, INTEGER exponent }. Only the two
        integers are read; a leading zero pad on either is dropped, as
        RSAParameters wants the plain unsigned bytes.
    #>
    param([Parameter(Mandatory)] [string]$Base64)

    $der = [Convert]::FromBase64String($Base64)
    $i = 0
    function Read-Length {
        $first = $der[$script:__p++]
        if ($first -lt 0x80) { return [int]$first }
        $count = $first -band 0x7F
        $len = 0
        for ($n = 0; $n -lt $count; $n++) { $len = ($len -shl 8) -bor $der[$script:__p++] }
        return $len
    }
    $script:__p = 0
    if ($der[$script:__p++] -ne 0x30) { throw 'Not a PKCS#1 RSA public key.' }
    [void](Read-Length)

    $ints = @()
    for ($k = 0; $k -lt 2; $k++) {
        if ($der[$script:__p++] -ne 0x02) { throw 'Malformed RSA public key.' }
        $len = Read-Length
        $bytes = $der[$script:__p..($script:__p + $len - 1)]
        $script:__p += $len
        while ($bytes.Length -gt 1 -and $bytes[0] -eq 0) { $bytes = $bytes[1..($bytes.Length - 1)] }
        $ints += ,([byte[]]$bytes)
    }

    $params = New-Object System.Security.Cryptography.RSAParameters
    $params.Modulus  = $ints[0]
    $params.Exponent = $ints[1]
    return $params
}

function Test-DRManifestSignature {
    <#
    .SYNOPSIS
        True when these manifest bytes were signed by the DRDirect build PC.
    .DESCRIPTION
        Checksums in a manifest only prove a file matches that manifest. This is
        what proves the manifest itself is genuine, which is why an update is
        refused outright when it fails - a wrong answer here runs someone else's
        code with the elevation this app is trusted with.
    #>
    param(
        [Parameter(Mandatory)] [byte[]]$ManifestBytes,
        [Parameter(Mandatory)] [string]$SignatureBase64
    )
    $rsa = $null
    try {
        # Windows PowerShell 5.1 runs on .NET Framework, which has no
        # ImportRSAPublicKey - every check threw there, so every update was
        # refused as unsigned. Unpick the PKCS#1 key ourselves instead.
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsa.ImportParameters((ConvertFrom-DRPkcs1PublicKey $script:DRUpdatePublicKey))
        return $rsa.VerifyData($ManifestBytes, [Convert]::FromBase64String($SignatureBase64.Trim()),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } catch {
        return $false
    } finally {
        if ($rsa) { $rsa.Dispose() }
    }
}

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
        $response = Invoke-WebRequest -Uri "$script:DRUpdateFeed/update_manifest.json$script:DRUpdateRef" -Headers $script:DRUpdateHeaders `
            -UseBasicParsing -TimeoutSec 15

        # Verify before parsing. The signature covers the exact bytes the feed
        # served, so it has to be taken from those bytes and not from anything
        # re-encoded on the way through.
        $raw = if ($response.Content -is [byte[]]) { [byte[]]$response.Content }
               else { [System.Text.Encoding]::UTF8.GetBytes([string]$response.Content) }

        $sigResponse = Invoke-WebRequest -Uri "$script:DRUpdateFeed/update_manifest.sig$script:DRUpdateRef" -Headers $script:DRUpdateHeaders `
            -UseBasicParsing -TimeoutSec 15
        $sigText = if ($sigResponse.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString([byte[]]$sigResponse.Content)
        } else { [string]$sigResponse.Content }

        if (-not (Test-DRManifestSignature -ManifestBytes $raw -SignatureBase64 $sigText)) {
            $script:DRLastUpdateError = 'The update was not signed by DRDirect and was refused.'
            return $null
        }

        # Keep the verified pair. The app checks its own script against these
        # before running it, and it must not have to trust the network to do so.
        try {
            $root = Get-DRUpdateRoot
            [System.IO.File]::WriteAllBytes((Join-Path $root 'update_manifest.json'), $raw)
            [System.IO.File]::WriteAllText((Join-Path $root 'update_manifest.sig'),
                $sigText.Trim(), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }

        # A manifest written by PowerShell can start with a byte-order mark,
        # which ConvertFrom-Json refuses. Trim it before parsing.
        $text = [System.Text.Encoding]::UTF8.GetString($raw)
        $text = $text.TrimStart([char]0xFEFF, [char]0x200B).Trim()
        return ConvertFrom-Json -InputObject $text
    } catch {
        $script:DRLastUpdateError = $_.Exception.Message
        return $null
    }
}


function Get-DRUpdateSummary {
    <#
        .SYNOPSIS
            Builds the text shown before anyone agrees to an update.
        .DESCRIPTION
            Nobody should be asked to accept a change without being told what
            it is. Keep it to the two things that matter: which version, and
            what changed.
    #>
    param($Manifest, [version]$Installed, [version]$Offered)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Version $Offered  (you have $Installed)")
    $lines.Add('')
    $lines.Add("What's new:")

    # notes may be a single string or a list of them; both are accepted so the
    # publisher can write one line or several.
    $notes = @()
    if ($Manifest.PSObject.Properties['notes'] -and $Manifest.notes) {
        foreach ($entry in @($Manifest.notes)) {
            foreach ($line in ([string]$entry) -split "`r?`n") {
                $trimmed = $line.Trim()
                if ($trimmed) { $notes += $trimmed }
            }
        }
    }

    if ($notes.Count -gt 0) {
        foreach ($note in $notes) {
            # ASCII dashes only: this text travels through a signed feed and a
            # message box, so it must survive any code page.
            if ($note -match '^\s*[-*]') { $lines.Add('  ' + $note.TrimStart()) }
            else { $lines.Add('  - ' + $note) }
        }
    }
    else {
        $lines.Add('  - No description was published for this version.')
    }

    return ($lines -join [Environment]::NewLine)
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
            # Say what actually went wrong. A refused signature and a dead
            # network are different problems, and calling both "could not
            # reach" sends people hunting a firewall that is working fine.
            Message = $(
                if ($script:DRLastUpdateError) {
                    'Could not get the update: ' + $script:DRLastUpdateError +
                    ' You are still running the version you have.'
                } else {
                    'Could not reach the update server. You are still running the version you have.'
                }
            )
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
        return [pscustomobject]@{
            Available = $true; Reachable = $true
            Version = $offered; Installed = $installed; Manifest = $manifest
            Message = "Update $offered is available."
            Summary = Get-DRUpdateSummary -Manifest $manifest -Installed $installed -Offered $offered
        }
    }

    return [pscustomobject]@{
        Available = $false; Reachable = $true
        Version = $offered; Installed = $installed; Manifest = $manifest
        Message = 'You are up to date.'
    }
}

function Clear-DRStaleTemp {
    <# Removes a part-download left by an earlier run, read-only flag and all. #>
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly
        }
    } catch { }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Get-DRFileHashWithRetry {
    <#
        Hashes a just-downloaded file, retrying briefly while the read is
        denied. Anti-virus holds a new script open while it scans it, which
        looks like a permissions failure but clears on its own in a moment.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $Attempts = 5
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            return Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop
        } catch [System.UnauthorizedAccessException], [System.IO.IOException] {
            if ($i -eq $Attempts) { throw }
            Start-Sleep -Milliseconds (200 * $i)
        }
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
            # A leftover from an abandoned run can still be marked read-only or
            # be held open, and Invoke-WebRequest would then fail on a file the
            # user cannot even see. Clear it before asking for a fresh copy.
            Clear-DRStaleTemp -Path $temp

            $url = "$script:DRUpdateFeed/$([uri]::EscapeDataString($file.name))$script:DRUpdateRef"
            Invoke-WebRequest -Uri $url -Headers $script:DRUpdateHeaders -OutFile $temp -UseBasicParsing -TimeoutSec 60

            # Defender scans a freshly written script before it lets anything
            # else open it, so the first read can be denied on a perfectly good
            # download. Give it a moment rather than failing the whole update.
            $actual = (Get-DRFileHashWithRetry -Path $temp).Hash
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
    # The Duplicate Finder is licensed in its own right. If it has been paid for
    # on this PC, the Cleaner offers it whatever the Cleaner's own licence said.
    # Opening the Finder once writes this file, so its presence proves nothing -
    # only a code that was actually accepted does. Without this, a free try of
    # the Finder would unlock the page here for good.
    try {
        $finderState = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\licence_finder.dat'
        if (Test-Path -LiteralPath $finderState -PathType Leaf) {
            $fs = Get-Content -LiteralPath $finderState -Raw | ConvertFrom-Json
            $names = $fs.PSObject.Properties.Name
            $needs = if ($names -contains 'needs_activation') { [bool]$fs.needs_activation } else { $false }
            $unlocked = $false
            foreach ($key in 'code', 'activated') {
                if ($names -contains $key -and -not [string]::IsNullOrWhiteSpace([string]$fs.$key)) {
                    $unlocked = $true
                }
            }
            # A free try is never an entitlement, whatever else the file holds.
            if ($names -contains 'trial') { $unlocked = $false }
            if ($unlocked -and -not $needs) { return $true }
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
