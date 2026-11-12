# DRDirect Imager: compressed whole-drive images, check, and restore. Windows PowerShell 5.1.
param([switch]$NoElevate, [switch]$Master)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate) {
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`""); if ($Master) { $relaunch += '-Master' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $relaunch
    return
}
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", '-NoElevate:$' + [string]$NoElevate.IsPresent, '-Master:$' + [string]$Master.IsPresent)
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
# Master (owner-only) USB maker: works only beside the owner key file, which is never copied onto a customer's stick.
if ($Master -and -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'OWNER ONLY - master key.txt'))) { $Master = [switch]$false }
. (Join-Path $PSScriptRoot 'DRDirect Imager Engine.ps1')
# An older engine copy has no Format-TookTime; this keeps the finish time working with it.
if (-not (Get-Command Format-TookTime -ErrorAction SilentlyContinue)) {
    function Format-TookTime([double]$Seconds) {
        $t = [TimeSpan]::FromSeconds([Math]::Round([Math]::Max($Seconds, 0)))
        $h = [int][Math]::Floor($t.TotalHours)
        if ($h -ge 1) { return ('{0} h {1:00} min {2:00} sec' -f $h, $t.Minutes, $t.Seconds) }
        if ($t.Minutes -ge 1) { return ('{0} min {1:00} sec' -f $t.Minutes, $t.Seconds) }
        '{0} sec' -f $t.Seconds
    }
}
# If this copy runs from a Rescue USB (a pc.id file sits beside it), it works only on the PC that USB was made for.
$rescueLockFile = Join-Path $PSScriptRoot 'pc.id'
$ownerLockFile = Join-Path $PSScriptRoot 'owner.id'
# A copy of the stick onto another stick refuses to open; a master (owner) stick asks for the owner password instead of checking the PC.
if ((Test-Path -LiteralPath $rescueLockFile) -or (Test-Path -LiteralPath $ownerLockFile)) {
    $qual = Split-Path -Qualifier $PSScriptRoot
    if ($qual -and -not (Test-StickSerial $qual.Substring(0, 1) (Join-Path $PSScriptRoot 'usb.id'))) {
        [void][System.Windows.MessageBox]::Show("This USB is a copy and cannot be used. Ask DRDirect for a new Rescue USB.", 'DRDirect Clone & Backup', 'OK', 'Information')
        return
    }
}
if (Test-Path -LiteralPath $ownerLockFile) {
    $ownerRec = [string](Get-Content -LiteralPath $ownerLockFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    $okOwner = $false
    for ($try = 1; $try -le 3 -and -not $okOwner; $try++) {
        $pw = New-Object System.Windows.Window
        $pw.Title = 'DRDirect Clone & Backup'; $pw.SizeToContent = 'WidthAndHeight'; $pw.WindowStartupLocation = 'CenterScreen'; $pw.ResizeMode = 'NoResize'; $pw.Topmost = $true
        $pp = New-Object System.Windows.Controls.StackPanel; $pp.Margin = '24,18'
        $pl = New-Object System.Windows.Controls.TextBlock; $pl.Text = 'Owner password'; $pl.FontSize = 16; $pl.Margin = '0,0,0,8'; [void]$pp.Children.Add($pl)
        $pb = New-Object System.Windows.Controls.PasswordBox; $pb.Width = 260; $pb.FontSize = 16; [void]$pp.Children.Add($pb)
        $pk = New-Object System.Windows.Controls.Button; $pk.Content = 'OK'; $pk.Margin = '0,14,0,0'; $pk.Padding = '20,5'; $pk.IsDefault = $true; $pk.HorizontalAlignment = 'Right'; [void]$pp.Children.Add($pk)
        $pk.Add_Click({ $pw.DialogResult = $true })
        $pw.Content = $pp; $pw.Add_ContentRendered({ $pb.Focus() | Out-Null })
        if (-not $pw.ShowDialog()) { return }
        if (Test-OwnerRecord $pb.Password $ownerRec) { $okOwner = $true }
    }
    if (-not $okOwner) { return }
}
elseif (Test-Path -LiteralPath $rescueLockFile) {
    $mineHashes = @()
    try {
        $u = ([string](Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).UUID).Trim()
        $sn = ([string](Get-CimInstance Win32_BaseBoard -ErrorAction Stop).SerialNumber).Trim()
        $ids = @(); if ($u) { $ids += $u.ToLowerInvariant() }; if ($u -and $sn) { $ids += ('{0}-{1}' -f $u, $sn).ToLowerInvariant() }
        $mineHashes = @($ids | ForEach-Object { ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($_)) | ForEach-Object { $_.ToString('X2') }) -join '' })
    } catch { }
    $allowedHashes = @(Get-Content -LiteralPath $rescueLockFile -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
    $okLock = $false
    foreach ($h in $mineHashes) { if ($allowedHashes -contains $h.ToUpperInvariant()) { $okLock = $true } }
    if (-not $okLock) {
        [void][System.Windows.MessageBox]::Show("This Rescue USB was made for a different PC, so the app will not open here.", 'DRDirect Clone & Backup', 'OK', 'Information')
        return
    }
}

# ---------- shared 3D styles (same look as the Cleaner's buttons) ----------
$Styles = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <DropShadowEffect x:Key="Drop" Color="#0A1A4A" Direction="270" ShadowDepth="9" BlurRadius="14" Opacity="0.6"/>
  <Style x:Key="Tile" TargetType="Button">
    <Setter Property="Width" Value="128"/><Setter Property="Height" Value="128"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Foreground" Value="White"/><Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="54"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Grid Margin="0,0,0,8">
        <Border CornerRadius="14" Background="#B0000814" Margin="0,8,0,-8" IsHitTestVisible="False"/>
        <Grid x:Name="Face">
          <Border CornerRadius="14" BorderBrush="#88FFFFFF" BorderThickness="1,1,1,0"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5272AD" Offset="0"/><GradientStop Color="#28396B" Offset="0.5"/><GradientStop Color="#111C3B" Offset="1"/></LinearGradientBrush></Border.Background></Border>
          <Border CornerRadius="14,14,0,0" VerticalAlignment="Top" Height="44" Margin="1,1,1,0" Background="#26FFFFFF" IsHitTestVisible="False"/>
          <Border CornerRadius="0,0,14,14" VerticalAlignment="Bottom" Height="4" Margin="1,0,1,1" Background="#55000000" IsHitTestVisible="False"/>
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"><ContentPresenter.Effect><DropShadowEffect Color="Black" Direction="270" ShadowDepth="2" BlurRadius="3" Opacity="0.6"/></ContentPresenter.Effect></ContentPresenter>
          <Border x:Name="Hover" CornerRadius="14" Background="#22FFFFFF" Opacity="0" IsHitTestVisible="False"/>
        </Grid>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hover" Property="Opacity" Value="1"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="Face" Property="RenderTransform"><Setter.Value><TranslateTransform Y="5"/></Setter.Value></Setter></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Act" TargetType="Button">
    <Setter Property="Height" Value="40"/><Setter Property="MinWidth" Value="120"/><Setter Property="Margin" Value="8,0,0,10"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Foreground" Value="White"/><Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#4FC3FF" Offset="0"/><GradientStop Color="#1E6FE8" Offset="1"/></LinearGradientBrush></Setter.Value></Setter>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Grid>
        <Border CornerRadius="9" Background="#B0000814" Margin="0,6,0,-6" IsHitTestVisible="False"/>
        <Grid x:Name="Face">
          <Border CornerRadius="9" Background="{TemplateBinding Background}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"><ContentPresenter.Effect><DropShadowEffect Color="Black" Direction="270" ShadowDepth="1.5" BlurRadius="2" Opacity="0.45"/></ContentPresenter.Effect></ContentPresenter></Border>
          <Border CornerRadius="9,9,0,0" VerticalAlignment="Top" Height="14" Margin="1,1,1,0" Background="#3CFFFFFF" IsHitTestVisible="False"/>
          <Border CornerRadius="0,0,9,9" VerticalAlignment="Bottom" Height="3" Margin="1,0,1,1" Background="#40000000" IsHitTestVisible="False"/>
          <Border x:Name="Hover" CornerRadius="9" Background="#22FFFFFF" Opacity="0" IsHitTestVisible="False"/>
        </Grid>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hover" Property="Opacity" Value="1"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="Face" Property="RenderTransform"><Setter.Value><TranslateTransform Y="4"/></Setter.Value></Setter></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.42"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Steel" TargetType="Button" BasedOn="{StaticResource Act}">
    <Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5272AD" Offset="0"/><GradientStop Color="#28396B" Offset="0.5"/><GradientStop Color="#111C3B" Offset="1"/></LinearGradientBrush></Setter.Value></Setter>
  </Style>
  <Style x:Key="Nav" TargetType="Button">
    <Setter Property="Height" Value="70"/><Setter Property="Margin" Value="0,0,0,22"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Foreground" Value="#E6EEFA"/><Setter Property="FontSize" Value="19"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Grid>
        <Border CornerRadius="12" Background="#B0000814" Margin="0,6,0,-6" IsHitTestVisible="False"/>
        <Grid x:Name="Face">
          <Border CornerRadius="12" BorderBrush="#88FFFFFF" BorderThickness="1,1,1,0"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5272AD" Offset="0"/><GradientStop Color="#28396B" Offset="0.5"/><GradientStop Color="#111C3B" Offset="1"/></LinearGradientBrush></Border.Background></Border>
          <Border CornerRadius="12,12,0,0" VerticalAlignment="Top" Height="24" Margin="1,1,1,0" Background="#26FFFFFF" IsHitTestVisible="False"/>
          <Border CornerRadius="0,0,12,12" VerticalAlignment="Bottom" Height="3" Margin="1,0,1,1" Background="#55000000" IsHitTestVisible="False"/>
          <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Left" Margin="22,0,0,0"><ContentPresenter.Effect><DropShadowEffect Color="Black" Direction="270" ShadowDepth="1.5" BlurRadius="2" Opacity="0.5"/></ContentPresenter.Effect></ContentPresenter>
          <Border x:Name="Hover" CornerRadius="12" Background="#22FFFFFF" Opacity="0" IsHitTestVisible="False"/>
        </Grid>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hover" Property="Opacity" Value="1"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="Face" Property="RenderTransform"><Setter.Value><TranslateTransform Y="4"/></Setter.Value></Setter></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="TitleBtn" TargetType="Button">
    <Setter Property="Width" Value="46"/><Setter Property="Foreground" Value="White"/><Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="11"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border x:Name="B" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
      <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#33FFFFFF"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
    <LinearGradientBrush x:Key="HeroBrush" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#2B5FE3" Offset="0"/><GradientStop Color="#1E40AF" Offset="0.55"/><GradientStop Color="#3D2C8D" Offset="1"/></LinearGradientBrush>
    <LinearGradientBrush x:Key="CardFace" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFFFFF" Offset="0"/><GradientStop Color="#EEF6FF" Offset="1"/></LinearGradientBrush>
</ResourceDictionary>
'@

function New-Window([string]$xaml) {
    # the shared styles must be inside the window when it loads, or {StaticResource} lookups fail
    $dict = $Styles -replace ' xmlns(:x)?="[^"]*"', ''
    $open = $xaml.IndexOf('>', $xaml.IndexOf('<Window')) + 1
    $xaml = $xaml.Insert($open, "<Window.Resources>$dict</Window.Resources>")
    $x = [xml]$xaml
    [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $x))
}
function Add-Styles($win) { }

$main = New-Window @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DRDirect Clone &amp; Backup" Width="1160" Height="760" WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize" FontFamily="Segoe UI" BorderBrush="#1B3E86" BorderThickness="1">
  <Window.Background><RadialGradientBrush Center="0.5,0.38" GradientOrigin="0.5,0.3" RadiusX="0.95" RadiusY="0.95"><GradientStop Color="#D9E0EE" Offset="0"/><GradientStop Color="#BAC6DD" Offset="0.6"/><GradientStop Color="#97A7C5" Offset="1"/></RadialGradientBrush></Window.Background>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="40"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Border Grid.Row="0" BorderBrush="#1B3E86" BorderThickness="0,0,0,1">
      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#1E40AF" Offset="0"/><GradientStop Color="#2B5FE3" Offset="1"/></LinearGradientBrush></Border.Background>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Grid x:Name="TitleDrag" Background="Transparent"><StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
          <Image x:Name="Logo2" Width="26" Height="26" RenderOptions.BitmapScalingMode="HighQuality"/>
          <TextBlock Text="DRDirect Clone &amp; Backup" Foreground="White" FontSize="19" FontWeight="SemiBold" Margin="12,0,0,0" VerticalAlignment="Center"/></StackPanel></Grid>
        <Button x:Name="TMin" Grid.Column="1" Style="{StaticResource TitleBtn}" Content="&#xE921;"/>
        <Button x:Name="TMax" Grid.Column="2" Style="{StaticResource TitleBtn}" Content="&#xE922;"/>
        <Button x:Name="TClose" Grid.Column="3" Style="{StaticResource TitleBtn}" Content="&#xE8BB;"/>
      </Grid>
    </Border>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="300"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#1A2E4C" Offset="0"/><GradientStop Color="#12203A" Offset="1"/></LinearGradientBrush></Border.Background>
        <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Margin="24,26,22,0">
            <StackPanel Orientation="Horizontal" Margin="0,0,0,34">
              <Image x:Name="Logo" Width="84" Height="84" RenderOptions.BitmapScalingMode="HighQuality"/>
              <StackPanel Margin="16,6,0,0"><TextBlock Text="DRDirect" Foreground="White" FontSize="28" FontWeight="Bold"/><TextBlock Text="Clone &amp; Backup" Foreground="#C9D5E6" FontSize="17"/><TextBlock x:Name="VersionText" Foreground="#FFE14D" FontSize="14" FontWeight="SemiBold" Margin="0,4,0,0"/></StackPanel>
            </StackPanel>
            <Button x:Name="NavClone" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8C8;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="#FFD54A" Width="44" VerticalAlignment="Center"/><TextBlock Text="SmartCopy" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Button>
            <Button x:Name="NavCreate" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74E;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="#FFD54A" Width="44" VerticalAlignment="Center"/><TextBlock Text="Secure" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Button>
            <Button x:Name="NavRestore" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE777;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="#FFD54A" Width="44" VerticalAlignment="Center"/><TextBlock Text="Restore" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Button>
            <Button x:Name="NavUsb" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE88E;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="#FFD54A" Width="44" VerticalAlignment="Center"/><TextBlock Text="Rescue USB" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Button>
          </StackPanel>
          <StackPanel Grid.Row="2" Margin="24,0,22,18"><Button x:Name="NavUpdate" Style="{StaticResource Nav}" Margin="0,0,0,12"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE895;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="#FFD54A" Width="44" VerticalAlignment="Center"/><TextBlock Text="Check for updates" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Button><Border x:Name="ActivatedBadge" Visibility="Collapsed" CornerRadius="8" Background="#1E4FA8" BorderBrush="#7FB0FF" BorderThickness="1" Padding="8,10" Margin="0,0,0,14"><TextBlock Text="&#x2714;  All Activated" HorizontalAlignment="Center" Foreground="#7CFFA6" FontSize="14" FontWeight="Bold"/></Border><TextBlock Text="Administrator session" Foreground="#9FB2CF" FontSize="13" Margin="0,2,0,0"/></StackPanel>
        </Grid>
      </Border>
      <Grid Grid.Column="1" Margin="30,22,30,24">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,16"><TextBlock Text="THIS PC" Foreground="#5B6B86" FontSize="13" FontWeight="SemiBold"/><TextBlock Text="Cloning" Foreground="#172033" FontSize="38" FontWeight="SemiBold"/></StackPanel>
        <Grid Grid.Row="1" Margin="0,0,0,26">
          <Border CornerRadius="26" Background="#B3000A30" Margin="0,10,0,-10"/>
          <Border CornerRadius="26" Background="{StaticResource HeroBrush}" BorderBrush="#99FFFFFF" BorderThickness="2">
            <Grid>
              <Border CornerRadius="24,24,0,0" VerticalAlignment="Top" Height="70" Background="#1FFFFFFF" IsHitTestVisible="False"/>
              <StackPanel VerticalAlignment="Center">
                <TextBlock Text="Clone, back up and restore" Foreground="White" FontSize="40" FontWeight="Bold" HorizontalAlignment="Center"><TextBlock.Effect><DropShadowEffect Color="#000820" Direction="300" ShadowDepth="3.5" BlurRadius="3" Opacity="0.85"/></TextBlock.Effect></TextBlock>
                <TextBlock Text="your whole drives, with every partition and Windows" Foreground="#DCE8FF" FontSize="16" HorizontalAlignment="Center" Margin="0,4,0,34"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                  <StackPanel Margin="10,0"><Button x:Name="BtnClone" Style="{StaticResource Tile}" Content="&#xE8C8;"/><TextBlock Text="SmartCopy" Foreground="White" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,12,0,0"><TextBlock.Effect><DropShadowEffect Color="#000820" Direction="300" ShadowDepth="2.5" BlurRadius="3" Opacity="0.8"/></TextBlock.Effect></TextBlock><TextBlock Text="Drive onto drive" Foreground="#DCE8FF" FontSize="13" HorizontalAlignment="Center" Margin="0,2,0,0"/></StackPanel><StackPanel Margin="10,0"><Button x:Name="BtnCreate" Style="{StaticResource Tile}" Content="&#xE74E;"/><TextBlock Text="Secure" Foreground="White" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,12,0,0"><TextBlock.Effect><DropShadowEffect Color="#000820" Direction="300" ShadowDepth="2.5" BlurRadius="3" Opacity="0.8"/></TextBlock.Effect></TextBlock><TextBlock Text="Drive into an image" Foreground="#DCE8FF" FontSize="13" HorizontalAlignment="Center" Margin="0,2,0,0"/></StackPanel><StackPanel Margin="10,0"><Button x:Name="BtnRestore" Style="{StaticResource Tile}" Content="&#xE777;"/><TextBlock Text="Restore" Foreground="White" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,12,0,0"><TextBlock.Effect><DropShadowEffect Color="#000820" Direction="300" ShadowDepth="2.5" BlurRadius="3" Opacity="0.8"/></TextBlock.Effect></TextBlock><TextBlock Text="Image back onto a drive" Foreground="#DCE8FF" FontSize="13" HorizontalAlignment="Center" Margin="0,2,0,0"/></StackPanel><StackPanel Margin="10,0"><Button x:Name="BtnUsb" Style="{StaticResource Tile}" Content="&#xE88E;"/><TextBlock Text="Rescue USB" Foreground="White" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,12,0,0"><TextBlock.Effect><DropShadowEffect Color="#000820" Direction="300" ShadowDepth="2.5" BlurRadius="3" Opacity="0.8"/></TextBlock.Effect></TextBlock><TextBlock Text="Boot and reinstall Windows" Foreground="#DCE8FF" FontSize="13" HorizontalAlignment="Center" Margin="0,2,0,0"/></StackPanel>
                </StackPanel>
              </StackPanel>
            </Grid>
          </Border>
        </Grid>
        <Grid Grid.Row="2" Margin="0,8,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Margin="0,0,10,10" CornerRadius="18" Background="{StaticResource CardFace}" BorderBrush="#99FFFFFF" BorderThickness="1" Padding="22,18">
          <Border.Effect><DropShadowEffect Color="#16275A" Direction="270" ShadowDepth="7" BlurRadius="14" Opacity="0.35"/></Border.Effect>
          <StackPanel><TextBlock Text="DRIVES FOUND" Foreground="#0F7B72" FontWeight="Bold" FontSize="13"/>
            <TextBlock x:Name="CardA" Text="" Foreground="#172033" FontSize="28" FontWeight="SemiBold" Margin="0,8,0,0"/>
            <TextBlock x:Name="CardASub" Text="" Foreground="#5B6B86" FontSize="13" Margin="0,4,0,0" TextWrapping="Wrap"/></StackPanel></Border>
        <Border Grid.Column="1" Margin="5,0,5,10" CornerRadius="18" Background="{StaticResource CardFace}" BorderBrush="#99FFFFFF" BorderThickness="1" Padding="22,18">
          <Border.Effect><DropShadowEffect Color="#16275A" Direction="270" ShadowDepth="7" BlurRadius="14" Opacity="0.35"/></Border.Effect>
          <StackPanel><TextBlock Text="FREE SPACE" Foreground="#0F7B72" FontWeight="Bold" FontSize="13"/>
            <TextBlock x:Name="CardB" Text="" Foreground="#172033" FontSize="28" FontWeight="SemiBold" Margin="0,8,0,0"/>
            <TextBlock x:Name="CardBSub" Text="" Foreground="#5B6B86" FontSize="13" Margin="0,4,0,0" TextWrapping="Wrap"/></StackPanel></Border>
        <Border Grid.Column="2" Margin="10,0,0,10" CornerRadius="18" Background="{StaticResource CardFace}" BorderBrush="#99FFFFFF" BorderThickness="1" Padding="22,18">
          <Border.Effect><DropShadowEffect Color="#16275A" Direction="270" ShadowDepth="7" BlurRadius="14" Opacity="0.35"/></Border.Effect>
          <StackPanel><TextBlock Text="IMAGE SIZE" Foreground="#0F7B72" FontWeight="Bold" FontSize="13"/>
            <TextBlock x:Name="CardC" Text="" Foreground="#172033" FontSize="28" FontWeight="SemiBold" Margin="0,8,0,0"/>
            <TextBlock x:Name="CardCSub" Text="" Foreground="#5B6B86" FontSize="13" Margin="0,4,0,0" TextWrapping="Wrap"/></StackPanel></Border>
        </Grid>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@
$logoFile = Join-Path $PSScriptRoot 'DRDirect Logo.png'
if (Test-Path -LiteralPath $logoFile) {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit(); $bmp.UriSource = New-Object Uri $logoFile; $bmp.CacheOption = 'OnLoad'; $bmp.EndInit()
    $main.FindName('Logo').Source = $bmp
    $main.FindName('Logo2').Source = $bmp
    $script:LogoBmp = $bmp
    $main.Icon = $bmp
}
# Every window gets the DRDirect logo in its title bar instead of the PowerShell icon.
function Set-WinBrand($win) { if ($script:LogoBmp) { try { $win.Icon = $script:LogoBmp } catch { } } }
$main.MaxHeight = [Windows.SystemParameters]::WorkArea.Height
$main.MaxWidth = [Windows.SystemParameters]::WorkArea.Width
$main.FindName('TitleDrag').Add_MouseLeftButtonDown({ $main.DragMove() })
$main.FindName('TMin').Add_Click({ $main.WindowState = 'Minimized' })
$main.FindName('TMax').Add_Click({ $main.WindowState = $(if ($main.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }) })
$main.FindName('TClose').Add_Click({ $main.Close() })

# the three cards under the big panel
try {
    $dl = @(Get-ImagerDisks)
    $main.FindName('CardA').Text = "$($dl.Count) drives"
    $main.FindName('CardASub').Text = (($dl | ForEach-Object { if ($_.Letters) { $_.Letters } }) -join '   ')
    $win = $dl | Where-Object { $_.IsWindows } | Select-Object -First 1
    $letter = if ($win -and $win.Letters) { ($win.Letters -split ' ')[0].TrimEnd(':') } else { 'C' }
    $free = (Get-Volume -DriveLetter $letter -ErrorAction Stop).SizeRemaining
    $main.FindName('CardB').Text = (Format-ImgSize $free)
    $main.FindName('CardBSub').Text = "On your Windows drive ($($letter):)"
} catch { }
$main.FindName('CardC').Text = 'Smallest'
$main.FindName('CardCSub').Text = 'Secure uses maximum compression'

# ---------- Rescue USB ----------
# Only USB flash drives are ever offered: never the Windows drive, never an internal drive.
function Get-RescueUsbDisks {
    foreach ($d in (Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)) {
        if ([string]$d.BusType -ne 'USB' -or $d.IsBoot -or $d.IsSystem) { continue }
        $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { [string]$_.DriveLetter })
        $files = 0; $usedBytes = 0L
        foreach ($l in $letters) {
            try {
                $v = Get-Volume -DriveLetter $l -ErrorAction Stop
                $usedBytes += ($v.Size - $v.SizeRemaining)
                $files += @(Get-ChildItem -LiteralPath ("$l`:\") -Recurse -File -Force -ErrorAction SilentlyContinue).Count
            } catch { }
        }
        [pscustomobject]@{ Number = [int]$d.Number; Name = [string]$d.FriendlyName; Size = [int64]$d.Size; Letters = $letters; Files = $files; UsedBytes = $usedBytes }
    }
}

# The big red warning. Returns $true only if the person typed the drive letter (or ERASE when the stick has no letter).
function Confirm-RescueUsbErase($Usb) {
    $win = New-Object System.Windows.Window
    $win.Title = 'DRDirect Clone & Backup - Rescue USB'; Set-WinBrand $win
    $win.SizeToContent = 'WidthAndHeight'; $win.MaxWidth = 560; $win.ResizeMode = 'NoResize'
    $win.WindowStartupLocation = 'CenterScreen'; $win.Topmost = $true
    $panel = New-Object System.Windows.Controls.StackPanel; $panel.Margin = '24,20,24,18'
    $head = New-Object System.Windows.Controls.TextBlock
    $head.Text = 'This USB flash drive will be erased'
    $head.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#B45309'))); $head.FontWeight = 'SemiBold'; $head.FontSize = 20; $head.TextWrapping = 'Wrap'
    [void]$panel.Children.Add($head)
    $letterText = if ($Usb.Letters.Count) { ($Usb.Letters | ForEach-Object { "$($_):" }) -join ' ' } else { 'no drive letter' }
    $what = if ($Usb.Files -gt 0) { "It holds $($Usb.Files) file(s), about $(Format-ImgSize $Usb.UsedBytes). Please copy anything you want to keep first." } else { 'It looks empty, so there is nothing to lose.' }
    $info = New-Object System.Windows.Controls.TextBlock
    $info.Text = "Drive:  $($Usb.Name)`nLetter: $letterText`nSize:   $(Format-ImgSize $Usb.Size)`n`n$what`n`nTo make the Rescue USB, the stick is cleared first, and then the rescue system is put on it. Your other drives are not touched. Please make sure this is the right stick: DRDirect is not responsible for files lost on the stick you choose."
    $info.TextWrapping = 'Wrap'; $info.FontSize = 14; $info.Margin = '0,14,0,0'
    [void]$panel.Children.Add($info)
    $need = if ($Usb.Letters.Count) { $Usb.Letters[0].ToUpperInvariant() } else { 'ERASE' }
    $ask = New-Object System.Windows.Controls.TextBlock
    $ask.Text = if ($Usb.Letters.Count) { "When you are ready, type the drive letter ($need) below:" } else { 'When you are ready, type ERASE below:' }
    $ask.FontWeight = 'SemiBold'; $ask.Margin = '0,16,0,6'
    [void]$panel.Children.Add($ask)
    $box = New-Object System.Windows.Controls.TextBox; $box.FontSize = 16; $box.MaxLength = 5
    [void]$panel.Children.Add($box)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = '0,18,0,0'
    $cancel = New-Object System.Windows.Controls.Button; $cancel.Content = 'Not now'; $cancel.Padding = '16,6'; $cancel.IsDefault = $true; $cancel.IsCancel = $true
    $go = New-Object System.Windows.Controls.Button; $go.Content = 'Make the Rescue USB'; $go.Padding = '16,6'; $go.Margin = '12,0,0,0'; $go.IsEnabled = $false
    $go.FontWeight = 'SemiBold'
    [void]$row.Children.Add($cancel); [void]$row.Children.Add($go); [void]$panel.Children.Add($row)
    $box.Add_TextChanged({ $go.IsEnabled = ($box.Text.Trim().ToUpperInvariant() -eq $need) })
    $go.Add_Click({ $win.DialogResult = $true })
    $win.Content = $panel
    $win.Add_ContentRendered({ $box.Focus() | Out-Null })
    return ([bool]$win.ShowDialog())
}

# Erases the chosen USB stick, formats it, and writes the rescue system on it. Returns @{ Ok; Message }.
# Safety: only a USB disk that is not the Windows disk, and only if the expected drive letter is on it.
# -AllowVirtual is for the test with a temporary virtual drive only.
function Write-RescueUsb {
    param([int]$DiskNumber, [string]$IsoPath, [string]$ExpectLetter, [switch]$AllowVirtual, [string]$OwnerPassword, [scriptblock]$Say = { param($t) })
    $mounted = $false
    try {
        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        $okBus = ([string]$disk.BusType -eq 'USB') -or ($AllowVirtual -and [string]$disk.BusType -eq 'File Backed Virtual')
        if (-not $okBus) { return @{ Ok = $false; Message = "Disk $DiskNumber is not a USB flash drive. Nothing was changed." } }
        if ($disk.IsBoot -or $disk.IsSystem) { return @{ Ok = $false; Message = 'That is the Windows drive. Nothing was changed.' } }
        if (-not (Test-Path -LiteralPath $IsoPath)) { return @{ Ok = $false; Message = 'The rescue file is missing. Nothing was changed.' } }
        if ($ExpectLetter) {
            $have = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { [string]$_.DriveLetter })
            if ($have -notcontains $ExpectLetter.ToUpperInvariant()) { return @{ Ok = $false; Message = "Drive $($ExpectLetter): is not on disk $DiskNumber any more. Nothing was changed." } }
        }
        & $Say 'Erasing the USB flash drive...'
        Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue
        Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue
        # A brand-new stick can be raw (never initialized); there is nothing to clear on it.
        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        if ([string]$disk.PartitionStyle -ne 'RAW') { Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop }
        # After clearing, Windows may leave the stick already set up (empty MBR) or raw; set it up only when raw, and make sure it is MBR.
        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        if ([string]$disk.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction Stop }
        elseif ([string]$disk.PartitionStyle -ne 'MBR') { Set-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction Stop }
        & $Say 'Formatting...'
        # FAT32 so every PC can start from it; Windows formats FAT32 only up to 32 GB, so the first partition is capped.
        $cap = [int64]30GB
        $part = if ($disk.Size -gt $cap) { New-Partition -DiskNumber $DiskNumber -Size $cap -AssignDriveLetter -IsActive -ErrorAction Stop } else { New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter -IsActive -ErrorAction Stop }
        $null = Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'DRDIRECT' -Confirm:$false -Force -ErrorAction Stop
        $dest = ([string]$part.DriveLetter) + ':\'
        & $Say 'Copying the rescue system...'
        $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $mounted = $true
        $src = (($img | Get-Volume).DriveLetter) + ':\'
        & robocopy.exe $src $dest /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Copying failed (robocopy code $LASTEXITCODE)." }
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null; $mounted = $false
        # Old-style PCs (BIOS) need the boot sector written too.
        $bootsect = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'ADK') -Recurse -Filter 'bootsect.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($bootsect) { & $bootsect.FullName /nt60 ($dest.TrimEnd('\')) /force /mbr 2>&1 | Out-Null }
        & $Say 'Setting up the stick...'
        # Boot files are hidden, so the stick looks tidy: only the DRDirect app, a launcher and a readme show.
        foreach ($item in (Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue)) {
            try { $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System } catch { }
        }
        $app = Join-Path $dest 'DRDirect'; $null = New-Item -ItemType Directory -Force -Path $app
        # The Windows app on the stick, so the same stick also works from inside Windows.
        foreach ($f in 'DRDirect Imager.ps1', 'DRDirect Imager Engine.ps1', 'DRDirect Image.ico', 'DRDirect Logo.png') {
            $s = Join-Path $PSScriptRoot $f
            if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination $app -Force }
        }
        $ico = Join-Path $PSScriptRoot 'DRDirect Image.ico'
        if (Test-Path -LiteralPath $ico) {
            Copy-Item -LiteralPath $ico -Destination (Join-Path $app 'DRDirect.ico') -Force
            Set-Content -LiteralPath (Join-Path $dest 'autorun.inf') -Value "[autorun]`r`nicon=DRDirect\DRDirect.ico`r`nlabel=DRDirect Rescue" -Encoding ASCII
            try { (Get-Item -LiteralPath (Join-Path $dest 'autorun.inf') -Force).Attributes = 'Hidden, System, Archive' } catch { }
        }
        $launcher = "@echo off`r`nstart `"`" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"%~dp0DRDirect\DRDirect Imager.ps1`"`r`n"
        Set-Content -LiteralPath (Join-Path $dest 'DRDirect Clone & Backup.bat') -Value $launcher -Encoding ASCII
        $readme = "Directional Aid for Users`r`n-------------------------`r`n`r`nThis is a DRDirect Rescue USB. It holds hidden boot files. Please do not change anything on it.`r`nTo start a rescue, restart the PC from this USB. To use the app inside Windows, open DRDirect Clone & Backup.bat.`r`nTo make another Rescue USB, use the Rescue USB button in DRDirect Clone & Backup. Copying these files is not enough.`r`n`r`nDRDirect`r`n"
        Set-Content -LiteralPath (Join-Path $dest 'readme.txt') -Value $readme -Encoding ASCII
        # The PC this stick was made for, kept as hashes (never the plain ID), for the PC lock.
        # The stick's own serial number, so a copy on another stick refuses to start (skipped when the stick reports none).
        $serialHash = Get-StickSerialHash ([string]$part.DriveLetter)
        if ($serialHash) { Set-Content -LiteralPath (Join-Path $app 'usb.id') -Value $serialHash -Encoding ASCII }
        if ($OwnerPassword) {
            # Master stick: no PC lock; it asks for the owner password instead.
            Set-Content -LiteralPath (Join-Path $app 'owner.id') -Value (New-OwnerRecord $OwnerPassword) -Encoding ASCII
        } else {
        try {
            $uuid = ([string](Get-CimInstance Win32_ComputerSystemProduct).UUID).Trim()
            $serial = ([string](Get-CimInstance Win32_BaseBoard).SerialNumber).Trim()
            $ids = @(); if ($uuid) { $ids += $uuid.ToLowerInvariant() }; if ($uuid -and $serial) { $ids += ("{0}-{1}" -f $uuid, $serial).ToLowerInvariant() }
            $hashes = foreach ($id in $ids) { ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($id)) | ForEach-Object { $_.ToString('X2') }) -join '' }
            Set-Content -LiteralPath (Join-Path $app 'pc.id') -Value $hashes -Encoding ASCII
        } catch { }
        }
        # Lock files are hidden and read-only so they are not changed by accident.
        foreach ($lf in 'pc.id', 'owner.id', 'usb.id') { $lp = Join-Path $app $lf; if (Test-Path -LiteralPath $lp) { try { (Get-Item -LiteralPath $lp -Force).Attributes = 'Hidden, ReadOnly, Archive' } catch { } } }
        & $Say 'Checking...'
        foreach ($need in 'bootmgr', 'EFI\Boot\bootx64.efi', 'sources\boot.wim', $(if ($OwnerPassword) { 'DRDirect\owner.id' } else { 'DRDirect\pc.id' }), 'DRDirect\DRDirect Imager.ps1', 'readme.txt') {
            if (-not (Test-Path -LiteralPath (Join-Path $dest $need))) { throw "The check failed: $need is missing on the USB." }
        }
        return @{ Ok = $true; Message = "The Rescue USB is ready on drive $($dest.Substring(0,2))." ; Letter = $dest.Substring(0,2) }
    } catch {
        return @{ Ok = $false; Message = "It did not finish: $($_.Exception.Message)" }
    } finally {
        if ($mounted) { try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch { } }
    }
}

# When more than one USB stick is plugged in, the person picks the right one. Returns the chosen stick, or $null.
function Select-RescueUsb($Sticks) {
    $win = New-Object System.Windows.Window
    $win.Title = 'DRDirect Clone & Backup - Rescue USB'; Set-WinBrand $win; $win.SizeToContent = 'WidthAndHeight'; $win.MinWidth = 520; $win.MaxWidth = 640; $win.ResizeMode = 'NoResize'
    $win.WindowStartupLocation = 'CenterScreen'; $win.Topmost = $true
    $panel = New-Object System.Windows.Controls.StackPanel; $panel.Margin = '24,20,24,18'
    $head = New-Object System.Windows.Controls.TextBlock; $head.Text = 'Which USB flash drive?'; $head.FontSize = 20; $head.FontWeight = 'SemiBold'
    [void]$panel.Children.Add($head)
    $sub = New-Object System.Windows.Controls.TextBlock; $sub.TextWrapping = 'Wrap'; $sub.Margin = '0,8,0,10'
    $sub.Text = 'More than one USB flash drive is plugged in. Pick the one to turn into the Rescue USB. Make sure it is the right one: DRDirect is not responsible for files lost on a stick you choose.'
    [void]$panel.Children.Add($sub)
    $list = New-Object System.Windows.Controls.ListBox; $list.FontSize = 15; $list.MinHeight = 90
    foreach ($s in $Sticks) {
        $letters = if ($s.Letters.Count) { ($s.Letters | ForEach-Object { "$($_):" }) -join ' ' } else { 'no letter' }
        $item = New-Object System.Windows.Controls.ListBoxItem; $item.Padding = '8,6'; $item.Tag = $s
        $item.Content = "$letters    $($s.Name)    $(Format-ImgSize $s.Size)    $($s.Files) file(s)"
        [void]$list.Items.Add($item)
    }
    $list.SelectedIndex = -1
    [void]$panel.Children.Add($list)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = '0,16,0,0'
    $cancel = New-Object System.Windows.Controls.Button; $cancel.Content = 'Not now'; $cancel.Padding = '16,6'; $cancel.IsCancel = $true
    $next = New-Object System.Windows.Controls.Button; $next.Content = 'Next'; $next.Padding = '16,6'; $next.Margin = '12,0,0,0'; $next.IsEnabled = $false; $next.IsDefault = $true
    [void]$row.Children.Add($cancel); [void]$row.Children.Add($next); [void]$panel.Children.Add($row)
    $list.Add_SelectionChanged({ $next.IsEnabled = ($list.SelectedItem -ne $null) })
    $next.Add_Click({ $win.DialogResult = $true })
    $win.Content = $panel
    if ($win.ShowDialog()) { return $list.SelectedItem.Tag }
    return $null
}
# Asks the owner for a new password twice. Returns the password, or $null if cancelled.
function Read-NewOwnerPassword {
    $w2 = New-Object System.Windows.Window
    $w2.Title = 'DRDirect Clone & Backup - Master Rescue USB'; Set-WinBrand $w2; $w2.SizeToContent = 'WidthAndHeight'; $w2.WindowStartupLocation = 'CenterScreen'; $w2.ResizeMode = 'NoResize'; $w2.Topmost = $true
    $p2 = New-Object System.Windows.Controls.StackPanel; $p2.Margin = '24,18'
    $t0 = New-Object System.Windows.Controls.TextBlock; $t0.TextWrapping = 'Wrap'; $t0.MaxWidth = 380; $t0.Margin = '0,0,0,10'
    $t0.Text = 'This stick works on any PC, for you only. Choose the owner password it will ask for. At least 8 characters. Write it down somewhere safe: it cannot be recovered.'
    $l1 = New-Object System.Windows.Controls.TextBlock; $l1.Text = 'Owner password'
    $b1 = New-Object System.Windows.Controls.PasswordBox; $b1.Width = 260; $b1.FontSize = 16
    $l2 = New-Object System.Windows.Controls.TextBlock; $l2.Text = 'Type it again'; $l2.Margin = '0,8,0,0'
    $b2 = New-Object System.Windows.Controls.PasswordBox; $b2.Width = 260; $b2.FontSize = 16
    $msg = New-Object System.Windows.Controls.TextBlock; $msg.Foreground = 'DarkRed'; $msg.Margin = '0,8,0,0'
    $ok = New-Object System.Windows.Controls.Button; $ok.Content = 'Next'; $ok.Margin = '0,12,0,0'; $ok.Padding = '20,5'; $ok.IsDefault = $true; $ok.HorizontalAlignment = 'Right'
    foreach ($e in $t0, $l1, $b1, $l2, $b2, $msg, $ok) { [void]$p2.Children.Add($e) }
    $ok.Add_Click({
        if ($b1.Password.Length -lt 8) { $msg.Text = 'Use at least 8 characters.' }
        elseif ($b1.Password -cne $b2.Password) { $msg.Text = 'The two passwords are not the same.' }
        else { $w2.DialogResult = $true }
    })
    $w2.Content = $p2
    if ($w2.ShowDialog()) { return $b1.Password }
    return $null
}
function Show-RescueUsb {
    param([switch]$Master)
    $dry = [bool]$env:DRIMG_USB_DRYRUN       # test switch: shows the whole flow, erases and writes nothing
    $iso = Join-Path $PSScriptRoot 'DRDirect Imager Rescue.iso'
    if (-not $dry -and -not (Test-Path -LiteralPath $iso)) {
        [System.Windows.MessageBox]::Show("The Rescue USB is not ready yet.`n`nThe rescue system it boots from is still being built on this PC. This button will make the USB as soon as that is finished.`n`nWhen it is ready, it will clear the USB flash drive you choose and set it up. It always asks you first.", 'Rescue USB', 'OK', 'Information') | Out-Null
        return
    }
    $sticks = @(Get-RescueUsbDisks)
    if (-not $sticks.Count) {
        [System.Windows.MessageBox]::Show("No USB flash drive was found.`n`nPlug in the USB flash drive you want to turn into a Rescue USB, then press the button again. The stick will be cleared, so use one you do not need.", 'Rescue USB', 'OK', 'Information') | Out-Null
        return
    }
    $usb = $sticks[0]
    if ($sticks.Count -gt 1) {
        $usb = Select-RescueUsb $sticks
        if (-not $usb) { return }
    }
    $ownerPw = ''
    if ($Master) {
        $ownerPw = Read-NewOwnerPassword
        if (-not $ownerPw) { return }
    }
    if (-not (Confirm-RescueUsbErase $usb)) { return }
    if ($dry) {
        [System.Windows.MessageBox]::Show("Dry run: nothing was erased or written.", 'Rescue USB', 'OK', 'Information') | Out-Null
        return
    }
    $work = New-Object System.Windows.Window
    $work.Title = 'DRDirect Clone & Backup - Rescue USB'; Set-WinBrand $work; $work.SizeToContent = 'WidthAndHeight'; $work.WindowStartupLocation = 'CenterScreen'; $work.Topmost = $true; $work.ResizeMode = 'NoResize'
    $note = New-Object System.Windows.Controls.TextBlock; $note.Margin = '30,24'; $note.FontSize = 16; $note.Text = 'Starting...'
    $work.Content = $note; $work.Show()
    $r = Write-RescueUsb -DiskNumber $usb.Number -IsoPath $iso -ExpectLetter $(if ($usb.Letters.Count) { $usb.Letters[0] } else { '' }) -OwnerPassword $ownerPw -Say { param($t) $note.Text = "$t`nPlease do not remove the USB."; $work.Dispatcher.Invoke([Action]{}, 'Render') }
    $work.Close()
    [System.Windows.MessageBox]::Show($r.Message, 'Rescue USB', 'OK', $(if ($r.Ok) { 'Information' } else { 'Warning' })) | Out-Null
}

# ---------- job dialog (form page + progress page) ----------
function Show-JobDialog {
    param([ValidateSet('create', 'check', 'restore', 'clone')][string]$Mode)

    $title = @{ create = 'Secure'; check = 'Check Image'; restore = 'Restore'; clone = 'SmartCopy' }[$Mode]
    $w = New-Window @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="640" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" FontFamily="Segoe UI">
  <Window.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#EEF6FF" Offset="0"/><GradientStop Color="#CFE2FB" Offset="1"/></LinearGradientBrush></Window.Background>
  <Grid Margin="26,22,26,12">
    <StackPanel x:Name="Form">
      <TextBlock x:Name="Head" FontSize="24" FontWeight="SemiBold" Foreground="#16275A"/>
      <TextBlock x:Name="Sub" TextWrapping="Wrap" Foreground="#3A4A6A" FontSize="14" Margin="0,4,0,16"/>
      <StackPanel x:Name="DiskRow"><TextBlock x:Name="DiskLabel" FontWeight="SemiBold" Foreground="#16275A" Margin="0,0,0,4"/><ComboBox x:Name="Disk" FontSize="14" Height="30"/></StackPanel>
      <StackPanel x:Name="Disk2Row" Margin="0,14,0,0" Visibility="Collapsed"><TextBlock x:Name="Disk2Label" FontWeight="SemiBold" Foreground="#16275A" Margin="0,0,0,4"/><ComboBox x:Name="Disk2" FontSize="14" Height="30"/></StackPanel>
      <StackPanel x:Name="FileRow" Margin="0,14,0,0"><TextBlock x:Name="FileLabel" FontWeight="SemiBold" Foreground="#16275A" Margin="0,0,0,4"/>
        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBox x:Name="Path" FontSize="14" Height="30" VerticalContentAlignment="Center" IsReadOnly="True"/>
          <Button x:Name="Browse" Grid.Column="1" Content="Browse..." Style="{StaticResource Steel}" Height="30" MinWidth="90" Margin="8,0,0,6"/></Grid></StackPanel>
      <StackPanel x:Name="SpeedRow" Margin="0,14,0,0" Visibility="Collapsed"><TextBlock Text="Speed" FontWeight="SemiBold" Foreground="#16275A" Margin="0,0,0,4"/><ComboBox x:Name="Speed" FontSize="14" Height="30"/></StackPanel>
      <StackPanel x:Name="ConfirmRow" Margin="0,14,0,0" Visibility="Collapsed">
        <TextBlock x:Name="ConfirmLabel" TextWrapping="Wrap" Foreground="#9A1B1B" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,4"/>
        <TextBox x:Name="Confirm" FontSize="16" Height="30" Width="90" HorizontalAlignment="Left" VerticalContentAlignment="Center"/></StackPanel>
      <TextBlock x:Name="Warn" TextWrapping="Wrap" Foreground="#9A1B1B" FontSize="13" Margin="0,12,0,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button x:Name="Cancel1" Content="Close" Style="{StaticResource Steel}"/><Button x:Name="Go" Style="{StaticResource Act}"/></StackPanel>
    </StackPanel>
    <StackPanel x:Name="Prog" Visibility="Collapsed">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="PHead" FontSize="24" FontWeight="SemiBold" Foreground="#16275A" VerticalAlignment="Center"/>
        <Grid x:Name="DoneBadge" Grid.Column="1" Visibility="Collapsed" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,0,10">
          <Border CornerRadius="14" Background="#B0000814" Margin="0,8,0,-8" IsHitTestVisible="False"/>
          <Border CornerRadius="14" BorderBrush="#99FFFFFF" BorderThickness="1.5,1.5,1.5,0" Padding="26,12">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5BEA8C" Offset="0"/><GradientStop Color="#16B04F" Offset="0.5"/><GradientStop Color="#0A7A33" Offset="1"/></LinearGradientBrush></Border.Background>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="30" Foreground="White" VerticalAlignment="Center" Margin="0,0,14,0"><TextBlock.Effect><DropShadowEffect Color="Black" Direction="270" ShadowDepth="2" BlurRadius="3" Opacity="0.6"/></TextBlock.Effect></TextBlock>
              <TextBlock Text="You are all done!" FontSize="30" FontWeight="ExtraBold" Foreground="White" VerticalAlignment="Center"><TextBlock.Effect><DropShadowEffect Color="#04301A" Direction="270" ShadowDepth="2.5" BlurRadius="3" Opacity="0.75"/></TextBlock.Effect></TextBlock>
            </StackPanel>
          </Border>
          <Border CornerRadius="14,14,0,0" VerticalAlignment="Top" Height="24" Margin="2,2,2,0" Background="#4CFFFFFF" IsHitTestVisible="False"/>
          <Border CornerRadius="0,0,14,14" VerticalAlignment="Bottom" Height="4" Margin="2,0,2,1" Background="#44000000" IsHitTestVisible="False"/>
        </Grid>
      </Grid>
      <ProgressBar x:Name="Bar" Height="22" Minimum="0" Maximum="100" Margin="0,18,0,8"/>
      <TextBlock x:Name="PText" FontSize="14" Foreground="#16275A"/>
      <TextBlock x:Name="PMsg" TextWrapping="Wrap" FontSize="14" FontWeight="SemiBold" Margin="0,10,0,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0"><Button x:Name="Stop" Content="Stop" Style="{StaticResource Steel}"/></StackPanel>
    </StackPanel>
  </Grid>
</Window>
'@
    Add-Styles $w
    $w.Owner = $main
    $w.Title = "DRDirect Clone & Backup - $title"
    Set-WinBrand $w
    $c = @{}
    foreach ($n in 'Form', 'Head', 'Sub', 'DiskRow', 'DiskLabel', 'Disk', 'Disk2Row', 'Disk2Label', 'Disk2', 'FileRow', 'FileLabel', 'Path', 'Browse', 'SpeedRow', 'Speed', 'ConfirmRow', 'ConfirmLabel', 'Confirm', 'Warn', 'Cancel1', 'Go', 'Prog', 'PHead', 'DoneBadge', 'Bar', 'PText', 'PMsg', 'Stop') { $c[$n] = $w.FindName($n) }

    $c.Head.Text = $title
    $c.PHead.Text = $title
    $c.Cancel1.Add_Click({ $w.Close() })
    $state = @{ Job = $null; Timer = $null; Clock = $null; Disks = @(); Last = '' }

    switch ($Mode) {
        'create' {
            $c.Sub.Text = 'Makes one compressed file holding the whole drive: every partition, Windows, and your files. The drive itself is only read.'
            $c.DiskLabel.Text = 'Drive to copy'
            $c.FileLabel.Text = 'Save the image as (on a different drive)'
            $c.Go.Content = 'Start'
            # Speed = how many CPU threads the image uses: the most threads is the fastest.
            $cores = [Environment]::ProcessorCount
            # MAX = every thread, plus the faster MAX engine (photos/videos stored as they are, image written past the cache), same as the PC Cleaner.
            $state.Speeds = @($cores, $cores, [Math]::Max(1, [int]($cores / 2)), [Math]::Max(1, [int]($cores / 4)), $cores)
            [void]$c.Speed.Items.Add('MAX  -  fastest (bigger file)')
            [void]$c.Speed.Items.Add(('{0}X  -  very fast (every CPU thread)' -f $state.Speeds[1]))
            [void]$c.Speed.Items.Add(('{0}X  -  fast' -f $state.Speeds[2]))
            [void]$c.Speed.Items.Add(('{0}X  -  gentle (the PC stays responsive)' -f $state.Speeds[3]))
            [void]$c.Speed.Items.Add('Smallest file  -  slower, uses every CPU thread')
            $c.Speed.SelectedIndex = 0
            $c.SpeedRow.Visibility = 'Visible'
        }
        'check' {
            $c.Sub.Text = 'Reads the whole image file and confirms nothing is damaged. Nothing is changed.'
            $c.DiskRow.Visibility = 'Collapsed'
            $c.FileLabel.Text = 'Image file'
            $c.Go.Content = 'Check'
        }
        'clone' {
            $c.Sub.Text = 'Copies one whole drive straight onto another: every partition, Windows, and your files. Only the used parts are copied, so it is faster. The source is only read. The target is erased.'
            $c.DiskLabel.Text = 'Copy FROM this drive (only read)'
            $c.Disk2Label.Text = 'Copy ONTO this drive (erased)'
            $c.Disk2Row.Visibility = 'Visible'
            $c.FileRow.Visibility = 'Collapsed'
            $c.Go.Content = 'Copy'
            $c.ConfirmRow.Visibility = 'Visible'
        }
        'restore' {
            $c.Sub.Text = 'Writes the image back onto a drive. Everything now on that drive is erased.'
            $c.DiskLabel.Text = 'Drive to overwrite'
            $c.FileLabel.Text = 'Image file'
            $c.Go.Content = 'Restore'
            $c.ConfirmRow.Visibility = 'Visible'
        }
    }

    if ($Mode -ne 'check') {
        $state.Disks = @(Get-ImagerDisks)
        foreach ($d in $state.Disks) {
            $tag = if ($d.IsWindows) { '   [Windows drive]' } else { '' }
            $ltr = if ($d.Letters) { "   ($($d.Letters))" } else { '' }
            if ($Mode -eq 'clone') { [void]$c.Disk2.Items.Add(("Drive {0}  -  {1}  -  {2}{3}{4}" -f $d.Number, $d.Name, (Format-ImgSize $d.Size), $ltr, $tag)) }
            [void]$c.Disk.Items.Add(("Drive {0}  -  {1}  -  {2}{3}{4}" -f $d.Number, $d.Name, (Format-ImgSize $d.Size), $ltr, $tag))
        }
        if ($Mode -eq 'restore') {
            $firstSafe = 0; for ($i = 0; $i -lt $state.Disks.Count; $i++) { if (-not $state.Disks[$i].IsWindows) { $firstSafe = $i; break } }
            $c.Disk.SelectedIndex = $firstSafe
            $c.ConfirmLabel.Text = ''
        }
        elseif ($state.Disks.Count) { $c.Disk.SelectedIndex = 0 }
        if ($Mode -eq 'clone') {
            $c.Disk.SelectedIndex = 0
            $safe = 0; for ($i = 0; $i -lt $state.Disks.Count; $i++) { if (-not $state.Disks[$i].IsWindows) { $safe = $i; break } }
            $c.Disk2.SelectedIndex = $safe
        }
    }

    $c.Browse.Add_Click({
        if ($Mode -eq 'create') {
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'DRDirect image (*.drimg)|*.drimg'; $dlg.DefaultExt = 'drimg'
            $dlg.FileName = (Get-Date -Format 'yyyyMMdd') + ' Image.drimg'
        }
        else {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = 'DRDirect image (*.drimg)|*.drimg'
        }
        if ($dlg.ShowDialog() -eq 'OK') { $c.Path.Text = $dlg.FileName }
    })

    $refresh = {
        $c.Warn.Text = ''
        $idx = $c.Disk.SelectedIndex
        $d = if ($Mode -ne 'check' -and $idx -ge 0) { $state.Disks[$idx] } else { $null }
        if ($Mode -eq 'restore' -and $d) {
            $c.ConfirmLabel.Text = "Type $($d.Number) to confirm that $(Get-DriveWords $d) will be erased:"
        }
        if ($Mode -eq 'clone') {
            $d2 = if ($c.Disk2.SelectedIndex -ge 0) { $state.Disks[$c.Disk2.SelectedIndex] } else { $null }
            $c.Go.IsEnabled = $false
            if ($d -and $d2) {
                $c.ConfirmLabel.Text = "Type $($d2.Number) to confirm that $(Get-DriveWords $d2) will be erased:"
                $why = Get-CloneBlockReason $d.Number $d2.Number
                if ($why) { $c.Warn.Text = $why }
                else {
                    if ($d.IsWindows) { $c.Warn.Text = 'Windows is running from the source drive, so it is copied while in use. For a perfect copy, use the rescue USB.' }
                    $c.Go.IsEnabled = ($c.Confirm.Text.Trim() -eq [string]$d2.Number)
                }
            }
            return
        }
        if ($Mode -eq 'create' -and $d -and $d.IsWindows) {
            $c.Warn.Text = 'Windows is running from this drive, so the copy is made while it is in use. For a perfect copy of the Windows drive, make it from the rescue USB.'
        }
        $c.Go.IsEnabled = $true
        if (-not $c.Path.Text) { $c.Go.IsEnabled = $false }
        if ($Mode -eq 'restore') {
            if (-not $d -or $c.Confirm.Text.Trim() -ne [string]$d.Number) { $c.Go.IsEnabled = $false }
            if ($d -and $c.Path.Text) { $why = Get-RestoreBlockReason $d.Number $c.Path.Text; if ($why) { $c.Warn.Text = $why; $c.Go.IsEnabled = $false } }
            elseif ($d -and $d.IsWindows) { $c.Warn.Text = 'Windows is running from this drive, so it cannot be overwritten from inside Windows. Restore it from the rescue USB instead.'; $c.Go.IsEnabled = $false }
        }
        if ($Mode -eq 'create' -and $d -and $c.Path.Text) {
            $why = Get-ImageBlockReason $d.Number $c.Path.Text
            if ($why) { $c.Warn.Text = $why; $c.Go.IsEnabled = $false }
        }
    }
    $c.Disk.Add_SelectionChanged($refresh)
    $c.Disk2.Add_SelectionChanged($refresh)
    $c.Confirm.Add_TextChanged($refresh)
    $c.Path.Add_TextChanged($refresh)
    & $refresh

    # shown while the drive is looked at, so the wait is explained
    $analyze = {
        $c.Form.Visibility = 'Collapsed'; $c.Prog.Visibility = 'Visible'
        $c.DoneBadge.Visibility = 'Collapsed'
        $c.PHead.Text = $title
        $c.PText.Text = 'Looking at the drive...'
        $c.PMsg.Text = ''; $c.PMsg.FontSize = 14; $c.PMsg.FontWeight = 'SemiBold'
        $c.Bar.IsIndeterminate = $true
        $c.Stop.IsEnabled = $false
        $w.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
    }
    $analyzed = {
        $c.Bar.IsIndeterminate = $false
        $c.Stop.IsEnabled = $true
        $c.Prog.Visibility = 'Collapsed'; $c.Form.Visibility = 'Visible'
    }

    $c.Go.Add_Click({
        $idx = $c.Disk.SelectedIndex
        $d = if ($Mode -ne 'check') { $state.Disks[$idx] } else { $null }
        $job = New-ImagerJob
        try {
            switch ($Mode) {
                'create' {
                    & $analyze
                    $ext = Get-SmartExtents $d.Number $d.Size
                    $workers = $state.Speeds[[Math]::Max(0, $c.Speed.SelectedIndex)]
                    $smallest = ($c.Speed.SelectedIndex -eq 4)
                    $maxMode = ($c.Speed.SelectedIndex -eq 0)
                    & $analyzed
                    $bytes = [double]$d.Size
                    if ($ext) { $bytes = 2MB; for ($i = 1; $i -lt $ext.Data.Count; $i += 2) { $bytes += $ext.Data[$i] } }
                    $ok = [System.Windows.MessageBox]::Show("Copy $(Get-DriveWords $d) into:`n$($c.Path.Text)`n`nOnly the used parts of the drive are read (about $(Format-ImgSize $bytes) of $(Format-ImgSize $d.Size)), so the empty space costs no time.$(if ($ext -and $ext.Whole.Count) { '`n`nCopied whole, because they cannot be mapped: ' + ($ext.Whole -join ', ') + '.' })`nThe image is locked to this PC (its PC ID), so it can only be opened and restored on this PC.`nThe drive is only read. Continue?", 'Secure', 'YesNo', 'Question')
                    if ($ok -ne 'Yes') { return }
                    Sync-DiskVolumes $d.Number
                    $job.Quick = (-not $smallest); $job.Fast = $false; $job.Workers = $workers
                    if ($maxMode -and ($job.PSObject.Properties.Name -contains 'Lighter')) { $job.Lighter = $true }
                    if ($ext) { $job.StartSmartImage($d.Path, $c.Path.Text, $d.Size, "$($d.Name)", $ext.Data, $ext.Tail) } else { $job.StartImage($d.Path, $c.Path.Text, $d.Size, "$($d.Name)") }
                }
                'check' { $job.StartVerify($c.Path.Text) }
                'clone' {
                    $d2 = $state.Disks[$c.Disk2.SelectedIndex]
                    & $analyze
                    $ext = Get-SmartExtents $d.Number $d.Size
                    $bytes = [double]$d.Size
                    if ($ext) { $bytes = 0; for ($i = 1; $i -lt $ext.Data.Count; $i += 2) { $bytes += $ext.Data[$i] }; $bytes += 2MB }
                    & $analyzed
                    $ok = [System.Windows.MessageBox]::Show("LAST CHANCE.`n`n$(Get-DriveWords $d2 -Cap) will be erased and replaced with a copy of $(Get-DriveWords $d).`n`nOnly the used parts are copied: about $(Format-ImgSize $bytes).`n`nThis cannot be undone. Continue?", 'SmartCopy', 'YesNo', 'Warning')
                    if ($ok -ne 'Yes') { return }
                    $state.Target = $d2.Number
                    Sync-DiskVolumes $d.Number
                    Initialize-RestoreTarget $d2.Number
                    if ($ext) { $job.StartSmartClone($d.Path, $d2.Path, $d.Size, $ext.Data, $ext.Tail) } else { $job.StartClone($d.Path, $d2.Path, $d.Size) }
                }
                'restore' {
                    $ok = [System.Windows.MessageBox]::Show("LAST CHANCE.`n`n$(Get-DriveWords $d -Cap) will be erased and overwritten with:`n$($c.Path.Text)`n`nThis cannot be undone. Continue?", 'Restore Image', 'YesNo', 'Warning')
                    if ($ok -ne 'Yes') { return }
                    $state.Target = $d.Number
                    Initialize-RestoreTarget $d.Number
                    $job.StartRestore($c.Path.Text, $d.Path)
                }
            }
        }
        catch { [System.Windows.MessageBox]::Show($_.Exception.Message, $title, 'OK', 'Error') | Out-Null; return }

        $state.Job = $job
        $state.Clock = [Diagnostics.Stopwatch]::StartNew()
        $c.Form.Visibility = 'Collapsed'; $c.Prog.Visibility = 'Visible'
        $c.DoneBadge.Visibility = 'Collapsed'
        $t = New-Object Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(300)
        $t.Add_Tick({
            $j = $state.Job
            $total = [double][Math]::Max($j.Total, 1)
            $done = [double]$j.Done
            $sec = [Math]::Max($state.Clock.Elapsed.TotalSeconds, 0.5)
            # Restore and check: the bar and the speed follow the saved data actually being read and written. Empty space in the
            # image is skipped at once, so counting it would show a speed (and a percentage) the drive never reaches.
            $real = ($j.FileTotal -gt 0)
            $pct = if ($real) { [Math]::Min(100, 100 * [double]$j.FileDone / [double]$j.FileTotal) } else { [Math]::Min(100, 100 * $done / $total) }
            $c.Bar.Value = $pct
            $rate = if ($real) { [double]$j.FileDone / $sec } else { $done / $sec }
            # Only real, measured time: how long it has been running. No countdown guesses.
            $ran = $state.Clock.Elapsed.ToString('hh\:mm\:ss')
            $c.PText.Text = if ($real) { ('{0:N1}%   {1} of {2} saved data   {3}/s   {4}' -f $pct, (Format-ImgSize $j.FileDone), (Format-ImgSize $j.FileTotal), (Format-ImgSize $rate), "running for $ran") } else { ('{0:N1}%   {1} of {2}   {3}/s   {4}' -f $pct, (Format-ImgSize $done), (Format-ImgSize $total), (Format-ImgSize $rate), "running for $ran") }
            if ($j.Finished) {
                $state.Clock.Stop()
                $state.Timer.Stop()
                $c.Stop.Content = 'Close'
                $c.Stop.Tag = 'done'
                if ($j.Ok -and $Mode -eq 'create') { Write-ImagerTiming $j $state.Clock.Elapsed.TotalSeconds $c.Path.Text }
                if ($j.Ok) {
                    $c.Bar.Value = 100
                    $c.PMsg.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#0B9A3E')); $c.PMsg.FontSize = 20; $c.PMsg.FontWeight = 'Bold'
                    $c.PMsg.Text = $(switch ($Mode) { 'create' { "Image saved:`n$($c.Path.Text)" } 'check' { 'The image is complete and undamaged.' } 'restore' { 'The drive has been restored.' } 'clone' { 'The drive has been copied.' } }) + "`nTime taken: $(Format-TookTime $state.Clock.Elapsed.TotalSeconds)"
                    $c.DoneBadge.Visibility = 'Visible'
                    if ($Mode -eq 'restore' -or $Mode -eq 'clone') { Complete-RestoreTarget $state.Target }
                }
                else {
                    $c.PMsg.Foreground = [Windows.Media.Brushes]::DarkRed; $c.PMsg.FontSize = 14
                    $c.PMsg.Text = "Stopped: $($j.Error)`nIt ran for $(Format-TookTime $state.Clock.Elapsed.TotalSeconds) before it stopped."
                    if ($Mode -eq 'restore' -or $Mode -eq 'clone') { $c.PMsg.Text += "`nThe target drive was only partly written. Run it again before using that drive." }
                }
            }
        })
        $state.Timer = $t
        $t.Start()
    })

    $c.Stop.Add_Click({
        if ($c.Stop.Tag -eq 'done') { $w.Close(); return }
        $msg = if ($Mode -eq 'restore' -or $Mode -eq 'clone') { 'Stop now? The drive will be left only partly written.' } else { 'Stop now?' }
        if ([System.Windows.MessageBox]::Show($msg, $title, 'YesNo', 'Question') -eq 'Yes') { $state.Job.Cancel = $true }
    })

    $w.Add_Closing({
        param($s, $e)
        if ($state.Job -and -not $state.Job.Finished) { $e.Cancel = $true }
    })
    [void]$w.ShowDialog()
}

$main.FindName('BtnClone').Add_Click({ Show-JobDialog 'clone' })
$main.FindName('NavClone').Add_Click({ Show-JobDialog 'clone' })
$main.FindName('BtnCreate').Add_Click({ Show-JobDialog 'create' })
$main.FindName('NavCreate').Add_Click({ Show-JobDialog 'create' })
$main.FindName('BtnRestore').Add_Click({ Show-JobDialog 'restore' })
$main.FindName('NavRestore').Add_Click({ Show-JobDialog 'restore' })
$main.FindName('NavUsb').Add_Click({ Show-RescueUsb })

# ---------- Check for updates ----------
$script:ImagerVersion = '1.0.0'
# "All Activated" shows only when this copy is activated: a stick that passed its PC lock to open, or a PC whose DRDirect PC Cleaner is activated.
function Test-ImagerActivated {
    param([string]$Root = $PSScriptRoot, [string]$CleanerDir = (Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner'))
    if ((Test-Path -LiteralPath (Join-Path $Root 'pc.id')) -or (Test-Path -LiteralPath (Join-Path $Root 'owner.id'))) { return $true }
    $state = Join-Path $CleanerDir 'licence.dat'
    $installed = Join-Path $CleanerDir 'Scripts\installed.json'
    if (-not (Test-Path -LiteralPath $state) -and -not (Test-Path -LiteralPath $installed)) { return $false }
    if (Test-Path -LiteralPath $state) {
        try {
            $j = Get-Content -LiteralPath $state -Raw -ErrorAction Stop | ConvertFrom-Json
            $names = @($j.PSObject.Properties.Name)
            if ($names -contains 'trial' -and $j.trial) { return $false }
            if ($names -contains 'needs_activation' -and [bool]$j.needs_activation) { return $false }
        } catch { return $false }
    }
    $true
}
$main.FindName('ActivatedBadge').Visibility = $(if (Test-ImagerActivated) { 'Visible' } else { 'Collapsed' })
$main.FindName('VersionText').Text = "Version $($script:ImagerVersion)"
function Get-ImagerUpdateStatus {
    # Reads the update feed's manifest and compares. It never installs anything.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $json = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Phears/drdirect-cleaner-updates/main/update_manifest.json' -UseBasicParsing -TimeoutSec 15
        $latest = $null
        if ($json.PSObject.Properties.Name -contains 'imager' -and $json.imager.version) { $latest = [string]$json.imager.version }
        if (-not $latest) { return [pscustomobject]@{ State = 'None'; Latest = $null } }
        if ([version]$latest -gt [version]$script:ImagerVersion) { return [pscustomobject]@{ State = 'New'; Latest = $latest } }
        return [pscustomobject]@{ State = 'Current'; Latest = $latest }
    } catch { return [pscustomobject]@{ State = 'Offline'; Latest = $null } }
}
function Invoke-ImagerUpdateCheck {
    $r = Get-ImagerUpdateStatus
    $msg = switch ($r.State) {
        'New'     { "A new version ($($r.Latest)) is available.`n`nYou have $($script:ImagerVersion). Installing it from here is not switched on yet, so ask DRDirect for the new copy." }
        'Current' { "You are up to date.`n`nVersion $($script:ImagerVersion)." }
        'None'    { "You are up to date.`n`nVersion $($script:ImagerVersion). No newer version has been published." }
        default   { "Could not reach the update server.`n`nCheck your internet connection and try again." }
    }
    $icon = if ($r.State -eq 'Offline') { 'Warning' } else { 'Information' }
    [System.Windows.MessageBox]::Show($msg, 'Check for updates', 'OK', $icon) | Out-Null
}
$main.FindName('NavUpdate').Add_Click({ Invoke-ImagerUpdateCheck })

$main.FindName('BtnUsb').Add_Click({ Show-RescueUsb })

if ($Master) { $main.Add_ContentRendered({ $main.Dispatcher.BeginInvoke([Action]{ Show-RescueUsb -Master }) | Out-Null }) }
[void]$main.ShowDialog()
