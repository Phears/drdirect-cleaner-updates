[CmdletBinding()]
param(
    [switch]$TestMode,
    [string]$TestRoot,
    [switch]$NoShow
)

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

# The engine above has already pointed this process at the signed-in person's
# folders (Windows 11 Administrator Protection runs an elevated copy as a hidden
# admin account), so the update-folder check below looks in the right place.

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

# Only one window of this program at a time. A second click (or a double
# click that starts it twice) brings the open window forward and quits.
function Enter-DRSingleWindow {
    param([string]$MutexName, [string]$Title, [switch]$CheckOnly)
    $taken = $false
    try {
        if ($CheckOnly) {
            $existing = $null
            try { $taken = [Threading.Mutex]::TryOpenExisting($MutexName, [ref]$existing); if ($existing) { $existing.Dispose() } }
            catch [UnauthorizedAccessException] { $taken = $true }
        } else {
            $created = $false
            $script:DRSingleWindowMutex = New-Object Threading.Mutex($true, $MutexName, [ref]$created)
            $taken = -not $created
        }
    } catch { return }
    if (-not $taken) { return }
    try {
        if (-not ('DRSingleWindow' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class DRSingleWindow {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr w, int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr w);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr w);
}
'@
        }
        # The first copy may still be starting; give its window a few seconds.
        for ($i = 0; $i -lt 20; $i++) {
            $open = Get-Process -Name 'powershell', 'DRDirect*' -ErrorAction SilentlyContinue |
                Where-Object { $_.Id -ne $PID -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -eq $Title } |
                Select-Object -First 1
            if ($open) {
                if ([DRSingleWindow]::IsIconic($open.MainWindowHandle)) { [void][DRSingleWindow]::ShowWindow($open.MainWindowHandle, 9) }
                [void][DRSingleWindow]::SetForegroundWindow($open.MainWindowHandle)
                break
            }
            Start-Sleep -Milliseconds 250
        }
    } catch { }
    exit 0
}
if (-not $NoShow) { Enter-DRSingleWindow -MutexName 'Global\DRDirectPCCleanerWindow' -Title 'DRDirect PC Cleaner' -CheckOnly }

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

if (-not $NoShow) { Enter-DRSingleWindow -MutexName 'Global\DRDirectPCCleanerWindow' -Title 'DRDirect PC Cleaner' }

# The updater is spliced in at build time, exactly like the engine above, so
# the compiled exe carries it without needing a loose file beside it.
# <UPDATER-IMPORT>
. (Join-Path $PSScriptRoot 'DRDirect Updater.ps1')
# </UPDATER-IMPORT>

# List the Cleaner in Windows' installed programs. The shared code is in the updater.
if (-not $TestMode -and -not $NoShow) { Register-DRInstalledProduct -Product 'Cleaner' }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$ErrorActionPreference = 'Stop'

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DRDirect PC Cleaner" Width="1020" Height="840" MinWidth="860" MinHeight="560"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Ideal"
        WindowStyle="None" ResizeMode="CanResize" BorderBrush="#D7DFEA" BorderThickness="1">
    <Window.Background>
        <!-- Darker toward the edges, so the page sits far back and the cards stand out in front of it -->
        <RadialGradientBrush Center="0.5,0.38" GradientOrigin="0.5,0.3" RadiusX="0.95" RadiusY="0.95">
            <GradientStop Color="#D9E0EE" Offset="0"/>
            <GradientStop Color="#BAC6DD" Offset="0.6"/>
            <GradientStop Color="#97A7C5" Offset="1"/>
        </RadialGradientBrush>
    </Window.Background>
    <Window.Resources>
        <DropShadowEffect x:Key="DR3DShadow" Color="#0A1A4A" Direction="270" ShadowDepth="11" BlurRadius="18" Opacity="0.7"/>
        <DropShadowEffect x:Key="DR3DText" Color="Black" Direction="270" ShadowDepth="1.5" BlurRadius="2" Opacity="0.45"/>
        <DropShadowEffect x:Key="DR3DHeroText" Color="#000820" Direction="300" ShadowDepth="3.5" BlurRadius="3" Opacity="0.85"/>
        <DropShadowEffect x:Key="DR3DCardSoft" Color="#6B82A6" BlurRadius="26" ShadowDepth="5" Direction="270" Opacity="0.22"/>
        <LinearGradientBrush x:Key="DR3DCardFace" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#EEF6FF" Offset="0"/><GradientStop Color="#DFEDFF" Offset="0.5"/><GradientStop Color="#CFE2FB" Offset="1"/></LinearGradientBrush>
        <DropShadowEffect x:Key="DR3DLetter" Color="#0A1438" Direction="270" ShadowDepth="1" BlurRadius="1.5" Opacity="0.18"/>
        <SolidColorBrush x:Key="DR3DSlabA" Color="#B0000814"/>
        <SolidColorBrush x:Key="DR3DSlabB" Color="#B3000A30"/>
        <Visibility x:Key="DR3DParts">Visible</Visibility>
        <Thickness x:Key="DR3DEdgeHero">0,8,0,-8</Thickness>
        <Thickness x:Key="DR3DEdgeSmall">0,6,0,-6</Thickness>
        <Thickness x:Key="DR3DEdgeNav">0,4,0,-4</Thickness>
        <Thickness x:Key="DR3DLip">0,0,0,4</Thickness>
        <Visibility x:Key="DR3DMaxParts">Collapsed</Visibility>
        <Thickness x:Key="DR3DNavMargin">10,3,10,8</Thickness>
        <Thickness x:Key="DR3DEdgeNavMid">0,2,0,-2</Thickness>
        <DropShadowEffect x:Key="DR3DButton" Color="#0A1A4A" Direction="270" ShadowDepth="9" BlurRadius="16" Opacity="0.6"/>
        <DropShadowEffect x:Key="DR3DCard" Color="#16275A" Direction="270" ShadowDepth="8" BlurRadius="3" Opacity="0.9"/>
        <Style x:Key="DRSwitch" TargetType="CheckBox"><Setter Property="Foreground" Value="White"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="13"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox"><StackPanel Orientation="Horizontal" Background="Transparent">
                <Border x:Name="Track" Width="40" Height="22" CornerRadius="11" Background="#55FFFFFF" BorderBrush="#CCFFFFFF" BorderThickness="1"><Ellipse x:Name="Knob" Width="16" Height="16" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/></Border>
                <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/></StackPanel>
                <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Track" Property="Background" Value="#22C55E"/><Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/><Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/></Trigger></ControlTemplate.Triggers>
            </ControlTemplate></Setter.Value></Setter></Style>
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

        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Effect" Value="{DynamicResource DR3DLetter}"/></Style>
        <Style x:Key="MutedText" TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="Effect" Value="{DynamicResource DR3DLetter}"/></Style>
        <Style x:Key="TitleText" TargetType="TextBlock"><Setter Property="FontSize" Value="30"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,2,0,0"/></Style>
        <Style x:Key="SectionText" TargetType="TextBlock"><Setter Property="FontSize" Value="20"/><Setter Property="FontWeight" Value="SemiBold"/></Style>

        <Style x:Key="PrimaryButton" TargetType="Button"><Setter Property="Effect" Value="{DynamicResource DR3DButton}"/>
            <Setter Property="Foreground" Value="White"/><Setter Property="Background" Value="{StaticResource Blue}"/>
            <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="20,11"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Template">
                <Setter.Value><ControlTemplate TargetType="Button">
                    <Grid><Border CornerRadius="9" Background="{DynamicResource DR3DSlabA}" Margin="{DynamicResource DR3DEdgeSmall}" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
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
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Effect="{DynamicResource DR3DText}"/>
                    </Border><Border CornerRadius="9,9,0,0" VerticalAlignment="Top" Height="14" Margin="1,1,1,0" Background="#3CFFFFFF" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/><Border CornerRadius="0,0,9,9" VerticalAlignment="Bottom" Height="3" Margin="1,0,1,1" Background="#40000000" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/></Grid>
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
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Grid><Border CornerRadius="9" Background="{DynamicResource DR3DSlabA}" Margin="{DynamicResource DR3DEdgeSmall}" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/><Border x:Name="SecondaryBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><Border CornerRadius="9,9,0,0" VerticalAlignment="Top" Height="14" Margin="1,1,1,0" Background="#3CFFFFFF" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/><Border CornerRadius="0,0,9,9" VerticalAlignment="Bottom" Height="3" Margin="1,0,1,1" Background="#40000000" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/></Grid><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="SecondaryBorder" Property="Background" Value="{StaticResource Hover}"/><Setter TargetName="SecondaryBorder" Property="BorderBrush" Value="#C9D5E6"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="SecondaryBorder" Property="Background" Value="#E7EEF8"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.42"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource SecondaryButton}">
            <Setter Property="Foreground" Value="{StaticResource Danger}"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="DangerBorder" Background="{TemplateBinding Background}" BorderBrush="#EFCFCF" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="DangerBorder" Property="Background" Value="{StaticResource DangerSoft}"/><Setter TargetName="DangerBorder" Property="BorderBrush" Value="#E2AFAF"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="DangerBorder" Property="Background" Value="#FADEDE"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.42"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <Style x:Key="HeroButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
            <Setter Property="Foreground" Value="#1E3A8A"/><Setter Property="Background" Value="White"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="FontSize" Value="15"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="HeroBorder" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="HeroBorder" Property="Background" Value="#EAF0FF"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="HeroBorder" Property="Background" Value="#D9E4FF"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <Style x:Key="HeroGhostButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
            <Setter Property="Foreground" Value="White"/><Setter Property="Background" Value="#55FFFFFF"/><Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="GhostBorder" Background="{TemplateBinding Background}" BorderBrush="#CCFFFFFF" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="GhostBorder" Property="Background" Value="#4DFFFFFF"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="GhostBorder" Property="Background" Value="#66FFFFFF"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        <Style x:Key="HeroGreenButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}"><Setter Property="Effect" Value="{x:Null}"/><Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#4FC3FF" Offset="0"/><GradientStop Color="#1E6FE8" Offset="1"/></LinearGradientBrush></Setter.Value></Setter>
            <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="13"/><Setter Property="Padding" Value="16,7"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                <Grid x:Name="GreenRoot" RenderTransformOrigin="0.5,0.5">
                    <Grid.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
                    <Grid.Effect><DynamicResource ResourceKey="DR3DShadow"/></Grid.Effect>
                    <!-- The darker edge underneath makes the button look raised, like a key. -->
                    <Border CornerRadius="16" Background="{DynamicResource DR3DSlabB}" Margin="{DynamicResource DR3DEdgeHero}" Visibility="{DynamicResource DR3DParts}"/>
                    <Grid x:Name="GreenFace">
                        <Grid.RenderTransform><TranslateTransform x:Name="GreenPress" Y="0"/></Grid.RenderTransform>
                        <Border x:Name="GreenBorder" Background="{TemplateBinding Background}" CornerRadius="16" BorderBrush="#E6FFFFFF" BorderThickness="1.5" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                            <Grid>
                                <Border CornerRadius="14,14,30,30" VerticalAlignment="Top" Margin="2,-5,2,0" Height="16" IsHitTestVisible="False">
                                    <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#99FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Border.Background>
                                </Border>
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center">
                                    <ContentPresenter.Effect><DynamicResource ResourceKey="DR3DText"/></ContentPresenter.Effect>
                                </ContentPresenter>
                            </Grid>
                        </Border>
                        <Border CornerRadius="16" IsHitTestVisible="False" BorderThickness="{DynamicResource DR3DLip}" BorderBrush="#55000000" Visibility="{DynamicResource DR3DParts}"/>
                    </Grid>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsPressed" Value="True"><Setter TargetName="GreenFace" Property="Margin" Value="0,3,0,-3"/></Trigger>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Trigger.EnterActions><BeginStoryboard><Storyboard>
                            <DoubleAnimation Storyboard.TargetName="GreenRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.1" Duration="0:0:0.45"><DoubleAnimation.EasingFunction><ElasticEase EasingMode="EaseOut" Oscillations="2" Springiness="4"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                            <DoubleAnimation Storyboard.TargetName="GreenRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.1" Duration="0:0:0.45"><DoubleAnimation.EasingFunction><ElasticEase EasingMode="EaseOut" Oscillations="2" Springiness="4"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                        </Storyboard></BeginStoryboard></Trigger.EnterActions>
                        <Trigger.ExitActions><BeginStoryboard><Storyboard>
                            <DoubleAnimation Storyboard.TargetName="GreenRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.2"/>
                            <DoubleAnimation Storyboard.TargetName="GreenRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.2"/>
                        </Storyboard></BeginStoryboard></Trigger.ExitActions>
                    </Trigger>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
                </ControlTemplate.Triggers></ControlTemplate></Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="GlossyChoiceButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}"><Setter Property="Effect" Value="{x:Null}"/><Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#4FC3FF" Offset="0"/><GradientStop Color="#1E6FE8" Offset="1"/></LinearGradientBrush></Setter.Value></Setter>
            <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="13"/><Setter Property="Padding" Value="16,7"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                <Grid x:Name="GreenRoot" RenderTransformOrigin="0.5,0.5">
                    <Grid.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
                    <Grid.Effect><DynamicResource ResourceKey="DR3DShadow"/></Grid.Effect>
                    <!-- The darker edge underneath makes the button look raised, like a key. -->
                    <Border CornerRadius="16" Background="{DynamicResource DR3DSlabB}" Margin="{DynamicResource DR3DEdgeHero}" Visibility="{DynamicResource DR3DParts}"/>
                    <Grid x:Name="GreenFace">
                        <Grid.RenderTransform><TranslateTransform x:Name="GreenPress" Y="0"/></Grid.RenderTransform>
                        <Border x:Name="GreenBorder" Background="{TemplateBinding Background}" CornerRadius="16" BorderBrush="#E6FFFFFF" BorderThickness="1.5" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                            <Grid>
                                <Border CornerRadius="14,14,30,30" VerticalAlignment="Top" Margin="2,-5,2,0" Height="16" IsHitTestVisible="False">
                                    <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#99FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Border.Background>
                                </Border>
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center">
                                    <ContentPresenter.Effect><DynamicResource ResourceKey="DR3DText"/></ContentPresenter.Effect>
                                </ContentPresenter>
                            </Grid>
                        </Border>
                        <Border CornerRadius="16" IsHitTestVisible="False" BorderThickness="{DynamicResource DR3DLip}" BorderBrush="#55000000" Visibility="{DynamicResource DR3DParts}"/>
                    </Grid>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsPressed" Value="True"><Setter TargetName="GreenFace" Property="Margin" Value="0,3,0,-3"/></Trigger>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Trigger.EnterActions><BeginStoryboard><Storyboard>
                            <DoubleAnimation Storyboard.TargetName="GreenRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.1" Duration="0:0:0.45"><DoubleAnimation.EasingFunction><ElasticEase EasingMode="EaseOut" Oscillations="2" Springiness="4"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                            <DoubleAnimation Storyboard.TargetName="GreenRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.1" Duration="0:0:0.45"><DoubleAnimation.EasingFunction><ElasticEase EasingMode="EaseOut" Oscillations="2" Springiness="4"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                        </Storyboard></BeginStoryboard></Trigger.EnterActions>
                        <Trigger.ExitActions><BeginStoryboard><Storyboard>
                            <DoubleAnimation Storyboard.TargetName="GreenRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.2"/>
                            <DoubleAnimation Storyboard.TargetName="GreenRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.2"/>
                        </Storyboard></BeginStoryboard></Trigger.ExitActions>
                    </Trigger>
                    <Trigger Property="Tag" Value="Active"><Setter TargetName="GreenBorder" Property="BorderBrush" Value="#FFF176"/><Setter TargetName="GreenBorder" Property="BorderThickness" Value="3.5"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
                </ControlTemplate.Triggers></ControlTemplate></Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="NavButton" TargetType="Button">
            <Setter Property="Foreground" Value="#E6EEFA"/><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="Padding" Value="18,12"/><Setter Property="Margin" Value="{DynamicResource DR3DNavMargin}"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="15.5"/>
            <!-- Every nav label starts with a symbol Segoe UI does not contain, so
                 the glyph is borrowed from a fallback font. Segoe UI Symbol is the only
                 installed font carrying them, so name it rather than leave the fallback
                 to chance - unnamed, an icon can quietly render as a blank gap. -->
            <Setter Property="FontFamily" Value="Segoe UI, Segoe UI Symbol, Segoe UI Emoji, Arial Unicode MS"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                <Grid x:Name="NavRoot" RenderTransformOrigin="0,0.5">
                    <Grid.RenderTransform><TranslateTransform X="0" Y="0"/></Grid.RenderTransform>
                    <!-- 3D: a raised tile with a darker edge underneath and a shine on top -->
                    <Border CornerRadius="9" Background="{DynamicResource DR3DSlabA}" Margin="{DynamicResource DR3DEdgeNav}" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/><Border CornerRadius="9" Background="#CC22346E" Margin="{DynamicResource DR3DEdgeNavMid}" Visibility="{DynamicResource DR3DMaxParts}" IsHitTestVisible="False"/>
                    <Border CornerRadius="9" Visibility="{DynamicResource DR3DParts}" BorderBrush="#88FFFFFF" BorderThickness="1,1,1,0" IsHitTestVisible="False"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5272AD" Offset="0"/><GradientStop Color="#28396B" Offset="0.5"/><GradientStop Color="#111C3B" Offset="1"/></LinearGradientBrush></Border.Background></Border>
                    <Border x:Name="NavBorder" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter Effect="{DynamicResource DR3DText}"/></Border>
                    <Border CornerRadius="9,9,0,0" VerticalAlignment="Top" Height="17" Margin="1,1,1,0" Background="#26FFFFFF" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/><Border CornerRadius="9,9,0,0" VerticalAlignment="Top" Height="30" Margin="1,1,1,0" Visibility="{DynamicResource DR3DMaxParts}" IsHitTestVisible="False"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#66FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Border.Background></Border><Border CornerRadius="9" Visibility="{DynamicResource DR3DMaxParts}" BorderBrush="#99000000" BorderThickness="0,0,0,6" IsHitTestVisible="False"/>
                    <Border CornerRadius="0,0,9,9" VerticalAlignment="Bottom" Height="3" Margin="1,0,1,1" Background="#55000000" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
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
        <Style x:Key="AINavButton" TargetType="Button" BasedOn="{StaticResource NavButton}"><Setter Property="Effect" Value="{DynamicResource DR3DButton}"/>
            <Setter Property="Foreground" Value="#E9D5FF"/><Setter Property="Background" Value="#2E1D5C"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                <Grid x:Name="NavRoot" RenderTransformOrigin="0,0.5">
                    <Grid.RenderTransform><TranslateTransform X="0" Y="0"/></Grid.RenderTransform>
                    <!-- 3D, like the other buttons: a darker edge underneath and a shine across the top -->
                    <Border CornerRadius="9" Background="{DynamicResource DR3DSlabA}" Margin="{DynamicResource DR3DEdgeSmall}" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
                    <Border x:Name="NavBorder" Background="{TemplateBinding Background}" BorderBrush="#8B5CF6" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter Effect="{DynamicResource DR3DText}"/></Border>
                    <Border CornerRadius="9" Visibility="{DynamicResource DR3DParts}" BorderBrush="#66FFFFFF" BorderThickness="1,1,1,0" IsHitTestVisible="False"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#55FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="0.5"/><GradientStop Color="#33000000" Offset="1"/></LinearGradientBrush></Border.Background></Border>
                    <Border CornerRadius="0,0,9,9" VerticalAlignment="Bottom" Height="3" Margin="1,0,1,1" Background="#55000000" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
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
        <Style x:Key="GreenNavButton" TargetType="Button" BasedOn="{StaticResource NavButton}"><Setter Property="Effect" Value="{DynamicResource DR3DButton}"/>
            <Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                <Grid x:Name="NavRoot" RenderTransformOrigin="0,0.5">
                    <Grid.RenderTransform><TranslateTransform X="0" Y="0"/></Grid.RenderTransform>
                    <Border CornerRadius="12" Background="{DynamicResource DR3DSlabA}" Margin="{DynamicResource DR3DEdgeSmall}" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
                    <Border x:Name="NavBorder" CornerRadius="12" BorderBrush="#CCFFFFFF" BorderThickness="1.2" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                        <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#4A9BFF" Offset="0"/><GradientStop Color="#1E5FD9" Offset="1"/></LinearGradientBrush></Border.Background>
                        <Grid>
                            <Border CornerRadius="12" VerticalAlignment="Top" Height="6" Margin="8,-4,8,0" Background="#38FFFFFF" IsHitTestVisible="False"/>
                            <ContentPresenter/>
                        </Grid>
                    </Border>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Trigger.EnterActions><BeginStoryboard><Storyboard>
                            <DoubleAnimation Storyboard.TargetName="NavRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="6" Duration="0:0:0.18"><DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                        </Storyboard></BeginStoryboard></Trigger.EnterActions>
                        <Trigger.ExitActions><BeginStoryboard><Storyboard>
                            <DoubleAnimation Storyboard.TargetName="NavRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.24"><DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                        </Storyboard></BeginStoryboard></Trigger.ExitActions>
                    </Trigger>
                </ControlTemplate.Triggers></ControlTemplate></Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="WingetNavButton" TargetType="Button" BasedOn="{StaticResource NavButton}"><Setter Property="Effect" Value="{DynamicResource DR3DButton}"/>
            <Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="Background" Value="#0061FF"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
                <Grid x:Name="NavRoot" RenderTransformOrigin="0,0.5">
                    <Grid.RenderTransform><TranslateTransform X="0" Y="0"/></Grid.RenderTransform>
                    <Border CornerRadius="9" Background="{DynamicResource DR3DSlabA}" Margin="{DynamicResource DR3DEdgeSmall}" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
                    <Border x:Name="NavBorder" Background="{TemplateBinding Background}" BorderBrush="#00E5FF" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter Effect="{DynamicResource DR3DText}"/></Border>
                    <Border CornerRadius="9,9,0,0" VerticalAlignment="Top" Height="17" Margin="1,1,1,0" Background="#33FFFFFF" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
                    <Border CornerRadius="0,0,9,9" VerticalAlignment="Bottom" Height="3" Margin="1,0,1,1" Background="#55000000" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
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
        <Style x:Key="AIChoice" TargetType="ToggleButton"><Setter Property="Effect" Value="{DynamicResource DR3DButton}"/>
            <Setter Property="Foreground" Value="#475467"/><Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="#D0D5DD"/>
            <Setter Property="FontSize" Value="12.5"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="Padding" Value="12,7"/>
            <Setter Property="Margin" Value="0,4"/><Setter Property="MinWidth" Value="124"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton">
                <Grid>
                <Border CornerRadius="10" Background="{DynamicResource DR3DSlabA}" Margin="{DynamicResource DR3DEdgeSmall}" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
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
                <Border CornerRadius="10,10,0,0" VerticalAlignment="Top" Height="15" Margin="2,2,2,0" Background="#40FFFFFF" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
                <Border CornerRadius="0,0,10,10" VerticalAlignment="Bottom" Height="3" Margin="2,0,2,2" Background="#40000000" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/>
                </Grid>
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
        <Style x:Key="Card" TargetType="Border"><Setter Property="Effect" Value="{DynamicResource DR3DCard}"/><Setter Property="Background" Value="{DynamicResource DR3DCardFace}"/><Setter Property="CornerRadius" Value="14"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="22"/><Setter Property="SnapsToDevicePixels" Value="True"/>
            <Setter Property="Effect" Value="{DynamicResource DR3DCardSoft}"/>
        </Style>
        <Style x:Key="HistoryRow" TargetType="Border"><Setter Property="Background" Value="Transparent"/><Setter Property="CornerRadius" Value="10"/><Setter Property="Padding" Value="14,12"/><Setter Property="BorderThickness" Value="1"/><Setter Property="BorderBrush" Value="Transparent"/><Setter Property="Margin" Value="0,0,0,4"/><Setter Property="SnapsToDevicePixels" Value="True"/>
            <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F6F9FD"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/></Trigger></Style.Triggers>
        </Style>
        <Style x:Key="TaskCheck" TargetType="CheckBox"><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="0,0,14,0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="LayoutTransform"><Setter.Value><ScaleTransform ScaleX="1.2" ScaleY="1.2"/></Setter.Value></Setter></Style>
        <Style x:Key="PresetChoiceButton" TargetType="Button"><Setter Property="Effect" Value="{DynamicResource DR3DButton}"/>
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
                    <Border x:Name="TitleLogo" Grid.Column="0" Width="26" Height="26" CornerRadius="7" Background="White" Margin="12,7,10,7">
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
                        <Border x:Name="SidebarLogo" Width="48" Height="48" CornerRadius="24" Background="#2E6DEB">
                            <TextBlock Text="✓" Foreground="White" FontSize="28" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
                            <TextBlock Text="DRDirect" Foreground="White" FontWeight="Bold" FontSize="24"/>
                            <TextBlock Text="PC Cleaner" Foreground="#B9C9DD" FontSize="16" FontWeight="SemiBold"/>
                            <TextBlock x:Name="VersionText" Foreground="#FFE14D" FontSize="14" FontWeight="SemiBold" Margin="0,4,0,0"/>
                        </StackPanel>
                    </StackPanel>
                </StackPanel>
                <!-- Scrolls on short screens (small laptops), so the last menu items never hide behind the Activate button -->
                <ScrollViewer x:Name="NavScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
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
                    <Button x:Name="NavDashboard" Style="{StaticResource NavButton}" Foreground="#FFE600" Tag="Active" Content="⌂   Dashboard"/>
                    <Button x:Name="NavModeToggle" Style="{StaticResource HeroGreenButton}" Margin="10,4,10,10" Padding="14,11" FontSize="15" FontWeight="Bold" Content="＋  Show all tools" ToolTip="Switch between the simple view and every tool"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFC04D" Offset="0"/><GradientStop Color="#F08200" Offset="1"/></LinearGradientBrush></Button.Background></Button>
                    <Button x:Name="NavProgress" Style="{StaticResource NavButton}" Content="◐   Maintenance progress" Visibility="Collapsed"/>
                    <TextBlock x:Name="NavHeadClean" Text="CLEAN" Foreground="#FFFF33" FontSize="12.5" FontWeight="ExtraBold" Margin="20,16,0,4"/>
                    <Button x:Name="NavCleanup" Style="{StaticResource NavButton}" Foreground="#FFE600" Content="✦   Clean my PC"/>
                    <Button x:Name="NavSpeed" Style="{StaticResource NavButton}" Foreground="#FFE600" Content="◈   Speed and space"/>
                    <Button x:Name="NavDuplicates" Style="{StaticResource NavButton}" Foreground="#22C16F" FontWeight="Bold" Content="⧉   Find duplicate files"/>
                    <Button x:Name="NavHibernate" Style="{StaticResource NavButton}" Foreground="#22D3EE" FontWeight="SemiBold" Content="☾   Hibernate" ToolTip="Turn Hibernate off to free several GB, or back on"/>
                    <Button x:Name="NavUninstaller" Style="{StaticResource GreenNavButton}" Margin="10,4,10,4" Padding="12,8" FontSize="13" ToolTip="Open the DRDirect Uninstaller Program to remove programs you no longer want"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="⌫" Foreground="White" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock Grid.Column="1" Text="DRDirect Uninstaller Program" Foreground="White" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></Grid></Button>
                    <TextBlock x:Name="NavHeadFix" Text="FIX &amp; PROTECT" Foreground="#FFFF33" FontSize="12.5" FontWeight="ExtraBold" Margin="20,16,0,4"/>
                    <Button x:Name="NavRepair" Style="{StaticResource NavButton}" Foreground="#FFE600"><StackPanel Orientation="Horizontal"><TextBlock Text="⚒   Fix Windows" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/><Grid Width="22" Height="22" Margin="10,0,0,0" VerticalAlignment="Center" Effect="{DynamicResource DR3DText}"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions><Rectangle Margin="0,0,1,1" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle><Rectangle Grid.Column="1" Margin="1,0,0,1" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle><Rectangle Grid.Row="1" Margin="0,1,1,0" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle><Rectangle Grid.Row="1" Grid.Column="1" Margin="1,1,0,0" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle></Grid></StackPanel></Button>
                    <Button x:Name="NavSecurity" Style="{StaticResource NavButton}" Foreground="#FFE600" Content="⬡   Check my security"/>
                    <Button x:Name="NavFullScan" Style="{StaticResource NavButton}" Foreground="#FFE600" Content="⛨   Full scan only" ToolTip="Runs one Microsoft Defender full scan and nothing else. It can take a long time."/>
                    <Button x:Name="NavSmartApp" Style="{StaticResource NavButton}" Foreground="#FFE600" Content="⛨   Smart App Control" ToolTip="Opens the Windows page where Smart App Control is switched on or off. The Cleaner changes nothing itself."/>
                    <Button x:Name="NavAI" Style="{StaticResource AINavButton}" Content="⊘   Switch off AI" Margin="10,4,10,4" ToolTip="Switch off AI in Windows and web browsers"/>
                    <TextBlock x:Name="NavHeadCheck" Text="CHECK" Foreground="#FFFF33" FontSize="12.5" FontWeight="ExtraBold" Margin="20,16,0,4"/>
                    <Button x:Name="NavHealth" Style="{StaticResource NavButton}" Foreground="#FACC15" Content="▰   Check my drives"/>
                    <Button x:Name="NavMemory" Style="{StaticResource NavButton}" Foreground="#FACC15" Content="▦   Check my RAM"/>
                    <Button x:Name="NavPowerHeat" Style="{StaticResource NavButton}" Foreground="#FACC15" Content="⚡   Check power and heat" ToolTip="Looks for signs of a failing power supply, dust or a PC that runs too hot"/>
                    <Button x:Name="NavHardware" Style="{StaticResource NavButton}" Content="▤   About my PC"/>
                    <Button x:Name="NavHistory" Style="{StaticResource NavButton}" Foreground="#22D3EE" FontWeight="SemiBold" Content="◷   Cleaning history" ToolTip="See what the Cleaner did, open the reports, and undo changes to settings"/>
                    <TextBlock x:Name="NavHeadUpdate" Text="UPDATE" Foreground="#FFFF33" FontSize="12.5" FontWeight="ExtraBold" Margin="20,16,0,4"/>
                    <Button x:Name="NavAppUpdates" Style="{StaticResource WingetNavButton}" Content="⭳   Update my apps" Margin="10,4,10,4" ToolTip="Update every app with winget, in a colour PowerShell window"/>
                    <Button x:Name="NavNoteButton" Content="Please read first  :)" Style="{StaticResource HeroGreenButton}" Margin="10,10,10,4" Padding="14,11" FontSize="15" FontWeight="Bold" ToolTip="Click to read a short, friendly note"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5BE584" Offset="0"/><GradientStop Color="#13A64A" Offset="1"/></LinearGradientBrush></Button.Background></Button>
                </StackPanel>
                </ScrollViewer>
                <Border x:Name="NavMoreHint" Grid.Row="1" Visibility="Collapsed" VerticalAlignment="Bottom" Height="64" Cursor="Hand" ToolTip="Scroll down for more tools"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0015253D" Offset="0"/><GradientStop Color="#F015253D" Offset="0.62"/><GradientStop Color="#FF15253D" Offset="1"/></LinearGradientBrush></Border.Background><TextBlock Text="▼   More tools below" Foreground="#FFC04D" FontSize="14" FontWeight="ExtraBold" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,8"/></Border>
                <StackPanel Grid.Row="2" Margin="16,14,16,24"><Border x:Name="RunStrip" Visibility="Collapsed" Background="#12306B" BorderBrush="#2E6DEB" BorderThickness="1" CornerRadius="9" Padding="12,10" Margin="0,0,0,12" Cursor="Hand" ToolTip="Click to go to the progress page"><StackPanel><TextBlock x:Name="RunStripTitle" Text="Working..." Foreground="White" FontWeight="SemiBold" FontSize="13"/><TextBlock x:Name="RunStripDetail" Text="" Foreground="#B9C9DD" FontSize="11" TextTrimming="CharacterEllipsis" Margin="0,2,0,6"/><ProgressBar x:Name="RunStripBar" Height="6" Minimum="0" Maximum="100" Value="0" Foreground="#2BE37A" Background="#2A3F66" BorderThickness="0"/></StackPanel></Border><Border x:Name="ActivateWrap" Margin="0,0,0,14" CornerRadius="8" Background="#1E4FA8" BorderBrush="#7FB0FF" BorderThickness="1" Padding="8,10" HorizontalAlignment="Stretch" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform x:Name="ActivateScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform><StackPanel><TextBlock x:Name="TrialCountdown" Text="" HorizontalAlignment="Center" Foreground="#D7E6FF" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,6" Visibility="Collapsed"/><Button x:Name="ActivateButton" Content="&#128273;  Activate this product" HorizontalAlignment="Center" Background="Transparent" BorderThickness="0" Cursor="Hand" Foreground="White" FontSize="14" FontWeight="Bold" Padding="0"/></StackPanel></Border><TextBlock x:Name="AdminStatus" Foreground="#9FB0C9" FontSize="12"/></StackPanel>
            </Grid>
        </Border>

        <Grid Grid.Column="1" Margin="34,26,34,28">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="0,0,0,20"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Orientation="Horizontal"><StackPanel><TextBlock x:Name="PageEyebrow" Text="THIS PC" Style="{StaticResource MutedText}" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="PageTitle" Text="Dashboard" Style="{StaticResource TitleText}"/></StackPanel><Border x:Name="AISearchBox" Visibility="Collapsed" Width="300" Height="40" CornerRadius="20" Background="White" BorderBrush="#7C3AED" BorderThickness="2" Margin="28,8,0,0" VerticalAlignment="Center"><Grid><TextBlock Text="🔍" FontSize="14" Margin="14,0,0,0" VerticalAlignment="Center" HorizontalAlignment="Left" Foreground="#7C3AED"/><TextBlock x:Name="AISearchHint" Text="Search AI items (Copilot, Edge...)" Margin="40,0,12,0" VerticalAlignment="Center" Foreground="#98A2B3" FontSize="13" IsHitTestVisible="False"/><TextBox x:Name="AISearchText" Background="Transparent" BorderThickness="0" Margin="38,0,12,0" VerticalContentAlignment="Center" FontSize="13" Foreground="#101828"/></Grid></Border><Border x:Name="DiskWarning" Visibility="Collapsed" Cursor="Hand" MinWidth="560" CornerRadius="24" Background="#FFF1F2" BorderThickness="3" Padding="20,10" Margin="28,6,0,0" VerticalAlignment="Center"><Border.BorderBrush><SolidColorBrush Color="#E5384A"/></Border.BorderBrush><Border.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><ColorAnimation Storyboard.TargetProperty="BorderBrush.Color" From="#E5384A" To="#1E90FF" Duration="0:0:0.35"/></Storyboard></BeginStoryboard></EventTrigger></Border.Triggers><StackPanel Orientation="Horizontal"><Ellipse Width="28" Height="28" Fill="#E5384A" Stroke="White" StrokeThickness="3" Margin="0,0,8,0" VerticalAlignment="Center"><Ellipse.Effect><DropShadowEffect ShadowDepth="0" BlurRadius="20" Opacity="0.9" Color="#E5384A"/></Ellipse.Effect><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.05" Duration="0:0:0.35"/></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Width="28" Height="28" Fill="#1E90FF" Stroke="White" StrokeThickness="3" Margin="0" VerticalAlignment="Center"><Ellipse.Effect><DropShadowEffect ShadowDepth="0" BlurRadius="20" Opacity="0.9" Color="#1E90FF"/></Ellipse.Effect><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><DoubleAnimation Storyboard.TargetProperty="Opacity" From="0.05" To="1" Duration="0:0:0.35"/></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><StackPanel VerticalAlignment="Center" Margin="16,0,0,0"><TextBlock x:Name="DiskWarningTitle" FontSize="20" FontWeight="ExtraBold" Foreground="#B42318"/></StackPanel><TextBlock x:Name="DiskWarningMore" Text="More info - click here" FontSize="16" FontWeight="SemiBold" Foreground="#1E5BD8" TextDecorations="Underline" Cursor="Hand" VerticalAlignment="Center" Margin="22,0,0,0"/></StackPanel></Border></StackPanel><Border Grid.Column="1" CornerRadius="16" Background="#E7F6EF" Padding="12,7" VerticalAlignment="Center"><TextBlock Text="●  Protected mode" Foreground="{StaticResource Success}" FontSize="12"/></Border></Grid>

            <Grid Grid.Row="1">
                <ScrollViewer x:Name="PageDashboard" VerticalScrollBarVisibility="Auto"><StackPanel>
<Border x:Name="UpdateBanner" Visibility="Collapsed" Background="#12C25B" CornerRadius="12" Padding="20,14" Margin="0,0,0,16"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Orientation="Horizontal" VerticalAlignment="Center"><TextBlock Text="&#10004;" Foreground="White" FontSize="22" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,12,0"/><TextBlock x:Name="UpdateBannerText" Text="There is a new update" Foreground="White" FontSize="18" FontWeight="Bold" VerticalAlignment="Center" TextWrapping="Wrap"/></StackPanel><Button x:Name="UpdateBannerButton" Grid.Column="1" Content="See what is new and update" Style="{StaticResource HeroButton}" Foreground="#0B7A3B" Margin="16,0,0,0"/></Grid></Border>
<Border Style="{StaticResource Card}" Effect="{DynamicResource DR3DShadow}" Padding="34" Margin="0,0,0,18" Background="{StaticResource HeroBrush}" BorderBrush="#2447B8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Border Grid.RowSpan="2" Margin="-34" CornerRadius="14" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}" BorderThickness="3,3,3,9" BorderBrush="#99FFFFFF"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#66FFFFFF" Offset="0"/><GradientStop Color="#14FFFFFF" Offset="0.30"/><GradientStop Color="#00000000" Offset="0.55"/><GradientStop Color="#99000820" Offset="1"/></LinearGradientBrush></Border.Background></Border><StackPanel HorizontalAlignment="Center"><TextBlock Text="START HERE" Effect="{DynamicResource DR3DHeroText}" HorizontalAlignment="Center" Foreground="#FFFF33" FontSize="12.5" FontWeight="ExtraBold"/><Grid HorizontalAlignment="Center" Margin="0,8,6,14"><TextBlock Text="Make my PC cleaner" Foreground="#0A1D78" FontSize="32" FontWeight="ExtraBold" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"><TextBlock.RenderTransform><TranslateTransform X="6" Y="6"/></TextBlock.RenderTransform><TextBlock.Effect><BlurEffect Radius="4"/></TextBlock.Effect></TextBlock><TextBlock Text="Make my PC cleaner" Foreground="#0A1D78" FontSize="32" FontWeight="ExtraBold" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"><TextBlock.RenderTransform><TranslateTransform X="4" Y="4"/></TextBlock.RenderTransform></TextBlock><TextBlock Text="Make my PC cleaner" Foreground="#1A35A8" FontSize="32" FontWeight="ExtraBold" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"><TextBlock.RenderTransform><TranslateTransform X="3" Y="3"/></TextBlock.RenderTransform></TextBlock><TextBlock Text="Make my PC cleaner" Foreground="#2447B8" FontSize="32" FontWeight="ExtraBold" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"><TextBlock.RenderTransform><TranslateTransform X="2" Y="2"/></TextBlock.RenderTransform></TextBlock><TextBlock Text="Make my PC cleaner" Foreground="#3A5FD0" FontSize="32" FontWeight="ExtraBold" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"><TextBlock.RenderTransform><TranslateTransform X="1" Y="1"/></TextBlock.RenderTransform></TextBlock><TextBlock Text="Make my PC cleaner" FontSize="32" FontWeight="ExtraBold"><TextBlock.Foreground><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFFFFF" Offset="0"/><GradientStop Color="#F4F8FF" Offset="0.48"/><GradientStop Color="#BFD4FF" Offset="0.52"/><GradientStop Color="#FFFFFF" Offset="1"/></LinearGradientBrush></TextBlock.Foreground></TextBlock></Grid><TextBlock Text="One click. We only do the safe things, and we ask you before anything starts." Effect="{DynamicResource DR3DHeroText}" Foreground="#C9D9FF" FontSize="16" TextWrapping="Wrap" MaxWidth="560" HorizontalAlignment="Center" TextAlignment="Center"/><WrapPanel Orientation="Horizontal" Margin="0,24,0,0" HorizontalAlignment="Center"><Button x:Name="SafeCleanButton" Content="Make my PC cleaner" Style="{StaticResource HeroGreenButton}" FontSize="15" FontWeight="Bold" Padding="20,9" Margin="0,0,10,10"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5BE584" Offset="0"/><GradientStop Color="#13A64A" Offset="1"/></LinearGradientBrush></Button.Background></Button><Button x:Name="SafePreviewButton" Content="Show me first" Style="{StaticResource HeroGreenButton}" Padding="18,9" Margin="0,0,10,10"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0E5A2D" Offset="0"/><GradientStop Color="#02240F" Offset="1"/></LinearGradientBrush></Button.Background></Button><Button x:Name="HeroUninstallButton" Style="{StaticResource HeroGreenButton}" Margin="0,0,10,10" ToolTip="Open the DRDirect Uninstaller Program to remove programs you no longer want"><StackPanel Orientation="Horizontal"><TextBlock Text="⌫" FontSize="14" Foreground="White" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock Text="DRDirect Uninstaller Program" Foreground="White" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Button></WrapPanel><TextBlock Text="✓  Settings changes can be undone.   ✓  Your files and passwords are never touched." Effect="{DynamicResource DR3DHeroText}" Foreground="White" FontSize="13.5" FontWeight="SemiBold" Margin="0,20,0,0" TextWrapping="Wrap" HorizontalAlignment="Center" TextAlignment="Center"/></StackPanel><WrapPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0,10,250,0"><CheckBox x:Name="SoundSwitch" Style="{StaticResource DRSwitch}" Effect="{DynamicResource DR3DHeroText}" Content="Sound" Margin="0,0,22,0" VerticalAlignment="Center" ToolTip="Sounds: a soft chime when a clean finishes, and a small tick when you point at a button"/><CheckBox x:Name="Buttons3DSwitch" Style="{StaticResource DRSwitch}" Effect="{DynamicResource DR3DHeroText}" Content="3D look" Margin="0,0,22,0" VerticalAlignment="Center" ToolTip="Turn the raised 3D look of the Cleaner on or off"/><CheckBox x:Name="Max3DSwitch" Style="{StaticResource DRSwitch}" Effect="{DynamicResource DR3DHeroText}" Content="Max 3D" Margin="0,0,22,0" VerticalAlignment="Center" ToolTip="Even deeper 3D: bigger shadows and thicker raised edges. Turns the 3D look on too."/><CheckBox x:Name="CrazyNuttySwitch" Style="{StaticResource DRSwitch}" Effect="{DynamicResource DR3DHeroText}" Content="Crazy Nutty 3D" Margin="0,0,22,0" VerticalAlignment="Center" ToolTip="Even more 3D than Max 3D?"/></WrapPanel><Button x:Name="HeroUpdateButton" Content="Check for updates" Style="{StaticResource HeroGreenButton}" Grid.Row="1" Margin="0,10,0,0" HorizontalAlignment="Right" VerticalAlignment="Top" Padding="18,9" ToolTip="Look for a newer version of the Cleaner"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#D2700F" Offset="0"/><GradientStop Color="#8F3800" Offset="1"/></LinearGradientBrush></Button.Background></Button></Grid></Border>
<UniformGrid Columns="3" Margin="0,0,0,22">
                            <Border x:Name="LastCleanCard" Style="{StaticResource Card}" Margin="0,0,12,0" BorderBrush="{StaticResource Violet}" BorderThickness="5,1,1,1"><Grid><StackPanel><StackPanel Orientation="Horizontal"><Border Style="{StaticResource StatIcon}" Background="{StaticResource VioletSoft}"><TextBlock Text="◷" Foreground="{StaticResource Violet}" FontSize="19" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="LAST CLEAN" Foreground="{StaticResource Violet}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock x:Name="LastCleanValue" Text="Not yet" FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock x:Name="LastCleanHint" Text="Shows here after your first clean" Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap"/><TextBlock x:Name="LastCleanQuickScan" Style="{StaticResource MutedText}" FontSize="12" Margin="0,10,0,0" TextWrapping="Wrap" Visibility="Collapsed"/><TextBlock x:Name="LastCleanFullScan" Style="{StaticResource MutedText}" FontSize="12" Margin="0,2,0,0" TextWrapping="Wrap" Visibility="Collapsed"/></StackPanel><Ellipse x:Name="LastCleanLightBlue" Width="14" Height="14" Fill="#1E90FF" Margin="-12,-12,0,0" HorizontalAlignment="Left" VerticalAlignment="Top" Visibility="Collapsed"><Ellipse.Effect><DropShadowEffect Color="#1E90FF" BlurRadius="14" ShadowDepth="0" Opacity="0.9"/></Ellipse.Effect></Ellipse><Ellipse x:Name="LastCleanLightRed" Width="14" Height="14" Fill="#E02424" Margin="0,-12,-12,0" HorizontalAlignment="Right" VerticalAlignment="Top" Visibility="Collapsed"><Ellipse.Effect><DropShadowEffect Color="#E02424" BlurRadius="14" ShadowDepth="0" Opacity="0.9"/></Ellipse.Effect></Ellipse></Grid></Border>
                            <Border Style="{StaticResource Card}" Margin="0,0,12,0" BorderBrush="{StaticResource Teal}" BorderThickness="5,1,1,1"><StackPanel><StackPanel Orientation="Horizontal"><Border Style="{StaticResource StatIcon}" Background="{StaticResource TealSoft}"><TextBlock Text="▰" Foreground="{StaticResource Teal}" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="FREE SPACE" Foreground="{StaticResource Teal}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock x:Name="FreeSpaceText" Text="Checking…" FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock Text="On your main drive" Style="{StaticResource MutedText}" FontSize="12"/></StackPanel></Border>
                            <Border x:Name="HealthCard" Style="{StaticResource Card}" BorderBrush="{StaticResource Amber}" BorderThickness="5,1,1,1"><StackPanel><StackPanel Orientation="Horizontal"><Border x:Name="HealthIconBox" Style="{StaticResource StatIcon}" Background="{StaticResource AmberSoft}"><TextBlock x:Name="HealthIcon" Text="⬡" Foreground="{StaticResource Amber}" FontSize="18" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="HealthLabel" Text="WINDOWS HEALTH" Foreground="{StaticResource Amber}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock x:Name="WindowsStatusText" Text="Checking..." FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock x:Name="WindowsStatusHint" Text="Takes a few seconds. Nothing is changed." Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap"/><Button x:Name="HealthCheckButton" Content="↻  Check again" Cursor="Hand" HorizontalAlignment="Left" Margin="0,10,0,0" Visibility="Collapsed" ToolTip="Look again, for example after fixing something. Nothing is changed."><Button.Template><ControlTemplate TargetType="Button"><TextBlock x:Name="LinkText" Text="{TemplateBinding Content}" Foreground="#2563EB" FontSize="13" FontWeight="SemiBold" Background="Transparent"/><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="LinkText" Property="TextDecorations" Value="Underline"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Button.Template></Button></StackPanel></Border>
                        </UniformGrid>
<Border x:Name="DashMoreHint" Visibility="Collapsed" Style="{StaticResource Card}" Padding="22,16" Margin="0,0,0,22" BorderBrush="#F08200" BorderThickness="2"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel VerticalAlignment="Center"><TextBlock Text="There are more tools here" FontSize="18" FontWeight="ExtraBold" Foreground="#9A4B00"/><TextBlock Text="Find duplicate files, speed and space, security, drive and memory checks, Hibernate, app updates and more." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,12,0"/></StackPanel><Button x:Name="DashShowAllButton" Grid.Column="1" Style="{StaticResource HeroGreenButton}" Padding="18,10" FontSize="15" FontWeight="Bold" Content="＋  Show all tools" VerticalAlignment="Center"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFC04D" Offset="0"/><GradientStop Color="#F08200" Offset="1"/></LinearGradientBrush></Button.Background></Button></Grid></Border>
<TextBlock x:Name="DashOtherTitle" Text="Other things you can do" FontSize="18" FontWeight="ExtraBold" Margin="0,0,0,10"/>
<UniformGrid x:Name="DashOtherGrid" Columns="3" Margin="0,0,0,14"><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,12,0"><StackPanel><TextBlock Text="Check my PC" FontSize="18" FontWeight="ExtraBold"/><TextBlock Text="Checks your drives (SSD and NVMe too), memory, processor and heat in one go. Nothing is changed." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="40"/><Button x:Name="ScanButton" Content="Check my PC" Style="{StaticResource HeroGreenButton}" FontSize="14" Padding="20,9" HorizontalAlignment="Left"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#4FC3FF" Offset="0"/><GradientStop Color="#1E6FE8" Offset="1"/></LinearGradientBrush></Button.Background></Button></StackPanel></Border><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,12,0"><StackPanel><TextBlock Text="Past results" FontSize="18" FontWeight="ExtraBold"/><TextBlock Text="Look at what the Cleaner did before." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="40"/><Button x:Name="LastReportButton" Content="See past results" Style="{StaticResource HeroGreenButton}" FontSize="14" Padding="20,9" HorizontalAlignment="Left"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#3EE0C8" Offset="0"/><GradientStop Color="#0E9F8A" Offset="1"/></LinearGradientBrush></Button.Background></Button></StackPanel></Border><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,12,0"><StackPanel><TextBlock Text="Update the Cleaner" FontSize="18" FontWeight="ExtraBold"/><TextBlock Text="Look for a newer version of the Cleaner." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="40"/><Button x:Name="CheckUpdatesButton" Content="Update this program" Style="{StaticResource HeroGreenButton}" FontSize="14" Padding="20,9" HorizontalAlignment="Left"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFC04D" Offset="0"/><GradientStop Color="#F08200" Offset="1"/></LinearGradientBrush></Button.Background></Button></StackPanel></Border></UniformGrid>
<StackPanel x:Name="DashMsTools" Margin="0,0,0,22"><TextBlock Text="MS Tools" FontSize="18" FontWeight="ExtraBold" Margin="0,0,0,10"/><Button x:Name="PCManagerButton" Style="{StaticResource HeroGreenButton}" FontSize="14" Padding="20,9" Foreground="White" HorizontalAlignment="Left" Margin="0,0,0,0" ToolTip="Opens Microsoft PC Manager, or its Microsoft Store page if it is not installed"><StackPanel Orientation="Horizontal"><Grid Width="22" Height="22" Margin="0,0,10,0" VerticalAlignment="Center" Effect="{DynamicResource DR3DText}"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions><Rectangle Margin="0,0,1,1" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle><Rectangle Grid.Column="1" Margin="1,0,0,1" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle><Rectangle Grid.Row="1" Margin="0,1,1,0" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle><Rectangle Grid.Row="1" Grid.Column="1" Margin="1,1,0,0" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle></Grid><TextBlock Text="Microsoft PC Manager" Foreground="White" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Button><Button x:Name="SmartAppControlButton" Style="{StaticResource HeroGreenButton}" FontSize="14" Padding="20,9" Foreground="White" HorizontalAlignment="Left" Margin="0,10,0,0" ToolTip="Opens the Windows page where Smart App Control is switched on or off. The Cleaner changes nothing itself."><TextBlock Text="Smart App Control" Foreground="White" FontWeight="SemiBold" VerticalAlignment="Center"/></Button><TextBlock Text="If it did not do the job, or you want your PC spotless, use DRDirect PC Cleaner for a deeper clean-up." Style="{StaticResource MutedText}" TextWrapping="Wrap" MaxWidth="560" HorizontalAlignment="Left" Margin="0,10,0,0"/></StackPanel>
<Button x:Name="DashNoteButton" Content="Please read first  :)" Style="{StaticResource SecondaryButton}" FontSize="13" Padding="16,8" HorizontalAlignment="Left" Margin="0,4,0,24" ToolTip="Click to read a short, friendly note"/>
<Expander x:Name="DashMoreOptions" Header="More options: choose how deep to clean, and see recent changes" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,18"><StackPanel Margin="0,12,0,0"><Grid Margin="0,0,0,18"><Grid.ColumnDefinitions><ColumnDefinition Width="1*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
                            <Grid Margin="0,0,16,10"><Border CornerRadius="14" Background="#16275A" Margin="0,10,0,0" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,0,10" Effect="{x:Null}">
                                <StackPanel>
                                    <TextBlock Text="HERE IS WHAT WILL CHANGE" Foreground="{StaticResource Blue}" FontSize="11" FontWeight="Bold"/>
                                    <TextBlock x:Name="SafePlanTitle" Text="What Safe mode does" FontSize="18" FontWeight="ExtraBold" Margin="0,6,0,2"/>
                                    <TextBlock Text="Pick a level to see its steps. Nothing has run yet, and you confirm before anything starts." Style="{StaticResource MutedText}" TextWrapping="Wrap"/>
                                    <StackPanel Orientation="Horizontal" Margin="0,10,0,0"><Button x:Name="SafeLevelSafeButton" Content="Easy" Style="{StaticResource SecondaryButton}" Padding="16,6"/><Button x:Name="SafeLevelMediumButton" Content="Deeper" Style="{StaticResource SecondaryButton}" Padding="16,6" Margin="8,0,0,0"/><Button x:Name="SafeLevelAdvancedButton" Content="Expert" Style="{StaticResource SecondaryButton}" Padding="16,6" Margin="8,0,0,0"/></StackPanel>
                                    <StackPanel x:Name="SafePlanList" Margin="0,8,0,6"/>
                                    <TextBlock x:Name="SafePlanNote" Foreground="#667085" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,10"/>
                                    <Button x:Name="SafePlanRunButton" Content="Yes, review and run" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Left"/>
                                </StackPanel>
                            </Border></Grid>
                            <Grid Grid.Column="1" Margin="0,0,0,10"><Border CornerRadius="14" Background="#16275A" Margin="0,10,0,0" Visibility="{DynamicResource DR3DParts}" IsHitTestVisible="False"/><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,0,10" Effect="{x:Null}">
                                <StackPanel>
                                    <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="HISTORY &amp; UNDO" Foreground="{StaticResource Blue}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/>
                                        <Button x:Name="DashboardHistoryButton" Grid.Column="1" Content="See all" Style="{StaticResource SecondaryButton}" Padding="12,5"/>
                                    </Grid>
                                    <TextBlock Text="Your recent changes" FontSize="18" FontWeight="ExtraBold" Margin="0,6,0,2"/>
                                    <StackPanel x:Name="DashboardHistoryList" Margin="0,8,0,10"/>
                                    <Button x:Name="UndoAllDashButton" Content="↺  Undo all AI changes" Style="{StaticResource SecondaryButton}" HorizontalAlignment="Left"/>
                                </StackPanel>
                            </Border></Grid>
                        </Grid></StackPanel></Expander>
<Border x:Name="TestModeBanner" Style="{StaticResource Card}" Background="#FFF4E3" BorderBrush="#F0C98C" Margin="0,18,0,0" Visibility="Collapsed"><TextBlock Text="TEST MODE is active. External Windows operations are simulated and file deletion is limited to the supplied test folder." Foreground="{StaticResource Warning}" TextWrapping="Wrap"/></Border>
</StackPanel></ScrollViewer>

                <Grid x:Name="PageTasks" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <!-- The cleanup level box stays at the top; the intro and the task list scroll under it. -->
                    <Grid Grid.Row="0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Border x:Name="CleanupPresetPanel" Grid.Row="0" Style="{StaticResource Card}" Padding="16" Margin="0,0,0,14" Visibility="Visible">
                        <StackPanel>
                            <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Orientation="Horizontal"><TextBlock Text="Choose cleanup level" FontSize="16" FontWeight="SemiBold"/><Border Background="#E8F0FF" CornerRadius="10" Padding="8,3" Margin="10,0,0,0"><TextBlock Text="ORDERED PRESETS" Foreground="#2563EB" FontSize="11" FontWeight="SemiBold"/></Border></StackPanel><Border Grid.Column="1" Background="#F4F7FF" BorderBrush="#C7D5F5" BorderThickness="1" CornerRadius="10" Padding="8,4" VerticalAlignment="Center"><StackPanel Orientation="Horizontal"><Button x:Name="CleanCheckAllButton" Content="Check all" Style="{StaticResource GlossyChoiceButton}" Padding="14,5" FontSize="12" Margin="0,0,8,4" ToolTip="Tick every item below, except the cookie item that signs you out"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#6F8FC4" Offset="0"/><GradientStop Color="#2E4F85" Offset="1"/></LinearGradientBrush></Button.Background></Button><Button x:Name="CleanCheckOffButton" Content="Check off" Style="{StaticResource GlossyChoiceButton}" Padding="14,5" FontSize="12" Margin="0,0,0,4" ToolTip="Untick every item below"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#B4BECE" Offset="0"/><GradientStop Color="#76849B" Offset="1"/></LinearGradientBrush></Button.Background></Button></StackPanel></Border></Grid>
                            <TextBlock Text="Safe = regular cleanup. Medium = full cleanup. Advanced = full cleanup plus Windows repair." Style="{StaticResource MutedText}" FontSize="12" Margin="0,4,0,12"/>
                            <UniformGrid Columns="3">
                                <StackPanel><TextBlock x:Name="PresetSafeDate" HorizontalAlignment="Center" Style="{StaticResource MutedText}" FontSize="12" Margin="0,0,0,4"/><Button x:Name="PresetSafe" Style="{StaticResource GlossyChoiceButton}" Padding="16,12" Margin="0,0,10,8"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5BE584" Offset="0"/><GradientStop Color="#13A64A" Offset="1"/></LinearGradientBrush></Button.Background><TextBlock Text="SAFE SCAN" Foreground="White" FontSize="15" FontWeight="Bold"/></Button></StackPanel>
                                <StackPanel><TextBlock x:Name="PresetMediumDate" HorizontalAlignment="Center" Style="{StaticResource MutedText}" FontSize="12" Margin="0,0,0,4"/><Button x:Name="PresetMedium" Style="{StaticResource GlossyChoiceButton}" Padding="16,12" Margin="0,0,10,8"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#4FC3FF" Offset="0"/><GradientStop Color="#1E6FE8" Offset="1"/></LinearGradientBrush></Button.Background><TextBlock Text="MEDIUM SCAN" Foreground="White" FontSize="15" FontWeight="Bold"/></Button></StackPanel>
                                <StackPanel><TextBlock x:Name="PresetAdvancedDate" HorizontalAlignment="Center" Style="{StaticResource MutedText}" FontSize="12" Margin="0,0,0,4"/><Button x:Name="PresetAdvanced" Style="{StaticResource GlossyChoiceButton}" Padding="16,12" Margin="0,0,0,8"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FF8A80" Offset="0"/><GradientStop Color="#D32020" Offset="1"/></LinearGradientBrush></Button.Background><TextBlock Text="ADVANCED SCAN" Foreground="White" FontSize="15" FontWeight="Bold"/></Button></StackPanel>
                            </UniformGrid>
                            <TextBlock x:Name="PresetDescription" Text="Choose a level, or select individual tasks below." Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0"/>
                        </StackPanel>
                    </Border>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel>
                    <Grid Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="TaskIntro" Text="Select exactly what you want to run. Nothing starts until you review and confirm the plan." Style="{StaticResource MutedText}" TextWrapping="Wrap"/><Border Grid.Column="1" Background="{StaticResource BlueSoft}" CornerRadius="14" Padding="12,6"><TextBlock x:Name="SelectionSummary" Text="0 selected" Foreground="{StaticResource Blue}" FontSize="12"/></Border></Grid>
                    <StackPanel x:Name="TaskList"/>
                    </StackPanel></ScrollViewer></Grid>
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
                    <Grid Grid.Row="3" Margin="0,16,0,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Border x:Name="RunRestartPanel" Grid.Row="0" Grid.ColumnSpan="3" Visibility="Collapsed" Background="#EEF4FF" BorderBrush="#C7D7F5" BorderThickness="1" CornerRadius="10" Padding="14,10" Margin="0,0,0,12"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="When the clean-up finishes, restart Windows:" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,14,0"/><ComboBox x:Name="RunRestartCombo" Grid.Column="1" MinWidth="290" FontSize="13" Padding="10,6" SelectedIndex="0"><ComboBoxItem Tag="0" Content="I will restart myself, when I am ready"/><ComboBoxItem Tag="10" Content="Right away (10 seconds after it finishes)"/><ComboBoxItem Tag="300" Content="In 5 minutes after it finishes"/><ComboBoxItem Tag="600" Content="In 10 minutes after it finishes"/></ComboBox></Grid></Border><TextBlock Grid.Row="1" x:Name="ProgressSafetyText" Text="Long-running Windows commands finish before the next task begins." Style="{StaticResource MutedText}" FontSize="12" VerticalAlignment="Center"/><Button x:Name="RestartButton" Grid.Row="1" Grid.Column="1" Content="Restart now" Style="{StaticResource PrimaryButton}" Margin="0,0,10,0" Visibility="Collapsed"/><Button x:Name="CancelPlanButton" Grid.Row="1" Grid.Column="2" Content="Stop after current task" Style="{StaticResource SecondaryButton}"/></Grid>
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
                            <ComboBox x:Name="RestartDelayCombo" SelectedIndex="0" FontSize="14" Padding="10,7">
                                <ComboBoxItem Tag="0" Content="I will restart myself, when I am ready"/>
                                <ComboBoxItem Tag="10" Content="Right away (10 seconds after it finishes)"/>
                                <ComboBoxItem Tag="300" Content="In 5 minutes after it finishes"/>
                                <ComboBoxItem Tag="600" Content="In 10 minutes after it finishes"/>
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
# Small screens (a 15 inch laptop): shrink everything to fit instead of opening
# a window bigger than the screen. Big screens are left exactly as they were.
try {
    $drArea = [Windows.SystemParameters]::WorkArea
    $drFit = [Math]::Max(0.6, [Math]::Min(1.0, [Math]::Min($drArea.Height / 900.0, $drArea.Width / 1300.0)))
    if ($drFit -lt 0.99) {
        $window.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform($drFit, $drFit)
        $window.MinWidth = [Math]::Floor($window.MinWidth * $drFit)
        $window.MinHeight = [Math]::Floor($window.MinHeight * $drFit)
        $window.Width = [Math]::Min($window.Width, $drArea.Width * 0.92)
        $window.Height = [Math]::Min($window.Height, $drArea.Height * 0.92)
    }
} catch { }


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

# The sidebar and the title bar show the real DRDirect logo instead of a drawn badge.
try {
    $logoB64 = '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'
    $logoBmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $logoBmp.BeginInit()
    $logoBmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $logoBmp.StreamSource = New-Object System.IO.MemoryStream (,[Convert]::FromBase64String($logoB64))
    $logoBmp.EndInit()
    $logoBmp.Freeze()
    foreach ($logoSpec in @(@('SidebarLogo', 58), @('TitleLogo', 30))) {
        $logoBox = $window.FindName($logoSpec[0])
        if ($logoBox) {
            $logoBox.Child = $null
            $logoBox.CornerRadius = New-Object System.Windows.CornerRadius(0)
            $logoBox.Width = $logoSpec[1]; $logoBox.Height = $logoSpec[1]
            $logoBox.Background = New-Object System.Windows.Media.ImageBrush($logoBmp)
            if ($logoSpec[0] -eq 'TitleLogo') { $logoBox.Margin = New-Object System.Windows.Thickness(12,5,10,5) }
        }
    }
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

# Open where the person left it: the size and place they gave the window last time are remembered,
# as long as they still fit on a screen that is connected now. A first start keeps the default.
try {
    $drWinKey = 'HKCU:\Software\DRDirect\PC Cleaner'
    $drSaved = Get-ItemProperty -LiteralPath $drWinKey -ErrorAction Stop
    $drW = [double]$drSaved.WinWidth; $drH = [double]$drSaved.WinHeight; $drL = [double]$drSaved.WinLeft; $drT = [double]$drSaved.WinTop
    if ($drW -ge 300 -and $drH -ge 300) {
        $drW = [Math]::Max($window.MinWidth,  [Math]::Min($drW, $wa.Width))
        $drH = [Math]::Max($window.MinHeight, [Math]::Min($drH, $wa.Height))
        $drVL = [Windows.SystemParameters]::VirtualScreenLeft;  $drVT = [Windows.SystemParameters]::VirtualScreenTop
        $drVW = [Windows.SystemParameters]::VirtualScreenWidth; $drVH = [Windows.SystemParameters]::VirtualScreenHeight
        $window.Width = $drW; $window.Height = $drH
        $window.Left = [Math]::Max($drVL, [Math]::Min($drL, $drVL + $drVW - $drW))
        $window.Top  = [Math]::Max($drVT, [Math]::Min($drT, $drVT + $drVH - $drH))
        $window.WindowStartupLocation = [Windows.WindowStartupLocation]::Manual
        if ([int]$drSaved.WinMax -eq 1) { $window.WindowState = [Windows.WindowState]::Maximized }
    }
} catch { }
$window.Add_Closing({
    try {
        $b = if ($window.WindowState -eq [Windows.WindowState]::Normal) { New-Object Windows.Rect($window.Left, $window.Top, $window.Width, $window.Height) } else { $window.RestoreBounds }
        if ($b.Width -lt 300 -or $b.Height -lt 300) { return }
        if (-not (Test-Path -LiteralPath $drWinKey)) { New-Item -Path $drWinKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $drWinKey -Name 'WinLeft'   -Value ([int][Math]::Round($b.Left))   -Type DWord
        Set-ItemProperty -LiteralPath $drWinKey -Name 'WinTop'    -Value ([int][Math]::Round($b.Top))    -Type DWord
        Set-ItemProperty -LiteralPath $drWinKey -Name 'WinWidth'  -Value ([int][Math]::Round($b.Width))  -Type DWord
        Set-ItemProperty -LiteralPath $drWinKey -Name 'WinHeight' -Value ([int][Math]::Round($b.Height)) -Type DWord
        Set-ItemProperty -LiteralPath $drWinKey -Name 'WinMax'    -Value ([int]($window.WindowState -eq [Windows.WindowState]::Maximized)) -Type DWord
    } catch { }
})

function Get-Control { param([string]$Name) $window.FindName($Name) }

$ui = @{}
@('NavScroll','NavMoreHint','NavHeadClean','NavHeadFix','NavHeadCheck','DashMoreHint','DashShowAllButton','NavModeToggle','NavHeadUpdate','DashOtherTitle','DashOtherGrid','DashMsTools','SmartAppControlButton','NavSmartApp','NavFullScan','DashMoreOptions','SoundSwitch','Max3DSwitch','CrazyNuttySwitch','DashNoteButton','NavNoteButton','AISearchBox','AISearchText','AISearchHint','RestartDelayPanel','RestartDelayCombo','CustomTitleBar','TitleDragArea','TitleMinButton','TitleMaxButton','TitleCloseButton','NavDashboard','NavCleanup','NavRepair','NavSecurity','NavHealth','NavMemory','NavPowerHeat','NavSpeed','NavHibernate','UpdateBanner','UpdateBannerText','DiskWarning','DiskWarningTitle','DiskWarningMore','UpdateBannerButton','HeroUpdateButton','RunRestartPanel','RunRestartCombo','RunStrip','RunStripTitle','RunStripDetail','RunStripBar','NavHistory','NavProgress','ActivateButton','ActivateWrap','ActivateScale','TrialCountdown','AdminStatus','VersionText','PageTitle','PageEyebrow','FreeSpaceText','WindowsStatusText','LastCleanCard','LastCleanLightBlue','LastCleanLightRed','LastCleanValue','LastCleanHint','LastCleanQuickScan','LastCleanFullScan','CleanCheckAllButton','CleanCheckOffButton','PresetSafeDate','PresetMediumDate','PresetAdvancedDate','ScanButton','HealthCheckButton','HealthCard','HealthIconBox','HealthIcon','HealthLabel','WindowsStatusHint','LastReportButton','TestModeBanner','PageDashboard','PageTasks','TaskIntro','SelectionSummary','CleanupPresetPanel','PresetSafe','PresetMedium','PresetAdvanced','PresetDescription','TaskList','ReviewButton','PageProgress','ProgressScanLevel','ProgressHeading','ProgressMessage','ProgressPercent','OverallProgress','ProgressList','CleaningAnimation','CleaningCaption','CleanDone','CleanDoneScale','CleanDoneTick','CleanDoneSub','ProgressSafetyText','RestartButton','CancelPlanButton','PageHistory','OpenReportsButton','ClearHistoryButton','HistoryList','DashboardHistoryList','DashboardHistoryButton','NavHardware','PageHardware','PageAppUpdates','NavAppUpdates','AppUpdatesStatus','ListAppUpdatesButton','UpdateAllAppsButton','HardwareList','CheckDriversButton','PCManagerButton','NavDuplicates','NavUninstaller','HeroUninstallButton','NavAI','PageDuplicates','OpenDuplicatesButton','CheckUpdatesButton','DuplicateStatus','BusyOverlay','OverlayTitle','OverlayMessage','OverlayProgress','OverlayPercent','OverlayContinueButton','ConfirmOverlay','ConfirmList','ConfirmWarning','ConfirmWarningText','ConfirmationCheck','ConfirmBackButton','ConfirmRunButton','SafeCleanButton','UndoAllButton','SafePreviewButton','SafePlanList','SafePlanRunButton','UndoAllDashButton','SafePlanTitle','SafePlanNote','SafeLevelSafeButton','SafeLevelMediumButton','SafeLevelAdvancedButton','Buttons3DSwitch') | ForEach-Object { $ui[$_] = Get-Control $_ }

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
$script:DRNoRestartTaskIds = @('health.chkdsk','health.drive-check','health.pc-checkup','health.ram-check','health.power-heat-check','health.ram-test','health.boost-memory','health.startup-apps','health.large-files','health.php-check','security.checkup','cleanup.hibernate-off','cleanup.hibernate-on','ai.check','ai.gmail','ai.office-copilot','ai.edge-button','ai.copilot-key','ai.remove-models','ai.adobe','ai.adobe.on','ai.zoom','ai.zoom.on',
    'ai.gmail.on','ai.office-copilot.on','ai.edge-button.on','ai.copilot-key.on',
    'ai.copilot-app.on','ai.m365-app.on','ai.chatgpt-app.on','ai.claude-app.on',
    'ai.edge.uninstall','ai.chrome.uninstall','ai.brave.uninstall','ai.firefox.uninstall',
    'ai.copilot-app.uninstall','ai.m365-app.uninstall','ai.chatgpt-app.uninstall','ai.claude-app.uninstall',
    'ai.chrome.reinstall','ai.brave.reinstall','ai.firefox.reinstall')
# The "Turn off" choices "Turn off all AI" picks, filled as the AI rows are drawn.
$script:DRCheckWarned = @{}
$script:DRCheckSevere = @{}
$script:DRNavLights = @{}
$script:DRNavLightTimer = $null
$script:DRNavLightOn = $false
$script:DRNavState = @{}
$script:DRSavedSelection = $null
$script:DRWasBusy = $false
$script:DRFinishedUnseen = $false
$script:DRAISearchRefresh = $false
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
$script:DRToolLimit = $null; $script:DRScanStart = $null; $script:DRScanTask = $null; $script:DRScanGuess = 1200.0
$script:restartDelaySeconds = 0
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

# Flashing red and blue warning on the Dashboard when C: is 80% full or more. A drive
# this full slows Windows down and can make updates and saves fail.
function Get-DRDiskWarning {
    param([double]$Size, [double]$Free, [int]$Threshold = 80, [string]$Letter = 'C')
    if ($Size -le 0) { return $null }
    $usedPercent = [int][math]::Round(100 * ($Size - $Free) / $Size)
    if ($usedPercent -lt $Threshold) { return $null }
    [pscustomobject]@{
        UsedPercent = $usedPercent
        Letter      = $Letter
        Title       = ('Your {0}: drive is {1}% full' -f $Letter, $usedPercent)
        Text        = ('Only {0} is free. Windows needs room to breathe: a drive this full runs slower, and updates and saving files can fail. Please clean it out soon.' -f (Format-Bytes $Free))
    }
}

function Get-DRDiskWarningInfo {
    param($Warning)
    ("Your {2}: drive is {0}% full ({1}).`r`n`r`n" -f $Warning.UsedPercent, ($Warning.Text -replace '^Only (.+?) is free\..*$', '$1 free'), $Warning.Letter) +
    "Windows needs room to breathe. A drive that is nearly full stops working properly, and without free space things start to go wrong. If it stays this full:`r`n`r`n" +
    "  - The PC gets slower, and programs can freeze or crash.`r`n" +
    "  - Windows updates can fail to install, so the PC misses security fixes.`r`n" +
    "  - YOU COULD LOSE DATA: files you are saving can fail to save or be damaged, and a crash while the drive is full can lose work you have not saved.`r`n" +
    "  - In bad cases Windows may have trouble starting.`r`n`r`n" +
    ("TO PREVENT LOSING DATA, YOU NEED TO CLEAN SOME SPACE OUT OF {0}: NOW. Click" -f $Warning.Letter) +
    " Yes below to open Clean my PC and clear junk files, then use Find large files, or move photos and videos to another drive. Try to keep at least 20% of the drive free."
}

function Show-DRDiskWarningInfo {
    if (-not $script:diskWarning) { return }
    $answer = [Windows.MessageBox]::Show(((Get-DRDiskWarningInfo -Warning $script:diskWarning) + "`r`n`r`nOpen Clean my PC now?"), ('Why your {0}: drive needs space' -f $script:diskWarning.Letter), 'YesNo', 'Warning')
    if ($answer -eq 'Yes') { Set-Page 'Cleanup' }
}

function Update-DRDiskWarning {
    # Every fixed drive is checked; the fullest one is the one the banner names.
    $warning = $null
    try {
        foreach ($disk in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2 OR DriveType=3' -ErrorAction Stop)) {
            $found = Get-DRDiskWarning -Size ([double]$disk.Size) -Free ([double]$disk.FreeSpace) -Letter ([string]$disk.DeviceID).TrimEnd(':')
            if ($found -and (-not $warning -or $found.UsedPercent -gt $warning.UsedPercent)) { $warning = $found }
        }
    } catch { $warning = $null }
    $script:diskWarning = $warning
    if ($warning) {
        $ui.DiskWarningTitle.Text = $warning.Title
        $ui.DiskWarning.ToolTip = $warning.Text
        $ui.DiskWarning.Visibility = 'Visible'
    } else {
        $ui.DiskWarning.Visibility = 'Collapsed'
    }
}

function Set-Page {
    param([string]$Name)
    $ui.PageDashboard.Visibility = if ($Name -eq 'Dashboard') { 'Visible' } else { 'Collapsed' }
    if ($Name -eq 'Dashboard') { Update-DRDiskWarning }
    $ui.PageTasks.Visibility = if ($Name -in @('Cleanup','Repair','Security','Health','Memory','Speed','Hibernate','AI')) { 'Visible' } else { 'Collapsed' }
    $ui.PageProgress.Visibility = if ($Name -eq 'Progress') { 'Visible' } else { 'Collapsed' }
    $ui.PageHistory.Visibility = if ($Name -eq 'History') { 'Visible' } else { 'Collapsed' }
    $ui.PageDuplicates.Visibility = if ($Name -eq 'Duplicates') { 'Visible' } else { 'Collapsed' }
    $ui.PageHardware.Visibility = if ($Name -eq 'Hardware') { 'Visible' } else { 'Collapsed' }
    $ui.PageAppUpdates.Visibility = if ($Name -eq 'AppUpdates') { 'Visible' } else { 'Collapsed' }
    $ui.PageTitle.Text = switch ($Name) { 'Cleanup' {'Clean my PC'} 'Repair' {'Fix Windows problems'} 'Security' {'Check my security'} 'Health' {'Check my drives'} 'Memory' {'Check my memory'} 'Speed' {'Speed and space'} 'Hibernate' {'Hibernate'} 'Hardware' {'About my PC'} 'History' {'Cleaning history'} 'Duplicates' {'Find duplicate files'} 'AI' {'Switch off AI'} 'AppUpdates' {'Update my apps'} 'Progress' {'Maintenance progress'} default {$Name} }
    $script:currentCategory = $Name
    $ui.AISearchBox.Visibility = if ($Name -eq 'AI') { 'Visible' } else { 'Collapsed' }
    if ($Name -ne 'AI' -and $ui.AISearchText.Text) { $ui.AISearchText.Text = '' }
    $ui.CleanupPresetPanel.Visibility = if ($Name -eq 'Cleanup') { 'Visible' } else { 'Collapsed' }
    $navMap = @{ Dashboard='NavDashboard'; Cleanup='NavCleanup'; Repair='NavRepair'; Security='NavSecurity'; Health='NavHealth'; Memory='NavMemory'; Speed='NavSpeed'; Hibernate='NavHibernate'; History='NavHistory'; Progress='NavProgress'; Duplicates='NavDuplicates'; Hardware='NavHardware'; AppUpdates='NavAppUpdates'; AI='NavAI' }
    foreach ($key in $navMap.Keys) { $ui[$navMap[$key]].Tag = if ($key -eq $Name) { 'Active' } else { $null } }
    if ($Name -in @('Cleanup','Repair','Security','Health','Memory','Speed','Hibernate','AI')) { Show-TaskCategory $Name }
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
        return 'Full cleanup: Safe plus Windows Disk Cleanup and game launcher caches.'
    }

    if ($Preset -eq 'Advanced') {
        return 'Everything in Medium plus developer caches, the previous Windows installation (Windows.old), icon cache, jump lists, memory dumps, old restore points, event logs, a Defender quick scan, and full Windows repair: restore point, DISM, SFC, and Windows Update repair. Cookies and the network reset stay manual.'
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
        # Wipes only free space after the Recycle Bin is emptied, so nothing kept is touched.
        'cleanup.ssd-shred',
        'cleanup.prefetch',
        'cleanup.wu-download-cache',
        'cleanup.old-update-backups',
        'cleanup.thumbnail-cache',
        'cleanup.shader-cache',
        'cleanup.wer-queue',
        'cleanup.delivery-optimization-cache',
        # Windows rebuilds this list on its own and nothing is lost with it.
        'cleanup.muicache',
        # Only changes a Notepad setting and skips if Notepad is open.
        'cleanup.notepad-fresh',
        # A quick Windows Defender scan after the clean. It only looks for threats; no files are changed by the scan itself.
        'security.quick-scan'
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
    # Windows traces: each loses a convenience list the person may notice is
    # empty - what they last copied, the Run box drop-down, past searches -
    # but no file of theirs, so a full cleanup takes them.
    $traceIds = @(
        'cleanup.clipboard',
        'cleanup.run-history',
        'cleanup.search-history',
        'cleanup.recent-docs'
    )
    # Compacting browser databases skips any browser that is open, so a full
    # cleanup can include it without risking a file the browser is using.
    $mediumIds = $safeIds + @('cleanup.disk-cleanup', 'cleanup.browser-compact', 'cleanup.game-caches') + $cloudCacheIds + $traceIds
    # Apart from the Recycle Bin, Safe and Medium never pre-select anything that
    # loses something the person cannot get back. Advanced is the full sweep and
    # takes all of it - icon cache (closes Explorer windows), jump lists (loses
    # pins), memory dumps, old restore points and event logs - except cookies,
    # which signs the person out and so is only ever ticked by hand.
    $advancedIds = $mediumIds + @(
        'cleanup.dev-caches',
        'cleanup.windows-old',
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
                ($Task.Category -eq 'Repair' -and $Task.Id -notin @('repair.network-reset','repair.font-cache','health.chkdsk','health.ram-test','cleanup.hibernate-off','cleanup.hibernate-on')) -or
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
        # Speed and space only looks at the PC, so a cleanup level never unticks it.
        foreach ($task in @($catalog | Where-Object { $_.Category -eq 'Speed' })) { $selection[$task.Id] = $true }

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
        $line = New-Object Windows.Controls.TextBlock -Property @{ TextWrapping = 'Wrap'; FontSize = 15; Margin = '0,5,0,0' }
        $dot = New-Object Windows.Documents.Run -ArgumentList '●  '
        # Same colours as the row banners below: green when the AI is on, red when it is off.
        $dot.Foreground = if ($item.On -or ([string]$item.Text -like '*(kept)*')) { '#16A34A' } else { '#E11D48' }
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
            Foreground = '#172033' }))
        [void]$panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{
            Text = 'Gmail, Zoom, Word and Excel and the Edge button cannot be read from here.'
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
    if (@($TaskIds | Where-Object { $_ -in @('health.drive-check', 'health.ram-check', 'health.power-heat-check', 'health.pc-checkup') }).Count) {
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
        # These two only open the app, and the last click is the person's, so the button says so.
        'ai.edge-button'   { '↗  Open Edge to hide it' }
        'ai.office-copilot' { '↗  Open Word to turn off' }
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
    if ($id -eq 'ai.claude-app') {
        # The Claude app has no setting to switch, so Turn off and Turn back on act on the Claude website
        # (blocked or open in the browsers). The app itself is only touched by Remove below.
        $blockStatus = @($script:DRAIStatus | Where-Object { $_.TaskId -eq 'ai.claude-block' }) | Select-Object -First 1
        $blockOpen = [bool]($blockStatus -and $blockStatus.CanOff -and $blockStatus.State -eq 'On')
        $blockCanOn = [bool]($blockStatus -and $blockStatus.CanOn)
        $siteOff = New-DRAIChoiceButton -Label '✕  Turn off' -Kind 'Off' -TaskId 'ai.claude-block' -Enabled $blockOpen -Reason 'Already off: the Claude website is blocked.' -Active (-not $blockOpen)
        $siteOn = New-DRAIChoiceButton -Label '✓  Turn back on' -Kind 'On' -TaskId 'ai.claude-block.on' -Enabled $blockCanOn -Reason 'Already on - the Cleaner has not turned it off.' -Active $blockOpen
        [void]$panel.Children.Add($siteOff); [void]$panel.Children.Add($siteOn)
    }
    $offButton = New-DRAIChoiceButton -Label $offLabel -Kind $offKind -TaskId $id -Enabled $canOff -Reason $offReason -Active $isOff
    [void]$panel.Children.Add($offButton)
    if ($id -eq 'ai.restore') { $script:DRAIRestoreButton = $offButton }
    # "Turn off all AI" picks everything the Cleaner can finish by itself.
    # Claude is never part of it: DRDirect keeps Claude.
    if ($offKind -eq 'Off' -and [string]$Task.Risk -ne 'Guided' -and $id -notin @('ai.claude-app','ai.claude-block')) { [void]$script:DRAIOffButtons.Add($offButton) }

    if (@($catalog | Where-Object { $_.Id -eq $onId }).Count) {
        $onLabel = switch ($id) {
            'ai.edge-button'    { '↗  Open Edge to show it' }
            'ai.office-copilot' { '↗  Open Word to turn on' }
            default             { if ($id -like 'ai.*-app') { '↻  Reinstall' } else { '✓  Turn back on' } }
        }
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
        Text = 'One click picks every "Turn off", "Remove" and "Delete" below that the Cleaner can do by itself. Claude is always left alone. Gmail, Word and the Edge button each open their own page, so pick those one by one. Nothing runs until you review and confirm.'
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

# Tasks that undo each other. Ticking one unticks the other, so a plan can never
# switch a setting off and straight back on.
$script:DRConflictingTasks = @{
    'cleanup.hibernate-off'           = 'cleanup.hibernate-on'
    'cleanup.hibernate-on'            = 'cleanup.hibernate-off'
    'security.typing-privacy'         = 'security.typing-privacy-restore'
    'security.typing-privacy-restore' = 'security.typing-privacy'
    'security.win11-extras'           = 'security.win11-extras-restore'
    'security.win11-extras-restore'   = 'security.win11-extras'
    'security.telemetry-off'          = 'security.telemetry-off-restore'
    'security.telemetry-off-restore'  = 'security.telemetry-off'
    'security.compat-task-off'        = 'security.compat-task-on'
    'security.compat-task-on'         = 'security.compat-task-off'
}
function Clear-DRConflictingTask {
    param([string]$TaskId)
    $other = $script:DRConflictingTasks[$TaskId]
    if (-not $other -or -not $selection[$other]) { return }
    $selection[$other] = $false
    foreach ($row in @($ui.TaskList.Children)) {
        $box = $null
        try { $box = $row.Child.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.Tag -eq $other } | Select-Object -First 1 } catch { }
        if ($box) { $box.IsChecked = $false }
    }
}

# These tasks are always run on their own: the Memory test needs a restart and takes an hour or
# more, CHKDSK works the drive hard, and Windows Update repair resets services that other repairs
# depend on. Ticking one clears every other tick, and ticking anything else clears them.
$script:DRRunsAloneTaskIds = @('health.ram-test','health.chkdsk','repair.windows-update')
function Set-DRVisibleTick {
    param([string]$TaskId, [bool]$Value)
    foreach ($row in @($ui.TaskList.Children)) {
        $box = $null
        try { $box = $row.Child.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.Tag -eq $TaskId } | Select-Object -First 1 } catch { }
        if ($box -and $box.IsChecked -ne $Value) { $box.IsChecked = $Value }
    }
}
function Clear-DRForRunsAlone {
    param([string]$TaskId)
    if ($script:DRRunsAloneTaskIds -contains $TaskId) {
        foreach ($key in @($selection.Keys | Where-Object { $_ -ne $TaskId })) {
            if ($selection[$key]) { $selection[$key] = $false; Set-DRVisibleTick -TaskId $key -Value $false }
        }
    } else {
        foreach ($alone in $script:DRRunsAloneTaskIds) {
            if ($selection[$alone]) { $selection[$alone] = $false; Set-DRVisibleTick -TaskId $alone -Value $false }
        }
    }
}

# Last safety net before a plan is shown or run: if both tasks of an undoing pair somehow
# ended up selected, keep the one that changes something and drop the one that undoes it.
function Remove-DRConflictingSelections {
    foreach ($undo in @('cleanup.hibernate-on','security.typing-privacy-restore','security.win11-extras-restore','security.telemetry-off-restore','security.compat-task-on')) {
        $other = $script:DRConflictingTasks[$undo]
        if ($selection[$undo] -and $selection[$other]) { $selection[$undo] = $false }
    }
    # The Memory test and CHKDSK are dropped if anything else is selected with them. Windows Update
    # repair is left out of this check on purpose: the Advanced full sweep still includes it.
    $picked = @($selection.Keys | Where-Object { $selection[$_] -and $_ -ne 'safety.restore-point' })
    if ($picked.Count -gt 1) {
        foreach ($alone in @('health.ram-test','health.chkdsk')) { if ($selection[$alone]) { $selection[$alone] = $false } }
    }
}

function New-TaskRow {
    # $Number is what the person reads out when they say which item they do
    # not want. It counts the rows actually on screen, so it stays 1..n even
    # though a level hides the tasks it will not run.
    param($Task, [int]$Number = 0)
    $border = New-Object Windows.Controls.Border
    $border.Style = $window.Resources['Card']
    $border.Margin = '0,0,0,10'

    # Only the cookie/sign-out task gets the loud treatment; every other row stays plain.
    $risk = [string]$Task.Risk
    $isLoud = $risk -eq 'SignOut'
    # The slow tasks get the same framed look, but their warning is about time, not sign-ins.
    $longTasks = @{
        'health.ram-test'         = @{ Badge = 'CAN TAKE 1 HOUR OR MORE'; Caution = 'Checking your RAM could take 1 hour or more, depending on your system. Windows has to restart to run it, so save your work first. Only tick it if you are ready to wait. The Cleaner never restarts the PC by itself.' }
        'security.full-scan'      = @{ Badge = 'CAN TAKE 1 HOUR OR MORE'; Caution = 'If you have not done a full scan for a while, please do one. Depending on your system, a full scan can take 1 hour or more. You can keep using the PC while it runs, but it may feel slower. Only tick it if you are ready to wait.' }
        'repair.dism-health'      = @{ Badge = 'CAN TAKE AN HOUR'; Caution = 'This repair can take up to an hour or more, depending on your system. It can look stuck for a while, so please let it finish. You can keep using the PC, but it may feel slower. Only tick it if you are ready to wait.' }
        'repair.component-cleanup' = @{ Badge = 'CAN TAKE 30 MIN OR MORE'; Caution = 'This clean-up can take 30 minutes or more, depending on your system. It can look stuck for a while, so please let it finish. Only tick it if you are ready to wait.' }
        'repair.sfc'              = @{ Badge = 'CAN TAKE 30 MIN OR MORE'; Caution = 'This scan can take 30 minutes or more, depending on your system. It can sit at the same percentage for a while, so please let it finish. Only tick it if you are ready to wait.' }
        'security.remove-exclusions' = @{ Badge = 'ONLY LOOKS'; Icon = '✔'; Caution = 'Shows which folders, programs and file types Defender skips, and marks any that look risky. Nothing is ever removed - exclusions you added on purpose, like a work or tools folder, always stay.' }
        'security.sweep'          = @{ Badge = 'ONLY LOOKS'; Icon = '✔'; Caution = 'Looks for signs of spyware and adware and shows a list. Nothing is ever changed or removed, because some of these can be normal on your PC.' }
        'health.chkdsk'           = @{ Badge = 'CAN TAKE 30 MIN OR MORE'; Caution = 'A deep drive test can take 30 minutes or more, depending on the size and speed of your drive. Windows keeps running, but the PC may feel slower. Only tick it if you are ready to wait.' }
    }
    $longInfo = $longTasks[[string]$Task.Id]
    $isLongTest = [bool]$longInfo

    if ($isLoud) {
        # A full red ring on all four sides, not just the left accent bar, so the
        # one task that can sign the user out cannot be skimmed past.
        $accent = @{ Badge='#FDE2E2'; BadgeInk='#A32020'; Label='⚠  SIGNS YOU OUT' }
        $border.Background = '#FFFAF0'
        $border.BorderBrush = '#C63C3C'
        $border.BorderThickness = '3'
    } elseif ($isLongTest) {
        $accent = @{ Badge='#FDE2E2'; BadgeInk='#A32020'; Label=($(if ($longInfo.ContainsKey('Icon')) { $longInfo['Icon'] } else { '⏱' }) + '  ' + $longInfo['Badge']) }
        $border.Background = '#FFFAF0'
        $border.BorderBrush = '#C63C3C'
        $border.BorderThickness = '3'
    } else {
        $accent = @{ Badge='#EEF2F7'; BadgeInk='#526079'; Label=$Task.Risk }
    }

    # AI Remover rows share the page's violet and say plainly what each one does.
    $aiStatus = $null
    if ($Task.Category -eq 'AI') {
        $aiLabel = if ($Task.Id -eq 'ai.restore') { 'UNDO' } elseif ($Task.Id -eq 'ai.check') { 'ONLY LOOKS' } elseif ($risk -eq 'Cleanup') { 'FREES SPACE' } elseif ($risk -eq 'Confirm') { 'UNINSTALLS' } elseif ($risk -eq 'Guided') { 'OPENS A WINDOW - YOU FINISH IT' } else { 'CAN BE UNDONE' }
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
        # The first thing on the page, so it glows cyan to blue and stands apart from the rows under it.
        if ($Task.Id -eq 'ai.check') {
            $border.Background = '#E9FBFF'
            $border.Tag = '#E9FBFF'
            $border.BorderThickness = '4'
            $border.Margin = '0,0,0,22'
            $border.Padding = '30,26'
            Start-DRAIGlowEdge -Card $border -From '#06B6D4' -To '#2563EB'
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
        Clear-DRConflictingTask -TaskId ([string]$sender.Tag)
        Clear-DRForRunsAlone -TaskId ([string]$sender.Tag)
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
    # A long AI or slow-task title lets its badge drop to the next line instead of cutting it off.
    $titlePanel = if ($Task.Category -eq 'AI' -or $isLongTest) { New-Object Windows.Controls.WrapPanel } else { New-Object Windows.Controls.StackPanel -Property @{ Orientation='Horizontal' } }
    # The number takes the colour of the level it belongs to, matching the
    # SAFE / MEDIUM / ADVANCED buttons above the list, so a row read out over the
    # phone carries which level it came from.
    $numberInk = switch ($script:cleanupLevel) {
        'Safe'     { '#00FF66' }
        'Medium'   { '#0057D9' }
        'Advanced' { '#FF1744' }
        default    { '#667085' }
    }
    $name = New-Object Windows.Controls.TextBlock -Property @{ FontWeight='SemiBold'; FontSize=15; VerticalAlignment='Center' }
    if ($Number -gt 0) {
        [void]$name.Inlines.Add((New-Object Windows.Documents.Run -Property @{
            Text = ('{0}.  ' -f $Number)
            Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString($numberInk)
            FontWeight = 'Bold'
        }))
    }
    [void]$name.Inlines.Add((New-Object Windows.Documents.Run -Property @{ Text = [string]$Task.Name }))
    # AI Remover rows show every product name (Edge, Chrome, Brave, Firefox, Gmail, Claude...) in big bold letters.
    if ($Task.Category -eq 'AI') {
        $title = [string]$Task.Name
        $brand = $null
        if ($title.Contains(': ')) { $brand = $title.Substring(0, $title.IndexOf(': ')) }
        elseif ($title -match '(ChatGPT|Claude|Copilot|Gmail|Edge|Chrome|Brave|Firefox|Adobe Acrobat|Windows)') { $brand = $Matches[1] }
        $name.Text = ''
        $addRun = { param([string]$Text, [bool]$Big) if ($Text) { [void]$name.Inlines.Add((New-Object Windows.Documents.Run -Property @{ Text = $Text; FontWeight = $(if ($Big) { 'ExtraBold' } else { 'SemiBold' }); FontSize = $(if ($Big) { 22 } else { 15 }) })) } }
        # The AI rows rebuild their title as runs, so the number has to be
        # added here too or it would be lost on this one category.
        if ($Number -gt 0) {
            [void]$name.Inlines.Add((New-Object Windows.Documents.Run -Property @{
                Text = ('{0}.  ' -f $Number)
                Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString($numberInk)
                FontWeight = 'Bold'
            }))
        }
        if ($brand) {
            $at = $title.IndexOf($brand)
            & $addRun $title.Substring(0, $at) $false
            & $addRun $brand $true
            & $addRun $title.Substring($at + $brand.Length) $false
        } else { & $addRun $title $true }
    }
    $badgePadding = if ($isLoud -or $isLongTest) { '9,4' } else { '8,3' }
    $badge = New-Object Windows.Controls.Border -Property @{ Background=$accent.Badge; CornerRadius=10; Padding=$badgePadding; Margin='10,0,0,0' }
    $badgeText = New-Object Windows.Controls.TextBlock -Property @{ Text=$accent.Label; Foreground=$accent.BadgeInk; FontSize=11 }
    if ($isLoud -or $isLongTest) { $badgeText.FontSize = 10.5; $badgeText.FontWeight = 'Bold' }
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
    # Shown even when the browser is not signed in: the state is read from the PC, so the row still says on or off.
    if ($aiStatus -and $Task.Id -notin @('ai.restore', 'ai.check')) {
        # The banner tells only what the Cleaner has verified: off, still on, or "cannot check".
        $rowState = [string](Get-DRPropertyValue -InputObject $aiStatus -Name 'State')
        $stateText = [string](Get-DRPropertyValue -InputObject $aiStatus -Name 'StateText')
        if (-not $rowState) { $rowState = 'Unknown' }
        if (-not $stateText) { $stateText = "Cannot tell - check it yourself" }
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

    if ($isLongTest) {
        $longCaution = $longInfo['Caution']
        [void]$copy.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$longCaution; Foreground='#96500A'; FontSize=12; FontWeight='SemiBold'; TextWrapping='Wrap'; Margin='0,7,12,0'; MaxWidth=650 }))
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

# Tasks only the owner may see or run. The owner's PC has the licence secret file beside the
# app; it is never shipped to customers, so on their PCs these tasks do not exist.
$script:DROwnerOnlyTaskIds = @('cleanup.event-applogs')
function Test-DROwnerMachine {
    foreach ($root in @([AppDomain]::CurrentDomain.BaseDirectory, $PSScriptRoot)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (Test-Path -LiteralPath (Join-Path $root 'licence_secret_cleaner.txt') -PathType Leaf) { return $true }
    }
    return $false
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
    if (-not (Test-DROwnerMachine)) { $hidden += $script:DROwnerOnlyTaskIds }
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
        $hidden += 'ai.claude-block'
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
        'Hibernate' { 'Hibernate saves your session to a file on C: so Windows can start fast. Turn it off to free several GB, or back on again. Pick one: they undo each other.' }
        'Memory' { 'The memory check only looks. The Windows memory test needs a restart that Windows asks about, and this app never restarts the PC by itself.' }
        'AI' { 'This page switches off the AI built into Windows and your browsers. Nothing is deleted and every change can be undone. Start with "What AI is on this PC?", then use "Turn off all AI". To change just one thing, open "Show each item" at the bottom.' }
    }
    if ($Category -eq 'AI' -and -not $script:DRAISearchRefresh) {
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
        $search = ([string]$ui.AISearchText.Text).Trim()
        # While searching only the matching rows show; the big cards come back when the box is empty.
        $aiCardsPending = -not $search
        # "What AI is on this PC?" comes first: look, then act. "Turn everything back on" follows it.
        $visible = @(@($visible | Where-Object { $_.Id -eq 'ai.check' }) + @($visible | Where-Object { $_.Id -eq 'ai.restore' }) + @($visible | Where-Object { $_.Id -notin @('ai.check','ai.restore') }))
        if ($search) {
            $visible = @($visible | Where-Object {
                $id = [string]$_.Id
                $text = (@($catalog | Where-Object { $_.Id -in @($id, "$id.on", "$id.uninstall", "$id.reinstall") } | ForEach-Object { "$($_.Name) $($_.Description)" }) -join ' ') + " $id"
                $text -like "*$([Management.Automation.WildcardPattern]::Escape($search))*"
            })
        }
    }
    $rowNumber = 0
    $aiFold = $null; $aiFoldPanel = $null
    foreach ($task in $visible) {
        $rowNumber++
        $foldThis = ($Category -eq 'AI' -and -not $search -and $task.Id -notin @('ai.check', 'ai.restore'))
        if ($foldThis -and -not $aiFold) {
            # Every single item sits under one button, so a new person sees only the three things that matter.
            $aiFoldPanel = New-Object Windows.Controls.StackPanel -Property @{ Margin = '0,12,0,0' }
            $aiFold = New-Object Windows.Controls.Expander -Property @{ Margin = '0,4,0,18'; Content = $aiFoldPanel }
            $aiFold.Header = New-Object Windows.Controls.TextBlock -Property @{ Text = 'Show each item - change just one thing'; FontSize = 17; FontWeight = 'ExtraBold'; Foreground = '#1E3A8A' }
            $ui.TaskList.Children.Add($aiFold) | Out-Null
        }
        $taskRow = New-TaskRow $task $rowNumber
        if ($foldThis) { $aiFoldPanel.Children.Add($taskRow) | Out-Null } else { $ui.TaskList.Children.Add($taskRow) | Out-Null }
        # The big buttons sit under the check row at the top: Turn off all AI, then Turn everything back on, then Uninstall all AI.
        if ($Category -eq 'AI' -and $aiCardsPending -and $task.Id -eq 'ai.check') {
            $ui.TaskList.Children.Add((New-DRAIAllOffCard)) | Out-Null
        }
        elseif ($Category -eq 'AI' -and $aiCardsPending -and $task.Id -eq 'ai.restore') {
            $aiCardsPending = $false
            $ui.TaskList.Children.Add((New-DRAIUninstallAllCard)) | Out-Null
        }
    }
    $script:renderedCleanupFilter = $script:cleanupLevel
    Update-SelectionSummary
}

$ui.AISearchText.Add_TextChanged({
    $ui.AISearchHint.Visibility = if ($ui.AISearchText.Text) { 'Collapsed' } else { 'Visible' }
    if ($script:currentCategory -ne 'AI') { return }
    # Redraw with the status already read, so each keystroke is instant.
    $script:DRAISearchRefresh = $true
    try { Show-TaskCategory 'AI' } finally { $script:DRAISearchRefresh = $false }
})

foreach ($bulkName in 'CleanCheckAllButton','CleanCheckOffButton') {
    $bulkButton = $ui[$bulkName]
    if (-not $bulkButton) { continue }
    $bulkButton.Tag = if ($bulkName -eq 'CleanCheckAllButton') { 'On' } else { 'Off' }
    $bulkButton.Add_Click({
        $on = ([string]$this.Tag -eq 'On')
        # Check all leaves the cookie item (it signs you out) alone; Check off clears everything on the page.
        foreach ($task in @($catalog | Where-Object { $_.Category -eq 'Cleanup' -and ((-not $on) -or [string]$_.Risk -ne 'SignOut') })) { $selection[$task.Id] = $on }
        if ($script:currentCategory -eq 'Cleanup') { Show-TaskCategory -Category 'Cleanup' } else { Update-SelectionSummary }
    })
}

function Set-DRLevelDates {
    # Above Safe, Medium and Advanced: when that level was last done. The reports do not say which level was
    # picked, so a level counts as done when a report's task list holds every item that level ticks. A Medium
    # clean therefore also counts as a Safe one, because Medium includes everything Safe does.
    if (-not $ui.PresetSafeDate -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return }
    $reportRoot = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Reports'
    $need = @{}
    foreach ($level in 'Safe','Medium','Advanced') {
        $need[$level] = @($catalog | Where-Object { [string]$_.Risk -ne 'SignOut' -and $_.Category -in @('Cleanup','Repair') -and (Test-TaskInOrderedPreset -Task $_ -Preset $level) } | ForEach-Object { [string]$_.Id })
    }
    $found = @{}
    if (Test-Path -LiteralPath $reportRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $reportRoot -Filter 'Maintenance_Report_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 80)) {
            if ($found.Count -ge 3) { break }
            $ran = @()
            try { $ran = @(Select-String -LiteralPath $file.FullName -Pattern '^\s+-\s+([a-z]+\.[a-z0-9.-]+)\s*$' -ErrorAction Stop | ForEach-Object { $_.Matches[0].Groups[1].Value }) } catch { continue }
            foreach ($level in 'Safe','Medium','Advanced') {
                if ($found.ContainsKey($level) -or -not $need[$level].Count) { continue }
                if (@($need[$level] | Where-Object { $ran -notcontains $_ }).Count -eq 0) { $found[$level] = $file.LastWriteTime }
            }
        }
    }
    foreach ($level in 'Safe','Medium','Advanced') {
        $when = $found[$level]
        $ui["Preset${level}Date"].Text = if (-not $when) { 'Not done yet' } else { 'Done ' + $when.ToString('dddd d MMMM') }
    }
}

function Test-DRRestartReminderDue {
    # The restart reminder shows when the Cleaner opens after a clean that needs a restart. If the person says No, it
    # comes back after 2 days, and keeps coming back every 2 days until the PC has been restarted.
    param([string]$RegistryKey, [datetime]$Now = (Get-Date), [double]$QuietDays = 2)
    try {
        $last = [string](Get-ItemProperty -LiteralPath $RegistryKey -Name 'RestartLastReminded' -ErrorAction Stop).RestartLastReminded
        $lastTime = [datetime]::Parse($last, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if (($Now - $lastTime).TotalDays -lt $QuietDays) { return $false }
    } catch { }
    return $true
}

function Update-SelectionSummary {
    $selected = @($catalog | Where-Object { $selection[$_.Id] })
    $total = @($selected).Count

    # The badge sits beside one page's list, so it counts that page. A run still
    # covers every page, and the badge says so when something is ticked elsewhere.
    $here = @($selected | Where-Object { $_.Category -eq $script:currentCategory }).Count
    if ($script:currentCategory -in @('Cleanup','Repair','Security','Health','Memory','Speed','Hibernate','AI')) {
        $ui.SelectionSummary.Text = if ($total -gt $here) { "$here selected here, $total in total" } else { "$here selected" }
    } else {
        $ui.SelectionSummary.Text = "$total selected"
    }

    $ui.ReviewButton.IsEnabled = $total -gt 0
}

function Show-Confirmation {
    Remove-DRConflictingSelections
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
    # Big and bright with a soft glow, so each task's state reads at a glance
    # Two lights side by side; while a task works they blink in turn
    $dot = New-Object Windows.Controls.StackPanel -Property @{ Orientation='Horizontal'; VerticalAlignment='Center'; Margin='0,0,16,0' }
    foreach ($gap in '0,0,7,0', '0') {
        $light = New-Object Windows.Shapes.Ellipse -Property @{ Width=22; Height=22; Fill='#98A2B3'; Stroke='White'; StrokeThickness=3; Margin=$gap; VerticalAlignment='Center' }
        $light.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ ShadowDepth=0; BlurRadius=16; Opacity=0.9; Color=[Windows.Media.ColorConverter]::ConvertFromString('#98A2B3') }
        [void]$dot.Children.Add($light)
    }
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
    param([string]$NavName, [string]$Label, [ValidateSet('Unchecked','Good','Expired','Attention')][string]$Status, [string]$Tip = '', [bool]$Severe = $false)
    $button = $ui[$NavName]
    if (-not $button) { return }
    $script:DRNavState[$NavName] = $Status
    [Windows.Controls.ToolTipService]::SetShowOnDisabled($button, $true)
    $panel = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal' }
    [void]$panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $Label; VerticalAlignment = 'Center' }))
    $mark = switch ($Status) { 'Good' { [string][char]0x2714 } 'Attention' { [string][char]0x26A0 } default { [string][char]0x25CF } }  # 'Expired' and 'Unchecked' are both a dot
    $color = switch ($Status) { 'Good' { '#2BE37A' } 'Expired' { '#2BE37A' } 'Attention' { '#FACC15' } default { '#EF4444' } }
    [void]$panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $mark; Margin = $(if ($NavName -eq 'NavPowerHeat' -or $Status -eq 'Unchecked') { '4,0,0,0' } else { '10,0,0,0' }); Foreground = $color; FontWeight = 'Bold'; FontSize = $(if ($Status -eq 'Unchecked') { 20 } elseif ($Status -eq 'Expired') { 12 } else { 17 }); VerticalAlignment = 'Center' }))
    # A serious result also gets red and blue lights that take turns, like an emergency light.
    if (-not $script:DRNavLights) { $script:DRNavLights = @{} }
    if ($Severe -and $Status -eq 'Attention') {
        $blue = New-Object Windows.Shapes.Ellipse -Property @{ Width = 10; Height = 10; Fill = '#1E90FF'; Margin = '0,0,2,0'; VerticalAlignment = 'Center' }
        $red = New-Object Windows.Shapes.Ellipse -Property @{ Width = 10; Height = 10; Fill = '#E02424'; Margin = '0,0,6,0'; VerticalAlignment = 'Center' }
        $blue.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString('#1E90FF'); BlurRadius = 12; ShadowDepth = 0; Opacity = 0.95 }
        $red.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString('#E02424'); BlurRadius = 12; ShadowDepth = 0; Opacity = 0.95 }
        # With the lights on, the label and mark are a little smaller so everything fits on the button.
        $panel.Children[0].FontSize = 13.5; $panel.Children[1].Margin = '6,0,0,0'; $panel.Children[1].FontSize = 15
        # Keep the label in the button's own colour (it turned dark when the lights were added).
        $panel.Children[0].SetBinding([Windows.Controls.TextBlock]::ForegroundProperty, (New-Object Windows.Data.Binding -Property @{ Path = [Windows.PropertyPath]'Foreground'; Source = $button })) | Out-Null
        # The lights sit at the left of the label so a long label can never push them off the button.
        $panel.Children.Insert(0, $red); $panel.Children.Insert(0, $blue)
        $script:DRNavLights[$NavName] = @($blue, $red)
        if (-not $Tip) { $Tip = 'Serious: this needs attention now. Click to check again.' }
    } else {
        [void]$script:DRNavLights.Remove($NavName)
    }
    # One timer makes every set of lights take turns, and it stops when none are left.
    if ($script:DRNavLights.Count -and -not $script:DRNavLightTimer) {
        $script:DRNavLightOn = $false
        $script:DRNavLightTimer = New-Object Windows.Threading.DispatcherTimer
        $script:DRNavLightTimer.Interval = [TimeSpan]::FromMilliseconds(450)
        $script:DRNavLightTimer.Add_Tick({
            $script:DRNavLightOn = -not $script:DRNavLightOn
            foreach ($pair in @($script:DRNavLights.Values)) {
                $pair[0].Opacity = $(if ($script:DRNavLightOn) { 1.0 } else { 0.15 })
                $pair[1].Opacity = $(if ($script:DRNavLightOn) { 0.15 } else { 1.0 })
            }
        })
        $script:DRNavLightTimer.Start()
    } elseif (-not $script:DRNavLights.Count -and $script:DRNavLightTimer) {
        $script:DRNavLightTimer.Stop(); $script:DRNavLightTimer = $null
    }
    # The longest label gets slightly smaller text so its mark is never cut off at the edge of the button.
    if ($NavName -eq 'NavPowerHeat' -and $panel.Children[0] -is [Windows.Controls.TextBlock] -and -not $Severe) {
        $panel.Children[0].FontSize = 14
        # Keep the label in the button's own colour (a size set in code otherwise turns it dark).
        $panel.Children[0].SetBinding([Windows.Controls.TextBlock]::ForegroundProperty, (New-Object Windows.Data.Binding -Property @{ Path = [Windows.PropertyPath]'Foreground'; Source = $button })) | Out-Null
    }
    $button.Content = $panel
    $button.ToolTip = if ($Tip) { $Tip } else { switch ($Status) { 'Good' { 'All good. You can check again any time.' } 'Expired' { 'It passed last time. A week has gone by, so it is time to check again.' } 'Attention' { 'Checked: something needs attention. Click to check again.' } default { 'Not checked yet. Click to check.' } } }
}

# How long a check result stays valid. After this the menu item goes back to the red
# dot, as a reminder to check again.
$script:DRCheckValidDays = 7
# A check can be run any time. Within 7 days it shows its tick (or warning); from 7 to 30 days a small green dot says it
# passed but a week has gone by; after 30 days, or if it was never run, a big red dot says it needs checking.
$script:DRCheckDueDays = 30
$script:DRCheckMarks = @{
    'health.drive-check' = @{ Nav = 'NavHealth'; Label = ([string][char]0x25B0 + '   Check my drives') }
    'health.ram-check'   = @{ Nav = 'NavMemory'; Label = ([string][char]0x25A6 + '   Check my RAM') }
    'health.power-heat-check' = @{ Nav = 'NavPowerHeat'; Label = ([string][char]0x26A1 + '   Check power and heat') }
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
            $result[$property.Name] = @{ Date = [datetime]$property.Value.date; Attention = [bool]$property.Value.attention; Severe = [bool]($property.Value.PSObject.Properties['severe'] -and $property.Value.severe) }
        }
    } catch { }
    return $result
}

function Save-DRCheckStatus {
    param([string]$TaskId, [bool]$Attention, [bool]$Severe = $false)
    $file = Get-DRCheckStatusPath
    if (-not $file) { return }
    try {
        $all = Read-DRCheckStatus
        $all[$TaskId] = @{ Date = (Get-Date); Attention = $Attention; Severe = $Severe }
        $out = [ordered]@{}
        foreach ($key in $all.Keys) { $out[$key] = [ordered]@{ date = $all[$key].Date.ToString('o'); attention = $all[$key].Attention; severe = [bool]$all[$key].Severe } }
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
                $tip = if ($saved[$taskId].Attention) { "Last checked ${when}: something needs attention. Click to check again." } else { "Last checked ${when}: all good. You can check again any time." }
            } elseif ($ageDays -le $script:DRCheckDueDays -and -not $saved[$taskId].Attention) {
                $status = 'Expired'
                $tip = "Last checked $when. It was fine. A week has gone by, so it is time to check again."
            } else {
                $tip = "Last checked $when. It needs to be checked again. Click to check."
            }
        }
        $severe = ($status -eq 'Attention' -and $saved.ContainsKey($taskId) -and [bool]$saved[$taskId].Severe)
        Set-DRNavCheckMark -NavName $info.Nav -Label $info.Label -Status $status -Tip $tip -Severe $severe
    }
}

function New-DRResultCard {
    # One finding of a check that only looks: a green card with a tick when all is well,
    # an amber one with a warning sign when something needs attention.
    param([string]$Message, [string]$State)
    $parts = @($Message -split "\r?\n" | ForEach-Object { $_.TrimEnd() })
    $head = $parts[0].Trim()
    $body = (@($parts | Select-Object -Skip 1 | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n")
    $good = ($State -eq 'Information') -and ($head -match 'NO PROBLEMS FOUND|great health|All good')
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
    $navFor = @{ 'health.drive-check' = @('NavHealth', ([string][char]0x25B0 + '   Check my drives')); 'health.ram-check' = @('NavMemory', ([string][char]0x25A6 + '   Check my RAM')); 'health.power-heat-check' = @('NavPowerHeat', ([string][char]0x26A1 + '   Check power and heat')) }
    if ($navFor.ContainsKey($TaskId)) {
        if ($State -eq 'Started') { $script:DRCheckWarned[$TaskId] = $false; $script:DRCheckSevere[$TaskId] = $false }
        if ($Message -match 'SERIOUS PROBLEM|Please check this soon') { $script:DRCheckSevere[$TaskId] = $true }
        if ($State -in @('Warning','Failed')) { $script:DRCheckWarned[$TaskId] = $true }
        if ($State -in @('Completed','Failed')) {
            $attention = $false
            if ($script:DRCheckWarned.ContainsKey($TaskId)) { $attention = [bool]$script:DRCheckWarned[$TaskId] }
            $severe = ($attention -and $script:DRCheckSevere.ContainsKey($TaskId) -and [bool]$script:DRCheckSevere[$TaskId])
            Set-DRNavCheckMark -NavName $navFor[$TaskId][0] -Label $navFor[$TaskId][1] -Status $(if ($attention) { 'Attention' } else { 'Good' }) -Severe $severe -Tip $(if ($attention) { 'Checked today: something needs attention. Click to check again.' } else { 'Checked today: all good. No need to check again for now.' })
            Save-DRCheckStatus -TaskId $TaskId -Attention $attention -Severe $severe
        }
    }
    $row = @($ui.ProgressList.Children | Where-Object Tag -eq $TaskId | Select-Object -First 1)
    if (-not $row) { return }
    $pair = $row.Child.Children[0]; $text = $row.Child.Children[1].Children[1]
    $found = $row.Child.Children[1].Children[2]
    # Bright green = working on it (the two lights blink in turn), bright blue = done
    $dotColour = switch ($State) { 'Started' {'#00E676'} 'Progress' {'#00E676'} 'Completed' {'#1E90FF'} 'Failed' {'#FF3B30'} 'Warning' {'#FF9500'} default {'#98A2B3'} }
    $lightIndex = 0
    foreach ($dot in $pair.Children) {
        # A failed task shows one red light and one blue, blinking in turn
        $lightColour = if ($State -eq 'Failed' -and $lightIndex -eq 1) { '#1E90FF' } else { $dotColour }
        $dot.Fill = $lightColour
        if ($dot.Effect) { $dot.Effect.Color = [Windows.Media.ColorConverter]::ConvertFromString($lightColour) }
        $lightIndex++
    }
    # Green lights blink while working; a failed task blinks red and blue until it is looked at
    if ($State -in @('Started', 'Progress', 'Failed')) {
        if (-not $pair.Tag) {
            $first = $true
            foreach ($dot in $pair.Children) {
                $from = if ($first) { 1.0 } else { 0.2 }; $to = if ($first) { 0.2 } else { 1.0 }
                $pulse = New-Object Windows.Media.Animation.DoubleAnimation -Property @{ From=$from; To=$to; Duration=[Windows.Duration]::new([TimeSpan]::FromMilliseconds(600)); AutoReverse=$true; RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever }
                $dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $pulse)
                $first = $false
            }
            $pair.Tag = 'pulsing'
        }
    } elseif ($pair.Tag) {
        foreach ($dot in $pair.Children) {
            $dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
            $dot.Opacity = 1.0
        }
        $pair.Tag = $null
    }
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
    if ($State -eq 'Failed') {
        $text.Foreground = '#C63C3C'
        $text.Text = "$Message`nDon't worry - this is often very easy to fix. A restart often sorts it."
    }
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

function Set-DRWindowsHealthCard {
    # Paints the dashboard's Windows Health card from Get-DRWindowsHealth: green when
    # nothing needs a look, red with the first problems named when something does.
    param($Result)
    $problems = @($Result.Problems | Where-Object { $_ })
    $good = $problems.Count -eq 0
    $accent = if ($good) { 'Success' } else { 'Danger' }
    $soft = if ($good) { 'SuccessSoft' } else { 'DangerSoft' }
    $ui.HealthCard.BorderBrush = $window.FindResource($accent)
    $ui.HealthIconBox.Background = $window.FindResource($soft)
    $ui.HealthIcon.Foreground = $window.FindResource($accent)
    $ui.HealthLabel.Foreground = $window.FindResource($accent)
    $ui.WindowsStatusText.Foreground = $window.FindResource($accent)
    if ($good) {
        $ui.HealthIcon.Text = [string][char]0x2714
        $ui.WindowsStatusText.Text = 'Healthy'
        $ui.WindowsStatusHint.Text = 'Protection is on, drives are fine and there is room to spare.'
        $ui.HealthCard.ToolTip = $null
    } else {
        $ui.HealthIcon.Text = '!'
        $ui.WindowsStatusText.Text = if ($problems.Count -eq 1) { '1 thing needs attention' } else { "$($problems.Count) things need attention" }
        $shown = (@($problems | Select-Object -First 2) -join '. ') + '.'
        if ($problems.Count -gt 2) { $shown += ' Point here to see them all.' }
        $ui.WindowsStatusHint.Text = $shown
        $ui.HealthCard.ToolTip = ($problems | ForEach-Object { [string][char]0x2022 + ' ' + $_ }) -join "`n"
    }
    $ui.HealthCheckButton.Visibility = 'Visible'
    $script:healthShown = $true
    # The alarm: a sound and a message, once per run, when PHP here is open to PHP2Shell.
    if ($Result.PSObject.Properties['PhpAlarm'] -and $Result.PhpAlarm -and -not (Get-Variable -Name phpAlarmShown -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
        $script:phpAlarmShown = $true
        try {
            [System.Media.SystemSounds]::Exclamation.Play()
            [System.Windows.MessageBox]::Show($window, "A PHP program on this PC has a known security gap that has a free fix.`n`nThis is only a reminder, and nothing is wrong with your files. Update PHP to 8.2.35, 8.3.36, 8.4.27 or 8.5.12 (or newer) when you can.`n`nRun 'PHP security check' under Health to see which one.`n`nNothing was changed.", 'Security alert - PHP', 'OK', 'Warning') | Out-Null
        } catch { }
    }
}

function Start-Analysis {
    Set-Variable -Name analysisTotal -Value @($catalog | Where-Object SupportsAnalysis).Count -Scope Script
    Set-Variable -Name analysisDone -Value 0 -Scope Script
    $script:healthShown = $false
    $ui.OverlayContinueButton.Visibility = 'Collapsed'
    $ui.BusyOverlay.Visibility = 'Visible'; $ui.OverlayTitle.Text = 'Analyzing this PC'; $ui.OverlayMessage.Text = 'Checking temporary files, browser data, and maintenance settings. Nothing is being changed.'
    Set-AnalysisProgress
    $engineSource = [System.IO.File]::ReadAllText($script:DREnginePath)
    $safeRoot = if ($TestRoot) { $TestRoot.Replace("'","''") } else { '' }
    $scriptText = $engineSource + "`r`nGet-DRAnalysis -TestRoot '$safeRoot'`r`nGet-DRWindowsHealth"
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

# One job at a time, so an older PC is never asked to clean, find duplicates
# and uninstall all at once. Returns $true (and tells the person) when
# something else is still working; that window is brought to the front.
# How many of the three tools (the cleaning, the Duplicate Finder, the Uninstaller) this PC can run at the same
# time right now. It looks at the processor cores, the memory and how busy the PC is at this moment.
function Get-DRToolLimit {
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $totalGB = [double]$computer.TotalPhysicalMemory / 1GB
        $freeGB = [double]$os.FreePhysicalMemory / 1MB
        $cores = [int]$computer.NumberOfLogicalProcessors
        $load = [double](@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average)
        $limit = 1
        if ($cores -ge 4 -and $totalGB -ge 8 -and $freeGB -ge 3 -and $load -lt 95) { $limit = 2 }
        if ($cores -ge 8 -and $totalGB -ge 16 -and $freeGB -ge 6 -and $load -lt 85) { $limit = 3 }
        return $limit
    } catch { return 1 }
}

function Test-DROtherToolBusy {
    param([ValidateSet('Clean', 'Finder', 'Uninstaller')][string]$Opening)
    if ($TestMode) { return $false }
    $busy = New-Object System.Collections.ArrayList; $window = $null
    if ($Opening -ne 'Clean' -and $script:activePowerShell) { [void]$busy.Add('the cleaning') }
    if ($Opening -ne 'Finder') {
        $finder = Get-Process -Name 'powershell', 'DRDirect*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -eq 'DRDirect Duplicate Finder' } | Select-Object -First 1
        if ($finder) { [void]$busy.Add('the Duplicate Finder'); $window = $finder }
    }
    if ($Opening -ne 'Uninstaller') {
        $uninstaller = Get-Process -Name 'BCUninstaller' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        if ($uninstaller) { [void]$busy.Add('the Uninstaller'); if (-not $window) { $window = $uninstaller } }
    }
    if ($busy.Count -eq 0) { return $false }
    # Others are running: one more is allowed only if this PC is strong enough for that many at once.
    $together = $busy.Count + 1
    # The PC is analysed once per start of the Cleaner; the answer is kept until it is closed.
    $analyzing = $null
    if ($null -eq $script:DRToolLimit) { try {
        $analyzing = New-Object Windows.Window
        $analyzing.WindowStyle = 'None'; $analyzing.ResizeMode = 'NoResize'; $analyzing.SizeToContent = 'WidthAndHeight'; $analyzing.Topmost = $true
        $analyzing.WindowStartupLocation = 'CenterScreen'; $analyzing.ShowInTaskbar = $false; $analyzing.Background = [Windows.Media.Brushes]::Transparent; $analyzing.AllowsTransparency = $true
        $card = New-Object Windows.Controls.Border
        $card.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1A2E4C'); $card.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#5B93FF')
        $card.BorderThickness = New-Object Windows.Thickness(2); $card.CornerRadius = New-Object Windows.CornerRadius(12); $card.Padding = New-Object Windows.Thickness(30, 22, 30, 22)
        $words = New-Object Windows.Controls.TextBlock
        $words.Text = 'Please wait, I am analyzing your system for better performance, to make DRDirect run better for you...'
        $words.Foreground = [Windows.Media.Brushes]::White; $words.FontSize = 16; $words.FontWeight = 'SemiBold'; $words.TextWrapping = 'Wrap'; $words.MaxWidth = 420; $words.TextAlignment = 'Center'
        $card.Child = $words; $analyzing.Content = $card
        $analyzing.Show()
        # Let it draw before the check starts, and stay up long enough to be read.
        $analyzing.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
    } catch { $analyzing = $null } }
    if ($null -eq $script:DRToolLimit) {
        $script:DRToolLimit = Get-DRToolLimit
        if ($analyzing) { try { Start-Sleep -Milliseconds 1200; $analyzing.Close() } catch { } }
    }
    $toolLimit = $script:DRToolLimit
    if ($together -le $toolLimit) { return $false }
    if ($window -and (Get-Command Enter-DRSingleWindow -ErrorAction SilentlyContinue) -and ('DRSingleWindow' -as [type])) {
        try {
            if ([DRSingleWindow]::IsIconic($window.MainWindowHandle)) { [void][DRSingleWindow]::ShowWindow($window.MainWindowHandle, 9) }
            [void][DRSingleWindow]::SetForegroundWindow($window.MainWindowHandle)
        } catch { }
    }
    $nl = [Environment]::NewLine
    $text = if ($together -ge 3) {
        "Sorry, this PC is not strong enough to run all 3 at the same time.$nl${nl}Try 2. If that does not work, do one at a time, that will work."
    } else {
        "Sorry, this PC is not strong enough to run 2 at the same time right now.$nl${nl}Please wait until $($busy -join ' and ') is finished and closed."
    }
    [Windows.MessageBox]::Show($text, 'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
    return $true
}

function Start-RunPlan {
    if (Test-DROtherToolBusy -Opening 'Clean') { $ui.ConfirmOverlay.Visibility = 'Collapsed'; return }
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
    $script:restartDelaySeconds = 0
    try {
        $choice = $ui.RestartDelayCombo.SelectedItem
        if ($ui.RestartDelayPanel.Visibility -eq 'Visible' -and $choice) { $script:restartDelaySeconds = [int]$choice.Tag }
    } catch { }
    # A Windows restore point goes first whenever the plan really changes something.
    Remove-DRConflictingSelections
    $selection['safety.restore-point'] = $false
    $changing = @($catalog | Where-Object { $selection[$_.Id] -and $_.Category -in @('Cleanup','Repair','Hibernate','AI') -and $_.Risk -ne 'Guided' -and $_.Id -notin @('ai.check','repair.restore-point') })
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
    # While it runs, the person can still change when Windows restarts afterwards, or turn the automatic restart off.
    try {
        $needsRestartRun = (@($selected | Where-Object { $script:DRNoRestartTaskIds -notcontains $_.Id }).Count -gt 0)
        $ui.RunRestartPanel.Visibility = if ($needsRestartRun) { 'Visible' } else { 'Collapsed' }
        $match = @($ui.RunRestartCombo.Items | Where-Object { [int]$_.Tag -eq [int]$script:restartDelaySeconds } | Select-Object -First 1)
        if ($match.Count) { $ui.RunRestartCombo.SelectedItem = $match[0] }
    } catch { }
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

    $localAppData = $env:LOCALAPPDATA
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
    # The run may have freed space, so the C: warning is checked again straight away.
    Update-DRDiskWarning
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
    # Windows' own soft calendar chime, left to ring out for about 5 seconds, so the person knows the Cleaner
    # is all done even if they have looked away. It is the sound that comes with Windows, so nothing is downloaded.
    # The Sound switch on the Dashboard turns it off.
    if (-not $cancelAfterTask -and $script:DRSoundOn) {
        try {
            $doneSound = Join-Path $env:WINDIR 'Media\Windows Notify Calendar.wav'
            if (Test-Path -LiteralPath $doneSound -PathType Leaf) {
                $bytes = [IO.File]::ReadAllBytes($doneSound)
                # Find the format and sound chunks, then repeat the chime as softer and softer echoes.
                $pos = 12; $channels = 1; $rate = 44100; $bits = 16; $dataAt = -1; $dataLen = 0
                while ($pos + 8 -le $bytes.Length) {
                    $id = [Text.Encoding]::ASCII.GetString($bytes, $pos, 4); $len = [BitConverter]::ToInt32($bytes, $pos + 4)
                    if ($id -eq 'fmt ') { $channels = [BitConverter]::ToInt16($bytes, $pos + 10); $rate = [BitConverter]::ToInt32($bytes, $pos + 12); $bits = [BitConverter]::ToInt16($bytes, $pos + 22) }
                    if ($id -eq 'data') { $dataAt = $pos + 8; $dataLen = [Math]::Min($len, $bytes.Length - $dataAt); break }
                    $pos += 8 + $len + ($len % 2)
                }
                if ($dataAt -lt 0 -or $bits -ne 16) { throw 'Unexpected sound format.' }
                $source = New-Object 'int16[]' ([int]($dataLen / 2))
                [Buffer]::BlockCopy($bytes, $dataAt, $source, 0, $source.Length * 2)
                $total = [int]($rate * 5.0) * $channels
                $mix = New-Object 'double[]' $total
                foreach ($echo in @(@(0.0, 1.0), @(0.9, 0.55), @(1.8, 0.32), @(2.7, 0.18), @(3.6, 0.09))) {
                    $offset = [int]($echo[0] * $rate) * $channels
                    for ($i = 0; $i -lt $source.Length -and ($offset + $i) -lt $total; $i++) { $mix[$offset + $i] += $source[$i] * $echo[1] }
                }
                $fade = [int]($rate * 1.0) * $channels
                for ($i = $total - $fade; $i -lt $total; $i++) { $mix[$i] *= ($total - $i) / $fade }
                $samples = New-Object 'int16[]' $total
                for ($i = 0; $i -lt $total; $i++) { $samples[$i] = [int16][Math]::Max(-32000, [Math]::Min(32000, [int]$mix[$i])) }
                $stream = New-Object System.IO.MemoryStream
                $writer = New-Object System.IO.BinaryWriter($stream)
                $dataBytes = $total * 2
                $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int](36 + $dataBytes))
                $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16); $writer.Write([int16]1); $writer.Write([int16]$channels)
                $writer.Write([int]$rate); $writer.Write([int]($rate * 2 * $channels)); $writer.Write([int16](2 * $channels)); $writer.Write([int16]16)
                $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int]$dataBytes)
                $byteSamples = New-Object 'byte[]' $dataBytes
                [Buffer]::BlockCopy($samples, 0, $byteSamples, 0, $dataBytes)
                $writer.Write($byteSamples); $writer.Flush(); $stream.Position = 0
                $script:DRDoneSound = New-Object System.Media.SoundPlayer($stream)
                $script:DRDoneSound.Play()
            } else {
                [System.Media.SystemSounds]::Asterisk.Play()
            }
        } catch {
            try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
        }
    }
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
    $ui.RunRestartPanel.Visibility = 'Collapsed'
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
    if ($needsRestart -and -not $cancelAfterTask -and -not $TestMode) {
        try {
            if (-not (Test-Path -LiteralPath $script:DR3DKey)) { New-Item -Path $script:DR3DKey -Force | Out-Null }
            Set-ItemProperty -LiteralPath $script:DR3DKey -Name 'RestartOwedSince' -Value ((Get-Date).ToString('o')) -Type String
            # A new clean starts the reminders fresh, so the next time the Cleaner opens it reminds right away.
            Remove-ItemProperty -LiteralPath $script:DR3DKey -Name 'RestartLastReminded' -ErrorAction SilentlyContinue
        } catch { }
    }
    if ($needsRestart -and -not $cancelAfterTask) {
        # A full hour. The countdown often sits behind a fullscreen game or a
        # document, so the person may not see it immediately; an hour is enough
        # to finish what they are doing and restart on their own terms. The
        # window also pushes itself to the front - see Show-DRRestartNotice -
        # so the restart is never a surprise.
        if ($script:restartDelaySeconds -gt 0) {
            Start-DRRestartCountdown -Seconds $script:restartDelaySeconds -BaseMessage $ui.ProgressSafetyText.Text
        } else {
            # The person chose to restart on their own: no countdown, only the buttons.
            $ui.ProgressSafetyText.Text = ($ui.ProgressSafetyText.Text + '  A restart is needed to finish. Click Restart now when you are ready. Windows will not restart by itself.').Trim()
        }
    }
}


$script:DRScanLinesAsync = $null
function Set-DRScanLines {
    # The Last clean card also says when Windows Defender last did a quick scan and a full scan.
    # Defender keeps both dates itself, so scans the Cleaner started and the daily scheduled one both count.
    # Reading them takes about a second, so it happens in the background and the card fills in when it is done.
    if (-not $ui.LastCleanQuickScan -or -not $ui.LastCleanFullScan) { return }
    if ($script:DRScanLinesAsync -and -not $script:DRScanLinesAsync.IsCompleted) { return }
    $script:DRScanLinesPS = [powershell]::Create()
    [void]$script:DRScanLinesPS.AddScript({
        try { $m = Get-MpComputerStatus -ErrorAction Stop; [pscustomobject]@{ Ok = $true; Quick = $m.QuickScanEndTime; Full = $m.FullScanEndTime } }
        catch { [pscustomobject]@{ Ok = $false } }
    })
    $script:DRScanLinesAsync = $script:DRScanLinesPS.BeginInvoke()
    $scanTimer = New-Object Windows.Threading.DispatcherTimer
    $scanTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $scanTimer.Add_Tick({
        if (-not $script:DRScanLinesAsync.IsCompleted) { return }
        $this.Stop()
        try {
            $result = @($script:DRScanLinesPS.EndInvoke($script:DRScanLinesAsync))[0]
            if ($result -and $result.Ok) {
                $say = {
                    param($label, $when)
                    # Defender reports a scan that never ran as a date long ago, so anything before 2000 means never.
                    if (-not $when -or $when.Year -lt 2000) { return "$label never" }
                    $day = if ($when.Date -eq (Get-Date).Date) { 'today' } elseif ($when.Date -eq (Get-Date).Date.AddDays(-1)) { 'yesterday' } else { $when.ToString('d MMMM') }
                    "$label $day"
                }
                $ui.LastCleanQuickScan.Text = & $say 'Quick scan:' $result.Quick
                $fullText = & $say 'Full scan:' $result.Full
                $ui.LastCleanFullScan.Text = $fullText
                # A full scan that never ran is the one thing worth pointing out, so it turns red.
                if ($fullText -like '*never') { $ui.LastCleanFullScan.Foreground = $window.FindResource('Danger') }
                else { $ui.LastCleanFullScan.ClearValue([Windows.Controls.TextBlock]::ForegroundProperty) }
                $ui.LastCleanQuickScan.Visibility = 'Visible'
                $ui.LastCleanFullScan.Visibility = 'Visible'
            }
        } catch { }
        finally { try { $script:DRScanLinesPS.Dispose() } catch { } }
    })
    $scanTimer.Start()
}

function Show-DRBebeSurprise {
    <#
        A family joke for one PC only: a chubby baby with a milk bottle and a
        5-second cry, before the Cleaner opens. Shown the first 3 times, then
        never again. The PC is matched by a SHA-256 of its ID, so the ID itself
        is not in the published script. Any error is ignored; the Cleaner opens.
    #>
    param([switch]$Force)
    try {
        $key = 'HKCU:\Software\DRDirect\PC Cleaner'
        if (-not $Force) {
            $uuid = [string](Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).UUID
            $serial = [string](Get-CimInstance Win32_BaseBoard -ErrorAction Stop).SerialNumber
            $id = ('{0}-{1}' -f $uuid.Trim(), $serial.Trim()).ToLowerInvariant()
            $sha = [Security.Cryptography.SHA256]::Create()
            $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($id)) | ForEach-Object { $_.ToString('x2') })
            if ($hash -ne '9d9fa84a3d0ff4a8b4a02c5b210c06dec09f0cdb637d92dcf3ddbe7be4b2178e') { return }
            $shown = 0
            try { $shown = [int](Get-ItemProperty -LiteralPath $key -Name 'BebeShown' -ErrorAction Stop).BebeShown } catch { }
            if ($shown -ge 3) { return }
            if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
            Set-ItemProperty -LiteralPath $key -Name 'BebeShown' -Value ($shown + 1) -Type DWord
        }

        # A real baby crying (Pixabay, free to use: "Baby Crying" by DRAGON-STUDIO), played for 8 seconds.
        $cryFile = Join-Path $env:TEMP 'DRDirect-bebe-cry.mp3'
        [IO.File]::WriteAllBytes($cryFile, [Convert]::FromBase64String('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'))
        $player = New-Object Windows.Media.MediaPlayer
        $player.Open([uri]$cryFile)
        $player.Volume = 1.0
        # The recording is about 4.6 seconds, so it starts again until the picture closes.
        $player.Add_MediaEnded({ $player.Position = [TimeSpan]::Zero; $player.Play() })
        [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="For BéBé Gilles" Width="640" Height="700" WindowStartupLocation="CenterScreen" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="True">
  <Border CornerRadius="28" BorderBrush="#FF9EC5" BorderThickness="6">
    <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF6FB" Offset="0"/><GradientStop Color="#DDF0FF" Offset="1"/></LinearGradientBrush></Border.Background>
    <Grid>
      <TextBlock Text="For BéBé Gilles" FontSize="50" FontWeight="ExtraBold" Foreground="#E2337A" HorizontalAlignment="Center" Margin="0,22,0,0" FontFamily="Segoe UI Black">
        <TextBlock.Effect><DropShadowEffect Color="#7FFFFFFF" ShadowDepth="3" BlurRadius="2"/></TextBlock.Effect>
      </TextBlock>
      <Canvas Width="520" Height="540" Margin="0,70,0,0">
        <!-- chubby body in a blue onesie -->
        <Ellipse Canvas.Left="120" Canvas.Top="270" Width="280" Height="250" Fill="#7EC8F2" Stroke="#3D8FC4" StrokeThickness="4"/>
        <!-- belly -->
        <Ellipse Canvas.Left="175" Canvas.Top="330" Width="170" Height="150" Fill="#A9DDF7"/>
        <!-- chubby legs -->
        <Ellipse Canvas.Left="105" Canvas.Top="440" Width="120" Height="90" Fill="#FFD3B0" Stroke="#E8A882" StrokeThickness="4"/>
        <Ellipse Canvas.Left="295" Canvas.Top="440" Width="120" Height="90" Fill="#FFD3B0" Stroke="#E8A882" StrokeThickness="4"/>
        <!-- big round head -->
        <Ellipse Canvas.Left="110" Canvas.Top="20" Width="300" Height="280" Fill="#FFD9BA" Stroke="#E8A882" StrokeThickness="4"/>
        <!-- curl of hair -->
        <Path Data="M 255,28 C 230,0 290,-6 278,22 C 270,40 250,30 262,20" Stroke="#8A5A2B" StrokeThickness="7" Fill="Transparent" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        <!-- ears -->
        <Ellipse Canvas.Left="92" Canvas.Top="135" Width="44" Height="60" Fill="#FFCFAA" Stroke="#E8A882" StrokeThickness="4"/>
        <Ellipse Canvas.Left="384" Canvas.Top="135" Width="44" Height="60" Fill="#FFCFAA" Stroke="#E8A882" StrokeThickness="4"/>
        <!-- happy closed eyes -->
        <Path Data="M 175,140 Q 197,118 219,140" Stroke="#3A2A20" StrokeThickness="7" Fill="Transparent" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        <Path Data="M 301,140 Q 323,118 345,140" Stroke="#3A2A20" StrokeThickness="7" Fill="Transparent" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        <!-- fat pink cheeks -->
        <Ellipse Canvas.Left="140" Canvas.Top="170" Width="80" Height="60" Fill="#FF9BB0" Opacity="0.75"/>
        <Ellipse Canvas.Left="300" Canvas.Top="170" Width="80" Height="60" Fill="#FF9BB0" Opacity="0.75"/>
        <!-- little nose -->
        <Ellipse Canvas.Left="249" Canvas.Top="168" Width="22" Height="16" Fill="#F2B08C"/>
        <!-- the milk bottle, tipped up to the mouth -->
        <Canvas Canvas.Left="236" Canvas.Top="196">
          <Canvas.RenderTransform><RotateTransform Angle="-35"/></Canvas.RenderTransform>
          <Ellipse Canvas.Left="10" Canvas.Top="0" Width="28" Height="34" Fill="#F5B88A" Stroke="#D98E5C" StrokeThickness="3"/>
          <Rectangle Canvas.Left="2" Canvas.Top="26" Width="44" Height="18" RadiusX="5" RadiusY="5" Fill="#FF6FA5" Stroke="#D9437E" StrokeThickness="3"/>
          <Rectangle Canvas.Left="0" Canvas.Top="42" Width="48" Height="150" RadiusX="16" RadiusY="16" Fill="#FFFFFF" Stroke="#9CC9E8" StrokeThickness="4"/>
          <Rectangle Canvas.Left="4" Canvas.Top="92" Width="40" Height="96" RadiusX="12" RadiusY="12" Fill="#F7F9FF"/>
          <Rectangle Canvas.Left="10" Canvas.Top="110" Width="16" Height="4" Fill="#9CC9E8"/>
          <Rectangle Canvas.Left="10" Canvas.Top="135" Width="16" Height="4" Fill="#9CC9E8"/>
          <Rectangle Canvas.Left="10" Canvas.Top="160" Width="16" Height="4" Fill="#9CC9E8"/>
        </Canvas>
        <!-- chubby hands holding the bottle -->
        <Ellipse Canvas.Left="250" Canvas.Top="300" Width="70" Height="62" Fill="#FFD3B0" Stroke="#E8A882" StrokeThickness="4"/>
        <Ellipse Canvas.Left="318" Canvas.Top="250" Width="66" Height="58" Fill="#FFD3B0" Stroke="#E8A882" StrokeThickness="4"/>
      </Canvas>
    </Grid>
  </Border>
</Window>
'@
        $bebe = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
        $closeTimer = New-Object Windows.Threading.DispatcherTimer
        $closeTimer.Interval = [TimeSpan]::FromSeconds(8)
        $closeTimer.Add_Tick({ $closeTimer.Stop(); try { $player.Stop(); $player.Close() } catch { }; $bebe.Close(); try { Remove-Item -LiteralPath $cryFile -Force -ErrorAction SilentlyContinue } catch { } })
        $bebe.Add_ContentRendered({ try { $player.Play() } catch { }; $closeTimer.Start() })
        [void]$bebe.ShowDialog()
    } catch { }
}

function Start-DRCleanButtonBounce {
    # A small hop every second or so on the green button while a clean is overdue.
    $btn = $ui.SafeCleanButton
    if (-not $btn) { return }
    $on = Get-Variable -Name DRBounceOn -Scope Script -ErrorAction SilentlyContinue
    if ($on -and $on.Value) { return }
    $move = New-Object Windows.Media.TranslateTransform
    $btn.RenderTransform = $move
    $hop = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $hop.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $hop.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(1300))
    # Whole pixels only: the 3D shadow turns blurry if the button sits between pixels.
    $up = New-Object Windows.Media.Animation.QuadraticEase; $up.EasingMode = 'EaseOut'
    $down = New-Object Windows.Media.Animation.BounceEase; $down.Bounces = 2; $down.Bounciness = 3; $down.EasingMode = 'EaseOut'
    for ($ms = 0; $ms -le 800; $ms += 16) {
        $y = if ($ms -le 250) { -10 * $up.Ease($ms / 250) } else { -10 + 10 * $down.Ease(($ms - 250) / 550) }
        [void]$hop.KeyFrames.Add([Windows.Media.Animation.DiscreteDoubleKeyFrame]::new([math]::Round($y), [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($ms))))
    }
    [void]$hop.KeyFrames.Add([Windows.Media.Animation.DiscreteDoubleKeyFrame]::new(0, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(816))))
    $move.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $hop)
    $script:DRBounceOn = $true
}

function Stop-DRCleanButtonBounce {
    $btn = $ui.SafeCleanButton
    if (-not $btn) { return }
    if ($btn.RenderTransform -is [Windows.Media.TranslateTransform]) {
        $btn.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null)
        $btn.RenderTransform.Y = 0
    }
    $script:DRBounceOn = $false
}

function Set-DRLastCleanCard {
    # The Dashboard's Last clean card: the newest report that ran a cleanup task.
    # Checks and scans write reports too, but they are not a clean, so they are skipped.
    if (-not $ui.LastCleanValue -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return }
    $reportRoot = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Reports'
    if (-not (Test-Path -LiteralPath $reportRoot -PathType Container)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $reportRoot -Filter 'Maintenance_Report_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 60)) {
        $ranClean = $false
        try { $ranClean = [bool](Select-String -LiteralPath $file.FullName -Pattern '^\s*-\s+cleanup\.' -Quiet -ErrorAction Stop) } catch { }
        if (-not $ranClean) { continue }
        $when = $file.LastWriteTime
        $ago = (Get-Date) - $when
        $ui.LastCleanValue.Text = if ($when.Date -eq (Get-Date).Date) { 'Today' } elseif ($when.Date -eq (Get-Date).Date.AddDays(-1)) { 'Yesterday' } else { '{0} days ago' -f [int]$ago.TotalDays }
        $ui.LastCleanHint.Text = $when.ToString('dddd d MMMM, h:mm tt')
        # A week or more without a clean: the card turns red and says it is time.
        $overdue = ((Get-Date).Date - $when.Date).TotalDays -ge 7
        if ($ui.LastCleanCard) {
            $ui.LastCleanCard.BorderBrush = $window.FindResource($(if ($overdue) { 'Danger' } else { 'Violet' }))
        }
        if ($overdue) {
            $ui.LastCleanValue.Foreground = $window.FindResource('Danger')
            $ui.LastCleanHint.Text = 'Time to clean. Do a Safe clean, or pick your own.'
        } else {
            $ui.LastCleanValue.ClearValue([Windows.Controls.TextBlock]::ForegroundProperty)
        }
        # The green button asks for the clean while it is overdue, and goes back after one.
        if ($ui.SafeCleanButton) {
            $ui.SafeCleanButton.Content = if ($overdue) { 'Cleaning time - press here' } else { 'Make my PC cleaner' }
            # The longer words get a little less padding so the buttons beside it stay on one row.
            $ui.SafeCleanButton.FontSize = if ($overdue) { 13 } else { 15 }
            $ui.SafeCleanButton.Padding = if ($overdue) { [Windows.Thickness]::new(12, 9, 12, 9) } else { [Windows.Thickness]::new(20, 9, 20, 9) }
            # While overdue it bounces to catch the eye, until it is pressed.
            if ($overdue) { Start-DRCleanButtonBounce } else { Stop-DRCleanButtonBounce }
        }
        # Red and blue lights in the top corners, taking turns, while a clean is overdue.
        if ($ui.LastCleanLightBlue -and $ui.LastCleanLightRed) {
            if (-not (Get-Variable -Name DRLightOn -Scope Script -ErrorAction SilentlyContinue)) { $script:DRLightOn = $false; $script:DRLightTimer = $null }
            $lightState = if ($overdue) { 'Visible' } else { 'Collapsed' }
            $ui.LastCleanLightBlue.Visibility = $lightState
            $ui.LastCleanLightRed.Visibility = $lightState
            if ($overdue) {
                if (-not $script:DRLightTimer) {
                    $script:DRLightTimer = New-Object Windows.Threading.DispatcherTimer
                    $script:DRLightTimer.Interval = [TimeSpan]::FromMilliseconds(500)
                    $script:DRLightTimer.Add_Tick({
                        $script:DRLightOn = -not $script:DRLightOn
                        $ui.LastCleanLightBlue.Opacity = if ($script:DRLightOn) { 1.0 } else { 0.2 }
                        $ui.LastCleanLightRed.Opacity = if ($script:DRLightOn) { 0.2 } else { 1.0 }
                    })
                }
                $script:DRLightTimer.Start()
            } elseif ($script:DRLightTimer) {
                $script:DRLightTimer.Stop()
            }
        }
        return
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
    try { Set-DRLastCleanCard } catch { }
    try { Set-DRScanLines } catch { }
    try { Set-DRLevelDates } catch { }
    if (-not $ui.DashboardHistoryList) { return }
    $ui.DashboardHistoryList.Children.Clear()

    $files = @()
    try {
        $localAppData = $env:LOCALAPPDATA
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

    $localAppData = $env:LOCALAPPDATA
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
        # A task that takes a while does not report how far it is, so the blue bar fills by time instead: the bar for the
        # whole run is the finished tasks plus a share of the one running, from how long that task took last time (or a
        # guess from its listed time). It slows near the end of that share and never reaches it until the task is done.
        $curTaskId = if ($busyNow -and -not $script:analysisMode -and $activeTaskId) { [string]$activeTaskId } else { '' }
        if ($curTaskId -ne [string]$script:DRScanTask) {
            if ($script:DRScanTask -and $script:DRScanStart) {
                # The task before this one ended. One that finished on its own teaches the next run how long it takes.
                try {
                    $taskDone = @($runEvents | Where-Object { $_.TaskId -eq $script:DRScanTask -and $_.State -eq 'Completed' }).Count -gt 0
                    if ($taskDone) {
                        if (-not (Test-Path -LiteralPath 'HKCU:\Software\DRDirect\PC Cleaner')) { New-Item -Path 'HKCU:\Software\DRDirect\PC Cleaner' -Force | Out-Null }
                        Set-ItemProperty -LiteralPath 'HKCU:\Software\DRDirect\PC Cleaner' -Name ('Last_' + $script:DRScanTask) -Value ([int]((Get-Date) - $script:DRScanStart).TotalSeconds) -Type DWord
                    }
                } catch { }
            }
            $script:DRScanTask = $curTaskId
            $script:DRScanStart = if ($curTaskId) { Get-Date } else { $null }
            if ($curTaskId) {
                $script:DRScanGuess = 60.0
                try {
                    $listed = [string](@($catalog | Where-Object { $_.Id -eq $curTaskId } | Select-Object -First 1).Duration)
                    if ($listed -match '(\d+)\s*-\s*(\d+)\s*min') { $script:DRScanGuess = 30.0 * ([double]$Matches[1] + [double]$Matches[2]) }
                    elseif ($listed -match '<\s*(\d+)\s*min') { $script:DRScanGuess = 30.0 * [double]$Matches[1] }
                    elseif ($listed -match 'hour') { $script:DRScanGuess = 5400.0 }
                    elseif ($listed -match '(\d+)\s*min') { $script:DRScanGuess = 60.0 * [double]$Matches[1] }
                    $lastSecs = [double](Get-ItemProperty -LiteralPath 'HKCU:\Software\DRDirect\PC Cleaner' -Name ('Last_' + $curTaskId) -ErrorAction Stop).('Last_' + $curTaskId)
                    if ($lastSecs -ge 5) { $script:DRScanGuess = $lastSecs }
                } catch { }
            }
        }
        if ($curTaskId) {
            $taskFrac = ((Get-Date) - $script:DRScanStart).TotalSeconds / [Math]::Max(5.0, $script:DRScanGuess)
            $taskShare = if ($taskFrac -lt 0.9) { $taskFrac } else { 0.9 + 0.09 * (1 - [Math]::Exp(-($taskFrac - 0.9) * 2)) }
            $planTotal = [Math]::Max(1, @($catalog | Where-Object { $selection[$_.Id] }).Count)
            $planDone = [Math]::Max(0, $planTotal - $runQueue.Count - 1)
            $planPct = [Math]::Min(99, 100.0 * ($planDone + $taskShare) / $planTotal)
            $ui.OverallProgress.IsIndeterminate = $false; $ui.RunStripBar.IsIndeterminate = $false
            $ui.OverallProgress.Value = $planPct; $ui.RunStripBar.Value = $planPct
            $ui.ProgressPercent.Text = 'About ' + [int]$planPct + '%'
        }
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
        foreach ($navName in @('NavHealth', 'NavMemory', 'NavPowerHeat')) {
            # The three checks are never locked: each can be pressed every time, even while it shows a green tick.
            $locked = $false
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
            } elseif ($item.PSObject.Properties['HealthCheck']) {
                Set-DRWindowsHealthCard $item
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
                } elseif ($item.PSObject.Properties['HealthCheck']) {
                    Set-DRWindowsHealthCard $item
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
            if (-not $script:healthShown) { $ui.WindowsStatusText.Text='Analysis complete' }
        } else {
            $completed = @($runEvents | Where-Object { $_.TaskId -eq $activeTaskId -and $_.State -in @('Completed','Failed') } | Select-Object -Last 1)
            if (-not $completed) { $failure=New-DREvent -TaskId $activeTaskId -State Failed -Message 'The maintenance task ended without a final status.'; $runEvents.Add($failure); Set-ProgressRowState $activeTaskId 'Failed' $failure.Message }
            $total=@($catalog | Where-Object { $selection[$_.Id] }).Count; $finished=$total-$runQueue.Count; $percent=[int](100*$finished/[Math]::Max(1,$total)); $ui.OverallProgress.Value=$percent; $ui.ProgressPercent.Text="$percent%"
            Start-NextTask
        }
    }
})
$pollTimer.Start()

# What starts ticked. The starting cleanup level resets every box, so this runs after it.
function Set-DRDefaultTicks {
    # Check my security starts with every task ticked except the full scan (an hour or more) and
    # "Restore typing settings" (it only undoes "Stop sending typing data") and "Remove Defender
    # exclusions", which deletes settings and is left for the person to choose.
    foreach ($task in @($catalog | Where-Object { $_.Category -eq 'Security' -and $_.Id -notin @('security.full-scan','security.typing-privacy-restore','security.remove-exclusions','security.win11-extras','security.win11-extras-restore','security.telemetry-off','security.telemetry-off-restore','security.compat-task-off','security.compat-task-on','security.sweep') })) { $selection[$task.Id] = $true }
    # Speed and space only looks at the PC (and releases idle memory), so it starts fully ticked.
    foreach ($task in @($catalog | Where-Object { $_.Category -eq 'Speed' })) { $selection[$task.Id] = $true }
    Update-SelectionSummary
}

foreach ($task in $catalog) { $selection[$task.Id] = $false }
Set-DRDefaultTicks
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
$ui.RunRestartCombo.Add_SelectionChanged({
    try { $choice = $ui.RunRestartCombo.SelectedItem; if ($choice) { $script:restartDelaySeconds = [int]$choice.Tag } } catch { }
})
$ui.NavHealth.Add_Click({ Invoke-DRAIRunNow -TaskIds @('health.drive-check') })
$ui.NavMemory.Add_Click({ Invoke-DRAIRunNow -TaskIds @('health.ram-check') })
$ui.NavPowerHeat.Add_Click({ Invoke-DRAIRunNow -TaskIds @('health.power-heat-check') })
$ui.NavSpeed.Add_Click({ Set-Page 'Speed' })
$ui.NavHibernate.Add_Click({ Set-Page 'Hibernate' })
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
    '       ____      ____      ____   ___  ____   _____   ____  _____',
    '      |  _ \    |  _ \    |  _ \ |_ _||  _ \ | ____| / ___||_   _|',
    '      | | | |   | |_) |   | | | | | | | |_) ||  _|  | |      | |',
    '      | |_| | _ |  _ <  _ | |_| | | | |  _ < | |___ | |___   | |',
    '      |____/ (_)|_| \_\(_)|____/ |___||_| \_\|_____| \____|  |_|',
    '    _     ____   ____      _   _  ____   ____      _     _____  _____  ____',
    '   / \   |  _ \ |  _ \    | | | ||  _ \ |  _ \    / \   |_   _|| ____||  _ \',
    '  / _ \  | |_) || |_) |   | | | || |_) || | | |  / _ \    | |  |  _|  | |_) |',
    ' / ___ \ |  __/ |  __/    | |_| ||  __/ | |_| | / ___ \   | |  | |___ |  _ <',
    '/_/   \_\|_|    |_|        \___/ |_|    |____/ /_/   \_\  |_|  |_____||_| \_\',
    '     ✦  K E E P I N G   Y O U R   A P P S   F R E S H  ✦'
)

# Centre each block of the banner (and the tagline) in the same width so the two words line up.
function Center-Block([string[]]$lines, [int]$width) {
    $indent = ($lines | ForEach-Object { $_.Length - $_.TrimStart().Length } | Measure-Object -Minimum).Minimum
    $trimmed = @($lines | ForEach-Object { $_.Substring($indent).TrimEnd() })
    $bw = ($trimmed | Measure-Object -Property Length -Maximum).Maximum
    $pad = ' ' * [Math]::Max(0, [int][Math]::Floor(($width - $bw) / 2))
    $trimmed | ForEach-Object { $pad + $_ }
}
$bannerWidth = 78
$banner = @(Center-Block $banner[0..4] $bannerWidth) + @(Center-Block $banner[5..9] $bannerWidth) + @(Center-Block @($banner[10]) $bannerWidth)

try { Clear-Host } catch {}
$frames = if ($NoAnim) { 1 } else { 24 }
for ($f = 0; $f -lt $frames; $f++) {
    if ($f -gt 0) { try { [Console]::SetCursorPosition(0, 0) } catch {} }
    Write-Host ''
    # The D.R.Direct APP Updater letters are solid bright green; the tagline (last line, bold) is bright blue.
    foreach ($line in $banner) {
        if ($line -like '*K E E P I N G*') { Write-Host ("$ESC[1m" + (RGB 0 160 255 $line)) }
        else { Write-Host (RGB 0 255 0 $line) }
    }
    Write-Host ''
    if (-not $NoAnim) { Start-Sleep -Milliseconds 40 }
}
Write-Host (RGB 0 255 80 ('═' * $bannerWidth))
Write-Host ''

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host (RGB 255 60 90 '💥 winget not found. Install "App Installer" from the Microsoft Store.')
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}

# ---- 0. make sure PowerShell 7 and Windows Terminal are installed -----------
# Both come from winget and keep themselves current through the upgrade below.
# Only a clear "not installed" answer triggers an install; if winget cannot tell
# (no network, source down), nothing is installed.
$essentials = @(
    # Present: winget does not always know about a copy that was installed another way,
    # so look for the program itself before deciding it is missing.
    @{ Name = 'PowerShell 7';      Id = 'Microsoft.PowerShell'
       Present = { (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')) -or [bool](Get-Command pwsh.exe -ErrorAction SilentlyContinue) } },
    @{ Name = 'Windows Terminal';  Id = 'Microsoft.WindowsTerminal'
       Present = { [bool](Get-Command wt.exe -ErrorAction SilentlyContinue) -or [bool](Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue) } }
)
$wingetPath = (Get-Command winget).Source
$ok = @(); $fail = @()
foreach ($e in $essentials) {
    if (& $e.Present) { continue }
    $null = & $wingetPath list --id $e.Id --exact --accept-source-agreements 2>&1
    if ($LASTEXITCODE -ne -1978335212) { continue }   # installed, or winget could not tell
    Write-Host (RGB 0 255 200 "🧰 $($e.Name) is not installed - installing it...")
    $a = @('install', '--id', $e.Id, '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements')
    $proc = Start-Process $wingetPath -ArgumentList $a -NoNewWindow -PassThru
    $null = $proc.Handle
    if (-not $proc.WaitForExit($TimeoutMinutes * 60000)) {
        try { Stop-Process -Id $proc.Id -Force } catch {}
        Write-Host (RGB 255 60 90 "⏰ $($e.Name) timed out after ${TimeoutMinutes}m - skipped")
        $fail += "$($e.Name) (timeout)"
    }
    elseif ($proc.ExitCode -eq 0) {
        Write-Host (RGB 80 255 120 "✅ $($e.Name) installed")
        $ok += "$($e.Name) (installed)"
    }
    elseif ($proc.ExitCode -in -1978335135, -1978335189) {
        # Already there under another name, or this PC cannot run it. Nothing to report.
        Write-Host (RGB 150 150 255 "⏭️  $($e.Name) - not needed on this PC")
    }
    else {
        Write-Host (RGB 255 60 90 "💥 $($e.Name) could not be installed (exit code $($proc.ExitCode))")
        $fail += "$($e.Name) (exit $($proc.ExitCode))"
    }
}
Write-Host ''

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
# Adobe Express Photos is not used here and its download keeps failing winget's checksum check.
$skipName = 'Adobe Express*'
foreach ($s in @($pkgs | Where-Object { ($skipIds -contains $_.Id) -or ($_.Name -like $skipName) })) {
    Write-Host (RGB 150 150 255 "⏭️  Skipping $($s.Name) [$($s.Id)]")
}
$pkgs = @($pkgs | Where-Object { ($skipIds -notcontains $_.Id) -and ($_.Name -notlike $skipName) })
if ($pkgs.Count -eq 0) {
    Write-Host (RGB 150 150 255 '😎 Everything is already up to date!')
    Read-Host 'Press Enter to close' | Out-Null
    exit 0
}

Write-Host (RGB 255 160 0 "📦 $($pkgs.Count) packages to upgrade:")
$pkgs | ForEach-Object { Write-Host (RGB 255 0 200 "   ✨ $($_.Name) ") -NoNewline; Write-Host (RGB 150 150 255 "[$($_.Id)]") }
Write-Host ''

$wingetExe = (Get-Command winget).Source
# ---- 2. upgrade each one with live winget progress --------------------------
$start = Get-Date; $i = 0
foreach ($p in $pkgs) {
    $i++
    Write-Host (RGB 0 255 80 ('-' * 90))
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
        Write-Host (RGB 150 150 255 "⏭️  $($p.Name) - installed by its own installer, so it updates itself. Nothing to uninstall, kept current one")
    }
    elseif ($proc.ExitCode -eq -1978335189) {
        # The newer version does not fit this PC (architecture or requirements). The
        # installed copy is untouched and fine, so this is not a problem either.
        Write-Host (RGB 150 150 255 "⏭️  $($p.Name) - newer version does not apply to this PC, kept current one")
    }
    elseif ($proc.ExitCode -eq 0) {
        Write-Host (RGB 80 255 120 "✅ $($p.Name) upgraded")
        $ok += $p.Name
    }
    elseif ($proc.ExitCode -eq -1978335212 -and $p.Name -like 'PowerShell 7*') {
        # PowerShell 7 was put on by hand, so winget lists it as out of date but cannot upgrade it by that name.
        # Installing the winget package over it brings it up to date and lets winget look after it from now on.
        Write-Host (RGB 0 255 200 "🧰 $($p.Name) was not installed through winget - bringing it under winget...")
        $ia = @('install', '--id', 'Microsoft.PowerShell', '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements')
        $iproc = Start-Process $wingetExe -ArgumentList $ia -NoNewWindow -PassThru
        $null = $iproc.Handle
        if (-not $iproc.WaitForExit($TimeoutMinutes * 60000)) {
            try { Stop-Process -Id $iproc.Id -Force } catch {}
            Write-Host (RGB 255 60 90 "⏰ PowerShell 7 timed out after ${TimeoutMinutes}m - skipped")
            $fail += 'PowerShell 7 (timeout)'
        }
        elseif ($iproc.ExitCode -eq 0) {
            Write-Host (RGB 80 255 120 '✅ PowerShell 7 is now installed through winget and up to date')
            $ok += 'PowerShell 7'
        }
        elseif ($iproc.ExitCode -in -1978335135, -1978335189) {
            Write-Host (RGB 150 150 255 '⏭️  PowerShell 7 - already current, kept as it is')
        }
        else {
            Write-Host (RGB 255 60 90 "💥 PowerShell 7 failed (exit code $($iproc.ExitCode))")
            $fail += "PowerShell 7 (exit $($iproc.ExitCode))"
        }
    }
    else {
        Write-Host (RGB 255 60 90 "💥 $($p.Name) failed (exit code $($proc.ExitCode))")
        $fail += "$($p.Name) (exit $($proc.ExitCode))"
    }
}

# ---- 3. summary -------------------------------------------------------------
$secs = [int]((Get-Date) - $start).TotalSeconds
Write-Host ''
Write-Host (RGB 0 255 80 ('═' * $bannerWidth))
Write-Host (RGB 80 255 120 "🎉 Done in ${secs}s") -NoNewline
Write-Host (RGB 255 230 0 "   ✅ $($ok.Count) upgraded") -NoNewline
if ($fail.Count -eq 0) { Write-Host (RGB 80 255 120 "   ✅ no problems") }
else { Write-Host (RGB 255 60 90 "   💥 $($fail.Count) problems") }
foreach ($f in $fail) { Write-Host (RGB 255 60 90 "   - $f") }
Write-Host (RGB 0 255 80 ('=' * 90))
Write-Host ''
Read-Host 'Press Enter to close' | Out-Null

'@
    try {
        $file = Join-Path $env:TEMP 'DRDirect-Winget-Upgrade.ps1'
        [IO.File]::WriteAllText($file, $flashy, (New-Object Text.UTF8Encoding $true))
        # 'start' forces a real new console window, like the cmd route that always showed one; the script itself waits for Enter before it closes, on every path.
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c start "DRDirect App Updater" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $file + '"') -WindowStyle Hidden | Out-Null
        $ui.AppUpdatesStatus.Text = 'Updating apps in a colour PowerShell window. Close it when it says it has finished.'
    } catch {
        $ui.AppUpdatesStatus.Text = "Could not start the update window: $($_.Exception.Message)"
    }
}
function Invoke-DRUpdateAllApps {
    $answer = [Windows.MessageBox]::Show("This runs 'winget upgrade --all' and updates every app winget can update on this PC.`n`nIt also installs PowerShell 7 and Windows Terminal if this PC does not have them.`n`nSome apps may close or restart during their update. Save your work first.`n`nContinue?", 'DRDirect PC Cleaner',
        [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
    if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
    if (Get-Command winget -ErrorAction SilentlyContinue) { Start-DRFlashyUpgrade; return }
    Start-DRWingetWindow 'upgrade --all --silent --accept-source-agreements --accept-package-agreements' 'Updating apps in a console window. Close it when it says it has finished.'
}
function Resolve-DRUninstallerExe {
    # The DRDirect Uninstaller ships in its own folder beside the Cleaner. It is a
    # separate program (based on Bulk Crap Uninstaller, Apache 2.0) that asks before
    # it removes anything, and it never touches the internet.
    $roots = New-Object System.Collections.Generic.List[string]
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($exe)) { $roots.Add((Split-Path -Parent $exe)) }
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $roots.Add($PSScriptRoot) }
    try {
        if (-not [string]::IsNullOrWhiteSpace([AppDomain]::CurrentDomain.BaseDirectory)) {
            $roots.Add([AppDomain]::CurrentDomain.BaseDirectory)
        }
    } catch { }
    # An updated interface runs as a script from the Scripts folder under AppData, so
    # "beside this script" is not where the user keeps the Cleaner. The program that
    # started it is, so walk up through the programs that launched this one.
    try {
        $walkId = $PID
        for ($level = 0; $level -lt 6 -and $walkId; $level++) {
            $info = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$walkId" -ErrorAction Stop
            if (-not $info) { break }
            if ($level -gt 0 -and -not [string]::IsNullOrWhiteSpace($info.ExecutablePath)) {
                $roots.Add((Split-Path -Parent $info.ExecutablePath))
            }
            $walkId = [int]$info.ParentProcessId
            if ($walkId -le 4) { break }
        }
    } catch { }
    # The Cleaner unpacks its own copy here the first time it starts, so this is the usual place.
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $unpacked = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Uninstaller\BCUninstaller.exe'
        if (Test-Path -LiteralPath $unpacked -PathType Leaf) { return $unpacked }
    }
    foreach ($root in @($roots | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $candidate = Join-Path -Path $root -ChildPath 'DRDirect Uninstaller\BCUninstaller.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Show-DRRunningUninstaller {
    # Going back and forth must never start over. If this uninstaller is already open
    # (even minimised), bring that same window forward instead of opening a second one
    # that would have to scan every program again.
    param([string]$UninstallerPath)
    try {
        $ours = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='BCUninstaller.exe'" -ErrorAction Stop |
            Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $UninstallerPath) })
    } catch { return $false }
    foreach ($candidate in $ours) {
        $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
        if (-not $process -or $process.MainWindowHandle -eq 0) { continue }
        if (-not ('DRFrontWindow' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DRFrontWindow {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
}
'@
        }
        $handle = $process.MainWindowHandle
        if ([DRFrontWindow]::IsIconic($handle)) { [void][DRFrontWindow]::ShowWindow($handle, 9) }
        [void][DRFrontWindow]::SetForegroundWindow($handle)
        return $true
    }
    return $false
}

function Get-DRCleanerLauncherPath {
    # The program file that started this Cleaner, so the uninstaller's "Back to the
    # Cleaner" button can start it again if it was closed in the meantime.
    try {
        $walkId = $PID
        for ($level = 0; $level -lt 6 -and $walkId; $level++) {
            $info = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$walkId" -ErrorAction Stop
            if (-not $info) { break }
            if ($info.ExecutablePath -and ([IO.Path]::GetFileName($info.ExecutablePath) -like 'DRDirect PC Cleaner*.exe')) { return $info.ExecutablePath }
            $walkId = [int]$info.ParentProcessId
            if ($walkId -le 4) { break }
        }
    } catch { }
    return $null
}

$script:DRUninstallerUpdateTried = $false

function Start-DRUninstallerUpdate {
    # Returns $true when the update was started; Open-DRUninstaller is called again when it ends.
    try {
        # The updater is built into the exe, not a file a new runspace could load,
        # so hand over its functions and settings as they are.
        $names = 'ConvertFrom-DRPkcs1PublicKey', 'Test-DRManifestSignature', 'Get-DRUpdateRoot', 'Get-DRInstalledVersion',
            'Clear-DRStaleTemp', 'Get-DRFileHashWithRetry', 'Update-DRUninstallerFromFeed'
        $code = ($names | ForEach-Object { "function $_ {`r`n$((Get-Command $_ -CommandType Function).Definition)`r`n}" }) -join "`r`n"

        $script:DRUnUpdateRunspace = [RunspaceFactory]::CreateRunspace()
        $script:DRUnUpdateRunspace.Open()
        foreach ($name in 'DRUpdateFeed', 'DRUpdateRef', 'DRUpdateHeaders', 'DRUpdatePublicKey') {
            $script:DRUnUpdateRunspace.SessionStateProxy.SetVariable($name, (Get-Variable -Name $name -Scope Script -ValueOnly))
        }
        $script:DRUnUpdatePs = [PowerShell]::Create()
        $script:DRUnUpdatePs.Runspace = $script:DRUnUpdateRunspace
        $null = $script:DRUnUpdatePs.AddScript("Set-StrictMode -Version 2.0`r`n$code`r`nUpdate-DRUninstallerFromFeed")
        $script:DRUnUpdateAsync = $script:DRUnUpdatePs.BeginInvoke()
    } catch {
        return $false
    }

    $ui.OverlayContinueButton.Visibility = 'Collapsed'
    $ui.OverlayPercent.Visibility = 'Collapsed'
    $ui.OverlayProgress.IsIndeterminate = $true
    $ui.OverlayTitle.Text = 'Updating the Uninstaller'
    $ui.OverlayMessage.Text = 'Getting the new version of the DRDirect Uninstaller Program. ' +
        'This only happens once after an update and can take up to a minute. Please wait...'
    $ui.BusyOverlay.Visibility = 'Visible'

    # Script scope: the timer's handler runs in its own scope, and StrictMode stops on anything it cannot see.
    $script:DRUnUpdateTimer = New-Object Windows.Threading.DispatcherTimer
    $script:DRUnUpdateTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:DRUnUpdateTimer.Add_Tick({
        if (-not $script:DRUnUpdateAsync.IsCompleted) { return }
        $script:DRUnUpdateTimer.Stop()
        try {
            $null = $script:DRUnUpdatePs.EndInvoke($script:DRUnUpdateAsync)
        } catch { }
        try {
            $script:DRUnUpdatePs.Dispose()
            $script:DRUnUpdateRunspace.Close()
            $script:DRUnUpdateRunspace.Dispose()
        } catch { }
        $ui.BusyOverlay.Visibility = 'Collapsed'
        $ui.OverlayProgress.IsIndeterminate = $false
        $ui.OverlayPercent.Visibility = 'Visible'
        # Whether it worked or not, open the Uninstaller that is now there.
        $script:DRUninstallerUpdateTried = $true
        Open-DRUninstaller
    })
    $script:DRUnUpdateTimer.Start()
    return $true
}

function Open-DRUninstaller {
    if (Test-DROtherToolBusy -Opening 'Uninstaller') { return }
    if ($TestMode) {
        [Windows.MessageBox]::Show('Test mode: the DRDirect Uninstaller Program would open here.', 'DRDirect PC Cleaner',
            [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    # The Uninstaller has its own key. The launcher says whether this PC already has one.
    if ($env:DRDIRECT_UNINSTALLER_OK -eq '0') {
        if ((Show-DRActivation 'locked' 'DRDirect Uninstaller') -ne 'activated') { return }
        $env:DRDIRECT_UNINSTALLER_OK = '1'
    }
    # An accepted update may carry a newer Uninstaller. Put it in place before it opens.
    # It can take a minute, so it runs in the background behind a "please wait" overlay,
    # and opening carries on once it is done. It is tried once per click.
    if (-not $script:DRUninstallerUpdateTried -and
        (Get-Command Update-DRUninstallerFromFeed -ErrorAction SilentlyContinue) -and
        (Update-DRUninstallerFromFeed -CheckOnly)) {
        if (Start-DRUninstallerUpdate) { return }
    }
    $script:DRUninstallerUpdateTried = $false
    $uninstaller = Resolve-DRUninstallerExe
    if (-not $uninstaller) {
        [Windows.MessageBox]::Show(
            "The DRDirect Uninstaller Program was not found beside the Cleaner." + [Environment]::NewLine + [Environment]::NewLine +
            "Keep the 'DRDirect Uninstaller' folder in the same folder as the Cleaner, then try again.",
            'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    if (Show-DRRunningUninstaller -UninstallerPath $uninstaller) { return }
    try {
        $launcher = Get-DRCleanerLauncherPath
        if ($launcher) { $env:DRDIRECT_CLEANER_EXE = $launcher }
        Start-Process -FilePath $uninstaller -WorkingDirectory (Split-Path -Parent $uninstaller)
    } catch {
        [Windows.MessageBox]::Show("Could not open the DRDirect Uninstaller Program: $($_.Exception.Message)", 'DRDirect PC Cleaner',
            [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
    }
}
# 3D buttons on the Dashboard: on unless the person switched them off.
$script:DR3DKey = 'HKCU:\Software\DRDirect\PC Cleaner'
# The 3D effects come from the XAML; keep them so they can be put back. They
# go in as the plain .NET objects - a PowerShell wrapper crashes the window.
$script:DR3DEffects = @{
    Shadow = $window.Resources['DR3DShadow'].psobject.BaseObject
    Text   = $window.Resources['DR3DText'].psobject.BaseObject
    Button = $window.Resources['DR3DButton'].psobject.BaseObject
    Card   = $window.Resources['DR3DCard'].psobject.BaseObject
    HeroText = $window.Resources['DR3DHeroText'].psobject.BaseObject
    CardSoft = $window.Resources['DR3DCardSoft'].psobject.BaseObject
    CardFace = $window.Resources['DR3DCardFace'].psobject.BaseObject
    Letter   = $window.Resources['DR3DLetter'].psobject.BaseObject
}
# The Max 3D card face: a bright top edge that fades into a deeper blue at the bottom, so the card looks like a raised pillow.
$script:DR3DMaxCardFace = New-Object Windows.Media.LinearGradientBrush
$script:DR3DMaxCardFace.StartPoint = [Windows.Point]::new(0, 0); $script:DR3DMaxCardFace.EndPoint = [Windows.Point]::new(0, 1)
foreach ($stop in @(@('#FFFFFF', 0.0), @('#F3F9FF', 0.10), @('#DCEBFF', 0.5), @('#B6D0F4', 1.0))) {
    [void]$script:DR3DMaxCardFace.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.ColorConverter]::ConvertFromString($stop[0]), [double]$stop[1])))
}
function New-DRSlabBrush([string]$Top, [string]$Bottom) {
    # A slab that shades from a lighter blue where it meets the button down to a deeper blue at the bottom.
    $brush = New-Object Windows.Media.LinearGradientBrush
    $brush.StartPoint = [Windows.Point]::new(0, 0); $brush.EndPoint = [Windows.Point]::new(0, 1)
    [void]$brush.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.ColorConverter]::ConvertFromString($Top), [double]0)))
    [void]$brush.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.ColorConverter]::ConvertFromString($Bottom), [double]1)))
    $brush.psobject.BaseObject
}
function New-DRShadow([string]$Color, [double]$Depth, [double]$Blur, [double]$Opacity, [double]$Direction = 270) {
    # The plain effect object, not the PowerShell wrapper around it: the window refuses a wrapped one.
    (New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString($Color); ShadowDepth = $Depth; BlurRadius = $Blur; Opacity = $Opacity; Direction = $Direction }).psobject.BaseObject
}
$script:DR3DMaxEffects = @{
    Shadow   = New-DRShadow '#2147A8' 30 40 0.55
    Text     = New-DRShadow '#000000' 3 3 0.6
    Button   = New-DRShadow '#2147A8' 24 32 0.6
    Card     = New-DRShadow '#3A63C4' 18 0 1.0
    HeroText = New-DRShadow '#000820' 8 4 0.9 300
    Letter   = New-DRShadow '#0A1438' 1.5 2 0.26
}
function Set-DR3DButtons {
    param([bool]$On, [bool]$Max = $false)
    if ($On) {
        # Max 3D swaps in bigger shadows and thicker raised edges; the normal 3D look uses the ones the window started with.
        $set = if ($Max) { $script:DR3DMaxEffects } else { $script:DR3DEffects }
        $window.Resources['DR3DShadow'] = $set.Shadow
        $window.Resources['DR3DText'] = $set.Text
        $window.Resources['DR3DButton'] = $set.Button
        $window.Resources['DR3DCard'] = $set.Card
        $window.Resources['DR3DHeroText'] = $set.HeroText
        # A little shadow under every letter, a touch deeper in Max 3D.
        $window.Resources['DR3DLetter'] = $set.Letter
        # The cards keep their soft shadow in the normal look and get a thick solid slab in Max 3D.
        $window.Resources['DR3DCardSoft'] = $(if ($Max) { $script:DR3DMaxEffects.Card } else { $script:DR3DEffects.CardSoft })
        $window.Resources['DR3DCardFace'] = $(if ($Max) { $script:DR3DMaxCardFace.psobject.BaseObject } else { $script:DR3DEffects.CardFace.psobject.BaseObject })
        $window.Resources['DR3DEdgeHero'] = $(if ($Max) { [Windows.Thickness]::new(0, 14, 0, -14) } else { [Windows.Thickness]::new(0, 8, 0, -8) })
        $window.Resources['DR3DEdgeSmall'] = $(if ($Max) { [Windows.Thickness]::new(0, 11, 0, -11) } else { [Windows.Thickness]::new(0, 6, 0, -6) })
        $window.Resources['DR3DEdgeNav'] = $(if ($Max) { [Windows.Thickness]::new(0, 9, 0, -9) } else { [Windows.Thickness]::new(0, 4, 0, -4) })
        $window.Resources['DR3DLip'] = $(if ($Max) { [Windows.Thickness]::new(0, 0, 0, 7) } else { [Windows.Thickness]::new(0, 0, 0, 4) })
        $window.Resources['DR3DParts'] = [Windows.Visibility]::Visible
        $window.Resources['DR3DMaxParts'] = $(if ($Max) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed })
        # Max 3D slabs are a rich blue, never black.
        $window.Resources['DR3DSlabA'] = $(if ($Max) { New-DRSlabBrush '#4D79D8' '#1A3688' } else { [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#B0000814')) })
        $window.Resources['DR3DSlabB'] = $(if ($Max) { New-DRSlabBrush '#4F82E2' '#17358F' } else { [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#B3000A30')) })
        $window.Resources['DR3DEdgeNavMid'] = $(if ($Max) { [Windows.Thickness]::new(0, 5, 0, -5) } else { [Windows.Thickness]::new(0, 2, 0, -2) })
        $window.Resources['DR3DNavMargin'] = $(if ($Max) { [Windows.Thickness]::new(10, 4, 10, 16) } else { [Windows.Thickness]::new(10, 3, 10, 8) })
    } else {
        $window.Resources['DR3DShadow'] = $null
        $window.Resources['DR3DText'] = $null
        $window.Resources['DR3DButton'] = $null
        $window.Resources['DR3DCard'] = $null
        $window.Resources['DR3DHeroText'] = $null
        $window.Resources['DR3DLetter'] = $null
        $window.Resources['DR3DCardSoft'] = $script:DR3DEffects.CardSoft
        $window.Resources['DR3DCardFace'] = $script:DR3DEffects.CardFace.psobject.BaseObject
        $window.Resources['DR3DParts'] = [Windows.Visibility]::Collapsed
        $window.Resources['DR3DMaxParts'] = [Windows.Visibility]::Collapsed
        $window.Resources['DR3DSlabA'] = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#B0000814'))
        $window.Resources['DR3DSlabB'] = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#B3000A30'))
        $window.Resources['DR3DNavMargin'] = [Windows.Thickness]::new(10, 3, 10, 8)
    }
}
# The first time the Cleaner opens the 3D look is off. The person turns it on with the switch, and the choice is remembered.
$dr3dOn = $false
try { $v = Get-ItemProperty -LiteralPath $script:DR3DKey -Name 'Buttons3D' -ErrorAction Stop; $dr3dOn = [int]$v.Buttons3D -ne 0 } catch { }
# Max 3D is a second, deeper level on top of the 3D look. It is off until the person turns it on.
$dr3dMax = $false
try { $v = Get-ItemProperty -LiteralPath $script:DR3DKey -Name 'Max3D' -ErrorAction Stop; $dr3dMax = [int]$v.Max3D -ne 0 } catch { }
if (-not $dr3dOn) { $dr3dMax = $false }
Set-DR3DButtons -On $dr3dOn -Max $dr3dMax
$ui.Buttons3DSwitch.IsChecked = $dr3dOn
$ui.Max3DSwitch.IsChecked = $dr3dMax
# Max 3D is only offered once the 3D look is on, so a first start shows just the plain look and its one switch.
function Update-DRMaxSwitchVisibility { $ui.Max3DSwitch.Visibility = $(if ([bool]$ui.Buttons3DSwitch.IsChecked) { 'Visible' } else { 'Collapsed' }) }
Update-DRMaxSwitchVisibility
function Save-DR3DChoice {
    if ($TestMode) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:DR3DKey)) { New-Item -Path $script:DR3DKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $script:DR3DKey -Name 'Buttons3D' -Value ([int][bool]$ui.Buttons3DSwitch.IsChecked) -Type DWord
        Set-ItemProperty -LiteralPath $script:DR3DKey -Name 'Max3D' -Value ([int][bool]$ui.Max3DSwitch.IsChecked) -Type DWord
    } catch { }
}
$ui.Buttons3DSwitch.Add_Click({
    # Turning the 3D look off also turns Max 3D off, since Max is only a deeper version of it.
    if (-not [bool]$ui.Buttons3DSwitch.IsChecked) { $ui.Max3DSwitch.IsChecked = $false }
    Set-DR3DButtons -On ([bool]$ui.Buttons3DSwitch.IsChecked) -Max ([bool]$ui.Max3DSwitch.IsChecked)
    Update-DRMaxSwitchVisibility
    Save-DR3DChoice
})
# Just for fun: there is nothing deeper than Max 3D, so this switch only asks, then turns itself back off.
if ($ui.CrazyNuttySwitch) {
    $ui.CrazyNuttySwitch.Add_Click({
        # The window shakes like it is going nuts, then the joke.
        try {
            $x = $window.Left
            foreach ($dx in 18, -18, 14, -14, 10, -10, 6, -6, 0) {
                $window.Left = $x + $dx
                $window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Render)
                Start-Sleep -Milliseconds 35
            }
            $window.Left = $x
        } catch { }
        [void][System.Windows.MessageBox]::Show($window, ("Really?! 🤪

You really don't have enough of Max 3D?

Any more 3D and the buttons will jump out of the screen and land in your coffee! ☕"), 'Crazy Nutty 3D', 'OK', 'Question')
        $ui.CrazyNuttySwitch.IsChecked = $false
    })
}
$ui.Max3DSwitch.Add_Click({
    # Max 3D needs the 3D look, so turning it on turns the 3D look on too.
    if ([bool]$ui.Max3DSwitch.IsChecked) { $ui.Buttons3DSwitch.IsChecked = $true }
    Set-DR3DButtons -On ([bool]$ui.Buttons3DSwitch.IsChecked) -Max ([bool]$ui.Max3DSwitch.IsChecked)
    Save-DR3DChoice
})

# The finish sound has its own switch on the Dashboard; the choice is remembered.
$script:DRSoundOn = $true
try { $v = Get-ItemProperty -LiteralPath $script:DR3DKey -Name 'FinishSound' -ErrorAction Stop; $script:DRSoundOn = [int]$v.FinishSound -ne 0 } catch { }
$ui.SoundSwitch.IsChecked = $script:DRSoundOn

# A short, soft, smooth note when the pointer touches a button, so the person hears that it is a button. It is made
# here, and the Sound switch turns it off with the other sounds.
try {
    # A soft rising glide (about a seventh of a second) with a slow fade in and out, so it sounds smooth, not sharp.
    $tickRate = 22050; $tickCount = [int]($tickRate * 0.09)
    $tickSamples = New-Object 'int16[]' $tickCount
    for ($i = 0; $i -lt $tickCount; $i++) {
        $t = $i / $tickRate; $p = $i / $tickCount
        # One soft note with a little bass under it, short, with a rounded swell in and out so there is no click or edge.
        $envelope = [math]::Pow([math]::Sin([math]::PI * $p), 2)
        $tickSamples[$i] = [int16](3200 * $envelope * ([math]::Sin(2 * [math]::PI * 330 * $t) + 0.8 * [math]::Sin(2 * [math]::PI * 165 * $t)))
    }
    $tickBytes = New-Object 'byte[]' ($tickCount * 2)
    [Buffer]::BlockCopy($tickSamples, 0, $tickBytes, 0, $tickBytes.Length)
    $tickStream = New-Object System.IO.MemoryStream
    $tickWriter = New-Object System.IO.BinaryWriter($tickStream)
    $tickWriter.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $tickWriter.Write([int](36 + $tickBytes.Length))
    $tickWriter.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $tickWriter.Write([int]16); $tickWriter.Write([int16]1); $tickWriter.Write([int16]1)
    $tickWriter.Write([int]$tickRate); $tickWriter.Write([int]($tickRate * 2)); $tickWriter.Write([int16]2); $tickWriter.Write([int16]16)
    $tickWriter.Write([Text.Encoding]::ASCII.GetBytes('data')); $tickWriter.Write([int]$tickBytes.Length); $tickWriter.Write($tickBytes)
    $tickWriter.Flush(); $tickStream.Position = 0
    $script:DRHoverSound = New-Object System.Media.SoundPlayer($tickStream)
    $script:DRHoverSound.Load()
    $script:DRHoverLast = [datetime]::MinValue
    [Windows.EventManager]::RegisterClassHandler([Windows.Controls.Button], [Windows.UIElement]::MouseEnterEvent, [Windows.Input.MouseEventHandler]{
        param($sender, $e)
        try {
            if (-not $script:DRSoundOn -or -not $sender.IsEnabled) { return }
            $now = [datetime]::UtcNow
            if (($now - $script:DRHoverLast).TotalMilliseconds -lt 110) { return }
            $script:DRHoverLast = $now
            $script:DRHoverSound.Play()
        } catch { }
    })
} catch { }

# Simple view for a first-time person: one big button and a short menu. Every tool is one click away.
$script:DRSimpleHidden = @('NavFullScan','NavSmartApp','NavSpeed','NavDuplicates','NavHibernate','NavUninstaller','NavSecurity','NavHealth','NavMemory','NavPowerHeat','NavHardware','NavAppUpdates','NavHeadUpdate','NavHeadClean','NavHeadFix','NavHeadCheck',
    'DashOtherTitle','DashOtherGrid','DashMsTools','DashMoreOptions')
function Set-DRUiMode {
    param([bool]$Simple)
    $script:DRSimpleMode = $Simple
    $shown = if ($Simple) { 'Collapsed' } else { 'Visible' }
    foreach ($name in $script:DRSimpleHidden) { $ui[$name].Visibility = $shown }
    $ui.DashMoreHint.Visibility = if ($Simple) { 'Visible' } else { 'Collapsed' }
    $ui.NavModeToggle.Content = if ($Simple) { '＋  Show all tools' } else { '－  Show fewer tools' }
    # Never leave someone on a page the short menu no longer lists.
    if ($Simple -and $script:currentCategory -in @('Speed','Hibernate','Security','Hardware','Health','Memory','AppUpdates','Duplicates')) { Set-Page 'Dashboard' }
}
# Every time the Cleaner opens it starts in the Simple view. Show all tools opens the rest for that visit only.
$script:DRSimpleMode = $true
Set-DRUiMode -Simple $script:DRSimpleMode
# A fade and "More tools below" appear at the foot of the menu whenever part of it is out of sight.
$ui.NavScroll.Add_ScrollChanged({
    $more = ($ui.NavScroll.ScrollableHeight -gt 4) -and ($ui.NavScroll.VerticalOffset -lt ($ui.NavScroll.ScrollableHeight - 4))
    $ui.NavMoreHint.Visibility = if ($more) { 'Visible' } else { 'Collapsed' }
})
$ui.NavMoreHint.Add_MouseLeftButtonUp({ $ui.NavScroll.ScrollToVerticalOffset($ui.NavScroll.ScrollableHeight) })
$ui.DashShowAllButton.Add_Click({ Set-DRUiMode -Simple $false })
$ui.NavModeToggle.Add_Click({
    Set-DRUiMode -Simple (-not $script:DRSimpleMode)
})
$ui.SoundSwitch.Add_Click({
    $script:DRSoundOn = [bool]$ui.SoundSwitch.IsChecked
    if (-not $TestMode) {
        try {
            if (-not (Test-Path -LiteralPath $script:DR3DKey)) { New-Item -Path $script:DR3DKey -Force | Out-Null }
            Set-ItemProperty -LiteralPath $script:DR3DKey -Name 'FinishSound' -Value ([int]$script:DRSoundOn) -Type DWord
        } catch { }
    }
})

# A waiting update must be impossible to miss: both update buttons flash
# green and yellow, pulse in size and glow until it is installed.
$script:DRUpdateFlashOn = $false
$script:DRUpdateFlashSaved = @{}
function Start-DRUpdateFlash {
    if ($script:DRUpdateFlashOn) { return }
    $script:DRUpdateFlashOn = $true
    $script:DRUpdateFlashSaved = @{}
    foreach ($button in @($ui.HeroUpdateButton, $ui.CheckUpdatesButton)) {
        $script:DRUpdateFlashSaved[$button.Name] = @{ Content = $button.Content; Background = $button.Background }
        $button.Content = [string][char]0x2605 + '  NEW UPDATE  ' + [string][char]0x2605
        $button.FontWeight = 'ExtraBold'
        $button.Foreground = [Windows.Media.Brushes]::White

        $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#16C060'))
        $button.Background = $brush
        $colour = New-Object Windows.Media.Animation.ColorAnimation
        $colour.To = [Windows.Media.ColorConverter]::ConvertFromString('#F2C200')
        $colour.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(550))
        $colour.AutoReverse = $true
        $colour.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $brush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $colour)

        $scale = New-Object Windows.Media.ScaleTransform 1, 1
        $button.RenderTransformOrigin = New-Object Windows.Point 0.5, 0.5
        $button.RenderTransform = $scale
        $pulse = New-Object Windows.Media.Animation.DoubleAnimation 1, 1.12, ([Windows.Duration]::new([TimeSpan]::FromMilliseconds(550)))
        $pulse.AutoReverse = $true
        $pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $pulse)
        $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $pulse)
    }
}

function Stop-DRUpdateFlash {
    if (-not $script:DRUpdateFlashOn) { return }
    $script:DRUpdateFlashOn = $false
    foreach ($button in @($ui.HeroUpdateButton, $ui.CheckUpdatesButton)) {
        $saved = $script:DRUpdateFlashSaved[$button.Name]
        $button.RenderTransform = $null
        if ($saved) { $button.Content = $saved.Content; $button.Background = $saved.Background }
        $button.ClearValue([Windows.Controls.Control]::FontWeightProperty)
        $button.ClearValue([Windows.Controls.Control]::ForegroundProperty)
    }
}

$ui.NavUninstaller.Add_Click({ Open-DRUninstaller })
$ui.HeroUninstallButton.Add_Click({ Open-DRUninstaller })

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
function Open-DRSmartAppControl {
    # Only opens the Windows page. Smart App Control is switched on or off there by the person; the Cleaner never changes it.
    try { Start-Process 'windowsdefender://appbrowser' | Out-Null }
    catch { [Windows.MessageBox]::Show("Could not open Windows Security: $($_.Exception.Message)", 'DRDirect PC Cleaner') | Out-Null }
}
$ui.SmartAppControlButton.Add_Click({ Open-DRSmartAppControl })
$ui.NavSmartApp.Add_Click({ Open-DRSmartAppControl })
# One button, one job: only the Defender full scan runs. Nothing ticked elsewhere is added to it.
$ui.NavFullScan.Add_Click({ Invoke-DRAIRunNow -TaskIds @('security.full-scan') })
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
    $planTasks = @($catalog | Where-Object { $_.Category -in @('Cleanup','Repair','Security') -and (Test-TaskInOrderedPreset -Task $_ -Preset $Level) })
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
foreach ($name in 'SafeCleanButton','SafePreviewButton') { if ($ui[$name]) { $ui[$name].Add_Click({ Stop-DRCleanButtonBounce; Invoke-DRSafeClean }) } }
if ($ui.SafePlanRunButton) { $ui.SafePlanRunButton.Add_Click({ Invoke-DRLevelClean }) }
if ($ui.SafeLevelSafeButton) { $ui.SafeLevelSafeButton.Add_Click({ Show-SafePlan -Level 'Safe' -Animate }) }
if ($ui.SafeLevelMediumButton) { $ui.SafeLevelMediumButton.Add_Click({ Show-SafePlan -Level 'Medium' -Animate }) }
if ($ui.SafeLevelAdvancedButton) { $ui.SafeLevelAdvancedButton.Add_Click({ Show-SafePlan -Level 'Advanced' -Animate }) }
foreach ($name in 'UndoAllButton','UndoAllDashButton') { if ($ui[$name]) { $ui[$name].Add_Click({ Invoke-DRUndoAll }) } }
Show-SafePlan

# Opens the Duplicate Finder window straight away, with no page in between.
$ui.NavDuplicates.Add_Click({ $ui.OpenDuplicatesButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) })
$ui.NavAI.Add_Click({ Set-Page 'AI' })
$ui.NavProgress.Add_Click({ Set-Page 'Progress' })
$ui.DashboardHistoryButton.Add_Click({ Set-Page 'History' })
# A short, friendly note that opens when the person clicks the link on the Dashboard.
function Show-DRNote {
    $text = @(
        'My goal is simple: to make Windows run better on every PC.',
        '',

        'I clear the junk, fix what is broken and give your PC a good tune-up, and I really am trying to make it last longer. I am not perfect, you know, but I am doing my best to keep it alive. But sometimes I have to say what nobody wants to hear: an old PC can only do so much.',
        '',
        'It happens to every PC, and to all of us. As we get older, we get slower too. We all take longer to get going in the morning, we all forget things for no reason, and we all groan when someone asks too much at once.',
        '',
        'So if a PC still crawls after a clean, it is nobody''s fault. It may simply be ready to retire to a quiet life on a shelf, with a gold watch and a farewell cake. Give it a good send-off, and when the new one arrives, I will keep that one running nicely too.',
        '',
        '- DRDirect'
    ) -join [Environment]::NewLine
    [void][Windows.MessageBox]::Show($text, 'Please read first', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
}
$ui.DashNoteButton.Add_Click({ Show-DRNote })
$ui.NavNoteButton.Add_Click({ Show-DRNote })
# The note is only there for the first week the Cleaner is used. After that people know about it, so both buttons go away.
$script:DRNoteFirstSeen = $null
try {
    $storedNoteDate = [string](Get-ItemProperty -LiteralPath $script:DR3DKey -Name 'NoteFirstSeen' -ErrorAction Stop).NoteFirstSeen
    $script:DRNoteFirstSeen = [datetime]::Parse($storedNoteDate, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
} catch { }
if (-not $script:DRNoteFirstSeen) {
    $script:DRNoteFirstSeen = Get-Date
    if (-not $TestMode) {
        try {
            if (-not (Test-Path -LiteralPath $script:DR3DKey)) { New-Item -Path $script:DR3DKey -Force | Out-Null }
            Set-ItemProperty -LiteralPath $script:DR3DKey -Name 'NoteFirstSeen' -Value ($script:DRNoteFirstSeen.ToString('o')) -Type String
        } catch { }
    }
}
$noteVisibility = if (((Get-Date) - $script:DRNoteFirstSeen).TotalDays -lt 7) { 'Visible' } else { 'Collapsed' }
$ui.DashNoteButton.Visibility = $noteVisibility
$ui.NavNoteButton.Visibility = $noteVisibility
# Check my PC looks at everything in one go: every drive (SSD and NVMe too), memory, the processor and heat, and the power.
$ui.ScanButton.Add_Click({ Invoke-DRAIRunNow -TaskIds @('health.drive-check', 'health.ram-check', 'health.power-heat-check', 'health.pc-checkup') })
$ui.HealthCheckButton.Add_Click({ Start-DRHealthCheck })
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
        [Windows.MessageBoxImage]::Warning,
        [Windows.MessageBoxResult]::No
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

    # An installed copy does not run from where it was installed: the locked
    # launcher unpacks the app into a temporary _MEI folder and runs it from
    # there, so "beside the exe" is a scratch directory holding no Finder. Ask
    # Windows where the program went, and fall back to the usual location.
    # Inno Setup names the key after the installer's AppId, not the program name.
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{6E1C2F4A-7D3B-4F5E-9A21-D7C0E5B4A8F3}_is1',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{6E1C2F4A-7D3B-4F5E-9A21-D7C0E5B4A8F3}_is1')) {
        try {
            $installed = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallLocation
            if (-not [string]::IsNullOrWhiteSpace($installed)) { $roots.Add($installed.TrimEnd('\')) }
        } catch { }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            $roots.Add((Join-Path $base 'DRDirect PC Cleaner'))
        }
    }

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

    # Installed copies have no loose script: Setup.exe lays down the compiled
    # Duplicate Finder beside the Cleaner. Looking only for the .ps1 greyed the
    # menu item out on every machine that installed the program properly.
    $exe = Resolve-DRDuplicateFinderExe
    if ($exe) { return $exe }

    return $null
}

$ui.OpenDuplicatesButton.Add_Click({
    if (Test-DROtherToolBusy -Opening 'Finder') { return }
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
            if (Get-DRSignedInUserSidOverride) {
                # This copy runs as a hidden admin account (Administrator
                # Protection). Hand the Finder to Explorer so it opens as the
                # person, with their own folders and licence. Unquoted on purpose:
                # Explorer takes the whole argument tail as one path.
                Start-Process -FilePath 'explorer.exe' -ArgumentList $finderExe | Out-Null
            } else {
                Start-Process -FilePath $finderExe | Out-Null
            }
            $ui.DuplicateStatus.Text = 'Duplicate Finder opened in its own window.'
        } catch {
            $ui.DuplicateStatus.Text = "Could not start the Duplicate Finder: $($_.Exception.Message)"
        }
        return
    }

    $finder = Resolve-DRDuplicateFinderPath
    if (-not $finder) {
        $ui.DuplicateStatus.Text = "Could not find the DRDirect Duplicate Finder beside the application."
        return
    }
    # The path contains spaces, so it must arrive at powershell.exe quoted.
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $trialFlag = ''
    try { if (Test-DRTrialMode) { $trialFlag = ' -TrialMode' } } catch { }
    # An installed copy resolves to the compiled Finder, which is launched
    # directly; a developer copy resolves to the loose script, which needs
    # PowerShell to run it. Everything below works the same either way.
    if ($finder -like '*.exe') {
        $launchPath = $finder
        $psArgs = ('-FromCleaner{0}' -f $trialFlag).Trim()
        $launchProcessName = [System.IO.Path]::GetFileNameWithoutExtension($finder)
    }
    else {
        $launchPath = $psExe
        $psArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -FromCleaner{1}' -f $finder, $trialFlag
        $launchProcessName = 'powershell'
    }

    try {
        if (Test-DRAdministrator) {
            # The Cleaner needs administrator rights, but the Duplicate Finder does
            # not - it only touches the user's own files. A child process inherits
            # this one's token, so launch it through Explorer instead, which runs as
            # the logged-in user and hands back an ordinary, unelevated token.
            $shortcut = Join-Path $env:TEMP 'DRDirect Duplicate Finder.lnk'
            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut($shortcut)
            $link.TargetPath = $launchPath
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
                if (Get-Process -Name $launchProcessName -ErrorAction SilentlyContinue |
                        Where-Object { $_.MainWindowTitle -like '*Duplicate Finder*' }) {
                    $appeared = $true
                    break
                }
            }

            if ($appeared) {
                $ui.DuplicateStatus.Text = 'Duplicate Finder opened in its own window, running as your normal user rather than as administrator.'
            } else {
                Start-Process -FilePath $launchPath -ArgumentList $psArgs -WindowStyle Hidden | Out-Null
                $ui.DuplicateStatus.Text = 'Duplicate Finder opened in its own window.'
            }
        } else {
            Start-Process -FilePath $launchPath -ArgumentList $psArgs -WindowStyle Hidden | Out-Null
            $ui.DuplicateStatus.Text = 'Duplicate Finder opened in its own window.'
        }
    } catch {
        $ui.DuplicateStatus.Text = "Could not start the Duplicate Finder: $($_.Exception.Message)"
    }
})

$script:DRHealthPs = $null; $script:DRHealthTimer = $null
function Start-DRHealthCheck {
    # The Windows Health card checks itself: a few seconds of reading in the
    # background when the window opens, so nobody has to press anything to see it.
    if ($script:DRHealthPs) { return }   # already checking
    $ui.HealthCheckButton.Visibility = 'Collapsed'
    $ui.WindowsStatusText.Text = 'Checking...'
    $ui.WindowsStatusHint.Text = 'Takes a few seconds. Nothing is changed.'
    try {
        # Script scope: the timer's handler runs in its own scope (see Start-DRQuietUpdateCheck).
        $script:DRHealthRunspace = [RunspaceFactory]::CreateRunspace()
        $script:DRHealthRunspace.ApartmentState = 'MTA'
        $script:DRHealthRunspace.ThreadOptions = 'ReuseThread'
        $script:DRHealthRunspace.Open()
        $script:DRHealthPs = [PowerShell]::Create()
        $script:DRHealthPs.Runspace = $script:DRHealthRunspace
        $null = $script:DRHealthPs.AddScript([System.IO.File]::ReadAllText($script:DREnginePath) + "`r`nGet-DRWindowsHealth")
        $script:DRHealthAsync = $script:DRHealthPs.BeginInvoke()

        if (-not $script:DRHealthTimer) {
            $script:DRHealthTimer = New-Object Windows.Threading.DispatcherTimer
            $script:DRHealthTimer.Interval = [TimeSpan]::FromMilliseconds(400)
            $script:DRHealthTimer.Add_Tick({
                if (-not $script:DRHealthAsync.IsCompleted) { return }
                $script:DRHealthTimer.Stop()
                try {
                    $result = @($script:DRHealthPs.EndInvoke($script:DRHealthAsync) | Where-Object { $_.PSObject.Properties['HealthCheck'] }) | Select-Object -Last 1
                    if ($result) { Set-DRWindowsHealthCard $result }
                    else { $ui.WindowsStatusText.Text = 'Not checked'; $ui.WindowsStatusHint.Text = 'Windows did not answer. Try again in a moment.'; $ui.HealthCheckButton.Visibility = 'Visible' }
                } catch {
                    $ui.WindowsStatusText.Text = 'Not checked'; $ui.WindowsStatusHint.Text = 'Windows did not answer. Try again in a moment.'; $ui.HealthCheckButton.Visibility = 'Visible'
                }
                try { $script:DRHealthPs.Dispose(); $script:DRHealthRunspace.Close(); $script:DRHealthRunspace.Dispose() } catch { }
                $script:DRHealthPs = $null
            })
        }
        $script:DRHealthTimer.Start()
    } catch {
        $script:DRHealthPs = $null
        $ui.WindowsStatusText.Text = 'Not checked'; $ui.WindowsStatusHint.Text = 'Windows did not answer. Try again in a moment.'; $ui.HealthCheckButton.Visibility = 'Visible'
    }
}

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
                    # Only the Check for updates button in the blue box turns green; nothing else changes.
                    try { Start-DRUpdateFlash } catch { }
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

$ui.HeroUpdateButton.Add_Click({
    $ui.CheckUpdatesButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
})

$ui.UpdateBannerButton.Add_Click({
    $ui.CheckUpdatesButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
})

$script:DRUpdateRunning = $false

function Get-DRLauncherPath {
    # The locked exe starts this script, so it is this PowerShell's parent. Gives
    # '' when the script was started any other way, such as from a console.
    $script:DRLauncherPids = @()
    try {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        $parentId = $parent.ParentProcessId
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$parentId" -ErrorAction Stop
        $path = [string]$parent.ExecutablePath
        if ($path -and ([IO.Path]::GetFileName($path) -like 'DRDirect PC Cleaner*.exe') -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            # The exe is two processes (a starter and the program it unpacks). Remember both, so a reopen can
            # wait until both have gone. Starting too early finds the old window still open and quits.
            $script:DRLauncherPids = @([int]$parentId)
            try {
                $grand = Get-CimInstance Win32_Process -Filter "ProcessId=$($parent.ParentProcessId)" -ErrorAction Stop
                if ([string]$grand.ExecutablePath -eq $path) { $script:DRLauncherPids += [int]$grand.ProcessId }
            } catch { }
            return $path
        }
    } catch { }
    return ''
}

function Complete-DRUpdateInstall {
    # What used to happen straight after Install-DRUpdate returned, now run once
    # the background install has finished.
    param($Result)
    if ($Result -and $Result.Success) {
        $launcher = Get-DRLauncherPath
        if ($launcher) {
            [Windows.MessageBox]::Show("Updated to $($Result.Version)." + [Environment]::NewLine + [Environment]::NewLine +
                'DRDirect PC Cleaner will now close and open again by itself.', 'DRDirect PC Cleaner',
                [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
            try {
                # The exe is a PyInstaller onefile. A copy started from inside a running one
                # inherits its markers and takes itself for a child of that copy, then fails
                # its parent check ("failed to obtain executable path for parent process")
                # once the parent has gone. This asks PyInstaller to treat it as a fresh start.
                $env:PYINSTALLER_RESET_ENVIRONMENT = '1'
                # Open the new copy once this one has gone. The old window holds the "only one window" lock until its
                # process is gone, so a helper waits for it (up to 10 seconds), ends it if it is still there, and then
                # starts the new one. It writes what it did to a small log so a missed restart can be traced.
                $waitIds = (@(@($script:DRLauncherPids) + @([int]$PID)) | Select-Object -Unique | ForEach-Object { [string][int]$_ }) -join ','
                $logFile = Join-Path (Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Logs') 'Update_Relaunch.log'
                $launcherQuoted = $launcher.Replace("'", "''")
                $reopen = @(
                    "`$log = '$($logFile.Replace("'", "''"))'",
                    "function Say(`$m) { try { Add-Content -LiteralPath `$log -Value ((Get-Date).ToString('s') + ' ' + `$m) } catch { } }",
                    "Say 'helper started; waiting for: $waitIds'",
                    "`$ids = @($waitIds)",
                    "`$deadline = (Get-Date).AddSeconds(10)",
                    "while ((Get-Date) -lt `$deadline -and @(`$ids | Where-Object { Get-Process -Id `$_ -ErrorAction SilentlyContinue }).Count) { Start-Sleep -Milliseconds 300 }",
                    "foreach (`$i in `$ids) { if (Get-Process -Id `$i -ErrorAction SilentlyContinue) { Say ('still running, ending ' + `$i); Stop-Process -Id `$i -Force -ErrorAction SilentlyContinue } }",
                    "Start-Sleep -Seconds 2",
                    "try { Start-Process -FilePath '$launcherQuoted'; Say 'opened the new copy' } catch { Say ('could not open: ' + `$_.Exception.Message) }"
                ) -join '; '
                $encodedReopen = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($reopen))
                Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
                    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', $encodedReopen
                $window.Close()
                return
            } catch { }   # could not restart it - fall through to the normal message
        }
    }
    if ($Result -and $Result.Success) {
        $ui.UpdateBanner.Visibility = 'Collapsed'
        # The green "New update" badge is set once at startup and nothing
        # cleared it, so it kept advertising an update already installed
        # until the app was restarted. Put the button back now.
        try {
            Stop-DRUpdateFlash
            $ui.CheckUpdatesButton.ToolTip = $null
        } catch { }
    }
    $message = if ($Result) { [string]$Result.Message } else { 'The update did not finish. Nothing was changed.' }
    $icon = if ($Result -and $Result.Success) { [Windows.MessageBoxImage]::Information } else { [Windows.MessageBoxImage]::Warning }
    [Windows.MessageBox]::Show($message, 'DRDirect PC Cleaner',
        [Windows.MessageBoxButton]::OK, $icon) | Out-Null
}

function Start-DRUpdateInstall {
    <#
        Downloads and installs the update in a background runspace.

        It used to run on the window's own thread. The download is the better
        part of ten megabytes, so on a slow line the window stopped drawing,
        Windows marked it "not responding", and the obvious response - Close
        the program - abandoned the update half way. The window now stays
        alive and says what it is doing. Returns $false if the background
        could not be started, so the caller can fall back rather than skip
        the update.
    #>
    param($Manifest)
    try {
        # The updater is compiled into the exe, not a file a new runspace could
        # load, so hand over the functions the install needs and its settings.
        $names = 'Get-DRUpdateRoot', 'Clear-DRStaleTemp', 'Get-DRFileHashWithRetry', 'Install-DRUpdate'
        $code = ($names | ForEach-Object { "function $_ {`r`n$((Get-Command $_ -CommandType Function).Definition)`r`n}" }) -join "`r`n"

        $script:DRInstallRunspace = [RunspaceFactory]::CreateRunspace()
        $script:DRInstallRunspace.Open()
        foreach ($name in 'DRUpdateFeed', 'DRUpdateRef', 'DRUpdateHeaders', 'DRUpdatableFiles') {
            $script:DRInstallRunspace.SessionStateProxy.SetVariable($name, (Get-Variable -Name $name -Scope Script -ValueOnly))
        }
        $script:DRInstallRunspace.SessionStateProxy.SetVariable('DRInstallManifest', $Manifest)
        $script:DRInstallPs = [PowerShell]::Create()
        $script:DRInstallPs.Runspace = $script:DRInstallRunspace
        $null = $script:DRInstallPs.AddScript("Set-StrictMode -Version 2.0`r`n$code`r`nInstall-DRUpdate -Manifest `$DRInstallManifest")
        $script:DRInstallAsync = $script:DRInstallPs.BeginInvoke()
    } catch {
        return $false
    }

    $ui.OverlayContinueButton.Visibility = 'Collapsed'
    $ui.OverlayPercent.Visibility = 'Collapsed'
    $ui.OverlayProgress.IsIndeterminate = $true
    $ui.OverlayTitle.Text = 'Installing the update'
    $ui.OverlayMessage.Text = 'Downloading the new version. On a slow connection this can take a minute or two. ' +
        'Please leave this window open - it is working.'
    $ui.BusyOverlay.Visibility = 'Visible'

    # Script scope: the timer's handler runs in its own scope, and StrictMode stops on anything it cannot see.
    $script:DRInstallTimer = New-Object Windows.Threading.DispatcherTimer
    $script:DRInstallTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:DRInstallTimer.Add_Tick({
        if (-not $script:DRInstallAsync.IsCompleted) { return }
        $script:DRInstallTimer.Stop()
        $result = $null
        try {
            $result = @($script:DRInstallPs.EndInvoke($script:DRInstallAsync)) | Select-Object -Last 1
        } catch {
            $result = [pscustomobject]@{ Success = $false; Message = "The update could not be installed: $($_.Exception.Message)" }
        }
        try {
            $script:DRInstallPs.Dispose()
            $script:DRInstallRunspace.Close()
            $script:DRInstallRunspace.Dispose()
        } catch { }
        $ui.BusyOverlay.Visibility = 'Collapsed'
        $ui.OverlayProgress.IsIndeterminate = $false
        $ui.OverlayPercent.Visibility = 'Visible'

        Complete-DRUpdateInstall $result

        $script:DRUpdateRunning = $false
        $ui.CheckUpdatesButton.IsEnabled = $true
        $ui.CheckUpdatesButton.Content = 'Update this program'
    })
    $script:DRInstallTimer.Start()
    return $true
}

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
        if (Start-DRUpdateInstall -Manifest $check.Manifest) {
            # Finishes in the timer; the finally below must not re-enable the button yet.
            $script:DRUpdateRunning = $true
            return
        }
        # The background could not be started - install the old way rather
        # than not at all. The window may stall while it downloads.
        Complete-DRUpdateInstall (Install-DRUpdate -Manifest $check.Manifest)
    }
    catch {
        [Windows.MessageBox]::Show("Could not check for updates: $($_.Exception.Message)",
            'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
    }
    finally {
        if (-not $script:DRUpdateRunning) {
            $ui.CheckUpdatesButton.IsEnabled = $true
            $ui.CheckUpdatesButton.Content = 'Update this program'
        }
    }
})

$ui.OpenReportsButton.Add_Click({ $path=Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner\Reports'; New-Item -Path $path -ItemType Directory -Force|Out-Null; Start-Process -FilePath explorer.exe -ArgumentList @($path) })
$ui.ClearHistoryButton.Add_Click({
    $localAppData = $env:LOCALAPPDATA
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
Update-DRDiskWarning
$ui.DiskWarning.Add_MouseLeftButtonUp({ Show-DRDiskWarningInfo })
$ui.DiskWarningMore.Add_MouseLeftButtonUp({ param($sender, $e) $e.Handled = $true; Show-DRDiskWarningInfo })
$window.Add_Closed({ Stop-DRRestartCountdown; $pollTimer.Stop(); if ($script:activePowerShell) { try { $script:activePowerShell.Stop() } catch {}; Stop-EngineCall } })

if ($NoShow) {
    # Some tasks are ticked by default; start the one-item test from nothing ticked.
    foreach ($key in @($selection.Keys)) { $selection[$key] = $false }
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
    $checkCard = @($ui.TaskList.Children | Where-Object { $_ -is [Windows.Controls.Border] -and $_.Child.Children[0] -is [Windows.Controls.StackPanel] -and [string]$_.Child.Children[0].Children[0].CommandParameter -eq 'ai.check' }) | Select-Object -First 1
    if (-not $checkCard) { throw 'GUI smoke test: the "What AI is on this PC?" row is missing.' }
    $checkCard.Child.Children[0].Children[0].IsChecked = $true
    if (-not @($checkCard.Child.Children[1].Children | Where-Object { $_.Tag -eq 'AICheckResults' }).Count) { throw 'GUI smoke test: "Check now" showed no results.' }
    if ($selection['ai.check']) { throw 'GUI smoke test: "Check now" was added to the plan.' }
    # The search box narrows the list to the Copilot rows and brings everything back when cleared.
    $allRows = @($ui.TaskList.Children).Count
    $ui.AISearchText.Text = 'copilot'
    $found = @($ui.TaskList.Children).Count
    if ($found -lt 1) { throw "GUI smoke test: the AI search showed $found rows for copilot." }
    $ui.AISearchText.Text = 'zzzz-no-such-ai'
    if (@($ui.TaskList.Children).Count) { throw 'GUI smoke test: the AI search showed rows for text that matches nothing.' }
    $ui.AISearchText.Text = ''
    Set-DRUiMode -Simple $true
    if ($ui.NavSpeed.Visibility -ne 'Collapsed' -or $ui.DashOtherGrid.Visibility -ne 'Collapsed' -or $ui.NavCleanup.Visibility -ne 'Visible') { throw 'GUI smoke test: Simple mode did not hide the extra tools.' }
    Set-DRUiMode -Simple $false
    if ($ui.NavSpeed.Visibility -ne 'Visible' -or $ui.DashOtherGrid.Visibility -ne 'Visible') { throw 'GUI smoke test: Full mode did not show every tool.' }
    if (-not $ui.SoundSwitch -or $ui.SoundSwitch.IsChecked -ne $script:DRSoundOn) { throw 'GUI smoke test: the Sound switch is missing or out of step.' }
    if (@($ui.TaskList.Children).Count -ne $allRows) { throw 'GUI smoke test: clearing the AI search did not bring the rows back.' }
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
        # Windows' installed-programs list shows the same version as the app
        if ($newest -ge [version]'0.0.1') { Set-DRInstalledProductVersion -Product 'Cleaner' -Version "$newest" }
    } catch { }
    Apply-CleanupPreset -Preset 'Safe'
    Set-DRDefaultTicks
    # Ask once a day, quietly, so a waiting update is visible on the button
    # rather than only to someone who thinks to go looking for it.
    # DRDirect can flag or fully block a PC. Checked against the signed feed; a
    # dead network or an unsigned list never flags or blocks anyone.
    function Get-DRBlockRefCode {
        try {
            $pcId = @(Get-DRThisPcBlockIds)[-1]
            $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($pcId))
            $hex = ($hash | ForEach-Object { $_.ToString('X2') }) -join ''
            return $hex.Substring(0, 4) + '-' + $hex.Substring(4, 4)
        } catch { return '' }
    }
    $blockedHard = $false
    try { $blockedHard = Test-DRPcBlockedHard } catch { }
    if ($blockedHard) {
        # Blocked completely: the Cleaner refuses to open at all.
        $refLine = $(if ($rc = Get-DRBlockRefCode) { [Environment]::NewLine + [Environment]::NewLine + 'Reference code: ' + $rc } else { '' })
        [Windows.MessageBox]::Show('This copy of DRDirect PC Cleaner has been blocked. Please contact your software provider.' + $refLine,
            'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Stop) | Out-Null
        exit 0
    }
    $blockedHere = $false
    try { $blockedHere = Test-DRPcBlocked } catch { }
    if ($blockedHere) {
        # A flagged PC sees a notice every time the Cleaner starts, and keeps
        # working, until it is taken off the list.
        $refLine = $(if ($rc = Get-DRBlockRefCode) { [Environment]::NewLine + [Environment]::NewLine + 'Reference code: ' + $rc } else { '' })
        [Windows.MessageBox]::Show('This copy of DRDirect PC Cleaner needs attention. Please contact your software provider.' + $refLine,
            'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning) | Out-Null
    }
    try { Start-DRQuietUpdateCheck } catch { }
    try { Start-DRHealthCheck } catch { }
    try { Set-DRLastCleanCard } catch { }
    try { Set-DRScanLines } catch { }
    try { Set-DRLevelDates } catch { }
    # Open tall enough that the start card and the three status cards show without scrolling,
    # but never taller than the screen.
    try {
        $work = [System.Windows.SystemParameters]::WorkArea
        if ($window.Height -gt ($work.Height - 20)) { $window.Height = [Math]::Max($window.MinHeight, $work.Height - 20) }
        $window.Top = $work.Top + [Math]::Max(0, ($work.Height - $window.Height) / 2)
    } catch { }
    # If the last clean asked for a restart and Windows has not restarted since, say so when the Cleaner opens.
    $script:DRRestartReminderShown = $false
    $window.Add_ContentRendered({
        if ($script:DRRestartReminderShown -or $TestMode) { return }
        $script:DRRestartReminderShown = $true
        try {
            $owed = [string](Get-ItemProperty -LiteralPath $script:DR3DKey -Name 'RestartOwedSince' -ErrorAction Stop).RestartOwedSince
            $since = [datetime]::Parse($owed, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            $booted = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
            if ($booted -gt $since) {
                Remove-ItemProperty -LiteralPath $script:DR3DKey -Name 'RestartOwedSince' -ErrorAction SilentlyContinue
                Remove-ItemProperty -LiteralPath $script:DR3DKey -Name 'RestartLastReminded' -ErrorAction SilentlyContinue
                return
            }
            # Said No recently? Then stay quiet; the reminder comes back after 2 days.
            if (-not (Test-DRRestartReminderDue -RegistryKey $script:DR3DKey)) { return }
            # The person chooses. No is the default answer, so pressing Enter or Space never restarts the PC
            # by accident: only an explicit click on Yes does, and even then Windows waits 30 seconds first.
            $answer = [Windows.MessageBox]::Show("Reminder: this PC has not been restarted since the last clean, and Windows may still be finishing the changes.`n`nRestart now? Save your open work first.`n`nChoose No to restart later yourself. Nothing restarts unless you choose Yes.",
                'DRDirect PC Cleaner', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question, [Windows.MessageBoxResult]::No)
            if ($answer -ne [Windows.MessageBoxResult]::Yes) {
                # No: ask again in 2 days, and every 2 days after that until the PC has been restarted.
                try { Set-ItemProperty -LiteralPath $script:DR3DKey -Name 'RestartLastReminded' -Value ((Get-Date).ToString('o')) -Type String } catch { }
            }
            if ($answer -eq [Windows.MessageBoxResult]::Yes) {
                try { Invoke-DRDirectRestartNow -DelaySeconds 30 }
                catch { [void][Windows.MessageBox]::Show("The PC could not be restarted from here: $($_.Exception.Message)`n`nRestart it yourself when you are ready.", 'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning) }
            }
        } catch { }
    })
    # A family joke on one PC only (see Show-DRBebeSurprise); every other PC skips straight past it.
    Show-DRBebeSurprise
    [void]$window.ShowDialog()
}
