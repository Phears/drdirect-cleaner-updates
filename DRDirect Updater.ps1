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
    'DRDirect Updater.ps1',
    'DRDirect Activation.ps1',
    # The Uninstaller is a separate program, so it travels as one package. It is
    # only stored here; Update-DRUninstallerFromFeed puts it in place.
    'DRDirect Uninstaller.zip'
)

# The public half of the update signing key. The private half never leaves the
# build PC. A manifest that does not verify against this is not ours, however
# well-formed it looks and wherever it was read from.
$script:DRUpdatePublicKey = 'MIIBCgKCAQEAyBcTNedOtDyzRcTcgWTLyT61ubvw6zd3PMrb+xl9Pm3pS1MT2r/21zwSSKgaFbQLzXtYZY9nRFN4i3rPgckA1ZYzJUxDFzVE7Lx42ZU7zgT4R6xx/HSpSK+v9j3AxAEuR83dqocDz29KI0gfXXWkiHldB1jZZlps3BJFGv9w3X6odaKLXvBGo3/lPKqoFhSFk5rG5qwJrOUfwm4NydOhwK1ldgLdbavDz2/6yoYlaIqRjZKznUNOFL4dpXboFNdoPa0hRnHAfIUWdDRHJCdOnw9Tg647mM89PQUChAHe3CcPf6bk7lOS2OOwaHqs3a5iDvh8LFMj2fTYJ5MEjOC6dQIDAQAB'

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

            # The Uninstaller package is large and rarely changes, so a copy that
            # already matches is kept instead of being downloaded again.
            $final = Join-Path $root $file.name
            if ((Test-Path -LiteralPath $final -PathType Leaf) -and
                (Get-DRFileHashWithRetry -Path $final).Hash -eq $file.sha256.ToUpperInvariant()) {
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

            $staged += [pscustomobject]@{ Temp = $temp; Final = $final }
        }

        if (-not @($Manifest.files | Where-Object { $script:DRUpdatableFiles -contains $_.name })) {
            throw 'The update contained no files this version can use.'
        }

        # Everything verified - swap the files in as the last step.
        foreach ($item in $staged) {
            Move-Item -LiteralPath $item.Temp -Destination $item.Final -Force
        }

        @{ version = $Manifest.version.ToString(); installed = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'installed.json') -Encoding UTF8

        return [pscustomobject]@{
            Success = $true; Version = $Manifest.version
            # Say what to do next. The downloaded scripts are only read when
            # the app starts, so an update that is installed but not reopened
            # looks like an update that did nothing.
            Message = "Updated to $($Manifest.version)." + [Environment]::NewLine + [Environment]::NewLine +
                      "Close and reopen the program to start using it. No PC restart is needed."
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
function Update-DRUninstallerFromFeed {
    <#
    .SYNOPSIS
        Puts the Uninstaller from the latest accepted update in place.
    .DESCRIPTION
        The launcher unpacks the Uninstaller from the copy built into the exe,
        which an update cannot change. So the feed carries it as a package, and
        this replaces the unpacked copy before it opens.

        It only trusts the signed manifest of an update the person accepted, and
        only replaces an Uninstaller that is already installed and not running.
        The launcher's own stamp (package.sha256) is left alone, so the launcher
        does not unpack its built-in copy over this one on the next start.
        Anything that goes wrong leaves the current Uninstaller as it is.

        -CheckOnly changes nothing and returns $true when there is work to do,
        so the Cleaner can say so before it starts.
    #>
    param([switch]$CheckOnly)
    $package = 'DRDirect Uninstaller.zip'
    try {
        $target = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Uninstaller'
        if (-not (Test-Path -LiteralPath (Join-Path $target 'BCUninstaller.exe') -PathType Leaf)) { return }

        $root = Get-DRUpdateRoot
        $manifestPath = Join-Path $root 'update_manifest.json'
        $signaturePath = Join-Path $root 'update_manifest.sig'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) { return }
        $manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
        if (-not (Test-DRManifestSignature -ManifestBytes $manifestBytes -SignatureBase64 ([System.IO.File]::ReadAllText($signaturePath)))) { return }

        # The cached manifest is refreshed by every check, so only a version the
        # person accepted counts, not one that was merely offered.
        $manifest = ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($manifestBytes).TrimStart([char]0xFEFF).Trim())
        if ([version]$manifest.version -gt (Get-DRInstalledVersion)) { return }
        $entry = @($manifest.files | Where-Object { $_.name -eq $package }) | Select-Object -First 1
        if (-not $entry) { return }
        $expected = ([string]$entry.sha256).ToUpperInvariant()

        $stamp = Join-Path $target 'feed_package.sha256'
        if ((Test-Path -LiteralPath $stamp -PathType Leaf) -and
            ([System.IO.File]::ReadAllText($stamp).Trim() -eq $expected)) { return }

        # Files in use cannot be replaced. It is tried again the next time it is opened.
        $running = @(Get-Process -Name 'BCUninstaller' -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -and $_.Path.StartsWith($target, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
        })
        if ($running.Count) { return }
        if ($CheckOnly) { return $true }

        # An update applied by an older updater skipped the package, so fetch it now.
        $zip = Join-Path $root $package
        if (-not (Test-Path -LiteralPath $zip -PathType Leaf) -or (Get-DRFileHashWithRetry -Path $zip).Hash -ne $expected) {
            try {
                [Net.ServicePointManager]::SecurityProtocol =
                    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            } catch { }
            $temp = "$zip.downloading"
            Clear-DRStaleTemp -Path $temp
            Invoke-WebRequest -Uri "$script:DRUpdateFeed/$([uri]::EscapeDataString($package))$script:DRUpdateRef" `
                -Headers $script:DRUpdateHeaders -OutFile $temp -UseBasicParsing -TimeoutSec 120
            if ((Get-DRFileHashWithRetry -Path $temp).Hash -ne $expected) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                return
            }
            Move-Item -LiteralPath $temp -Destination $zip -Force
        }

        # Same rules as the launcher: never write outside the folder, and never
        # replace what the person's own use created (settings, records, undo copies).
        $keepFiles = @('bcuninstaller.settings', 'certcache.xml', 'infocache.xml', 'bcuninstaller.log')
        $keepFolders = @('undobackups', 'installlogs')
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($member in $archive.Entries) {
                $parts = @($member.FullName.Replace('\', '/').Split('/') | Where-Object { $_ })
                if ($member.FullName.EndsWith('/') -or $parts.Count -eq 0 -or $parts -contains '..') { continue }
                $destination = Join-Path $target ($parts -join '\')
                $isUserData = ($keepFolders -contains $parts[0].ToLowerInvariant()) -or
                    ($parts.Count -eq 1 -and $keepFiles -contains $parts[0].ToLowerInvariant())
                if ($isUserData -and (Test-Path -LiteralPath $destination)) { continue }
                $folder = Split-Path -Parent $destination
                if (-not (Test-Path -LiteralPath $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($member, $destination, $true)
            }
        } finally {
            $archive.Dispose()
        }
        [System.IO.File]::WriteAllText($stamp, $expected, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # Not fatal: the Uninstaller that is already there still opens.
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

# ---------------------------------------------------------------------------
# Windows' installed-programs list
# ---------------------------------------------------------------------------
# Lists a DRDirect program in Settings > Apps and in the DRDirect Uninstaller, so
# it is always there while it is installed and can be removed cleanly. Shared by
# the Cleaner and the Duplicate Finder, which both load this file. Each program
# calls Register-DRInstalledProduct on start; nothing here runs on load.

# DRDirect PC Cleaner Setup.exe lists both programs under this id. Never change it.
$script:DRSetupUninstallId = '{6E1C2F4A-7D3B-4F5E-9A21-D7C0E5B4A8F3}_is1'

function Get-DRProductListing {
    <# What each program lists, and what removing it may and may not delete. #>
    param([Parameter(Mandatory)] [ValidateSet('Cleaner', 'Duplicate Finder')] [string]$Product)
    if ($Product -eq 'Cleaner') {
        return [ordered]@{
            DisplayName    = 'DRDirect PC Cleaner'
            KeyName        = 'DRDirectPCCleaner'
            Folder         = 'DRDirect PC Cleaner'
            ExeLike        = 'DRDirect*.exe'
            ExeNotLike     = '*Duplicate*'
            RunningNames   = @('DRDirect PC Cleaner.exe')
            RunningCommand = @('{folder}\Scripts')
            # Removed by default. A folder is emptied except for anything in Keep.
            Remove         = @('Scripts', 'Logs', 'Uninstaller', 'check_status.json', 'lastupdatecheck.txt',
                               'uninstaller_window_size.txt')
            Keep           = @('Uninstaller\UndoBackups', 'Uninstaller\InstallLogs')
            ExtraOnTick    = @()
            RemovesText    = 'Its settings, logs and the DRDirect Uninstaller in {folder}'
            KeepsText      = "Your own files, browsers and logins are not touched. Your reports, licence and the Uninstaller's safe copies are kept unless you tick the box below."
            TickText       = 'Also delete my reports, licence and safe copies'
        }
    }
    return [ordered]@{
        DisplayName    = 'DRDirect Duplicate Finder'
        KeyName        = 'DRDirectDuplicateFinder'
        Folder         = 'DRDirect Duplicate Finder'
        ExeLike        = 'DRDirect*Duplicate*.exe'
        ExeNotLike     = '*Inner*'
        RunningNames   = @('DRDirect Duplicate Finder Inner.exe')
        RunningCommand = @('DRDirect Duplicate Finder.ps1')
        Remove         = @('*')
        Keep           = @()
        # Its licence lives in the Cleaner's folder: only that one file, and only when ticked.
        ExtraOnTick    = @('..\DRDirect PC Cleaner\licence_finder.dat')
        RemovesText    = 'Its logs in {folder}'
        KeepsText      = 'Your own files and any duplicates you kept are not touched, and neither is the DRDirect PC Cleaner. Your Duplicate Finder licence is kept unless you tick the box below.'
        TickText       = 'Also delete my Duplicate Finder licence'
    }
}

function Find-DRLauncherExe {
    <#
    .SYNOPSIS
        The exe the person actually opened: the launcher above this process.
    .DESCRIPTION
        The compiled app runs from a temporary _MEI folder that disappears, so the
        process tree is walked up to the first DRDirect exe outside it. $null when
        run from the project folder or a script, which has nothing to list.
    #>
    param([string]$Like, [string]$NotLike)
    try {
        $byId = @{}
        foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, ExecutablePath -ErrorAction Stop)) {
            $byId[[int]$p.ProcessId] = $p
        }
        $processId = $PID
        for ($depth = 0; $depth -lt 6 -and $byId.ContainsKey($processId); $depth++) {
            $processId = [int]$byId[$processId].ParentProcessId
            if (-not $byId.ContainsKey($processId)) { break }
            $candidate = [string]$byId[$processId].ExecutablePath
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            if ($candidate -match '\\_MEI\d+\\') { continue }
            $leaf = Split-Path -Leaf $candidate
            if ($leaf -like $Like -and -not ($NotLike -and $leaf -like $NotLike) -and
                    (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                return [IO.Path]::GetFullPath($candidate)
            }
        }
    } catch { }
    return $null
}

function Test-DRInstalledBySetup {
    <# True when this exe is the copy DRDirect PC Cleaner Setup.exe installed, which Setup already lists. #>
    param([Parameter(Mandatory)] [string]$ExePath)
    foreach ($key in @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$script:DRSetupUninstallId",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$script:DRSetupUninstallId",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$script:DRSetupUninstallId")) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $location = $null
        try { $location = [string](Get-ItemProperty -LiteralPath $key -Name 'InstallLocation' -ErrorAction Stop).InstallLocation } catch { }
        # Setup is there but does not say where: assume it covers this copy rather than list it twice
        if ([string]::IsNullOrWhiteSpace($location)) { return $true }
        try {
            $setupFolder = [IO.Path]::GetFullPath($location).TrimEnd('\') + '\'
            if ($ExePath.StartsWith($setupFolder, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        } catch { return $true }
    }
    return $false
}

function Register-DRInstalledProduct {
    <#
    .SYNOPSIS
        Adds or refreshes this program's entry in Windows' installed-programs list.
    .DESCRIPTION
        Writes to the person's own HKCU and LOCALAPPDATA. In the Cleaner the engine
        has already pointed both at the signed-in person, so with Administrator
        Protection the entry still lands in their list, not the hidden admin
        account's. Never throws: a failure here must not stop the program opening.
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('Cleaner', 'Duplicate Finder')] [string]$Product,
        [string]$Version
    )
    try {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return }
        $listing = Get-DRProductListing -Product $Product
        $folder = Join-Path $env:LOCALAPPDATA $listing.Folder
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $listing.KeyName
        $removerName = 'Remove ' + $listing.DisplayName
        $remover = Join-Path $folder ($removerName + '.ps1')
        $removerCmd = Join-Path $folder ($removerName + '.cmd')

        $exePath = Find-DRLauncherExe -Like $listing.ExeLike -NotLike $listing.ExeNotLike
        if (-not $exePath) { return }

        if (Test-DRInstalledBySetup -ExePath $exePath) {
            # Setup's own entry covers it; drop ours rather than show it twice
            if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
            foreach ($path in @($remover, $removerCmd)) {
                if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
            return
        }

        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
        }
        # The listing goes into the remover as JSON inside a single-quoted string
        $config = ([pscustomobject]$listing | ConvertTo-Json -Compress -Depth 4).Replace("'", "''")
        $removerScript = $script:DRRemoverTemplate.Replace('__DRDIRECT_LISTING__', $config)
        if (-not (Test-Path -LiteralPath $remover -PathType Leaf) -or [IO.File]::ReadAllText($remover) -ne $removerScript) {
            [IO.File]::WriteAllText($remover, $removerScript, (New-Object System.Text.UTF8Encoding($true)))
        }
        # Runs the remover with its window hidden. A plain .cmd keeps the list honest:
        # it carries no signature, so the entry is not shown as signed by Microsoft.
        # One line, so the .cmd never re-reads itself after it has been deleted.
        $removerCmdText = '@powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0' +
            $removerName + '.ps1" & exit /b' + "`r`n"
        if (-not (Test-Path -LiteralPath $removerCmd -PathType Leaf) -or [IO.File]::ReadAllText($removerCmd) -ne $removerCmdText) {
            [IO.File]::WriteAllText($removerCmd, $removerCmdText, [System.Text.Encoding]::ASCII)
        }

        if (-not $Version) {
            try {
                $installed = Get-DRInstalledVersion
                if ($installed -gt [version]'0.0.0') { $Version = "$installed" }
            } catch { }
        }

        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
        $values = [ordered]@{
            DisplayName     = $listing.DisplayName
            Publisher       = 'DRDirect Pro Tech'
            DisplayIcon     = "`"$exePath`",0"
            InstallLocation = $folder
            UninstallString = "`"$removerCmd`""
            DRDirectProgram = $exePath
        }
        if ($Version) { $values['DisplayVersion'] = $Version }
        foreach ($name in @($values.Keys)) {
            $current = $null
            try { $current = (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop).$name } catch { }
            if ($current -ne $values[$name]) {
                Set-ItemProperty -LiteralPath $key -Name $name -Value $values[$name] -Type String
            }
        }
        foreach ($name in @('NoModify', 'NoRepair')) {
            Set-ItemProperty -LiteralPath $key -Name $name -Value 1 -Type DWord
        }
    } catch { }
}

function Set-DRInstalledProductVersion {
    <# Keeps the listed version in step with the one the program shows. Only updates an existing entry. #>
    param([Parameter(Mandatory)] [ValidateSet('Cleaner', 'Duplicate Finder')] [string]$Product, [string]$Version)
    try {
        if (-not $Version) { return }
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + (Get-DRProductListing -Product $Product).KeyName
        if (Test-Path -LiteralPath $key) {
            Set-ItemProperty -LiteralPath $key -Name 'DisplayVersion' -Value $Version -Type String
        }
    } catch { }
}

# The remover written beside each listed program and started by Windows Settings >
# Apps or the DRDirect Uninstaller. Register-DRInstalledProduct fills in the listing.
$script:DRRemoverTemplate = @'
# Removes a DRDirect program from this PC. Nothing is deleted until the person confirms.
# -Unattended skips the questions; it exists only for testing in a temporary folder.
param([switch]$Unattended, [switch]$DeleteEverything)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$listing = '__DRDIRECT_LISTING__' | ConvertFrom-Json
$title = 'Remove ' + $listing.DisplayName
$keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $listing.KeyName

function Show-Message([string]$text, [string]$icon = 'Information', [string]$buttons = 'OK') {
    if ($Unattended) { Write-Output "[$icon] $text"; return 'OK' }
    return [Windows.Forms.MessageBox]::Show($text, $title, $buttons, $icon)
}

# Only ever the folder this remover sits in, and only when it is the program's own folder
$folder = $null
try { $folder = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') } catch { }
if (-not $folder -or (Split-Path -Leaf $folder) -ne $listing.Folder -or
        -not [IO.Path]::GetDirectoryName($folder) -or
        -not (Test-Path -LiteralPath (Join-Path $folder ($title + '.ps1')) -PathType Leaf)) {
    Show-Message 'The DRDirect folder is not where it should be, so nothing was removed.' 'Error' | Out-Null; exit 1
}

# The exe recorded when the program last started. Only that one file is removed,
# never the folder it sits in.
$exePath = $null
try { $exePath = [string](Get-ItemProperty -LiteralPath $keyPath -Name 'DRDirectProgram' -ErrorAction Stop).DRDirectProgram } catch { }
if ($exePath) {
    $exeOk = $false
    try {
        $exePath = [IO.Path]::GetFullPath($exePath)
        $leaf = Split-Path -Leaf $exePath
        $exeOk = (Test-Path -LiteralPath $exePath -PathType Leaf) -and ($leaf -like $listing.ExeLike) -and
                 -not ($listing.ExeNotLike -and $leaf -like $listing.ExeNotLike)
    } catch { }
    if (-not $exeOk) { $exePath = $null }
}

# Confirm first, and say exactly what goes and what stays
$form = New-Object Windows.Forms.Form
$form.Text = $title; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
$form.StartPosition = 'CenterScreen'; $form.Font = New-Object Drawing.Font('Segoe UI', 10); $form.AutoSize = $true
$form.AutoSizeMode = 'GrowAndShrink'; $form.Padding = New-Object Windows.Forms.Padding(16); $form.TopMost = $true
$layout = New-Object Windows.Forms.FlowLayoutPanel
$layout.FlowDirection = 'TopDown'; $layout.AutoSize = $true; $layout.WrapContents = $false
$label = New-Object Windows.Forms.Label
$label.AutoSize = $true; $label.MaximumSize = New-Object Drawing.Size(520, 0)
$what = "Remove $($listing.DisplayName) from this PC?`r`n`r`nThis removes:`r`n"
if ($exePath) { $what += "  - The program: $exePath`r`n" }
$what += '  - ' + $listing.RemovesText.Replace('{folder}', $folder) + "`r`n`r`n" + $listing.KeepsText
$label.Text = $what
$check = New-Object Windows.Forms.CheckBox
$check.AutoSize = $true; $check.Text = $listing.TickText; $check.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 12)
$buttons = New-Object Windows.Forms.FlowLayoutPanel
$buttons.AutoSize = $true; $buttons.FlowDirection = 'LeftToRight'
$ok = New-Object Windows.Forms.Button; $ok.Text = 'Remove'; $ok.AutoSize = $true; $ok.DialogResult = 'OK'
$cancel = New-Object Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.AutoSize = $true; $cancel.DialogResult = 'Cancel'
$buttons.Controls.AddRange(@($ok, $cancel))
$layout.Controls.AddRange(@($label, $check, $buttons))
$form.Controls.Add($layout); $form.AcceptButton = $cancel; $form.CancelButton = $cancel
if ($Unattended) {
    $deleteEverything = [bool]$DeleteEverything
} else {
    if ($form.ShowDialog() -ne 'OK') { exit 1602 }
    $deleteEverything = $check.Checked
}

# The program must be closed, or its files cannot be removed
$commandMarks = @($listing.RunningCommand | ForEach-Object { $_.Replace('{folder}', $folder) })
while ($true) {
    $running = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $process = $_
        $process.ProcessId -ne $PID -and (
            ($process.ExecutablePath -and $exePath -and [string]::Equals($process.ExecutablePath, $exePath, [StringComparison]::OrdinalIgnoreCase)) -or
            ($process.ExecutablePath -and $process.ExecutablePath.StartsWith($folder + '\', [StringComparison]::OrdinalIgnoreCase)) -or
            (@($listing.RunningNames) -contains $process.Name) -or
            ($process.CommandLine -and @($commandMarks | Where-Object { $process.CommandLine.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0))
    })
    if ($running.Count -eq 0) { break }
    if ($Unattended) { Write-Output "$($listing.DisplayName) is still running; nothing was removed."; exit 1 }
    $answer = Show-Message "Please close $($listing.DisplayName) and the DRDirect Uninstaller, then click Retry." 'Warning' 'RetryCancel'
    if ($answer -ne 'Retry') { exit 1602 }
}

$problems = New-Object Collections.Generic.List[string]
function Test-DRInside([string]$path) {
    $path -eq $folder -or $path.StartsWith($folder + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Remove-DRItem([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $full = [IO.Path]::GetFullPath($path)
    if (-not (Test-DRInside $full)) { return }   # never anything outside the program's folder
    try { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
    catch { $problems.Add($full) }
}
$keep = @($listing.Keep | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $folder $_)) })
function Remove-DRKeeping([string]$path) {
    # Removes a file or folder, but leaves anything in Keep (and the folders that lead to it)
    $full = [IO.Path]::GetFullPath($path)
    if ($keep -contains $full) { return }
    $holdsKept = @($keep | Where-Object { $_.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    if ($holdsKept -and (Test-Path -LiteralPath $full -PathType Container)) {
        foreach ($child in Get-ChildItem -LiteralPath $full -Force) { Remove-DRKeeping $child.FullName }
    } else {
        Remove-DRItem $full
    }
}

if ($deleteEverything) {
    Remove-DRItem $folder
    foreach ($extra in @($listing.ExtraOnTick)) {
        # Only a licence file in a sibling DRDirect folder, nothing wider
        try {
            $full = [IO.Path]::GetFullPath((Join-Path $folder $extra))
            if ([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($full)) -eq [IO.Path]::GetDirectoryName($folder) -and
                    (Split-Path -Leaf $full) -like 'licence*.dat' -and (Test-Path -LiteralPath $full -PathType Leaf)) {
                Remove-Item -LiteralPath $full -Force -ErrorAction Stop
            }
        } catch { $problems.Add($extra) }
    }
} else {
    foreach ($item in @($listing.Remove)) {
        if ($item -eq '*') {
            foreach ($child in Get-ChildItem -LiteralPath $folder -Force) { Remove-DRKeeping $child.FullName }
        } else {
            Remove-DRKeeping (Join-Path $folder $item)
        }
    }
    Remove-DRItem (Join-Path $folder ($title + '.cmd'))
    Remove-DRItem $PSCommandPath
    # Nothing kept in it: the folder itself goes too
    if ((Test-Path -LiteralPath $folder) -and @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0) { Remove-DRItem $folder }
}

# Shortcuts that point at the removed program would only lead nowhere
if ($exePath) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $places = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('StartMenu'),
                    [Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('CommonStartMenu')) |
                  Where-Object { $_ -and (Test-Path -LiteralPath $_) }
        foreach ($place in $places) {
            foreach ($link in Get-ChildItem -LiteralPath $place -Filter '*.lnk' -Recurse -Depth 2 -ErrorAction SilentlyContinue) {
                try {
                    if ([string]::Equals($shell.CreateShortcut($link.FullName).TargetPath, $exePath, [StringComparison]::OrdinalIgnoreCase)) {
                        Remove-Item -LiteralPath $link.FullName -Force -ErrorAction Stop
                    }
                } catch { }
            }
        }
    } catch { }

    try { Remove-Item -LiteralPath $exePath -Force -ErrorAction Stop }
    catch { $problems.Add($exePath) }
}

try { Remove-Item -LiteralPath $keyPath -Recurse -Force -ErrorAction Stop } catch { }

if ($problems.Count -gt 0) {
    Show-Message ("$($listing.DisplayName) was removed, but these could not be deleted. You can delete them yourself:`r`n`r`n" + ($problems -join "`r`n")) 'Warning' | Out-Null
} else {
    Show-Message "$($listing.DisplayName) has been removed from this PC." | Out-Null
}
exit 0
'@
