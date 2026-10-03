[CmdletBinding()]
param(
    [switch]$TestMode,
    [string]$TestRoot,
    [switch]$NoShow
)

# This script is published in the public update feed, so a downloaded copy would
# otherwise open as the full Cleaner with no licence check at all. Only start
# when DRDirect opened it: the compiled exe, the launcher (which hands over the
# PC IDs it checked), test mode, or the project folder the licence secret lives in.
$drStartedByDRDirect = [bool]$TestMode
if (-not $drStartedByDRDirect) {
    $drHostName = ''
    try { $drHostName = [Diagnostics.Process]::GetCurrentProcess().ProcessName } catch { }
    $drStartedByDRDirect = @('powershell', 'pwsh', 'powershell_ise') -notcontains $drHostName.ToLowerInvariant()
}
if (-not $drStartedByDRDirect) {
    $drStartedByDRDirect = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('DRDIRECT_ALLOWED_PC_IDS'))
}
if (-not $drStartedByDRDirect -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $drStartedByDRDirect = Test-Path -LiteralPath (Join-Path $PSScriptRoot 'licence_secret_cleaner.txt') -PathType Leaf
}
# The update folder the launcher runs updates from. A customer's copy must never
# be locked out of its own update, even if the launcher's hand-off went missing.
if (-not $drStartedByDRDirect -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot) -and
        -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $drUpdateFolder = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Scripts'
    $drStartedByDRDirect = [string]::Equals(
        [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\'),
        [IO.Path]::GetFullPath($drUpdateFolder).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase)
}
if (-not $drStartedByDRDirect) {
    $drRefusal = "This file is part of DRDirect PC Cleaner and cannot be opened on its own." + [Environment]::NewLine + [Environment]::NewLine +
        "Open DRDirect PC Cleaner from its shortcut instead. Don't have it? Contact DRDirect."
    if ($NoShow) {
        Write-Error $drRefusal
    } else {
        try {
            Add-Type -AssemblyName PresentationFramework
            [Windows.MessageBox]::Show($drRefusal, 'DRDirect PC Cleaner', 'OK', 'Information') | Out-Null
        } catch { Write-Error $drRefusal }
    }
    exit 2
}

# Opened without administrator rights (for example from a script launcher)? Ask
# Windows for them once, so every check and clean-up can do its job - without
# them, drive health, memory and many cleaners cannot read or change anything.
# Test mode asks too, so what you see is what a customer sees. Only the silent
# smoke test never asks, and saying No carries on as a standard user.
if (-not $NoShow -and $PSCommandPath) {
    $drIsAdmin = $false
    try { $drIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
    if (-not $drIsAdmin) {
        try {
            $drArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
            if ($TestMode) { $drArgs += '-TestMode' }
            if ($TestRoot) { $drArgs += @('-TestRoot', ('"{0}"' -f $TestRoot)) }
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $drArgs | Out-Null
            exit 0
        } catch { }
    }
}

function Resolve-DREnginePath {
    $runtimeRoots = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $runtimeRoots.Add($PSScriptRoot)
    }
    try {
        $executablePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($executablePath)) {
            $runtimeRoots.Add((Split-Path -Parent $executablePath))
        }
    } catch { }
    try {
        if (-not [string]::IsNullOrWhiteSpace([AppDomain]::CurrentDomain.BaseDirectory)) {
            $runtimeRoots.Add([AppDomain]::CurrentDomain.BaseDirectory)
        }
    } catch { }
    try {
        $invocationPath = $MyInvocation.PSCommandPath
        if (-not [string]::IsNullOrWhiteSpace($invocationPath)) {
            $runtimeRoots.Add((Split-Path -Parent $invocationPath))
        }
    } catch { }

    foreach ($root in @($runtimeRoots | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $candidate = Join-Path -Path $root -ChildPath 'DRDirect Cleaner Engine.ps1'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'The embedded maintenance engine could not be located beside the application.'
}

$script:DREnginePath = Resolve-DREnginePath
# <ENGINE-IMPORT>
. $script:DREnginePath
# </ENGINE-IMPORT>

# The updater is spliced in at build time, exactly like the engine above, so
# the compiled exe carries it without needing a loose file beside it.
# <UPDATER-IMPORT>
. (Join-Path $PSScriptRoot 'DRDirect Updater.ps1')
# </UPDATER-IMPORT>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$ErrorActionPreference = 'Stop'

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DRDirect PC Cleaner" Width="1020" Height="660" MinWidth="860" MinHeight="560"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Ideal"
        WindowStyle="None" ResizeMode="CanResize" BorderBrush="#D7DFEA" BorderThickness="1">
    <Window.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#F7F9FD" Offset="0"/>
            <GradientStop Color="#E4EBF5" Offset="1"/>
        </LinearGradientBrush>
    </Window.Background>
    <Window.Resources>
        <SolidColorBrush x:Key="Navy" Color="#15253D"/>
        <SolidColorBrush x:Key="Blue" Color="#2563EB"/>
        <SolidColorBrush x:Key="BlueSoft" Color="#E8F0FF"/>
        <SolidColorBrush x:Key="Ink" Color="#172033"/>
        <SolidColorBrush x:Key="Muted" Color="#667085"/>
        <SolidColorBrush x:Key="Line" Color="#E3E8F0"/>
        <SolidColorBrush x:Key="Success" Color="#16835B"/>
        <SolidColorBrush x:Key="Warning" Color="#A86412"/>
        <SolidColorBrush x:Key="Danger" Color="#C63C3C"/>
        <SolidColorBrush x:Key="DangerSoft" Color="#FDECEC"/>
        <SolidColorBrush x:Key="Hover" Color="#F2F6FC"/>
        <SolidColorBrush x:Key="Subtle" Color="#8A94A6"/>
        <SolidColorBrush x:Key="Violet" Color="#7C3AED"/>
        <SolidColorBrush x:Key="VioletSoft" Color="#F1EAFE"/>
        <SolidColorBrush x:Key="Amber" Color="#D97706"/>
        <SolidColorBrush x:Key="AmberSoft" Color="#FEF3E2"/>
        <SolidColorBrush x:Key="Teal" Color="#0D9488"/>
        <SolidColorBrush x:Key="TealSoft" Color="#E0F5F3"/>
        <SolidColorBrush x:Key="SuccessSoft" Color="#E7F6EF"/>
        <LinearGradientBrush x:Key="HeroBrush" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#2B5FE3" Offset="0"/>
            <GradientStop Color="#1E40AF" Offset="0.55"/>
            <GradientStop Color="#3D2C8D" Offset="1"/>
        </LinearGradientBrush>
        <Style x:Key="StatIcon" TargetType="Border">
            <Setter Property="Width" Value="38"/><Setter Property="Height" Value="38"/>
            <Setter Property="CornerRadius" Value="11"/><Setter Property="Margin" Value="0,0,12,0"/>
        </Style>

        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Ink}"/></Style>
        <Style x:Key="MutedText" TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Muted}"/></Style>
        <Style x:Key="TitleText" TargetType="TextBlock"><Setter Property="FontSize" Value="30"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,2,0,0"/></Style>
        <Style x:Key="SectionText" TargetType="TextBlock"><Setter Property="FontSize" Value="20"/><Setter Property="FontWeight" Value="SemiBold"/></Style>

        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/><Setter Property="Background" Value="{StaticResource Blue}"/>
            <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="20,11"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Template">
                <Setter.Value><ControlTemplate TargetType="Button">
                    <Border x:Name="PrimaryBorder" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True" RenderTransformOrigin="0.5,0.5">
                        <Border.RenderTransform>
                            <TransformGroup>
                                <ScaleTransform ScaleX="1" ScaleY="1"/>
                                <TranslateTransform X="0" Y="0"/>
                            </TransformGroup>
                        </Border.RenderTransform>
                        <Border.Effect>
                            <DropShadowEffect Color="#1B3F9E" BlurRadius="18" ShadowDepth="4" Direction="270" Opacity="0"/>
                        </Border.Effect>
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="PrimaryBorder" Property="Background" Value="#1D4FD8"/>
                            <Trigger.EnterActions>
                                <BeginStoryboard>
                                    <Storyboard>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" To="1.04" Duration="0:0:0.18">
                                            <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                        </DoubleAnimation>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" To="1.04" Duration="0:0:0.18">
                                            <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                        </DoubleAnimation>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.Y)" To="-2" Duration="0:0:0.18">
                                            <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                        </DoubleAnimation>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)" To="0.42" Duration="0:0:0.18"/>
                                    </Storyboard>
                                </BeginStoryboard>
                            </Trigger.EnterActions>
                            <Trigger.ExitActions>
                                <BeginStoryboard>
                                    <Storyboard>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.22">
                                            <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                        </DoubleAnimation>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.22">
                                            <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                        </DoubleAnimation>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.Y)" To="0" Duration="0:0:0.22">
                                            <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                        </DoubleAnimation>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)" To="0" Duration="0:0:0.22"/>
                                    </Storyboard>
                                </BeginStoryboard>
                            </Trigger.ExitActions>
                        </Trigger>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="PrimaryBorder" Property="Background" Value="#1A44BC"/>
                            <Trigger.EnterActions>
                                <BeginStoryboard>
                                    <Storyboard>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" To="0.97" Duration="0:0:0.08"/>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" To="0.97" Duration="0:0:0.08"/>
                                        <DoubleAnimation Storyboard.TargetName="PrimaryBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.Y)" To="0" Duration="0:0:0.08"/>
                                    </Storyboard>
                                </BeginStoryboard>
                            </Trigger.EnterActions>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.42"/></Trigger>
                    </ControlTemplate.Triggers></ControlTemplate></Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
            <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Background" Value="White"/><Setter Property="BorderThickness" Value="1"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="SecondaryBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="SecondaryBorder" Property="Background" Value="{StaticResource Hover}"/><Setter TargetName="SecondaryBorder" Property="BorderBrush" Value="#C9D5E6"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="SecondaryBorder" Property="Background" Value="#E7EEF8"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.42"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource SecondaryButton}">
            <Setter Property="Foreground" Value="{StaticResource Danger}"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="DangerBorder" Background="{TemplateBinding Background}" BorderBrush="#EFCFCF" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="DangerBorder" Property="Background" Value="{StaticResource DangerSoft}"/><Setter TargetName="DangerBorder" Property="BorderBrush" Value="#E2AFAF"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="DangerBorder" Property="Background" Value="#FADEDE"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.42"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <Style x:Key="HeroButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
            <Setter Property="Foreground" Value="#1E3A8A"/><Setter Property="Background" Value="White"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="HeroBorder" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="HeroBorder" Property="Background" Value="#EAF0FF"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="HeroBorder" Property="Background" Value="#D9E4FF"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <Style x:Key="HeroGhostButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
            <Setter Property="Foreground" Value="White"/><Setter Property="Background" Value="#33FFFFFF"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="GhostBorder" Background="{TemplateBinding Background}" BorderBrush="#66FFFFFF" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="GhostBorder" Property="Background" Value="#4DFFFFFF"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="GhostBorder" Property="Background" Value="#66FFFFFF"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <Style x:Key="NavButton" TargetType="Button">
            <Setter Property="Foreground" Value="#BDCAE0"/><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="Padding" Value="18,12"/><Setter Property="Margin" Value="10,2"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                <Grid x:Name="NavRoot" RenderTransformOrigin="0,0.5">
                    <Grid.RenderTransform><TranslateTransform X="0" Y="0"/></Grid.RenderTransform>
                    <Border x:Name="NavBorder" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter/></Border>
                    <Border x:Name="NavAccent" Width="3" Height="22" CornerRadius="2" Background="#5B93FF" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0" Opacity="0" RenderTransformOrigin="0.5,0.5">
                        <Border.RenderTransform><ScaleTransform ScaleX="1" ScaleY="0.3"/></Border.RenderTransform>
                    </Border>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="Tag" Value="Active">
                        <Setter TargetName="NavBorder" Property="Background" Value="#2A4364"/>
                        <Setter Property="Foreground" Value="White"/>
                        <Setter Property="FontWeight" Value="SemiBold"/>
                        <Trigger.EnterActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="NavAccent" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.22"/>
                                    <DoubleAnimation Storyboard.TargetName="NavAccent" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.28">
                                        <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.5"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.EnterActions>
                        <Trigger.ExitActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="NavAccent" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.15"/>
                                    <DoubleAnimation Storyboard.TargetName="NavAccent" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.3" Duration="0:0:0.15"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.ExitActions>
                    </Trigger>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="NavBorder" Property="Background" Value="#274069"/>
                        <Setter Property="Foreground" Value="White"/>
                        <Trigger.EnterActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="NavRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="6" Duration="0:0:0.18">
                                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.EnterActions>
                        <Trigger.ExitActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="NavRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.24">
                                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.ExitActions>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Trigger.EnterActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="NavRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="3" Duration="0:0:0.08"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.EnterActions>
                    </Trigger>
                </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <!-- AI Remover gets its own violet, so it never reads as just another cleanup page. -->
        <Style x:Key="AINavButton" TargetType="Button" BasedOn="{StaticResource NavButton}">
            <Setter Property="Foreground" Value="#E9D5FF"/><Setter Property="Background" Value="#2E1D5C"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                <Grid x:Name="NavRoot" RenderTransformOrigin="0,0.5">
                    <Grid.RenderTransform><TranslateTransform X="0" Y="0"/></Grid.RenderTransform>
                    <Border x:Name="NavBorder" Background="{TemplateBinding Background}" BorderBrush="#8B5CF6" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter/></Border>
                    <Border x:Name="NavAccent" Width="3" Height="22" CornerRadius="2" Background="#C084FC" HorizontalAlignment="Left" VerticalAlignment="Center" Opacity="0"/>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="Tag" Value="Active">
                        <Setter TargetName="NavBorder" Property="Background" Value="#5B21B6"/>
                        <Setter TargetName="NavAccent" Property="Opacity" Value="1"/>
                        <Setter Property="Foreground" Value="White"/>
                    </Trigger>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="NavBorder" Property="Background" Value="#43287F"/>
                        <Setter Property="Foreground" Value="White"/>
                        <Trigger.EnterActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="NavRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="6" Duration="0:0:0.18">
                                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.EnterActions>
                        <Trigger.ExitActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="NavRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.24">
                                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.ExitActions>
                    </Trigger>
                </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <!-- The winget update button gets its own very bright electric blue, in the same style as AI Remover's violet. -->
        <Style x:Key="WingetNavButton" TargetType="Button" BasedOn="{StaticResource NavButton}">
            <Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="Background" Value="#0061FF"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                <Grid x:Name="NavRoot" RenderTransformOrigin="0,0.5">
                    <Grid.RenderTransform><TranslateTransform X="0" Y="0"/></Grid.RenderTransform>
                    <Border x:Name="NavBorder" Background="{TemplateBinding Background}" BorderBrush="#00E5FF" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter/></Border>
                    <Border x:Name="NavAccent" Width="3" Height="22" CornerRadius="2" Background="#FFFFFF" HorizontalAlignment="Left" VerticalAlignment="Center" Opacity="0"/>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="Tag" Value="Active">
                        <Setter TargetName="NavBorder" Property="Background" Value="#2D8CFF"/>
                        <Setter TargetName="NavAccent" Property="Opacity" Value="1"/>
                        <Setter Property="Foreground" Value="White"/>
                    </Trigger>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="NavBorder" Property="Background" Value="#1F7AFF"/>
                        <Setter Property="Foreground" Value="White"/>
                        <Trigger.EnterActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="NavRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="6" Duration="0:0:0.18">
                                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.EnterActions>
                        <Trigger.ExitActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="NavRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.24">
                                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.ExitActions>
                    </Trigger>
                </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <!-- The choices on each AI Remover row: rose for "off", green for "back on", violet for
             "only looks". Coloured before they are picked; picked ones fill in, pop and glow. -->
        <Style x:Key="AIChoice" TargetType="ToggleButton">
            <Setter Property="Foreground" Value="#475467"/><Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="#D0D5DD"/>
            <Setter Property="FontSize" Value="12.5"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="Padding" Value="12,7"/>
            <Setter Property="Margin" Value="0,4"/><Setter Property="MinWidth" Value="124"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton">
                <Border x:Name="ChoiceBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1.5" CornerRadius="10" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True" RenderTransformOrigin="0.5,0.5">
                    <Border.RenderTransform>
                        <TransformGroup>
                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                            <TranslateTransform X="0" Y="0"/>
                        </TransformGroup>
                    </Border.RenderTransform>
                    <Border.Effect>
                        <DropShadowEffect Color="#E11D48" BlurRadius="18" ShadowDepth="0" Opacity="0"/>
                    </Border.Effect>
                    <ContentPresenter x:Name="ChoiceText" TextElement.Foreground="{TemplateBinding Foreground}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Trigger.EnterActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" To="1.06" Duration="0:0:0.16">
                                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" To="1.06" Duration="0:0:0.16">
                                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.Y)" To="-2" Duration="0:0:0.16"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.EnterActions>
                        <Trigger.ExitActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.2"/>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.2"/>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.Y)" To="0" Duration="0:0:0.2"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.ExitActions>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Trigger.EnterActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" To="0.94" Duration="0:0:0.07"/>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" To="0.94" Duration="0:0:0.07"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </Trigger.EnterActions>
                    </Trigger>
                    <MultiTrigger>
                        <MultiTrigger.Conditions><Condition Property="IsChecked" Value="True"/><Condition Property="Tag" Value="Off"/></MultiTrigger.Conditions>
                        <Setter TargetName="ChoiceBorder" Property="Background">
                            <Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FB7185" Offset="0"/><GradientStop Color="#E11D48" Offset="1"/></LinearGradientBrush></Setter.Value>
                        </Setter>
                        <Setter TargetName="ChoiceBorder" Property="BorderBrush" Value="#E11D48"/>
                        <Setter TargetName="ChoiceText" Property="TextElement.Foreground" Value="White"/>
                        <MultiTrigger.EnterActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <ColorAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Color)" To="#E11D48" Duration="0:0:0"/>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" From="0.86" To="1" Duration="0:0:0.35">
                                        <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.6"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" From="0.86" To="1" Duration="0:0:0.35">
                                        <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.6"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)" From="0.3" To="0.85" Duration="0:0:1.1" AutoReverse="True" RepeatBehavior="Forever"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </MultiTrigger.EnterActions>
                        <MultiTrigger.ExitActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)" To="0" Duration="0:0:0.2"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </MultiTrigger.ExitActions>
                    </MultiTrigger>
                    <MultiTrigger>
                        <MultiTrigger.Conditions><Condition Property="IsChecked" Value="True"/><Condition Property="Tag" Value="On"/></MultiTrigger.Conditions>
                        <Setter TargetName="ChoiceBorder" Property="Background">
                            <Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#4ADE80" Offset="0"/><GradientStop Color="#16A34A" Offset="1"/></LinearGradientBrush></Setter.Value>
                        </Setter>
                        <Setter TargetName="ChoiceBorder" Property="BorderBrush" Value="#16A34A"/>
                        <Setter TargetName="ChoiceText" Property="TextElement.Foreground" Value="White"/>
                        <MultiTrigger.EnterActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <ColorAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Color)" To="#16A34A" Duration="0:0:0"/>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" From="0.86" To="1" Duration="0:0:0.35">
                                        <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.6"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" From="0.86" To="1" Duration="0:0:0.35">
                                        <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.6"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)" From="0.3" To="0.85" Duration="0:0:1.1" AutoReverse="True" RepeatBehavior="Forever"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </MultiTrigger.EnterActions>
                        <MultiTrigger.ExitActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)" To="0" Duration="0:0:0.2"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </MultiTrigger.ExitActions>
                    </MultiTrigger>
                    <MultiTrigger>
                        <MultiTrigger.Conditions><Condition Property="IsChecked" Value="True"/><Condition Property="Tag" Value="Look"/></MultiTrigger.Conditions>
                        <Setter TargetName="ChoiceBorder" Property="Background">
                            <Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#A78BFA" Offset="0"/><GradientStop Color="#7C3AED" Offset="1"/></LinearGradientBrush></Setter.Value>
                        </Setter>
                        <Setter TargetName="ChoiceBorder" Property="BorderBrush" Value="#7C3AED"/>
                        <Setter TargetName="ChoiceText" Property="TextElement.Foreground" Value="White"/>
                        <MultiTrigger.EnterActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <ColorAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Color)" To="#7C3AED" Duration="0:0:0"/>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" From="0.86" To="1" Duration="0:0:0.35">
                                        <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.6"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" From="0.86" To="1" Duration="0:0:0.35">
                                        <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.6"/></DoubleAnimation.EasingFunction>
                                    </DoubleAnimation>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)" From="0.3" To="0.85" Duration="0:0:1.1" AutoReverse="True" RepeatBehavior="Forever"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </MultiTrigger.EnterActions>
                        <MultiTrigger.ExitActions>
                            <BeginStoryboard>
                                <Storyboard>
                                    <DoubleAnimation Storyboard.TargetName="ChoiceBorder" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)" To="0" Duration="0:0:0.2"/>
                                </Storyboard>
                            </BeginStoryboard>
                        </MultiTrigger.ExitActions>
                    </MultiTrigger>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate></Setter.Value></Setter>
            <Style.Triggers>
                <Trigger Property="Tag" Value="Off"><Setter Property="Background" Value="#FFF1F2"/><Setter Property="BorderBrush" Value="#FDA4AF"/><Setter Property="Foreground" Value="#BE123C"/></Trigger>
                <Trigger Property="Tag" Value="On"><Setter Property="Background" Value="#ECFDF3"/><Setter Property="BorderBrush" Value="#86EFAC"/><Setter Property="Foreground" Value="#15803D"/></Trigger>
                <Trigger Property="Tag" Value="Look"><Setter Property="Background" Value="#F5F3FF"/><Setter Property="BorderBrush" Value="#C4B5FD"/><Setter Property="Foreground" Value="#6D28D9"/></Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="White"/><Setter Property="CornerRadius" Value="14"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="22"/><Setter Property="SnapsToDevicePixels" Value="True"/>
            <Setter Property="Effect"><Setter.Value><DropShadowEffect Color="#6B82A6" BlurRadius="26" ShadowDepth="5" Direction="270" Opacity="0.22"/></Setter.Value></Setter>
        </Style>
        <Style x:Key="HistoryRow" TargetType="Border"><Setter Property="Background" Value="Transparent"/><Setter Property="CornerRadius" Value="10"/><Setter Property="Padding" Value="14,12"/><Setter Property="BorderThickness" Value="1"/><Setter Property="BorderBrush" Value="Transparent"/><Setter Property="Margin" Value="0,0,0,4"/><Setter Property="SnapsToDevicePixels" Value="True"/>
            <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F6F9FD"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/></Trigger></Style.Triggers>
        </Style>
        <Style x:Key="TaskCheck" TargetType="CheckBox"><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="0,0,14,0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="LayoutTransform"><Setter.Value><ScaleTransform ScaleX="1.2" ScaleY="1.2"/></Setter.Value></Setter></Style>
        <Style x:Key="PresetChoiceButton" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource Ink}"/>
            <Setter Property="Background" Value="White"/>
            <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,12"/>
            <Setter Property="Margin" Value="0,0,10,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ChoiceBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="10"
                                Padding="{TemplateBinding Padding}"
                                RenderTransformOrigin="0.5,0.5">
                            <Border.RenderTransform>
                                <TransformGroup>
                                    <ScaleTransform ScaleX="1" ScaleY="1"/>
                                    <TranslateTransform X="0" Y="0"/>
                                </TransformGroup>
                            </Border.RenderTransform>
                            <Border.Effect>
                                <DropShadowEffect Color="#1F3A6E" BlurRadius="20" ShadowDepth="4" Direction="270" Opacity="0"/>
                            </Border.Effect>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Tag" Value="Active">
                                <Setter TargetName="ChoiceBorder" Property="Background" Value="#F8FAFC"/>
                                <Setter TargetName="ChoiceBorder" Property="BorderThickness" Value="3"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="ChoiceBorder"
                                                             Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)"
                                                             To="1.05" Duration="0:0:0.18">
                                                <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                            <DoubleAnimation Storyboard.TargetName="ChoiceBorder"
                                                             Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)"
                                                             To="1.05" Duration="0:0:0.18">
                                                <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                            <DoubleAnimation Storyboard.TargetName="ChoiceBorder"
                                                             Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.Y)"
                                                             To="-3" Duration="0:0:0.18">
                                                <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                            <DoubleAnimation Storyboard.TargetName="ChoiceBorder"
                                                             Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)"
                                                             To="0.32" Duration="0:0:0.18"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="ChoiceBorder"
                                                             Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)"
                                                             To="1" Duration="0:0:0.22">
                                                <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                            <DoubleAnimation Storyboard.TargetName="ChoiceBorder"
                                                             Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)"
                                                             To="1" Duration="0:0:0.22">
                                                <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                            <DoubleAnimation Storyboard.TargetName="ChoiceBorder"
                                                             Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.Y)"
                                                             To="0" Duration="0:0:0.22">
                                                <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                            <DoubleAnimation Storyboard.TargetName="ChoiceBorder"
                                                             Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)"
                                                             To="0" Duration="0:0:0.22"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="ChoiceBorder"
                                                             Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)"
                                                             To="0.98" Duration="0:0:0.08"/>
                                            <DoubleAnimation Storyboard.TargetName="ChoiceBorder"
                                                             Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)"
                                                             To="0.98" Duration="0:0:0.08"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="TitleBarButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Width" Value="46"/>
            <Setter Property="Height" Value="36"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="TitleButtonBorder" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="TitleButtonBorder" Property="Background" Value="#33FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="TitleButtonBorder" Property="Background" Value="#4DFFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions><RowDefinition Height="40"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Border Grid.Row="0" BorderBrush="#1B3E86" BorderThickness="0,0,0,1">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#1E40AF" Offset="0"/><GradientStop Color="#2B5FE3" Offset="1"/></LinearGradientBrush></Border.Background>
            <Grid x:Name="CustomTitleBar">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <Grid x:Name="TitleDragArea" Grid.Column="0" Background="Transparent">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Width="26" Height="26" CornerRadius="7" Background="White" Margin="12,7,10,7">
                        <TextBlock Text="✓" Foreground="#1E40AF" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Grid.Column="1" Text="DRDirect PC Cleaner" Foreground="White" FontSize="19" FontWeight="Bold" VerticalAlignment="Center"/>
                </Grid>
                <Button x:Name="TitleMinButton" Grid.Column="1" Style="{StaticResource TitleBarButton}" Content="—"/>
                <Button x:Name="TitleMaxButton" Grid.Column="2" Style="{StaticResource TitleBarButton}" Content="□"/>
                <Button x:Name="TitleCloseButton" Grid.Column="3" Style="{StaticResource TitleBarButton}" Content="✕"/>
            </Grid>
        </Border>
        <Grid Grid.Row="1">
        <Grid.ColumnDefinitions><ColumnDefinition Width="256"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Grid.Column="0">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#1A2E4C" Offset="0"/><GradientStop Color="#12203A" Offset="1"/></LinearGradientBrush></Border.Background>
            <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <StackPanel Margin="24,24,20,24">
                    <StackPanel Orientation="Horizontal">
                        <Border Width="48" Height="48" CornerRadius="24" Background="#2E6DEB">
                            <TextBlock Text="✓" Foreground="White" FontSize="28" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
                            <TextBlock Text="DRDirect" Foreground="White" FontWeight="Bold" FontSize="24"/>
                            <TextBlock Text="PC Cleaner" Foreground="#B9C9DD" FontSize="16" FontWeight="SemiBold"/>
                            <TextBlock x:Name="VersionText" Foreground="#7F94AE" FontSize="11" Margin="0,2,0,0"/>
                        </StackPanel>
                    </StackPanel>
                </StackPanel>
                <!-- Scrolls on short screens (small laptops), so the last menu items never hide behind the Activate button -->
                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
                <ScrollViewer.Resources>
                    <Style TargetType="ScrollBar">
                        <Setter Property="Width" Value="6"/>
                        <Setter Property="MinWidth" Value="6"/>
                        <Setter Property="Margin" Value="0,0,4,0"/>
                        <Setter Property="Template">
                            <Setter.Value>
                                <ControlTemplate TargetType="ScrollBar">
                                    <Track x:Name="PART_Track" IsDirectionReversed="True">
                                        <Track.Thumb>
                                            <Thumb>
                                                <Thumb.Template>
                                                    <ControlTemplate TargetType="Thumb"><Border CornerRadius="3" Background="#4A6284"/></ControlTemplate>
                                                </Thumb.Template>
                                            </Thumb>
                                        </Track.Thumb>
                                    </Track>
                                </ControlTemplate>
                            </Setter.Value>
                        </Setter>
                    </Style>
                </ScrollViewer.Resources>
                <StackPanel x:Name="Navigation">
                    <Button x:Name="NavDashboard" Style="{StaticResource NavButton}" Tag="Active" Content="⌂   Dashboard"/>
                    <TextBlock Text="CLEAN" Foreground="#2BE37A" FontSize="11" FontWeight="Bold" Margin="20,16,0,4"/>
                    <Button x:Name="NavCleanup" Style="{StaticResource NavButton}" Content="✦   Clean my PC"/>
                    <Button x:Name="NavDuplicates" Style="{StaticResource NavButton}" Content="⧉   Find duplicate files"/>
                    <Button x:Name="NavSpeed" Style="{StaticResource NavButton}" Content="◈   Speed and space"/>
                    <TextBlock Text="FIX" Foreground="#2BE37A" FontSize="11" FontWeight="Bold" Margin="20,16,0,4"/>
                    <Button x:Name="NavRepair" Style="{StaticResource NavButton}" Content="⚒   Fix Windows"/>
                    <Button x:Name="NavAI" Style="{StaticResource AINavButton}" Content="⊘   Switch off AI" Margin="10,4,10,4" ToolTip="Switch off AI in Windows and web browsers"/>
                    <TextBlock Text="PROTECT" Foreground="#2BE37A" FontSize="11" FontWeight="Bold" Margin="20,16,0,4"/>
                    <Button x:Name="NavSecurity" Style="{StaticResource NavButton}" Content="⬡   Check my security"/>
                    <Button x:Name="NavHealth" Style="{StaticResource NavButton}" Foreground="#FACC15" Content="▰   Check my drives"/>
                    <Button x:Name="NavMemory" Style="{StaticResource NavButton}" Foreground="#FACC15" Content="▦   Check my RAM"/>
                    <Button x:Name="NavHardware" Style="{StaticResource NavButton}" Content="▤   About my PC"/>
                    <TextBlock Text="UPDATE" Foreground="#2BE37A" FontSize="11" FontWeight="Bold" Margin="20,16,0,4"/>
                    <Button x:Name="NavAppUpdates" Style="{StaticResource WingetNavButton}" Content="⭳   Update my apps" Margin="10,4,10,4" ToolTip="Update every app with winget, in a colour PowerShell window"/>
                    <Button x:Name="NavHistory" Style="{StaticResource NavButton}" Foreground="#22D3EE" FontWeight="SemiBold" Content="◷   Cleaning history" ToolTip="See what the Cleaner did, open the reports, and undo changes to settings"/>
                    <Button x:Name="NavProgress" Style="{StaticResource NavButton}" Content="◐   Maintenance progress" Visibility="Collapsed"/>
                </StackPanel>
                </ScrollViewer>
                <StackPanel Grid.Row="2" Margin="16,14,16,24"><Border x:Name="RunStrip" Visibility="Collapsed" Background="#12306B" BorderBrush="#2E6DEB" BorderThickness="1" CornerRadius="9" Padding="12,10" Margin="0,0,0,12" Cursor="Hand" ToolTip="Click to go to the progress page"><StackPanel><TextBlock x:Name="RunStripTitle" Text="Working..." Foreground="White" FontWeight="SemiBold" FontSize="13"/><TextBlock x:Name="RunStripDetail" Text="" Foreground="#B9C9DD" FontSize="11" TextTrimming="CharacterEllipsis" Margin="0,2,0,6"/><ProgressBar x:Name="RunStripBar" Height="6" Minimum="0" Maximum="100" Value="0" Foreground="#2BE37A" Background="#2A3F66" BorderThickness="0"/></StackPanel></Border><Border x:Name="ActivateWrap" Margin="0,0,0,14" CornerRadius="8" Background="#1E4FA8" BorderBrush="#7FB0FF" BorderThickness="1" Padding="8,10" HorizontalAlignment="Stretch" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform x:Name="ActivateScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform><StackPanel><TextBlock x:Name="TrialCountdown" Text="" HorizontalAlignment="Center" Foreground="#D7E6FF" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,6" Visibility="Collapsed"/><Button x:Name="ActivateButton" Content="&#128273;  Activate this product" HorizontalAlignment="Center" Background="Transparent" BorderThickness="0" Cursor="Hand" Foreground="White" FontSize="14" FontWeight="Bold" Padding="0"/></StackPanel></Border><TextBlock x:Name="AdminStatus" Foreground="#9FB0C9" FontSize="12"/></StackPanel>
            </Grid>
        </Border>

        <Grid Grid.Column="1" Margin="34,26,34,28">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="0,0,0,20"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="PageEyebrow" Text="THIS PC" Style="{StaticResource MutedText}" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="PageTitle" Text="Dashboard" Style="{StaticResource TitleText}"/></StackPanel><Border Grid.Column="1" CornerRadius="16" Background="#E7F6EF" Padding="12,7" VerticalAlignment="Center"><TextBlock Text="●  Protected mode" Foreground="{StaticResource Success}" FontSize="12"/></Border></Grid>

            <Grid Grid.Row="1">
                <ScrollViewer x:Name="PageDashboard" VerticalScrollBarVisibility="Auto"><StackPanel>
<Border x:Name="UpdateBanner" Visibility="Collapsed" Background="#12C25B" CornerRadius="12" Padding="20,14" Margin="0,0,0,16"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Orientation="Horizontal" VerticalAlignment="Center"><TextBlock Text="&#10004;" Foreground="White" FontSize="22" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,12,0"/><TextBlock x:Name="UpdateBannerText" Text="There is a new update" Foreground="White" FontSize="18" FontWeight="Bold" VerticalAlignment="Center" TextWrapping="Wrap"/></StackPanel><Button x:Name="UpdateBannerButton" Grid.Column="1" Content="See what is new and update" Style="{StaticResource HeroButton}" Foreground="#0B7A3B" Margin="16,0,0,0"/></Grid></Border>
<Border Style="{StaticResource Card}" Padding="34" Margin="0,0,0,18" Background="{StaticResource HeroBrush}" BorderBrush="#2447B8"><StackPanel><TextBlock Text="START HERE" Foreground="#A8C4FF" FontSize="11" FontWeight="Bold"/><TextBlock Text="Make my PC cleaner" Foreground="White" FontSize="32" FontWeight="ExtraBold" Margin="0,8,0,8"/><TextBlock Text="One click. We only do the safe things, and we ask you before anything starts." Foreground="#C9D9FF" FontSize="16" TextWrapping="Wrap" MaxWidth="560" HorizontalAlignment="Left"/><StackPanel Orientation="Horizontal" Margin="0,24,0,0"><Button x:Name="SafeCleanButton" Content="Make my PC cleaner" Style="{StaticResource HeroButton}"/><Button x:Name="SafePreviewButton" Content="Show me first" Style="{StaticResource HeroGhostButton}" Margin="10,0,0,0"/></StackPanel><TextBlock Text="✓  Settings changes can be undone.   ✓  Your files and passwords are never touched." Foreground="#DDE8FF" FontSize="13" Margin="0,20,0,0" TextWrapping="Wrap"/></StackPanel></Border>
<UniformGrid Columns="3" Margin="0,0,0,22">
                            <Border Style="{StaticResource Card}" Margin="0,0,12,0" BorderBrush="{StaticResource Violet}" BorderThickness="5,1,1,1"><StackPanel><StackPanel Orientation="Horizontal"><Border Style="{StaticResource StatIcon}" Background="{StaticResource VioletSoft}"><TextBlock Text="◷" Foreground="{StaticResource Violet}" FontSize="19" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="LAST CLEAN" Foreground="{StaticResource Violet}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock Text="Not yet" FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock Text="Shows here after your first clean" Style="{StaticResource MutedText}" FontSize="12"/></StackPanel></Border>
                            <Border Style="{StaticResource Card}" Margin="0,0,12,0" BorderBrush="{StaticResource Teal}" BorderThickness="5,1,1,1"><StackPanel><StackPanel Orientation="Horizontal"><Border Style="{StaticResource StatIcon}" Background="{StaticResource TealSoft}"><TextBlock Text="▰" Foreground="{StaticResource Teal}" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="FREE SPACE" Foreground="{StaticResource Teal}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock x:Name="FreeSpaceText" Text="Checking…" FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock Text="On your main drive" Style="{StaticResource MutedText}" FontSize="12"/></StackPanel></Border>
                            <Border Style="{StaticResource Card}" BorderBrush="{StaticResource Amber}" BorderThickness="5,1,1,1"><StackPanel><StackPanel Orientation="Horizontal"><Border Style="{StaticResource StatIcon}" Background="{StaticResource AmberSoft}"><TextBlock Text="⬡" Foreground="{StaticResource Amber}" FontSize="18" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="WINDOWS HEALTH" Foreground="{StaticResource Amber}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock x:Name="WindowsStatusText" Text="Not checked" FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock Text="Press &quot;Check my PC&quot; to find out" Style="{StaticResource MutedText}" FontSize="12"/></StackPanel></Border>
                        </UniformGrid>
<TextBlock Text="Other things you can do" FontSize="18" FontWeight="ExtraBold" Margin="0,0,0,10"/>
<UniformGrid Columns="3" Margin="0,0,0,14"><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,12,0"><StackPanel><TextBlock Text="Check my PC" FontSize="18" FontWeight="ExtraBold"/><TextBlock Text="See how much space you can free. Nothing is changed." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="40"/><Button x:Name="ScanButton" Content="Check my PC" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Left"/></StackPanel></Border><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,12,0"><StackPanel><TextBlock Text="Past results" FontSize="18" FontWeight="ExtraBold"/><TextBlock Text="Look at what the Cleaner did before." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="40"/><Button x:Name="LastReportButton" Content="See past results" Style="{StaticResource SecondaryButton}" HorizontalAlignment="Left"/></StackPanel></Border><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,12,0"><StackPanel><TextBlock Text="Update this program" FontSize="18" FontWeight="ExtraBold"/><TextBlock Text="Look for a newer version of the Cleaner." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="40"/><Button x:Name="CheckUpdatesButton" Content="Update this program" Style="{StaticResource SecondaryButton}" HorizontalAlignment="Left"/></StackPanel></Border></UniformGrid>
<StackPanel Margin="0,0,0,22"><TextBlock Text="MS Tools" FontSize="18" FontWeight="ExtraBold" Margin="0,0,0,10"/><Button x:Name="PCManagerButton" Style="{StaticResource HeroGhostButton}" Background="#0078D4" Foreground="White" HorizontalAlignment="Left" Margin="0,0,0,0" ToolTip="Opens Microsoft PC Manager, or its Microsoft Store page if it is not installed"><StackPanel Orientation="Horizontal"><Grid Width="16" Height="16" Margin="0,0,10,0" VerticalAlignment="Center"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions><Rectangle Fill="#F25022" Margin="0,0,1,1"/><Rectangle Grid.Column="1" Fill="#7FBA00" Margin="1,0,0,1"/><Rectangle Grid.Row="1" Fill="#00A4EF" Margin="0,1,1,0"/><Rectangle Grid.Row="1" Grid.Column="1" Fill="#FFB900" Margin="1,1,0,0"/></Grid><TextBlock Text="Microsoft PC Manager" Foreground="White" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Button><TextBlock Text="If it did not do the job, or you want your PC spick and span, use DRDirect PC Cleaner for a deeper clean-up." Style="{StaticResource MutedText}" TextWrapping="Wrap" MaxWidth="560" HorizontalAlignment="Left" Margin="0,10,0,0"/></StackPanel>
<Expander Header="More options: choose how deep to clean, and see recent changes" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,18"><StackPanel Margin="0,12,0,0"><Grid Margin="0,0,0,18"><Grid.ColumnDefinitions><ColumnDefinition Width="1*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
                            <Border Style="{StaticResource Card}" Padding="22" Margin="0,0,16,0">
                                <StackPanel>
                                    <TextBlock Text="HERE IS WHAT WILL CHANGE" Foreground="{StaticResource Blue}" FontSize="11" FontWeight="Bold"/>
                                    <TextBlock x:Name="SafePlanTitle" Text="What Safe mode does" FontSize="18" FontWeight="ExtraBold" Margin="0,6,0,2"/>
                                    <TextBlock Text="Pick a level to see its steps. Nothing has run yet, and you confirm before anything starts." Style="{StaticResource MutedText}" TextWrapping="Wrap"/>
                                    <StackPanel Orientation="Horizontal" Margin="0,10,0,0"><Button x:Name="SafeLevelSafeButton" Content="Easy" Style="{StaticResource SecondaryButton}" Padding="16,6"/><Button x:Name="SafeLevelMediumButton" Content="Deeper" Style="{StaticResource SecondaryButton}" Padding="16,6" Margin="8,0,0,0"/><Button x:Name="SafeLevelAdvancedButton" Content="Expert" Style="{StaticResource SecondaryButton}" Padding="16,6" Margin="8,0,0,0"/></StackPanel>
                                    <StackPanel x:Name="SafePlanList" Margin="0,8,0,6"/>
                                    <TextBlock x:Name="SafePlanNote" Foreground="#667085" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,10"/>
                                    <Button x:Name="SafePlanRunButton" Content="Yes, review and run" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Left"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Style="{StaticResource Card}" Padding="22">
                                <StackPanel>
                                    <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="HISTORY &amp; UNDO" Foreground="{StaticResource Blue}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/>
                                        <Button x:Name="DashboardHistoryButton" Grid.Column="1" Content="See all" Style="{StaticResource SecondaryButton}" Padding="12,5"/>
                                    </Grid>
                                    <TextBlock Text="Your recent changes" FontSize="18" FontWeight="ExtraBold" Margin="0,6,0,2"/>
                                    <StackPanel x:Name="DashboardHistoryList" Margin="0,8,0,10"/>
                                    <Button x:Name="UndoAllDashButton" Content="↺  Undo all AI changes" Style="{StaticResource SecondaryButton}" HorizontalAlignment="Left"/>
                                </StackPanel>
                            </Border>
                        </Grid></StackPanel></Expander>
<Border x:Name="TestModeBanner" Style="{StaticResource Card}" Background="#FFF4E3" BorderBrush="#F0C98C" Margin="0,18,0,0" Visibility="Collapsed"><TextBlock Text="TEST MODE is active. External Windows operations are simulated and file deletion is limited to the supplied test folder." Foreground="{StaticResource Warning}" TextWrapping="Wrap"/></Border>
</StackPanel></ScrollViewer>

                <Grid x:Name="PageTasks" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <!-- The whole page scrolls, not just the list: on a short screen the level buttons
                         would otherwise leave the task list room for barely one row. -->
                    <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto"><StackPanel>
                    <Grid Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="TaskIntro" Text="Select exactly what you want to run. Nothing starts until you review and confirm the plan." Style="{StaticResource MutedText}" TextWrapping="Wrap"/><Border Grid.Column="1" Background="{StaticResource BlueSoft}" CornerRadius="14" Padding="12,6"><TextBlock x:Name="SelectionSummary" Text="0 selected" Foreground="{StaticResource Blue}" FontSize="12"/></Border></Grid>
                    <Border x:Name="CleanupPresetPanel" Style="{StaticResource Card}" Padding="16" Margin="0,0,0,14" Visibility="Visible">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal"><TextBlock Text="Choose cleanup level" FontSize="16" FontWeight="SemiBold"/><Border Background="#E8F0FF" CornerRadius="10" Padding="8,3" Margin="10,0,0,0"><TextBlock Text="ORDERED PRESETS" Foreground="#2563EB" FontSize="11" FontWeight="SemiBold"/></Border></StackPanel>
                            <TextBlock Text="Safe = regular cleanup. Medium = full cleanup. Advanced = full cleanup plus Windows repair." Style="{StaticResource MutedText}" FontSize="12" Margin="0,4,0,12"/>
                            <UniformGrid Columns="3">
                                <Button x:Name="PresetSafe" Style="{StaticResource PresetChoiceButton}" BorderBrush="{StaticResource Success}" Background="#EDF8F3">
                                    <TextBlock Text="SAFE SCAN" Foreground="{StaticResource Success}" FontSize="15" FontWeight="Bold"/>
                                </Button>
                                <Button x:Name="PresetMedium" Style="{StaticResource PresetChoiceButton}" BorderBrush="{StaticResource Blue}" Background="#EEF4FF">
                                    <TextBlock Text="MEDIUM SCAN" Foreground="{StaticResource Blue}" FontSize="15" FontWeight="Bold"/>
                                </Button>
                                <Button x:Name="PresetAdvanced" Style="{StaticResource PresetChoiceButton}" BorderBrush="{StaticResource Danger}" Background="#FFF1F1" Margin="0">
                                    <TextBlock Text="ADVANCED SCAN" Foreground="{StaticResource Danger}" FontSize="15" FontWeight="Bold"/>
                                </Button>
                            </UniformGrid>
                            <TextBlock x:Name="PresetDescription" Text="Choose a level, or select individual tasks below." Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0"/>
                        </StackPanel>
                    </Border>
                    <StackPanel x:Name="TaskList"/>
                    </StackPanel></ScrollViewer>
                    <Grid Grid.Row="1" Margin="0,16,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Destructive actions always require final confirmation." Style="{StaticResource MutedText}" FontSize="12" VerticalAlignment="Center"/><Button x:Name="ReviewButton" Grid.Column="1" Content="Review selected plan" Style="{StaticResource PrimaryButton}" IsEnabled="False"/></Grid>
                </Grid>

                <Grid x:Name="PageProgress" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="ProgressScanLevel" Text="SELECTED SCAN" Foreground="{StaticResource Blue}" FontSize="24" FontWeight="Bold" Margin="0,0,0,6"/><TextBlock x:Name="ProgressHeading" Text="Running maintenance plan" Style="{StaticResource SectionText}"/><TextBlock x:Name="ProgressMessage" Text="Preparing…" Style="{StaticResource MutedText}" Margin="0,5,0,0"/></StackPanel><TextBlock x:Name="ProgressPercent" Grid.Column="1" Text="0%" Foreground="{StaticResource Blue}" FontWeight="SemiBold" FontSize="18" VerticalAlignment="Center"/></Grid>
                    <!-- A sweeping brush over a bar that fills as tasks finish: it is
                         obvious the PC is being worked on, even during a long silent
                         step where the percentage does not move for minutes. -->
                    <Border x:Name="CleaningAnimation" Grid.Row="1" Height="76" CornerRadius="14" Margin="0,14,0,4"
                            Background="{StaticResource HeroBrush}" ClipToBounds="True" Visibility="Collapsed">
                        <Grid>
                            <Rectangle Width="220" HorizontalAlignment="Left" IsHitTestVisible="False" Opacity="0.20">
                                <Rectangle.Fill>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                        <GradientStop Color="#00FFFFFF" Offset="0"/>
                                        <GradientStop Color="#FFFFFFFF" Offset="0.5"/>
                                        <GradientStop Color="#00FFFFFF" Offset="1"/>
                                    </LinearGradientBrush>
                                </Rectangle.Fill>
                                <Rectangle.RenderTransform><TranslateTransform x:Name="SweepShift" X="-260"/></Rectangle.RenderTransform>
                                <Rectangle.Triggers>
                                    <EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever">
                                        <DoubleAnimation Storyboard.TargetName="SweepShift" Storyboard.TargetProperty="X"
                                                         From="-260" To="1500" Duration="0:0:2.6"/>
                                    </Storyboard></BeginStoryboard></EventTrigger>
                                </Rectangle.Triggers>
                            </Rectangle>
                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0">
                                <TextBlock Text="&#129529;" FontSize="30" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.9">
                                    <TextBlock.RenderTransform><RotateTransform x:Name="BrushSwing" Angle="-18"/></TextBlock.RenderTransform>
                                    <TextBlock.Triggers>
                                        <EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True">
                                            <DoubleAnimation Storyboard.TargetName="BrushSwing" Storyboard.TargetProperty="Angle"
                                                             From="-18" To="18" Duration="0:0:0.9"/>
                                        </Storyboard></BeginStoryboard></EventTrigger>
                                    </TextBlock.Triggers>
                                </TextBlock>
                                <StackPanel Margin="16,0,0,0" VerticalAlignment="Center">
                                    <TextBlock Text="CLEANING THIS PC" Foreground="#A8C4FF" FontSize="11" FontWeight="Bold"/>
                                    <TextBlock x:Name="CleaningCaption" Text="Working..." Foreground="White" FontSize="18" FontWeight="SemiBold" Margin="0,3,0,0"/>
                                </StackPanel>
                            </StackPanel>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,22,0">
                                <Ellipse Width="9" Height="9" Fill="#BFD3FF" Margin="4,0">
                                    <Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True">
                                        <DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.2" Duration="0:0:0.6"/>
                                    </Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers>
                                </Ellipse>
                                <Ellipse Width="9" Height="9" Fill="#BFD3FF" Margin="4,0">
                                    <Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True">
                                        <DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.2" Duration="0:0:0.6" BeginTime="0:0:0.2"/>
                                    </Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers>
                                </Ellipse>
                                <Ellipse Width="9" Height="9" Fill="#BFD3FF" Margin="4,0">
                                    <Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True">
                                        <DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.2" Duration="0:0:0.6" BeginTime="0:0:0.4"/>
                                    </Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers>
                                </Ellipse>
                            </StackPanel>
                        </Grid>
                    </Border>
                    <!-- Shown in place of the cleaning banner once the plan finishes:
                         the tick draws itself, so the 'done' moment is unmistakable. -->
                    <Border x:Name="CleanDone" Grid.Row="1" Visibility="Collapsed" Opacity="0" Height="66" CornerRadius="14" Margin="0,14,0,4"
                            Background="{StaticResource SuccessSoft}" BorderBrush="#BCE3D0" BorderThickness="1" RenderTransformOrigin="0.5,0.5">
                        <Border.RenderTransform><ScaleTransform x:Name="CleanDoneScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0">
                            <Grid Width="36" Height="36" Margin="0,0,14,0">
                                <Ellipse Stroke="{StaticResource Success}" StrokeThickness="2.5"/>
                                <Path x:Name="CleanDoneTick" Stroke="{StaticResource Success}" StrokeThickness="3"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                                      StrokeDashArray="9 100" StrokeDashOffset="9" Data="M10,18.5 L15,23.5 L26,12"/>
                            </Grid>
                            <StackPanel VerticalAlignment="Center">
                                <TextBlock Text="Maintenance complete" Foreground="{StaticResource Success}" FontSize="16" FontWeight="SemiBold"/>
                                <TextBlock x:Name="CleanDoneSub" Foreground="#5F7A6E" FontSize="12"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                    <ProgressBar x:Name="OverallProgress" Grid.Row="1" Height="8" Minimum="0" Maximum="100" Value="0" Margin="0,96,0,18" Foreground="{StaticResource Blue}" Background="#DEE5F0" BorderThickness="0"/>
                    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="ProgressList"/></ScrollViewer>
                    <Grid Grid.Row="3" Margin="0,16,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="ProgressSafetyText" Text="Long-running Windows commands finish before the next task begins." Style="{StaticResource MutedText}" FontSize="12" VerticalAlignment="Center"/><Button x:Name="RestartButton" Grid.Column="1" Content="Restart now" Style="{StaticResource PrimaryButton}" Margin="0,0,10,0" Visibility="Collapsed"/><Button x:Name="CancelPlanButton" Grid.Column="2" Content="Stop after current task" Style="{StaticResource SecondaryButton}"/></Grid>
                </Grid>

                <Grid x:Name="PageHistory" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Grid Margin="0,0,0,14"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Reports are stored locally and include selected tasks, timestamps, results, warnings, and errors." Style="{StaticResource MutedText}" TextWrapping="Wrap"/><Button x:Name="OpenReportsButton" Grid.Column="1" Content="Open reports folder" Style="{StaticResource SecondaryButton}"/><Button x:Name="ClearHistoryButton" Grid.Column="2" Content="Clear all history" Style="{StaticResource DangerButton}" Margin="10,0,0,0"/><Button x:Name="UndoAllButton" Grid.Column="3" Content="↺  Undo all AI changes" Style="{StaticResource SecondaryButton}" Margin="10,0,0,0"/></Grid>
                    <Border Grid.Row="1" Style="{StaticResource Card}"><StackPanel x:Name="HistoryList"/></Border>
                </Grid>

                <Grid x:Name="PageHardware" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Grid Margin="0,0,0,14"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="What is inside this PC, and where there is room to improve it. Nothing here is changed or installed." Style="{StaticResource MutedText}" TextWrapping="Wrap" VerticalAlignment="Center"/><Button x:Name="CheckDriversButton" Grid.Column="1" Content="Check for driver updates" Style="{StaticResource SecondaryButton}" Margin="10,0,0,0"/></Grid>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="HardwareList"/></ScrollViewer>
                </Grid>

                <Grid x:Name="PageAppUpdates" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="Updates the apps installed on this PC using Windows Package Manager (winget). Your files and settings are not touched." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,0,0,14"/>
                    <Border Grid.Row="1" Style="{StaticResource Card}" VerticalAlignment="Top" Padding="30">
                        <StackPanel>
                            <TextBlock Text="KEEP APPS CURRENT" Foreground="{StaticResource Blue}" FontSize="11" FontWeight="Bold"/>
                            <TextBlock Text="Update all apps" FontSize="24" FontWeight="SemiBold" Margin="0,8,0,10"/>
                            <TextBlock Text="'Show available updates' only lists what is out of date. 'Update all apps' runs winget upgrade --all after you confirm. Progress is shown in a console window." Style="{StaticResource MutedText}" TextWrapping="Wrap" MaxWidth="620" HorizontalAlignment="Left"/>
                            <TextBlock x:Name="AppUpdatesStatus" Text="Nothing has run yet." Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,12,0,0"/>
                            <StackPanel Orientation="Horizontal" Margin="0,22,0,0">
                                <Button x:Name="ListAppUpdatesButton" Content="Show available updates" Style="{StaticResource SecondaryButton}"/>
                                <Button x:Name="UpdateAllAppsButton" Content="Update all apps" Style="{StaticResource PrimaryButton}" Margin="10,0,0,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Grid>

                <Grid x:Name="PageDuplicates" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="Finds files that are 100% identical - same size, same SHA-256, then verified byte-for-byte - and keeps one copy of each set." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,0,0,14"/>
                    <Border Grid.Row="1" Style="{StaticResource Card}" VerticalAlignment="Top" Padding="30">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
                            <StackPanel VerticalAlignment="Center">
                                <TextBlock Text="RECLAIM SPACE" Foreground="{StaticResource Blue}" FontSize="11" FontWeight="Bold"/>
                                <TextBlock Text="Find duplicate files" FontSize="24" FontWeight="SemiBold" Margin="0,8,0,10"/>
                                <TextBlock Text="One copy of every file is always kept. Removed duplicates go to the Recycle Bin, so nothing is deleted permanently. Windows system folders, program folders, and hard links are skipped." Style="{StaticResource MutedText}" TextWrapping="Wrap" MaxWidth="620" HorizontalAlignment="Left"/>
                                <TextBlock x:Name="DuplicateStatus" Text="Opens in its own window." Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,12,0,0"/>
                                <StackPanel Orientation="Horizontal" Margin="0,22,0,0">
                                    <Button x:Name="OpenDuplicatesButton" Content="Open Duplicate Finder" Style="{StaticResource PrimaryButton}"/>
                                </StackPanel>
                            </StackPanel>
                            <Grid Grid.Column="1">
                                <Ellipse Width="120" Height="120" Fill="{StaticResource BlueSoft}"/>
                                <TextBlock Text="⧉" Foreground="{StaticResource Blue}" FontSize="46" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Grid>
                        </Grid>
                    </Border>
                </Grid>
            </Grid>
        </Grid>

        <Grid x:Name="BusyOverlay" Grid.ColumnSpan="2" Background="#990F172A" Visibility="Collapsed">
            <Border Width="520" Background="White" CornerRadius="14" Padding="32" HorizontalAlignment="Center" VerticalAlignment="Center"><StackPanel><TextBlock x:Name="OverlayTitle" Text="Analyzing this PC" Style="{StaticResource SectionText}" HorizontalAlignment="Center"/><Grid Margin="0,22,0,6"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><ProgressBar x:Name="OverlayProgress" Height="18" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Center" Foreground="{StaticResource Blue}" Background="#DEE5F0" BorderThickness="0"/><TextBlock x:Name="OverlayPercent" Grid.Column="1" Text="0%" Margin="14,0,0,0" Foreground="{StaticResource Blue}" FontWeight="SemiBold" FontSize="18" VerticalAlignment="Center"/></Grid><TextBlock x:Name="OverlayMessage" Text="Checking temporary files and browser caches…" Style="{StaticResource MutedText}" TextAlignment="Center" TextWrapping="Wrap"/><Button x:Name="OverlayContinueButton" Content="View results" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Center" Margin="0,22,0,0" Visibility="Collapsed"/></StackPanel></Border>
        </Grid>

        <Grid x:Name="ConfirmOverlay" Grid.ColumnSpan="2" Background="#990F172A" Visibility="Collapsed">
            <Border Width="570" MaxHeight="650" Background="White" CornerRadius="14" Padding="28" HorizontalAlignment="Center" VerticalAlignment="Center">
                <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <StackPanel><TextBlock Text="Review maintenance plan" Style="{StaticResource SectionText}"/><TextBlock Text="Only these selected operations will run, in the order shown." Style="{StaticResource MutedText}" Margin="0,5,0,14"/></StackPanel>
                    <ScrollViewer Grid.Row="1" MaxHeight="350" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="ConfirmList"/></ScrollViewer>
                    <Border x:Name="ConfirmWarning" Grid.Row="2" Background="#FFF4E3" CornerRadius="8" Padding="12" Margin="0,14,0,0" Visibility="Collapsed"><TextBlock x:Name="ConfirmWarningText" Foreground="{StaticResource Warning}" TextWrapping="Wrap"/></Border>
                    <Grid Grid.Row="3" Margin="0,20,0,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <StackPanel x:Name="RestartDelayPanel" Grid.Row="0" Margin="0,0,0,16" Visibility="Collapsed"><TextBlock Text="When should Windows restart after the clean?" FontWeight="SemiBold" Margin="0,0,0,6"/>
                            <ComboBox x:Name="RestartDelayCombo" SelectedIndex="6" FontSize="14" Padding="10,7">
                                <ComboBoxItem Tag="10" Content="Right away (10 seconds after it finishes)"/>
                                <ComboBoxItem Tag="300" Content="In 5 minutes"/>
                                <ComboBoxItem Tag="600" Content="In 10 minutes"/>
                                <ComboBoxItem Tag="1800" Content="In 30 minutes"/>
                                <ComboBoxItem Tag="3600" Content="In 1 hour"/>
                                <ComboBoxItem Tag="7200" Content="In 2 hours"/>
                                <ComboBoxItem Tag="10800" Content="In 3 hours"/>
                            </ComboBox>
                            <TextBlock Text="You can still restart sooner, or cancel the restart, from the progress page." Style="{StaticResource MutedText}" FontSize="12" Margin="0,6,0,0"/></StackPanel>
                        <CheckBox x:Name="ConfirmationCheck" Grid.Row="1" Content="I reviewed this plan and approve the selected changes."/><StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0"><Button x:Name="ConfirmBackButton" Content="Go back" Style="{StaticResource SecondaryButton}"/><Button x:Name="ConfirmRunButton" Content="Run selected tasks" Style="{StaticResource PrimaryButton}" Margin="10,0,0,0" IsEnabled="False"/></StackPanel></Grid>
                </Grid>
            </Border>
        </Grid>
    </Grid>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# When this interface runs as the compiled exe, the taskbar icon comes from the
# exe. When it runs as the updated script (hosted by powershell.exe), nothing
# sets an icon, so Windows shows the PowerShell icon instead. Give the window its
# own DRDirect icon and a stable app identity so both ways look the same.
try {
    $iconB64 = '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'
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.StreamSource = New-Object System.IO.MemoryStream (,[Convert]::FromBase64String($iconB64))
        $bmp.EndInit()
        $bmp.Freeze()
        $window.Icon = $bmp
    } catch { }
    if (-not ([System.Management.Automation.PSTypeName]'DRDirect.AppId').Type) {
        Add-Type -Namespace DRDirect -Name AppId -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@ -ErrorAction Stop
    }
    [void][DRDirect.AppId]::SetCurrentProcessExplicitAppUserModelID('DRDirect.PCCleaner')
} catch { }

# A small or zoomed screen (a 15" laptop at 125%) has far less room than the
# layout needs, so everything came out huge and the Cleanup list got about one
# row. There the whole window is laid out as a normal 1020 x 740 window and
# drawn smaller to fit. Big screens keep the full size.
try {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $layoutWidth = 1020; $layoutHeight = 740
    $uiScale = [Math]::Min(1.0, [Math]::Min(($wa.Height * 0.95) / $layoutHeight, ($wa.Width * 0.95) / $layoutWidth))
    if ($uiScale -lt 1.0) {
        $uiScale = [Math]::Max($uiScale, 0.6)
        $window.Content.LayoutTransform = [System.Windows.Media.ScaleTransform]::new($uiScale, $uiScale)
        $window.MinWidth  = [Math]::Floor($window.MinWidth  * $uiScale)
        $window.MinHeight = [Math]::Floor($window.MinHeight * $uiScale)
        $window.Width  = [Math]::Floor($layoutWidth  * $uiScale)
        $window.Height = [Math]::Floor($layoutHeight * $uiScale)
    }
    # Never open larger than the visible screen, or the title bar and its
    # buttons land off the top of it.
    if ($window.MinHeight -gt $wa.Height) { $window.MinHeight = $wa.Height }
    if ($window.MinWidth  -gt $wa.Width)  { $window.MinWidth  = $wa.Width }
    if ($window.Height -gt $wa.Height) { $window.Height = $wa.Height }
    if ($window.Width  -gt $wa.Width)  { $window.Width  = $wa.Width }
    $window.MaxHeight = $wa.Height
    $window.MaxWidth  = $wa.Width
} catch { }

function Get-Control { param([string]$Name) $window.FindName($Name) }

$ui = @{}
@('RestartDelayPanel','RestartDelayCombo','CustomTitleBar','TitleDragArea','TitleMinButton','TitleMaxButton','TitleCloseButton','NavDashboard','NavCleanup','NavRepair','NavSecurity','NavHealth','NavMemory','NavSpeed','UpdateBanner','UpdateBannerText','UpdateBannerButton','RunStrip','RunStripTitle','RunStripDetail','RunStripBar','NavHistory','NavProgress','ActivateButton','ActivateWrap','ActivateScale','TrialCountdown','AdminStatus','VersionText','PageTitle','PageEyebrow','FreeSpaceText','WindowsStatusText','ScanButton','LastReportButton','TestModeBanner','PageDashboard','PageTasks','TaskIntro','SelectionSummary','CleanupPresetPanel','PresetSafe','PresetMedium','PresetAdvanced','PresetDescription','TaskList','ReviewButton','PageProgress','ProgressScanLevel','ProgressHeading','ProgressMessage','ProgressPercent','OverallProgress','ProgressList','CleaningAnimation','CleaningCaption','CleanDone','CleanDoneScale','CleanDoneTick','CleanDoneSub','ProgressSafetyText','RestartButton','CancelPlanButton','PageHistory','OpenReportsButton','ClearHistoryButton','HistoryList','DashboardHistoryList','DashboardHistoryButton','NavHardware','PageHardware','PageAppUpdates','NavAppUpdates','AppUpdatesStatus','ListAppUpdatesButton','UpdateAllAppsButton','HardwareList','CheckDriversButton','PCManagerButton','NavDuplicates','NavAI','PageDuplicates','OpenDuplicatesButton','CheckUpdatesButton','DuplicateStatus','BusyOverlay','OverlayTitle','OverlayMessage','OverlayProgress','OverlayPercent','OverlayContinueButton','ConfirmOverlay','ConfirmList','ConfirmWarning','ConfirmWarningText','ConfirmationCheck','ConfirmBackButton','ConfirmRunButton','SafeCleanButton','UndoAllButton','SafePreviewButton','SafePlanList','SafePlanRunButton','UndoAllDashButton','SafePlanTitle','SafePlanNote','SafeLevelSafeButton','SafeLevelMediumButton','SafeLevelAdvancedButton') | ForEach-Object { $ui[$_] = Get-Control $_ }

# A quiet 'done' beat when a plan finishes: the completion badge fades in with a
# small bounce, its tick draws itself, and the results list eases into view.
# Wrapped so a cosmetic hiccup can never crash the run.
function Invoke-DRCleanReveal {
    param([int]$TaskCount, [switch]$ChecksOnly)
    if (-not $ui.CleanDone) { return }
  try {
    Add-Type -AssemblyName PresentationCore | Out-Null
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'

    $s = if ($TaskCount -ne 1) { 's' } else { '' }
    $ui.CleanDoneSub.Text = if ($ChecksOnly) { "$TaskCount check$s finished. Nothing was changed on this PC." } else { "$TaskCount task$s finished. Your PC has been cleaned up." }
    $ui.CleanDone.Visibility = 'Visible'

    $badgeFade = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, ([Windows.Duration]([TimeSpan]::FromMilliseconds(300))))
    $badgeFade.EasingFunction = $ease
    $ui.CleanDone.BeginAnimation([Windows.UIElement]::OpacityProperty, $badgeFade)

    $draw = New-Object System.Windows.Media.Animation.DoubleAnimation(9, 0, ([Windows.Duration]([TimeSpan]::FromMilliseconds(360))))
    $draw.BeginTime = [TimeSpan]::FromMilliseconds(200)
    $draw.EasingFunction = $ease
    $ui.CleanDoneTick.BeginAnimation([System.Windows.Shapes.Shape]::StrokeDashOffsetProperty, $draw)

    $bounce = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $bk = New-Object System.Windows.Media.Animation.CubicEase; $bk.EasingMode = 'EaseOut'
    $bounce.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.0, ([Windows.Media.Animation.KeyTime][TimeSpan]::FromMilliseconds(500)))))
    $bounce.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.05, ([Windows.Media.Animation.KeyTime][TimeSpan]::FromMilliseconds(620)), $bk)))
    $bounce.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.0, ([Windows.Media.Animation.KeyTime][TimeSpan]::FromMilliseconds(740)), $bk)))
    $ui.CleanDoneScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $bounce)
    $ui.CleanDoneScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $bounce.Clone())

    # Ease the finished results list up into view.
    if ($ui.ProgressList) {
        $tt = New-Object System.Windows.Media.TranslateTransform
        $tt.Y = 16
        $ui.ProgressList.RenderTransform = $tt
        $lf = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, ([Windows.Duration]([TimeSpan]::FromMilliseconds(450))))
        $ls = New-Object System.Windows.Media.Animation.DoubleAnimation(16, 0, ([Windows.Duration]([TimeSpan]::FromMilliseconds(600))))
        $lf.EasingFunction = $ease; $ls.EasingFunction = $ease
        $ui.ProgressList.BeginAnimation([Windows.UIElement]::OpacityProperty, $lf)
        $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $ls)
    }
  } catch { }
}

$catalog = @(Get-DRTaskCatalog)
$selection = @{}
$analysis = @{}
$currentCategory = 'Dashboard'
$script:driverPanel = $null
# What the AI Remover page found on its last check (apps, browsers, sign-ins).
$script:DRAIStatus = @()
# These only look, or only open a page for the customer to finish, so a run of
# nothing but these never needs Windows to restart.
$script:DRNoRestartTaskIds = @('health.chkdsk','health.drive-check','health.pc-checkup','health.ram-check','health.ram-test','health.boost-memory','health.startup-apps','health.large-files','security.checkup','cleanup.hibernate-off','cleanup.hibernate-on','ai.check','ai.gmail','ai.office-copilot','ai.edge-button','ai.copilot-key','ai.remove-models','ai.adobe','ai.adobe.on','ai.zoom','ai.zoom.on',
    'ai.gmail.on','ai.office-copilot.on','ai.edge-button.on','ai.copilot-key.on',
    'ai.copilot-app.on','ai.m365-app.on','ai.chatgpt-app.on','ai.claude-app.on',
    'ai.edge.uninstall','ai.chrome.uninstall','ai.brave.uninstall','ai.firefox.uninstall',
    'ai.copilot-app.uninstall','ai.m365-app.uninstall','ai.chatgpt-app.uninstall','ai.claude-app.uninstall',
    'ai.chrome.reinstall','ai.brave.reinstall','ai.firefox.reinstall')
# The "Turn off" choices "Turn off all AI" picks, filled as the AI rows are drawn.
$script:DRCheckWarned = @{}
$script:DRNavState = @{}
$script:DRSavedSelection = $null
$script:DRWasBusy = $false
$script:DRFinishedUnseen = $false
$script:DRAIOffButtons = New-Object System.Collections.ArrayList
$script:DRAIAllOffButton = $null
$script:DRAIUninstallButtons = New-Object System.Collections.ArrayList
$script:DRAIRestoreButton = $null
$runQueue = New-Object System.Collections.Generic.Queue[string]
$runEvents = New-Object System.Collections.Generic.List[object]
$runStartedAt = $null
$activePowerShell = $null
$activeRunspace = $null
$activeOutput = $null
$activeAsync = $null
$activeOutputIndex = 0
$activeTaskId = $null
$cancelAfterTask = $false
$activeTaskStartedAt = $null
$activeTaskMessage = ''
$childPidFile = Join-Path $env:TEMP ('DRDirect_child_{0}.pid' -f $PID)
$env:DRDIRECT_CHILD_PID_FILE = $childPidFile
$script:restartCountdownTimer = $null
$script:restartSecondsLeft = 0
$script:restartDelaySeconds = 10800
$script:restartCountdownBaseMessage = ''
$analysisMode = $false
$analysisTotal = 0
$analysisDone = 0
$cleanupPreset = 'Custom'
# The level the person last chose. Unticking a box drops the preset to Custom,
# but it must not reveal cookie cleanup on a Safe or Medium sweep.
$cleanupLevel = 'Custom'
$renderedCleanupFilter = $null
# TITLE BAR + BIGGER LOGO v1.4: custom dark-blue title bar and larger sidebar logo
$applyingCleanupPreset = $false

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Start-DRFadeIn {
    param(
        $Element,
        [double]$Shift = 14,
        [double]$Seconds = 0.30,
        [double]$Delay = 0
    )

    if (-not $Element) { return }

    try {
        $transform = New-Object Windows.Media.TranslateTransform
        $Element.RenderTransform = $transform

        $ease = New-Object Windows.Media.Animation.CubicEase
        $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut

        $fade = New-Object Windows.Media.Animation.DoubleAnimation
        $fade.From = 0
        $fade.To = 1
        $fade.Duration = [Windows.Duration][TimeSpan]::FromSeconds($Seconds)
        $fade.BeginTime = [TimeSpan]::FromSeconds($Delay)
        $fade.EasingFunction = $ease

        $slide = New-Object Windows.Media.Animation.DoubleAnimation
        $slide.From = $Shift
        $slide.To = 0
        $slide.Duration = [Windows.Duration][TimeSpan]::FromSeconds($Seconds)
        $slide.BeginTime = [TimeSpan]::FromSeconds($Delay)
        $slide.EasingFunction = $ease

        $Element.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        $transform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slide)
    } catch { }
}

function Set-Page {
    param([string]$Name)
    $ui.PageDashboard.Visibility = if ($Name -eq 'Dashboard') { 'Visible' } else { 'Collapsed' }
    $ui.PageTasks.Visibility = if ($Name -in @('Cleanup','Repair','Security','Health','Memory','Speed','AI')) { 'Visible' } else { 'Collapsed' }
    $ui.PageProgress.Visibility = if ($Name -eq 'Progress') { 'Visible' } else { 'Collapsed' }
    $ui.PageHistory.Visibility = if ($Name -eq 'History') { 'Visible' } else { 'Collapsed' }
    $ui.PageDuplicates.Visibility = if ($Name -eq 'Duplicates') { 'Visible' } else { 'Collapsed' }
    $ui.PageHardware.Visibility = if ($Name -eq 'Hardware') { 'Visible' } else { 'Collapsed' }
    $ui.PageAppUpdates.Visibility = if ($Name -eq 'AppUpdates') { 'Visible' } else { 'Collapsed' }
    $ui.PageTitle.Text = switch ($Name) { 'Cleanup' {'Clean my PC'} 'Repair' {'Fix Windows problems'} 'Security' {'Check my security'} 'Health' {'Check my drives'} 'Memory' {'Check my memory'} 'Speed' {'Speed and space'} 'Hardware' {'About my PC'} 'History' {'Cleaning history'} 'Duplicates' {'Find duplicate files'} 'AI' {'Switch off AI'} 'AppUpdates' {'Update my apps'} 'Progress' {'Maintenance progress'} default {$Name} }
    $script:currentCategory = $Name
    $ui.CleanupPresetPanel.Visibility = if ($Name -eq 'Cleanup') { 'Visible' } else { 'Collapsed' }
    $navMap = @{ Dashboard='NavDashboard'; Cleanup='NavCleanup'; Repair='NavRepair'; Security='NavSecurity'; Health='NavHealth'; Memory='NavMemory'; Speed='NavSpeed'; History='NavHistory'; Progress='NavProgress'; Duplicates='NavDuplicates'; Hardware='NavHardware'; AppUpdates='NavAppUpdates'; AI='NavAI' }
    foreach ($key in $navMap.Keys) { $ui[$navMap[$key]].Tag = if ($key -eq $Name) { 'Active' } else { $null } }
    if ($Name -in @('Cleanup','Repair','Security','Health','Memory','Speed','AI')) { Show-TaskCategory $Name }
    if ($Name -eq 'History') { Show-History }
    if ($Name -eq 'Dashboard') { Show-DashboardHistory }
    if ($Name -eq 'Hardware') { Show-Hardware }

    $activePage = switch ($Name) {
        'Dashboard' { $ui.PageDashboard }
        'Progress'  { $ui.PageProgress }
        'History'   { $ui.PageHistory }
        'Duplicates' { $ui.PageDuplicates }
        'Hardware'  { $ui.PageHardware }
        'AppUpdates' { $ui.PageAppUpdates }
        default     { $ui.PageTasks }
    }
    Start-DRFadeIn -Element $activePage
    Start-DRFadeIn -Element $ui.PageTitle -Shift 8 -Seconds 0.26 -Delay 0.04
}

function Get-CleanupPresetDescription {
    param([string]$Preset)

    if ($Preset -eq 'Safe') {
        return 'Regular cleanup: temporary files, browser caches, Recycle Bin, Prefetch, old Windows Update leftovers, and caches Windows rebuilds by itself.'
    }

    if ($Preset -eq 'Medium') {
        return 'Full cleanup: Safe plus Windows Disk Cleanup.'
    }

    if ($Preset -eq 'Advanced') {
        return 'Everything in Medium plus icon cache, jump lists, memory dumps, old restore points, event logs, a Defender quick scan, and full Windows repair: restore point, DISM, SFC, and Windows Update repair. Cookies and the network reset stay manual.'
    }

    return 'Custom selection. Security and drive-health operations remain manual.'
}

function Test-TaskInOrderedPreset {
    param(
        [object]$Task,
        [ValidateSet('Safe','Medium','Advanced')][string]$Preset
    )

    # Ordered presets are explicit lists, not risk rules, so each level stays a
    # strict superset of the one before it and cookie cleanup - the only task
    # that signs the user out - is held back until Advanced.
    # The Recycle Bin is part of every level: emptying it is what customers
    # expect a cleanup to do. The run still warns before it goes.
    $safeIds = @(
        'cleanup.windows-temp',
        'cleanup.browser-cache',
        'cleanup.recycle-bin',
        'cleanup.hidden-recycle-folders',
        'cleanup.prefetch',
        'cleanup.wu-download-cache',
        'cleanup.old-update-backups',
        'cleanup.thumbnail-cache',
        'cleanup.shader-cache',
        'cleanup.wer-queue',
        'cleanup.delivery-optimization-cache'
    )
    # The cloud caches are safe and only ever appear for a service that is
    # installed, so a full cleanup should take them too.
    $cloudCacheIds = @(
        'cleanup.cloud-icloud',
        'cleanup.cloud-google',
        'cleanup.cloud-onedrive',
        'cleanup.cloud-dropbox',
        'cleanup.cloud-mega',
        'cleanup.cloud-appcaches',
        'cleanup.cloud-store'
    )
    $mediumIds = $safeIds + @('cleanup.disk-cleanup') + $cloudCacheIds
    # Apart from the Recycle Bin, Safe and Medium never pre-select anything that
    # loses something the person cannot get back. Advanced is the full sweep and
    # takes all of it - icon cache (closes Explorer windows), jump lists (loses
    # pins), memory dumps, old restore points and event logs - except cookies,
    # which signs the person out and so is only ever ticked by hand.
    $advancedIds = $mediumIds + @(
        'cleanup.icon-cache',
        'cleanup.jumplists',
        'cleanup.memory-dumps',
        'cleanup.old-restore-points',
        'cleanup.event-logs',
        'health.drive-check',
        'health.ram-check'
    )

    if ($Preset -eq 'Safe') {
        return ($safeIds -contains $Task.Id)
    }

    if ($Preset -eq 'Medium') {
        return ($mediumIds -contains $Task.Id)
    }

    if ($Preset -eq 'Advanced') {
        # A quick Defender scan rides along with the full sweep. It stays on the
        # Security page too, so it can still be run on its own in a few minutes.
        #
        # The network reset is left out. A PC on a static address or manual DNS
        # has to have those re-entered afterwards, and a remote session drops
        # while the address renews. It stays on the Repair page to tick by hand.
        return (($advancedIds -contains $Task.Id) -or
                ($Task.Category -eq 'Repair' -and $Task.Id -notin @('repair.network-reset','health.chkdsk','health.ram-test')) -or
                $Task.Id -eq 'security.quick-scan')
    }

    return $false
}

function Test-CleanupPresetMatch {
    param([ValidateSet('Safe','Medium','Advanced')][string]$Preset)

    foreach ($task in @($catalog)) {
        $expected = Test-TaskInOrderedPreset -Task $task -Preset $Preset

        if ([bool]$selection[$task.Id] -ne [bool]$expected) {
            return $false
        }
    }

    return $true
}

function Set-CleanupPresetVisual {
    param([string]$Preset)

    $script:applyingCleanupPreset = $true
    try {
        $ui.PresetSafe.Tag = if ($Preset -eq 'Safe') { 'Active' } else { $null }
        $ui.PresetMedium.Tag = if ($Preset -eq 'Medium') { 'Active' } else { $null }
        $ui.PresetAdvanced.Tag = if ($Preset -eq 'Advanced') { 'Active' } else { $null }
    }
    finally {
        $script:applyingCleanupPreset = $false
    }

    $script:cleanupPreset = $Preset
    $ui.PresetDescription.Text = Get-CleanupPresetDescription -Preset $Preset
}

function Sync-CleanupPresetFromSelection {
    if ($script:applyingCleanupPreset) {
        return
    }

    foreach ($presetName in @('Safe','Medium','Advanced')) {
        if (Test-CleanupPresetMatch -Preset $presetName) {
            Set-CleanupPresetVisual -Preset $presetName
            Sync-CleanupTaskVisibility
            return
        }
    }

    Set-CleanupPresetVisual -Preset 'Custom'
    Sync-CleanupTaskVisibility
}

function Sync-CleanupTaskVisibility {
    if ($script:currentCategory -ne 'Cleanup') { return }
    if ($script:renderedCleanupFilter -eq $script:cleanupLevel) { return }

    # Deferred so the list is not rebuilt from inside the checkbox event that
    # is still running against one of its rows.
    $window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [action]{ Show-TaskCategory -Category 'Cleanup' }
    ) | Out-Null
}

function Apply-CleanupPreset {
    param([ValidateSet('Safe','Medium','Advanced')][string]$Preset)

    $script:applyingCleanupPreset = $true
    try {
        foreach ($task in @($catalog)) {
            $selection[$task.Id] = [bool](
                Test-TaskInOrderedPreset -Task $task -Preset $Preset
            )
        }

        $ui.PresetSafe.Tag = if ($Preset -eq 'Safe') { 'Active' } else { $null }
        $ui.PresetMedium.Tag = if ($Preset -eq 'Medium') { 'Active' } else { $null }
        $ui.PresetAdvanced.Tag = if ($Preset -eq 'Advanced') { 'Active' } else { $null }
    }
    finally {
        $script:applyingCleanupPreset = $false
    }

    $script:cleanupPreset = $Preset
    $script:cleanupLevel = $Preset
    $ui.PresetDescription.Text = Get-CleanupPresetDescription -Preset $Preset

    if ($script:currentCategory -eq 'Cleanup') {
        Show-TaskCategory -Category 'Cleanup'
    }
    else {
        Update-SelectionSummary
    }
}

function Start-DRAIGlowEdge {
    # A border that slowly shifts between two colours, for the two "everything"
    # boxes at the top of the AI Remover page.
    param($Card, [string]$From, [string]$To)
    try {
        $edge = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($From))
        $Card.BorderBrush = $edge
        $shift = New-Object Windows.Media.Animation.ColorAnimation
        $shift.To = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($To)
        $shift.Duration = [Windows.Duration][TimeSpan]::FromSeconds(1.8)
        $shift.AutoReverse = $true
        $shift.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $edge.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $shift)
    } catch { $Card.BorderBrush = $From }
}

function Set-DRAIRowTint {
    # The row lights up in the colour of the choice picked on it, and fades back
    # to white when nothing on it is picked.
    param($Card, [string]$Kind, [switch]$KeepEdge)
    if (-not ($Card -is [Windows.Controls.Border])) { return }
    $colors = @{ Off = @('#FFF1F2', '#E11D48'); On = @('#F0FDF4', '#16A34A'); Look = @('#F5F3FF', '#7C3AED') }
    $restFill = if ($Card.Tag -is [string] -and $Card.Tag -like '#*') { [string]$Card.Tag } else { '#FFFFFF' }
    $fill, $edge = if ($Kind -and $colors.ContainsKey($Kind)) { $colors[$Kind] } else { @($restFill, '#7C3AED') }
    if ($Card.BorderBrush -is [Windows.Media.SolidColorBrush] -and $Card.BorderBrush.HasAnimatedProperties) { $KeepEdge = [switch]$true }
    try {
        $from = if ($Card.Background -is [Windows.Media.SolidColorBrush]) { $Card.Background.Color } else { [Windows.Media.Colors]::White }
        $brush = New-Object Windows.Media.SolidColorBrush $from
        $Card.Background = $brush
        $fade = New-Object Windows.Media.Animation.ColorAnimation -ArgumentList ([Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($fill)), ([Windows.Duration][TimeSpan]::FromMilliseconds(280))
        $brush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $fade)
        if (-not $KeepEdge) { $Card.BorderBrush = $edge }
    } catch { }
}

function Show-DRAICheckResults {
    # The answer to "What AI is on this PC?", shown straight away inside its own row.
    # It only reads, so it never joins the plan or asks for a restart.
    param($Card)
    if (-not ($Card -is [Windows.Controls.Border])) { return }
    $copy = @($Card.Child.Children | Where-Object { [Windows.Controls.Grid]::GetColumn($_) -eq 1 }) | Select-Object -First 1
    if (-not $copy) { return }
    foreach ($old in @($copy.Children | Where-Object { $_.Tag -eq 'AICheckResults' })) { [void]$copy.Children.Remove($old) }

    $rows = @(); $failed = $null
    try {
        $window.Cursor = [System.Windows.Input.Cursors]::Wait
        $rows = @(Get-DRAIReport)
    } catch { $failed = $_.Exception.Message } finally { $window.Cursor = $null }

    $panel = New-Object Windows.Controls.StackPanel -Property @{ Margin = '0,12,12,0'; MaxWidth = 650; HorizontalAlignment = 'Left' }
    $panel.Tag = 'AICheckResults'
    if ($failed) {
        [void]$panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = "The check could not finish: $failed"; Foreground = '#C63C3C'; TextWrapping = 'Wrap' }))
    }
    foreach ($item in $rows) {
        $line = New-Object Windows.Controls.TextBlock -Property @{ TextWrapping = 'Wrap'; FontSize = 13; Margin = '0,3,0,0' }
        $dot = New-Object Windows.Documents.Run -ArgumentList '●  '
        $dot.Foreground = if ($item.On) { '#E11D48' } else { '#16A34A' }
        $text = New-Object Windows.Documents.Run -ArgumentList ([string]$item.Text)
        $text.Foreground = '#172033'
        [void]$line.Inlines.Add($dot); [void]$line.Inlines.Add($text)
        [void]$panel.Children.Add($line)
    }
    if (-not $failed) {
        $on = @($rows | Where-Object { $_.On }).Count
        $summary = if ($on) { '{0} AI item(s) still on - pick "Turn off" for them on this page.' -f $on } else { 'No AI that the Cleaner can switch off is still on.' }
        [void]$panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{
            Text = $summary; FontWeight = 'Bold'; FontSize = 13; Margin = '0,8,0,0'; TextWrapping = 'Wrap'
            Foreground = $(if ($on) { '#BE123C' } else { '#15803D' }) }))
        [void]$panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{
            Text = 'Gmail, Zoom, Word and Excel, the Edge button and the Copilot key cannot be read from here.'
            Foreground = '#667085'; FontSize = 11.5; Margin = '0,4,0,0'; TextWrapping = 'Wrap' }))
    }
    [void]$copy.Children.Add($panel)
    Start-DRFadeIn -Element $panel -Shift 8 -Seconds 0.3
}

function Test-DRRunBusy {
    # True while a clean-up or check is still running. Starting another run now would
    # throw away the progress on screen and the tasks still waiting, so it must wait.
    return (($runQueue.Count -gt 0) -or ($script:activeAsync -and -not $script:activeAsync.IsCompleted))
}

function Invoke-DRAIRunNow {
    # AI Remover buttons act as soon as they are clicked: only these tasks run,
    # with no plan to review. Anything that uninstalls or deletes asks first.
    param([string[]]$TaskIds)
    if (Test-DRRunBusy) {
        [void][Windows.MessageBox]::Show("Something is already running.`n`nWait for it to finish, then try again. Starting another now would cancel the progress you can see.", 'DRDirect PC Cleaner',
            [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
        return
    }
    $tasks = @($catalog | Where-Object { $TaskIds -contains $_.Id })
    if (-not $tasks.Count) { return }
    if (@($tasks | Where-Object { $_.Risk -in @('Confirm','Cleanup') }).Count) {
        $names = ($tasks | ForEach-Object { $_.Name }) -join "`n"
        $answer = [Windows.MessageBox]::Show("This will run now:`n`n$names`n`nContinue?", 'DRDirect PC Cleaner',
            [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
    }
    # The one-click checks must not cost the person the ticks they had already set.
    if (@($TaskIds | Where-Object { $_ -in @('health.drive-check', 'health.ram-check') }).Count) {
        $script:DRSavedSelection = @{}
        foreach ($key in @($selection.Keys)) { $script:DRSavedSelection[$key] = [bool]$selection[$key] }
    }
    foreach ($key in @($selection.Keys)) { $selection[$key] = $false }
    foreach ($task in $tasks) { $selection[$task.Id] = $true }
    Start-RunPlan
}

function New-DRAIChoiceButton {
    # One of a row's choices. Clicking it runs that task straight away. Rows that
    # know their state show it: the choice that matches is dark, the other light.
    param([string]$Label, [ValidateSet('Off','On','Look')][string]$Kind, [string]$TaskId, [bool]$Enabled, [string]$Reason, $Active = $null)
    $button = New-Object Windows.Controls.Primitives.ToggleButton
    $button.Style = $window.Resources['AIChoice']
    $button.Content = $Label
    $button.Tag = $Kind
    $button.CommandParameter = $TaskId
    if ($null -ne $Active) {
        $palette = if ($Kind -eq 'On') {
            if ($Active) { @('#15803D', '#14532D', 'White') } else { @('#DCFCE7', '#86EFAC', '#15803D') }
        } else {
            if ($Active) { @('#BE123C', '#881337', 'White') } else { @('#FFE4E6', '#FDA4AF', '#BE123C') }
        }
        $button.Background = $palette[0]; $button.BorderBrush = $palette[1]; $button.Foreground = $palette[2]
    }
    if ($Enabled) {
        $button.IsChecked = $false
    } else {
        $button.IsEnabled = $false
        # A choice that can't be used (browser not signed in, nothing to undo) fades, unless it is the state the row is in.
        if (-not $Active) { $button.Opacity = 0.45 }
        $selection[$TaskId] = $false
        if ($Reason) {
            $button.ToolTip = $Reason
            [Windows.Controls.ToolTipService]::SetShowOnDisabled($button, $true)
        }
    }
    $button.Add_Checked({
        param($sender, $e)
        # "Check now" answers straight away instead of joining the plan.
        if ([string]$sender.CommandParameter -eq 'ai.check') {
            Show-DRAICheckResults -Card $sender.Parent.Parent.Parent
            $sender.IsChecked = $false
            return
        }
        $taskId = [string]$sender.CommandParameter
        $sender.IsChecked = $false
        Invoke-DRAIRunNow -TaskIds @($taskId)
    })
    return $button
}

function New-DRAIChoicePanel {
    # "Turn off" and "Turn back on" (or "Remove" and "Reinstall") in place of a tick box.
    param($Task, $Status, [bool]$NeedsSignIn)
    $panel = New-Object Windows.Controls.StackPanel -Property @{ VerticalAlignment = 'Center'; Margin = '0,0,16,0' }
    $id = [string]$Task.Id
    $onId = "$id.on"
    $offLabel = switch -Wildcard ($id) {
        'ai.check'         { '⌕  Check now' }
        'ai.restore'       { '↺  Turn all back on' }
        'ai.remove-models' { '✕  Delete' }
        'ai.*-app'         { '✕  Remove' }
        default            { '✕  Turn off' }
    }
    $offKind = switch ($id) { 'ai.restore' { 'On' } 'ai.check' { 'Look' } default { 'Off' } }
    $canOff = (-not $Status) -or [bool]$Status.CanOff
    $offReason = $null
    if ($NeedsSignIn) { $canOff = $false; $offReason = 'Sign in to the browser first.' }
    elseif (-not $canOff) { $offReason = 'Already removed from this PC.' }
    # Rows that can tell whether their AI is on show it in dark green (on) or dark red (off).
    $isOff = $null
    if ($Status -and $offKind -eq 'Off') { $isOff = [bool]($Status.CanOn -or -not $Status.CanOff) }
    $offButton = New-DRAIChoiceButton -Label $offLabel -Kind $offKind -TaskId $id -Enabled $canOff -Reason $offReason -Active $isOff
    [void]$panel.Children.Add($offButton)
    if ($id -eq 'ai.restore') { $script:DRAIRestoreButton = $offButton }
    # "Turn off all AI" picks everything the Cleaner can finish by itself.
    # Claude is never part of it: DRDirect keeps Claude.
    if ($offKind -eq 'Off' -and [string]$Task.Risk -ne 'Guided' -and $id -ne 'ai.claude-app') { [void]$script:DRAIOffButtons.Add($offButton) }

    if (@($catalog | Where-Object { $_.Id -eq $onId }).Count) {
        $onLabel = if ($id -like 'ai.*-app') { '↻  Reinstall' } else { '✓  Turn back on' }
        $canOn = [bool]($Status -and $Status.CanOn)
        $onReason = if ($canOn) { $null } elseif ($id -like 'ai.*-app') { 'Already installed.' } else { 'Already on - the Cleaner has not turned it off on this PC.' }
        [void]$panel.Children.Add((New-DRAIChoiceButton -Label $onLabel -Kind 'On' -TaskId $onId -Enabled $canOn -Reason $onReason -Active $(if ($null -ne $isOff) { -not $isOff } else { $null })))
    }

    # The third choice: uninstall the browser. Windows does the removing in Installed apps.
    $uninstallId = "$id.uninstall"
    if (@($catalog | Where-Object { $_.Id -eq $uninstallId }).Count) {
        $canUninstall = $id -ne 'ai.edge'
        $uninstallReason = if ($canUninstall) { $null } else { 'Windows does not let Edge be uninstalled. Turn its AI off instead.' }
        # An app that is already removed has nothing left to uninstall.
        if ($canUninstall -and $id -like 'ai.*-app' -and $Status -and -not $Status.CanOff) { $canUninstall = $false; $uninstallReason = 'Not installed.' }
        if ($canUninstall -and $Status -and $Status.CanReinstall) { $canUninstall = $false; $uninstallReason = 'Already uninstalled. Use Reinstall to put it back.' }
        $uninstallButton = New-DRAIChoiceButton -Label '🗑  Uninstall completely' -Kind 'Look' -TaskId $uninstallId -Enabled $canUninstall -Reason $uninstallReason
        $uninstallButton.Background = '#EEF2FF'; $uninstallButton.BorderBrush = '#4338CA'; $uninstallButton.Foreground = '#312E81'
        [void]$panel.Children.Add($uninstallButton)
        # "Uninstall all AI" runs every one of these. DRDirect keeps Claude, so it is never in it.
        if ($canUninstall -and $id -ne 'ai.claude-app') { [void]$script:DRAIUninstallButtons.Add($uninstallButton) }
    }

    # The fourth choice, once a browser or Recall has been uninstalled: put it back.
    $reinstallId = "$id.reinstall"
    if (@($catalog | Where-Object { $_.Id -eq $reinstallId }).Count) {
        $canReinstall = [bool]($Status -and $Status.CanReinstall)
        $reinstallReason = if ($canReinstall) { $null } else { 'Already installed.' }
        $reinstallButton = New-DRAIChoiceButton -Label '⬇  Reinstall' -Kind 'On' -TaskId $reinstallId -Enabled $canReinstall -Reason $reinstallReason -Active $canReinstall
        if (-not $canReinstall) { $reinstallButton.Background = '#DCFCE7'; $reinstallButton.BorderBrush = '#86EFAC'; $reinstallButton.Foreground = '#15803D' }
        [void]$panel.Children.Add($reinstallButton)
    }
    return $panel
}

function New-DRAIAllOffCard {
    # One click for "everything off", above the rows it picks. Its border slowly
    # shifts between violet and pink so it is the first thing the eye finds.
    $border = New-Object Windows.Controls.Border
    $border.Style = $window.Resources['Card']
    $border.Margin = '0,0,0,14'
    $border.Background = '#F6F1FF'
    $border.Tag = '#F6F1FF'
    $border.BorderThickness = '2'
    Start-DRAIGlowEdge -Card $border -From '#7C3AED' -To '#EC4899'

    $grid = New-Object Windows.Controls.Grid
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))

    $button = New-Object Windows.Controls.Primitives.ToggleButton
    $button.Style = $window.Resources['AIChoice']
    $button.Content = '✕  Turn off all AI'
    $button.Tag = 'Off'
    $button.FontSize = 14
    $button.Padding = '16,10'
    $button.MinWidth = 170
    $button.VerticalAlignment = 'Center'
    $button.Margin = '0,0,18,0'
    $button.Add_Checked({
        param($sender, $e)
        $sender.IsChecked = $false
        $ids = @($script:DRAIOffButtons | Where-Object { $_.IsEnabled } | ForEach-Object { [string]$_.CommandParameter })
        $answer = [Windows.MessageBox]::Show("Turn off all AI the Cleaner can switch off ($($ids.Count) items)? Claude is left alone.", 'DRDirect PC Cleaner',
            [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
        if ($ids.Count) { Invoke-DRAIRunNow -TaskIds $ids }
    })
    $script:DRAIAllOffButton = $button

    $copy = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($copy, 1)
    [void]$copy.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = 'Turn off all AI'; FontWeight = 'Bold'; FontSize = 17; Foreground = '#5B21B6' }))
    [void]$copy.Children.Add((New-Object Windows.Controls.TextBlock -Property @{
        Text = 'One click picks every "Turn off", "Remove" and "Delete" below that the Cleaner can do by itself. Claude is always left alone. Gmail, Word, the Edge button and the Copilot key each open their own page, so pick those one by one. Nothing runs until you review and confirm.'
        Foreground = '#667085'; TextWrapping = 'Wrap'; Margin = '0,5,12,0'; MaxWidth = 650 }))
    [void]$grid.Children.Add($button); [void]$grid.Children.Add($copy)
    $border.Child = $grid
    return $border
}

function New-DRAIUninstallAllCard {
    # The choice to remove every AI app and browser in one go, under "Turn off all AI".
    $border = New-Object Windows.Controls.Border
    $border.Style = $window.Resources['Card']
    $border.Margin = '0,0,0,14'
    $border.Background = '#EEF2FF'
    $border.Tag = '#EEF2FF'
    $border.BorderThickness = '2'
    Start-DRAIGlowEdge -Card $border -From '#4338CA' -To '#BE123C'

    $grid = New-Object Windows.Controls.Grid
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))

    $button = New-Object Windows.Controls.Primitives.ToggleButton
    $button.Style = $window.Resources['AIChoice']
    $button.Content = '🗑  Uninstall all AI'
    $button.Tag = 'Look'
    $button.FontSize = 14
    $button.Padding = '16,10'
    $button.MinWidth = 170
    $button.VerticalAlignment = 'Center'
    $button.Margin = '0,0,18,0'
    $button.Background = '#EEF2FF'; $button.BorderBrush = '#4338CA'; $button.Foreground = '#312E81'
    $button.Add_Checked({
        param($sender, $e)
        $sender.IsChecked = $false
        $ids = @($script:DRAIUninstallButtons | Where-Object { $_.IsEnabled } | ForEach-Object { [string]$_.CommandParameter })
        if (-not $ids.Count) {
            [void][Windows.MessageBox]::Show('There is no AI app or browser here that can be uninstalled.', 'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
            return
        }
        $names = (@($catalog | Where-Object { $ids -contains $_.Id } | ForEach-Object { $_.Name -replace ': uninstall completely$', '' -replace ' uninstall completely$', '' })) -join "`n"
        $answer = [Windows.MessageBox]::Show("This will uninstall ALL of these from this PC:`n`n$names`n`nClaude is left alone. Bookmarks, passwords and chats stay in their accounts.`n`nContinue?", 'DRDirect PC Cleaner',
            [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
        foreach ($key in @($selection.Keys)) { $selection[$key] = $false }
        foreach ($id in $ids) { $selection[$id] = $true }
        Start-RunPlan
    })

    $copy = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($copy, 1)
    [void]$copy.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = 'Uninstall all AI'; FontWeight = 'Bold'; FontSize = 17; Foreground = '#312E81' }))
    [void]$copy.Children.Add((New-Object Windows.Controls.TextBlock -Property @{
        Text = 'Your choice: one click uninstalls every AI app and browser listed below that can be removed. Claude is always left alone, and Edge cannot be removed by Windows. You are asked to confirm first.'
        Foreground = '#667085'; TextWrapping = 'Wrap'; Margin = '0,5,12,0'; MaxWidth = 650 }))
    [void]$grid.Children.Add($button); [void]$grid.Children.Add($copy)
    $border.Child = $grid
    return $border
}

function New-TaskRow {
    param($Task)
    $border = New-Object Windows.Controls.Border
    $border.Style = $window.Resources['Card']
    $border.Margin = '0,0,0,10'

    # Only the cookie/sign-out task gets the loud treatment; every other row stays plain.
    $risk = [string]$Task.Risk
    $isLoud = $risk -eq 'SignOut'

    if ($isLoud) {
        # A full red ring on all four sides, not just the left accent bar, so the
        # one task that can sign the user out cannot be skimmed past.
        $accent = @{ Badge='#FDE2E2'; BadgeInk='#A32020'; Label='⚠  SIGNS YOU OUT' }
        $border.Background = '#FFFAF0'
        $border.BorderBrush = '#C63C3C'
        $border.BorderThickness = '3'
    } else {
        $accent = @{ Badge='#EEF2F7'; BadgeInk='#526079'; Label=$Task.Risk }
    }

    # AI Remover rows share the page's violet and say plainly what each one does.
    $aiStatus = $null
    if ($Task.Category -eq 'AI') {
        $aiLabel = if ($Task.Id -eq 'ai.restore') { 'UNDO' } elseif ($Task.Id -eq 'ai.check') { 'ONLY LOOKS' } elseif ($risk -eq 'Cleanup') { 'FREES SPACE' } elseif ($risk -eq 'Confirm') { 'UNINSTALLS' } elseif ($risk -eq 'Guided') { 'YOU MAKE THE LAST CLICK' } else { 'CAN BE UNDONE' }
        $accent = @{ Badge='#F1EAFE'; BadgeInk='#6D28D9'; Label=$aiLabel }
        # A thick dark blue outline all the way round each AI row.
        $border.BorderBrush = '#1E3A8A'
        $border.BorderThickness = '8'
        $aiStatus = @($script:DRAIStatus | Where-Object { $_.TaskId -eq $Task.Id }) | Select-Object -First 1
        if ($Task.Id -eq 'ai.restore') {
            $border.Background = '#F0FDF4'
            $border.Tag = '#F0FDF4'
            $border.BorderThickness = '2'
            $border.Margin = '0,0,0,18'
            Start-DRAIGlowEdge -Card $border -From '#16A34A' -To '#14B8A6'
        }
    }
    $needsSignIn = [bool]($aiStatus -and $aiStatus.NeedsSignIn -and -not $aiStatus.SignedIn)

    $grid = New-Object Windows.Controls.Grid
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='Auto' }))
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='*' }))
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='Auto' }))

    $check = New-Object Windows.Controls.CheckBox
    $check.Style = $window.Resources['TaskCheck']
    $check.IsChecked = [bool]$selection[$Task.Id]
    $check.Tag = $Task.Id

    # A free try covers the Safe cleanup tasks. Everything deeper is visible,
    # so they can see what they would get, but not selectable.
    try {
        if ((Test-DRTrialMode) -and $Task.Category -eq 'Cleanup' -and $risk -ne 'Safe') {
            $check.IsEnabled = $false
            $check.IsChecked = $false
            $selection[$Task.Id] = $false
            $border.Opacity = 0.45
            $border.ToolTip = 'Included with a full code. The free try covers the Safe scan.'
        }
    } catch { }
    # A browser's AI is only switched off once the customer has signed in to it.
    if ($needsSignIn) {
        $check.IsEnabled = $false
        $check.IsChecked = $false
        $selection[$Task.Id] = $false
    }
    $check.Add_Checked({
        param($sender,$args)
        $selection[$sender.Tag] = $true
        Sync-CleanupPresetFromSelection
        Update-SelectionSummary
    })
    $check.Add_Unchecked({
        param($sender,$args)
        $selection[$sender.Tag] = $false
        Sync-CleanupPresetFromSelection
        Update-SelectionSummary
    })

    $copy = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($copy,1)
    # A long AI title lets its badge drop to the next line instead of cutting it off.
    $titlePanel = if ($Task.Category -eq 'AI') { New-Object Windows.Controls.WrapPanel } else { New-Object Windows.Controls.StackPanel -Property @{ Orientation='Horizontal' } }
    $name = New-Object Windows.Controls.TextBlock -Property @{ Text=$Task.Name; FontWeight='SemiBold'; FontSize=15; VerticalAlignment='Center' }
    # AI Remover rows show every product name (Edge, Chrome, Brave, Firefox, Gmail, Claude...) in big bold letters.
    if ($Task.Category -eq 'AI') {
        $title = [string]$Task.Name
        $brand = $null
        if ($title.Contains(': ')) { $brand = $title.Substring(0, $title.IndexOf(': ')) }
        elseif ($title -match '(ChatGPT|Claude|Copilot|Gmail|Edge|Chrome|Brave|Firefox|Adobe Acrobat|Windows)') { $brand = $Matches[1] }
        $name.Text = ''
        $addRun = { param([string]$Text, [bool]$Big) if ($Text) { [void]$name.Inlines.Add((New-Object Windows.Documents.Run -Property @{ Text = $Text; FontWeight = $(if ($Big) { 'ExtraBold' } else { 'SemiBold' }); FontSize = $(if ($Big) { 22 } else { 15 }) })) } }
        if ($brand) {
            $at = $title.IndexOf($brand)
            & $addRun $title.Substring(0, $at) $false
            & $addRun $brand $true
            & $addRun $title.Substring($at + $brand.Length) $false
        } else { & $addRun $title $true }
    }
    $badgePadding = if ($isLoud) { '9,4' } else { '8,3' }
    $badge = New-Object Windows.Controls.Border -Property @{ Background=$accent.Badge; CornerRadius=10; Padding=$badgePadding; Margin='10,0,0,0' }
    $badgeText = New-Object Windows.Controls.TextBlock -Property @{ Text=$accent.Label; Foreground=$accent.BadgeInk; FontSize=11 }
    if ($isLoud) { $badgeText.FontSize = 10.5; $badgeText.FontWeight = 'Bold' }
    $badge.Child = $badgeText

    if ($isLoud) {
        # Slow breathing pulse so the risky rows catch the eye without shouting.
        try {
            $pulse = New-Object Windows.Media.Animation.DoubleAnimation
            $pulse.From = 1.0
            $pulse.To = 0.55
            $pulse.Duration = [Windows.Duration][TimeSpan]::FromSeconds(1.6)
            $pulse.AutoReverse = $true
            $pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $badge.BeginAnimation([Windows.UIElement]::OpacityProperty, $pulse)
        } catch { }
    }
    $titlePanel.Children.Add($name) | Out-Null; $titlePanel.Children.Add($badge) | Out-Null
    $description = New-Object Windows.Controls.TextBlock -Property @{ Text=$Task.Description; Foreground='#667085'; TextWrapping='Wrap'; Margin='0,5,12,0'; MaxWidth=650 }
    $copy.Children.Add($titlePanel) | Out-Null; $copy.Children.Add($description) | Out-Null

    # At the bottom of a row that knows its state: green when its AI is active, dark red when it is off.
    $stateBanner = $null
    if ($aiStatus -and $Task.Id -notin @('ai.restore', 'ai.check') -and -not $needsSignIn) {
        # The banner tells only what the Cleaner has verified: off, still on, or "cannot check".
        $rowState = [string](Get-DRPropertyValue -InputObject $aiStatus -Name 'State')
        $stateText = [string](Get-DRPropertyValue -InputObject $aiStatus -Name 'StateText')
        if (-not $rowState) { $rowState = 'Unknown' }
        if (-not $stateText) { $stateText = 'Cannot check - you decide' }
        $stateInk  = switch ($rowState) { 'Off' { '#9F1239' } 'On' { '#166534' } default { '#475467' } }
        $stateFill = switch ($rowState) { 'Off' { '#FFE4E6' } 'On' { '#DCFCE7' } default { '#EEF1F6' } }
        $stateEdge = switch ($rowState) { 'Off' { '#BE123C' } 'On' { '#15803D' } default { '#98A2B3' } }
        # A wide banner centred along the bottom of the row, with a big solid dot.
        $stateLine = New-Object Windows.Controls.StackPanel -Property @{ Orientation='Horizontal'; HorizontalAlignment='Center' }
        $stateLine.Children.Add((New-Object Windows.Shapes.Ellipse -Property @{ Width=20; Height=20; Fill=$stateEdge; Stroke=$stateInk; StrokeThickness=3; Margin='0,0,12,0'; VerticalAlignment='Center' })) | Out-Null
        $stateLine.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$stateText; Foreground=$stateInk; FontWeight='ExtraBold'; FontSize=19; VerticalAlignment='Center' })) | Out-Null
        $stateBanner = New-Object Windows.Controls.Border -Property @{ Background=$stateFill; BorderBrush=$stateEdge; BorderThickness=3; CornerRadius=12; Padding='26,9'; Margin='0,14,0,0'; HorizontalAlignment='Center'; Child=$stateLine }
    }

    if ($needsSignIn) {
        $where = switch ($aiStatus.Browser) {
            'Edge'    { 'Open Edge, click the profile picture at the top left and sign in.' }
            'Firefox' { 'Open Firefox, click the account button at the top right and sign in to a Mozilla account.' }
            default   { 'Open {0}, click the profile picture at the top right and sign in.' -f $aiStatus.Browser }
        }
        $lockPanel = New-Object Windows.Controls.Grid -Property @{ Margin='0,9,12,0'; MaxWidth=650; HorizontalAlignment='Left' }
        $lockPanel.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='*' }))
        $lockPanel.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='Auto' }))
        $lockText = New-Object Windows.Controls.TextBlock -Property @{
            Text = ('{0} is not signed in. {1} Then click Check again.' -f $aiStatus.Browser, $where)
            Foreground = '#96500A'; FontSize = 12; FontWeight = 'SemiBold'; TextWrapping = 'Wrap'; VerticalAlignment = 'Center'
        }
        $recheck = New-Object Windows.Controls.Button
        $recheck.Style = $window.Resources['SecondaryButton']
        $recheck.Content = 'Check again'
        $recheck.Padding = '12,6'
        $recheck.Margin = '12,0,0,0'
        $recheck.VerticalAlignment = 'Center'
        $recheck.Add_Click({ Show-TaskCategory 'AI' })
        [Windows.Controls.Grid]::SetColumn($recheck, 1)
        [void]$lockPanel.Children.Add($lockText); [void]$lockPanel.Children.Add($recheck)
        [void]$copy.Children.Add($lockPanel)
    }

    if ($isLoud) {
        $caution = 'Clearing cookies helps protect your privacy by removing trackers and saved sign-ins. Before you tick it, make sure you know all your email addresses and passwords, and keep them in a safe place. You may have to sign in again. Only tick it if you are sure and ready to do so. DRDirect is not responsible for any sign-in or password you cannot get back.'
        $cautionText = New-Object Windows.Controls.TextBlock -Property @{
            Text = $caution
            Foreground = '#96500A'
            FontSize = 12
            FontWeight = 'SemiBold'
            TextWrapping = 'Wrap'
            Margin = '0,7,12,0'
            MaxWidth = 650
        }
        [void]$copy.Children.Add($cautionText)

        Start-DRFadeIn -Element $cautionText -Shift 6 -Seconds 0.35 -Delay 0.12

        try {
            $cautionPulse = New-Object Windows.Media.Animation.DoubleAnimation
            $cautionPulse.From = 1.0
            $cautionPulse.To = 0.55
            $cautionPulse.Duration = [Windows.Duration][TimeSpan]::FromSeconds(1.6)
            $cautionPulse.BeginTime = [TimeSpan]::FromSeconds(0.5)
            $cautionPulse.AutoReverse = $true
            $cautionPulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $cautionText.BeginAnimation([Windows.UIElement]::OpacityProperty, $cautionPulse)
        } catch { }
    }

    $meta = New-Object Windows.Controls.StackPanel -Property @{ HorizontalAlignment='Right'; Margin='12,0,0,0' }
    [Windows.Controls.Grid]::SetColumn($meta,2)
    $value = if ($analysis.ContainsKey($Task.Id) -and $Task.SupportsAnalysis) { Format-Bytes $analysis[$Task.Id].Bytes } else { $Task.Duration }
    if ($aiStatus -and $aiStatus.Detail) { $value = $aiStatus.Detail }
    $meta.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$value; FontWeight='SemiBold'; HorizontalAlignment='Right' })) | Out-Null
    $sub = if ($analysis.ContainsKey($Task.Id) -and $analysis[$Task.Id].ItemCount -gt 0) { "$($analysis[$Task.Id].ItemCount) location(s)" } elseif ($Task.RequiresAdmin) { 'Administrator' } else { 'Current user' }
    $meta.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$sub; Foreground='#667085'; FontSize=11; HorizontalAlignment='Right'; Margin='0,4,0,0' })) | Out-Null

    # AI Remover rows get "Turn off" / "Turn back on" in place of the tick box.
    if ($Task.Category -eq 'AI') { $check = New-DRAIChoicePanel -Task $Task -Status $aiStatus -NeedsSignIn $needsSignIn }
    $grid.Children.Add($check) | Out-Null; $grid.Children.Add($copy) | Out-Null; $grid.Children.Add($meta) | Out-Null
    if ($stateBanner) {
        $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height='Auto' }))
        $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height='Auto' }))
        [Windows.Controls.Grid]::SetRow($stateBanner, 1); [Windows.Controls.Grid]::SetColumnSpan($stateBanner, 3)
        $grid.Children.Add($stateBanner) | Out-Null
    }
    $border.Child = $grid
    if ($Task.Category -eq 'AI') {
        $picked = @($check.Children | Where-Object { $_.IsChecked }) | Select-Object -First 1
        if ($picked) { Set-DRAIRowTint -Card $border -Kind ([string]$picked.Tag) }
    }
    return $border
}

function Get-VisibleTasksForCategory {
    param([string]$Category)

    $tasks = @($catalog | Where-Object Category -eq $Category)

    # Each ordered level only lists what it will actually run, computed from the
    # same membership check the preset buttons use - so a task added to Medium
    # or Advanced automatically stays hidden under a lower level instead of
    # needing a second hardcoded list kept in sync by hand. Cookie cleanup is
    # the one task that signs the person out, so the row exists on Advanced and
    # nowhere else, Custom included.
    $hidden = @()
    if ($script:cleanupLevel -ne 'Advanced') { $hidden = @('cleanup.cookies') }
    if ($script:cleanupLevel -in @('Safe', 'Medium')) {
        $hidden += @($catalog | Where-Object { $_.Category -eq 'Cleanup' -and -not (Test-TaskInOrderedPreset -Task $_ -Preset $script:cleanupLevel) } | ForEach-Object Id)
    }

    # A cloud cache row is only worth showing when that service is actually set
    # up here. Offering to clear a Dropbox cache on a PC without Dropbox is a
    # row that can only ever report "nothing to do".
    foreach ($task in $tasks) {
        $service = Get-DRPropertyValue -InputObject $task -Name 'CloudService'
        if ($service -and -not (Test-DRCloudServicePresent $service)) { $hidden += $task.Id }
    }

    # An AI row only appears for an app or browser that is on this PC.
    if ($Category -eq 'AI') {
        foreach ($status in @($script:DRAIStatus)) { if (-not $status.Present) { $hidden += $status.TaskId } }
        # A "turn back on" task is a choice inside its row, not a row of its own.
        $hidden += @($tasks | Where-Object { $_.Id -like '*.on' -or $_.Id -like '*.uninstall' -or $_.Id -like '*.reinstall' } | ForEach-Object { $_.Id })
    }

    if ($Category -in @('Cleanup','AI') -and $hidden.Count) {
        return @($tasks | Where-Object { $hidden -notcontains $_.Id })
    }

    return $tasks
}

function Test-DRCloudServicePresent {
    <# True when the service keeps a folder on this PC, so it is signed in. #>
    param([string]$Service)

    # Declared up front: the engine runs under StrictMode, where reading a
    # variable that was never set is a hard error, not an empty value.
    if (-not (Test-Path variable:script:DRCloudPresence)) { $script:DRCloudPresence = @{} }
    if ($script:DRCloudPresence.ContainsKey($Service)) { return $script:DRCloudPresence[$Service] }

    $probes = switch ($Service) {
        'iCloud'       { @("$env:LOCALAPPDATA\Apple Inc\iCloud", (Join-Path $env:USERPROFILE 'iCloudDrive'), (Join-Path $env:USERPROFILE 'iCloud Drive')) }
        'Google Drive' { @("$env:LOCALAPPDATA\Google\DriveFS", (Join-Path $env:USERPROFILE 'Google Drive'), (Join-Path $env:USERPROFILE 'My Drive')) }
        # The exe itself, not the sync folder: Windows/Explorer can leave an
        # empty OneDrive folder behind (just a desktop.ini) long after the
        # client was uninstalled, which made this a false positive.
        'OneDrive'     { @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe") }
        'Dropbox'      { @("$env:LOCALAPPDATA\Dropbox", (Join-Path $env:USERPROFILE 'Dropbox')) }
        'App caches'   { @("$env:APPDATA\discord", "$env:LOCALAPPDATA\Spotify", "$env:APPDATA\Slack", "$env:APPDATA\Microsoft\Teams", "$env:LOCALAPPDATA\Steam") }
        'Microsoft Store' { @("$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe") }
        'MEGA'         { @("$env:LOCALAPPDATA\Mega Limited", (Join-Path $env:USERPROFILE 'MEGA')) }
        default        { @() }
    }

    $present = $false
    foreach ($probe in $probes) {
        if (-not $probe) { continue }
        try { if (Test-Path -LiteralPath $probe) { $present = $true; break } } catch { }
    }
    $script:DRCloudPresence[$Service] = $present
    return $present
}

function Show-TaskCategory {
    param([string]$Category)
    $ui.TaskList.Children.Clear()
    $ui.CleanupPresetPanel.Visibility = if ($Category -eq 'Cleanup') { 'Visible' } else { 'Collapsed' }
    $ui.TaskIntro.Text = switch ($Category) {
        'Cleanup' { 'Select cleanup items after reviewing the estimated impact. Passwords, bookmarks, personal documents, and active sessions remain protected unless cookie cleanup is explicitly selected.' }
        'Repair' { 'Windows repairs are separate from cleanup. Creating a restore point is recommended before repair operations.' }
        'Security' { 'Run Defender operations independently. Existing exclusions are never removed automatically.' }
        'Health' { 'Drive health checks are read-only and do not schedule repairs or restarts.' }
        'Speed' { 'These checks only look at the PC and show what is using space or slowing it down. Nothing is changed or deleted.' }
        'Memory' { 'The memory check only looks. The Windows memory test needs a restart that Windows asks about, and this app never restarts the PC by itself.' }
        'AI' { 'Pick "Turn off" or "Turn back on" for each item. A browser has to be signed in before its AI is turned off. Passwords, bookmarks, files and sign-ins are never touched.' }
    }
    if ($Category -eq 'AI') {
        # Checked fresh every time, so signing in and coming back unlocks the row.
        try {
            $window.Cursor = [System.Windows.Input.Cursors]::Wait
            $script:DRAIStatus = @(Get-DRAIStatus)
        } catch { $script:DRAIStatus = @() } finally { $window.Cursor = $null }
    }
    $visible = @(Get-VisibleTasksForCategory -Category $Category)
    # A row that is not on screen must not run. Dropping to Safe after ticking
    # cookie cleanup on Advanced would otherwise leave it selected but invisible.
    if ($Category -in @('Cleanup','AI')) {
        $visibleIds = @($visible | ForEach-Object { $_.Id })
        if ($Category -eq 'AI') { $visibleIds += @($visibleIds | ForEach-Object { "$_.on"; "$_.uninstall"; "$_.reinstall" }) }
        foreach ($task in @($catalog | Where-Object Category -eq $Category)) {
            if ($visibleIds -notcontains $task.Id) { $selection[$task.Id] = $false }
        }
    }
    if ($Category -eq 'AI') {
        $script:DRAIOffButtons.Clear()
        $script:DRAIUninstallButtons.Clear()
        $script:DRAIRestoreButton = $null
        $ui.TaskList.Children.Add((New-DRAIAllOffCard)) | Out-Null
        $ui.TaskList.Children.Add((New-DRAIUninstallAllCard)) | Out-Null
        $visible = @(@($visible | Where-Object { $_.Id -eq 'ai.restore' }) + @($visible | Where-Object { $_.Id -ne 'ai.restore' }))
    }
    foreach ($task in $visible) { $ui.TaskList.Children.Add((New-TaskRow $task)) | Out-Null }
    $script:renderedCleanupFilter = $script:cleanupLevel
    Update-SelectionSummary
}

function Update-SelectionSummary {
    $selected = @($catalog | Where-Object { $selection[$_.Id] })
    $total = @($selected).Count

    # The badge sits beside one page's list, so it counts that page. A run still
    # covers every page, and the badge says so when something is ticked elsewhere.
    $here = @($selected | Where-Object { $_.Category -eq $script:currentCategory }).Count
    if ($script:currentCategory -in @('Cleanup','Repair','Security','Health','Memory','Speed','AI')) {
        $ui.SelectionSummary.Text = if ($total -gt $here) { "$here selected here, $total in total" } else { "$here selected" }
    } else {
        $ui.SelectionSummary.Text = "$total selected"
    }

    $ui.ReviewButton.IsEnabled = $total -gt 0
}

function Show-Confirmation {
    $selection['safety.restore-point'] = $false
    $selected = @($catalog | Where-Object { $selection[$_.Id] })
    $ui.ConfirmList.Children.Clear()
    [void]$ui.ConfirmList.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text='Here is what will change. Nothing has run yet.'; FontWeight='ExtraBold'; FontSize=16; Margin='0,0,0,4' }))
    [void]$ui.ConfirmList.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text='A Windows restore point is saved first when possible, and the Cleaner keeps backups of the settings it changes. Your files, passwords and logins are never touched.'; Foreground='#0E8A5F'; FontSize=12.5; TextWrapping='Wrap'; Margin='0,0,0,8' }))
    foreach ($task in $selected) {
        $row = New-Object Windows.Controls.Border -Property @{ BorderBrush='#E3E8F0'; BorderThickness='0,0,0,1'; Padding='0,10' }
        $grid = New-Object Windows.Controls.Grid
        $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='*' }))
        $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='Auto' }))
        $left = New-Object Windows.Controls.StackPanel
        [void]$left.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$task.Name; FontWeight='SemiBold' }))
        [void]$left.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$task.Description; Foreground='#667085'; FontSize=12; TextWrapping='Wrap'; Margin='0,3,12,0' }))
        [void]$grid.Children.Add($left)
        # Plain-words tag: what kind of step this is.
        $tagText = switch ([string]$task.Risk) { 'Safe' {'SAFE'} 'Guided' {'YOU MAKE THE LAST CLICK'} 'SignOut' {'SIGNS YOU OUT'} 'Confirm' {'ASKS FIRST'} default { ([string]$task.Risk).ToUpperInvariant() } }
        $tagInk = switch ([string]$task.Risk) { 'Safe' {'#0E8A5F'} 'Guided' {'#6D28D9'} default {'#C0143C'} }
        $tagFill = switch ([string]$task.Risk) { 'Safe' {'#E4F6EE'} 'Guided' {'#EFE7FD'} default {'#FDE6EA'} }
        $risk = New-Object Windows.Controls.Border -Property @{ Background=$tagFill; CornerRadius=10; Padding='9,3'; VerticalAlignment='Top'; Child=(New-Object Windows.Controls.TextBlock -Property @{ Text=$tagText; Foreground=$tagInk; FontSize=10.5; FontWeight='Bold' }) }
        [Windows.Controls.Grid]::SetColumn($risk,1); [void]$grid.Children.Add($risk)
        $row.Child = $grid; [void]$ui.ConfirmList.Children.Add($row)
    }
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($selected.Risk -contains 'SignOut') { $warnings.Add('Cookie cleanup can end active website and webmail sessions.') }
    if ($selected.Id -contains 'cleanup.recycle-bin') { $warnings.Add('Recycle Bin contents will be permanently removed.') }
    if ($selected.Id -contains 'security.remove-exclusions') { $warnings.Add('All configured Defender exclusions will be exported to a backup and then removed.') }
    if ($selected.Id -contains 'security.checkup-fix') { $warnings.Add('Any of the Windows firewall, Microsoft Defender real-time protection and Windows Update that is off will be switched back on.') }
    if (@($selected | Where-Object { $_.Id -in @('ai.edge','ai.chrome','ai.brave','ai.firefox','ai.block-sites') }).Count) { $warnings.Add('The browsers you picked will show "Managed by your organization" - that is what keeps their AI off. "Turn back on" removes it.') }
    if (@($selected | Where-Object { $_.Category -eq 'AI' -and $_.Risk -eq 'Guided' }).Count) { $warnings.Add('Some items open Gmail, Word, Edge, Settings, the Microsoft Store or a download page at the right place. The last click there is yours - the steps show when it runs.') }
    if ($selected.Id -contains 'ai.remove-models') { $warnings.Add('Close Chrome and Edge before running, so the AI model they downloaded can be deleted.') }
    if (@($selected | Where-Object { $_.Category -eq 'AI' -and $_.Risk -eq 'Confirm' }).Count) { $warnings.Add('The AI apps you picked will be uninstalled. They can be installed again from the Microsoft Store.') }
    if ($selected.Id -contains 'ai.restore' -and @($selected | Where-Object { $_.Category -eq 'AI' -and $_.Id -notin @('ai.restore','ai.check') -and $_.Id -notlike '*.on' -and $_.Id -notlike '*.uninstall' -and $_.Id -notlike '*.reinstall' }).Count) { $warnings.Add('"Turn everything back on" is also picked, so it runs last and undoes the AI settings you turned off. Pick one or the other.') }
    $needsRestartHere = @($selected | Where-Object { $script:DRNoRestartTaskIds -notcontains $_.Id }).Count -gt 0
    $ui.RestartDelayPanel.Visibility = if ($needsRestartHere) { 'Visible' } else { 'Collapsed' }
    if ($needsRestartHere) { $warnings.Add('When everything has finished, Windows needs to restart. Choose below when. You get a countdown first, and you can cancel it or restart sooner.') }
    $ui.ConfirmWarning.Visibility = if ($warnings.Count) { 'Visible' } else { 'Collapsed' }
    $ui.ConfirmWarningText.Text = $warnings -join "`n"
    $ui.ConfirmationCheck.IsChecked = $false
    $ui.ConfirmRunButton.IsEnabled = $false
    $ui.ConfirmOverlay.Visibility = 'Visible'
}

function New-ProgressRow {
    param($Task)
    $border = New-Object Windows.Controls.Border
    $border.Style = $window.Resources['Card']; $border.Margin = '0,0,0,10'; $border.Tag = $Task.Id
    $grid = New-Object Windows.Controls.Grid
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='Auto' }))
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='*' }))
    $dot = New-Object Windows.Shapes.Ellipse -Property @{ Width=10; Height=10; Fill='#98A2B3'; Margin='0,0,14,0'; VerticalAlignment='Center'; Name='StateDot' }
    $panel = New-Object Windows.Controls.StackPanel; [Windows.Controls.Grid]::SetColumn($panel,1)
    $panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$Task.Name; FontWeight='SemiBold' })) | Out-Null
    $state = New-Object Windows.Controls.TextBlock -Property @{ Text='Waiting'; Foreground='#667085'; FontSize=12; Margin='0,3,0,0'; Name='StateText' }
    $panel.Children.Add($state) | Out-Null
    # What a read-only check found (drive by drive, stick by stick) is shown here.
    $found = New-Object Windows.Controls.StackPanel -Property @{ Visibility='Collapsed'; Name='ResultText' }
    $panel.Children.Add($found) | Out-Null
    $grid.Children.Add($dot) | Out-Null; $grid.Children.Add($panel) | Out-Null; $border.Child = $grid
    return $border
}

function Set-DRNavCheckMark {
    # The mark beside a menu item: a small red dot until its check has run, then a
    # green tick when it passed or a yellow warning sign when something needs attention.
    param([string]$NavName, [string]$Label, [ValidateSet('Unchecked','Good','Attention')][string]$Status, [string]$Tip = '')
    $button = $ui[$NavName]
    if (-not $button) { return }
    $script:DRNavState[$NavName] = $Status
    [Windows.Controls.ToolTipService]::SetShowOnDisabled($button, $true)
    $panel = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal' }
    [void]$panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $Label; VerticalAlignment = 'Center' }))
    $mark = switch ($Status) { 'Good' { [string][char]0x2714 } 'Attention' { [string][char]0x26A0 } default { [string][char]0x25CF } }
    $color = switch ($Status) { 'Good' { '#2BE37A' } 'Attention' { '#FACC15' } default { '#EF4444' } }
    [void]$panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $mark; Margin = '10,0,0,0'; Foreground = $color; FontWeight = 'Bold'; FontSize = $(if ($Status -eq 'Unchecked') { 11 } else { 17 }); VerticalAlignment = 'Center' }))
    $button.Content = $panel
    $button.ToolTip = if ($Tip) { $Tip } else { switch ($Status) { 'Good' { 'All good. No need to check again for now.' } 'Attention' { 'Checked: something needs attention. Click to check again.' } default { 'Not checked yet. Click to check.' } } }
}

# How long a check result stays valid. After this the menu item goes back to the red
# dot, as a reminder to check again.
$script:DRCheckValidDays = 90
$script:DRCheckMarks = @{
    'health.drive-check' = @{ Nav = 'NavHealth'; Label = ([string][char]0x25B0 + '   Check my drives') }
    'health.ram-check'   = @{ Nav = 'NavMemory'; Label = ([string][char]0x25A6 + '   Check my RAM') }
}

function Get-DRCheckStatusPath {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $null }
    return (Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\check_status.json')
}

function Read-DRCheckStatus {
    $result = @{}
    $file = Get-DRCheckStatusPath
    if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { return $result }
    try {
        $saved = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
        foreach ($property in $saved.PSObject.Properties) {
            $result[$property.Name] = @{ Date = [datetime]$property.Value.date; Attention = [bool]$property.Value.attention }
        }
    } catch { }
    return $result
}

function Save-DRCheckStatus {
    param([string]$TaskId, [bool]$Attention)
    $file = Get-DRCheckStatusPath
    if (-not $file) { return }
    try {
        $all = Read-DRCheckStatus
        $all[$TaskId] = @{ Date = (Get-Date); Attention = $Attention }
        $out = [ordered]@{}
        foreach ($key in $all.Keys) { $out[$key] = [ordered]@{ date = $all[$key].Date.ToString('o'); attention = $all[$key].Attention } }
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
        [System.IO.File]::WriteAllText($file, ($out | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Restore-DRCheckMarks {
    # On start: show each saved result while it is recent, otherwise the red dot.
    $saved = Read-DRCheckStatus
    foreach ($taskId in $script:DRCheckMarks.Keys) {
        $info = $script:DRCheckMarks[$taskId]
        $status = 'Unchecked'; $tip = ''
        if ($saved.ContainsKey($taskId)) {
            $ageDays = [int]((Get-Date) - $saved[$taskId].Date).TotalDays
            $when = $saved[$taskId].Date.ToString('d MMM yyyy')
            if ($ageDays -le $script:DRCheckValidDays) {
                $status = if ($saved[$taskId].Attention) { 'Attention' } else { 'Good' }
                $tip = if ($saved[$taskId].Attention) { "Last checked ${when}: something needs attention. Click to check again." } else { "Last checked ${when}: all good. No need to check again until the red dot comes back." }
            } else {
                $tip = "Last checked $when. It is time to check again."
            }
        }
        Set-DRNavCheckMark -NavName $info.Nav -Label $info.Label -Status $status -Tip $tip
    }
}

function New-DRResultCard {
    # One finding of a check that only looks: a green card with a tick when all is well,
    # an amber one with a warning sign when something needs attention.
    param([string]$Message, [string]$State)
    $parts = @($Message -split "\r?\n" | ForEach-Object { $_.TrimEnd() })
    $head = $parts[0].Trim()
    $body = (@($parts | Select-Object -Skip 1 | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n")
    $good = ($State -eq 'Information') -and ($head -match 'NO PROBLEMS FOUND|great health')
    $bad = ($State -eq 'Warning')
    if ($good) { $fill = '#E4F6EE'; $edge = '#8FD3B4'; $ink = '#0E8A5F'; $mark = [string][char]0x2714 + '  ' }
    elseif ($bad) { $fill = '#FFF4E3'; $edge = '#F0C98C'; $ink = '#A86412'; $mark = [string][char]0x26A0 + '  ' }
    else { $fill = '#F3F6FB'; $edge = '#D9E1EE'; $ink = '#344054'; $mark = '' }
    $box = New-Object Windows.Controls.Border -Property @{ Background=$fill; BorderBrush=$edge; BorderThickness='1'; CornerRadius='10'; Padding='16,12'; Margin='0,10,0,0' }
    $stack = New-Object Windows.Controls.StackPanel
    $title = New-Object Windows.Controls.TextBlock -Property @{ Text=($mark + $head); Foreground=$ink; FontSize=$(if ($good -or $bad) { 17 } else { 14 }); FontWeight='SemiBold'; TextWrapping='Wrap' }
    [void]$stack.Children.Add($title)
    if ($body) {
        [void]$stack.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$body; Foreground='#475467'; FontSize=13; TextWrapping='Wrap'; Margin='0,6,0,0'; LineHeight=20 }))
    }
    $box.Child = $stack
    return $box
}

function Set-ProgressRowState {
    param([string]$TaskId,[string]$State,[string]$Message)
    # The two quick checks leave their result on the menu.
    $navFor = @{ 'health.drive-check' = @('NavHealth', ([string][char]0x25B0 + '   Check my drives')); 'health.ram-check' = @('NavMemory', ([string][char]0x25A6 + '   Check my RAM')) }
    if ($navFor.ContainsKey($TaskId)) {
        if ($State -eq 'Started') { $script:DRCheckWarned[$TaskId] = $false }
        if ($State -in @('Warning','Failed')) { $script:DRCheckWarned[$TaskId] = $true }
        if ($State -in @('Completed','Failed')) {
            $attention = $false
            if ($script:DRCheckWarned.ContainsKey($TaskId)) { $attention = [bool]$script:DRCheckWarned[$TaskId] }
            Set-DRNavCheckMark -NavName $navFor[$TaskId][0] -Label $navFor[$TaskId][1] -Status $(if ($attention) { 'Attention' } else { 'Good' }) -Tip $(if ($attention) { 'Checked today: something needs attention. Click to check again.' } else { 'Checked today: all good. No need to check again for now.' })
            Save-DRCheckStatus -TaskId $TaskId -Attention $attention
        }
    }
    $row = @($ui.ProgressList.Children | Where-Object Tag -eq $TaskId | Select-Object -First 1)
    if (-not $row) { return }
    $dot = $row.Child.Children[0]; $text = $row.Child.Children[1].Children[1]
    $found = $row.Child.Children[1].Children[2]
    $dot.Fill = switch ($State) { 'Started' {'#2563EB'} 'Progress' {'#2563EB'} 'Completed' {'#16835B'} 'Failed' {'#C63C3C'} 'Warning' {'#A86412'} default {'#98A2B3'} }
    # A check that only looks keeps what it found on screen instead of losing it
    # behind the final "completed" line.
    $taskInfo = @($catalog | Where-Object Id -eq $TaskId | Select-Object -First 1)
    $onlyLooks = ($taskInfo.Count -gt 0) -and (-not [bool]$taskInfo[0].Destructive) -and ($TaskId -notlike 'ai.*')
    if ($onlyLooks -and $State -in @('Information','Warning')) {
        [void]$found.Children.Add((New-DRResultCard -Message $Message -State $State))
        $found.Visibility = 'Visible'
        return
    }
    $text.Text = $Message
    if ($TaskId -eq $script:activeTaskId) { Set-Variable -Name activeTaskMessage -Value $Message -Scope Script }
    if ($State -eq 'Failed') { $text.Foreground = '#C63C3C' }
}

function Start-EngineCall {
    param([string]$ScriptText,[bool]$IsAnalysis=$false)
    $activeRunspace = [RunspaceFactory]::CreateRunspace()
    $activeRunspace.ApartmentState = 'MTA'; $activeRunspace.ThreadOptions = 'ReuseThread'; $activeRunspace.Open()
    $activePowerShell = [PowerShell]::Create(); $activePowerShell.Runspace = $activeRunspace
    $activeOutput = $null
    $activeOutputIndex = 0; $analysisMode = $IsAnalysis
    $activePowerShell.AddScript($ScriptText) | Out-Null
    $activeAsync = $activePowerShell.BeginInvoke()
    Set-Variable -Name activeRunspace -Value $activeRunspace -Scope Script
    Set-Variable -Name activePowerShell -Value $activePowerShell -Scope Script
    Set-Variable -Name activeOutput -Value $activeOutput -Scope Script
    Set-Variable -Name activeAsync -Value $activeAsync -Scope Script
    Set-Variable -Name activeOutputIndex -Value 0 -Scope Script
    Set-Variable -Name analysisMode -Value $IsAnalysis -Scope Script
}

function Stop-EngineCall {
    if ($script:activePowerShell) { try { $script:activePowerShell.Dispose() } catch {} }
    if ($script:activeRunspace) { try { $script:activeRunspace.Close(); $script:activeRunspace.Dispose() } catch {} }
    $script:activePowerShell=$null; $script:activeRunspace=$null; $script:activeOutput=$null; $script:activeAsync=$null; $script:activeOutputIndex=0
}

function Set-AnalysisProgress {
    param([string]$Message)
    $total = [Math]::Max(1, $script:analysisTotal)
    $percent = [int](100 * $script:analysisDone / $total)
    if ($percent -gt 100) { $percent = 100 }
    $ui.OverlayProgress.Value = $percent; $ui.OverlayPercent.Text = "$percent%"
    if ($Message) { $ui.OverlayMessage.Text = $Message }
}

function Start-Analysis {
    Set-Variable -Name analysisTotal -Value @($catalog | Where-Object SupportsAnalysis).Count -Scope Script
    Set-Variable -Name analysisDone -Value 0 -Scope Script
    $ui.OverlayContinueButton.Visibility = 'Collapsed'
    $ui.BusyOverlay.Visibility = 'Visible'; $ui.OverlayTitle.Text = 'Analyzing this PC'; $ui.OverlayMessage.Text = 'Checking temporary files, browser data, and maintenance settings. Nothing is being changed.'
    Set-AnalysisProgress
    $engineSource = [System.IO.File]::ReadAllText($script:DREnginePath)
    $safeRoot = if ($TestRoot) { $TestRoot.Replace("'","''") } else { '' }
    $scriptText = $engineSource + "`r`nGet-DRAnalysis -TestRoot '$safeRoot'"
    Start-EngineCall -ScriptText $scriptText -IsAnalysis $true
}

function Set-ProgressScanLevel {
    param([string]$Preset)

    switch ($Preset) {
        'Safe' {
            $ui.ProgressScanLevel.Text = 'SAFE SCAN'
            $ui.ProgressScanLevel.Foreground = $window.Resources['Success']
        }
        'Medium' {
            $ui.ProgressScanLevel.Text = 'MEDIUM SCAN'
            $ui.ProgressScanLevel.Foreground = $window.Resources['Blue']
        }
        'Advanced' {
            $ui.ProgressScanLevel.Text = 'ADVANCED SCAN'
            $ui.ProgressScanLevel.Foreground = $window.Resources['Danger']
        }
        default {
            $ui.ProgressScanLevel.Text = 'CUSTOM SCAN'
            $ui.ProgressScanLevel.Foreground = $window.Resources['Muted']
        }
    }
}

function Start-RunPlan {
    # A trial gets one cleanup run in total, not one per launch.
    if (Test-DRTrialMode) {
        if (Get-DRTrialValue 'clean_used') {
            # The try is spent - this is when the activation window belongs.
            $ui.ConfirmOverlay.Visibility = 'Collapsed'
            if ((Show-DRActivation 'expired') -eq 'activated') {
                $ui.ActivateWrap.Visibility = 'Collapsed'
                [Windows.MessageBox]::Show('Activated. Restart the Cleaner to lift the limits.',
                    'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK,
                    [Windows.MessageBoxImage]::Information) | Out-Null
            }
            return
        }
        Set-DRTrialValue 'clean_used' $true
    }

    Stop-DRRestartCountdown
    # The person's choice of how long to wait before the restart. A plan started from an AI
    # button never shows the box, so it keeps the 3 hour default.
    $script:restartDelaySeconds = 10800
    try {
        $choice = $ui.RestartDelayCombo.SelectedItem
        if ($ui.RestartDelayPanel.Visibility -eq 'Visible' -and $choice) { $script:restartDelaySeconds = [int]$choice.Tag }
    } catch { }
    # A Windows restore point goes first whenever the plan really changes something.
    $selection['safety.restore-point'] = $false
    $changing = @($catalog | Where-Object { $selection[$_.Id] -and $_.Category -in @('Cleanup','Repair','AI') -and $_.Risk -ne 'Guided' -and $_.Id -notin @('ai.check','repair.restore-point') })
    if ($changing.Count -and (@($catalog | Where-Object Id -eq 'safety.restore-point').Count) -and -not $selection['repair.restore-point'] -and (Test-DRAdministrator)) { $selection['safety.restore-point'] = $true }
    $selected = @($catalog | Where-Object { $selection[$_.Id] })
    $runQueue.Clear(); foreach ($task in $selected) { $runQueue.Enqueue($task.Id) }
    if (Test-Path -LiteralPath $script:childPidFile) { Remove-Item -LiteralPath $script:childPidFile -Force -ErrorAction SilentlyContinue }
    $runEvents.Clear(); $runStartedAt = Get-Date; $cancelAfterTask = $false
    Set-Variable -Name runStartedAt -Value $runStartedAt -Scope Script
    Set-Variable -Name cancelAfterTask -Value $false -Scope Script
    $ui.ProgressList.Children.Clear(); foreach ($task in $selected) { $ui.ProgressList.Children.Add((New-ProgressRow $task)) | Out-Null }
    if ($ui.CleaningAnimation) { $ui.CleaningAnimation.Visibility='Visible' }
    if ($ui.CleanDone) { $ui.CleanDone.Visibility='Collapsed' }
    if ($ui.ProgressList) {
        $ui.ProgressList.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $ui.ProgressList.Opacity = 1
    }
    $ui.OverallProgress.Value=0; $ui.ProgressPercent.Text='0%'; $ui.CancelPlanButton.IsEnabled=$true; $ui.CancelPlanButton.Content='Stop after current task'
    $ui.RestartButton.Visibility='Collapsed'
    Set-ProgressScanLevel -Preset $script:cleanupPreset
    $ui.NavProgress.Visibility='Visible'
    $ui.ConfirmOverlay.Visibility='Collapsed'; Set-Page 'Progress'; Start-NextTask
}

function Get-DRActiveChildProcessId {
    if (-not (Test-Path -LiteralPath $script:childPidFile)) { return 0 }
    try {
        $raw = [System.IO.File]::ReadAllText($script:childPidFile).Trim()
        $value = 0
        if ([int]::TryParse($raw, [ref]$value)) { return $value }
    } catch { }
    return 0
}

function Update-ForceStopAvailability {
    param($Task)

    # Only offered once a stop has been requested, and only for tasks that are
    # safe to interrupt. DISM, SFC and the Windows Update reset are left alone:
    # killing those part-way can leave Windows servicing in a broken state.
    # Read defensively: an older engine file beside a newer interface will not
    # carry this property, and StrictMode turns a missing one into a crash.
    $script:activeTaskInterruptible = [bool](Get-DRPropertyValue -InputObject $Task -Name 'Interruptible')

    if (-not $script:cancelAfterTask) { return }

    if ($script:activeTaskInterruptible) {
        $ui.CancelPlanButton.IsEnabled = $true
        $ui.CancelPlanButton.Content = 'Force stop now'
        $ui.CancelPlanButton.Tag = 'ForceStop'
    }
    else {
        $ui.CancelPlanButton.IsEnabled = $false
        $ui.CancelPlanButton.Content = 'Stopping after current task…'
        $ui.CancelPlanButton.Tag = $null
    }
}

function Stop-DRActiveChildProcess {
    $childPid = Get-DRActiveChildProcessId
    if ($childPid -le 0) { return $false }
    try {
        # /T so the tool's own helper processes go with it.
        Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', [string]$childPid, '/T', '/F') `
            -WindowStyle Hidden -Wait -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Format-DRElapsed {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) { return ('{0}h {1:00}m' -f [int]$Span.TotalHours, $Span.Minutes) }
    if ($Span.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f [int]$Span.TotalMinutes, $Span.Seconds) }
    return ('{0}s' -f [int]$Span.TotalSeconds)
}

function Update-DRElapsedDisplay {
    if (-not $script:activeAsync) { return }
    if (-not $script:activeTaskStartedAt) { return }
    if ($script:analysisMode) { return }
    if (-not $script:activeTaskId) { return }

    $row = @($ui.ProgressList.Children | Where-Object Tag -eq $script:activeTaskId | Select-Object -First 1)
    if (-not $row) { return }

    $elapsed = Format-DRElapsed -Span ((Get-Date) - $script:activeTaskStartedAt)
    $base = $script:activeTaskMessage
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'Working…' }
    $row.Child.Children[1].Children[1].Text = ('{0}  ·  running {1}' -f $base, $elapsed)
}

function Start-NextTask {
    if ($cancelAfterTask -or $runQueue.Count -eq 0) { Complete-RunPlan; return }
    $activeTaskId = $runQueue.Dequeue(); Set-Variable -Name activeTaskId -Value $activeTaskId -Scope Script
    $task = $catalog | Where-Object Id -eq $activeTaskId | Select-Object -First 1
    Set-Variable -Name activeTaskStartedAt -Value (Get-Date) -Scope Script
    if ($ui.CleaningCaption) { $ui.CleaningCaption.Text = $task.Name }
    $ui.ProgressMessage.Text = "Starting $($task.Name)…"; Set-ProgressRowState $activeTaskId 'Started' 'Starting…'
    Update-ForceStopAvailability -Task $task
    $engineSource = [System.IO.File]::ReadAllText($script:DREnginePath); $safeId=$activeTaskId.Replace("'","''"); $safeRoot=if($TestRoot){$TestRoot.Replace("'","''")}else{''}
    $scriptText = $engineSource + "`r`nInvoke-DRTask -TaskId '$safeId' -TestRoot '$safeRoot'"
    Start-EngineCall -ScriptText $scriptText
}


function Get-DRPropertyValue {
    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) { return $null }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Write-DRSafeRunReport {
    param(
        [object[]]$Events,
        [string[]]$TaskId,
        [datetime]$StartedAt
    )

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'Windows did not provide a Local AppData folder.'
    }

    $reportRoot = Join-Path -Path $localAppData -ChildPath 'DRDirect PC Cleaner\Reports'
    [void][System.IO.Directory]::CreateDirectory($reportRoot)

    $finishedAt = Get-Date
    $reportPath = Join-Path -Path $reportRoot -ChildPath (
        'Maintenance_Report_{0}.txt' -f $finishedAt.ToString('yyyyMMdd_HHmmss')
    )

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('DRDirect PC Cleaner - Maintenance Report')
    [void]$builder.AppendLine(('Started:  {0}' -f $StartedAt.ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$builder.AppendLine(('Finished: {0}' -f $finishedAt.ToString('yyyy-MM-dd HH:mm:ss')))
    $elapsed = $finishedAt - $StartedAt
    [void]$builder.AppendLine(('Total time it took: {0:00}:{1:00}:{2:00}' -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds))
    [void]$builder.AppendLine('')

    [void]$builder.AppendLine('Selected tasks:')
    foreach ($id in @($TaskId)) {
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            [void]$builder.AppendLine(('  - {0}' -f $id))
        }
    }

    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('Results:')

    if (@($Events).Count -eq 0) {
        [void]$builder.AppendLine('  No task events were returned.')
    }
    else {
        foreach ($eventItem in @($Events)) {
            $eventTime = Get-DRPropertyValue -InputObject $eventItem -Name 'Timestamp'
            if ($null -eq $eventTime) {
                $eventTime = Get-DRPropertyValue -InputObject $eventItem -Name 'Time'
            }

            $eventTask = Get-DRPropertyValue -InputObject $eventItem -Name 'TaskId'
            $eventState = Get-DRPropertyValue -InputObject $eventItem -Name 'State'
            $eventMessage = Get-DRPropertyValue -InputObject $eventItem -Name 'Message'

            $timeText = ''
            if ($null -ne $eventTime) {
                try {
                    $timeText = ([datetime]$eventTime).ToString('HH:mm:ss')
                }
                catch {
                    $timeText = [string]$eventTime
                }
            }

            if ([string]::IsNullOrWhiteSpace([string]$eventTask)) {
                $eventTask = 'general'
            }
            if ([string]::IsNullOrWhiteSpace([string]$eventState)) {
                $eventState = 'Information'
            }
            if ([string]::IsNullOrWhiteSpace([string]$eventMessage)) {
                $eventMessage = [string]$eventItem
            }

            $prefix = if ([string]::IsNullOrWhiteSpace($timeText)) {
                ''
            }
            else {
                '[{0}] ' -f $timeText
            }

            [void]$builder.AppendLine(
                ('  {0}{1} | {2} | {3}' -f $prefix, $eventTask, $eventState, $eventMessage)
            )
        }
    }

    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($reportPath, $builder.ToString(), $encoding)

    return $reportPath
}

function Complete-RunPlan {
    [string[]]$selectedIds = @(
        $catalog |
            Where-Object { $selection[$_.Id] } |
            ForEach-Object { [string]$_.Id }
    )

    [object[]]$eventSnapshot = @(
        $runEvents | ForEach-Object { $_ }
    )

    $failed = @(
        $eventSnapshot | Where-Object { $_.State -eq 'Failed' }
    ).Count

    $report = $null
    $reportWarning = $null

    try {
        # Pass plain arrays to the engine report function. Generic List objects can
        # select an incompatible .NET overload in Windows PowerShell/PS2EXE.
        $engineReportOutput = @(
            Write-DRRunReport `
                -Events $eventSnapshot `
                -TaskId $selectedIds `
                -StartedAt ([datetime]$runStartedAt)
        )

        $reportCandidates = @(
            $engineReportOutput |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        if ($reportCandidates.Count -gt 0) {
            $report = $reportCandidates[-1]
        }

        if ([string]::IsNullOrWhiteSpace([string]$report)) {
            throw 'The engine report writer returned no report path.'
        }
    }
    catch {
        $reportWarning = $_.Exception.Message

        try {
            $report = Write-DRSafeRunReport `
                -Events $eventSnapshot `
                -TaskId $selectedIds `
                -StartedAt ([datetime]$runStartedAt)
        }
        catch {
            $fallbackError = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($reportWarning)) {
                $reportWarning = $fallbackError
            }
            else {
                $reportWarning = $reportWarning + ' Fallback report error: ' + $fallbackError
            }
            $report = $null
        }
    }

    $onlyChecks = (@($selectedIds | Where-Object { $id = $_; @($catalog | Where-Object { $_.Id -eq $id -and (([bool]$_.Destructive) -or $_.Category -eq 'AI') }).Count -gt 0 }).Count -eq 0)
    if ($cancelAfterTask) {
        $ui.ProgressHeading.Text = 'Plan stopped safely'
        $ui.ProgressMessage.Text = 'No additional tasks were started.'
    }
    elseif ($failed) {
        $ui.ProgressHeading.Text = 'Maintenance finished with warnings'
        $ui.ProgressMessage.Text = "$($selectedIds.Count) selected task(s) finished."
    }
    else {
        $ui.ProgressHeading.Text = if ($onlyChecks) { 'Check complete' } else { 'Maintenance complete' }
        $ui.ProgressMessage.Text = if ($onlyChecks) { 'The result is shown below. Nothing was changed on this PC.' } else { "$($selectedIds.Count) selected task(s) finished." }
    }

    $ui.ProgressPercent.Text = '100%'
    $ui.OverallProgress.Value = 100
    $ui.CancelPlanButton.Content = 'Return to dashboard'
    $ui.CancelPlanButton.IsEnabled = $true
    $ui.CancelPlanButton.Tag = 'Done'

    # RESTART PROMPT ALL LEVELS FIX v1.8
    # Every completed Safe, Medium, or Advanced plan asks about restart and
    # starts the 90-second automatic restart countdown.
    if ($ui.CleaningAnimation) { $ui.CleaningAnimation.Visibility='Collapsed' }
    if (-not $cancelAfterTask) { Invoke-DRCleanReveal -TaskCount $selectedIds.Count -ChecksOnly:([bool]$onlyChecks) }
    $needsRestart = (-not $cancelAfterTask) -and (@($selectedIds | Where-Object { $script:DRNoRestartTaskIds -notcontains $_ }).Count -gt 0)

    $ui.RestartButton.Visibility = if ($needsRestart) {
        'Visible'
    }
    else {
        'Collapsed'
    }
    $ui.RestartButton.IsEnabled = $true
    $ui.RestartButton.Content = 'Restart now'
    if ($needsRestart) {
        $ui.CancelPlanButton.Content = 'Restart later'
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$report)) {
        $ui.ProgressSafetyText.Text = "Report: $report"
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$reportWarning)) {
        $ui.ProgressSafetyText.Text = "Maintenance finished, but the report could not be saved: $reportWarning"
    }
    else {
        $ui.ProgressSafetyText.Text = 'Maintenance finished. No report path was returned.'
    }

    # History display must never crash the application's main ShowDialog loop.
    try {
        Show-History
        Show-DashboardHistory
    }
    catch {
        $historyError = $_.Exception.Message
        $ui.ProgressSafetyText.Text = $ui.ProgressSafetyText.Text + " History refresh warning: $historyError"
    }

    Set-Variable -Name restartStillNeeded -Value ([bool]($needsRestart -and -not $cancelAfterTask)) -Scope Script
    if ($needsRestart -and -not $cancelAfterTask) {
        # A full hour. The countdown often sits behind a fullscreen game or a
        # document, so the person may not see it immediately; an hour is enough
        # to finish what they are doing and restart on their own terms. The
        # window also pushes itself to the front - see Show-DRRestartNotice -
        # so the restart is never a surprise.
        Start-DRRestartCountdown -Seconds $script:restartDelaySeconds -BaseMessage $ui.ProgressSafetyText.Text
    }
}


function Show-DashboardHistory {
    <#
        .SYNOPSIS
            The three most recent runs, on the Dashboard.
        .DESCRIPTION
            The same reports the History page lists, surfaced where the app
            opens. Never throws: a Dashboard that will not draw is worse than
            one without this panel.
    #>
    if (-not $ui.DashboardHistoryList) { return }
    $ui.DashboardHistoryList.Children.Clear()

    $files = @()
    try {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
            $reportRoot = Join-Path -Path $localAppData -ChildPath 'DRDirect PC Cleaner\Reports'
            if (Test-Path -LiteralPath $reportRoot -PathType Container) {
                $files = @(
                    Get-ChildItem -LiteralPath $reportRoot -Filter 'Maintenance_Report_*.txt' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 3
                )
            }
        }
    } catch { }

    if (@($files).Count -eq 0) {
        $empty = New-Object Windows.Controls.TextBlock
        $empty.Text = 'Nothing has been run on this PC yet. Analysis and cleanup results will be listed here.'
        $empty.Foreground = '#667085'
        $empty.TextWrapping = 'Wrap'
        $empty.Margin = '0,2,0,2'
        [void]$ui.DashboardHistoryList.Children.Add($empty)
        return
    }

    foreach ($file in $files) {
        $row = New-Object Windows.Controls.Border -Property @{
            BorderBrush = '#EDF1F7'; BorderThickness = '0,0,0,1'; Padding = '0,9'
        }
        $grid = New-Object Windows.Controls.Grid
        $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='*' }))
        $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='Auto' }))

        $when = $file.LastWriteTime
        $label = New-Object Windows.Controls.TextBlock -Property @{
            Text = $when.ToString('dddd d MMMM, HH:mm'); FontWeight = 'SemiBold'
        }
        $ago = (Get-Date) - $when
        $agoText = if ($ago.TotalDays -ge 2) { ('{0} days ago' -f [int]$ago.TotalDays) }
                   elseif ($ago.TotalDays -ge 1) { 'yesterday' }
                   elseif ($ago.TotalHours -ge 1) { ('{0} hours ago' -f [int]$ago.TotalHours) }
                   else { 'less than an hour ago' }
        $right = New-Object Windows.Controls.TextBlock -Property @{
            Text = $agoText; Foreground = '#667085'; VerticalAlignment = 'Center'
        }
        [System.Windows.Controls.Grid]::SetColumn($right, 1)
        [void]$grid.Children.Add($label)
        [void]$grid.Children.Add($right)
        $row.Child = $grid
        [void]$ui.DashboardHistoryList.Children.Add($row)
    }
}

function New-DRHardwareCard {
    param([string]$Heading)
    $card = New-Object Windows.Controls.Border
    $card.Style = $window.Resources['Card']
    $card.Margin = '0,0,0,14'
    $panel = New-Object Windows.Controls.StackPanel
    $card.Child = $panel

    $title = New-Object Windows.Controls.TextBlock
    $title.Text = $Heading
    $title.FontSize = 16
    $title.FontWeight = 'SemiBold'
    $title.Margin = '0,0,0,10'
    [void]$panel.Children.Add($title)

    [void]$ui.HardwareList.Children.Add($card)
    return $panel
}

function Add-DRHardwareRow {
    param($Panel, [string]$Label, [string]$Value, [string]$Note = '')
    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '0,4'

    $labelColumn = New-Object Windows.Controls.ColumnDefinition
    $labelColumn.Width = '190'
    [void]$grid.ColumnDefinitions.Add($labelColumn)
    $valueColumn = New-Object Windows.Controls.ColumnDefinition
    $valueColumn.Width = '*'
    [void]$grid.ColumnDefinitions.Add($valueColumn)

    $labelText = New-Object Windows.Controls.TextBlock
    $labelText.Text = $Label
    $labelText.Foreground = '#667085'
    $labelText.FontSize = 13
    $labelText.TextWrapping = 'Wrap'
    [void]$grid.Children.Add($labelText)

    $stack = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($stack, 1)

    $valueText = New-Object Windows.Controls.TextBlock
    $valueText.Text = $Value
    $valueText.FontSize = 14
    $valueText.TextWrapping = 'Wrap'
    [void]$stack.Children.Add($valueText)

    if ($Note) {
        $noteText = New-Object Windows.Controls.TextBlock
        $noteText.Text = $Note
        $noteText.Foreground = '#8A94A6'
        $noteText.FontSize = 12
        $noteText.TextWrapping = 'Wrap'
        $noteText.Margin = '0,2,0,0'
        [void]$stack.Children.Add($noteText)
    }

    [void]$grid.Children.Add($stack)
    [void]$Panel.Children.Add($grid)
}

function Show-Hardware {
    $ui.HardwareList.Children.Clear()

    $items = @()
    try { $items = @(Get-DRHardwareInventory) } catch { $items = @() }

    if (-not $items.Count) {
        $panel = New-DRHardwareCard 'Hardware'
        Add-DRHardwareRow $panel 'Nothing reported' 'Windows did not return any hardware details on this PC.'
        return
    }

    $sections = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) { if (-not $sections.Contains($item.Section)) { [void]$sections.Add($item.Section) } }

    foreach ($section in $sections) {
        $panel = New-DRHardwareCard $section
        foreach ($item in $items) {
            if ($item.Section -ne $section) { continue }
            Add-DRHardwareRow $panel $item.Label $item.Value $item.Note
        }
    }

    # The driver card starts empty; the check needs the internet, so it is never automatic.
    $script:driverPanel = New-DRHardwareCard 'Driver updates'
    Add-DRHardwareRow $script:driverPanel 'Not checked yet' 'Use "Check for driver updates" above. This asks Microsoft what drivers are available for this PC and installs nothing.'
}

function Start-DRDriverCheck {
    if (-not $script:driverPanel) { return }
    $script:driverPanel.Children.RemoveRange(1, $script:driverPanel.Children.Count - 1)
    Add-DRHardwareRow $script:driverPanel 'Checking' 'Asking Microsoft what drivers are available for this PC. This can take up to a minute.'
    $ui.CheckDriversButton.IsEnabled = $false
    # Let the message paint before the search blocks the interface.
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Render)

    $status = Get-DRDriverUpdateStatus

    $script:driverPanel.Children.RemoveRange(1, $script:driverPanel.Children.Count - 1)
    if ($status.Error) {
        Add-DRHardwareRow $script:driverPanel 'Could not check' 'Windows could not reach the update service. Check the internet connection and try again.' $status.Error
    } elseif ($status.Available -eq 0) {
        Add-DRHardwareRow $script:driverPanel 'Up to date' 'Microsoft has no newer drivers for this PC.'
    } else {
        Add-DRHardwareRow $script:driverPanel 'Updates available' ('{0} driver update(s) are available for this PC.' -f $status.Available) 'Install these from Settings, Windows Update, Advanced options, Optional updates. This app does not install them.'
        foreach ($title in $status.Titles) {
            Add-DRHardwareRow $script:driverPanel '' $title
        }
    }
    $ui.CheckDriversButton.IsEnabled = $true
}

function Show-History {
    $ui.HistoryList.Children.Clear()

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        return
    }

    $reportRoot = Join-Path -Path $localAppData -ChildPath 'DRDirect PC Cleaner\Reports'
    if (-not (Test-Path -LiteralPath $reportRoot -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($reportRoot)
    }

    $files = @(
        Get-ChildItem `
            -LiteralPath $reportRoot `
            -Filter 'Maintenance_Report_*.txt' `
            -File `
            -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 8
    )

    if ($files.Count -eq 0) {
        $emptyText = New-Object Windows.Controls.TextBlock
        $emptyText.Text = 'No maintenance reports yet.'
        $emptyText.Foreground = '#667085'
        $emptyText.Margin = '0,8'
        [void]$ui.HistoryList.Children.Add($emptyText)
        return
    }

    $rowIndex = 0
    foreach ($file in $files) {
        $row = New-Object Windows.Controls.Border
        $row.Style = $window.Resources['HistoryRow']

        $grid = New-Object Windows.Controls.Grid

        $mainColumn = New-Object Windows.Controls.ColumnDefinition
        $mainColumn.Width = '*'
        [void]$grid.ColumnDefinitions.Add($mainColumn)

        $buttonColumn = New-Object Windows.Controls.ColumnDefinition
        $buttonColumn.Width = 'Auto'
        [void]$grid.ColumnDefinitions.Add($buttonColumn)

        $deleteColumn = New-Object Windows.Controls.ColumnDefinition
        $deleteColumn.Width = 'Auto'
        [void]$grid.ColumnDefinitions.Add($deleteColumn)

        $panel = New-Object Windows.Controls.StackPanel

        $panel.VerticalAlignment = 'Center'

        $dateText = New-Object Windows.Controls.TextBlock
        $dateText.Text = $file.LastWriteTime.ToString('MMM d, yyyy  ·  h:mm tt')
        $dateText.FontWeight = 'SemiBold'
        $dateText.FontSize = 15
        [void]$panel.Children.Add($dateText)

        $nameText = New-Object Windows.Controls.TextBlock
        $nameText.Text = $file.Name
        $nameText.Foreground = '#8A94A6'
        $nameText.FontSize = 11
        $nameText.Margin = '0,3,0,0'
        [void]$panel.Children.Add($nameText)

        $button = New-Object Windows.Controls.Button
        $button.Content = 'Open'
        $button.Style = $window.Resources['SecondaryButton']
        $button.Padding = '16,8'
        $button.VerticalAlignment = 'Center'
        $button.Tag = $file.FullName
        $button.Add_Click({
            param($sender, $eventArgs)

            $target = [string]$sender.Tag
            if (-not [string]::IsNullOrWhiteSpace($target)) {
                # Always do something visible, never run a program. Only viewable
                # files (documents, images, media) are opened, with a reveal
                # fallback; everything else is shown in its folder.
                $openable = @(
                    '.txt','.md','.log','.csv','.tsv','.rtf','.pdf',
                    '.doc','.docx','.xls','.xlsx','.ppt','.pptx','.odt','.ods','.odp',
                    '.jpg','.jpeg','.png','.gif','.bmp','.webp','.tif','.tiff','.svg','.heic','.ico',
                    '.mp3','.wav','.flac','.aac','.ogg','.m4a','.wma',
                    '.mp4','.mov','.avi','.mkv','.webm','.wmv','.m4v',
                    '.html','.htm','.xml','.json')
                $ext = [System.IO.Path]::GetExtension($target).ToLowerInvariant()
                if ($openable -contains $ext) {
                    try { Start-Process -FilePath $target | Out-Null }
                    catch { Start-Process explorer.exe -ArgumentList "/select,`"$target`"" | Out-Null }
                } else {
                    Start-Process explorer.exe -ArgumentList "/select,`"$target`"" | Out-Null
                }
            }
        })

        $deleteButton = New-Object Windows.Controls.Button
        $deleteButton.Content = 'Delete'
        $deleteButton.Style = $window.Resources['DangerButton']
        $deleteButton.Padding = '16,8'
        $deleteButton.VerticalAlignment = 'Center'
        $deleteButton.Margin = '8,0,0,0'
        $deleteButton.Tag = $file.FullName
        $deleteButton.Add_Click({
            param($sender, $eventArgs)

            $target = [string]$sender.Tag
            if ([string]::IsNullOrWhiteSpace($target)) { return }

            $answer = [Windows.MessageBox]::Show("Delete this report?`n`n$([IO.Path]::GetFileName($target))", 'DRDirect PC Cleaner', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }

            try {
                Remove-Item -LiteralPath $target -Force -ErrorAction Stop
            } catch {
                [void][Windows.MessageBox]::Show("Could not delete the report.`n`n$($_.Exception.Message)", 'DRDirect PC Cleaner', 'OK', 'Error')
            }

            Show-History
            Show-DashboardHistory
        })

        [Windows.Controls.Grid]::SetColumn($button, 1)
        [Windows.Controls.Grid]::SetColumn($deleteButton, 2)
        [void]$grid.Children.Add($panel)
        [void]$grid.Children.Add($button)
        [void]$grid.Children.Add($deleteButton)

        $row.Child = $grid
        [void]$ui.HistoryList.Children.Add($row)

        Start-DRFadeIn -Element $row -Shift 10 -Seconds 0.26 -Delay ([Math]::Min($rowIndex * 0.05, 0.4))
        $rowIndex++
    }
}


$pollTimer = New-Object Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$pollTimer.Add_Tick({
    # While a clean-up or check is running, the two one-click checks are greyed out and
    # cannot be pressed: a second run would wipe the first one's progress.
    try {
        $busyNow = Test-DRRunBusy
        # The progress box: always shows where a run is up to, on every page, and takes
        # you back to the progress page when clicked.
        if ($busyNow) { $script:DRWasBusy = $true }
        elseif ($script:DRWasBusy) {
            $script:DRWasBusy = $false; $script:DRFinishedUnseen = $true
            if ($script:DRSavedSelection) {
                foreach ($key in @($script:DRSavedSelection.Keys)) { $selection[$key] = $script:DRSavedSelection[$key] }
                $script:DRSavedSelection = $null
            }
        }
        if ($script:currentCategory -eq 'Progress') { $script:DRFinishedUnseen = $false }
        if ($busyNow -and $script:currentCategory -ne 'Progress') {
            $ui.RunStrip.Visibility = 'Visible'
            $ui.RunStripTitle.Text = 'Working... ' + $ui.ProgressPercent.Text
            $ui.RunStripDetail.Text = [string]$ui.ProgressMessage.Text
            $ui.RunStripBar.Value = [double]$ui.OverallProgress.Value
        } elseif ($script:DRFinishedUnseen) {
            $ui.RunStrip.Visibility = 'Visible'
            $ui.RunStripTitle.Text = [string][char]0x2714 + '  Finished. Click to see it'
            $ui.RunStripDetail.Text = [string]$ui.ProgressHeading.Text
            $ui.RunStripBar.Value = 100
        } else {
            $ui.RunStrip.Visibility = 'Collapsed'
        }
        foreach ($navName in @('NavHealth', 'NavMemory')) {
            $locked = ($script:DRNavState.ContainsKey($navName) -and $script:DRNavState[$navName] -eq 'Good')
            $wantEnabled = ((-not $busyNow) -and (-not $locked))
            if ($ui[$navName].IsEnabled -ne $wantEnabled) { $ui[$navName].IsEnabled = $wantEnabled }
            $wantOpacity = if ($busyNow) { 0.35 } else { 1 }
            if ($ui[$navName].Opacity -ne $wantOpacity) { $ui[$navName].Opacity = $wantOpacity }
        }
    } catch { }
    if (-not $script:activeAsync) { return }
    Update-DRElapsedDisplay
    while ($script:activeOutput -and $script:activeOutputIndex -lt $script:activeOutput.Count) {
        $item = $script:activeOutput[$script:activeOutputIndex]; $script:activeOutputIndex++
        if ($script:analysisMode) {
            if ($item.TaskId) {
                $analysis[$item.TaskId] = $item
                Set-Variable -Name analysisDone -Value ($script:analysisDone + 1) -Scope Script
                $label = @($catalog | Where-Object Id -eq $item.TaskId | Select-Object -First 1).Name
                if (-not $label) { $label = $item.TaskId }
                Set-AnalysisProgress "Checked $label"
            }
        } elseif ($item.State) {
            $runEvents.Add($item); Set-ProgressRowState $item.TaskId $item.State $item.Message; $ui.ProgressMessage.Text=$item.Message
        }
    }
    if ($script:activeAsync.IsCompleted) {
        $completedOutput = @()
        try { $completedOutput = @($script:activePowerShell.EndInvoke($script:activeAsync)) } catch {}
        foreach ($item in $completedOutput) {
            if ($script:analysisMode) {
                if ($item.TaskId) {
                $analysis[$item.TaskId] = $item
                Set-Variable -Name analysisDone -Value ($script:analysisDone + 1) -Scope Script
                $label = @($catalog | Where-Object Id -eq $item.TaskId | Select-Object -First 1).Name
                if (-not $label) { $label = $item.TaskId }
                Set-AnalysisProgress "Checked $label"
            }
            } elseif ($item.State) {
                $runEvents.Add($item); Set-ProgressRowState $item.TaskId $item.State $item.Message; $ui.ProgressMessage.Text=$item.Message
            }
        }
        $wasAnalysis=$script:analysisMode; Stop-EngineCall
        if ($wasAnalysis) {
            $ui.OverlayProgress.Value=100; $ui.OverlayPercent.Text='100%'
            $ui.OverlayTitle.Text='Analysis complete'
            $ui.OverlayMessage.Text='All checks finished. Nothing was changed. Click View results to choose what to clean.'
            $ui.OverlayContinueButton.Visibility='Visible'
            $ui.WindowsStatusText.Text='Analysis complete'
        } else {
            $completed = @($runEvents | Where-Object { $_.TaskId -eq $activeTaskId -and $_.State -in @('Completed','Failed') } | Select-Object -Last 1)
            if (-not $completed) { $failure=New-DREvent -TaskId $activeTaskId -State Failed -Message 'The maintenance task ended without a final status.'; $runEvents.Add($failure); Set-ProgressRowState $activeTaskId 'Failed' $failure.Message }
            $total=@($catalog | Where-Object { $selection[$_.Id] }).Count; $finished=$total-$runQueue.Count; $percent=[int](100*$finished/[Math]::Max(1,$total)); $ui.OverallProgress.Value=$percent; $ui.ProgressPercent.Text="$percent%"
            Start-NextTask
        }
    }
})
$pollTimer.Start()

foreach ($task in $catalog) { $selection[$task.Id] = $false }
Set-CleanupPresetVisual -Preset 'Custom'

$ui.TitleDragArea.Add_MouseLeftButtonDown({
    if ($_.ClickCount -eq 2) {
        if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) { $window.WindowState = [System.Windows.WindowState]::Normal }
        else { $window.WindowState = [System.Windows.WindowState]::Maximized }
    } else {
        $window.DragMove()
    }
})
$ui.TitleMinButton.Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
# A borderless window (WindowStyle="None") maximizes to the whole monitor
# rather than the usable work area, so it hangs about 8px off every edge and
# over the taskbar - which is exactly where the minimize, maximize and close
# buttons live. Clamping MaxWidth/MaxHeight to the work area of the monitor the
# window is actually on keeps those buttons on screen, on any monitor.
function Set-DRWorkAreaLimit {
    try {
        $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $screen = if ($handle -ne [IntPtr]::Zero) {
            [System.Windows.Forms.Screen]::FromHandle($handle)
        } else {
            [System.Windows.Forms.Screen]::PrimaryScreen
        }

        $source = [System.Windows.PresentationSource]::FromVisual($window)
        $scaleX = 1.0; $scaleY = 1.0
        if ($source -and $source.CompositionTarget) {
            $scaleX = $source.CompositionTarget.TransformToDevice.M11
            $scaleY = $source.CompositionTarget.TransformToDevice.M22
        }
        if ($scaleX -le 0) { $scaleX = 1.0 }
        if ($scaleY -le 0) { $scaleY = 1.0 }

        $window.MaxWidth = [Math]::Floor($screen.WorkingArea.Width / $scaleX)
        $window.MaxHeight = [Math]::Floor($screen.WorkingArea.Height / $scaleY)
    } catch { }
}

try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }

# The window has no title bar, so the only edge Windows can grab is a hairline.
# A wider invisible resize border all round lets people drag any edge or corner
# to make it bigger or smaller. The title bar is still dragged by the code above.
try {
    $drChrome = New-Object System.Windows.Shell.WindowChrome
    $drChrome.CaptionHeight = 0
    $drChrome.ResizeBorderThickness = New-Object System.Windows.Thickness(8)
    $drChrome.GlassFrameThickness = New-Object System.Windows.Thickness(0)
    $drChrome.CornerRadius = New-Object System.Windows.CornerRadius(0)
    $drChrome.UseAeroCaptionButtons = $false
    [System.Windows.Shell.WindowChrome]::SetWindowChrome($window, $drChrome)
} catch { }
$window.Add_SourceInitialized({ Set-DRWorkAreaLimit })
$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) { Set-DRWorkAreaLimit }
    $ui.TitleMaxButton.Content = if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) { '❐' } else { '□' }
})
$window.Add_LocationChanged({ if ($window.WindowState -ne [System.Windows.WindowState]::Maximized) { Set-DRWorkAreaLimit } })

$ui.TitleMaxButton.Add_Click({
    if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
        $window.WindowState = [System.Windows.WindowState]::Normal
        $ui.TitleMaxButton.Content = '□'
    } else {
        $window.WindowState = [System.Windows.WindowState]::Maximized
        $ui.TitleMaxButton.Content = '❐'
    }
})
$ui.TitleCloseButton.Add_Click({ $window.Close() })
$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) { $ui.TitleMaxButton.Content = '❐' }
    else { $ui.TitleMaxButton.Content = '□' }
})

$ui.NavDashboard.Add_Click({ Set-Page 'Dashboard' })
$ui.NavCleanup.Add_Click({ Set-Page 'Cleanup' })
$ui.NavRepair.Add_Click({ Set-Page 'Repair' })
$ui.NavSecurity.Add_Click({ Set-Page 'Security' })
# A recent result stays on the menu between sessions; a small red dot means a check is due.
Restore-DRCheckMarks
# One click, one check: these two menu items run just that check straight away.
$ui.RunStrip.Add_MouseLeftButtonUp({ Set-Page 'Progress' })
$ui.NavHealth.Add_Click({ Invoke-DRAIRunNow -TaskIds @('health.drive-check') })
$ui.NavMemory.Add_Click({ Invoke-DRAIRunNow -TaskIds @('health.ram-check') })
$ui.NavSpeed.Add_Click({ Set-Page 'Speed' })
$ui.NavHardware.Add_Click({ Set-Page 'Hardware' })
$ui.CheckDriversButton.Add_Click({ Start-DRDriverCheck })

function Start-DRWingetWindow {
    param([string]$WingetArgs, [string]$StartedText)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $answer = [Windows.MessageBox]::Show("winget (Windows Package Manager) is not installed on this PC.`n`nInstall it now? The Cleaner downloads Microsoft's own installer (about 20 MB) from aka.ms/getwinget, installs it, then continues.", 'DRDirect PC Cleaner',
            [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) {
            $ui.AppUpdatesStatus.Text = 'winget is not installed, so apps were not updated.'
            return
        }
        # One console window does everything so progress is visible. If the install
        # fails, it opens Microsoft's download page and the Store page instead.
        $installScript = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
try {
    Write-Host 'Downloading winget from Microsoft...'
    `$file = Join-Path `$env:TEMP 'DRDirect-winget.msixbundle'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile `$file -UseBasicParsing
    Write-Host 'Installing winget...'
    Add-AppxPackage -Path `$file
    Remove-Item -LiteralPath `$file -Force -ErrorAction SilentlyContinue
    `$exe = Join-Path `$env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    for (`$i = 0; `$i -lt 15 -and -not (Test-Path -LiteralPath `$exe); `$i++) { Start-Sleep -Seconds 1 }
    Write-Host 'winget is installed.'
    Write-Host ''
    & `$exe $WingetArgs
} catch {
    Write-Host ('Could not install winget: ' + `$_.Exception.Message) -ForegroundColor Yellow
    Write-Host 'Opening Microsoft''s download page so you can install it by hand.'
    Start-Process 'https://aka.ms/getwinget'
}
Write-Host ''
Read-Host 'Press Enter to close this window'
"@
        try {
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($installScript))
            Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded | Out-Null
            $ui.AppUpdatesStatus.Text = 'Installing winget from Microsoft in a console window. It then runs the update by itself.'
        } catch {
            $ui.AppUpdatesStatus.Text = "Could not start the winget install: $($_.Exception.Message)"
        }
        return
    }
    try {
        # Own console window so progress is visible; 'pause' keeps it open to read the result.
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c winget $WingetArgs & echo. & pause" | Out-Null
        $ui.AppUpdatesStatus.Text = $StartedText
    } catch {
        $ui.AppUpdatesStatus.Text = "Could not start winget: $($_.Exception.Message)"
    }
}

$ui.ListAppUpdatesButton.Add_Click({
    Start-DRWingetWindow 'upgrade --source winget' 'Listing available updates in a console window. Nothing is installed.'
})
function Start-DRFlashyUpgrade {
    # Colourful winget upgrade in its own PowerShell window (live progress, per-app timeout).
    # The script is written to %TEMP% as UTF-8 with BOM so Windows PowerShell reads the emoji correctly.
    $flashy = @'
# Flashy winget upgrade --all  (live progress, per-package timeout)
# Usage: .\winget-upgrade-all.ps1 [-IncludeUnknown] [-NoAnim] [-TimeoutMinutes 10]
param([switch]$IncludeUnknown, [switch]$NoAnim, [int]$TimeoutMinutes = 10)

$ESC = [char]27
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function RGB($r, $g, $b, $text) { "$ESC[38;2;${r};${g};${b}m$text$ESC[0m" }
function Hue($i, $n) {
    $h = ($i / [math]::Max($n, 1)) * 6
    $x = [int](255 * (1 - [math]::Abs(($h % 2) - 1)))
    switch ([int][math]::Floor($h) % 6) {
        0 { 255, $x, 0 } 1 { $x, 255, 0 } 2 { 0, 255, $x }
        3 { 0, $x, 255 } 4 { $x, 0, 255 } default { 255, 0, $x }
    }
}
function Rainbow($text, $shift = 0) {
    $n = $text.Length; $out = ''
    for ($i = 0; $i -lt $n; $i++) {
        $c = Hue (($i + $shift) % $n) $n
        $out += RGB $c[0] $c[1] $c[2] $text[$i]
    }
    $out
}

$banner = @(
    '  __        _____ _   _  ____ _____ _____   _   _ ____   ____ ____      _    ____  _____ ',
    '  \ \      / /_ _| \ | |/ ___| ____|_   _| | | | |  _ \ / ___|  _ \    / \  |  _ \| ____|',
    '   \ \ /\ / / | ||  \| | |  _|  _|   | |   | | | | |_) | |  _| |_) |  / _ \ | | | |  _|  ',
    '    \ V  V /  | || |\  | |_| | |___  | |   | |_| |  __/| |_| |  _ <  / ___ \| |_| | |___ ',
    '     \_/\_/  |___|_| \_|\____|_____| |_|    \___/|_|    \____|_| \_\/_/   \_\____/|_____|'
)

try { Clear-Host } catch {}
$frames = if ($NoAnim) { 1 } else { 24 }
for ($f = 0; $f -lt $frames; $f++) {
    if ($f -gt 0) { try { [Console]::SetCursorPosition(0, 0) } catch {} }
    Write-Host ''
    foreach ($line in $banner) { Write-Host (Rainbow $line ($f * 3)) }
    Write-Host ''
    if (-not $NoAnim) { Start-Sleep -Milliseconds 40 }
}
Write-Host (Rainbow ('=' * 90))
Write-Host ''

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host (RGB 255 60 90 '💥 winget not found. Install "App Installer" from the Microsoft Store.')
    exit 1
}

# ---- 1. find what needs upgrading -------------------------------------------
Write-Host (RGB 0 255 200 '🔎 Checking for upgrades...')
$listArgs = @('upgrade', '--accept-source-agreements')
if ($IncludeUnknown) { $listArgs += '--include-unknown' }
$raw = (& winget @listArgs 2>&1 | Out-String) -split "`r?`n"

$pkgs = @(); $idCol = -1; $verCol = -1; $inTable = $false
foreach ($l in $raw) {
    $l = ($l -split "`r")[-1]                       # drop spinner prefixes
    if ($l -match '^Name\s+Id\s+Version') {
        if ($pkgs.Count -gt 0) { break }            # 2nd table = needs explicit targeting
        $idCol = $l.IndexOf('Id'); $verCol = $l.IndexOf('Version'); $inTable = $false; continue
    }
    if ($idCol -ge 0 -and $l -match '^-{5,}') { $inTable = $true; continue }
    if ($inTable) {
        if ($l -match 'upgrades? available' -or $l.Trim() -eq '') { $inTable = $false; continue }
        if ($l.Length -gt $verCol) {
            $pkgs += [pscustomobject]@{
                Name = $l.Substring(0, $idCol).Trim()
                Id   = $l.Substring($idCol, $verCol - $idCol).Trim()
            }
        }
    }
}

# Apps left out on purpose (Warp updates itself and its download stalls).
$skipIds = @('Warp.Warp')
foreach ($s in @($pkgs | Where-Object { $skipIds -contains $_.Id })) {
    Write-Host (RGB 150 150 255 "⏭️  Skipping $($s.Name) [$($s.Id)]")
}
$pkgs = @($pkgs | Where-Object { $skipIds -notcontains $_.Id })
if ($pkgs.Count -eq 0) {
    Write-Host (RGB 150 150 255 '😎 Everything is already up to date!')
    exit 0
}

Write-Host (RGB 255 160 0 "📦 $($pkgs.Count) packages to upgrade:")
$pkgs | ForEach-Object { Write-Host (RGB 255 0 200 "   ✨ $($_.Name) ") -NoNewline; Write-Host (RGB 150 150 255 "[$($_.Id)]") }
Write-Host ''

$wingetExe = (Get-Command winget).Source
# ---- 2. upgrade each one with live winget progress --------------------------
$ok = @(); $fail = @(); $start = Get-Date; $i = 0
foreach ($p in $pkgs) {
    $i++
    Write-Host (Rainbow ('-' * 90))
    Write-Host (RGB 255 230 0 "⚡ [$i/$($pkgs.Count)] $($p.Name)") -NoNewline
    Write-Host (RGB 150 150 255 "  [$($p.Id)]  (timeout ${TimeoutMinutes}m)")

    $a = @('upgrade', '--id', $p.Id, '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements')
    $proc = Start-Process $wingetExe -ArgumentList $a -NoNewWindow -PassThru   # shares console => real progress bar
    $null = $proc.Handle   # without this, ExitCode comes back empty after a timed WaitForExit
    $done = $proc.WaitForExit($TimeoutMinutes * 60000)
    if (-not $done) {
        try { Stop-Process -Id $proc.Id -Force } catch {}
        Write-Host (RGB 255 60 90 "⏰ $($p.Name) timed out after ${TimeoutMinutes}m - skipped")
        $fail += "$($p.Name) (timeout)"
    }
    elseif ($proc.ExitCode -eq -1978335090) {
        # Installed with a different installer type than winget updates with (e.g. an old Store copy).
        # Nothing is broken and the app is untouched, so it is not reported as a problem.
    }
    elseif ($proc.ExitCode -eq 0) {
        Write-Host (RGB 80 255 120 "✅ $($p.Name) upgraded")
        $ok += $p.Name
    }
    else {
        Write-Host (RGB 255 60 90 "💥 $($p.Name) failed (exit code $($proc.ExitCode))")
        $fail += "$($p.Name) (exit $($proc.ExitCode))"
    }
}

# ---- 3. summary -------------------------------------------------------------
$secs = [int]((Get-Date) - $start).TotalSeconds
Write-Host ''
Write-Host (Rainbow ('=' * 90))
Write-Host (RGB 80 255 120 "🎉 Done in ${secs}s") -NoNewline
Write-Host (RGB 255 230 0 "   ✅ $($ok.Count) upgraded") -NoNewline
Write-Host (RGB 255 60 90 "   💥 $($fail.Count) problems")
foreach ($f in $fail) { Write-Host (RGB 255 60 90 "   - $f") }
Write-Host (Rainbow ('=' * 90))
Write-Host ''
Read-Host 'Press Enter to close' | Out-Null

'@
    try {
        $file = Join-Path $env:TEMP 'DRDirect-Winget-Upgrade.ps1'
        [IO.File]::WriteAllText($file, $flashy, (New-Object Text.UTF8Encoding $true))
        # 'start' forces a real new console window, like the cmd route that always showed one; -NoExit keeps it open if the script stops early.
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c start "DRDirect winget upgrade" powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -File "' + $file + '"') -WindowStyle Hidden | Out-Null
        $ui.AppUpdatesStatus.Text = 'Updating apps in a colour PowerShell window. Close it when it says it has finished.'
    } catch {
        $ui.AppUpdatesStatus.Text = "Could not start the update window: $($_.Exception.Message)"
    }
}
function Invoke-DRUpdateAllApps {
    $answer = [Windows.MessageBox]::Show("This runs 'winget upgrade --all' and updates every app winget can update on this PC.`n`nSome apps may close or restart during their update. Save your work first.`n`nContinue?", 'DRDirect PC Cleaner',
        [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
    if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
    if (Get-Command winget -ErrorAction SilentlyContinue) { Start-DRFlashyUpgrade; return }
    Start-DRWingetWindow 'upgrade --all --silent --accept-source-agreements --accept-package-agreements' 'Updating apps in a console window. Close it when it says it has finished.'
}
$ui.UpdateAllAppsButton.Add_Click({ Invoke-DRUpdateAllApps })
# The sidebar item runs the update straight away (after confirming) instead of opening a page first.
$ui.NavAppUpdates.Add_Click({ Invoke-DRUpdateAllApps })

$ui.PCManagerButton.Add_Click({
    # Opens PC Manager if it is installed, otherwise its Store page. Nothing is
    # installed here; the person chooses that in the Store.
    try {
        $pcManager = Get-AppxPackage -Name 'Microsoft.MicrosoftPCManager' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pcManager) {
            # Through Explorer, so the app opens as the normal user, not elevated.
            Start-Process explorer.exe -ArgumentList 'shell:AppsFolder\Microsoft.MicrosoftPCManager_8wekyb3d8bbwe!App' | Out-Null
        } else {
            Start-Process 'ms-windows-store://pdp/?productid=9PM860492SZD' | Out-Null
        }
    }
    catch { [Windows.MessageBox]::Show("Could not open the Microsoft Store: $($_.Exception.Message)", 'DRDirect PC Cleaner') | Out-Null }
})
$ui.NavHistory.Add_Click({ Set-Page 'History' })
$script:dashLevel = 'Safe'
function Invoke-DRSafeClean { Apply-CleanupPreset -Preset 'Safe'; Show-Confirmation }
function Invoke-DRLevelClean { Apply-CleanupPreset -Preset $script:dashLevel; Show-Confirmation }
function Invoke-DRUndoAll {
    $answer = [Windows.MessageBox]::Show("This puts back every AI and browser setting the Cleaner changed on this PC, using the backups it saved.`n`nDeleted files and cleared caches cannot be brought back.`n`nContinue?", 'DRDirect PC Cleaner',
        [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
    if ($answer -eq [Windows.MessageBoxResult]::Yes) { Invoke-DRAIRunNow -TaskIds @('ai.restore') }
}
function Show-SafePlan {
    # The dashboard card lists the steps of the chosen level, from the same rule the Cleanup page uses.
    # Safe is green, Medium is blue, Advanced is red; a click springs the button and slides the steps in.
    param([string]$Level = 'Safe', [switch]$Animate)
    if (-not $ui.SafePlanList) { return }
    $script:dashLevel = $Level
    $palette = @{
        Safe     = @{ Solid = '#0E8A5F'; Soft = '#E4F6EE'; Button = 'SafeLevelSafeButton' }
        Medium   = @{ Solid = '#2554D8'; Soft = '#E6EDFC'; Button = 'SafeLevelMediumButton' }
        Advanced = @{ Solid = '#C0143C'; Soft = '#FDE6EA'; Button = 'SafeLevelAdvancedButton' }
    }
    $mine = $palette[$Level]
    $ui.SafePlanList.Children.Clear()
    $ui.SafePlanTitle.Text = switch ($Level) { 'Safe' {'What Safe mode does'} 'Medium' {'What Medium does'} default {'What Advanced does'} }
    $ui.SafePlanTitle.Foreground = $mine.Solid
    foreach ($key in 'Safe','Medium','Advanced') {
        $button = $ui[$palette[$key].Button]
        if (-not $button) { continue }
        $on = ($key -eq $Level)
        $button.Background = $(if ($on) { $palette[$key].Solid } else { $palette[$key].Soft })
        $button.Foreground = $(if ($on) { 'White' } else { $palette[$key].Solid })
        $button.BorderBrush = $palette[$key].Solid
        $button.BorderThickness = $(if ($on) { '2' } else { '1.5' })
        $button.FontWeight = $(if ($on) { 'ExtraBold' } else { 'SemiBold' })
    }
    $planTasks = @($catalog | Where-Object { $_.Category -in @('Cleanup','Repair') -and (Test-TaskInOrderedPreset -Task $_ -Preset $Level) })
    foreach ($task in $planTasks) {
        $line = New-Object Windows.Controls.StackPanel -Property @{ Margin='0,6,0,0' }
        $top = New-Object Windows.Controls.StackPanel -Property @{ Orientation='Horizontal' }
        [void]$top.Children.Add((New-Object Windows.Controls.Border -Property @{ Width=20; Height=20; CornerRadius=10; Background=$mine.Soft; Margin='0,0,10,0'; Child=(New-Object Windows.Controls.TextBlock -Property @{ Text='✓'; Foreground=$mine.Solid; FontWeight='Bold'; FontSize=12; HorizontalAlignment='Center'; VerticalAlignment='Center' }) }))
        [void]$top.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$task.Name; VerticalAlignment='Center' }))
        [void]$line.Children.Add($top)
        [void]$ui.SafePlanList.Children.Add($line)
    }
    if (-not $planTasks.Count) { [void]$ui.SafePlanList.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text='No steps are available on this PC.'; Foreground='#667085' })) }
    # Cookies are never part of a level; Advanced, the full sweep, shows them with an empty box and says why.
    $cookieTask = @($catalog | Where-Object { [string]$_.Risk -eq 'SignOut' } | Select-Object -First 1)
    if ($Level -eq 'Advanced' -and $cookieTask.Count -and $cookieTask[0]) {
        $cookieLine = New-Object Windows.Controls.StackPanel -Property @{ Margin='0,10,0,0' }
        $cookieTop = New-Object Windows.Controls.StackPanel -Property @{ Orientation='Horizontal' }
        [void]$cookieTop.Children.Add((New-Object Windows.Controls.Border -Property @{ Width=20; Height=20; CornerRadius=4; BorderBrush='#C63C3C'; BorderThickness=2; Background='White'; Margin='0,0,10,0' }))
        [void]$cookieTop.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=[string]$cookieTask[0].Name; VerticalAlignment='Center'; FontWeight='SemiBold' }))
        [void]$cookieTop.Children.Add((New-Object Windows.Controls.Border -Property @{ Background='#FDE2E2'; CornerRadius=10; Padding='8,2'; Margin='10,0,0,0'; VerticalAlignment='Center'; Child=(New-Object Windows.Controls.TextBlock -Property @{ Text='⚠  SIGNS YOU OUT'; Foreground='#A32020'; FontSize=10.5; FontWeight='Bold' }) }))
        [void]$cookieLine.Children.Add($cookieTop)
        [void]$cookieLine.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text='Left unticked on purpose. Before you tick it yourself on the Cleanup page, make sure you know all your email addresses and passwords, and keep them in a safe place. You may have to sign in again.'; Foreground='#96500A'; FontSize=12; FontWeight='SemiBold'; TextWrapping='Wrap'; Margin='30,3,0,0' }))
        [void]$ui.SafePlanList.Children.Add($cookieLine)
    }
    $ui.SafePlanNote.Text = switch ($Level) {
        'Safe'     { 'The safest steps only.' }
        'Medium'   { 'Safe steps plus more cleanup. Cookies stay off.' }
        default    { 'The full sweep. Cookies are never ticked, so nobody gets signed out.' }
    }
    $ui.SafePlanNote.Foreground = $mine.Solid
    $ui.SafePlanRunButton.Content = "Yes, go ahead with " + @{Safe='Easy';Medium='Deeper';Advanced='Expert'}[$Level]
    $ui.SafePlanRunButton.Background = $mine.Solid

    if ($Animate) {
        # Cosmetic only: wrapped so an animation problem can never stop the card working.
        try {
            $chosen = $ui[$mine.Button]
            $chosen.RenderTransformOrigin = New-Object Windows.Point(0.5, 0.5)
            $scale = New-Object Windows.Media.ScaleTransform(0.82, 0.82)
            $chosen.RenderTransform = $scale
            $spring = New-Object Windows.Media.Animation.ElasticEase
            $spring.EasingMode = 'EaseOut'; $spring.Oscillations = 2; $spring.Springiness = 5
            $pop = New-Object Windows.Media.Animation.DoubleAnimation(0.82, 1.0, [Windows.Duration][TimeSpan]::FromMilliseconds(520))
            $pop.EasingFunction = $spring
            $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $pop)
            $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $pop)
            $glide = New-Object Windows.Media.Animation.CubicEase
            $glide.EasingMode = 'EaseOut'
            $step = 0
            foreach ($line in @($ui.SafePlanList.Children)) {
                $line.Opacity = 0
                $slide = New-Object Windows.Media.TranslateTransform(-18, 0)
                $line.RenderTransform = $slide
                $delay = [TimeSpan]::FromMilliseconds(40 * $step)
                $fade = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [Windows.Duration][TimeSpan]::FromMilliseconds(260))
                $fade.BeginTime = $delay
                $move = New-Object Windows.Media.Animation.DoubleAnimation(-18.0, 0.0, [Windows.Duration][TimeSpan]::FromMilliseconds(320))
                $move.BeginTime = $delay; $move.EasingFunction = $glide
                $line.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
                $slide.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $move)
                $step++
            }
        } catch { }
    }
}
foreach ($name in 'SafeCleanButton','SafePreviewButton') { if ($ui[$name]) { $ui[$name].Add_Click({ Invoke-DRSafeClean }) } }
if ($ui.SafePlanRunButton) { $ui.SafePlanRunButton.Add_Click({ Invoke-DRLevelClean }) }
if ($ui.SafeLevelSafeButton) { $ui.SafeLevelSafeButton.Add_Click({ Show-SafePlan -Level 'Safe' -Animate }) }
if ($ui.SafeLevelMediumButton) { $ui.SafeLevelMediumButton.Add_Click({ Show-SafePlan -Level 'Medium' -Animate }) }
if ($ui.SafeLevelAdvancedButton) { $ui.SafeLevelAdvancedButton.Add_Click({ Show-SafePlan -Level 'Advanced' -Animate }) }
foreach ($name in 'UndoAllButton','UndoAllDashButton') { if ($ui[$name]) { $ui[$name].Add_Click({ Invoke-DRUndoAll }) } }
Show-SafePlan

$ui.NavDuplicates.Add_Click({ Set-Page 'Duplicates' })
$ui.NavAI.Add_Click({ Set-Page 'AI' })
$ui.NavProgress.Add_Click({ Set-Page 'Progress' })
$ui.DashboardHistoryButton.Add_Click({ Set-Page 'History' })
$ui.ScanButton.Add_Click({ Start-Analysis })
$ui.OverlayContinueButton.Add_Click({ $ui.BusyOverlay.Visibility='Collapsed'; $ui.OverlayContinueButton.Visibility='Collapsed'; Set-Page 'Cleanup' })
$ui.LastReportButton.Add_Click({ Set-Page 'History' })
$ui.ReviewButton.Add_Click({ Show-Confirmation })
$ui.PresetSafe.Add_Click({ Apply-CleanupPreset -Preset 'Safe' })
$ui.PresetMedium.Add_Click({ Apply-CleanupPreset -Preset 'Medium' })
$ui.PresetAdvanced.Add_Click({ Apply-CleanupPreset -Preset 'Advanced' })

# A free try covers the Safe scan only. The deeper ones come with a code.
try {
    if (Test-DRTrialMode) {
        foreach ($p in 'PresetMedium', 'PresetAdvanced') {
            $ui[$p].IsEnabled = $false
            $ui[$p].Opacity = 0.4
            $ui[$p].ToolTip = 'The free try covers the Safe scan. Contact DRDirect for a code to unlock the rest.'
        }
        # Which version is running should never be a question. Show it where the
    # product is named, so anyone reporting a problem can read it straight off.

    Apply-CleanupPreset -Preset 'Safe'
    }
} catch { }
$ui.ConfirmationCheck.Add_Checked({ $ui.ConfirmRunButton.IsEnabled=$true })
$ui.ConfirmationCheck.Add_Unchecked({ $ui.ConfirmRunButton.IsEnabled=$false })
$ui.ConfirmBackButton.Add_Click({ $ui.ConfirmOverlay.Visibility='Collapsed' })
$ui.ConfirmRunButton.Add_Click({ Start-RunPlan })
$ui.CancelPlanButton.Add_Click({
    if ($ui.CancelPlanButton.Tag -eq 'Done') {
        Stop-DRRestartCountdown
        $ui.RestartButton.Content = 'Restart now'
        $ui.CancelPlanButton.Tag=$null
        $ui.NavProgress.Visibility='Collapsed'
        Set-Page 'Dashboard'
    }
    elseif ($ui.CancelPlanButton.Tag -eq 'ForceStop') {
        $ui.CancelPlanButton.IsEnabled = $false
        $ui.CancelPlanButton.Tag = $null
        $ui.CancelPlanButton.Content = 'Stopping…'
        if (Stop-DRActiveChildProcess) {
            $ui.ProgressSafetyText.Text = 'Stopping the current operation. Windows will tidy up after it; the scan can be run again at any time.'
        }
        else {
            $ui.ProgressSafetyText.Text = 'The operation had already moved on. It will stop at the end of this task.'
        }
    }
    else {
        $cancelAfterTask=$true; Set-Variable -Name cancelAfterTask -Value $true -Scope Script
        $ui.CancelPlanButton.IsEnabled=$false; $ui.CancelPlanButton.Content='Stopping after current task…'
        $ui.ProgressSafetyText.Text='Cancellation requested. The current Windows operation will finish safely.'

        # Long read-only work - a Defender scan, CHKDSK, Disk Cleanup - does not
        # have to be waited out. Offer a real stop for those, but never for DISM,
        # SFC or the Windows Update reset.
        $task = $catalog | Where-Object Id -eq $script:activeTaskId | Select-Object -First 1
        if ($task) { Update-ForceStopAvailability -Task $task }
    }
})

# RESTART NOW FIX: v1.6
# Start-Process joins ArgumentList arrays without preserving quotes around comments.
# Use one correctly quoted argument string, wait for shutdown.exe, and check its exit code.
function Invoke-DRDirectRestartNow {
    [CmdletBinding()]
    param([ValidateRange(0,60)][int]$DelaySeconds = 5)

    $shutdownExe = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    if (-not (Test-Path -LiteralPath $shutdownExe -PathType Leaf)) {
        throw "Windows shutdown.exe was not found at: $shutdownExe"
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        throw 'Administrator permission is required to restart Windows.'
    }

    # Cancel any stale pending shutdown first. Exit code 1116 simply means none was pending.
    try {
        $null = Start-Process -FilePath $shutdownExe -ArgumentList '/a' -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    }
    catch { }

    $comment = 'DRDirect PC Cleaner maintenance completed. Restarting to finish Windows maintenance.'
    $argumentLine = '/r /t {0} /f /c "{1}"' -f $DelaySeconds, $comment.Replace('"', "'")
    $process = Start-Process -FilePath $shutdownExe -ArgumentList $argumentLine -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop

    if ($process.ExitCode -ne 0) {
        throw "Windows rejected the restart command. shutdown.exe exit code: $($process.ExitCode)"
    }
}

# AUTO RESTART COUNTDOWN: v1.7
# After any Safe, Medium, or Advanced plan finishes, Restart now works immediately. If the user does
# nothing, Windows restarts automatically when the visible 90-second countdown ends.
# Choosing Restart later cancels the countdown and returns to the dashboard.
function Stop-DRRestartCountdown {
    Clear-DRRestartNotice
    if ($script:restartCountdownTimer) {
        try { $script:restartCountdownTimer.Stop() } catch { }
        $script:restartCountdownTimer = $null
    }
    $script:restartSecondsLeft = 0
}

function Format-DRCountdown {
    param([int]$Seconds)
    $span = [TimeSpan]::FromSeconds($Seconds)
    if ($span.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds) }
    if ($Seconds -ge 60) { return ('{0}:{1:00}' -f [int][Math]::Floor($Seconds / 60), ($Seconds % 60)) }
    return ('{0}s' -f $Seconds)
}

# Win32 taskbar flash. A countdown behind a fullscreen game is a countdown
# nobody sees, so the window asks for attention rather than waiting to be found.
if (-not ('DRDirect.NativeWindow' -as [type])) {
    try {
        Add-Type -Namespace DRDirect -Name NativeWindow -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct FLASHWINFO {
    public uint cbSize;
    public IntPtr hwnd;
    public uint dwFlags;
    public uint uCount;
    public uint dwTimeout;
}

[DllImport("user32.dll")]
public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

public static void Flash(IntPtr handle, uint count) {
    FLASHWINFO info = new FLASHWINFO();
    info.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
    info.hwnd = handle;
    info.dwFlags = 0x00000003 | 0x0000000C; // FLASHW_ALL | FLASHW_TIMERNOFG
    info.uCount = count;
    info.dwTimeout = 0;
    FlashWindowEx(ref info);
}
'@ -ErrorAction Stop
    } catch { }
}

function Show-DRRestartNotice {
    param([switch]$Urgent)

    try {
        if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
        $window.Topmost = $true
        $window.Activate() | Out-Null
        $window.Focus() | Out-Null

        if ('DRDirect.NativeWindow' -as [type]) {
            $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
            if ($handle -ne [IntPtr]::Zero) {
                [DRDirect.NativeWindow]::Flash($handle, $(if ($Urgent) { 20 } else { 8 }))
            }
        }
    } catch { }
}

function Clear-DRRestartNotice {
    try { $window.Topmost = $false } catch { }
}

function Start-DRRestartCountdown {
    [CmdletBinding()]
    param(
        [ValidateRange(1,21600)][int]$Seconds = 10800,
        [string]$BaseMessage = ''
    )

    Stop-DRRestartCountdown
    $script:restartSecondsLeft = $Seconds
    $script:restartCountdownBaseMessage = $BaseMessage

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $script:restartCountdownTimer = $timer

    $updateCountdownText = {
        $prefix = if ([string]::IsNullOrWhiteSpace($script:restartCountdownBaseMessage)) {
            ''
        } else {
            $script:restartCountdownBaseMessage + '  '
        }
        $clock = Format-DRCountdown -Seconds $script:restartSecondsLeft
        $ui.ProgressSafetyText.Text = $prefix + "Windows will restart in $clock to finish the repairs. Save your work. Click Restart now to go sooner, or Restart later to cancel."
        $ui.RestartButton.Content = "Restart now ($clock)"
    }

    & $updateCountdownText
    Show-DRRestartNotice

    $timer.Add_Tick({
        $script:restartSecondsLeft--

        if ($script:restartSecondsLeft -gt 0) {
            $prefix = if ([string]::IsNullOrWhiteSpace($script:restartCountdownBaseMessage)) {
                ''
            } else {
                $script:restartCountdownBaseMessage + '  '
            }
            $clock = Format-DRCountdown -Seconds $script:restartSecondsLeft
            $ui.ProgressSafetyText.Text = $prefix + "Windows will restart in $clock to finish the repairs. Save your work. Click Restart now to go sooner, or Restart later to cancel."
            $ui.RestartButton.Content = "Restart now ($clock)"

            if (@(1800, 600, 300, 60) -contains $script:restartSecondsLeft) {
                Show-DRRestartNotice -Urgent:($script:restartSecondsLeft -le 300)
            }
            return
        }

        Stop-DRRestartCountdown
        $ui.RestartButton.IsEnabled = $false
        $ui.RestartButton.Content = 'Restarting…'
        $ui.ProgressSafetyText.Text = 'The countdown has finished. Windows is restarting now.'

        if ($TestMode) {
            $ui.RestartButton.IsEnabled = $true
            $ui.RestartButton.Content = 'Restart now'
            $ui.ProgressSafetyText.Text = 'TEST MODE: the automatic restart was not performed.'
            return
        }

        try {
            Invoke-DRDirectRestartNow -DelaySeconds 0
        }
        catch {
            $ui.RestartButton.IsEnabled = $true
            $ui.RestartButton.Content = 'Restart now'
            $message = 'Automatic restart failed: ' + $_.Exception.Message + "`n`nPlease restart Windows manually from the Start menu."
            $ui.ProgressSafetyText.Text = $message
            [Windows.MessageBox]::Show($message, 'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
        }
    })

    $timer.Start()
}

$ui.RestartButton.Add_Click({
    $answer = [Windows.MessageBox]::Show(
        'Save all open work before restarting. Restart this PC now?',
        'Confirm restart',
        [Windows.MessageBoxButton]::YesNo,
        [Windows.MessageBoxImage]::Warning
    )

    if ($answer -ne [Windows.MessageBoxResult]::Yes) {
        return
    }

    Stop-DRRestartCountdown

    if ($TestMode) {
        [Windows.MessageBox]::Show('TEST MODE: restart was not performed.', 'DRDirect PC Cleaner') | Out-Null
        return
    }

    try {
        $ui.RestartButton.IsEnabled = $false
        $ui.RestartButton.Content = 'Restarting…'
        $ui.ProgressSafetyText.Text = 'Windows restart scheduled for 5 seconds. Save any remaining work now.'
        Invoke-DRDirectRestartNow -DelaySeconds 5
    }
    catch {
        $ui.RestartButton.IsEnabled = $true
        $ui.RestartButton.Content = 'Restart now'
        $message = 'Restart failed: ' + $_.Exception.Message + "`n`nPlease restart Windows manually from the Start menu."
        $ui.ProgressSafetyText.Text = $message
        [Windows.MessageBox]::Show($message, 'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
    }
})
function Resolve-DRDuplicateFinderExe {
    # The Duplicate Finder's own locked build, if it was installed beside this
    # one. Launching that lets it read its own licence. Running the loose script
    # instead makes it inherit this app's licence state, which is how a paid
    # Finder ended up wearing a free-try badge from an old Cleaner.
    $roots = New-Object System.Collections.Generic.List[string]
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($exe)) { $roots.Add((Split-Path -Parent $exe)) }
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $roots.Add($PSScriptRoot) }

    $names = @(
        'DRDirect Duplicate Finder CURRENT.exe',
        'DRDirect Duplicate Finder Locked.exe',
        'DRDirect Duplicate Finder.exe'
    )
    foreach ($root in @($roots | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        foreach ($name in $names) {
            $candidate = Join-Path -Path $root -ChildPath $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
        $candidate = Join-Path -Path $root -ChildPath 'Duplicate Finder\DRDirect Duplicate Finder CURRENT.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Resolve-DRDuplicateFinderPath {
    # Same lookup the engine uses - the finder ships beside this script.
    $roots = New-Object System.Collections.Generic.List[string]
    # An updated copy takes priority over the one bundled in the exe, which is
    # how a new Duplicate Finder reaches this PC without rebuilding anything.
    $roots.Add((Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Scripts'))
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $roots.Add($PSScriptRoot) }
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($exe)) { $roots.Add((Split-Path -Parent $exe)) }
    } catch { }
    try {
        if (-not [string]::IsNullOrWhiteSpace([AppDomain]::CurrentDomain.BaseDirectory)) {
            $roots.Add([AppDomain]::CurrentDomain.BaseDirectory)
        }
    } catch { }

    foreach ($root in @($roots | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $candidate = Join-Path -Path $root -ChildPath 'DRDirect Duplicate Finder.ps1'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

$ui.OpenDuplicatesButton.Add_Click({
    # Re-checked on every click, so a code entered mid-session takes effect
    # without restarting the Cleaner.
    try { $script:DRDuplicatesAllowed = Test-DRDuplicatesAllowed } catch { }
    if (-not $script:DRDuplicatesAllowed) {
        # A Duplicate Finder code can only be checked by the Duplicate Finder -
        # it is signed with that product's own secret, which this program does
        # not carry and should not. So hand over rather than ask for the code
        # here, where it could never be verified.
        if (-not (Resolve-DRDuplicateFinderPath)) {
            [Windows.MessageBox]::Show(
                "The Duplicate Finder is not included with this licence, and is not installed on this PC." + [Environment]::NewLine + [Environment]::NewLine +
                "Contact DRDirect to buy it. They will send you the program and a code for this machine.",
                'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
            $ui.DuplicateStatus.Text = 'The Duplicate Finder is not included with this licence. Contact DRDirect to buy it.'
            return
        }

        $answer = [Windows.MessageBox]::Show(
            "The Duplicate Finder is not included with this licence." + [Environment]::NewLine + [Environment]::NewLine +
            "It is installed, and has its own activation code. Open it now to enter that code?",
            'DRDirect PC Cleaner', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) {
            $ui.DuplicateStatus.Text =
                'The Duplicate Finder is not included with this licence. Contact DRDirect for a code.'
            return
        }
        # Falls through and opens it. The Finder asks for its own code, and once
        # that is accepted this page unlocks by itself on the next click.
        $ui.DuplicateStatus.Text = 'Opening the Duplicate Finder so you can enter its code.'
    }

    # Its own build first: it checks its own licence and needs no flags from here.
    $finderExe = Resolve-DRDuplicateFinderExe
    if ($finderExe) {
        try {
            Start-Process -FilePath $finderExe | Out-Null
            $ui.DuplicateStatus.Text = 'Duplicate Finder opened in its own window.'
        } catch {
            $ui.DuplicateStatus.Text = "Could not start the Duplicate Finder: $($_.Exception.Message)"
        }
        return
    }

    $finder = Resolve-DRDuplicateFinderPath
    if (-not $finder) {
        $ui.DuplicateStatus.Text = "Could not find 'DRDirect Duplicate Finder.ps1' beside the application."
        return
    }
    # The path contains spaces, so it must arrive at powershell.exe quoted.
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $trialFlag = ''
    try { if (Test-DRTrialMode) { $trialFlag = ' -TrialMode' } } catch { }
    $psArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -FromCleaner{1}' -f $finder, $trialFlag

    try {
        if (Test-DRAdministrator) {
            # The Cleaner needs administrator rights, but the Duplicate Finder does
            # not - it only touches the user's own files. A child process inherits
            # this one's token, so launch it through Explorer instead, which runs as
            # the logged-in user and hands back an ordinary, unelevated token.
            $shortcut = Join-Path $env:TEMP 'DRDirect Duplicate Finder.lnk'
            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut($shortcut)
            $link.TargetPath = $psExe
            $link.Arguments = $psArgs
            $link.WorkingDirectory = Split-Path -Parent $finder
            $link.WindowStyle = 7
            $link.Save()

            # Explorer takes the whole argument tail as one path and does not strip
            # quotes, so this must be passed unquoted even though it has spaces.
            Start-Process -FilePath 'explorer.exe' -ArgumentList $shortcut | Out-Null

            # Some machines refuse to run a shortcut from the temp folder, and
            # do it silently - Explorer reports success either way. Wait, and if
            # no window turned up, start it directly instead of leaving the
            # person looking at a button that appears to do nothing.
            $appeared = $false
            for ($i = 0; $i -lt 12; $i++) {
                Start-Sleep -Milliseconds 500
                if (Get-Process -Name 'powershell' -ErrorAction SilentlyContinue |
                        Where-Object { $_.MainWindowTitle -like '*Duplicate Finder*' }) {
                    $appeared = $true
                    break
                }
            }

            if ($appeared) {
                $ui.DuplicateStatus.Text = 'Duplicate Finder opened in its own window, running as your normal user rather than as administrator.'
            } else {
                Start-Process -FilePath $psExe -ArgumentList $psArgs -WindowStyle Hidden | Out-Null
                $ui.DuplicateStatus.Text = 'Duplicate Finder opened in its own window.'
            }
        } else {
            Start-Process -FilePath $psExe -ArgumentList $psArgs -WindowStyle Hidden | Out-Null
            $ui.DuplicateStatus.Text = 'Duplicate Finder opened in its own window.'
        }
    } catch {
        $ui.DuplicateStatus.Text = "Could not start the Duplicate Finder: $($_.Exception.Message)"
    }
})

function Start-DRQuietUpdateCheck {
    <#
        .SYNOPSIS
            Look for a new version in the background and mark the button.
        .DESCRIPTION
            Nobody presses a button to ask whether there is news. Check once a
            day, quietly, off the interface thread, and if something is waiting
            say so on the button itself. Never interrupt and never show an
            error: a PC with no internet must open exactly as it always does.

            This only reads the version number to decide whether to draw a
            badge. Nothing is trusted or installed here - pressing the button
            still runs the full signature and checksum checks before anything
            is downloaded.
    #>
    $stampFile = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\lastupdatecheck.txt'
    # Checked on every start: it is one small request, and a waiting update should
    # never be hidden for a day because the last look was this morning.
    $installed = try { Get-DRInstalledVersion } catch { [version]'0.0.0' }

    $probe = {
        param($InstalledText)
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $headers = @{ Accept = 'application/vnd.github.raw'; 'User-Agent' = 'DRDirect-Updater' }
            $uri = 'https://api.github.com/repos/Phears/drdirect-cleaner-updates/contents/update_manifest.json?ref=main'
            $response = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 20
            $text = if ($response.Content -is [byte[]]) {
                [Text.Encoding]::UTF8.GetString([byte[]]$response.Content)
            } else { [string]$response.Content }
            $offered = ([string](($text.TrimStart([char]0xFEFF)) | ConvertFrom-Json).version).Trim()
            if ([version]$offered -gt [version]$InstalledText) { 'AVAILABLE ' + $offered } else { 'NONE' }
        } catch { 'NONE' }
    }

    try {
        # Script scope, not local: the timer's handler runs in its own scope and
        # under StrictMode a local variable it cannot see is a hard error, which
        # would take the whole window down with it.
        $script:DRCheckRunspace = [RunspaceFactory]::CreateRunspace()
        $script:DRCheckRunspace.ApartmentState = 'MTA'
        $script:DRCheckRunspace.ThreadOptions = 'ReuseThread'
        $script:DRCheckRunspace.Open()
        $script:DRCheckPs = [PowerShell]::Create()
        $script:DRCheckPs.Runspace = $script:DRCheckRunspace
        $null = $script:DRCheckPs.AddScript($probe.ToString()).AddArgument($installed.ToString())
        $script:DRCheckAsync = $script:DRCheckPs.BeginInvoke()
        $script:DRCheckStamp = $stampFile

        $script:DRCheckTimer = New-Object Windows.Threading.DispatcherTimer
        $script:DRCheckTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:DRCheckTimer.Add_Tick({
            if (-not $script:DRCheckAsync.IsCompleted) { return }
            $script:DRCheckTimer.Stop()
            try {
                $line = [string](@($script:DRCheckPs.EndInvoke($script:DRCheckAsync)) | Select-Object -Last 1)
                if ($line -like 'AVAILABLE*') {
                    $version = ($line -split ' ')[1]
                    $ui.CheckUpdatesButton.Content = "New update available - $version"
                    $ui.CheckUpdatesButton.FontWeight = 'Bold'
                    try { $ui.CheckUpdatesButton.Background = '#12C25B'; $ui.CheckUpdatesButton.Foreground = 'White'; $ui.CheckUpdatesButton.BorderBrush = '#0B7A3B' } catch { }
                    $ui.UpdateBannerText.Text = "There is a new update - version $version"
                    $ui.UpdateBanner.Visibility = 'Visible'
                    $ui.CheckUpdatesButton.ToolTip =
                        "Version $version is ready. Click to see what changed and install it."
                }
                try { [System.IO.File]::WriteAllText($script:DRCheckStamp, (Get-Date).ToString('yyyy-MM-dd')) } catch { }
            } catch { }
            try {
                $script:DRCheckPs.Dispose()
                $script:DRCheckRunspace.Close()
                $script:DRCheckRunspace.Dispose()
            } catch { }
        })
        $script:DRCheckTimer.Start()
    } catch { }
}

$ui.UpdateBannerButton.Add_Click({
    $ui.CheckUpdatesButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
})

$ui.CheckUpdatesButton.Add_Click({
    # A copy waiting to be activated gets the code box here too - some people
    # will reach for Update rather than the link in the corner.

    # This button lives on the Dashboard, away from the duplicates page, so
    # results are shown in a dialog rather than written into a status line the
    # person may not be looking at.
    $ui.CheckUpdatesButton.IsEnabled = $false
    $ui.CheckUpdatesButton.Content = 'Checking...'
    try {
        $check = Test-DRUpdateAvailable
        if (-not $check.Available) {
            [Windows.MessageBox]::Show($check.Message, 'DRDirect PC Cleaner',
                [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
            return
        }

        # Nothing is downloaded until the person using the PC agrees to it, and
        # nobody should have to agree to a change nobody described. Show what the
        # update actually does before asking.
        $detail = Get-DRPropertyValue -InputObject $check -Name 'Summary'
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $check.Message }
        $prompt = $detail + [Environment]::NewLine + [Environment]::NewLine +
                  'Download and install it now?'
        $answer = [Windows.MessageBox]::Show($prompt, 'DRDirect PC Cleaner',
            [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }

        $ui.CheckUpdatesButton.Content = 'Updating...'
        $result = Install-DRUpdate -Manifest $check.Manifest
        if ($result.Success) { $ui.UpdateBanner.Visibility = 'Collapsed' }
        $icon = if ($result.Success) { [Windows.MessageBoxImage]::Information } else { [Windows.MessageBoxImage]::Warning }
        [Windows.MessageBox]::Show($result.Message, 'DRDirect PC Cleaner',
            [Windows.MessageBoxButton]::OK, $icon) | Out-Null
    }
    catch {
        [Windows.MessageBox]::Show("Could not check for updates: $($_.Exception.Message)",
            'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
    }
    finally {
        $ui.CheckUpdatesButton.IsEnabled = $true
        $ui.CheckUpdatesButton.Content = 'Update this program'
    }
})

$ui.OpenReportsButton.Add_Click({ $path=Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Reports'; New-Item -Path $path -ItemType Directory -Force|Out-Null; Start-Process -FilePath explorer.exe -ArgumentList @($path) })
$ui.ClearHistoryButton.Add_Click({
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) { return }

    $reportRoot = Join-Path -Path $localAppData -ChildPath 'DRDirect PC Cleaner\Reports'
    $all = @(Get-ChildItem -LiteralPath $reportRoot -Filter 'Maintenance_Report_*.txt' -File -ErrorAction SilentlyContinue)
    if (-not $all) {
        [void][Windows.MessageBox]::Show('There are no reports to delete.', 'DRDirect PC Cleaner', 'OK', 'Information')
        return
    }

    $answer = [Windows.MessageBox]::Show("Permanently delete all $($all.Count) maintenance report(s)?`n`nThis only removes the report files. It does not undo any maintenance that was already run.", 'DRDirect PC Cleaner', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    $failed = 0
    foreach ($file in $all) {
        try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch { $failed++ }
    }

    Show-History

    if ($failed -gt 0) {
        [void][Windows.MessageBox]::Show("$failed report(s) could not be deleted. They may be open in another program.", 'DRDirect PC Cleaner', 'OK', 'Warning')
    }
})

# The activate option stays available, but nothing pops up on opening - the
# window only appears once the free try has actually run out.
# Always offered, and it breathes gently so it is noticed - people look for a
# way to activate exactly once, usually while on the phone to you.
$ui.ActivateWrap.Visibility = 'Visible'

# Trial countdown: show "14 days left" and tick down each day, so the free
# period never lapses without warning. Hidden for full licences until their
# final stretch, and for lifetime copies entirely.
try {
    $left = Get-DRDaysLeft
    if ($null -ne $left -and $left -ge 0 -and $left -le 21) {
        $ui.TrialCountdown.Text =
            if     ($left -eq 0) { 'Trial ends today' }
            elseif ($left -eq 1) { 'Trial - 1 day left' }
            else                 { "Trial - $left days left" }
        if ($left -le 3) {
            $ui.TrialCountdown.Foreground =
                New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xFF, 0xD5, 0xDA))
        }
        $ui.TrialCountdown.Visibility = 'Visible'
    }
} catch { }

function Stop-DRActivatePulse {
    # Clearing the animation hands the property back to its own value, so the
    # box settles at its normal size instead of freezing mid-throb.
    try {
        $ui.ActivateScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $null)
        $ui.ActivateScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $null)
        $ui.ActivateScale.ScaleX = 1
        $ui.ActivateScale.ScaleY = 1
    } catch { }
}

# Only throb while there is actually something to activate. An activated copy
# showed a pulsing button that did nothing when pressed.
try {
    if (Test-DRNeedsActivation) {
        $pulse = New-Object Windows.Media.Animation.DoubleAnimation(1, 1.05,
            (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(1100))))
        $pulse.AutoReverse = $true
        $pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $pulse.EasingFunction = New-Object Windows.Media.Animation.SineEase -Property @{ EasingMode = 'EaseInOut' }
        $ui.ActivateScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $pulse)
        $ui.ActivateScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $pulse)
    }
} catch { }

$ui.ActivateButton.Add_Click({
    # Nothing to activate? Say so, rather than showing an end-of-licence notice
    # to someone whose licence is perfectly good.
    try {
        if (-not (Test-DRNeedsActivation)) {
            Stop-DRActivatePulse
            [Windows.MessageBox]::Show('This copy is activated. Nothing to do.',
                'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK,
                [Windows.MessageBoxImage]::Information) | Out-Null
            return
        }
    } catch { }

    if ((Show-DRActivation 'expired') -eq 'activated') {
        Stop-DRActivatePulse
        $ui.ActivateWrap.Visibility = 'Collapsed'
        [Windows.MessageBox]::Show('Activated. Restart the Cleaner to lift the trial limits.',
            'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Information) | Out-Null
    }
})

# Both products ship from one folder now, so offer the page whenever the
# Finder is actually there to open. Missing means the person bought the
# Cleaner on its own - say so plainly instead of failing on the click.
$script:DRDuplicatesAllowed = $true
try { $script:DRDuplicatesAllowed = Test-DRDuplicatesAllowed } catch { }

if (-not (Resolve-DRDuplicateFinderPath)) {
    $ui.NavDuplicates.IsEnabled = $false
    $ui.NavDuplicates.Opacity = 0.4
    $ui.NavDuplicates.ToolTip = 'A separate program. Contact DRDirect for a copy.'
} elseif (-not $script:DRDuplicatesAllowed) {
    # Short licences buy the Cleaner alone. Leave the page reachable so the
    # offer is visible, and refuse at the point of opening instead.
    $ui.NavDuplicates.IsEnabled = $true
    $ui.NavDuplicates.Opacity = 1
    $ui.NavDuplicates.ToolTip = 'Not included with this licence. Contact DRDirect for a code.'
} else {
    $ui.NavDuplicates.IsEnabled = $true
    $ui.NavDuplicates.Opacity = 1
    $ui.NavDuplicates.ToolTip = $null
}

$ui.AdminStatus.Text = if (Test-DRAdministrator) { '●  Administrator session' } else { '○  Standard user session' }
if ($TestMode) { $ui.TestModeBanner.Visibility='Visible' }
try { $drive=Get-PSDrive -Name C -ErrorAction Stop; $ui.FreeSpaceText.Text=Format-Bytes $drive.Free } catch { $ui.FreeSpaceText.Text='Unavailable' }
$window.Add_Closed({ Stop-DRRestartCountdown; $pollTimer.Stop(); if ($script:activePowerShell) { try { $script:activePowerShell.Stop() } catch {}; Stop-EngineCall } })

if ($NoShow) {
    Set-Page 'Cleanup'
    $firstTaskRow = $ui.TaskList.Children | Select-Object -First 1
    if (-not $firstTaskRow) { throw 'GUI smoke test could not render cleanup tasks.' }
    $firstTaskRow.Child.Children[0].IsChecked = $true
    Show-Confirmation
    # Two lines of reassurance sit above the plan rows, so the one task makes three children.
    if (@($ui.ConfirmList.Children | Where-Object { $_ -is [Windows.Controls.Border] }).Count -ne 1) { throw 'GUI smoke test could not build a one-item confirmation plan.' }
    $ui.ConfirmOverlay.Visibility = 'Collapsed'
    Set-Page 'AI'
    # "Turn everything back on" is always listed, so an empty page means the page broke.
    if (-not @($ui.TaskList.Children).Count) { throw 'GUI smoke test could not render the AI Remover page.' }
    # "Turn off all AI" acts straight away (and asks first), so the test only checks it and the row buttons exist.
    if (-not $script:DRAIAllOffButton) { throw 'GUI smoke test: "Turn off all AI" is missing.' }
    if (-not @($script:DRAIOffButtons).Count) { throw 'GUI smoke test: the AI rows have no "Turn off" buttons.' }
    # "Check now" shows its answer in its own row and picks nothing.
    $checkCard = @($ui.TaskList.Children | Where-Object { $_.Child.Children[0] -is [Windows.Controls.StackPanel] -and [string]$_.Child.Children[0].Children[0].CommandParameter -eq 'ai.check' }) | Select-Object -First 1
    if (-not $checkCard) { throw 'GUI smoke test: the "What AI is on this PC?" row is missing.' }
    $checkCard.Child.Children[0].Children[0].IsChecked = $true
    if (-not @($checkCard.Child.Children[1].Children | Where-Object { $_.Tag -eq 'AICheckResults' }).Count) { throw 'GUI smoke test: "Check now" showed no results.' }
    if ($selection['ai.check']) { throw 'GUI smoke test: "Check now" was added to the plan.' }
    Set-Page 'Dashboard'
    $pollTimer.Stop()
    $window.Close()
    Write-Output 'DRDirect PC Cleaner GUI initialized successfully.'
} else {
    try {
        $shown = try { Get-DRInstalledVersion } catch { $null }
        # <BUILD-VERSION>
        $script:DRBuildVersion = ''
        # </BUILD-VERSION>
        # Show whichever is newer: the version the update system recorded, or the
        # one stamped in at build time. A fresh install over an old one inherits
        # the old recorded number, which used to make a new build say 1.3.0.
        $recorded = [version]'0.0'; $built = [version]'0.0'
        if ($shown) { [void][version]::TryParse("$shown", [ref]$recorded) }
        if ($script:DRBuildVersion) { [void][version]::TryParse("$script:DRBuildVersion", [ref]$built) }
        $newest = if ($recorded -gt $built) { $recorded } else { $built }
        $ui.VersionText.Text = if ($newest -ge [version]'0.0.1') { "Version $newest" } else { 'Version 1.0' }
    } catch { }
    Apply-CleanupPreset -Preset 'Safe'
    # Ask once a day, quietly, so a waiting update is visible on the button
    # rather than only to someone who thinks to go looking for it.
    try { Start-DRQuietUpdateCheck } catch { }
    [void]$window.ShowDialog()
}
