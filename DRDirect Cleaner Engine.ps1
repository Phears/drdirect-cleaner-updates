# DRDirect Cleaner Engine
# Non-interactive maintenance functions used by the WPF application.
# Compatible with Windows PowerShell 5.1.

Set-StrictMode -Version 2.0

$script:DRAppName = 'DRDirect PC Cleaner'
$script:DRLogRoot = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Logs'
$script:DRReportRoot = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Reports'
# File Explorer's pinned Quick Access folders live in this jump list file.
$script:DRQuickAccessJumpList = 'f01b4d95cf55d32a.automaticDestinations-ms'

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
        [pscustomobject]@{ Id='cleanup.windows-temp'; Category='Cleanup'; Name='Windows temporary files'; Description='Removes temporary files no longer needed by Windows or applications.'; Risk='Safe'; Duration='1-5 min'; RequiresAdmin=$true; DefaultSelected=$true; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.browser-cache'; Category='Cleanup'; Name='Browser caches'; Description='Clears cache files while preserving passwords, bookmarks, cookies, and active sessions.'; Risk='Safe'; Duration='1-5 min'; RequiresAdmin=$false; DefaultSelected=$true; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.recycle-bin'; Category='Cleanup'; Name='Recycle Bin'; Description='Permanently removes Recycle Bin contents from available fixed drives.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.hidden-recycle-folders'; Category='Cleanup'; Name='Hidden Recycle Bin folders'; Description='Removes hidden $Recycle.Bin folders from fixed drives so Windows can rebuild them.'; Risk='Advanced'; Duration='< 5 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.cookies'; Category='Cleanup'; Name='Cookies and website storage'; Description='Clears cookies and site storage. This can sign you out of websites and webmail.'; Risk='SignOut'; Duration='1-5 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.prefetch'; Category='Cleanup'; Name='Windows Prefetch'; Description='Clears the Prefetch cache. Windows rebuilds it and app launches may initially be slower.'; Risk='Advanced'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.wu-download-cache'; Category='Cleanup'; Name='Windows Update download cache'; Description='Clears already-installed update installers cached under SoftwareDistribution\Download. Windows re-downloads only what it needs next time.'; Risk='Safe'; Duration='1-5 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.old-update-backups'; Category='Cleanup'; Name='Old Windows Update backup folders'; Description='Removes SoftwareDistribution.old and catroot2.old, copies left behind by an earlier Windows Update fix. Windows no longer uses them. The Windows Update folders in use are never touched.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.thumbnail-cache'; Category='Cleanup'; Name='Thumbnail cache'; Description='Clears cached thumbnail images. Windows rebuilds them the next time you browse those files.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.shader-cache'; Category='Cleanup'; Name='Graphics shader cache'; Description='Clears saved graphics files from DirectX and the NVIDIA, AMD and Intel drivers. Games rebuild them by themselves, so the first launch afterwards can be choppy for a few seconds.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.icon-cache'; Category='Cleanup'; Name='Icon cache'; Description='Clears the icon cache and restarts Explorer to rebuild it. Fixes blank or wrong icons. The taskbar and desktop will flash off and back on and open folder windows will close. Do not run it while File Explorer is copying or moving files.'; Risk='Advanced'; Duration='< 2 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.wer-queue'; Category='Cleanup'; Name='Windows Error Reporting queue'; Description='Removes queued and archived crash reports waiting to be sent to Microsoft.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.delivery-optimization-cache'; Category='Cleanup'; Name='Delivery Optimization cache'; Description='Clears the peer-to-peer Windows Update cache. Windows rebuilds it as needed.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.jumplists'; Category='Cleanup'; Name='Jump lists and recent items'; Description='Clears taskbar jump lists and the Recent Items list. Files you pinned inside an app''s jump list are removed too. Taskbar icons and Quick Access folders are kept.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.memory-dumps'; Category='Cleanup'; Name='Memory dump files'; Description='Removes saved crash dump files (Memory.dmp and Minidump). These are only useful for diagnosing a specific past crash.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.old-restore-points'; Category='Cleanup'; Name='Old restore points'; Description='Deletes older System Restore snapshots, keeping only the most recent one. Reduces how far back you can roll back Windows.'; Risk='Advanced'; Duration='< 5 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.event-logs'; Category='Cleanup'; Name='Windows Event Logs'; Description='Clears the Application and System event logs. Removes diagnostic history used for troubleshooting. The Security log is never touched.'; Risk='Advanced'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='cleanup.cloud-icloud'; Category='Cleanup'; Name='iCloud cache'; Description='Clears the local cache and logs iCloud leaves on this PC. Your synced files are not touched.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$false; DefaultSelected=$true; SupportsAnalysis=$true; Destructive=$true; Interruptible=$false; CloudService='iCloud' }
        [pscustomobject]@{ Id='cleanup.cloud-google'; Category='Cleanup'; Name='Google Drive cache'; Description='Clears the local cache and logs Google Drive leaves on this PC. Your synced files are not touched.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$false; DefaultSelected=$true; SupportsAnalysis=$true; Destructive=$true; Interruptible=$false; CloudService='Google Drive' }
        [pscustomobject]@{ Id='cleanup.cloud-onedrive'; Category='Cleanup'; Name='OneDrive cache'; Description='Clears the local cache and logs OneDrive leaves on this PC. Your synced files are not touched.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$false; DefaultSelected=$true; SupportsAnalysis=$true; Destructive=$true; Interruptible=$false; CloudService='OneDrive' }
        [pscustomobject]@{ Id='cleanup.cloud-dropbox'; Category='Cleanup'; Name='Dropbox cache'; Description='Clears the local cache and logs Dropbox leaves on this PC. Your synced files are not touched.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$false; DefaultSelected=$true; SupportsAnalysis=$true; Destructive=$true; Interruptible=$false; CloudService='Dropbox' }
        [pscustomobject]@{ Id='cleanup.cloud-mega'; Category='Cleanup'; Name='MEGA cache'; Description='Clears the local cache and logs MEGA leaves on this PC. Your synced files are not touched.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$false; DefaultSelected=$true; SupportsAnalysis=$true; Destructive=$true; Interruptible=$false; CloudService='MEGA' }

        [pscustomobject]@{ Id='cleanup.disk-cleanup'; Category='Cleanup'; Name='Windows Disk Cleanup'; Description='Runs the Windows Disk Cleanup profile for the C: drive.'; Risk='Safe'; Duration='1-10 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$true ; CloudService=$null }

        [pscustomobject]@{ Id='repair.restore-point'; Category='Repair'; Name='Create restore point'; Description='Creates a Windows restore point before repair operations when System Protection is available.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$true; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='repair.dism-health'; Category='Repair'; Name='DISM RestoreHealth'; Description='Repairs the Windows component store using DISM RestoreHealth.'; Risk='Repair'; Duration='20-60 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='repair.component-cleanup'; Category='Repair'; Name='DISM component cleanup'; Description='Removes superseded Windows component versions.'; Risk='Repair'; Duration='10-30 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='repair.sfc'; Category='Repair'; Name='System File Checker'; Description='Scans protected Windows files and repairs damaged copies.'; Risk='Repair'; Duration='10-30 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='repair.windows-update'; Category='Repair'; Name='Windows Update repair'; Description='Resets Windows Update services, caches, Winsock, and the WinHTTP proxy.'; Risk='Advanced'; Duration='5-15 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='repair.network-reset'; Category='Repair'; Name='Network reset'; Description='Flushes the DNS cache, releases and renews the IP address, resets Winsock, the TCP/IP stack, and the WinHTTP proxy, restores TCP auto-tuning to normal, disables TCP heuristics, and clears the ARP cache. The connection drops briefly during renew, a restart is required afterward, and any static IP or manual DNS configuration may need to be re-entered.'; Risk='Advanced'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }

        [pscustomobject]@{ Id='security.checkup'; Category='Security'; Name='Security checkup'; Description='Checks that the firewall, virus protection and Windows Update are all switched on. It only looks - nothing is changed.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='security.checkup-fix'; Category='Security'; Name='Turn protection back on'; Description='Switches the Windows firewall, Microsoft Defender real-time protection and Windows Update back on if any of them are off. When another antivirus or firewall is in charge, that part is left alone.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='security.defender-update'; Category='Security'; Name='Update Defender intelligence'; Description='Downloads the latest available Microsoft Defender security intelligence.'; Risk='Safe'; Duration='1-5 min'; RequiresAdmin=$true; DefaultSelected=$true; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='security.quick-scan'; Category='Security'; Name='Defender quick scan'; Description='Scans common threat locations without changing exclusions.'; Risk='Safe'; Duration='5-20 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$true ; CloudService=$null }
        [pscustomobject]@{ Id='security.full-scan'; Category='Security'; Name='Defender full scan'; Description='Scans all accessible files. This may take several hours.'; Risk='Long'; Duration='1+ hours'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$true ; CloudService=$null }
        [pscustomobject]@{ Id='security.remove-exclusions'; Category='Security'; Name='Remove Defender exclusions'; Description='Exports and removes all configured Defender exclusions. Never runs automatically.'; Risk='Advanced'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$true; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='security.network-files'; Category='Security'; Name='Enable network-file scanning'; Description='Enables Microsoft Defender scanning of files accessed over the network.'; Risk='Advanced'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='security.typing-privacy'; Category='Security'; Name='Stop sending typing data to Microsoft'; Description='Turns off "Improve inking and typing" and typing personalization, so Windows stops collecting what you type and write to tune its suggestions. Your current settings are saved first, and "Restore typing settings" puts them back.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='security.typing-privacy-restore'; Category='Security'; Name='Restore typing settings'; Description='Puts the typing settings back exactly as they were before "Stop sending typing data to Microsoft" changed them. Does nothing if that option was never run.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }

        [pscustomobject]@{ Id='health.chkdsk'; Category='Health'; Name='CHKDSK disk check'; Description='Checks the C: file system for corruption while Windows keeps running. Reports what it finds, repairs what is safe to repair, and never schedules a restart.'; Risk='Safe'; Duration='5-30 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$true ; CloudService=$null }
        [pscustomobject]@{ Id='health.drive-check'; Category='Health'; Name='Drive health check'; Description='Reads the health information your drives report about themselves, including estimated life left and read errors. Nothing is changed or deleted.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }

        # AI Remover. Nothing here is ever pre-selected or part of a cleanup level.
        [pscustomobject]@{ Id='ai.check'; Category='AI'; Name='What AI is on this PC?'; Description='Only looks - nothing is changed. Click Check now and the AI still switched on or installed is listed right here - handy after a Windows or browser update brings something back.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.windows'; Category='AI'; Name='Windows: turn off Recall and AI in Paint and Notepad'; Description='Switches off Recall (the snapshots of your screen), Click to Do, and the AI tools in Paint and Notepad. Takes effect after the restart. "Turn back on" undoes it.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.copilot-key'; Category='AI'; Name='Copilot key: open Search instead'; Description='Opens the Settings page for the Copilot key on the keyboard (also Windows key + C): under "Customize Copilot key on keyboard", choose Search. Windows keeps this choice to itself, so the last click is yours.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.copilot-app'; Category='AI'; Name='Windows: remove the Copilot app'; Description='Uninstalls the Microsoft Copilot app for every account on this PC. It can be installed again from the Microsoft Store.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.m365-app'; Category='AI'; Name='Windows: remove the Microsoft 365 Copilot app'; Description='Uninstalls the Microsoft 365 Copilot app (the Copilot chat and Office start page). Word, Excel, Outlook and your documents are not touched. It can be installed again from the Microsoft Store.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.office-copilot'; Category='AI'; Name='Word and Excel: turn off Copilot'; Description='Opens Word so you can switch Copilot off: File > Options > Copilot, untick Enable Copilot, then OK. Do the same in Excel and PowerPoint. Office keeps this switch inside each app, so the last click is yours.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.zoom'; Category='AI'; Name='Zoom: turn off AI Companion'; Description='Opens Zoom so you can switch its AI off: Settings > General > AI > Manage, then untick Auto-start questions, Auto-generate transcripts, Auto-start notes and Use transcript to enrich notes, and click Update on each page. Zoom keeps this switch in the app and your Zoom account, so the last click is yours.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.edge'; Category='AI'; Name='Edge: turn off Copilot'; Description='Turns off the Copilot sidebar, Copilot reading the page, Copilot on the new tab page, and AI writing help. Passwords, bookmarks and sign-ins are not touched. Edge will show "Managed by your organization" while this is on.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.edge-button'; Category='AI'; Name='Edge: hide the Copilot button'; Description='Opens Edge so you can switch off the Copilot button on the toolbar: Settings, search for Copilot, switch the button off. The newest Edge keeps this switch to itself, so the last click is yours.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.chrome'; Category='AI'; Name='Chrome: turn off Gemini and AI Mode'; Description='Turns off Gemini in Chrome, the AI Mode button, "Help me write", and the AI tab and history features. Passwords, bookmarks and sign-ins are not touched. Chrome will show "Managed by your organization" while this is on.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.brave'; Category='AI'; Name='Brave: turn off Leo AI'; Description='Turns off Leo, the AI assistant built into Brave. Passwords, bookmarks and sign-ins are not touched. Brave will show "Managed by your organization" while this is on.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.firefox'; Category='AI'; Name='Firefox: turn off AI'; Description='Turns off the AI chatbot sidebar, AI link previews and AI tab groups. Passwords, bookmarks and sign-ins are not touched. Firefox settings will say the browser is managed by your organization while this is on.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.remove-models'; Category='AI'; Name='Delete downloaded AI models'; Description='Deletes the AI model Chrome and Edge download in the background - often 2 to 4 GB. Close the browser first, and also pick "Turn off" on the Chrome or Edge row, or the browser downloads it again. Only browsers that are signed in are changed.'; Risk='Cleanup'; Duration='< 2 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.block-sites'; Category='AI'; Name='Block AI websites'; Description='Blocks the ChatGPT, Gemini, Copilot, Perplexity, DeepSeek, Grok and Meta AI websites in Edge, Chrome, Brave and Firefox. Claude is left open. Only browsers that are signed in are changed (Brave has no sign-in). The browsers will show "Managed by your organization" while this is on.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.adobe'; Category='AI'; Name='Adobe Acrobat: turn off AI Assistant'; Description='Turns off the AI Assistant and generative AI features in Adobe Acrobat and Acrobat Reader. Only shown when Adobe Acrobat or Reader is installed. Your PDFs and Adobe sign-in are not touched. Close and reopen Acrobat afterwards. Acrobat may show that some settings are managed by your organization while this is on.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.search'; Category='AI'; Name='Windows Search: turn off web and Bing results'; Description='Stops the Start menu search box from sending what you type to Bing and showing web and AI results. Searching your own files and apps still works. Takes effect after you sign out and back in.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.gmail'; Category='AI'; Name='Gmail: turn off Gemini'; Description='Opens Gmail settings in the web browser: untick the Smart features boxes and click Save changes. Google keeps this switch in the Google account, so the last click is yours.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.chatgpt-app'; Category='AI'; Name='Remove the ChatGPT app'; Description='Uninstalls the ChatGPT app. Chats saved in the ChatGPT account are not deleted, and the app can be installed again.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.claude-app'; Category='AI'; Name='Remove the Claude app'; Description='Uninstalls the Claude app. Chats saved in the Claude account are not deleted, and the app can be installed again.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        # The "Turn back on" choice of each row above. Shown inside its row, never as a row of its own.
        [pscustomobject]@{ Id='ai.windows.on'; Category='AI'; Name='Windows: turn Recall and the AI in Paint and Notepad back on'; Description='Puts the Windows AI settings back exactly as they were.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.copilot-key.on'; Category='AI'; Name='Copilot key: open Copilot again'; Description='Opens the Settings page for the Copilot key so you can choose Copilot again.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.copilot-app.on'; Category='AI'; Name='Reinstall the Copilot app'; Description='Opens the Copilot app in the Microsoft Store so you can install it again.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.m365-app.on'; Category='AI'; Name='Reinstall the Microsoft 365 Copilot app'; Description='Opens the Microsoft 365 Copilot app in the Microsoft Store so you can install it again.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.office-copilot.on'; Category='AI'; Name='Word and Excel: turn Copilot back on'; Description='Opens Word so you can tick Enable Copilot again.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.zoom.on'; Category='AI'; Name='Zoom: turn AI Companion back on'; Description='Opens Zoom so you can switch AI Companion back on.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.edge.on'; Category='AI'; Name='Edge: turn Copilot back on'; Description='Puts the Edge AI settings back exactly as they were.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.edge-button.on'; Category='AI'; Name='Edge: show the Copilot button again'; Description='Opens Edge so you can switch the Copilot button back on.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.chrome.on'; Category='AI'; Name='Chrome: turn Gemini and AI Mode back on'; Description='Puts the Chrome AI settings back exactly as they were.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.brave.on'; Category='AI'; Name='Brave: turn Leo AI back on'; Description='Puts the Brave AI settings back exactly as they were.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.firefox.on'; Category='AI'; Name='Firefox: turn AI back on'; Description='Puts the Firefox AI settings back exactly as they were.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.block-sites.on'; Category='AI'; Name='Unblock AI websites'; Description='Takes out only the AI websites the Cleaner blocked.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.adobe.on'; Category='AI'; Name='Adobe Acrobat: turn AI Assistant back on'; Description='Puts the Adobe Acrobat AI settings back exactly as they were.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.search.on'; Category='AI'; Name='Windows Search: turn web and Bing results back on'; Description='Puts the Start menu search settings back exactly as they were.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.gmail.on'; Category='AI'; Name='Gmail: turn Gemini back on'; Description='Opens Gmail settings so you can tick Smart features again.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.chatgpt-app.on'; Category='AI'; Name='Reinstall the ChatGPT app'; Description='Opens the official ChatGPT download page.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.windows.uninstall'; Category='AI'; Name='Windows: uninstall Recall completely'; Description='Removes the Recall feature from Windows altogether. Takes effect after a restart.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.copilot-app.uninstall'; Category='AI'; Name='Copilot app: uninstall completely'; Description='Removes the Copilot app for every account and stops Windows adding it to new accounts.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.m365-app.uninstall'; Category='AI'; Name='Microsoft 365 Copilot app: uninstall completely'; Description='Removes the Microsoft 365 Copilot app for every account. Word, Excel and your documents are not touched.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.chatgpt-app.uninstall'; Category='AI'; Name='ChatGPT app: uninstall completely'; Description='Removes the ChatGPT app, including a regular installed copy. Chats saved in the account are not deleted.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.claude-app.uninstall'; Category='AI'; Name='Claude app: uninstall completely'; Description='Removes the Claude app, including a regular installed copy. Chats saved in the account are not deleted.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.edge.uninstall'; Category='AI'; Name='Edge: uninstall completely'; Description='Windows does not allow Edge to be uninstalled.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.chrome.uninstall'; Category='AI'; Name='Chrome: uninstall completely'; Description='Uninstalls Chrome from this PC. Bookmarks and passwords stay in your Google account.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.brave.uninstall'; Category='AI'; Name='Brave: uninstall completely'; Description='Uninstalls Brave from this PC.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.firefox.uninstall'; Category='AI'; Name='Firefox: uninstall completely'; Description='Uninstalls Firefox from this PC. Bookmarks and passwords stay in your Mozilla account.'; Risk='Confirm'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$true ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.windows.reinstall'; Category='AI'; Name='Windows: put Recall back'; Description='Installs the Recall feature in Windows again. Takes effect after a restart.'; Risk='Safe'; Duration='< 2 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.chrome.reinstall'; Category='AI'; Name='Reinstall Chrome'; Description='Opens the official Chrome download page.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.brave.reinstall'; Category='AI'; Name='Reinstall Brave'; Description='Opens the official Brave download page.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.firefox.reinstall'; Category='AI'; Name='Reinstall Firefox'; Description='Opens the official Firefox download page.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.claude-app.on'; Category='AI'; Name='Reinstall the Claude app'; Description='Opens the official Claude download page.'; Risk='Guided'; Duration='< 1 min'; RequiresAdmin=$false; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
        [pscustomobject]@{ Id='ai.restore'; Category='AI'; Name='Turn everything back on'; Description='Turns every Windows and browser AI setting and website block on this page back on, exactly as it was before, and the "Managed by your organization" message goes away. Apps, and the switches in Gmail, Word, Edge and the Copilot key, come back with their own "Reinstall" or "Turn back on" button.'; Risk='Safe'; Duration='< 1 min'; RequiresAdmin=$true; DefaultSelected=$false; SupportsAnalysis=$false; Destructive=$false ; Interruptible=$false ; CloudService=$null }
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

function Get-DRCloudCachePatterns {
    <#
        .SYNOPSIS
            Where each cloud client keeps throwaway data on this PC.
        .DESCRIPTION
            Caches, logs and the client's own deleted-file staging areas. None of
            it is a synced file: the services rebuild all of it, and nothing here
            is removed from anyone's account or their other devices.
    #>
    param([string]$Service)

    switch ($Service) {
        'iCloud' { @(
            "$env:LOCALAPPDATA\Apple Inc\iCloud\Logs",
            "$env:LOCALAPPDATA\Apple Computer\Logs",
            "$env:LOCALAPPDATA\Apple Inc\CloudKit\Caches"
        ) }
        'Google Drive' { @(
            "$env:LOCALAPPDATA\Google\DriveFS\*\content_cache",
            "$env:LOCALAPPDATA\Google\DriveFS\Logs"
        ) }
        'OneDrive' { @(
            "$env:LOCALAPPDATA\Microsoft\OneDrive\logs",
            "$env:LOCALAPPDATA\Microsoft\OneDrive\setup\logs"
        ) }
        'Dropbox' { @(
            "$env:LOCALAPPDATA\Dropbox\logs",
            "$env:USERPROFILE\Dropbox\.dropbox.cache"
        ) }
        'MEGA' { @(
            "$env:LOCALAPPDATA\Mega Limited\MEGAsync\logs",
            "$env:USERPROFILE\MEGA\.debris"
        ) }
        default { @() }
    }
}

function Get-DRShaderCachePaths {
    <#
        .SYNOPSIS
            Where DirectX and the graphics drivers keep compiled shaders.
        .DESCRIPTION
            Every one of these is rebuilt on demand the next time a game or app
            draws with it. Newer NVIDIA drivers moved theirs to LocalLow.
    #>
    $localLow = Join-Path (Split-Path -Parent $env:LOCALAPPDATA) 'LocalLow'
    @(
        (Join-Path $env:LOCALAPPDATA 'D3DSCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
        (Join-Path $localLow 'NVIDIA\PerDriverVersion\DXCache'),
        (Join-Path $localLow 'NVIDIA\PerDriverVersion\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxcCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\VkCache'),
        (Join-Path $env:LOCALAPPDATA 'Intel\ShaderCache')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
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

function Get-DROldUpdateBackupFolders {
    <#
        .SYNOPSIS
            Copies of the Windows Update folders left behind by an earlier reset.
        .DESCRIPTION
            The usual Windows Update fix renames SoftwareDistribution and catroot2
            to .old or .bak so Windows builds fresh ones, and nothing reads the
            renamed copies again. Only these exact names count: the folders in use
            and every other .old item are never returned. Links are skipped so a
            junction can never carry the delete somewhere else.
    #>
    param([string]$WindowsDir = $env:WINDIR)

    $system32 = Join-Path $WindowsDir 'System32'
    $candidates = @(
        @{ Root = $WindowsDir; Name = 'SoftwareDistribution.old' },
        @{ Root = $WindowsDir; Name = 'SoftwareDistribution.bak' },
        @{ Root = $system32;   Name = 'catroot2.old' },
        @{ Root = $system32;   Name = 'catroot2.bak' }
    )
    foreach ($candidate in $candidates) {
        $item = Get-Item -LiteralPath (Join-Path $candidate.Root $candidate.Name) -Force -ErrorAction SilentlyContinue
        if (-not $item -or -not $item.PSIsContainer) { continue }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        [pscustomobject]@{ Path = $item.FullName; AllowedRoot = $candidate.Root }
    }
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
                'cleanup.cloud-icloud' {
                    $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot) } else { @(Get-DRPatternMatches (Get-DRCloudCachePatterns 'iCloud')) }
                    foreach ($match in $matches) { $bytes += Get-DRPathSize $match.FullName; $items++ }
                    $detail = 'Cache and logs only; synced files are not touched'
                }
                'cleanup.cloud-google' {
                    $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot) } else { @(Get-DRPatternMatches (Get-DRCloudCachePatterns 'Google Drive')) }
                    foreach ($match in $matches) { $bytes += Get-DRPathSize $match.FullName; $items++ }
                    $detail = 'Cache and logs only; synced files are not touched'
                }
                'cleanup.cloud-onedrive' {
                    $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot) } else { @(Get-DRPatternMatches (Get-DRCloudCachePatterns 'OneDrive')) }
                    foreach ($match in $matches) { $bytes += Get-DRPathSize $match.FullName; $items++ }
                    $detail = 'Cache and logs only; synced files are not touched'
                }
                'cleanup.cloud-dropbox' {
                    $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot) } else { @(Get-DRPatternMatches (Get-DRCloudCachePatterns 'Dropbox')) }
                    foreach ($match in $matches) { $bytes += Get-DRPathSize $match.FullName; $items++ }
                    $detail = 'Cache and logs only; synced files are not touched'
                }
                'cleanup.cloud-mega' {
                    $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot) } else { @(Get-DRPatternMatches (Get-DRCloudCachePatterns 'MEGA')) }
                    foreach ($match in $matches) { $bytes += Get-DRPathSize $match.FullName; $items++ }
                    $detail = 'Cache and logs only; synced files are not touched'
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
                'cleanup.wu-download-cache' {
                    $path = if ($TestRoot) { $TestRoot } else { Join-Path $env:WINDIR 'SoftwareDistribution\Download' }
                    $bytes = Get-DRPathSize $path; $items = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue).Count
                    $detail = 'Already-installed update installers'
                }
                'cleanup.old-update-backups' {
                    $windowsDir = if ($TestRoot) { $TestRoot } else { $env:WINDIR }
                    foreach ($folder in @(Get-DROldUpdateBackupFolders -WindowsDir $windowsDir)) { $bytes += Get-DRPathSize $folder.Path; $items++ }
                    $detail = 'Left behind by an earlier Windows Update fix'
                }
                'cleanup.thumbnail-cache' {
                    $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot -ErrorAction SilentlyContinue) } else { @(Get-DRPatternMatches @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer\thumbcache_*.db'))) }
                    foreach ($match in $matches) { $bytes += Get-DRPathSize $match.FullName; $items++ }
                    $detail = 'Rebuilt automatically as you browse files'
                }
                'cleanup.shader-cache' {
                    $paths = if ($TestRoot) { @($TestRoot) } else { @(Get-DRShaderCachePaths) }
                    foreach ($path in $paths) { $bytes += Get-DRPathSize $path; $items += @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue).Count }
                    $detail = 'Games rebuild these by themselves'
                }
                'cleanup.icon-cache' {
                    $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot -ErrorAction SilentlyContinue) } else { @(Get-DRPatternMatches @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer\iconcache_*.db'))) }
                    foreach ($match in $matches) { $bytes += Get-DRPathSize $match.FullName; $items++ }
                    $detail = 'Advanced; Explorer restarts to rebuild it'
                }
                'cleanup.wer-queue' {
                    $paths = if ($TestRoot) { @($TestRoot) } else { @((Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'), (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')) }
                    foreach ($path in $paths) { $bytes += Get-DRPathSize $path; $items += @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue).Count }
                    $detail = 'Queued and archived crash reports'
                }
                'cleanup.jumplists' {
                    $paths = if ($TestRoot) { @($TestRoot) } else { @((Join-Path $env:APPDATA 'Microsoft\Windows\Recent\AutomaticDestinations'), (Join-Path $env:APPDATA 'Microsoft\Windows\Recent\CustomDestinations')) }
                    foreach ($path in $paths) {
                        foreach ($item in @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Where-Object Name -ne $script:DRQuickAccessJumpList)) { $bytes += Get-DRPathSize $item.FullName; $items++ }
                    }
                    $detail = 'Taskbar jump lists and Recent Items'
                }
                'cleanup.memory-dumps' {
                    $paths = if ($TestRoot) { @($TestRoot) } else { @((Join-Path $env:WINDIR 'Memory.dmp'), (Join-Path $env:WINDIR 'Minidump')) }
                    foreach ($path in $paths) {
                        $bytes += Get-DRPathSize $path
                        if (Test-Path -LiteralPath $path -PathType Container) { $items += @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue).Count }
                        elseif (Test-Path -LiteralPath $path) { $items++ }
                    }
                    $detail = 'Only useful for diagnosing a specific past crash'
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

function Get-DRBatteryHealth {
    <#
        .SYNOPSIS
            How much charge each laptop battery holds now, against when it was new.
        .DESCRIPTION
            Read-only. Windows keeps the designed and the current full-charge
            capacity in root\wmi. A PC with no battery returns nothing, so the
            Hardware page shows no battery section on a desktop.
    #>
    if (-not @(Get-DRCimValue 'Win32_Battery').Count) { return }

    $static = @(); $full = @(); $cycles = @()
    try { $static = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'BatteryStaticData' -ErrorAction Stop) } catch { }
    try { $full = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'BatteryFullChargedCapacity' -ErrorAction Stop) } catch { }
    try { $cycles = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'BatteryCycleCount' -ErrorAction Stop) } catch { }

    $reported = 0
    foreach ($entry in $static) {
        $instance = Get-DRDiskProperty $entry 'InstanceName'
        $design = Get-DRDiskProperty $entry 'DesignedCapacity'
        $now = Get-DRDiskProperty (@($full | Where-Object { (Get-DRDiskProperty $_ 'InstanceName') -eq $instance }) | Select-Object -First 1) 'FullChargedCapacity'
        $count = Get-DRDiskProperty (@($cycles | Where-Object { (Get-DRDiskProperty $_ 'InstanceName') -eq $instance }) | Select-Object -First 1) 'CycleCount'
        if (-not $design -or -not $now) { continue }

        # A new battery can hold slightly more than its rating; call that 100%.
        $percent = [int][Math]::Min(100, [Math]::Round(100.0 * $now / $design))
        $verdict = if ($percent -ge 80) { 'good' }
                   elseif ($percent -ge 60) { 'worn - it runs out sooner than when new' }
                   else { 'worn out - consider replacing the battery' }
        $note = '{0:N0} of {1:N0} mWh' -f $now, $design
        if ($count) { $note = '{0}, {1:N0} charge cycles' -f $note, $count }
        $reported++
        [pscustomobject]@{ Value = ('{0}% of its original capacity' -f $percent); Note = ('{0} - {1}' -f $note, $verdict) }
    }
    if (-not $reported) {
        [pscustomobject]@{ Value = 'Not reported'; Note = 'This battery does not tell Windows how worn it is.' }
    }
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

    # Battery - laptops only
    foreach ($battery in @(Get-DRBatteryHealth)) {
        $items.Add((New-DRHardwareItem 'Battery' 'Battery health' $battery.Value $battery.Note))
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

function Get-DRSecurityCenterProducts {
    # Other security products that told Windows Security Center they are switched
    # on. Microsoft Defender registers there too, so it is left out by name.
    param([ValidateSet('AntiVirusProduct','FirewallProduct')][string]$Kind)
    $products = @()
    try { $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName $Kind -ErrorAction Stop) } catch { return }
    foreach ($product in $products) {
        $name = Get-DRDiskProperty $product 'displayName'
        $state = Get-DRDiskProperty $product 'productState'
        if (-not $name -or $name -match 'Defender') { continue }
        # Bit 12 of productState is Security Center's "switched on" flag.
        if ($null -ne $state -and ([int64]$state -band 0x1000)) { $name }
    }
}

function Get-DRFirewallOffProfiles {
    # The network types (Domain, Private, Public) the Windows firewall is off for.
    Get-NetFirewallProfile -ErrorAction Stop | Where-Object { "$($_.Enabled)" -ne 'True' } | ForEach-Object { [string]$_.Name }
}

function Test-DRDefenderRealtimeOn {
    # $true or $false, or $null when Defender cannot be asked at all.
    try { return [bool](Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch { return $null }
}

function Get-DRWindowsUpdateState {
    $service = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -ErrorAction SilentlyContinue
    $last = $null
    try {
        $newest = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($newest) { $last = [datetime]$newest.InstalledOn }
    } catch { }
    [pscustomobject]@{
        ServiceDisabled = [bool]($service -and "$($service.StartType)" -eq 'Disabled')
        PolicyOff       = [bool]($policy -and $policy.NoAutoUpdate -eq 1)
        LastInstalled   = $last
    }
}

function Enable-DRFirewallProfiles {
    param([string[]]$Profiles)
    Set-NetFirewallProfile -Profile $Profiles -Enabled True -ErrorAction Stop
}

function Enable-DRDefenderRealtime {
    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
}

function Enable-DRWindowsUpdateService {
    # Manual is Windows' own setting for this service: it starts whenever an
    # update check needs it.
    Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop
}

function Get-DRSecurityStatus {
    <#
        .SYNOPSIS
            Read-only: whether the firewall, virus protection and Windows Update are on.
        .DESCRIPTION
            When another product registered with Windows Security Center does a
            job, the Windows part being off is how it should be, so that counts as
            on and is never "fixed". Only Fixable rows are ever switched back on.
    #>
    $otherAv = @(Get-DRSecurityCenterProducts -Kind AntiVirusProduct)
    $otherFw = @(Get-DRSecurityCenterProducts -Kind FirewallProduct)
    $row = { param($Area, $Label, $Ok, $Fixable, $Message, $Detail)
        [pscustomobject]@{ Area = $Area; Label = $Label; Ok = [bool]$Ok; Fixable = [bool]$Fixable; Message = $Message; Detail = $Detail } }

    $firewall = 'The Windows firewall'
    $offProfiles = @(); $firewallKnown = $true
    try { $offProfiles = @(Get-DRFirewallOffProfiles) } catch { $firewallKnown = $false }
    if ($otherFw.Count) { & $row 'Firewall' $firewall $true $false ('Firewall: {0} is protecting this PC.' -f ($otherFw -join ', ')) $null }
    elseif (-not $firewallKnown) { & $row 'Firewall' $firewall $false $false 'Firewall: Windows did not report whether its firewall is on.' $null }
    elseif ($offProfiles.Count) { & $row 'Firewall' $firewall $false $true ('Firewall: OFF for {0} networks.' -f ($offProfiles -join ', ')) $offProfiles }
    else { & $row 'Firewall' $firewall $true $false 'Firewall: on for all networks.' $null }

    $defender = 'Microsoft Defender real-time protection'
    if ($otherAv.Count) { & $row 'Virus' $defender $true $false ('Virus protection: {0} is protecting this PC.' -f ($otherAv -join ', ')) $null }
    else {
        $realtime = Test-DRDefenderRealtimeOn
        if ($realtime -eq $true) { & $row 'Virus' $defender $true $false 'Virus protection: Microsoft Defender real-time protection is on.' $null }
        elseif ($realtime -eq $false) { & $row 'Virus' $defender $false $true 'Virus protection: Microsoft Defender real-time protection is OFF.' $null }
        else { & $row 'Virus' $defender $false $false 'Virus protection: no active antivirus was found on this PC.' $null }
    }

    $update = Get-DRWindowsUpdateState
    $days = if ($update.LastInstalled) { [int]((Get-Date) - $update.LastInstalled).TotalDays } else { $null }
    if ($update.ServiceDisabled) { & $row 'Update' 'Windows Update' $false $true 'Windows Update: switched OFF, so this PC is not getting security fixes.' $null }
    elseif ($update.PolicyOff) { & $row 'Update' 'Windows Update' $false $false 'Windows Update: automatic updates are turned off by a policy setting. The Cleaner does not change policies.' $null }
    elseif ($null -ne $days -and $days -gt 60) { & $row 'Update' 'Windows Update' $false $false ('Windows Update: on, but the last update was installed {0} days ago. Open Settings > Windows Update and install what is waiting.' -f $days) $null }
    elseif ($update.LastInstalled) { & $row 'Update' 'Windows Update' $true $false ('Windows Update: on. Last update installed {0}.' -f $update.LastInstalled.ToString('d MMMM yyyy')) $null }
    else { & $row 'Update' 'Windows Update' $true $false 'Windows Update: on.' $null }
}

function Repair-DRSecurityProtection {
    param([string]$TaskId)

    $toFix = @(Get-DRSecurityStatus | Where-Object { -not $_.Ok -and $_.Fixable })
    if (-not $toFix.Count) {
        New-DREvent -TaskId $TaskId -State Information -Message 'Everything the Cleaner can switch on is already on. Nothing was changed.'
    }
    foreach ($item in $toFix) {
        try {
            switch ($item.Area) {
                'Firewall' { Enable-DRFirewallProfiles -Profiles $item.Detail }
                'Virus'    { Enable-DRDefenderRealtime }
                'Update'   { Enable-DRWindowsUpdateService }
            }
        } catch {
            New-DREvent -TaskId $TaskId -State Warning -Message ('{0} could not be switched on: {1}' -f $item.Label, $_.Exception.Message)
        }
    }

    # Check again instead of trusting the commands: a policy or Tamper Protection
    # can refuse a change without any error.
    $after = @(Get-DRSecurityStatus)
    foreach ($item in $toFix) {
        $now = $after | Where-Object Area -eq $item.Area | Select-Object -First 1
        if ($now -and $now.Ok) { New-DREvent -TaskId $TaskId -State Information -Message ('{0} is back on.' -f $item.Label) }
        else { New-DREvent -TaskId $TaskId -State Warning -Message ('{0} is still off. It may be controlled by a policy or by another program.' -f $item.Label) }
    }
    foreach ($left in @($after | Where-Object { -not $_.Ok -and -not $_.Fixable })) {
        New-DREvent -TaskId $TaskId -State Warning -Message $left.Message
    }
}

function Get-DRTypingPrivacyValues {
    # The switches behind Settings > Privacy > "Improve inking and typing" and
    # "Inking & typing personalization", with the value that turns each one off.
    param([string]$Root = 'HKCU:\Software\Microsoft')
    @(
        [pscustomobject]@{ Key = Join-Path $Root 'Input\TIPC';                            Name = 'Enabled';                        Off = 0 },
        [pscustomobject]@{ Key = Join-Path $Root 'InputPersonalization';                  Name = 'RestrictImplicitInkCollection';  Off = 1 },
        [pscustomobject]@{ Key = Join-Path $Root 'InputPersonalization';                  Name = 'RestrictImplicitTextCollection'; Off = 1 },
        [pscustomobject]@{ Key = Join-Path $Root 'InputPersonalization\TrainedDataStore'; Name = 'HarvestContacts';                Off = 0 },
        [pscustomobject]@{ Key = Join-Path $Root 'Personalization\Settings';              Name = 'AcceptedPrivacyPolicy';          Off = 0 }
    )
}

function Get-DRTypingPrivacyBackupPath {
    Join-Path (Split-Path -Parent $script:DRReportRoot) 'Backups\Typing_Settings.json'
}

function Set-DRTypingPrivacy {
    param(
        [string]$TaskId,
        [string]$Root = 'HKCU:\Software\Microsoft',
        [string]$BackupPath = (Get-DRTypingPrivacyBackupPath)
    )

    $values = @(Get-DRTypingPrivacyValues -Root $Root)
    # Save what was there before touching anything. A backup that already exists
    # holds the customer's original settings, so a second run never replaces it.
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        $before = foreach ($value in $values) {
            $current = $null
            $property = Get-ItemProperty -LiteralPath $value.Key -Name $value.Name -ErrorAction SilentlyContinue
            if ($property) { $current = $property.($value.Name) }
            [pscustomobject]@{ Key = $value.Key; Name = $value.Name; Existed = ($null -ne $property); Value = $current }
        }
        New-Item -Path (Split-Path -Parent $BackupPath) -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText($BackupPath, (ConvertTo-Json -InputObject @($before) -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    }

    foreach ($value in $values) {
        if (-not (Test-Path -LiteralPath $value.Key)) { New-Item -Path $value.Key -Force | Out-Null }
        New-ItemProperty -LiteralPath $value.Key -Name $value.Name -Value $value.Off -PropertyType DWord -Force | Out-Null
    }
    New-DREvent -TaskId $TaskId -State Information -Message 'Windows no longer collects typing and handwriting to tune its suggestions. Your previous settings were saved; "Restore typing settings" puts them back.'
}

function Restore-DRTypingPrivacy {
    param(
        [string]$TaskId,
        [string]$Root = 'HKCU:\Software\Microsoft',
        [string]$BackupPath = (Get-DRTypingPrivacyBackupPath)
    )

    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        New-DREvent -TaskId $TaskId -State Information -Message 'There was nothing to restore: the Cleaner has not changed the typing settings on this PC.'
        return
    }

    $allowed = @(Get-DRTypingPrivacyValues -Root $Root)
    # Windows PowerShell hands a JSON array back as one object; ForEach-Object unrolls it.
    $saved = @(Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json | ForEach-Object { $_ })
    foreach ($entry in $saved) {
        # Only the switches this Cleaner changes; an edited backup cannot point anywhere else.
        if (-not @($allowed | Where-Object { $_.Key -eq $entry.Key -and $_.Name -eq $entry.Name }).Count) { continue }
        if ($entry.Existed) {
            if (-not (Test-Path -LiteralPath $entry.Key)) { New-Item -Path $entry.Key -Force | Out-Null }
            New-ItemProperty -LiteralPath $entry.Key -Name $entry.Name -Value ([int]$entry.Value) -PropertyType DWord -Force | Out-Null
        } else {
            Remove-ItemProperty -LiteralPath $entry.Key -Name $entry.Name -ErrorAction SilentlyContinue
        }
    }
    Remove-DRSafeItem -LiteralPath $BackupPath -AllowedRoot (Split-Path -Parent $BackupPath) | Out-Null
    New-DREvent -TaskId $TaskId -State Information -Message 'Typing settings are back to how they were before the Cleaner changed them.'
}

# ---------------------------------------------------------------------------
# AI Remover. Windows and browser AI is switched off with the same policy
# settings a company would use, saved first so "Turn back on" can undo it.
# Passwords, bookmarks, sign-ins and browser profiles are never opened for
# writing.
# ---------------------------------------------------------------------------

function Get-DRAIBrowserForTask {
    param([string]$TaskId)
    switch ($TaskId) {
        'ai.edge'    { return 'Edge' }
        'ai.edge-button' { return 'Edge' }
        'ai.chrome'  { return 'Chrome' }
        'ai.brave'   { return 'Brave' }
        'ai.firefox' { return 'Firefox' }
    }
    return $null
}

function Get-DRAIPolicyValues {
    # The policy switches behind each AI option, with the value that turns the AI
    # off. They sit under HKLM so they cover every account; Root only moves for tests.
    param(
        [ValidateSet('Windows','Edge','Chrome','Brave','Firefox','Adobe','Search')][string]$Target,
        [string]$Root = 'HKLM:\SOFTWARE'
    )
    $spec = switch ($Target) {
        'Windows' { @(
            'Policies\Microsoft\Windows\WindowsAI|DisableAIDataAnalysis|1'      # Recall stops saving snapshots
            'Policies\Microsoft\Windows\WindowsAI|AllowRecallEnablement|0'      # Recall is removed
            'Policies\Microsoft\Windows\WindowsAI|DisableClickToDo|1'
            'Policies\Microsoft\Windows\WindowsAI|DisableSettingsAgent|1'     # Enterprise/Education only; harmless elsewhere
            'Microsoft\Windows\CurrentVersion\Policies\Paint|DisableCocreator|1'
            'Microsoft\Windows\CurrentVersion\Policies\Paint|DisableGenerativeFill|1'
            'Microsoft\Windows\CurrentVersion\Policies\Paint|DisableImageCreator|1'
            'Policies\WindowsNotepad|DisableAIFeatures|1'
        ) }
        'Edge' { @(
            'Policies\Microsoft\Edge|HubsSidebarEnabled|0'                      # the sidebar Copilot lives in
            'Policies\Microsoft\Edge|CopilotPageContext|0'
            'Policies\Microsoft\Edge|CopilotCDPPageContext|0'
            'Policies\Microsoft\Edge|Microsoft365CopilotChatIconEnabled|0'
            'Policies\Microsoft\Edge|ComposeInlineEnabled|0'
            'Policies\Microsoft\Edge|NewTabPageBingChatEnabled|0'
            'Policies\Microsoft\Edge|GenAILocalFoundationalModelSettings|1'
        ) }
        'Chrome' { @(
            'Policies\Google\Chrome|GenAiDefaultSettings|2'                     # every AI feature off unless named
            'Policies\Google\Chrome|GeminiSettings|1'
            'Policies\Google\Chrome|AIModeSettings|1'
            'Policies\Google\Chrome|HelpMeWriteSettings|2'
            'Policies\Google\Chrome|TabOrganizerSettings|2'
            'Policies\Google\Chrome|TabCompareSettings|2'
            'Policies\Google\Chrome|HistorySearchSettings|2'
            'Policies\Google\Chrome|CreateThemesSettings|2'
            'Policies\Google\Chrome|DevToolsGenAiSettings|2'
            'Policies\Google\Chrome|GenAILocalFoundationalModelSettings|1'
        ) }
        'Brave' { @(
            'Policies\BraveSoftware\Brave|BraveAIChatEnabled|0'
        ) }
        'Search' { @(
            'Policies\Microsoft\Windows\Explorer|DisableSearchBoxSuggestions|1'   # no web or Bing suggestions in the Start search box
            'Policies\Microsoft\Windows\Windows Search|DisableWebSearch|1'
            'Policies\Microsoft\Windows\Windows Search|ConnectedSearchUseWeb|0'
        ) }
        'Adobe' { @(
            'Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown|bEnableGentech|0'     # AI Assistant and generative AI in Acrobat
            'Policies\Adobe\Acrobat Reader\DC\FeatureLockDown|bEnableGentech|0'   # the same for the free Reader
        ) }
        'Firefox' { @(
            'Policies\Mozilla\Firefox\GenerativeAI|Enabled|0'
            'Policies\Mozilla\Firefox\GenerativeAI|Chatbot|0'
            'Policies\Mozilla\Firefox\GenerativeAI|LinkPreviews|0'
            'Policies\Mozilla\Firefox\GenerativeAI|TabGroups|0'
        ) }
    }
    foreach ($line in $spec) {
        $key, $name, $off = $line -split '\|'
        [pscustomobject]@{ Key = (Join-Path $Root $key); Name = $name; Off = [int]$off }
    }
}

function Open-DRRegistryKey {
    # 'HKLM:\...' or 'HKCU:\...' opened in the 64-bit view, so a 32-bit host still
    # writes where Windows and 64-bit browsers read. $null when the key is missing.
    param([Parameter(Mandatory=$true)][string]$Key, [switch]$Writable, [switch]$Create)
    $parts = $Key -split ':\\', 2
    if (@($parts).Count -ne 2 -or -not $parts[1]) { throw "Not a registry key path: $Key" }
    $hive = switch ($parts[0]) {
        'HKLM'  { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKCU'  { [Microsoft.Win32.RegistryHive]::CurrentUser }
        default { throw "Unsupported registry hive: $($parts[0])" }
    }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
    if ($Create) { return $base.CreateSubKey($parts[1]) }
    return $base.OpenSubKey($parts[1], [bool]$Writable)
}

function Test-DRRegistryKey {
    param([string]$Key)
    $opened = Open-DRRegistryKey -Key $Key
    if (-not $opened) { return $false }
    $opened.Close()
    return $true
}

function Get-DRRegistryValueState {
    param([string]$Key, [string]$Name)
    $opened = Open-DRRegistryKey -Key $Key
    if ($opened) {
        try {
            if (@($opened.GetValueNames()) -contains $Name) {
                return [pscustomobject]@{
                    Key = $Key; Name = $Name; Existed = $true
                    Kind = [string]$opened.GetValueKind($Name)
                    Value = $opened.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                }
            }
        } finally { $opened.Close() }
    }
    [pscustomobject]@{ Key = $Key; Name = $Name; Existed = $false; Kind = $null; Value = $null }
}

function Get-DRMissingRegistryKeys {
    # Every key on the way down from Root to Key that does not exist yet, top first.
    param([string]$Key, [string]$Root)
    $missing = @()
    $path = $Root
    foreach ($segment in ($Key.Substring($Root.Length).Trim('\') -split '\\')) {
        $path = "$path\$segment"
        if ($missing.Count -or -not (Test-DRRegistryKey -Key $path)) { $missing += $path }
    }
    $missing
}

function Remove-DREmptyRegistryKey {
    # Deletes a key only while it holds no values and no subkeys.
    param([string]$Key)
    $opened = Open-DRRegistryKey -Key $Key
    if (-not $opened) { return $false }
    try { $empty = ($opened.ValueCount -eq 0 -and $opened.SubKeyCount -eq 0) } finally { $opened.Close() }
    if (-not $empty) { return $false }
    $split = $Key.LastIndexOf('\')
    $parent = Open-DRRegistryKey -Key $Key.Substring(0, $split) -Writable
    if (-not $parent) { return $false }
    try { $parent.DeleteSubKey($Key.Substring($split + 1), $false) } finally { $parent.Close() }
    return $true
}

function Test-DRAIRemovableKey {
    # A key the Cleaner created may be removed again only if it is on the way to
    # one of the policy keys and at least two levels below Root (Policies\Google),
    # so an edited backup can never reach anything else.
    param([string]$Key, [object[]]$Allowed, [string]$Root)
    if (-not $Key -or -not $Key.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (@($Key.Substring($Root.Length).Trim('\') -split '\\').Count -lt 2) { return $false }
    foreach ($value in $Allowed) {
        if ($value.Key -eq $Key -or $value.Key.StartsWith($Key + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DRAIBackupFolder {
    # Machine-wide, like the policies themselves, so any administrator can put AI back.
    Join-Path $env:ProgramData 'DRDirect PC Cleaner\Backups'
}

function Set-DRAIPolicy {
    param(
        [string]$TaskId,
        [ValidateSet('Windows','Edge','Chrome','Brave','Firefox','Adobe','Search')][string]$Target,
        [string]$Root = 'HKLM:\SOFTWARE',
        [string]$BackupFolder = (Get-DRAIBackupFolder)
    )

    $values = @(Get-DRAIPolicyValues -Target $Target -Root $Root)
    $backupPath = Join-Path $BackupFolder ('AI_{0}.json' -f $Target)
    # Save what was there before touching anything. A backup that already exists
    # holds the customer's original settings, so a second run never replaces it.
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        $before = [pscustomobject]@{
            Target   = $Target
            Settings = @($values | ForEach-Object { Get-DRRegistryValueState -Key $_.Key -Name $_.Name })
            NewKeys  = @($values | ForEach-Object { Get-DRMissingRegistryKeys -Key $_.Key -Root $Root } | Select-Object -Unique)
        }
        New-Item -Path $BackupFolder -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText($backupPath, (ConvertTo-Json -InputObject $before -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    }

    foreach ($value in $values) {
        $opened = Open-DRRegistryKey -Key $value.Key -Create
        try { $opened.SetValue($value.Name, [int]$value.Off, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $opened.Close() }
    }

    $managed = ' It will show "Managed by your organization" - that is what keeps the AI off. "Turn back on" removes it.'
    $message = switch ($Target) {
        'Windows' { 'Recall, Click to Do, and the AI in Paint and Notepad are now off. They are gone after the restart.' }
        'Edge'    { 'Copilot is now off in Edge. Close Edge completely and open it again.' + $managed + ' If the Copilot button still shows on the toolbar, open Edge Settings, search for "Copilot" and switch the button off.' }
        'Chrome'  { 'Gemini and AI Mode are now off in Chrome. Close Chrome completely and open it again.' + $managed }
        'Brave'   { 'Leo AI is now off in Brave. Close Brave completely and open it again.' + $managed }
        'Search'  { 'Web and Bing results are now off in Start search. Sign out and back in for it to take effect. "Turn back on" removes it.' }
        'Adobe'   { 'The AI Assistant is now off in Adobe Acrobat and Reader. Close Acrobat completely and open it again. Acrobat may say some settings are managed by your organization - that is what keeps the AI off. "Turn back on" removes it.' }
        'Firefox' { 'AI is now off in Firefox. Close Firefox completely and open it again.' + $managed }
    }
    New-DREvent -TaskId $TaskId -State Information -Message $message
}

function Restore-DRAIPolicy {
    param(
        [string]$TaskId,
        [string]$Root = 'HKLM:\SOFTWARE',
        [string]$BackupFolder = (Get-DRAIBackupFolder),
        # Website blocks first, so a browser key they emptied can go with its own target.
        [string[]]$Targets = @('Sites_Chrome','Sites_Edge','Sites_Brave','Sites_Firefox','Windows','Edge','Chrome','Brave','Firefox','Adobe','Search')
    )

    $restored = @()
    $emptied = @()
    foreach ($target in $Targets) {
        $backupPath = Join-Path $BackupFolder ('AI_{0}.json' -f $target)
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { continue }
        $allowed = if ($target -like 'Sites_*') { @([pscustomobject]@{ Key = (Get-DRAISiteBlockKey -Browser $target.Substring(6) -Root $Root) }) }
                   else { @(Get-DRAIPolicyValues -Target $target -Root $Root) }
        $saved = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json

        foreach ($entry in @(Get-DRDiskProperty $saved 'Settings' | Where-Object { $_ })) {
            # Only the switches this Cleaner sets; an edited backup cannot point anywhere else.
            if (-not (Test-DRAIAllowedEntry -Target $target -Entry $entry -Root $Root)) { continue }
            if ($entry.Existed) {
                $kind = [Microsoft.Win32.RegistryValueKind]$entry.Kind
                $data = switch ($kind) {
                    'DWord'       { [int]$entry.Value }
                    'QWord'       { [long]$entry.Value }
                    # The leading comma keeps an array whole instead of unrolling it.
                    'MultiString' { ,[string[]]@($entry.Value) }
                    'Binary'      { ,[byte[]]@($entry.Value) }
                    default       { [string]$entry.Value }
                }
                $opened = Open-DRRegistryKey -Key $entry.Key -Create
                try { $opened.SetValue($entry.Name, $data, $kind) } finally { $opened.Close() }
            } else {
                $opened = Open-DRRegistryKey -Key $entry.Key -Writable
                if ($opened) {
                    try {
                        # A block-list entry is only taken out while it still holds the site
                        # the Cleaner put there; anything reusing that slot since is kept.
                        $expected = Get-DRDiskProperty $entry 'Value'
                        if ($null -eq $expected -or [string]$opened.GetValue($entry.Name) -eq [string]$expected) { $opened.DeleteValue($entry.Name, $false) }
                    } finally { $opened.Close() }
                }
            }
        }

        foreach ($newKey in @(Get-DRDiskProperty $saved 'NewKeys' | Where-Object { $_ })) {
            if (Test-DRAIRemovableKey -Key $newKey -Allowed $allowed -Root $Root) { $emptied += $newKey }
        }

        Remove-DRSafeItem -LiteralPath $backupPath -AllowedRoot $BackupFolder | Out-Null
        $restored += if ($target -like 'Sites_*') { 'AI websites in ' + $target.Substring(6) } else { $target }
    }

    # Keys the Cleaner created, deepest first, and only while they are empty: a key
    # something else has put its own settings in since is left alone. Done last, so
    # a browser key emptied by a later step still goes.
    foreach ($newKey in @($emptied | Select-Object -Unique | Sort-Object Length -Descending)) {
        Remove-DREmptyRegistryKey -Key $newKey | Out-Null
    }

    if (-not $restored.Count) {
        New-DREvent -TaskId $TaskId -State Information -Message 'There was nothing to put back: the Cleaner has not changed any AI settings on this PC.'
        return
    }
    New-DREvent -TaskId $TaskId -State Information -Message ('AI settings are back to how they were for: {0}. Close and reopen those browsers. Removed apps come back with their own "Reinstall" button.' -f ($restored -join ', '))
}

function Test-DRAIAllowedEntry {
    # Whether a backup entry is one this Cleaner could have written for that target.
    param([string]$Target, $Entry, [string]$Root)
    if ($Target -like 'Sites_*') {
        $blockKey = Get-DRAISiteBlockKey -Browser $Target.Substring(6) -Root $Root
        return ($Entry.Key -eq $blockKey -and [string]$Entry.Name -match '^\d+$' -and -not $Entry.Existed)
    }
    return [bool]@(Get-DRAIPolicyValues -Target $Target -Root $Root | Where-Object { $_.Key -eq $Entry.Key -and $_.Name -eq $Entry.Name }).Count
}

function Get-DRAIBlockedSites {
    param([ValidateSet('Chrome','Edge','Brave','Firefox')][string]$Browser)
    # Claude is deliberately not on this list: DRDirect keeps Claude open.
    $sites = @('chatgpt.com', 'chat.openai.com', 'gemini.google.com', 'copilot.microsoft.com',
               'perplexity.ai', 'chat.deepseek.com', 'grok.com', 'meta.ai')
    # Firefox takes match patterns; *.site also covers the site itself.
    if ($Browser -eq 'Firefox') { return @($sites | ForEach-Object { '*://*.{0}/*' -f $_ }) }
    return $sites
}

function Get-DRAISiteBlockKey {
    param([ValidateSet('Chrome','Edge','Brave','Firefox')][string]$Browser, [string]$Root = 'HKLM:\SOFTWARE')
    $relative = switch ($Browser) {
        'Chrome'  { 'Policies\Google\Chrome\URLBlocklist' }
        'Edge'    { 'Policies\Microsoft\Edge\URLBlocklist' }
        'Brave'   { 'Policies\BraveSoftware\Brave\URLBlocklist' }
        'Firefox' { 'Policies\Mozilla\Firefox\WebsiteFilter\Block' }
    }
    Join-Path $Root $relative
}

function Add-DRAISiteBlock {
    <#
        Adds the AI sites to a browser's block list beside anything already on it,
        and records exactly which numbered entries were added - before adding them -
        so "Turn back on" takes out only those. Returns how many were added.
    #>
    param(
        [ValidateSet('Chrome','Edge','Brave','Firefox')][string]$Browser,
        [string]$Root = 'HKLM:\SOFTWARE',
        [string]$BackupFolder = (Get-DRAIBackupFolder)
    )
    $key = Get-DRAISiteBlockKey -Browser $Browser -Root $Root
    $backupPath = Join-Path $BackupFolder ('AI_Sites_{0}.json' -f $Browser)
    $saved = $null
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) { $saved = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json }
    # Earlier runs are added to, never replaced, so every entry ever added stays on record.
    $settings = if ($saved) { @(Get-DRDiskProperty $saved 'Settings' | Where-Object { $_ }) } else { @() }
    $newKeys  = if ($saved) { @(Get-DRDiskProperty $saved 'NewKeys' | Where-Object { $_ }) } else { @(Get-DRMissingRegistryKeys -Key $key -Root $Root) }

    # Anything an earlier version added that is no longer blocked (claude.ai) comes
    # out again, but only while it still holds exactly what the Cleaner put there.
    $wanted = @(Get-DRAIBlockedSites -Browser $Browser)
    $dropped = @($settings | Where-Object { $wanted -notcontains [string]$_.Value })
    if ($dropped.Count) {
        $opened = Open-DRRegistryKey -Key $key -Writable
        if ($opened) {
            try {
                foreach ($entry in $dropped) {
                    if ([string]$opened.GetValue($entry.Name) -eq [string]$entry.Value) { $opened.DeleteValue($entry.Name, $false) }
                }
            } finally { $opened.Close() }
        }
        $settings = @($settings | Where-Object { $wanted -contains [string]$_.Value })
    }

    $names = @(); $present = @()
    $opened = Open-DRRegistryKey -Key $key
    if ($opened) {
        try {
            $names = @($opened.GetValueNames())
            $present = @($names | ForEach-Object { [string]$opened.GetValue($_) })
        } finally { $opened.Close() }
    }
    $plan = @()
    $next = 1
    foreach ($site in (Get-DRAIBlockedSites -Browser $Browser)) {
        if ($present -contains $site) { continue }
        while ($names -contains [string]$next) { $next++ }
        $names += [string]$next
        $plan += [pscustomobject]@{ Key = $key; Name = [string]$next; Existed = $false; Kind = 'String'; Value = $site }
    }
    if (-not $plan.Count) {
        # Nothing new to add, but the record still has to forget what was taken out.
        if ($dropped.Count) {
            $record = [pscustomobject]@{ Target = ('Sites_{0}' -f $Browser); Settings = @($settings); NewKeys = @($newKeys) }
            [System.IO.File]::WriteAllText($backupPath, (ConvertTo-Json -InputObject $record -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
        }
        return 0
    }

    New-Item -Path $BackupFolder -ItemType Directory -Force | Out-Null
    $record = [pscustomobject]@{ Target = ('Sites_{0}' -f $Browser); Settings = @($settings + $plan); NewKeys = @($newKeys) }
    [System.IO.File]::WriteAllText($backupPath, (ConvertTo-Json -InputObject $record -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

    $opened = Open-DRRegistryKey -Key $key -Create
    try { foreach ($entry in $plan) { $opened.SetValue($entry.Name, $entry.Value, [Microsoft.Win32.RegistryValueKind]::String) } } finally { $opened.Close() }
    return $plan.Count
}

function Invoke-DRAISiteBlock {
    param([string]$TaskId, [string]$TestRoot)
    $blocked = @(); $skipped = @()
    foreach ($browser in @('Edge','Chrome','Brave','Firefox')) {
        if (-not (Test-DRAIBrowserPresent -Browser $browser)) { continue }
        # Same rule as the browser rows: a browser with accounts must be signed in first.
        if ($browser -ne 'Brave' -and -not (Test-DRBrowserSignedIn -Browser $browser)) { $skipped += $browser; continue }
        if (-not $TestRoot) { Add-DRAISiteBlock -Browser $browser | Out-Null }
        $blocked += $browser
    }
    foreach ($browser in $skipped) {
        New-DREvent -TaskId $TaskId -State Warning -Message ('{0} is not signed in, so AI websites were not blocked there. Sign in to {0} first, then run this again.' -f $browser)
    }
    if (-not $blocked.Count) {
        if (-not $skipped.Count) { New-DREvent -TaskId $TaskId -State Information -Message 'No supported web browser was found. Nothing was changed.' }
        return
    }
    if ($TestRoot) {
        New-DREvent -TaskId $TaskId -State Information -Message ('TEST MODE: nothing was changed. AI websites would be blocked in {0}.' -f ($blocked -join ', '))
        return
    }
    New-DREvent -TaskId $TaskId -State Information -Message ('ChatGPT, Gemini, Copilot and other AI websites are now blocked in {0}, and Claude is left open. Close and reopen the browser. It will show "Managed by your organization" - that is what keeps them blocked. "Turn back on" removes it.' -f ($blocked -join ', '))
}

function Open-DRForUser {
    # Opens a web page or program as the signed-in person rather than as
    # administrator, by handing it to Explorer. A browser started as administrator
    # would not be the customer's normal browser session.
    param([string]$Target)
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('"{0}"' -f $Target)
}

function Invoke-DRAIGuidedTask {
    # For switches kept in an online account or inside an app: open the right place
    # and say exactly what to click. Nothing on this PC is changed.
    param([string]$TaskId, [string]$TestRoot, [switch]$TurnOn, [string]$EventTaskId)
    $eventId = if ($EventTaskId) { $EventTaskId } else { $TaskId }
    $target = $null; $message = $null
    switch ($TaskId) {
        'ai.gmail' {
            $target = 'https://mail.google.com/mail/u/0/#settings/general'
            $message = if ($TurnOn) { 'Gmail settings are open in the web browser. Sign in if asked, tick the Smart features boxes, then click Save changes at the bottom of the page.' }
                       else { 'Gmail settings are open in the web browser. Sign in if asked, untick the Smart features boxes, then click Save changes at the bottom of the page.' }
        }
        'ai.office-copilot' {
            $target = Get-DRWordExe
            $message = if ($TurnOn) { 'Word is opening. Click File > Options > Copilot, tick Enable Copilot and click OK, then close and reopen Word. Do the same in Excel and PowerPoint.' }
                       else { 'Word is opening. Click File > Options > Copilot, untick Enable Copilot and click OK, then close and reopen Word. Do the same in Excel and PowerPoint.' }
            if (-not $target) { $message = 'Word is not installed on this PC. Nothing was opened.' }
        }
        'ai.zoom' {
            $target = Get-DRZoomExe
            $message = if ($TurnOn) { 'Zoom is opening. Click Settings (the gear, bottom left) > General, scroll to AI and click Manage, and tick the features you want back on.' }
                       else { 'Zoom is opening. Click Settings (the gear, bottom left) > General, scroll to AI and click Manage. Untick Auto-start questions and Auto-generate transcripts, click Update, then untick Auto-start notes and Use transcript to enrich notes and click Update again. Some switches are also in your Zoom account at zoom.us > Settings > AI Companion.' }
            if (-not $target) { $message = 'Zoom is not installed on this PC. Nothing was opened.' }
        }
        'ai.copilot-key' {
            $target = 'ms-settings:personalization-textinput'
            $message = if ($TurnOn) { 'Settings is open at Text input. Under "Customize Copilot key on keyboard", choose Copilot.' }
                       else { 'Settings is open at Text input. Under "Customize Copilot key on keyboard", choose Search.' }
        }
        'ai.edge-button' {
            # Turning AI off needs the sign-in first; showing the button again does not.
            if (-not $TurnOn -and -not (Test-DRBrowserSignedIn -Browser Edge)) {
                New-DREvent -TaskId $eventId -State Warning -Message 'Edge is not signed in, so nothing was opened. Sign in to Edge first, then run this again.'
                return
            }
            $target = Get-DRAIBrowserExe -Browser Edge
            $message = if ($TurnOn) { 'Edge is opening. Click the three dots at the top right, open Settings, search for "Copilot" and switch the Copilot button on.' }
                       else { 'Edge is opening. Click the three dots at the top right, open Settings, search for "Copilot" and switch the Copilot button off.' }
            if (-not $target) { $message = 'Edge was not found on this PC. Nothing was opened.' }
        }
    }
    if ($target -and $TestRoot) { $message = 'TEST MODE: nothing was opened. ' + $message }
    elseif ($target) { Open-DRForUser -Target $target }
    New-DREvent -TaskId $eventId -State Information -Message $message
}

function Format-DRAIBytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    return ('{0:N0} MB' -f ($Bytes / 1MB))
}

function Get-DRAIModelFolders {
    # The large AI models Chrome and Edge download in the background for their
    # built-in AI. Only these folders - never the profile, passwords or history.
    param([string]$LocalAppData = $env:LOCALAPPDATA)
    foreach ($spec in @(
            @{ Browser = 'Chrome'; UserData = 'Google\Chrome\User Data'; Folders = @('OptGuideOnDeviceModel') },
            @{ Browser = 'Edge';   UserData = 'Microsoft\Edge\User Data'; Folders = @('OptGuideOnDeviceModel', 'EdgeLLMOnDeviceModel') })) {
        $userData = Join-Path $LocalAppData $spec.UserData
        foreach ($folder in $spec.Folders) {
            $path = Join-Path $userData $folder
            if (Test-Path -LiteralPath $path -PathType Container) {
                [pscustomobject]@{ Browser = $spec.Browser; Path = $path; Root = $userData; Bytes = (Get-DRPathSize -Path $path) }
            }
        }
    }
}

function Remove-DRAIModels {
    param([string]$TaskId, [string]$TestRoot, [string]$LocalAppData = $env:LOCALAPPDATA)
    $models = @(Get-DRAIModelFolders -LocalAppData $LocalAppData)
    if (-not $models.Count) {
        New-DREvent -TaskId $TaskId -State Information -Message 'No downloaded AI models were found. Nothing was deleted.'
        return
    }
    $freed = [int64]0; $done = @()
    foreach ($browser in @($models | ForEach-Object { $_.Browser } | Select-Object -Unique)) {
        # Same rule as the browser rows: the customer signs in first.
        if (-not (Test-DRBrowserSignedIn -Browser $browser -LocalAppData $LocalAppData)) {
            New-DREvent -TaskId $TaskId -State Warning -Message ('{0} is not signed in, so its AI model was not deleted. Sign in to {0} first, then run this again.' -f $browser)
            continue
        }
        $ok = $true
        foreach ($model in @($models | Where-Object { $_.Browser -eq $browser })) {
            if ($TestRoot) { $freed += $model.Bytes; continue }
            try { Remove-DRSafeItem -LiteralPath $model.Path -AllowedRoot $model.Root | Out-Null; $freed += $model.Bytes }
            catch {
                $ok = $false
                New-DREvent -TaskId $TaskId -State Warning -Message ('The AI model {0} downloaded could not be fully deleted, probably because {0} is open. Close {0} completely, then run this again.' -f $browser)
            }
        }
        if ($ok) { $done += $browser }
    }
    if (-not $done.Count) { return }
    if ($TestRoot) {
        New-DREvent -TaskId $TaskId -State Information -Message ('TEST MODE: nothing was deleted. Deleting the AI model downloaded by {0} would free {1}.' -f ($done -join ' and '), (Format-DRAIBytes $freed))
        return
    }
    New-DREvent -TaskId $TaskId -State Information -Message ('Freed {0} by deleting the AI model downloaded by {1}. If "turn off" is not also done for that browser, it downloads the model again.' -f (Format-DRAIBytes $freed), ($done -join ' and '))
}

function Test-DRAIPolicyApplied {
    # True when every switch for that target is set to the value that turns the AI off.
    param([ValidateSet('Windows','Edge','Chrome','Brave','Firefox','Adobe','Search')][string]$Target, [string]$Root = 'HKLM:\SOFTWARE')
    foreach ($value in @(Get-DRAIPolicyValues -Target $Target -Root $Root)) {
        $state = Get-DRRegistryValueState -Key $value.Key -Name $value.Name
        if (-not $state.Existed -or [string]$state.Value -ne [string]$value.Off) { return $false }
    }
    return $true
}

function Test-DRAISitesBlocked {
    param([ValidateSet('Chrome','Edge','Brave','Firefox')][string]$Browser, [string]$Root = 'HKLM:\SOFTWARE')
    $opened = Open-DRRegistryKey -Key (Get-DRAISiteBlockKey -Browser $Browser -Root $Root)
    if (-not $opened) { return $false }
    try { $present = @($opened.GetValueNames() | ForEach-Object { [string]$opened.GetValue($_) }) } finally { $opened.Close() }
    foreach ($site in (Get-DRAIBlockedSites -Browser $Browser)) { if ($present -notcontains $site) { return $false } }
    return $true
}

function Get-DRAIReport {
    <#
        What AI is switched on or installed right now, as rows of On (still there)
        and Text. Only reads - used by "What AI is on this PC?".
    #>
    param([object[]]$Status = @(Get-DRAIStatus))
    $isPresent = { param([string]$Id) [bool]@($Status | Where-Object { $_.TaskId -eq $Id -and $_.Present }).Count }
    $row = { param([bool]$On, [string]$Text) [pscustomobject]@{ On = $On; Text = $Text } }

    if (& $isPresent 'ai.windows') {
        $off = Test-DRAIPolicyApplied -Target Windows
        & $row (-not $off) ('Recall, Click to Do and the AI in Paint and Notepad: {0}' -f $(if ($off) { 'switched off' } else { 'ON' }))
    }
    if (& $isPresent 'ai.search') {
        $off = Test-DRAIPolicyApplied -Target Search
        & $row (-not $off) ('Web and Bing results in Start search: {0}' -f $(if ($off) { 'switched off' } else { 'ON' }))
    }
    if (& $isPresent 'ai.adobe') {
        $off = Test-DRAIPolicyApplied -Target Adobe
        & $row (-not $off) ('Adobe Acrobat AI Assistant: {0}' -f $(if ($off) { 'switched off' } else { 'ON' }))
    }
    foreach ($app in @(
            @{ Id = 'ai.copilot-app'; Label = 'Copilot app' },
            @{ Id = 'ai.m365-app';    Label = 'Microsoft 365 Copilot app' },
            @{ Id = 'ai.chatgpt-app'; Label = 'ChatGPT app' },
            @{ Id = 'ai.claude-app';  Label = 'Claude app' })) {
        # Claude is kept on purpose, so it is listed but not counted as AI still on.
        if (& $isPresent $app.Id) { & $row ($app.Id -ne 'ai.claude-app') ('{0}: installed{1}' -f $app.Label, $(if ($app.Id -eq 'ai.claude-app') { ' (kept)' } else { '' })) }
    }
    $browsers = @(@('Edge','Chrome','Brave','Firefox') | Where-Object { Test-DRAIBrowserPresent -Browser $_ })
    foreach ($browser in $browsers) {
        $off = Test-DRAIPolicyApplied -Target $browser
        & $row (-not $off) ('{0} built-in AI: {1}' -f $browser, $(if ($off) { 'switched off' } else { 'ON' }))
    }
    if ($browsers.Count) {
        $open = @($browsers | Where-Object { -not (Test-DRAISitesBlocked -Browser $_) })
        if ($open.Count) { & $row $true ('AI websites: open in {0}' -f ($open -join ', ')) }
        else { & $row $false 'AI websites: blocked in every browser' }
    }
    foreach ($model in @(Get-DRAIModelFolders | Where-Object { $_.Bytes -gt 0 })) {
        & $row $true ('AI model downloaded by {0}: {1}' -f $model.Browser, (Format-DRAIBytes $model.Bytes))
    }
}

function Invoke-DRAICheck {
    param([string]$TaskId)
    $rows = @(Get-DRAIReport)
    foreach ($item in $rows) {
        New-DREvent -TaskId $TaskId -State $(if ($item.On) { 'Warning' } else { 'Information' }) -Message $item.Text
    }
    New-DREvent -TaskId $TaskId -State Information -Message 'Gemini in Gmail, AI in Zoom, Copilot in Word and Excel, the Edge Copilot button and the Copilot key are settings the Cleaner cannot read, so they are not listed.'
    $on = @($rows | Where-Object { $_.On }).Count
    if ($on) {
        New-DREvent -TaskId $TaskId -State Warning -Message ('{0} AI item(s) are on or installed. Pick "Turn off" for them on the AI Remover page. Nothing was changed.' -f $on)
    } else {
        New-DREvent -TaskId $TaskId -State Information -Message 'No AI that the Cleaner can switch off was found. Nothing was changed.'
    }
}

function Get-DRAIRemovedApps {
    # The AI apps this Cleaner has removed on this PC, so their rows can offer
    # "Reinstall" after they are gone.
    param([string]$BackupFolder = (Get-DRAIBackupFolder))
    $path = Join-Path $BackupFolder 'AI_RemovedApps.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    # Windows PowerShell hands a JSON array back as one object; the first ForEach-Object unrolls it.
    try { return @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json | ForEach-Object { $_ } | ForEach-Object { [string]$_ } | Where-Object { $_ }) } catch { return @() }
}

function Add-DRAIRemovedApp {
    param([string]$App, [string]$BackupFolder = (Get-DRAIBackupFolder))
    $apps = @(@(Get-DRAIRemovedApps -BackupFolder $BackupFolder) + $App | Select-Object -Unique)
    New-Item -Path $BackupFolder -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $BackupFolder 'AI_RemovedApps.json'), (ConvertTo-Json -InputObject @($apps)), (New-Object System.Text.UTF8Encoding($false)))
}

function Open-DRAIAppReinstall {
    # The Microsoft Store page for Microsoft's own apps; the maker's official
    # download page for ChatGPT and Claude.
    param([string]$TaskId, [string]$App, [string]$TestRoot)
    $label = Get-DRAIAppLabel -App $App
    $target = switch ($App) {
        'Copilot'     { 'ms-windows-store://pdp/?ProductId=9NHT9RB2F4HD' }
        'M365Copilot' { 'ms-windows-store://pdp/?ProductId=9WZDNCRD29V9' }
        'ChatGPT'     { 'https://chatgpt.com/download' }
        'Claude'      { 'https://claude.com/download' }
    }
    $message = if ($App -in @('Copilot','M365Copilot')) { '{0} is open in the Microsoft Store. Click Get or Install.' -f $label }
               else { 'The official {0} download page is open in the web browser. Download the app and run the installer.' -f $App }
    if ($TestRoot) { $message = 'TEST MODE: nothing was opened. ' + $message }
    else { Open-DRForUser -Target $target }
    New-DREvent -TaskId $TaskId -State Information -Message $message
}

function Invoke-DRAITurnBackOn {
    # The "Turn back on" choice of each AI Remover row. Task ids are the row id plus ".on".
    param([string]$TaskId, [string]$TestRoot)
    $base = $TaskId.Substring(0, $TaskId.Length - 3)
    $policyTargets = switch ($base) {
        'ai.windows'     { @('Windows') }
        'ai.edge'        { @('Edge') }
        'ai.chrome'      { @('Chrome') }
        'ai.brave'       { @('Brave') }
        'ai.firefox'     { @('Firefox') }
        'ai.adobe'       { @('Adobe') }
        'ai.search'      { @('Search') }
        'ai.block-sites' { @('Sites_Chrome','Sites_Edge','Sites_Brave','Sites_Firefox') }
        default          { $null }
    }
    if ($policyTargets) {
        if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: AI settings were not changed.' }
        else { Restore-DRAIPolicy -TaskId $TaskId -Targets $policyTargets }
        return
    }
    $app = switch ($base) { 'ai.copilot-app' {'Copilot'} 'ai.m365-app' {'M365Copilot'} 'ai.chatgpt-app' {'ChatGPT'} 'ai.claude-app' {'Claude'} default { $null } }
    if ($app) { Open-DRAIAppReinstall -TaskId $TaskId -App $app -TestRoot $TestRoot; return }
    Invoke-DRAIGuidedTask -TaskId $base -TestRoot $TestRoot -TurnOn -EventTaskId $TaskId
}

function Test-DRBrowserSignedIn {
    <#
        True when the browser has an account signed in. Only reads: Chrome and
        Edge list signed-in accounts in their Local State file, and Firefox keeps
        signedInUser.json in a profile that is signed in to a Mozilla account.
    #>
    param(
        [ValidateSet('Chrome','Edge','Firefox')][string]$Browser,
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$AppData = $env:APPDATA
    )
    if ($Browser -eq 'Firefox') {
        $profiles = Join-Path $AppData 'Mozilla\Firefox\Profiles'
        foreach ($folder in @(Get-ChildItem -LiteralPath $profiles -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $folder.FullName 'signedInUser.json') -PathType Leaf) { return $true }
        }
        return $false
    }

    $userData = if ($Browser -eq 'Chrome') { 'Google\Chrome\User Data' } else { 'Microsoft\Edge\User Data' }
    $state = Join-Path (Join-Path $LocalAppData $userData) 'Local State'
    if (-not (Test-Path -LiteralPath $state -PathType Leaf)) { return $false }
    try {
        # Shared read, so an open browser is never disturbed.
        $stream = New-Object System.IO.FileStream($state, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
    } catch { return $false }
    return [regex]::IsMatch($text, '"user_name"\s*:\s*"[^"]+"')
}

function Get-DRAIBrowserExe {
    param([ValidateSet('Chrome','Edge','Brave','Firefox')][string]$Browser)
    $relative = switch ($Browser) {
        'Chrome'  { 'Google\Chrome\Application\chrome.exe' }
        'Edge'    { 'Microsoft\Edge\Application\msedge.exe' }
        'Brave'   { 'BraveSoftware\Brave-Browser\Application\brave.exe' }
        'Firefox' { 'Mozilla Firefox\firefox.exe' }
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $root) { continue }
        $candidate = Join-Path $root $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    # Installed somewhere else: the installer still registers the exe with Windows.
    return (Get-DRAppPath -Exe (Split-Path -Leaf $relative))
}

function Get-DRAppPath {
    # The full path Windows has registered for a program's exe, or $null.
    param([string]$Exe)
    foreach ($hive in @('HKLM:', 'HKCU:')) {
        $properties = Get-ItemProperty -LiteralPath "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$Exe" -ErrorAction SilentlyContinue
        $path = [string](Get-DRDiskProperty $properties '(default)')
        if ($path) { $path = $path.Trim('"') }
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    return $null
}

function Test-DRAIBrowserPresent {
    param([ValidateSet('Chrome','Edge','Brave','Firefox')][string]$Browser)
    return [bool](Get-DRAIBrowserExe -Browser $Browser)
}

function Get-DRZoomExe {
    $zoom = Get-DRAppPath -Exe 'Zoom.exe'
    if ($zoom) { return $zoom }
    foreach ($candidate in @((Join-Path $env:APPDATA 'Zoom\bin\Zoom.exe'), (Join-Path $env:ProgramFiles 'Zoom\bin\Zoom.exe'), (Join-Path ${env:ProgramFiles(x86)} 'Zoom\bin\Zoom.exe'))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

function Get-DRWordExe {
    $word = Get-DRAppPath -Exe 'WINWORD.EXE'
    if ($word) { return $word }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        $candidate = Join-Path $root 'Microsoft Office\root\Office16\WINWORD.EXE'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Test-DRAIAppMatch {
    # Store packages match on their package name and publisher; classic programs
    # on the name and publisher shown in Installed apps.
    param([string]$App, [string]$Name, [string]$Publisher)
    switch ($App) {
        'Copilot'     { return ($Name -eq 'Microsoft.Copilot') }
        'M365Copilot' { return ($Name -eq 'Microsoft.MicrosoftOfficeHub') }
        'ChatGPT'     { return ($Name -match 'ChatGPT' -and ($Publisher -match 'OpenAI' -or $Name -match '^OpenAI\.')) }
        'Adobe'       { return ($Name -match '^Adobe (Acrobat|Reader)' -and $Publisher -match 'Adobe') }
        'Claude'      { return ($Name -match 'Claude' -and $Name -notmatch 'Code' -and $Publisher -match 'Anthropic') }
    }
    return $false
}

function Get-DRInstalledProgramEntries {
    # Name and publisher of every classic (non-Store) program listed in Installed apps.
    foreach ($root in @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($item in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            $name = Get-DRDiskProperty $properties 'DisplayName'
            if ($name) { [pscustomobject]@{ Name = [string]$name; Publisher = [string](Get-DRDiskProperty $properties 'Publisher') } }
        }
    }
}

function Get-DRAIAppxPackages {
    param([string]$App, [switch]$AllUsers)
    $packages = @()
    try {
        if ($AllUsers) { $packages = @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
        else { $packages = @(Get-AppxPackage -ErrorAction Stop) }
    } catch { $packages = @() }
    @($packages | Where-Object { Test-DRAIAppMatch -App $App -Name $_.Name -Publisher $_.Publisher })
}

function Get-DRAIAppLabel {
    param([string]$App)
    switch ($App) {
        'Copilot'     { return 'The Copilot app' }
        'M365Copilot' { return 'The Microsoft 365 Copilot app' }
        'ChatGPT'     { return 'The ChatGPT app' }
        'Claude'      { return 'The Claude app' }
    }
    return 'The app'
}

function Remove-DRAIApp {
    param(
        [string]$TaskId,
        [ValidateSet('Copilot','M365Copilot','ChatGPT','Claude')][string]$App
    )

    $label = Get-DRAIAppLabel -App $App
    $packages = @(Get-DRAIAppxPackages -App $App -AllUsers)
    $programs = @(Get-DRInstalledProgramEntries | Where-Object { Test-DRAIAppMatch -App $App -Name $_.Name -Publisher $_.Publisher })
    if (-not $packages.Count -and -not $programs.Count) {
        New-DREvent -TaskId $TaskId -State Information -Message ('{0} is not installed on this PC. Nothing was changed.' -f $label)
        return
    }

    foreach ($package in $packages) {
        try { Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop }
        catch {
            try { Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop }
            catch { New-DREvent -TaskId $TaskId -State Warning -Message ('{0} could not be removed: {1}' -f $label, $_.Exception.Message) }
        }
    }
    # Windows adds its own AI apps to every new account; stop that too.
    if ($App -in @('Copilot','M365Copilot')) {
        try {
            foreach ($provisioned in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { Test-DRAIAppMatch -App $App -Name $_.DisplayName -Publisher '' })) {
                Remove-AppxProvisionedPackage -Online -PackageName $provisioned.PackageName -ErrorAction Stop | Out-Null
            }
        } catch { }
    }
    # A classic install is never run from here: its uninstall command comes from
    # the registry, and running that as administrator is not safe to automate.
    foreach ($program in $programs) {
        New-DREvent -TaskId $TaskId -State Warning -Message ('{0} has to be removed by hand: Settings > Apps > Installed apps > {1} > Uninstall.' -f $program.Name, $program.Name)
    }

    # Check again instead of trusting the commands.
    if ($packages.Count) {
        if (@(Get-DRAIAppxPackages -App $App -AllUsers).Count) {
            New-DREvent -TaskId $TaskId -State Warning -Message ('{0} is still installed. Close it if it is open and run this again, or remove it in Settings > Apps > Installed apps.' -f $label)
        } else {
            New-DREvent -TaskId $TaskId -State Information -Message ('{0} was removed. Its "Reinstall" button brings it back.' -f $label)
            Add-DRAIRemovedApp -App $App
        }
    }
}

function Get-DRProgramUninstallEntries {
    # Classic programs from Installed apps, with the command Windows uses to remove each.
    foreach ($root in @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($item in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            $name = Get-DRDiskProperty $properties 'DisplayName'
            if ($name) {
                [pscustomobject]@{
                    Name = [string]$name
                    Publisher = [string](Get-DRDiskProperty $properties 'Publisher')
                    Uninstall = [string](Get-DRDiskProperty $properties 'UninstallString')
                    Quiet = [string](Get-DRDiskProperty $properties 'QuietUninstallString')
                }
            }
        }
    }
}

function Invoke-DRProgramUninstall {
    # Runs one program's own uninstaller without asking questions. Returns $false when
    # there is no way to do that safely, so the caller can say so instead of guessing.
    param($Entry, [string]$Browser)
    $command = $null
    if ($Entry.Quiet) { $command = $Entry.Quiet }
    elseif ($Entry.Uninstall -match '(?i)msiexec(\.exe)?"?\s+/[IX]\s*(\{[0-9A-F-]+\})') {
        $command = 'msiexec.exe /x {0} /qn /norestart' -f $Matches[2]
    }
    elseif ($Browser -in @('Chrome','Brave') -and $Entry.Uninstall) { $command = $Entry.Uninstall + ' --force-uninstall' }
    elseif ($Browser -eq 'Firefox' -and $Entry.Uninstall) { $command = $Entry.Uninstall + ' /S' }
    if (-not $command) { return $false }
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList ('/c "{0}"' -f $command) -WindowStyle Hidden -Wait -ErrorAction Stop
    return $true
}

function Uninstall-DRAICompletely {
    param([string]$TaskId, [string]$TestRoot)
    $base = $TaskId -replace '\.uninstall$', ''
    if ($base -eq 'ai.edge') {
        New-DREvent -TaskId $TaskId -State Warning -Message 'Windows does not allow Edge to be uninstalled. Use "Turn off" for its AI instead.'
        return
    }
    if ($TestRoot) {
        New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: nothing was uninstalled.'
        return
    }
    if ($base -eq 'ai.windows') {
        try {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName Recall -ErrorAction Stop
            if ($feature.State -eq 'Disabled') { New-DREvent -TaskId $TaskId -State Information -Message 'Recall is not installed on this PC. Nothing was changed.' }
            else {
                Disable-WindowsOptionalFeature -Online -FeatureName Recall -NoRestart -ErrorAction Stop | Out-Null
                Add-DRAIRemovedApp -App 'Recall'
                New-DREvent -TaskId $TaskId -State Information -Message 'Recall was uninstalled. Restart Windows to finish. Its "Reinstall" button brings it back.'
            }
        } catch { New-DREvent -TaskId $TaskId -State Warning -Message ('Recall could not be uninstalled: {0}' -f $_.Exception.Message) }
        return
    }
    $browser = switch ($base) { 'ai.chrome' {'Chrome'} 'ai.brave' {'Brave'} 'ai.firefox' {'Firefox'} default { $null } }
    if ($browser) {
        $pattern = switch ($browser) { 'Chrome' {'^Google Chrome$'} 'Brave' {'^Brave$'} 'Firefox' {'^Mozilla Firefox'} }
        $entries = @(Get-DRProgramUninstallEntries | Where-Object { $_.Name -match $pattern })
        if (-not $entries.Count) { New-DREvent -TaskId $TaskId -State Information -Message ('{0} is not installed on this PC. Nothing was changed.' -f $browser); return }
        $done = $false
        foreach ($entry in $entries) {
            try { if (Invoke-DRProgramUninstall -Entry $entry -Browser $browser) { $done = $true } }
            catch { New-DREvent -TaskId $TaskId -State Warning -Message ('{0} could not be uninstalled: {1}' -f $browser, $_.Exception.Message) }
        }
        if (-not $done) { New-DREvent -TaskId $TaskId -State Warning -Message ('{0} has to be uninstalled by hand: Settings > Apps > Installed apps.' -f $browser); return }
        if (Test-DRAIBrowserPresent -Browser $browser) { New-DREvent -TaskId $TaskId -State Warning -Message ('{0} is still installed. Close it and run this again, or use Settings > Apps > Installed apps.' -f $browser) }
        else {
            Add-DRAIRemovedApp -App $browser
            New-DREvent -TaskId $TaskId -State Information -Message ('{0} was uninstalled. Its "Reinstall" button brings it back.' -f $browser)
        }
        return
    }
    $app = switch ($base) { 'ai.copilot-app' {'Copilot'} 'ai.m365-app' {'M365Copilot'} 'ai.chatgpt-app' {'ChatGPT'} 'ai.claude-app' {'Claude'} default { $null } }
    if (-not $app) { return }
    # The Store package first, then a regular installed copy through its own silent uninstaller.
    Remove-DRAIApp -TaskId $TaskId -App $app
    foreach ($entry in @(Get-DRProgramUninstallEntries | Where-Object { Test-DRAIAppMatch -App $app -Name $_.Name -Publisher $_.Publisher })) {
        try {
            if (Invoke-DRProgramUninstall -Entry $entry -Browser '') { New-DREvent -TaskId $TaskId -State Information -Message ('{0} was uninstalled.' -f $entry.Name) }
            else { New-DREvent -TaskId $TaskId -State Warning -Message ('{0} has no silent uninstaller: Settings > Apps > Installed apps > {0} > Uninstall.' -f $entry.Name) }
        } catch { New-DREvent -TaskId $TaskId -State Warning -Message ('{0} could not be uninstalled: {1}' -f $entry.Name, $_.Exception.Message) }
    }
}

function Invoke-DRAIReinstall {
    # The "Reinstall" choice after "Uninstall completely": Recall is switched back on by
    # Windows; a browser is installed from its maker's official download page.
    param([string]$TaskId, [string]$TestRoot)
    $base = $TaskId -replace '\.reinstall$', ''
    if ($base -eq 'ai.windows') {
        if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: Recall was not installed.'; return }
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName Recall -All -NoRestart -ErrorAction Stop | Out-Null
            New-DREvent -TaskId $TaskId -State Information -Message 'Recall was installed again. Restart Windows to finish.'
        } catch { New-DREvent -TaskId $TaskId -State Warning -Message ('Recall could not be installed: {0}' -f $_.Exception.Message) }
        return
    }
    $browser = switch ($base) { 'ai.chrome' {'Chrome'} 'ai.brave' {'Brave'} 'ai.firefox' {'Firefox'} default { $null } }
    if (-not $browser) { return }
    $target = switch ($browser) {
        'Chrome'  { 'https://www.google.com/chrome/' }
        'Brave'   { 'https://brave.com/download/' }
        'Firefox' { 'https://www.mozilla.org/firefox/new/' }
    }
    $message = 'The official {0} download page is open in the web browser. Download it and run the installer.' -f $browser
    if ($TestRoot) { $message = 'TEST MODE: nothing was opened. ' + $message }
    else { Open-DRForUser -Target $target }
    New-DREvent -TaskId $TaskId -State Information -Message $message
}

function Invoke-DRAIBrowserTask {
    param([string]$TaskId, [string]$Browser, [string]$TestRoot)
    # The customer signs in first, so the AI is switched off for the account they use.
    # Brave has no sign-in to check.
    if ($Browser -ne 'Brave' -and -not (Test-DRBrowserSignedIn -Browser $Browser)) {
        New-DREvent -TaskId $TaskId -State Warning -Message ('{0} is not signed in, so nothing was changed. Sign in to {0} first, then run this again.' -f $Browser)
        return
    }
    if ($TestRoot) {
        New-DREvent -TaskId $TaskId -State Information -Message ('TEST MODE: {0} settings were not changed.' -f $Browser)
        return
    }
    Set-DRAIPolicy -TaskId $TaskId -Target $Browser
}

function Get-DRAIStatus {
    <#
        For each AI Remover option: whether its app or browser is on this PC and,
        for a browser with accounts, whether one is signed in. Only reads.
    #>
    $build = 0
    try { $build = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber } catch { }
    $packages = @()
    try { $packages = @(Get-AppxPackage -ErrorAction Stop) } catch { }
    $programs = @(Get-DRInstalledProgramEntries)
    $modelBytes = [int64]0
    foreach ($model in @(Get-DRAIModelFolders)) { $modelBytes += $model.Bytes }
    $removedApps = @(Get-DRAIRemovedApps)
    $backupFolder = Get-DRAIBackupFolder
    $hasBackup = { param([string]$Name) Test-Path -LiteralPath (Join-Path $backupFolder ('AI_{0}.json' -f $Name)) -PathType Leaf }
    $appOf = @{ 'ai.copilot-app' = 'Copilot'; 'ai.m365-app' = 'M365Copilot'; 'ai.chatgpt-app' = 'ChatGPT'; 'ai.claude-app' = 'Claude' }
    $hasApp = {
        param([string]$App)
        [bool](@($packages | Where-Object { Test-DRAIAppMatch -App $App -Name $_.Name -Publisher $_.Publisher }).Count -or
               @($programs | Where-Object { Test-DRAIAppMatch -App $App -Name $_.Name -Publisher $_.Publisher }).Count)
    }

    foreach ($task in @(Get-DRTaskCatalog | Where-Object { $_.Category -eq 'AI' -and $_.Id -notlike '*.on' -and $_.Id -notlike '*.uninstall' -and $_.Id -notlike '*.reinstall' })) {
        $browser = Get-DRAIBrowserForTask -TaskId $task.Id
        $present = switch ($task.Id) {
            'ai.windows'     { $build -ge 22000 }
            'ai.check'       { $true }
            'ai.copilot-key' { $build -ge 22000 }
            'ai.remove-models' { $modelBytes -gt 0 }
            'ai.office-copilot' { [bool](Get-DRWordExe) }
            'ai.zoom'        { [bool](Get-DRZoomExe) }
            'ai.block-sites' { [bool]@(@('Edge','Chrome','Brave','Firefox') | Where-Object { Test-DRAIBrowserPresent -Browser $_ }).Count }
            'ai.gmail'       { $true }
            'ai.copilot-app' { & $hasApp 'Copilot' }
            'ai.m365-app'    { & $hasApp 'M365Copilot' }
            'ai.chatgpt-app' { & $hasApp 'ChatGPT' }
            'ai.claude-app'  { & $hasApp 'Claude' }
            'ai.adobe'       { & $hasApp 'Adobe' }
            'ai.search'      { $build -ge 22000 }
            'ai.restore'     { $true }
            default          { [bool]($browser -and (Test-DRAIBrowserPresent -Browser $browser)) }
        }
        # Which of the row's two choices can do anything right now.
        $canOff = $true; $canOn = $false; $canReinstall = $false
        if ($appOf.ContainsKey($task.Id)) {
            # A removed app keeps its row, so it can be reinstalled from here.
            $installed = [bool]$present
            $removed = $removedApps -contains $appOf[$task.Id]
            $present = $installed -or $removed
            $canOff = $installed
            $canOn = $removed -and -not $installed
        } elseif ($task.Id -eq 'ai.windows' -or $task.Id -in @('ai.edge','ai.chrome','ai.brave','ai.firefox')) {
            $canOn = & $hasBackup $(if ($task.Id -eq 'ai.windows') { 'Windows' } else { $browser })
            # A browser or Recall this Cleaner uninstalled keeps its row, so it can be put back from here.
            $reinstallKey = switch ($task.Id) { 'ai.windows' {'Recall'} 'ai.chrome' {'Chrome'} 'ai.brave' {'Brave'} 'ai.firefox' {'Firefox'} default { $null } }
            if ($reinstallKey) {
                $wasRemoved = $removedApps -contains $reinstallKey
                if ($task.Id -eq 'ai.windows') { $canReinstall = $wasRemoved }
                else {
                    $installed = [bool]$present
                    $present = $installed -or $wasRemoved
                    $canReinstall = $wasRemoved -and -not $installed
                    if ($canReinstall) { $canOff = $false; $canOn = $false }
                }
            }
        } elseif ($task.Id -in @('ai.adobe','ai.search')) {
            $canOn = & $hasBackup $(if ($task.Id -eq 'ai.adobe') { 'Adobe' } else { 'Search' })
        } elseif ($task.Id -eq 'ai.block-sites') {
            $canOn = [bool]@(Get-ChildItem -LiteralPath $backupFolder -Filter 'AI_Sites_*.json' -File -ErrorAction SilentlyContinue).Count
        } elseif ($task.Id -in @('ai.gmail','ai.office-copilot','ai.zoom','ai.edge-button','ai.copilot-key')) {
            $canOn = $true
        }
        # What is really true for this row, so the screen never claims more than the Cleaner knows.
        # Off = its AI is verified off, On = verified still on, Unknown = the Cleaner cannot read it.
        $state = 'Unknown'; $stateText = 'Cannot check - you decide'
        try {
            if ($appOf.ContainsKey($task.Id)) {
                if ($canOff) { $state = 'On'; $stateText = 'App is installed' } else { $state = 'Off'; $stateText = 'App is removed' }
            } elseif ($task.Id -eq 'ai.windows') {
                if (Test-DRAIPolicyApplied -Target Windows) { $state = 'Off' } else { $state = 'On' }
            } elseif ($task.Id -in @('ai.edge','ai.chrome','ai.brave','ai.firefox')) {
                if (Test-DRAIPolicyApplied -Target $browser) { $state = 'Off' } else { $state = 'On' }
            } elseif ($task.Id -eq 'ai.adobe') {
                if (Test-DRAIPolicyApplied -Target Adobe) { $state = 'Off' } else { $state = 'On' }
            } elseif ($task.Id -eq 'ai.search') {
                if (Test-DRAIPolicyApplied -Target Search) { $state = 'Off' } else { $state = 'On' }
            } elseif ($task.Id -eq 'ai.block-sites') {
                $openIn = @(@('Edge','Chrome','Brave','Firefox') | Where-Object { (Test-DRAIBrowserPresent -Browser $_) -and -not (Test-DRAISitesBlocked -Browser $_) })
                if ($openIn.Count) { $state = 'On'; $stateText = 'AI websites are still open in ' + ($openIn -join ', ') } else { $state = 'Off'; $stateText = 'AI websites are blocked' }
            } elseif ($task.Id -eq 'ai.remove-models') {
                if ($modelBytes -gt 0) { $state = 'On'; $stateText = 'AI models are still on this PC' } else { $state = 'Off'; $stateText = 'No AI models on this PC' }
            }
            if ($state -eq 'Off' -and $stateText -eq 'Cannot check - you decide') { $stateText = 'AI is turned off' }
            if ($state -eq 'On' -and $stateText -eq 'Cannot check - you decide') { $stateText = 'AI is still on' }
        } catch { $state = 'Unknown'; $stateText = 'Cannot check - you decide' }
        $needsSignIn = $browser -in @('Chrome','Edge','Firefox')
        [pscustomobject]@{
            TaskId      = $task.Id
            State       = $state
            StateText   = $stateText
            Present     = [bool]$present
            Browser     = $browser
            NeedsSignIn = [bool]$needsSignIn
            SignedIn    = [bool]($needsSignIn -and (Test-DRBrowserSignedIn -Browser $browser))
            Detail      = $(if ($task.Id -eq 'ai.remove-models' -and $modelBytes -gt 0) { Format-DRAIBytes $modelBytes } else { $null })
            CanOff      = [bool]$canOff
            CanOn       = [bool]$canOn
            CanReinstall = [bool]$canReinstall
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
            { $_ -like 'cleanup.cloud-*' } {
                # One clause for every cloud service; the catalog names which one.
                $service = $task.CloudService
                $matches = if ($TestRoot) { @(Get-Item -LiteralPath $TestRoot) } else { @(Get-DRPatternMatches (Get-DRCloudCachePatterns $service)) }
                if (@($matches).Count -eq 0) {
                    New-DREvent -TaskId $TaskId -State Information -Message ('{0} is not set up on this PC, so there was nothing to clear.' -f $service)
                } else {
                    foreach ($match in $matches) { Clear-DRFolderContents -FolderPath $match.FullName -TaskId $TaskId | Out-Null }
                    New-DREvent -TaskId $TaskId -State Information -Message ('Cleared {0} {1} cache location(s). Synced files were not touched.' -f @($matches).Count, $service)
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
                #
                # Recycle Bin, crash dumps and old driver packages are left out too:
                # each is something the customer could still need (a file to restore,
                # a crash to diagnose, a driver to roll back). They have their own
                # opt-in tasks where one exists.
                $cleanmgr = Join-Path $env:SystemRoot 'System32\cleanmgr.exe'
                if (-not $TestRoot) {
                    $volumeCaches = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
                    $items = @('BranchCache','Delivery Optimization Files','Downloaded Program Files','Internet Cache Files','Old ChkDsk Files','RetailDemo Offline Content','Setup Log Files','Temporary Files','Temporary Setup Files','Thumbnail Cache','Windows Error Reporting Files','Windows Defender')
                    foreach ($item in $items) {
                        $key = Join-Path $volumeCaches $item
                        if (Test-Path $key) { New-ItemProperty -Path $key -Name StateFlags0777 -Value 2 -PropertyType DWord -Force | Out-Null }
                    }
                    # Older builds ticked these in the same saved profile, and Windows
                    # remembers it, so they must be switched off explicitly.
                    foreach ($item in @('Recycle Bin','System error memory dump files','System error minidump files','Device Driver Packages')) {
                        $key = Join-Path $volumeCaches $item
                        if (Test-Path $key) { Remove-ItemProperty -Path $key -Name StateFlags0777 -ErrorAction SilentlyContinue }
                    }
                }
                Invoke-DRExternalCommand -TaskId $TaskId -FilePath $cleanmgr -Arguments @('/d','C:','/sagerun:777') -TestRoot $TestRoot | Out-Null
            }
            'cleanup.wu-download-cache' {
                if ($TestRoot) { Clear-DRFolderContents -FolderPath $TestRoot -TaskId $TaskId -TestRoot $TestRoot | Out-Null }
                else {
                    # Never pull installers out from under an update that is
                    # installing now or waiting on a restart to finish.
                    $installer = Get-Service -Name TrustedInstaller -ErrorAction SilentlyContinue
                    $rebootPending = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
                    if (($installer -and $installer.Status -eq 'Running') -or $rebootPending) {
                        New-DREvent -TaskId $TaskId -State Information -Message 'Windows Update is busy or waiting for a restart, so its download cache was left alone. Try again after restarting.'
                    } else {
                        $wuService = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
                        $wasRunning = $wuService -and $wuService.Status -eq 'Running'
                        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
                        try { Clear-DRFolderContents -FolderPath (Join-Path $env:WINDIR 'SoftwareDistribution\Download') -TaskId $TaskId | Out-Null }
                        finally { if ($wasRunning) { Start-Service -Name wuauserv -ErrorAction SilentlyContinue } }
                    }
                }
            }
            'cleanup.old-update-backups' {
                # A test root stands in for the Windows folder, so the same exact
                # names are looked for under it instead.
                $windowsDir = if ($TestRoot) { $TestRoot } else { $env:WINDIR }
                $folders = @(Get-DROldUpdateBackupFolders -WindowsDir $windowsDir)
                if ($folders.Count -eq 0) {
                    New-DREvent -TaskId $TaskId -State Information -Message 'There were no old Windows Update backup folders on this PC.'
                } else {
                    $removedFolders = 0
                    foreach ($folder in $folders) {
                        try { if (Remove-DRSafeItem -LiteralPath $folder.Path -AllowedRoot $folder.AllowedRoot) { $removedFolders++ } }
                        catch { New-DREvent -TaskId $TaskId -State Warning -Message ("Could not fully remove {0}: {1}" -f $folder.Path, $_.Exception.Message) }
                    }
                    New-DREvent -TaskId $TaskId -State Information -Message ("Removed {0} old Windows Update backup folder(s)." -f $removedFolders)
                }
            }
            'cleanup.thumbnail-cache' {
                if ($TestRoot) { Clear-DRFolderContents -FolderPath $TestRoot -TaskId $TaskId -TestRoot $TestRoot | Out-Null }
                else {
                    $folder = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
                    foreach ($match in @(Get-DRPatternMatches @((Join-Path $folder 'thumbcache_*.db')))) {
                        try { Remove-DRSafeItem -LiteralPath $match.FullName -AllowedRoot $folder | Out-Null }
                        catch { New-DREvent -TaskId $TaskId -State Warning -Message ("Skipped {0}: {1}" -f $match.Name, $_.Exception.Message) }
                    }
                }
            }
            'cleanup.shader-cache' {
                # Each cache folder is its own approved root, so only what is inside
                # it can go. Files a running game holds open are skipped quietly.
                $folders = if ($TestRoot) { @($TestRoot) } else { @(Get-DRShaderCachePaths) }
                if ($folders.Count -eq 0) {
                    New-DREvent -TaskId $TaskId -State Information -Message 'No graphics shader caches were found on this PC.'
                } else {
                    foreach ($folder in $folders) { Clear-DRFolderContents -FolderPath $folder -TaskId $TaskId | Out-Null }
                    New-DREvent -TaskId $TaskId -State Information -Message ('Cleared {0} graphics shader cache folder(s).' -f $folders.Count)
                }
            }
            'cleanup.icon-cache' {
                if ($TestRoot) { Clear-DRFolderContents -FolderPath $TestRoot -TaskId $TaskId -TestRoot $TestRoot | Out-Null }
                else {
                    $folder = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
                    # Remember the folder windows that are already open. With
                    # "separate process" folder windows turned on they survive the
                    # restart, and they must not be closed along with the stray one.
                    $windowsBefore = @()
                    try { $windowsBefore = @((New-Object -ComObject Shell.Application).Windows() | ForEach-Object { try { $_.HWND } catch { } }) } catch { }
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                    foreach ($match in @(Get-DRPatternMatches @((Join-Path $folder 'iconcache_*.db')))) {
                        try { Remove-DRSafeItem -LiteralPath $match.FullName -AllowedRoot $folder | Out-Null }
                        catch { New-DREvent -TaskId $TaskId -State Warning -Message ("Skipped {0}: {1}" -f $match.Name, $_.Exception.Message) }
                    }
                    Start-Process explorer.exe
                    # explorer.exe with no arguments restarts the shell AND opens a
                    # new Explorer window - closing that stray window here, not the
                    # shell itself, is what keeps this from popping a folder open
                    # mid-scan.
                    Start-Sleep -Milliseconds 1200
                    try {
                        $shellApp = New-Object -ComObject Shell.Application
                        foreach ($openWindow in @($shellApp.Windows())) {
                            try { if ($openWindow.FullName -match 'explorer\.exe$' -and $windowsBefore -notcontains $openWindow.HWND) { $openWindow.Quit() } } catch { }
                        }
                    } catch { }
                }
            }
            'cleanup.wer-queue' {
                if ($TestRoot) { Clear-DRFolderContents -FolderPath $TestRoot -TaskId $TaskId -TestRoot $TestRoot | Out-Null }
                else {
                    foreach ($folder in @((Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'), (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'))) {
                        Clear-DRFolderContents -FolderPath $folder -TaskId $TaskId | Out-Null
                    }
                }
            }
            'cleanup.delivery-optimization-cache' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: Delivery Optimization cache was not changed.' }
                else {
                    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop }
                    else { New-DREvent -TaskId $TaskId -State Warning -Message 'Delivery Optimization cache cmdlet is not available on this system.' }
                }
            }
            'cleanup.jumplists' {
                $folders = if ($TestRoot) { @($TestRoot) } else { @((Join-Path $env:APPDATA 'Microsoft\Windows\Recent\AutomaticDestinations'), (Join-Path $env:APPDATA 'Microsoft\Windows\Recent\CustomDestinations')) }
                foreach ($folder in $folders) {
                    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
                    foreach ($item in @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue)) {
                        # This one file holds File Explorer's pinned Quick Access
                        # folders - a list people built by hand, not history.
                        if ($item.Name -eq $script:DRQuickAccessJumpList) { continue }
                        try { Remove-DRSafeItem -LiteralPath $item.FullName -AllowedRoot $folder | Out-Null }
                        catch { New-DREvent -TaskId $TaskId -State Warning -Message ("Skipped {0}: {1}" -f $item.Name, $_.Exception.Message) }
                    }
                }
            }
            'cleanup.memory-dumps' {
                if ($TestRoot) { Clear-DRFolderContents -FolderPath $TestRoot -TaskId $TaskId -TestRoot $TestRoot | Out-Null }
                else {
                    $dumpFile = Join-Path $env:WINDIR 'Memory.dmp'
                    if (Test-Path -LiteralPath $dumpFile) { Remove-DRSafeItem -LiteralPath $dumpFile -AllowedRoot $env:WINDIR | Out-Null }
                    Clear-DRFolderContents -FolderPath (Join-Path $env:WINDIR 'Minidump') -TaskId $TaskId | Out-Null
                }
            }
            'cleanup.old-restore-points' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: restore points were not changed.' }
                else {
                    # Removes System Restore points one by one through System
                    # Restore itself. vssadmin was not used because it deletes
                    # any shadow copy - including the ones backup programs make.
                    if (-not ('DRDirect.SystemRestore' -as [type])) {
                        Add-Type -Namespace DRDirect -Name SystemRestore -MemberDefinition '[DllImport("srclient.dll")] public static extern int SRRemoveRestorePoint(int dwRPNum);'
                    }
                    $points = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber)
                    if ($points.Count -le 1) {
                        New-DREvent -TaskId $TaskId -State Information -Message 'There were no older restore points to remove.'
                    } else {
                        $removedPoints = 0
                        foreach ($point in $points[0..($points.Count - 2)]) {
                            $result = [DRDirect.SystemRestore]::SRRemoveRestorePoint([int]$point.SequenceNumber)
                            if ($result -eq 0) { $removedPoints++ }
                            else { New-DREvent -TaskId $TaskId -State Warning -Message ("Could not remove restore point '{0}' (code {1})." -f $point.Description, $result) }
                        }
                        New-DREvent -TaskId $TaskId -State Information -Message ("Removed {0} older restore point(s); the most recent one was kept." -f $removedPoints)
                    }
                }
            }
            'cleanup.event-logs' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: event logs were not cleared.' }
                else {
                    # The Security log is left alone on purpose: clearing it is a
                    # classic sign of an intruder covering tracks, so antivirus
                    # flags it and it would wipe the customer's own audit trail.
                    foreach ($log in @('Application','System')) {
                        $errorText = & wevtutil.exe cl $log 2>&1
                        if ($LASTEXITCODE -ne 0) { New-DREvent -TaskId $TaskId -State Warning -Message ("Could not clear {0}: {1}" -f $log, ($errorText | Out-String).Trim()) }
                    }
                }
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
            'security.checkup' {
                # Read-only, so it looks at the real PC even in test mode.
                $status = @(Get-DRSecurityStatus)
                foreach ($item in $status) {
                    New-DREvent -TaskId $TaskId -State $(if ($item.Ok) { 'Information' } else { 'Warning' }) -Message $item.Message
                }
                $problems = @($status | Where-Object { -not $_.Ok })
                if (-not $problems.Count) {
                    New-DREvent -TaskId $TaskId -State Information -Message 'All protection is on. Nothing was changed.'
                } elseif (@($problems | Where-Object Fixable).Count) {
                    New-DREvent -TaskId $TaskId -State Warning -Message ('{0} thing(s) need attention. Tick "Turn protection back on" to fix them. Nothing was changed.' -f $problems.Count)
                } else {
                    New-DREvent -TaskId $TaskId -State Warning -Message ('{0} thing(s) need attention. Nothing was changed.' -f $problems.Count)
                }
            }
            'security.checkup-fix' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: protection settings were not changed.' }
                else { Repair-DRSecurityProtection -TaskId $TaskId }
            }
            'security.typing-privacy' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: typing settings were not changed.' }
                else { Set-DRTypingPrivacy -TaskId $TaskId }
            }
            'security.typing-privacy-restore' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: typing settings were not changed.' }
                else { Restore-DRTypingPrivacy -TaskId $TaskId }
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
            'ai.windows' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: Windows AI settings were not changed.' }
                else { Set-DRAIPolicy -TaskId $TaskId -Target Windows }
            }
            'ai.search' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: Windows Search settings were not changed.' }
                else { Set-DRAIPolicy -TaskId $TaskId -Target Search }
            }
            'ai.adobe' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: Adobe AI settings were not changed.' }
                else { Set-DRAIPolicy -TaskId $TaskId -Target Adobe }
            }
            'ai.edge'    { Invoke-DRAIBrowserTask -TaskId $TaskId -Browser Edge -TestRoot $TestRoot }
            'ai.chrome'  { Invoke-DRAIBrowserTask -TaskId $TaskId -Browser Chrome -TestRoot $TestRoot }
            'ai.brave'   { Invoke-DRAIBrowserTask -TaskId $TaskId -Browser Brave -TestRoot $TestRoot }
            'ai.firefox' { Invoke-DRAIBrowserTask -TaskId $TaskId -Browser Firefox -TestRoot $TestRoot }
            'ai.block-sites' { Invoke-DRAISiteBlock -TaskId $TaskId -TestRoot $TestRoot }
            'ai.remove-models' { Remove-DRAIModels -TaskId $TaskId -TestRoot $TestRoot }
            { $_ -like 'ai.*.on' } { Invoke-DRAITurnBackOn -TaskId $TaskId -TestRoot $TestRoot }
            # Read-only, so it looks at the real PC even in test mode.
            'ai.check' { Invoke-DRAICheck -TaskId $TaskId }
            { $_ -in @('ai.gmail','ai.office-copilot','ai.zoom','ai.edge-button','ai.copilot-key') } { Invoke-DRAIGuidedTask -TaskId $TaskId -TestRoot $TestRoot }
            { $_ -like 'ai.*.uninstall' } { Uninstall-DRAICompletely -TaskId $TaskId -TestRoot $TestRoot }
            { $_ -like 'ai.*.reinstall' } { Invoke-DRAIReinstall -TaskId $TaskId -TestRoot $TestRoot }
            { $_ -in @('ai.copilot-app','ai.m365-app','ai.chatgpt-app','ai.claude-app') } {
                $app = switch ($TaskId) { 'ai.copilot-app' {'Copilot'} 'ai.m365-app' {'M365Copilot'} 'ai.chatgpt-app' {'ChatGPT'} 'ai.claude-app' {'Claude'} }
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: no apps were removed.' }
                else { Remove-DRAIApp -TaskId $TaskId -App $app }
            }
            'ai.restore' {
                if ($TestRoot) { New-DREvent -TaskId $TaskId -State Information -Message 'TEST MODE: AI settings were not changed.' }
                else { Restore-DRAIPolicy -TaskId $TaskId }
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
    $finishedAt = Get-Date
    $elapsed = $finishedAt - $StartedAt
    $lines.Add(('Started: {0}' -f $StartedAt))
    $lines.Add(('Finished: {0}' -f $finishedAt))
    $lines.Add(('Total time it took: {0:00}:{1:00}:{2:00}' -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds))
    $lines.Add('')
    $lines.Add('Selected tasks:')
    foreach ($id in $TaskId) { $lines.Add('  - ' + $id) }
    $lines.Add('')
    $lines.Add('Events:')
    foreach ($event in $Events) { $lines.Add(('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}: {3}' -f $event.Timestamp, $event.State, $event.TaskId, $event.Message)) }
    [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($true))
    return $path
}
