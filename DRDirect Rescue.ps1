# DRDirect Imager - rescue edition (text mode, runs inside the rescue USB). Windows PowerShell 5.1.
. (Join-Path $PSScriptRoot 'DRDirect Imager Engine.ps1')
if (-not (Get-Command Format-TookTime -ErrorAction SilentlyContinue)) {
    function Format-TookTime([double]$Seconds) { $t = [TimeSpan]::FromSeconds([Math]::Round([Math]::Max($Seconds, 0))); if ($t.TotalHours -ge 1) { '{0} h {1} min {2} sec' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds } elseif ($t.TotalMinutes -ge 1) { '{0} min {1} sec' -f $t.Minutes, $t.Seconds } else { '{0} sec' -f $t.Seconds } }
}

# ---------- PC lock: this rescue USB starts only on the PC it was made for ----------
function Get-RescuePcHashes {
    # Same IDs and same hashing as the maker: motherboard UUID, and UUID-boardserial, lower case, SHA-256.
    $uuid = ([string](Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID).Trim()
    $serial = ([string](Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue).SerialNumber).Trim()
    $ids = @(); if ($uuid) { $ids += $uuid.ToLowerInvariant() }; if ($uuid -and $serial) { $ids += ('{0}-{1}' -f $uuid, $serial).ToLowerInvariant() }
    foreach ($id in $ids) { ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($id)) | ForEach-Object { $_.ToString('X2') }) -join '' }
}
function Get-RescueUsbDrive {
    # The USB this program was started from: the volume named DRDIRECT.
    Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq 'DRDIRECT' -and $_.DriveLetter } | Select-Object -First 1
}
# Owner password lockout, kept on the stick in owner.wait: after 3 wrong passwords the stick waits
# 5 minutes; after every further 3 wrong passwords it waits 30 minutes. A right password clears it.
function Get-OwnerWait([string]$File) {
    $r = @{ Rounds = 0; Until = [datetime]::MinValue }
    try {
        $l = @(Get-Content -LiteralPath $File -ErrorAction Stop)
        $r.Rounds = [int]$l[0]; $r.Until = [datetime]::new([int64]$l[1], [DateTimeKind]::Utc)
    } catch { }
    $r
}
function Set-OwnerWait([string]$File, [int]$Rounds) {
    $mins = if ($Rounds -le 1) { 5 } else { 30 }
    $until = [datetime]::UtcNow.AddMinutes($mins)
    try { Set-Content -LiteralPath $File -Value @([string]$Rounds, [string]$until.Ticks) -Encoding ASCII -Force } catch { }
    $mins
}
function Test-RescuePcLock {
    $vol = Get-RescueUsbDrive
    if (-not $vol) { return @{ Ok = $false; Why = 'The Rescue USB could not find itself, so it cannot check which PC it is for.' } }
    $file = "$($vol.DriveLetter):\DRDirect\pc.id"
    # A copy of the stick onto another stick refuses to start (the stick's own serial number no longer matches).
    if (-not (Test-StickSerial $vol.DriveLetter "$($vol.DriveLetter):\DRDirect\usb.id")) { return @{ Ok = $false; Why = 'This USB is a copy and cannot be used. Ask DRDirect for a new Rescue USB.' } }
    # Master (owner) stick: works on any PC, but only with the owner password.
    $ownerFile = "$($vol.DriveLetter):\DRDirect\owner.id"
    if (Test-Path -LiteralPath $ownerFile) {
        $rec = [string](Get-Content -LiteralPath $ownerFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        $waitFile = "$($vol.DriveLetter):\DRDirect\owner.wait"
        $wait = Get-OwnerWait $waitFile
        $left = [math]::Ceiling(($wait.Until - [datetime]::UtcNow).TotalMinutes)
        if ($left -gt 0) { return @{ Ok = $false; Why = "Too many wrong owner passwords. This stick is locked. Try again in $left minute(s)." } }
        for ($try = 1; $try -le 3; $try++) {
            $sec = Read-Host '  Owner password' -AsSecureString
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
            if (Test-OwnerRecord $plain $rec) { Remove-Item -LiteralPath $waitFile -Force -ErrorAction SilentlyContinue; return @{ Ok = $true; Why = '' } }
            Write-Host '  Wrong password.' -ForegroundColor Yellow
        }
        $mins = Set-OwnerWait $waitFile ($wait.Rounds + 1)
        return @{ Ok = $false; Why = "Wrong owner password three times. This stick is now locked for $mins minutes." }
    }
    if (-not (Test-Path -LiteralPath $file)) { return @{ Ok = $false; Why = 'This USB has no PC lock file. Make it again with the Rescue USB button.' } }
    $allowed = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
    $mine = @(Get-RescuePcHashes | ForEach-Object { $_.ToUpperInvariant() })
    if (-not $mine.Count) { return @{ Ok = $false; Why = 'This PC does not report an ID, so the lock cannot be checked.' } }
    foreach ($h in $mine) { if ($allowed -contains $h) { return @{ Ok = $true; Why = '' } } }
    @{ Ok = $false; Why = 'This Rescue USB was made for a different PC.' }
}
$lockResult = Test-RescuePcLock
if (-not $lockResult.Ok) {
    Clear-Host
    Write-Host ''
    Write-Host '  DRDirect Imager - Rescue' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  $($lockResult.Why)" -ForegroundColor Yellow
    Write-Host '  It will not run here. The PC will restart in 15 seconds.'
    Start-Sleep -Seconds 15
    wpeutil reboot
    return
}

# ---------- The rescue screen: pick a job on the left, fill in two boxes, press Start ----------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:mode = 'clone'
$script:job = $null
$script:disks = @()
$script:stickDisk = -1

function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Font([float]$size, [string]$style = 'Regular') { New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]$style) }

# ---- 3D Max look: gradient face, gloss band, dark bottom edge, white rim, drop shadow (same recipe as the app) ----
function Set-DoubleBuffer($ctl) { try { [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($ctl, $true, $null) } catch { } }
function New-RoundPath($r, [int]$rad) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath; $d = $rad * 2
    $p.AddArc($r.X, $r.Y, $d, $d, 180, 90); $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90); $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90); $p.CloseFigure(); $p
}
function Set-3D($b, [string]$kind) {
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.UseVisualStyleBackColor = $false
    $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent; $b.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
    $b.AccessibleName = $kind; Set-DoubleBuffer $b
    $b.Add_MouseEnter({ $this.Invalidate() }); $b.Add_MouseLeave({ $this.Invalidate() })
    $b.Add_Paint({
        $s = $this; $e = $_; $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
        $g.Clear($s.Parent.BackColor)
        $kind = $s.AccessibleName
        $selected = ($kind -eq 'nav') -and ($script:mode -eq [string]$s.Tag)
        $hot = $s.ClientRectangle.Contains($s.PointToClient([System.Windows.Forms.Cursor]::Position))
        if (-not $s.Enabled) { $stops = '#A9B4C9', '#8E9BB5', '#74829F' }
        elseif ($kind -eq 'done') { $stops = '#5BEA8C', '#16B04F', '#0A7A33' }
        elseif ($kind -eq 'go' -or $selected) { $stops = '#6FD0FF', '#2A86F0', '#1E5FD0' }
        else { $stops = '#5272AD', '#28396B', '#111C3B' }
        $rad = [Math]::Min(14, [int]($s.Height / 4)); $depth = 6
        $face = New-Object System.Drawing.Rectangle(1, 0, ($s.Width - 3), ($s.Height - $depth - 1))
        $shadow = New-Object System.Drawing.Rectangle(1, $depth, ($s.Width - 3), ($s.Height - $depth - 1))
        $sb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(176, 0, 8, 20)); $sp = New-RoundPath $shadow $rad; $g.FillPath($sb, $sp)
        $fp = New-RoundPath $face $rad
        $c0 = [System.Drawing.ColorTranslator]::FromHtml($stops[0]); $c1 = [System.Drawing.ColorTranslator]::FromHtml($stops[1]); $c2 = [System.Drawing.ColorTranslator]::FromHtml($stops[2])
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($face, $c0, $c2, 90)
        $bl = New-Object System.Drawing.Drawing2D.ColorBlend 3
        $bl.Colors = [System.Drawing.Color[]]@($c0, $c1, $c2); $bl.Positions = [single[]]@(0, 0.5, 1); $lg.InterpolationColors = $bl
        $g.FillPath($lg, $fp)
        $g.SetClip($fp)
        $gloss = New-Object System.Drawing.Rectangle($face.X, $face.Y, $face.Width, [int]($face.Height * 0.48))
        $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(38, 255, 255, 255))), $gloss)
        $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(85, 0, 0, 0))), $face.X, ($face.Bottom - 4), $face.Width, 4)
        if ($hot -and $s.Enabled) { $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(34, 255, 255, 255))), $fp) }
        $g.ResetClip()
        $g.DrawPath((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(136, 255, 255, 255)), 1), $fp)
        $sf = New-Object System.Drawing.StringFormat; $sf.LineAlignment = 'Center'
        $left = ($kind -eq 'nav' -and $s.TextAlign -eq 'MiddleLeft')
        $sf.Alignment = $(if ($left) { 'Near' } else { 'Center' })
        $x = $(if ($left) { 20 } else { 0 })
        $tr = New-Object System.Drawing.RectangleF($x, 0, $s.Width, $face.Height)
        $g.DrawString($s.Text, $s.Font, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 0, 8, 32))), (New-Object System.Drawing.RectangleF(($x + 1), 2, $s.Width, $face.Height)), $sf)
        $g.DrawString($s.Text, $s.Font, (New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#F2F7FF'))), $tr, $sf)
    })
}
function Set-Gradient($panel, [string]$top, [string]$bottom) {
    Set-DoubleBuffer $panel; $panel.Tag = "$top|$bottom"
    $panel.Add_Paint({
        $c = ([string]$this.Tag).Split('|'); $r = $this.ClientRectangle; if ($r.Width -lt 2 -or $r.Height -lt 2) { return }
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($r, [System.Drawing.ColorTranslator]::FromHtml($c[0]), [System.Drawing.ColorTranslator]::FromHtml($c[1]), 90)
        $_.Graphics.FillRectangle($lg, $r)
    })
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DRDirect Clone & Backup - Rescue'
if ($script:RescueIcon) { $form.Icon = $script:RescueIcon }
$form.FormBorderStyle = 'None'; $form.WindowState = 'Maximized'; $form.BackColor = C '#D9E0EE'; $form.Font = Font 12

# left side
$side = New-Object System.Windows.Forms.Panel; $side.Dock = 'Left'; $side.Width = 290; $side.BackColor = C '#12203A'
$brand = New-Object System.Windows.Forms.Label; $brand.Text = 'DRDirect'; $brand.ForeColor = 'White'; $brand.Font = Font 26 'Bold'; $brand.Location = '22,22'; $brand.AutoSize = $true
$brand2 = New-Object System.Windows.Forms.Label; $brand2.Text = 'Clone && Backup  -  Rescue'; $brand2.ForeColor = C '#C9D5E6'; $brand2.Font = Font 12; $brand2.Location = '26,72'; $brand2.AutoSize = $true
$side.Controls.AddRange(@($brand, $brand2))
$script:RescueIcon = $null
$logoPath = Join-Path $PSScriptRoot 'DRDirect Logo.png'
if (Test-Path -LiteralPath $logoPath) {
    try {
        $logoImg = [System.Drawing.Image]::FromFile($logoPath)
        $logoPic = New-Object System.Windows.Forms.PictureBox; $logoPic.Image = $logoImg; $logoPic.SizeMode = 'Zoom'; $logoPic.Size = '84,84'; $logoPic.Location = '16,14'; $logoPic.BackColor = [System.Drawing.Color]::Transparent
        $side.Controls.Add($logoPic)
        $brand.Location = '108,22'; $brand2.Location = '110,74'; $brand2.Font = Font 10
        $lblVer = New-Object System.Windows.Forms.Label; $lblVer.Text = 'Version 1.0.0'; $lblVer.ForeColor = C '#FFE14D'; $lblVer.Font = Font 12 'Bold'; $lblVer.AutoSize = $true; $lblVer.Location = '110,96'; $lblVer.BackColor = [System.Drawing.Color]::Transparent; $side.Controls.Add($lblVer)
        $script:RescueIcon = [System.Drawing.Icon]::FromHandle(([System.Drawing.Bitmap]$logoImg).GetHicon())
    } catch { }
}
$nav = @{}
function New-NavButton([string]$key, [string]$text, [int]$top) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Tag = $key; $b.Location = New-Object System.Drawing.Point(20, $top); $b.Size = '250,60'
    $b.ForeColor = 'White'; $b.Font = Font 15 'Bold'; $b.TextAlign = 'MiddleLeft'; $b.Cursor = 'Hand'
    Set-3D $b 'nav'
    $side.Controls.Add($b); $nav[$key] = $b; $b
}
[void](New-NavButton 'clone' 'SmartCopy' 130)
[void](New-NavButton 'secure' 'Secure' 200)
[void](New-NavButton 'restore' 'Restore' 270)
[void](New-NavButton 'check' 'Check an image' 340)
$btnFiles = New-NavButton 'files' 'Files' 410
# Fix start-up: rebuilds the Windows start-up files on this PC's own drive with Microsoft's bcdboot (always on the Rescue USB).
$btnFixBoot = New-NavButton 'fixboot' 'Fix start-up' 480
# Windows repair: only on a stick that also carries Microsoft's Windows Setup (added by the DRDirect USB maker).
# winsetup.id holds the start-up menu entry for Windows Setup in each of the stick's two boot stores.
$script:winSetupIds = @{}
$btnWinRepair = $null
try {
    $wv = Get-RescueUsbDrive
    if ($wv) {
        $wf = "$($wv.DriveLetter):\DRDirect\winsetup.id"
        if (Test-Path -LiteralPath $wf) {
            foreach ($line in @(Get-Content -LiteralPath $wf -ErrorAction Stop)) {
                if ($line -match '^\s*(BIOS|EFI)\s+(\{[0-9a-fA-F-]{36}\})\s*$') { $script:winSetupIds[$Matches[1]] = $Matches[2] }
            }
        }
    }
} catch { }
if ($script:winSetupIds.Count) { $btnWinRepair = New-NavButton 'winrepair' 'Windows repair' 550 }
$btnRestart = New-NavButton 'restart' 'Restart the PC' 0
$side.Add_Resize({ $btnRestart.Top = $side.Height - 100 }); $btnRestart.Top = 700
$form.Controls.Add($side)

# right side
$main = New-Object System.Windows.Forms.Panel; $main.Dock = 'Fill'
$form.Controls.Add($main); $main.BringToFront()
$lblKicker = New-Object System.Windows.Forms.Label; $lblKicker.Text = 'THIS PC'; $lblKicker.ForeColor = C '#5B6B86'; $lblKicker.Font = Font 11 'Bold'; $lblKicker.Location = '40,28'; $lblKicker.AutoSize = $true
$lblHead = New-Object System.Windows.Forms.Label; $lblHead.ForeColor = C '#172033'; $lblHead.Font = Font 30 'Bold'; $lblHead.Location = '36,48'; $lblHead.AutoSize = $true
$lblSub = New-Object System.Windows.Forms.Label; $lblSub.ForeColor = C '#3A4A6A'; $lblSub.Font = Font 13; $lblSub.Location = '40,112'; $lblSub.Size = '900,30'

$card = New-Object System.Windows.Forms.Panel; $card.Location = '40,160'; $card.Size = '960,620'; $card.BackColor = 'White'; $card.BorderStyle = 'FixedSingle'
function New-Lbl([string]$t = '') { $l = New-Object System.Windows.Forms.Label; $l.ForeColor = C '#16275A'; $l.Font = Font 12 'Bold'; $l.AutoSize = $true; $l.Text = $t; $card.Controls.Add($l); $l }
function New-Combo([bool]$list) { $c = New-Object System.Windows.Forms.ComboBox; $c.Font = Font 13; $c.Width = 780; $c.DropDownStyle = $(if ($list) { 'DropDownList' } else { 'DropDown' }); $card.Controls.Add($c); $c }
$lblA = New-Lbl; $lblB = New-Lbl
$cbDiskA = New-Combo $true; $cbDiskB = New-Combo $true; $cbImg = New-Combo $false
$btnBrowse = New-Object System.Windows.Forms.Button; $btnBrowse.Text = 'Browse...'; $btnBrowse.Size = '130,34'; $btnBrowse.Font = Font 11 'Bold'; $btnBrowse.Size = '130,40'; $btnBrowse.ForeColor = 'White'; Set-3D $btnBrowse 'nav'; $card.Controls.Add($btnBrowse)
$btnPickA = New-Object System.Windows.Forms.Button; $btnPickA.Text = 'Choose...'; $btnPickA.Font = Font 11 'Bold'; $btnPickA.Size = '130,40'; $btnPickA.ForeColor = 'White'; Set-3D $btnPickA 'nav'; $card.Controls.Add($btnPickA)
$btnPickB = New-Object System.Windows.Forms.Button; $btnPickB.Text = 'Choose...'; $btnPickB.Font = Font 11 'Bold'; $btnPickB.Size = '130,40'; $btnPickB.ForeColor = 'White'; Set-3D $btnPickB 'nav'; $card.Controls.Add($btnPickB)
$chkErase = New-Object System.Windows.Forms.CheckBox; $chkErase.ForeColor = C '#9A1B1B'; $chkErase.Font = Font 12 'Bold'; $chkErase.AutoSize = $true; $chkErase.Location = '24,350'; $card.Controls.Add($chkErase)
$lblOpt = New-Lbl 'Options'; $lblOpt.Location = '24,222'
$chkTrim = New-Object System.Windows.Forms.CheckBox; $chkTrim.Text = 'Trim  (tell the SSD which space is free, after the copy)'; $chkTrim.Checked = $false; $chkTrim.AutoSize = $true; $chkTrim.Font = Font 12; $chkTrim.Location = '24,252'; $card.Controls.Add($chkTrim)
$chkVerify = New-Object System.Windows.Forms.CheckBox; $chkVerify.AutoSize = $true; $chkVerify.Font = Font 12; $chkVerify.Location = '24,284'; $card.Controls.Add($chkVerify)
$chkAfter = New-Object System.Windows.Forms.CheckBox; $chkAfter.Text = 'After completion:'; $chkAfter.AutoSize = $true; $chkAfter.Font = Font 12; $chkAfter.Location = '24,316'; $card.Controls.Add($chkAfter)
$cbAfter = New-Object System.Windows.Forms.ComboBox; $cbAfter.DropDownStyle = 'DropDownList'; $cbAfter.Font = Font 12; $cbAfter.Width = 190; $cbAfter.Location = '230,312'
[void]$cbAfter.Items.AddRange(@('Restart', 'Shut down')); $cbAfter.SelectedIndex = 0; $card.Controls.Add($cbAfter)
$lblAfter2 = New-Object System.Windows.Forms.Label; $lblAfter2.Text = 'only when it finished without errors'; $lblAfter2.ForeColor = C '#5B6B86'; $lblAfter2.Font = Font 11; $lblAfter2.AutoSize = $true; $lblAfter2.Location = '436,318'; $card.Controls.Add($lblAfter2)
$lblProblem = New-Object System.Windows.Forms.Label; $lblProblem.ForeColor = C '#C0261D'; $lblProblem.Font = Font 12; $lblProblem.Location = '24,392'; $lblProblem.Size = '900,56'; $card.Controls.Add($lblProblem)
$btnStart = New-Object System.Windows.Forms.Button; $btnStart.Text = 'Start'; $btnStart.Size = '200,56'; $btnStart.Location = '24,455'
$btnStart.Size = '220,64'; $btnStart.ForeColor = 'White'; $btnStart.Font = Font 17 'Bold'; $btnStart.Cursor = 'Hand'; Set-3D $btnStart 'go'; $card.Controls.Add($btnStart)
$btnStop = New-Object System.Windows.Forms.Button; $btnStop.Text = 'Stop'; $btnStop.Size = '130,64'; $btnStop.Location = '260,455'; $btnStop.Font = Font 15 'Bold'; $btnStop.ForeColor = 'White'; Set-3D $btnStop 'nav'; $btnStop.Visible = $false; $card.Controls.Add($btnStop)
$bar = New-Object System.Windows.Forms.ProgressBar; $bar.Location = '24,530'; $bar.Size = '910,26'; $bar.Maximum = 1000; $card.Controls.Add($bar)
$lblProg = New-Object System.Windows.Forms.Label; $lblProg.ForeColor = C '#16275A'; $lblProg.Font = Font 12; $lblProg.Location = '24,556'; $lblProg.Size = '910,60'; $card.Controls.Add($lblProg)
$btnDone = New-Object System.Windows.Forms.Button; $btnDone.Text = 'You are all done!'; $btnDone.Size = '600,84'; $btnDone.Font = Font 28 'Bold'; $btnDone.ForeColor = 'White'; $btnDone.TabStop = $false; $btnDone.Visible = $false
Set-3D $btnDone 'done'; $btnDone.Anchor = 'Top, Right'; $btnDone.Location = '380,26'
$main.Controls.AddRange(@($lblKicker, $lblHead, $lblSub, $card, $btnDone))
$main.Add_Resize({ $btnDone.Left = [Math]::Max(380, $main.Width - $btnDone.Width - 40) })
Set-Gradient $side '#1A2E4C' '#12203A'; Set-Gradient $main '#D9E0EE' '#97A7C5'; Set-Gradient $card '#FFFFFF' '#EAF3FF'
$card.BorderStyle = 'None'
foreach ($c in @($lblKicker, $lblHead, $lblSub, $brand, $brand2)) { $c.BackColor = [System.Drawing.Color]::Transparent }
foreach ($c in $card.Controls) { if ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.CheckBox]) { $c.BackColor = [System.Drawing.Color]::Transparent } }
$card.Add_Paint({ $_.Graphics.DrawRectangle((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(153, 255, 255, 255)), 1), 0, 0, ($this.Width - 1), ($this.Height - 1)) })

function Place($label, $ctrl, [int]$y, [bool]$withBrowse) {
    $label.Location = New-Object System.Drawing.Point(24, $y)
    $ctrl.Location = New-Object System.Drawing.Point(24, ($y + 32)); $ctrl.Visible = $true; $label.Visible = $true
    if ($withBrowse) { $ctrl.Width = 640; $btnBrowse.Location = New-Object System.Drawing.Point(($ctrl.Right + 12), ($y + 31)); $btnBrowse.Visible = $true }
    elseif ($ctrl -eq $cbDiskA) { $ctrl.Width = 640; $btnPickA.Location = New-Object System.Drawing.Point(($ctrl.Right + 12), ($y + 31)); $btnPickA.Visible = $true }
    elseif ($ctrl -eq $cbDiskB) { $ctrl.Width = 640; $btnPickB.Location = New-Object System.Drawing.Point(($ctrl.Right + 12), ($y + 31)); $btnPickB.Visible = $true }
    else { $ctrl.Width = 780 }
}

# ---------- Chooser windows for the rescue screen: pick the Image like in Miray (disks on the left, folders and files on the right), and pick the Target drive from a list ----------
# The standard Windows file dialog does not work inside the rescue, so these are drawn by the program itself.

function Set-WindowsDriveLetters {
    # Inside the rescue only, once: give every drive the same letter it has in Windows (Windows on C:, and so on),
    # so the rescue shows "Disk 0 ... C:" just like in Windows instead of D:. The letters come from the PC's own
    # Windows list of drive letters. Nothing on the drives changes; the letters last only until the rescue restarts.
    # The Rescue USB itself and X: are never moved.
    if ($env:SystemDrive -ne 'X:' -or $script:lettersMatched) { return }
    $script:lettersMatched = $true
    $hiveName = 'DRD_WINSYS'
    try {
        $diskBy = @{}; foreach ($dk in @(Get-Disk -ErrorAction SilentlyContinue)) { $diskBy[[int]$dk.Number] = $dk }
        $stick = Get-RescueUsbDrive
        $stickLetter = if ($stick) { [string]$stick.DriveLetter } else { '' }
        $stickDiskNo = -1
        if ($stickLetter) { try { $stickDiskNo = [int](Get-Partition -DriveLetter $stickLetter -ErrorAction Stop).DiskNumber } catch { } }

        # How Windows names a partition in its list: GPT = "DMIO:ID:" + partition GUID, MBR = disk signature + start offset.
        $keyOf = {
            param($p)
            $dk = $diskBy[[int]$p.DiskNumber]; if (-not $dk) { return '' }
            [byte[]]$b = $null
            if ([string]$dk.PartitionStyle -eq 'GPT' -and $p.Guid) { $b = [Text.Encoding]::ASCII.GetBytes('DMIO:ID:') + ([guid]([string]$p.Guid)).ToByteArray() }
            elseif ([string]$dk.PartitionStyle -eq 'MBR' -and $dk.Signature) { $b = [BitConverter]::GetBytes([uint32]$dk.Signature) + [BitConverter]::GetBytes([uint64]$p.Offset) }
            if ($b) { [BitConverter]::ToString($b) } else { '' }
        }
        $readMap = {
            param([string]$sysFile)
            $map = @{}
            & reg.exe load "HKLM\$hiveName" $sysFile 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return $map }
            try {
                $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("$hiveName\MountedDevices")
                if ($k) {
                    foreach ($n in $k.GetValueNames()) {
                        if ($n -match '^\\DosDevices\\([A-Z]):$') { $v = $k.GetValue($n); if ($v -is [byte[]] -and $v.Length -ge 12) { $map[$Matches[1]] = [BitConverter]::ToString($v) } }
                    }
                    $k.Close()
                }
            } catch { }
            $k = $null; [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            & reg.exe unload "HKLM\$hiveName" 2>&1 | Out-Null
            $map
        }

        # Find the Windows on this PC. With more than one, use the one whose own list says it is C:.
        $parts = @(Get-Partition -ErrorAction SilentlyContinue)
        $byKey = @{}; foreach ($p in $parts) { $kk = & $keyOf $p; if ($kk) { $byKey[$kk] = $p } }
        $best = $null
        foreach ($p in $parts) {
            $l = [string]$p.DriveLetter
            if (-not $l -or $l -eq 'X' -or $l -eq $stickLetter) { continue }
            $sys = "$($l):\Windows\System32\config\SYSTEM"
            if (-not (Test-Path -LiteralPath $sys)) { continue }
            $m = & $readMap $sys
            if (-not $m.Count) { continue }
            if (-not $best) { $best = $m }
            if ($m['C'] -and $m['C'] -eq (& $keyOf $p)) { $best = $m; break }
        }
        if (-not $best) { return }

        # Which partition should get which letter.
        $want = New-Object System.Collections.Generic.List[object]
        foreach ($L in ($best.Keys | Sort-Object)) {
            if ($L -in 'A', 'B', 'X' -or $L -eq $stickLetter) { continue }
            $p = $byKey[$best[$L]]
            if (-not $p -or [int]$p.DiskNumber -eq $stickDiskNo) { continue }
            $want.Add(@{ Disk = [int]$p.DiskNumber; Part = [int]$p.PartitionNumber; Letter = $L })
        }
        $wantLetters = @($want | ForEach-Object { $_.Letter })

        foreach ($w in $want) {
            try {
                $now = Get-Partition -DiskNumber $w.Disk -PartitionNumber $w.Part -ErrorAction Stop
                if ([string]$now.DriveLetter -eq $w.Letter) { continue }
                $inUse = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
                if ($inUse -contains $w.Letter) {
                    # Someone else has the letter: move that drive out of the way first (never the Rescue USB, X: or a CD drive).
                    $holder = Get-Partition -ErrorAction SilentlyContinue | Where-Object { [string]$_.DriveLetter -eq $w.Letter } | Select-Object -First 1
                    if (-not $holder -or [int]$holder.DiskNumber -eq $stickDiskNo) { continue }
                    $free = [char[]]'ZYWVUTSRQPONMLKJIHGFED' | ForEach-Object { [string]$_ } | Where-Object { $inUse -notcontains $_ -and $wantLetters -notcontains $_ } | Select-Object -First 1
                    if ($free) { Set-Partition -DiskNumber $holder.DiskNumber -PartitionNumber $holder.PartitionNumber -NewDriveLetter $free -ErrorAction Stop }
                    else { Remove-PartitionAccessPath -DiskNumber $holder.DiskNumber -PartitionNumber $holder.PartitionNumber -AccessPath "$($w.Letter):\" -ErrorAction Stop }
                }
                if ($now.DriveLetter) { Set-Partition -DiskNumber $w.Disk -PartitionNumber $w.Part -NewDriveLetter $w.Letter -ErrorAction Stop }
                else { Add-PartitionAccessPath -DiskNumber $w.Disk -PartitionNumber $w.Part -AccessPath "$($w.Letter):\" -ErrorAction Stop }
            } catch { }
        }
    } catch { }
}

function Mount-AllVolumes {
    # Inside the rescue only: a drive with no letter gets one so its folders can be opened. Nothing on the drive changes.
    if ($env:SystemDrive -ne 'X:') { return }
    Set-WindowsDriveLetters
    foreach ($p in @(Get-Partition -ErrorAction SilentlyContinue)) {
        try {
            if ($p.DriveLetter) { continue }
            if ($p.Type -in 'System', 'Reserved', 'Recovery', 'Unknown') { continue }
            if ($p.Size -lt 1GB) { continue }
            $v = $p | Get-Volume -ErrorAction SilentlyContinue
            if (-not $v -or -not $v.FileSystem) { continue }
            Add-PartitionAccessPath -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -AssignDriveLetter -ErrorAction Stop
        } catch { }
    }
}

function Get-PickerDisks {
    # Every disk with the drives on it: @{ Disk = <disk>; Volumes = @( @{ Letter; Label; Size } ) }
    foreach ($d in @(Get-ImagerDisks)) {
        $vols = @()
        foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
            $v = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
            if ($v -and $v.FileSystem) {
                $label = if ($v.FileSystemLabel) { [string]$v.FileSystemLabel } else { 'No name' }
                $vols += @{ Letter = [string]$p.DriveLetter; Label = $label; Size = [int64]$v.Size }
            }
        }
        @{ Disk = $d; Volumes = $vols }
    }
}

function New-ImageDialog {
    # Mode 'open' picks an existing image; mode 'save' picks a folder and a file name.
    param([ValidateSet('open', 'save')][string]$Mode = 'open', [string]$Start = '')
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $(if ($Mode -eq 'save') { 'DRDirect Clone & Backup - Save image as ...' } else { 'DRDirect Clone & Backup - Select image ...' }); if ($script:RescueIcon) { $f.Icon = $script:RescueIcon }
    $f.Size = New-Object System.Drawing.Size(1040, 640); $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false; $f.Font = Font 11; $f.BackColor = C '#EEF2F8'

    $tbPath = New-Object System.Windows.Forms.TextBox; $tbPath.ReadOnly = $true; $tbPath.Location = '12,12'; $tbPath.Size = '840,28'; $tbPath.BackColor = 'White'
    $btnUp = New-Object System.Windows.Forms.Button; $btnUp.Text = 'Up'; $btnUp.Location = '864,10'; $btnUp.Size = '70,30'
    $btnRef = New-Object System.Windows.Forms.Button; $btnRef.Text = 'Refresh'; $btnRef.Location = '942,10'; $btnRef.Size = '80,30'
    $tree = New-Object System.Windows.Forms.TreeView; $tree.Location = '12,52'; $tree.Size = '330,440'; $tree.HideSelection = $false; $tree.ShowLines = $true; $tree.Font = Font 11
    $list = New-Object System.Windows.Forms.ListView; $list.Location = '352,52'; $list.Size = '670,440'; $list.View = 'Details'; $list.FullRowSelect = $true; $list.HideSelection = $false; $list.MultiSelect = $false; $list.Font = Font 11
    [void]$list.Columns.Add('Name', 400); [void]$list.Columns.Add('Size', 100); [void]$list.Columns.Add('Modified', 150)
    $lblFile = New-Object System.Windows.Forms.Label; $lblFile.Text = 'File:'; $lblFile.Location = '12,508'; $lblFile.AutoSize = $true
    $tbFile = New-Object System.Windows.Forms.TextBox; $tbFile.Location = '70,504'; $tbFile.Size = '740,28'
    $lblType = New-Object System.Windows.Forms.Label; $lblType.Text = 'Type:'; $lblType.Location = '12,548'; $lblType.AutoSize = $true
    $cbType = New-Object System.Windows.Forms.ComboBox; $cbType.DropDownStyle = 'DropDownList'; $cbType.Location = '70,544'; $cbType.Size = '740,28'
    [void]$cbType.Items.Add('DRDirect image (*.drimg)'); $cbType.SelectedIndex = 0
    $btnOk = New-Object System.Windows.Forms.Button; $btnOk.Text = $(if ($Mode -eq 'save') { 'Save' } else { 'OK' }); $btnOk.Location = '830,502'; $btnOk.Size = '190,32'
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = 'Cancel'; $btnCancel.Location = '830,542'; $btnCancel.Size = '190,32'
    $f.Controls.AddRange(@($tbPath, $btnUp, $btnRef, $tree, $list, $lblFile, $tbFile, $lblType, $cbType, $btnOk, $btnCancel))
    $f.AcceptButton = $btnOk; $f.CancelButton = $btnCancel

    $d = @{ Form = $f; Tree = $tree; List = $list; File = $tbFile; Path = $tbPath; Ok = $btnOk; Cancel = $btnCancel; Up = $btnUp; Mode = $Mode; Dir = ''; Result = $null; Disks = @() }
    $script:imgDlg = $d

    $d.ShowItems = {
        param($items)
        $d = $script:imgDlg
        $d.List.BeginUpdate(); $d.List.Items.Clear()
        foreach ($it in $items) {
            $li = New-Object System.Windows.Forms.ListViewItem($it.Name)
            [void]$li.SubItems.Add([string]$it.Size); [void]$li.SubItems.Add([string]$it.Modified)
            $li.Tag = $it
            [void]$d.List.Items.Add($li)
        }
        $d.List.EndUpdate()
    }
    $d.ShowDir = {
        param([string]$path)
        $d = $script:imgDlg
        $d.Dir = $path; $d.Path.Text = $path
        $items = @()
        try {
            foreach ($x in @(Get-ChildItem -LiteralPath $path -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -notin '$RECYCLE.BIN', 'System Volume Information' } | Sort-Object Name)) {
                $items += @{ Kind = 'dir'; Name = $x.Name; Path = $x.FullName; Size = ''; Modified = $x.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
            }
            foreach ($x in @(Get-ChildItem -LiteralPath $path -File -Force -Filter '*.drimg' -ErrorAction Stop | Sort-Object Name)) {
                $items += @{ Kind = 'file'; Name = $x.Name; Path = $x.FullName; Size = (Format-ImgSize $x.Length); Modified = $x.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
            }
        } catch { }
        & $d.ShowItems $items
    }
    $d.ShowDisk = {
        param($entry)
        $d = $script:imgDlg
        $d.Dir = ''; $d.Path.Text = [string]$entry.Disk.Name
        $items = @()
        foreach ($v in $entry.Volumes) { $items += @{ Kind = 'dir'; Name = ('{0}:  {1}' -f $v.Letter, $v.Label); Path = ($v.Letter + ':\'); Size = (Format-ImgSize $v.Size); Modified = '' } }
        & $d.ShowItems $items
    }
    $d.OpenItem = {
        param($it)
        $d = $script:imgDlg
        if ($it.Kind -eq 'dir') { & $d.ShowDir $it.Path }
        elseif ($d.Mode -eq 'open') { $d.Result = $it.Path; $d.Form.DialogResult = 'OK'; $d.Form.Close() }
        else { $d.File.Text = $it.Name }
    }
    $d.Accept = {
        $d = $script:imgDlg
        $name = ([string]$d.File.Text).Trim('"', ' ')
        if ($d.Mode -eq 'open') {
            $p = $name
            if ($name -and -not [System.IO.Path]::IsPathRooted($name) -and $d.Dir) { $p = Join-Path $d.Dir $name }
            if (-not $name -and $d.List.SelectedItems.Count) { $it = $d.List.SelectedItems[0].Tag; if ($it.Kind -eq 'dir') { & $d.ShowDir $it.Path; return } else { $p = $it.Path } }
            if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { $d.Result = $p; $d.Form.DialogResult = 'OK'; $d.Form.Close() }
            elseif ($p -and (Test-Path -LiteralPath $p -PathType Container)) { & $d.ShowDir $p }
            else { [void][System.Windows.Forms.MessageBox]::Show('Choose an image file from the list first.', 'Select image', 'OK', 'Information') }
        }
        else {
            if (-not $d.Dir) { [void][System.Windows.Forms.MessageBox]::Show('Open a drive and a folder first, then give the image a name.', 'Save image as', 'OK', 'Information'); return }
            if (-not $name) { $name = (Get-Date -Format 'yyyyMMdd') + ' Image.drimg' }
            if ($name -notlike '*.drimg') { $name += '.drimg' }
            $p = if ([System.IO.Path]::IsPathRooted($name)) { $name } else { Join-Path $d.Dir $name }
            if (Test-Path -LiteralPath $p) {
                if ([System.Windows.Forms.MessageBox]::Show("$p already exists. Replace it?", 'Save image as', 'YesNo', 'Warning') -ne 'Yes') { return }
            }
            $d.Result = $p; $d.Form.DialogResult = 'OK'; $d.Form.Close()
        }
    }

    # the disks and their drives on the left
    foreach ($e in @(Get-PickerDisks)) {
        $d.Disks += , $e
        $node = New-Object System.Windows.Forms.TreeNode(('Disk {0}   {1}   {2}' -f $e.Disk.Number, $e.Disk.Name, (Format-ImgSize $e.Disk.Size)))
        $node.Tag = @{ Kind = 'disk'; Entry = $e }
        foreach ($v in $e.Volumes) {
            $child = New-Object System.Windows.Forms.TreeNode(('{0}:  {1}   {2}' -f $v.Letter, $v.Label, (Format-ImgSize $v.Size)))
            $child.Tag = @{ Kind = 'vol'; Path = ($v.Letter + ':\') }
            [void]$node.Nodes.Add($child)
        }
        [void]$tree.Nodes.Add($node)
    }
    $tree.ExpandAll()
    $tree.Add_AfterSelect({
        $d = $script:imgDlg; $t = $d.Tree.SelectedNode.Tag
        if ($t.Kind -eq 'vol') { & $d.ShowDir $t.Path } elseif ($t.Kind -eq 'disk') { & $d.ShowDisk $t.Entry }
    })
    $list.Add_DoubleClick({ $d = $script:imgDlg; if ($d.List.SelectedItems.Count) { & $d.OpenItem $d.List.SelectedItems[0].Tag } })
    $list.Add_SelectedIndexChanged({ $d = $script:imgDlg; if ($d.List.SelectedItems.Count) { $it = $d.List.SelectedItems[0].Tag; if ($it.Kind -eq 'file') { $d.File.Text = $it.Name } } })
    $btnOk.Add_Click({ & $script:imgDlg.Accept })
    $btnCancel.Add_Click({ $script:imgDlg.Form.DialogResult = 'Cancel'; $script:imgDlg.Form.Close() })
    $btnUp.Add_Click({
        $d = $script:imgDlg
        if (-not $d.Dir) { return }
        $up = [System.IO.Path]::GetDirectoryName($d.Dir.TrimEnd('\'))
        if ($up) { & $d.ShowDir $up } else { if ($d.Tree.SelectedNode -and $d.Tree.SelectedNode.Parent) { $d.Tree.SelectedNode = $d.Tree.SelectedNode.Parent } }
    })
    $btnRef.Add_Click({ $d = $script:imgDlg; if ($d.Dir) { & $d.ShowDir $d.Dir } })

    # start where the box already points, else on the first drive
    $startDir = ''
    if ($Start) { $c = if ($Mode -eq 'open' -and $Start -match '\.drimg$') { Split-Path $Start -Parent } else { $Start }; if ($c -and (Test-Path -LiteralPath $c -PathType Container)) { $startDir = $c } }
    if ($startDir) { & $d.ShowDir $startDir }
    # the first disk opens once the window is on screen (a selection made before that is not acted on)
    $f.Add_Shown({ $d = $script:imgDlg; if (-not $d.Dir -and $d.Tree.Nodes.Count) { $d.Tree.SelectedNode = $d.Tree.Nodes[0] } })
    $d
}

function Show-ImageDialog {
    param([ValidateSet('open', 'save')][string]$Mode = 'open', [string]$Start = '')
    Mount-AllVolumes
    $d = New-ImageDialog -Mode $Mode -Start $Start
    [void]$d.Form.ShowDialog()
    $r = $d.Result
    $d.Form.Dispose()
    $r
}

# ---------- Files: browse every drive and copy folders or files out to another drive (e.g. a USB stick). Nothing on the source is changed or deleted. ----------
function Show-FolderPicker {
    param([string]$Title = 'Choose a folder')
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title; if ($script:RescueIcon) { $f.Icon = $script:RescueIcon }
    $f.Size = New-Object System.Drawing.Size(620, 600); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false; $f.Font = Font 11; $f.BackColor = C '#EEF2F8'
    $tv = New-Object System.Windows.Forms.TreeView; $tv.Location = '12,12'; $tv.Size = '580,470'; $tv.HideSelection = $false; $tv.Font = Font 11
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Copy here'; $ok.Location = '300,500'; $ok.Size = '140,34'; $ok.DialogResult = 'OK'
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = '452,500'; $cancel.Size = '140,34'; $cancel.DialogResult = 'Cancel'
    $f.Controls.AddRange(@($tv, $ok, $cancel)); $f.AcceptButton = $ok; $f.CancelButton = $cancel
    foreach ($v in @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem } | Sort-Object DriveLetter)) {
        $label = if ($v.FileSystemLabel) { [string]$v.FileSystemLabel } else { 'No name' }
        $n = New-Object System.Windows.Forms.TreeNode(('{0}:  {1}   {2}' -f $v.DriveLetter, $label, (Format-ImgSize $v.Size)))
        $n.Tag = ([string]$v.DriveLetter + ':\'); [void]$n.Nodes.Add('...'); [void]$tv.Nodes.Add($n)
    }
    $tv.Add_BeforeExpand({
        $n = $_.Node
        if ($n.Nodes.Count -eq 1 -and $n.Nodes[0].Text -eq '...') {
            $n.Nodes.Clear()
            foreach ($x in @(Get-ChildItem -LiteralPath $n.Tag -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin '$RECYCLE.BIN', 'System Volume Information' } | Sort-Object Name)) {
                $c = New-Object System.Windows.Forms.TreeNode($x.Name); $c.Tag = $x.FullName; [void]$c.Nodes.Add('...'); [void]$n.Nodes.Add($c)
            }
        }
    })
    $r = $null
    if ($f.ShowDialog() -eq 'OK' -and $tv.SelectedNode) { $r = [string]$tv.SelectedNode.Tag }
    $f.Dispose(); $r
}

function Show-FileBrowser {
    Mount-AllVolumes
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'DRDirect Clone & Backup - Files'; if ($script:RescueIcon) { $f.Icon = $script:RescueIcon }
    $f.Size = New-Object System.Drawing.Size(1100, 700); $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false; $f.Font = Font 11; $f.BackColor = C '#EEF2F8'
    $tbPath = New-Object System.Windows.Forms.TextBox; $tbPath.ReadOnly = $true; $tbPath.Location = '12,12'; $tbPath.Size = '900,28'; $tbPath.BackColor = 'White'
    $btnUp = New-Object System.Windows.Forms.Button; $btnUp.Text = 'Up'; $btnUp.Location = '924,10'; $btnUp.Size = '70,30'
    $btnRef = New-Object System.Windows.Forms.Button; $btnRef.Text = 'Refresh'; $btnRef.Location = '1002,10'; $btnRef.Size = '80,30'
    $tree = New-Object System.Windows.Forms.TreeView; $tree.Location = '12,52'; $tree.Size = '300,520'; $tree.HideSelection = $false; $tree.Font = Font 11
    $list = New-Object System.Windows.Forms.ListView; $list.Location = '322,52'; $list.Size = '760,520'; $list.View = 'Details'; $list.FullRowSelect = $true; $list.HideSelection = $false; $list.MultiSelect = $true; $list.Font = Font 11
    [void]$list.Columns.Add('Name', 460); [void]$list.Columns.Add('Size', 100); [void]$list.Columns.Add('Modified', 170)
    $lblInfo = New-Object System.Windows.Forms.Label; $lblInfo.Location = '12,590'; $lblInfo.Size = '800,50'; $lblInfo.ForeColor = C '#16275A'; $lblInfo.Text = 'Select folders or files (Ctrl or Shift for several), then press Copy to...'
    $btnCopy = New-Object System.Windows.Forms.Button; $btnCopy.Text = 'Copy to...'; $btnCopy.Location = '830,584'; $btnCopy.Size = '120,40'
    $btnClose = New-Object System.Windows.Forms.Button; $btnClose.Text = 'Close'; $btnClose.Location = '962,584'; $btnClose.Size = '120,40'
    $f.Controls.AddRange(@($tbPath, $btnUp, $btnRef, $tree, $list, $lblInfo, $btnCopy, $btnClose)); $f.CancelButton = $btnClose
    $st = @{ Dir = '' }

    $show = {
        param([string]$path)
        $st.Dir = $path; $tbPath.Text = $path
        $list.BeginUpdate(); $list.Items.Clear()
        try {
            foreach ($x in @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Where-Object { $_.Name -notin '$RECYCLE.BIN', 'System Volume Information' } | Sort-Object @{ Expression = { -not $_.PSIsContainer } }, Name)) {
                $li = New-Object System.Windows.Forms.ListViewItem($(if ($x.PSIsContainer) { '[' + $x.Name + ']' } else { $x.Name }))
                [void]$li.SubItems.Add($(if ($x.PSIsContainer) { '' } else { Format-ImgSize $x.Length })); [void]$li.SubItems.Add($x.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
                $li.Tag = @{ Path = $x.FullName; Dir = [bool]$x.PSIsContainer }
                [void]$list.Items.Add($li)
            }
        } catch { $lblInfo.Text = 'Cannot open this folder: ' + $_.Exception.Message }
        $list.EndUpdate()
    }

    foreach ($v in @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem } | Sort-Object DriveLetter)) {
        $label = if ($v.FileSystemLabel) { [string]$v.FileSystemLabel } else { 'No name' }
        $n = New-Object System.Windows.Forms.TreeNode(('{0}:  {1}   {2}' -f $v.DriveLetter, $label, (Format-ImgSize $v.Size)))
        $n.Tag = ([string]$v.DriveLetter + ':\'); [void]$n.Nodes.Add('...'); [void]$tree.Nodes.Add($n)
    }
    $tree.Add_BeforeExpand({
        $n = $_.Node
        if ($n.Nodes.Count -eq 1 -and $n.Nodes[0].Text -eq '...') {
            $n.Nodes.Clear()
            foreach ($x in @(Get-ChildItem -LiteralPath $n.Tag -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin '$RECYCLE.BIN', 'System Volume Information' } | Sort-Object Name)) {
                $c = New-Object System.Windows.Forms.TreeNode($x.Name); $c.Tag = $x.FullName; [void]$c.Nodes.Add('...'); [void]$n.Nodes.Add($c)
            }
        }
    })
    $tree.Add_AfterSelect({ & $show ([string]$tree.SelectedNode.Tag) })
    $list.Add_DoubleClick({ if ($list.SelectedItems.Count) { $t = $list.SelectedItems[0].Tag; if ($t.Dir) { & $show $t.Path } } })
    $btnUp.Add_Click({
        if (-not $st.Dir) { return }
        $up = [System.IO.Path]::GetDirectoryName($st.Dir.TrimEnd('\'))
        if ($up) { & $show $up }
    })
    $btnRef.Add_Click({ if ($st.Dir) { & $show $st.Dir } })
    $btnClose.Add_Click({ $f.Close() })
    $btnCopy.Add_Click({
        if (-not $list.SelectedItems.Count) { [void][System.Windows.Forms.MessageBox]::Show('Select the folders or files to copy first.', 'Files', 'OK', 'Information'); return }
        $items = @($list.SelectedItems | ForEach-Object { $_.Tag })
        $dest = Show-FolderPicker 'Copy to which folder?'
        if (-not $dest) { return }
        foreach ($it in $items) {
            $src = $it.Path.TrimEnd('\')
            if ($dest.TrimEnd('\') + '\' -like ($src + '\*')) {
                [void][System.Windows.Forms.MessageBox]::Show("Cannot copy '$src' into itself. Choose a different place.", 'Files', 'OK', 'Warning'); return
            }
        }
        if ([System.Windows.Forms.MessageBox]::Show(("Copy {0} item(s) into {1} ?`n`nThe originals are not changed." -f $items.Count, $dest), 'Files', 'YesNo', 'Question') -ne 'Yes') { return }
        $btnCopy.Enabled = $false; $btnClose.Enabled = $false; $failed = 0
        foreach ($it in $items) {
            $name = Split-Path $it.Path -Leaf
            $lblInfo.Text = "Copying $name ..."; [System.Windows.Forms.Application]::DoEvents()
            try {
                if ($it.Dir) {
                    $p = Start-Process -FilePath robocopy.exe -ArgumentList @("`"$($it.Path)`"", "`"$(Join-Path $dest $name)`"", '/E', '/COPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -WindowStyle Hidden -PassThru
                    while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
                    if ($p.ExitCode -ge 8) { $failed++ }
                }
                else { Copy-Item -LiteralPath $it.Path -Destination $dest -Force -ErrorAction Stop }
            } catch { $failed++ }
        }
        $btnCopy.Enabled = $true; $btnClose.Enabled = $true
        if ($failed) { $lblInfo.Text = "Finished, but $failed item(s) could not be fully copied." } else { $lblInfo.Text = "Done. Copied into $dest" }
    })
    [void]$f.ShowDialog(); $f.Dispose()
}

function New-DiskDialog {
    # The Target list: one row per disk with its size, kind, drive letters and serial number.
    param($Disks, [int]$StickDisk = -1, [string]$Title = 'Select target ...', [int]$Current = -1)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'DRDirect Clone & Backup - ' + $Title; if ($script:RescueIcon) { $f.Icon = $script:RescueIcon }; $f.Size = New-Object System.Drawing.Size(1000, 460); $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false; $f.Font = Font 11; $f.BackColor = C '#EEF2F8'
    $lv = New-Object System.Windows.Forms.ListView; $lv.Location = '12,12'; $lv.Size = '970,330'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false; $lv.Font = Font 12
    [void]$lv.Columns.Add('Name', 400); [void]$lv.Columns.Add('Size', 100); [void]$lv.Columns.Add('Type', 80); [void]$lv.Columns.Add('Drives', 120); [void]$lv.Columns.Add('Serial number', 250)
    for ($i = 0; $i -lt @($Disks).Count; $i++) {
        $x = $Disks[$i]
        $tag = ''
        if ($x.Number -eq $StickDisk) { $tag = '   (this Rescue USB)' } elseif ($x.IsWindows) { $tag = '   (Windows drive)' }
        $bus = ''; $serial = ''
        try { $g = Get-Disk -Number $x.Number -ErrorAction Stop; $bus = [string]$g.BusType; $serial = ([string]$g.SerialNumber).Trim() } catch { }
        $li = New-Object System.Windows.Forms.ListViewItem(('Disk {0}   {1}{2}' -f $x.Number, $x.Name, $tag))
        [void]$li.SubItems.Add((Format-ImgSize $x.Size)); [void]$li.SubItems.Add($bus); [void]$li.SubItems.Add([string]$x.Letters); [void]$li.SubItems.Add($serial)
        $li.Tag = $i
        [void]$lv.Items.Add($li)
    }
    if ($Current -ge 0 -and $Current -lt $lv.Items.Count) { $lv.Items[$Current].Selected = $true } elseif ($lv.Items.Count) { $lv.Items[0].Selected = $true }
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'OK'; $ok.Location = '780,360'; $ok.Size = '200,36'
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = '570,360'; $cancel.Size = '200,36'
    $look = New-Object System.Windows.Forms.Button; $look.Text = 'Look inside (folders)...'; $look.Location = '12,360'; $look.Size = '240,36'; $look.Add_Click({ Show-FileBrowser })
    $f.Controls.AddRange(@($lv, $look, $ok, $cancel)); $f.AcceptButton = $ok; $f.CancelButton = $cancel
    $d = @{ Form = $f; List = $lv; Result = -1 }
    $script:diskDlg = $d
    $ok.Add_Click({ $d = $script:diskDlg; if ($d.List.SelectedItems.Count) { $d.Result = [int]$d.List.SelectedItems[0].Tag; $d.Form.DialogResult = 'OK'; $d.Form.Close() } })
    $cancel.Add_Click({ $script:diskDlg.Form.DialogResult = 'Cancel'; $script:diskDlg.Form.Close() })
    $lv.Add_DoubleClick({ $d = $script:diskDlg; if ($d.List.SelectedItems.Count) { $d.Result = [int]$d.List.SelectedItems[0].Tag; $d.Form.DialogResult = 'OK'; $d.Form.Close() } })
    $d
}

function Show-DiskDialog {
    param($Disks, [int]$StickDisk = -1, [string]$Title = 'Select target ...', [int]$Current = -1)
    $d = New-DiskDialog -Disks $Disks -StickDisk $StickDisk -Title $Title -Current $Current
    [void]$d.Form.ShowDialog()
    $r = $d.Result
    $d.Form.Dispose()
    $r
}

function Get-ImageSuggestions {
    # .drimg files already on any drive (up to 3 folders deep), newest first, so the person can just pick one.
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'X' -and $_.FileSystemLabel -ne 'DRDIRECT' })) {
        $l = "$($v.DriveLetter):\"
        try { Get-ChildItem -LiteralPath $l -Recurse -Depth 3 -File -Filter *.drimg -ErrorAction SilentlyContinue | ForEach-Object { $found.Add($_) } } catch { }
    }
    @($found | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName })
}
function Get-SaveSuggestions([int]$srcDisk) {
    # Where a new image could go: every drive with a letter that is not the one being copied and not the rescue USB.
    $skip = @(Get-DiskLetters $srcDisk)
    $name = 'Backup-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.drimg'
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'X' -and $_.FileSystemLabel -ne 'DRDIRECT' -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -ne 'FAT32' })) {
        if ($skip -notcontains [string]$v.DriveLetter) { "$($v.DriveLetter):\DRDirect Images\$name" }
    }
}

function Load-Disks {
    Mount-AllVolumes
    $script:disks = @(Get-ImagerDisks)
    $stick = Get-RescueUsbDrive
    $script:stickDisk = -1
    if ($stick) { $script:stickDisk = [int](Get-Partition -DriveLetter $stick.DriveLetter -ErrorAction SilentlyContinue).DiskNumber }
    $items = foreach ($d in $script:disks) {
        $tag = if ($d.Number -eq $script:stickDisk) { '   (this Rescue USB)' } else { '' }
        'Disk {0}   {1}   {2}   {3}{4}' -f $d.Number, $d.Name, (Format-ImgSize $d.Size), $d.Letters, $tag
    }
    foreach ($cb in $cbDiskA, $cbDiskB) { $cb.Items.Clear(); if ($items) { [void]$cb.Items.AddRange([object[]]@($items)) } }
    if ($cbDiskA.Items.Count) { $cbDiskA.SelectedIndex = 0 }
    if ($cbDiskB.Items.Count -gt 1) { $cbDiskB.SelectedIndex = 1 } elseif ($cbDiskB.Items.Count) { $cbDiskB.SelectedIndex = 0 }
}
function Get-SelectedDisk($cb) { if ($cb.SelectedIndex -ge 0 -and $cb.SelectedIndex -lt $script:disks.Count) { $script:disks[$cb.SelectedIndex] } else { $null } }

function Fill-Images([bool]$forSave) {
    $cbImg.Items.Clear()
    $list = if ($forSave) { $a = Get-SelectedDisk $cbDiskA; if ($a) { @(Get-SaveSuggestions $a.Number) } else { @() } } else { @(Get-ImageSuggestions) }
    if ($list.Count) { [void]$cbImg.Items.AddRange([object[]]$list); $cbImg.SelectedIndex = 0 } else { $cbImg.Text = '' }
}

function Get-Problem {
    $img = ([string]$cbImg.Text).Trim('"', ' ')
    switch ($script:mode) {
        'clone' {
            $a = Get-SelectedDisk $cbDiskA; $b = Get-SelectedDisk $cbDiskB
            if (-not $a) { return 'Choose the drive to copy from.' }
            if (-not $b) { return 'Choose the drive to copy onto.' }
            $why = Get-CloneBlockReason $a.Number $b.Number
            if (-not $why -and $b.Number -eq $script:stickDisk) { $why = 'That is the Rescue USB you started from. Choose another drive.' }
            return $why
        }
        'secure' {
            $a = Get-SelectedDisk $cbDiskA
            if (-not $a) { return 'Choose the drive to save.' }
            if (-not $img) { return 'Choose where to save the image (Save image as).' }
            $why = Get-ImageBlockReason $a.Number $img
            if (-not $why) {
                $vol = Get-Volume -DriveLetter $img.Substring(0, 1) -ErrorAction SilentlyContinue
                if (-not $vol) { $why = "Drive $($img.Substring(0,2)) was not found." }
                elseif ($vol.FileSystem -eq 'FAT32') { $why = 'That drive is FAT32, which cannot hold files over 4 GB. Save the image on another drive.' }
                elseif ($vol.SizeRemaining -lt 1GB) { $why = 'That drive has almost no free space.' }
            }
            return $why
        }
        'restore' {
            $b = Get-SelectedDisk $cbDiskB
            if (-not $img) { return 'Choose the image file to restore (Image).' }
            if (-not $b) { return 'Choose the drive to restore onto.' }
            if ($b.Number -eq $script:stickDisk) { return 'That is the Rescue USB you started from. Choose another drive.' }
            return (Get-RestoreBlockReason $b.Number $img)
        }
        'check' {
            if (-not $img) { return 'Choose the image file to check (Image).' }
            if (-not (Test-Path -LiteralPath $img -PathType Leaf)) { return 'That image file was not found.' }
            return $null
        }
    }
}

function Refresh-Start {
    if ($script:job -and -not $script:job.Finished) { return }
    $why = $null
    try { $why = Get-Problem } catch { $why = $_.Exception.Message }
    $lblProblem.Text = [string]$why
    $erase = $script:mode -in 'clone', 'restore'
    $chkErase.Visible = $erase
    if ($erase) { $t = Get-SelectedDisk $cbDiskB; if ($t) { $chkErase.Text = "Yes, erase Disk $($t.Number) ($($t.Name)). Everything on it is replaced." } }
    $btnStart.Enabled = (-not $why) -and ((-not $erase) -or $chkErase.Checked)
    $btnStart.Invalidate()
}

function Set-Mode([string]$m) {
    if ($script:job -and -not $script:job.Finished) { return }
    $script:mode = $m
    foreach ($k in $nav.Keys) { $nav[$k].Invalidate() }
    foreach ($c in @($lblA, $lblB, $cbDiskA, $cbDiskB, $cbImg, $btnBrowse, $btnPickA, $btnPickB)) { $c.Visible = $false }
    $chkErase.Checked = $false; $lblProg.Font = Font 12; $lblProg.Text = ''; $bar.Value = 0; $btnDone.Visible = $false
    $isDisk = $m -in 'clone', 'restore'
    $chkTrim.Visible = $isDisk
    $chkVerify.Visible = $m -in 'secure', 'restore'
    $chkVerify.Text = if ($m -eq 'restore') { 'Verify the image first  (so a damaged image never erases the drive)' } else { 'Verify copied data  (check the image after it is saved)' }
    foreach ($c in @($lblOpt, $chkAfter, $cbAfter, $lblAfter2)) { $c.Visible = ($m -ne 'check') }
    Load-Disks
    switch ($m) {
        'clone' {
            $lblHead.Text = 'SmartCopy'; $lblSub.Text = 'Copy a whole drive onto another drive.'
            $lblA.Text = 'From  (copy this drive)'; $lblB.Text = 'Onto  (this drive will be ERASED)'
            Place $lblA $cbDiskA 24 $false; Place $lblB $cbDiskB 124 $false
        }
        'secure' {
            $lblHead.Text = 'Secure'; $lblSub.Text = 'Save a whole drive as an image file. The drive is only read, nothing on it changes.'
            $lblA.Text = 'Drive to save'; $lblB.Text = 'Save image as'
            Place $lblA $cbDiskA 24 $false; Place $lblB $cbImg 124 $true; Fill-Images $true
        }
        'restore' {
            $lblHead.Text = 'Restore'; $lblSub.Text = 'Put an image back onto a drive.'
            $lblA.Text = 'Image'; $lblB.Text = 'Onto  (this drive will be ERASED)'
            Place $lblA $cbImg 24 $true; Place $lblB $cbDiskB 124 $false; Fill-Images $false
        }
        'check' {
            $lblHead.Text = 'Check an image'; $lblSub.Text = 'Make sure an image file is complete and can be restored.'
            $lblA.Text = 'Image'
            Place $lblA $cbImg 24 $true; Fill-Images $false
        }
    }
    Refresh-Start
}

function Set-Busy([bool]$busy) {
    if ($busy) { $btnDone.Visible = $false }
    foreach ($c in @($cbDiskA, $cbDiskB, $cbImg, $btnBrowse, $btnPickA, $btnPickB, $chkErase, $btnStart, $chkTrim, $chkVerify, $chkAfter, $cbAfter)) { $c.Enabled = -not $busy }
    foreach ($k in $nav.Keys) { $nav[$k].Enabled = -not $busy }
    $btnStop.Visible = $busy
    if (-not $busy) { Refresh-Start }
}

foreach ($k in 'clone', 'secure', 'restore', 'check') { $nav[$k].Add_Click({ Set-Mode ([string]$this.Tag) }) }
$btnFiles.Add_Click({ Show-FileBrowser })
$btnRestart.Add_Click({ wpeutil reboot })

# ---------- Fix start-up ----------
# Windows that will not start is very often only missing or damaged start-up files (the boot menu and boot files on the
# PC's start-up partition). Microsoft's bcdboot writes them again from the Windows folder on that drive. Nothing in
# Windows, the programs or the files is changed.
function Find-WindowsOnPc {
    $usb = Get-RescueUsbDrive
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter)) {
        $L = [string]$v.DriveLetter
        if ($L -eq 'X' -or ($usb -and $L -eq [string]$usb.DriveLetter)) { continue }
        if (-not (Test-Path -LiteralPath "$($L):\Windows\System32\config\SYSTEM")) { continue }
        $part = Get-Partition -DriveLetter $L -ErrorAction SilentlyContinue
        if (-not $part) { continue }
        [pscustomobject]@{ Letter = $L; Label = [string]$v.FileSystemLabel; Size = [int64]$v.Size; Disk = [int]$part.DiskNumber }
    }
}
function Repair-StartUp($win) {
    $disk = Get-Disk -Number $win.Disk -ErrorAction Stop
    $parts = @(Get-Partition -DiskNumber $win.Disk -ErrorAction Stop)
    if ([string]$disk.PartitionStyle -eq 'GPT') {
        $fw = 'UEFI'
        $sys = $parts | Where-Object { [string]$_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
        if (-not $sys) { return @{ Ok = $false; Text = 'This drive has no EFI start-up partition, so its start-up cannot be rebuilt here. Nothing was changed.' } }
    } else {
        $fw = 'BIOS'
        $sys = $parts | Where-Object { $_.IsActive } | Select-Object -First 1
        if (-not $sys) {
            # No active partition: Windows' own partition becomes the start-up partition.
            $sys = $parts | Where-Object { [string]$_.DriveLetter -eq $win.Letter } | Select-Object -First 1
            Set-Partition -DiskNumber $win.Disk -PartitionNumber $sys.PartitionNumber -IsActive $true -ErrorAction Stop
        }
    }
    $added = $false
    $sl = [string]$sys.DriveLetter
    if (-not $sl -or $sl -eq [char]0) {
        Add-PartitionAccessPath -DiskNumber $win.Disk -PartitionNumber $sys.PartitionNumber -AssignDriveLetter -ErrorAction Stop
        $added = $true
        Start-Sleep -Milliseconds 800
        $sl = [string](Get-Partition -DiskNumber $win.Disk -PartitionNumber $sys.PartitionNumber).DriveLetter
        if (-not $sl -or $sl -eq [char]0) { return @{ Ok = $false; Text = 'The start-up partition could not be opened. Nothing was changed.' } }
    }
    try {
        $out = (& bcdboot.exe "$($win.Letter):\Windows" /s "$($sl):" /f $fw 2>&1 | ForEach-Object { [string]$_ }) -join ' '
        $code = $LASTEXITCODE
    } finally {
        if ($added) { try { Remove-PartitionAccessPath -DiskNumber $win.Disk -PartitionNumber $sys.PartitionNumber -AccessPath "$($sl):\" -ErrorAction Stop } catch { } }
    }
    if ($code -eq 0) { return @{ Ok = $true; Text = "Start-up fixed for Windows on drive $($win.Letter): ($fw).`r`n`r`nTake out the Rescue USB and restart the PC." } }
    @{ Ok = $false; Text = "The start-up could not be rebuilt (bcdboot code $code).`r`n$out" }
}
function Select-WindowsForFix($list) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Fix start-up - which Windows?'; $f.StartPosition = 'CenterScreen'; $f.Size = '620,330'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
    $lb = New-Object System.Windows.Forms.ListBox; $lb.Location = '16,16'; $lb.Size = '570,200'; $lb.Font = Font 13
    foreach ($w in $list) { [void]$lb.Items.Add(('Drive {0}:   {1}   {2:N0} GB   (disk {3})' -f $w.Letter, $(if ($w.Label) { $w.Label } else { 'Windows' }), ($w.Size / 1e9), $w.Disk)) }
    $lb.SelectedIndex = 0
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Fix this one'; $ok.Location = '336,232'; $ok.Size = '130,40'; $ok.DialogResult = 'OK'
    $no = New-Object System.Windows.Forms.Button; $no.Text = 'Cancel'; $no.Location = '476,232'; $no.Size = '110,40'; $no.DialogResult = 'Cancel'
    $f.Controls.AddRange(@($lb, $ok, $no)); $f.AcceptButton = $ok; $f.CancelButton = $no
    if ($f.ShowDialog() -ne 'OK') { return $null }
    $list[$lb.SelectedIndex]
}
$btnFixBoot.Add_Click({
    $title = 'DRDirect Rescue - Fix start-up'
    $form.Cursor = 'WaitCursor'
    $wins = @(Find-WindowsOnPc)
    $form.Cursor = 'Default'
    if (-not $wins.Count) {
        [System.Windows.Forms.MessageBox]::Show("No Windows was found on this PC's drives.`r`n`r`nIf the drive is locked with BitLocker, it has to be unlocked first. Nothing was changed.", $title, 'OK', 'Warning') | Out-Null
        return
    }
    $win = if ($wins.Count -eq 1) { $wins[0] } else { Select-WindowsForFix $wins }
    if (-not $win) { return }
    $q = "Fix the start-up of Windows on drive $($win.Letter): ?`r`n`r`n" +
        "Use this when Windows will not start (black screen, 'no boot device', 'Boot Manager' or 'BCD' errors, a start-up repair loop).`r`n`r`n" +
        "The Windows start-up files and boot menu are written again from Windows itself. Windows, programs and files are not changed."
    if ([System.Windows.Forms.MessageBox]::Show($q, $title, 'YesNo', 'Question') -ne 'Yes') { return }
    $form.Cursor = 'WaitCursor'
    try { $r = Repair-StartUp $win } catch { $r = @{ Ok = $false; Text = "The start-up could not be rebuilt: $($_.Exception.Message)" } } finally { $form.Cursor = 'Default' }
    [System.Windows.Forms.MessageBox]::Show($r.Text, $title, 'OK', $(if ($r.Ok) { 'Information' } else { 'Error' })) | Out-Null
})
if ($btnWinRepair) {
    $btnWinRepair.Add_Click({
        $q = "Restart into Windows Setup on this USB?`r`n`r`n" +
            "To fix a PC that will not start: choose Next, then Repair your computer, then Troubleshoot, then Startup Repair.`r`n`r`n" +
            "Install now reinstalls Windows instead.`r`n`r`nNothing on this PC changes until you choose something there."
        $a = [System.Windows.Forms.MessageBox]::Show($q, 'DRDirect Rescue - Windows repair', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        $v = Get-RescueUsbDrive
        $set = 0
        if ($v) {
            # One start only: the next restart goes to Windows Setup, the one after that back to the Rescue as usual.
            $stores = @{ BIOS = "$($v.DriveLetter):\Boot\BCD"; EFI = "$($v.DriveLetter):\EFI\Microsoft\Boot\BCD" }
            foreach ($k in $stores.Keys) {
                if (-not $script:winSetupIds.ContainsKey($k) -or -not (Test-Path -LiteralPath $stores[$k])) { continue }
                & bcdedit.exe /store $stores[$k] /bootsequence $script:winSetupIds[$k] | Out-Null
                if ($LASTEXITCODE -eq 0) { $set++ }
            }
        }
        if (-not $set) {
            [System.Windows.Forms.MessageBox]::Show("The USB could not be set to start Windows Setup by itself.`r`n`r`nThe PC will restart now: when the start-up menu shows, pick 'Windows install or repair'.", 'DRDirect Rescue - Windows repair', 'OK', 'Information') | Out-Null
        }
        wpeutil reboot
    })
}
foreach ($c in $cbDiskA, $cbDiskB, $cbImg) { $c.Add_SelectedIndexChanged({ Refresh-Start }); $c.Add_TextChanged({ Refresh-Start }) }
$chkErase.Add_CheckedChanged({ Refresh-Start })
$cbDiskA.Add_SelectedIndexChanged({ if ($script:mode -eq 'secure') { Fill-Images $true } })
$btnBrowse.Add_Click({
    $kind = if ($script:mode -eq 'secure') { 'save' } else { 'open' }
    $picked = Show-ImageDialog -Mode $kind -Start ([string]$cbImg.Text).Trim('"', ' ')
    if ($picked) { $cbImg.Text = $picked }
})
$btnPickA.Add_Click({
    $t = if ($script:mode -eq 'clone') { 'Select source ...' } else { 'Select drive ...' }
    $r = Show-DiskDialog -Disks $script:disks -StickDisk $script:stickDisk -Title $t -Current $cbDiskA.SelectedIndex
    if ($r -ge 0) { $cbDiskA.SelectedIndex = $r }
})
$btnPickB.Add_Click({
    $r = Show-DiskDialog -Disks $script:disks -StickDisk $script:stickDisk -Title 'Select target ...' -Current $cbDiskB.SelectedIndex
    if ($r -ge 0) { $cbDiskB.SelectedIndex = $r }
})
$btnStop.Add_Click({ if ($script:job) { $script:job.Cancel = $true; $lblProg.Text = 'Stopping...' } })

$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 500
$script:clock = $null; $script:targetNo = -1; $script:stage = 'main'; $script:mainSecs = 0
$timer.Add_Tick({
    $j = $script:job; if (-not $j) { return }
    $total = [double][Math]::Max($j.Total, 1)
    $secs = [Math]::Max($script:clock.Elapsed.TotalSeconds, 0.5)
    # Restore and check: follow the saved data actually read and written. Empty space is skipped at once, so counting it shows a speed the drive never reaches.
    $real = ($j.FileTotal -gt 0)
    $rate = if ($real) { [double]$j.FileDone / $secs } else { $j.Done / $secs }
    $frac = if ($real) { [double]$j.FileDone / [double]$j.FileTotal } else { $j.Done / $total }
    $bar.Value = [int][Math]::Min(1000, 1000 * $frac)
    if (-not $j.Finished) {
        # Time left from how much of the image file is still to read: empty parts of the drive take no time, so the drive total would overstate it.
        $fileRate = if ($j.FileTotal -gt 0) { $j.FileDone / [Math]::Max($script:clock.Elapsed.TotalSeconds, 0.5) } else { 0 }
        $secsLeft = if ($fileRate -gt 0) { ($j.FileTotal - $j.FileDone) / $fileRate } elseif ($rate -gt 0) { ($total - $j.Done) / $rate } else { -1 }
        $left = if ($secsLeft -ge 0) { '   about ' + (Format-Duration $secsLeft) + ' left' } else { '' }
        $lblProg.ForeColor = C '#16275A'; $lblProg.Font = Font 12
        $lblProg.Text = if ($real) { ('{0:N1}%   {1} of {2} saved data   {3}/s{4}' -f (100 * $frac), (Format-ImgSize $j.FileDone), (Format-ImgSize $j.FileTotal), (Format-ImgSize $rate), $left) } else { ('{0:N1}%   {1} of {2}   {3}/s{4}' -f (100 * $j.Done / $total), (Format-ImgSize $j.Done), (Format-ImgSize $total), (Format-ImgSize $rate), $left) }
        return
    }
    $timer.Stop()
    $img = ([string]$cbImg.Text).Trim('"', ' ')
    if ($j.Ok -and $script:stage -eq 'preverify') { $script:job = $null; $lblProg.Text = 'The image is good. Starting the restore...'; Start-Main; return }
    # The real time the main job took on this PC (before any check afterwards).
    if ($script:stage -eq 'main') { $script:mainSecs = $script:clock.Elapsed.TotalSeconds }
    if ($j.Ok -and $script:stage -eq 'main' -and $script:mode -eq 'secure') { Write-ImagerTiming $j $script:mainSecs $img }
    if ($j.Ok -and $script:stage -eq 'main' -and $script:mode -eq 'secure' -and $chkVerify.Checked) { $lblProg.Text = 'Saved in ' + (Format-TookTime $script:mainSecs) + '. Now checking the image...'; Start-Verify $img 'postverify'; return }
    if ($script:stage -eq 'main' -and $script:mode -eq 'restore') {
        # Where the restore spent its time, saved next to the image so a slow restore can be explained.
        try { Set-Content -LiteralPath ($img + '.restore-timing.txt') -Encoding UTF8 -Value @(
            ('Restore finished {0}   ok={1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $j.Ok),
            ('Total seconds:                        {0:N1}' -f $script:mainSecs),
            ('Image file read, seconds:             {0:N1}   (slow = the drive holding the image is slow)' -f $j.SecRead),
            ('Reader waited for writers, seconds:   {0:N1}   (high = unpacking or writing the target is slow)' -f $j.SecBlocked),
            ('Time inside target writes, seconds:   {0:N1}   (summed over all threads)' -f $j.SecWrite),
            ('Threads: {0}' -f [Environment]::ProcessorCount)) } catch { }
    }
    if ($j.Ok) {
        $bar.Value = 1000
        if ($script:targetNo -ge 0) {
            Complete-RestoreTarget $script:targetNo
            if ($chkTrim.Checked) {
                $lblProg.Text = 'Trimming the drive (this can take a few minutes)...'; [System.Windows.Forms.Application]::DoEvents()
                foreach ($l in (Get-DiskLetters $script:targetNo)) { try { Optimize-Volume -DriveLetter $l -ReTrim -ErrorAction Stop | Out-Null } catch { } }
            }
        }
        $lblProg.ForeColor = C '#0B9A3E'; $lblProg.Font = Font 15 'Bold'   # two lines fit: the result and the time taken
        $lblProg.Text = switch ($script:mode) {
            'clone' { 'The drive is copied. Remove the USB and restart the PC.' }
            'restore' { 'The drive is restored. Remove the USB and restart the PC.' }
            'secure' { 'The image is saved.' }
            default { 'The image is good.' }
        }
        # Exact time it really took on this PC (no guesses).
        $took = "`nTime taken: " + (Format-TookTime $script:mainSecs)
        if ($script:stage -eq 'postverify') { $took += '   (checking the image: ' + (Format-TookTime $script:clock.Elapsed.TotalSeconds) + ')' }
        $lblProg.Text += $took
        $btnDone.Visible = $true
    } else {
        $lblProg.ForeColor = C '#C0261D'; $lblProg.Font = Font 12
        $extra = if ($script:targetNo -ge 0) { ' The target drive was only partly written. Run it again before using that drive.' } else { '' }
        $lblProg.Text = $(if ($script:stage -eq 'preverify') { "The image is damaged, so nothing was erased: $($j.Error)" } else { "Stopped: $($j.Error)$extra" }) + "`nIt ran for " + (Format-TookTime $script:clock.Elapsed.TotalSeconds) + '.'
    }
    $okEnd = $j.Ok; $after = if ($chkAfter.Checked -and $script:mode -ne 'check') { [string]$cbAfter.SelectedItem } else { '' }
    $script:job = $null; $script:targetNo = -1
    Set-Busy $false
    Load-Disks
    if ($okEnd -and $after) {
        $lblProg.Text += "   $after in 10 seconds..."; [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Seconds 10
        if ($after -eq 'Restart') { wpeutil reboot } else { wpeutil shutdown }
    }
})

function Start-Main {
    try {
        $img = ([string]$cbImg.Text).Trim('"', ' ')
        $script:stage = 'main'
        $script:targetNo = -1
        $j = New-ImagerJob
        switch ($script:mode) {
            'clone' {
                $a = Get-SelectedDisk $cbDiskA; $b = Get-SelectedDisk $cbDiskB
                Sync-DiskVolumes $a.Number
                Initialize-RestoreTarget $b.Number; $script:targetNo = $b.Number
                $ext = Get-SmartExtents $a.Number $a.Size
                if ($ext) { $j.StartSmartClone($a.Path, $b.Path, $a.Size, $ext.Data, $ext.Tail) } else { $j.StartClone($a.Path, $b.Path, $a.Size) }
            }
            'secure' {
                $a = Get-SelectedDisk $cbDiskA
                $dir = Split-Path $img -Parent
                if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
                Sync-DiskVolumes $a.Number
                $ext = Get-SmartExtents $a.Number $a.Size
                $j.Quick = $true
                # MAX speed, same as MAX in the PC Cleaner: photos/videos stored as they are, image written straight to the drive.
                if ($j.PSObject.Properties.Name -contains 'Lighter') { $j.Lighter = $true }
                if ($ext) { $j.StartSmartImage($a.Path, $img, $a.Size, $a.Name, $ext.Data, $ext.Tail) } else { $j.StartImage($a.Path, $img, $a.Size, $a.Name) }
            }
            'restore' {
                $b = Get-SelectedDisk $cbDiskB
                Initialize-RestoreTarget $b.Number; $script:targetNo = $b.Number
                $j.StartRestore($img, $b.Path)
            }
            'check' { $j.StartVerify($img) }
        }
        $script:job = $j; $script:clock = [Diagnostics.Stopwatch]::StartNew(); $timer.Start()
    } catch {
        $script:job = $null
        $lblProg.ForeColor = C '#C0261D'; $lblProg.Text = $_.Exception.Message
        Set-Busy $false
    }
}

function Start-Verify([string]$img, [string]$stage) {
    $script:stage = $stage
    $j = New-ImagerJob; $j.StartVerify($img)
    $script:job = $j; $script:clock = [Diagnostics.Stopwatch]::StartNew(); $timer.Start()
}

$btnStart.Add_Click({
    $img = ([string]$cbImg.Text).Trim('"', ' ')
    $lblProg.Font = Font 12; $lblProg.ForeColor = C '#16275A'; $lblProg.Text = 'Getting ready...'; $bar.Value = 0
    Set-Busy $true; [System.Windows.Forms.Application]::DoEvents()
    if ($script:mode -eq 'restore' -and $chkVerify.Checked) {
        try { Start-Verify $img 'preverify' } catch { $script:job = $null; $lblProg.ForeColor = C '#C0261D'; $lblProg.Text = $_.Exception.Message; Set-Busy $false }
    } else { Start-Main }
})

Set-Mode 'clone'
[void]$form.ShowDialog()
wpeutil reboot
