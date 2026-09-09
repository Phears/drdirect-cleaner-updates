<#
    DRDirect activation dialog
    ---------------------------------------------------------------
    Shown by the launcher when a copy is locked to another PC, or
    when its time has run out. Prints the entered code on stdout so
    the launcher can check it; prints nothing if the person cancels.

    Run:
      powershell.exe -File "DRDirect Activation.ps1" -PcId <id> -Reason expired|otherpc [-Detail "..."]
#>
[CmdletBinding()]
param(
    # Not required: the window no longer shows the ID, so callers pass nothing.
    [string]$PcId = '',
    [ValidateSet('expired', 'otherpc')] [string]$Reason = 'expired',
    [string]$Detail = '',
    # Which program is asking, so the window says the right name.
    [string]$Product = 'PC Cleaner'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# One file per product, in one folder. A code for the Cleaner must not activate
# the Duplicate Finder, and the other way round.
$script:DRStateLeaf = if ($Product -match 'Duplicate') { 'licence_finder.dat' } else { 'licence.dat' }
$script:DRStatePath = Join-Path $env:LOCALAPPDATA (Join-Path 'DRDirect PC Cleaner' $script:DRStateLeaf)

$heading = if ($Reason -eq 'otherpc') { 'This copy is not activated for this PC' }
           else                       { 'This copy has reached the end of its licence' }
$blurb = if ($Reason -eq 'otherpc') {
    "Contact DRDirect to be sent an activation code for this machine."
} else {
    "Contact DRDirect to continue using the $Product on this machine."
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DRDirect" Height="380" Width="640"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#F4F7FB" FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#1D4ED8"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="22,10"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#E4EBF7"/>
      <Setter Property="Foreground" Value="#1D4ED8"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Padding="26,22">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#1D4ED8" Offset="0"/><GradientStop Color="#173794" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <StackPanel Orientation="Horizontal">
        <Border Width="54" Height="54" CornerRadius="27" Background="White" VerticalAlignment="Center">
          <TextBlock Text="&#10003;" Foreground="#1D4ED8" FontSize="30" FontWeight="Bold"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Margin="16,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="DRDirect" Foreground="White" FontSize="26" FontWeight="Bold"/>
          <TextBlock x:Name="LblProduct" Foreground="#C9D9FF" FontSize="14"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <StackPanel Grid.Row="1" Margin="26,22,26,0">
      <TextBlock x:Name="LblHeading" FontSize="19" FontWeight="SemiBold" Foreground="#101828" TextWrapping="Wrap"/>
      <TextBlock x:Name="LblBlurb" Foreground="#475467" TextWrapping="Wrap" Margin="0,8,0,0"/>

      <TextBlock Text="Activation code" FontWeight="SemiBold" Foreground="#344054" Margin="0,18,0,6"/>
      <TextBox x:Name="TxtCode" Padding="10,9" FontFamily="Consolas" FontSize="16"
               BorderBrush="#C9D4E6" Background="White" CharacterCasing="Upper"/>
      <TextBlock x:Name="LblHint" Text="Paste the code DRDirect sent you, then press Activate."
                 Foreground="#667085" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
    </StackPanel>

    <Border x:Name="DoneOverlay" Grid.RowSpan="3" Background="#F4F7FB" Visibility="Collapsed" Panel.ZIndex="10">
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
        <Grid x:Name="DoneMark" Width="110" Height="110" RenderTransformOrigin="0.5,0.5">
          <Grid.RenderTransform><ScaleTransform x:Name="DoneScale" ScaleX="0.3" ScaleY="0.3"/></Grid.RenderTransform>
          <Ellipse Fill="#12B76A"/>
          <TextBlock Text="&#10003;" Foreground="White" FontSize="58" FontWeight="Bold"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <TextBlock x:Name="DoneTitle" Text="Activated" FontSize="26" FontWeight="SemiBold"
                   Foreground="#101828" HorizontalAlignment="Center" Margin="0,22,0,0" Opacity="0"/>
        <TextBlock x:Name="DoneSub" Text="" Foreground="#475467" FontSize="13"
                   HorizontalAlignment="Center" Margin="0,8,0,0" Opacity="0" TextWrapping="Wrap"
                   MaxWidth="420" TextAlignment="Center"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="2" Background="#EDF2FA" Padding="26,16" Margin="0,22,0,0">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnRemove" Content="Remove this copy" Style="{StaticResource Ghost}" Foreground="#B42318" Margin="0,0,10,0"/><Button x:Name="BtnCancel" Content="Close" Style="{StaticResource Ghost}"/>
        <Button x:Name="BtnOk" Content="Activate" Style="{StaticResource Btn}" Margin="10,0,0,0"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'LblProduct','LblHeading','LblBlurb','TxtCode','LblHint','BtnRemove','BtnCancel','BtnOk',
                'DoneOverlay','DoneScale','DoneTitle','DoneSub') {
    $ui[$n] = $win.FindName($n)
}
$ui.LblProduct.Text = $Product
$ui.LblHeading.Text = $heading
$ui.LblBlurb.Text = $blurb
if ($Detail) { $ui.LblHint.Text = $Detail }

$script:Entered = ''
$script:Result = ''

function Get-DRSecretBytes {
    # licence.json sits beside this script inside the bundle.
    # The two programs carry differently named licence files, so try each.
    $file = $null
    foreach ($name in 'licence.json', 'licence_finder.json', 'licence_cleaner.json') {
        $candidate = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $file = $candidate; break }
    }
    if (-not $file) { return $null }
    try {
        $hex = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).secret
        $bytes = New-Object byte[] ($hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
        }
        return $bytes
    } catch { return $null }
}

function Get-DRSignature {
    param([byte[]]$Secret, [string]$Payload)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $Secret)
    $hash = ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Payload)) |
             ForEach-Object { $_.ToString('x2') }) -join ''
    $raw = $hash.Substring(0, 16).ToUpperInvariant()
    return ($raw -split '(.{4})' | Where-Object { $_ }) -join '-'
}

function Get-DRThisPcIds {
    # Same identifiers the launcher checks, so codes match either way.
    $ids = New-Object System.Collections.Generic.List[string]
    try {
        $uuid = (Get-CimInstance Win32_ComputerSystemProduct).UUID
        $serial = (Get-CimInstance Win32_BaseBoard).SerialNumber
        if ($uuid) { $ids.Add($uuid.Trim().ToLowerInvariant()) }
        if ($uuid -and $serial) { $ids.Add(("{0}-{1}" -f $uuid.Trim(), $serial.Trim()).ToLowerInvariant()) }
        if ($serial) { $ids.Add($serial.Trim().ToLowerInvariant()) }
    } catch { }
    return $ids
}

function Save-DRActivationFields {
    # One licence, one activation. This is the shared state file the Cleaner and
    # the Duplicate Finder both read, so a code entered in either one unlocks
    # both on this PC.
    param([hashtable]$Fields)
    $path = $script:DRStatePath
    $state = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $state[$_.Name] = $_.Value } } catch { }
    }
    foreach ($k in $Fields.Keys) { $state[$k] = $Fields[$k] }
    $state['needs_activation'] = $false
    $state.Remove('trial') | Out-Null
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    # No BOM. Set-Content -Encoding UTF8 writes one in Windows PowerShell, and
    # the launcher parses this file as plain UTF-8 JSON, which fails on it - so
    # the activation was saved correctly and then read back as nothing.
    [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}

function Save-DRActivation {
    param([string]$Field, $Value)
    Save-DRActivationFields @{ $Field = $Value }
}


function Show-DRActivated {
    <#
    .SYNOPSIS
        A short, plain celebration: the tick springs in, the words fade up.
    .DESCRIPTION
        Entirely cosmetic, so every part of it is guarded - the code has already
        been accepted by the time this runs and nothing here may undo that.
    #>
    param([string]$Message)
    try {
        $ui.DoneSub.Text = $Message
        $ui.DoneOverlay.Visibility = 'Visible'

    $spring = New-Object Windows.Media.Animation.DoubleAnimation(0.3, 1,
        (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(520))))
    $spring.EasingFunction = New-Object Windows.Media.Animation.BackEase -Property @{
        EasingMode = 'EaseOut'; Amplitude = 0.7 }
    $ui.DoneScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $spring)
    $ui.DoneScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $spring)

    foreach ($pair in @(@($ui.DoneTitle, 260), @($ui.DoneSub, 420))) {
        $fade = New-Object Windows.Media.Animation.DoubleAnimation(0, 1,
            (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(340))))
        $fade.BeginTime = [TimeSpan]::FromMilliseconds($pair[1])
        $pair[0].BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    }

    } catch { }

    # Let it be seen, then get out of the way. If even this fails, close now
    # rather than leaving the window stuck open after a successful activation.
    try {
        # Script scope, not local: a local variable is not visible inside the
        # tick handler when it fires later, and reading it there throws.
        $script:DRDoneTimer = New-Object Windows.Threading.DispatcherTimer
        $script:DRDoneWindow = $win
        $script:DRDoneTimer.Interval = [TimeSpan]::FromMilliseconds(2600)
        $script:DRDoneTimer.Add_Tick({
            try { $script:DRDoneTimer.Stop() } catch { }
            try { $script:DRDoneWindow.Close() } catch { }
        })
        $script:DRDoneTimer.Start()
    } catch {
        try { $win.Close() } catch { }
    }
}

$ui.BtnOk.Add_Click({
    $entered = $ui.TxtCode.Text.Trim().ToUpperInvariant()
    if (-not $entered) { $ui.LblHint.Text = 'Enter the code first.'; return }

    $secret = Get-DRSecretBytes
    if (-not $secret) { $ui.LblHint.Text = 'This copy cannot be activated here. Contact DRDirect.'; return }

    foreach ($pcId in Get-DRThisPcIds) {
        if ($entered -eq (Get-DRSignature $secret ("{0}|activate" -f $pcId))) {
            Save-DRActivation 'activated' $entered
            $script:Result = 'activated'
            Show-DRActivated 'This PC is activated. Everything is unlocked.'
            return
        }
        # A fresh free try, if that is what you chose to send.
        foreach ($offset in -14..7) {
            $issued = (Get-Date).Date.AddDays($offset).ToString('yyyy-MM-dd')
            if ($entered -eq (Get-DRSignature $secret ("{0}|once|{1}" -f $pcId, $issued))) {
                $path = $script:DRStatePath
                $state = @{}
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    try { (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).PSObject.Properties |
                            ForEach-Object { $state[$_.Name] = $_.Value } } catch { }
                }
                $state['needs_activation'] = $false
                $state['trial'] = @{ granted = (Get-Date).ToString('yyyy-MM-dd')
                                     clean_used = $false; category = $null }
                # No BOM. Set-Content -Encoding UTF8 writes one in Windows PowerShell, and
                # the launcher parses this file as plain UTF-8 JSON, which fails on it - so
                # the activation was saved correctly and then read back as nothing.
                [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
                $script:Result = 'activated'
                Show-DRActivated 'Another free try: one cleanup run and one duplicate category.'
                return
            }
        }

        foreach ($days in 7, 14, 91, 183, 365, 730) {
            foreach ($offset in -14..7) {
                $until = (Get-Date).Date.AddDays($offset + $days).ToString('yyyy-MM-dd')
                if ($entered -eq (Get-DRSignature $secret ("{0}|{1}" -f $pcId, $until))) {
                    # The launcher re-verifies the stored code against the stored
                    # date on every start, so both must be saved. Writing only the
                    # date left it unverifiable, and the activation was discarded
                    # on the next launch.
                    Save-DRActivationFields @{ until = $until; code = $entered }
                    $script:Result = 'activated'
                    Show-DRActivated "Activated until $until."
                    return
                }
            }
        }
    }
    $ui.LblHint.Text = 'That code is not correct for this PC. Check it and try again.'
})

$ui.BtnRemove.Add_Click({
    $answer = [Windows.MessageBox]::Show(
        "Remove everything DRDirect from this PC?" + [Environment]::NewLine + [Environment]::NewLine +
        "This deletes the settings, reports, licence and the program file itself. " +
        "It cannot be undone.",
        'DRDirect PC Cleaner', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    $problems = @()
    try {
        $appData = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner'
        if (Test-Path -LiteralPath $appData) { Remove-Item -LiteralPath $appData -Recurse -Force }
    } catch { $problems += $_.Exception.Message }

    # The program cannot delete itself while it is running, so hand the job to a
    # short script that waits for it to close, removes it, then removes itself.
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
            if ($p.ProcessName -like '*DRDirect PC Cleaner Locked*') { $exe = $p.Path; break }
        }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            $bat = Join-Path $env:TEMP 'drdirect_remove.cmd'
            $lines = @(
                '@echo off',
                'timeout /t 3 /nobreak >nul',
                (':retry'),
                ('del /f /q "' + $exe + '" >nul 2>&1'),
                ('if exist "' + $exe + '" (timeout /t 2 /nobreak >nul & goto retry)'),
                ('del /f /q "%~f0" >nul 2>&1')
            )
            Set-Content -LiteralPath $bat -Value $lines -Encoding ASCII
            Start-Process -FilePath $bat -WindowStyle Hidden
        }
    } catch { $problems += $_.Exception.Message }

    if ($problems) {
        [Windows.MessageBox]::Show(
            "Some of it could not be removed:" + [Environment]::NewLine +
            ($problems -join [Environment]::NewLine),
            'DRDirect PC Cleaner', 'OK', 'Warning') | Out-Null
    } else {
        [Windows.MessageBox]::Show(
            'Everything DRDirect has been removed from this PC. The program will close now.',
            'DRDirect PC Cleaner', 'OK', 'Information') | Out-Null
    }
    $script:Result = 'removed'
    $win.Close()
})

$ui.BtnCancel.Add_Click({ $script:Result = ''; $win.Close() })
$ui.TxtCode.Add_KeyDown({ if ($_.Key -eq 'Return') { $ui.BtnOk.RaiseEvent(
    (New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })

# Flash the window in the taskbar - this is the moment that matters.
Add-Type -Namespace DRD -Name Flash -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags;
                           public uint uCount; public uint dwTimeout; }
'@ -ErrorAction SilentlyContinue

$win.Add_ContentRendered({
    try {
        $helper = New-Object Windows.Interop.WindowInteropHelper($win)
        $info = New-Object DRD.Flash+FLASHWINFO
        $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($info)
        $info.hwnd = $helper.Handle
        $info.dwFlags = 0x3   # caption + taskbar button
        $info.uCount = 5
        $info.dwTimeout = 0
        [DRD.Flash]::FlashWindowEx([ref]$info) | Out-Null
    } catch { }

    # A gentle pulse on the code box, so the eye lands where it should.
    try {
        $pulse = New-Object Windows.Media.Animation.ColorAnimation
        $pulse.From = [Windows.Media.Colors]::White
        $pulse.To = [Windows.Media.Color]::FromRgb(0xDC, 0xE8, 0xFF)
        $pulse.Duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(650))
        $pulse.AutoReverse = $true
        $pulse.RepeatBehavior = New-Object Windows.Media.Animation.RepeatBehavior 3
        $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Colors]::White)
        $ui.TxtCode.Background = $brush
        $brush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $pulse)
    } catch { }
})

$ui.TxtCode.Focus() | Out-Null
try {
    $null = $win.ShowDialog()
} catch {
    # A code may already have been accepted before this blew up, so report
    # rather than swallow, and let the caller see the result either way.
    try {
        [Windows.MessageBox]::Show(
            "The window closed unexpectedly: $($_.Exception.Message)",
            'DRDirect', 'OK', 'Warning') | Out-Null
    } catch { }
}
Write-Output $script:Result
