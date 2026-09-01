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
        # No credentials: the feed is public precisely so nothing has to be
        # embedded in the exe, where any recipient could extract it.
        $response = Invoke-WebRequest -Uri "$script:DRUpdateFeed/update_manifest.json" `
            -UseBasicParsing -TimeoutSec 15 -Headers @{ 'Cache-Control' = 'no-cache' }
        return $response.Content | ConvertFrom-Json
    } catch {
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
