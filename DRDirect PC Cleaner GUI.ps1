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
                    <Button x:Name="NavDashboard" Style="{StaticResource NavButton}" Foreground="#FFE600" Tag="Active"><Grid HorizontalAlignment="Stretch"><TextBlock Text="⌂   Dashboard" VerticalAlignment="Center" HorizontalAlignment="Left" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/><Viewbox Width="46" Height="46" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,-10,0,-10" IsHitTestVisible="False"><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="DbChrome" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FFFFFF" Offset="0"/><GradientStop Color="#A9B8CF" Offset="0.2"/><GradientStop Color="#4A5A73" Offset="0.45"/><GradientStop Color="#E8EEF8" Offset="0.65"/><GradientStop Color="#6B7A92" Offset="0.85"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush><RadialGradientBrush x:Key="DbOrb" GradientOrigin="0.32,0.25" Center="0.4,0.4" RadiusX="0.75" RadiusY="0.75"><GradientStop Color="#E4F3FF" Offset="0"/><GradientStop Color="#6FAEFF" Offset="0.25"/><GradientStop Color="#1F5FE0" Offset="0.65"/><GradientStop Color="#061F66" Offset="1"/></RadialGradientBrush><LinearGradientBrush x:Key="DbGold" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF4B8" Offset="0"/><GradientStop Color="#F2B91C" Offset="0.45"/><GradientStop Color="#9A6000" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="DbGloss" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#E6FFFFFF" Offset="0"/><GradientStop Color="#1AFFFFFF" Offset="0.6"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="7" ShadowDepth="4" Direction="270" Opacity="0.6"/></Canvas.Effect><Ellipse Canvas.Left="5" Canvas.Top="9" Width="54" Height="54" Fill="#2A3548"/><Ellipse Canvas.Left="5" Canvas.Top="5" Width="54" Height="54" Fill="{StaticResource DbChrome}"/><Ellipse Canvas.Left="10" Canvas.Top="10" Width="44" Height="44" Fill="{StaticResource DbOrb}" Stroke="#8FE6FF" StrokeThickness="1"/><Path Data="M32,15 L14,31 h5 v14 h10 v-9 h6 v9 h10 v-14 h5 z" Fill="#7A4A00"><Path.RenderTransform><TranslateTransform Y="3"/></Path.RenderTransform></Path><Path Data="M32,15 L14,31 h5 v14 h10 v-9 h6 v9 h10 v-14 h5 z" Fill="{StaticResource DbGold}" Stroke="#FFF6B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Path Data="M32,15 L14,31 h8 l10,-9 l10,9 h8 z" Fill="{StaticResource DbGloss}" Opacity="0.7"/><Ellipse Canvas.Left="11" Canvas.Top="11" Width="26" Height="12" Fill="{StaticResource DbGloss}"><Ellipse.RenderTransform><RotateTransform Angle="-25" CenterX="13" CenterY="6"/></Ellipse.RenderTransform></Ellipse></Canvas></Viewbox></Grid></Button>
                    <Button x:Name="NavModeToggle" Style="{StaticResource HeroGreenButton}" Margin="10,4,10,10" Padding="14,11" FontSize="15" FontWeight="Bold" ToolTip="Switch between the simple view and every tool"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFC04D" Offset="0"/><GradientStop Color="#F08200" Offset="1"/></LinearGradientBrush></Button.Background><Grid HorizontalAlignment="Stretch"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="NavModeText" Text="＋  Show all tools" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/><Viewbox Grid.Column="1" Width="46" Height="46" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="4,-12,4,-12" IsHitTestVisible="False"><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="MtBlue" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#DDF0FF" Offset="0"/><GradientStop Color="#6FAEFF" Offset="0.2"/><GradientStop Color="#1F5FE0" Offset="0.55"/><GradientStop Color="#0B3AA8" Offset="0.8"/><GradientStop Color="#4F8CF0" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="MtGold" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF4B8" Offset="0"/><GradientStop Color="#F2B91C" Offset="0.45"/><GradientStop Color="#9A6000" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect Color="#3A1A00" BlurRadius="7" ShadowDepth="4" Direction="270" Opacity="0.65"/></Canvas.Effect><Path Canvas.Left="4" Canvas.Top="7.7" Data="M28,4 h8 l2,6 l5,2 l6,-3 l6,6 l-3,6 l2,5 l6,2 v8 l-6,2 l-2,5 l3,6 l-6,6 l-6,-3 l-5,2 l-2,6 h-8 l-2,-6 l-5,-2 l-6,3 l-6,-6 l3,-6 l-2,-5 l-6,-2 v-8 l6,-2 l2,-5 l-3,-6 l6,-6 l6,3 l5,-2 z" Fill="#05215E"><Path.RenderTransform><ScaleTransform ScaleX="0.62" ScaleY="0.62"/></Path.RenderTransform></Path><Path Canvas.Left="4" Canvas.Top="4" Data="M28,4 h8 l2,6 l5,2 l6,-3 l6,6 l-3,6 l2,5 l6,2 v8 l-6,2 l-2,5 l3,6 l-6,6 l-6,-3 l-5,2 l-2,6 h-8 l-2,-6 l-5,-2 l-6,3 l-6,-6 l3,-6 l-2,-5 l-6,-2 v-8 l6,-2 l2,-5 l-3,-6 l6,-6 l6,3 l5,-2 z" Fill="{StaticResource MtBlue}" Stroke="#CFF3FF" StrokeThickness="2.5" StrokeLineJoin="Round"><Path.RenderTransform><ScaleTransform ScaleX="0.62" ScaleY="0.62"/></Path.RenderTransform></Path><Ellipse Canvas.Left="16.4" Canvas.Top="16.4" Width="14.9" Height="14.9" Fill="#0A2E8A" Stroke="#7FEBFF" StrokeThickness="1.3"/><Path Canvas.Left="26" Canvas.Top="27.7" Data="M28,4 h8 l2,6 l5,2 l6,-3 l6,6 l-3,6 l2,5 l6,2 v8 l-6,2 l-2,5 l3,6 l-6,6 l-6,-3 l-5,2 l-2,6 h-8 l-2,-6 l-5,-2 l-6,3 l-6,-6 l3,-6 l-2,-5 l-6,-2 v-8 l6,-2 l2,-5 l-3,-6 l6,-6 l6,3 l5,-2 z" Fill="#7A4A00"><Path.RenderTransform><ScaleTransform ScaleX="0.62" ScaleY="0.62"/></Path.RenderTransform></Path><Path Canvas.Left="26" Canvas.Top="24" Data="M28,4 h8 l2,6 l5,2 l6,-3 l6,6 l-3,6 l2,5 l6,2 v8 l-6,2 l-2,5 l3,6 l-6,6 l-6,-3 l-5,2 l-2,6 h-8 l-2,-6 l-5,-2 l-6,3 l-6,-6 l3,-6 l-2,-5 l-6,-2 v-8 l6,-2 l2,-5 l-3,-6 l6,-6 l6,3 l5,-2 z" Fill="{StaticResource MtGold}" Stroke="#FFF6B8" StrokeThickness="2.5" StrokeLineJoin="Round"><Path.RenderTransform><ScaleTransform ScaleX="0.62" ScaleY="0.62"/></Path.RenderTransform></Path><Ellipse Canvas.Left="38.4" Canvas.Top="36.4" Width="14.9" Height="14.9" Fill="#7A4A00" Stroke="#FFF6B8" StrokeThickness="1.3"/></Canvas></Viewbox></Grid></Button>
                    <Button x:Name="NavProgress" Style="{StaticResource NavButton}" Content="◐   Maintenance progress" Visibility="Collapsed"/>
                    <TextBlock x:Name="NavHeadClean" Text="CLEAN" Foreground="#FFFF33" FontSize="12.5" FontWeight="ExtraBold" Margin="20,16,0,4"/>
                    <Button x:Name="NavCleanup" Style="{StaticResource NavButton}" Foreground="#FFE600"><Grid HorizontalAlignment="Stretch"><StackPanel Orientation="Vertical" VerticalAlignment="Center"><TextBlock VerticalAlignment="Center" Text="✦   Clean my PC" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/><TextBlock HorizontalAlignment="Left" Text="(3 choices)" FontSize="12" FontWeight="ExtraBold" Foreground="#DFF4FF" Margin="30,1,0,0"><TextBlock.Effect><DropShadowEffect Color="#00B3FF" Direction="315" ShadowDepth="2.5" BlurRadius="3" Opacity="1"/></TextBlock.Effect></TextBlock></StackPanel><Viewbox Width="46" Height="46" Margin="0,-10,0,-10" HorizontalAlignment="Right" VerticalAlignment="Center" IsHitTestVisible="False"><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="BrH" MappingMode="Absolute" StartPoint="27,0" EndPoint="37,0"><GradientStop Color="#B8DBFF" Offset="0"/><GradientStop Color="#3F7FF0" Offset="0.3"/><GradientStop Color="#0B3AA8" Offset="0.65"/><GradientStop Color="#05215E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrHay" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF3C4" Offset="0"/><GradientStop Color="#F0D58A" Offset="0.5"/><GradientStop Color="#C99A3E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrChrome" MappingMode="Absolute" StartPoint="21,0" EndPoint="43,0"><GradientStop Color="#6B7A92" Offset="0"/><GradientStop Color="#FFFFFF" Offset="0.25"/><GradientStop Color="#B9C6DA" Offset="0.5"/><GradientStop Color="#4A5A73" Offset="0.8"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="5" Direction="270" Opacity="0.65"/></Canvas.Effect><Canvas><Canvas.RenderTransform><RotateTransform Angle="35" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="#05215E" StrokeThickness="11" StrokeStartLineCap="Round"/><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="{StaticResource BrH}" StrokeThickness="8" StrokeStartLineCap="Round"/><Line X1="29.6" Y1="5" X2="29.6" Y2="35" Stroke="#CCFFFFFF" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="30" Canvas.Top="3.6" Width="4" Height="4" Fill="#E6FFFFFF"/><Polygon Points="22,45.0 42,45.0 49,63.0 46,65.0 43,63.0 40,66.0 37,63.0 34,66.0 31,63.0 28,66.0 25,63.0 22,66.0 19,63.0 16,65.0 15,63.0" Fill="#5A3A0E" StrokeLineJoin="Round"/><Polygon Points="22,42 42,42 49,60 46,62 43,60 40,63 37,60 34,63 31,60 28,63 25,60 22,63 19,60 16,62 15,60" Fill="{StaticResource BrHay}" Stroke="#FFF1B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Line X1="24" Y1="44" X2="19" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="27" Y1="44" X2="23" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="30" Y1="44" X2="28" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="33" Y1="44" X2="33" Y2="61" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="36" Y1="44" X2="38" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="39" Y1="44" X2="43" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="41" Y1="44" X2="46" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Rectangle Canvas.Left="21" Canvas.Top="39" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="#2A3548"/><Rectangle Canvas.Left="21" Canvas.Top="35" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="{StaticResource BrChrome}" Stroke="#FFFFFF" StrokeThickness="1.2"/><Line X1="22" Y1="38.5" X2="42" Y2="38.5" Stroke="#664A5A73" StrokeThickness="1"/><Line X1="22" Y1="41.5" X2="42" Y2="41.5" Stroke="#664A5A73" StrokeThickness="1"/><Rectangle Canvas.Left="23" Canvas.Top="36" Width="18" Height="2.4" RadiusX="1.2" RadiusY="1.2" Fill="#E6FFFFFF"/></Canvas><Canvas x:Name="NavCleanDust" Visibility="Collapsed"><Ellipse Canvas.Left="-4" Canvas.Top="52" Width="14" Height="14" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.0"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-8" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="4" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.4"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.4"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-4" Duration="0:0:1.4"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.84"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.4"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="10" Canvas.Top="50" Width="16" Height="16" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.8"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.8"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="4" Duration="0:0:1.8"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.08"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.8"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-8" Canvas.Top="48" Width="10" Height="10" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.1"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-12" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="14" Canvas.Top="56" Width="12" Height="12" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.2"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.9"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="8" Duration="0:0:1.9"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.14"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.9"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="2" Canvas.Top="58" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.9"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.3"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="0" Duration="0:0:1.3"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.78"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.3"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-6" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.3"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.5"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-10" Duration="0:0:1.5"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.9"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.5"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="12" Canvas.Top="46" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.55"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.7"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="6" Duration="0:0:1.7"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.02"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.7"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="6" Canvas.Top="50" Width="13" Height="13" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.5"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-6" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse></Canvas></Canvas></Viewbox></Grid></Button>
                    <Button x:Name="NavSpeed" Style="{StaticResource NavButton}" Foreground="#FFE600" Content="◈   Speed and space"/>
                    <Button x:Name="NavDuplicates" Style="{StaticResource NavButton}" Foreground="#22C16F" FontWeight="Bold" Content="⧉   Find duplicate files"/>
                    <Button x:Name="NavHibernate" Style="{StaticResource NavButton}" Foreground="#22D3EE" FontWeight="SemiBold" Content="☾   Hibernate" ToolTip="Turn Hibernate off to free several GB, or back on"/>
                    <Button x:Name="NavUninstaller" Style="{StaticResource GreenNavButton}" Margin="10,4,10,4" Padding="12,8" FontSize="13" ToolTip="Open the DRDirect Uninstaller Program to remove programs you no longer want"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="⌫" Foreground="White" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock Grid.Column="1" Text="DRDirect Uninstaller Program" Foreground="White" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></Grid></Button>
                    <TextBlock x:Name="NavHeadFix" Text="FIX &amp; PROTECT" Foreground="#FFFF33" FontSize="12.5" FontWeight="ExtraBold" Margin="20,16,0,4"/>
                    <Button x:Name="NavRepair" Style="{StaticResource NavButton}" Foreground="#FFE600"><Grid HorizontalAlignment="Stretch"><TextBlock Text="⚒   Fix Windows" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/><Viewbox Width="46" Height="46" Margin="0,-10,0,-10" HorizontalAlignment="Right" VerticalAlignment="Center" IsHitTestVisible="False"><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="FxSteelH" MappingMode="Absolute" StartPoint="27,0" EndPoint="37,0"><GradientStop Color="#8A97AB" Offset="0"/><GradientStop Color="#F4F8FF" Offset="0.3"/><GradientStop Color="#B9C6DA" Offset="0.55"/><GradientStop Color="#6D7B92" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="FxSteel" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#F4F8FF" Offset="0"/><GradientStop Color="#B9C6DA" Offset="0.5"/><GradientStop Color="#6D7B92" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="FxGold" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF4B8" Offset="0"/><GradientStop Color="#F2B91C" Offset="0.45"/><GradientStop Color="#9A6000" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="7" ShadowDepth="4" Direction="270" Opacity="0.6"/></Canvas.Effect><Canvas><Canvas.RenderTransform><RotateTransform Angle="-42" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Rectangle Canvas.Left="27" Canvas.Top="32" Width="10" Height="26" RadiusX="5" RadiusY="5" Fill="#7A4A00"/><Rectangle Canvas.Left="27" Canvas.Top="30" Width="10" Height="26" RadiusX="5" RadiusY="5" Fill="{StaticResource FxGold}" Stroke="#FFF6B8" StrokeThickness="1"/><Line X1="29.5" Y1="34" X2="29.5" Y2="52" Stroke="#B3FFFFFF" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Rectangle Canvas.Left="30.5" Canvas.Top="8" Width="3" Height="23" Fill="{StaticResource FxSteel}" Stroke="#6D7B92" StrokeThickness="0.6"/><Polygon Points="29.5,8 34.5,8 33.5,4 30.5,4" Fill="#B9C6DA" Stroke="#6D7B92" StrokeThickness="0.6"/></Canvas><Canvas><Canvas.RenderTransform><RotateTransform Angle="42" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Line X1="32" Y1="26" X2="32" Y2="58" Stroke="#05215E" StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Line X1="32" Y1="26" X2="32" Y2="58" Stroke="{StaticResource FxSteelH}" StrokeThickness="8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Line X1="29.5" Y1="28" X2="29.5" Y2="56" Stroke="#CCFFFFFF" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="19.5" Canvas.Top="6.5" Width="25" Height="25" Fill="#05215E"/><Ellipse Canvas.Left="19.5" Canvas.Top="4.5" Width="25" Height="25" Fill="{StaticResource FxSteel}" Stroke="White" StrokeThickness="1"/><Rectangle Canvas.Left="27" Canvas.Top="3" Width="10" Height="12" Fill="#0A2E8A" Stroke="#05215E" StrokeThickness="1"/><Line X1="27.8" Y1="3" X2="27.8" Y2="14.5" Stroke="#9FC2F0" StrokeThickness="1"/><Path Data="M21,12 A12,12 0 0 1 29,5" Stroke="#E6FFFFFF" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Canvas></Canvas></Viewbox></Grid></Button>
                    <Button x:Name="NavSecurity" Style="{StaticResource NavButton}" Foreground="#FFE600"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Viewbox Width="30" Height="30" Margin="-4,-6,10,-6"><Canvas Width="48" Height="48"><Canvas.Effect><DropShadowEffect ShadowDepth="2" Direction="270" BlurRadius="3" Opacity="0.55"/></Canvas.Effect><Path Data="M24,4 L40,10 L40,24 C40,33 33,40 24,44 C15,40 8,33 8,24 L8,10 Z" Stroke="#8A4B00" StrokeThickness="1"><Path.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF59A" Offset="0"/><GradientStop Color="#FFD21F" Offset="0.45"/><GradientStop Color="#E58A00" Offset="1"/></LinearGradientBrush></Path.Fill></Path><Path Data="M24,9 L35,13 L35,24 C35,30.5 30.5,35.5 24,39 C17.5,35.5 13,30.5 13,24 L13,13 Z"><Path.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#3A64A0" Offset="0"/><GradientStop Color="#0E2144" Offset="1"/></LinearGradientBrush></Path.Fill></Path><Path Data="M19.5,23 L19.5,20 A4.5,4.5 0 0 1 28.5,20 L28.5,23" Stroke="#C9D3E3" StrokeThickness="3" Fill="Transparent"/><Rectangle Canvas.Left="16.5" Canvas.Top="22.5" Width="15" Height="12" RadiusX="3" RadiusY="3" Stroke="#8A4B00" StrokeThickness="0.8"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF59A" Offset="0"/><GradientStop Color="#FFD21F" Offset="0.45"/><GradientStop Color="#E58A00" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle><Ellipse Canvas.Left="22.3" Canvas.Top="26.3" Width="3.4" Height="3.4" Fill="#5A3300"/><Path Data="M24,9 L13,13 L13,22 C18,20 24,19 35,17 L35,13 Z" Opacity="0.5"><Path.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#E6FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Path.Fill></Path></Canvas></Viewbox><TextBlock Grid.Column="1" TextWrapping="Wrap" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"><Run Text="Check my "/><Run Text="security and privacy" Foreground="#00FF2E" FontWeight="ExtraBold"/></TextBlock></Grid></Button>
                    <Button x:Name="NavFullScan" Style="{StaticResource NavButton}" Foreground="#FFE600" Content="⛨   Full scan only" ToolTip="Runs one Microsoft Defender full scan and nothing else. It can take a long time."/>
                    <Button x:Name="NavSmartApp" Style="{StaticResource NavButton}" Foreground="#FFE600" Content="⛨   Smart App Control" ToolTip="Opens the Windows page where Smart App Control is switched on or off. The Cleaner changes nothing itself."/>
                    <Button x:Name="NavAI" Style="{StaticResource AINavButton}" Margin="10,4,10,4" ToolTip="Switch off AI in Windows and web browsers"><Grid HorizontalAlignment="Stretch"><StackPanel Orientation="Vertical" VerticalAlignment="Center" HorizontalAlignment="Left"><TextBlock Text="⊘   Switch On or Off AI" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/><TextBlock HorizontalAlignment="Center" Text="(you choose)" FontSize="12" FontWeight="ExtraBold" Foreground="#DFF4FF" Margin="0,1,0,0"><TextBlock.Effect><DropShadowEffect Color="#00B3FF" Direction="315" ShadowDepth="2.5" BlurRadius="3" Opacity="1"/></TextBlock.Effect></TextBlock></StackPanel><Viewbox Width="46" Height="46" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,-10,0,-10" IsHitTestVisible="False"><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="RbBlue" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#B8DBFF" Offset="0"/><GradientStop Color="#5B9BFF" Offset="0.25"/><GradientStop Color="#1F5FE0" Offset="0.6"/><GradientStop Color="#0B3AA8" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="RbCyan" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#E0FFFF" Offset="0"/><GradientStop Color="#22D3EE" Offset="0.5"/><GradientStop Color="#0A7FA8" Offset="1"/></LinearGradientBrush><RadialGradientBrush x:Key="RbGold" GradientOrigin="0.3,0.25"><GradientStop Color="#FFFBD0" Offset="0"/><GradientStop Color="#FFD400" Offset="0.4"/><GradientStop Color="#C97800" Offset="1"/></RadialGradientBrush><LinearGradientBrush x:Key="RbShine" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#D9FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="7" ShadowDepth="4" Direction="270" Opacity="0.55"/></Canvas.Effect><Line X1="32" Y1="9" X2="32" Y2="4" Stroke="{StaticResource RbCyan}" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="28.5" Canvas.Top="0.5" Width="7" Height="7" Fill="{StaticResource RbGold}" Stroke="White" StrokeThickness="0.8"/><Line X1="19" Y1="38" X2="10" Y2="46" Stroke="#05215E" StrokeThickness="8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Line X1="19" Y1="38" X2="10" Y2="46" Stroke="{StaticResource RbCyan}" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Line X1="45" Y1="38" X2="55" Y2="26" Stroke="#05215E" StrokeThickness="8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Line X1="45" Y1="38" X2="55" Y2="26" Stroke="{StaticResource RbCyan}" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Line X1="26" Y1="54" X2="26" Y2="59" Stroke="{StaticResource RbCyan}" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Line X1="38" Y1="54" X2="38" Y2="59" Stroke="{StaticResource RbCyan}" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Rectangle Canvas.Left="19" Canvas.Top="37" Width="26" Height="21" RadiusX="7" RadiusY="7" Fill="#05215E"/><Rectangle Canvas.Left="19" Canvas.Top="33" Width="26" Height="21" RadiusX="7" RadiusY="7" Fill="{StaticResource RbBlue}" Stroke="#C9F3FF" StrokeThickness="1.8"/><Ellipse Canvas.Left="27" Canvas.Top="38" Width="10" Height="10" Fill="{StaticResource RbGold}" Stroke="White" StrokeThickness="1"/><Rectangle Canvas.Left="18" Canvas.Top="13" Width="28" Height="21" RadiusX="8" RadiusY="8" Fill="#05215E"/><Rectangle Canvas.Left="18" Canvas.Top="9" Width="28" Height="21" RadiusX="8" RadiusY="8" Fill="{StaticResource RbBlue}" Stroke="#C9F3FF" StrokeThickness="1.8"/><Rectangle Canvas.Left="21" Canvas.Top="11" Width="22" Height="7" RadiusX="3.5" RadiusY="3.5" Fill="{StaticResource RbShine}"/><Ellipse Canvas.Left="22.6" Canvas.Top="18.6" Width="6.8" Height="6.8" Fill="{StaticResource RbGold}"/><Ellipse Canvas.Left="34.6" Canvas.Top="18.6" Width="6.8" Height="6.8" Fill="{StaticResource RbGold}"/><Line X1="6" Y1="59" X2="58" Y2="6" Stroke="#8C000000" StrokeThickness="9" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Line X1="6" Y1="59" X2="58" Y2="6" Stroke="#FF3B3B" StrokeThickness="5.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Line X1="7" Y1="56" X2="56" Y2="7" Stroke="#FFB0B0" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Canvas></Viewbox></Grid></Button>
                    <TextBlock x:Name="NavHeadCheck" Text="CHECK" Foreground="#FFFF33" FontSize="12.5" FontWeight="ExtraBold" Margin="20,16,0,4"/>
                    <Button x:Name="NavHealth" Style="{StaticResource NavButton}" Foreground="#FACC15" Content="▰   Check my drives"/>
                    <Button x:Name="NavMemory" Style="{StaticResource NavButton}" Foreground="#FACC15" Content="▦   Check my RAM"/>
                    <Button x:Name="NavPowerHeat" Style="{StaticResource NavButton}" Foreground="#FACC15" Content="⚡   Check power and heat" ToolTip="Looks for signs of a failing power supply, dust or a PC that runs too hot"/>
                    <Button x:Name="NavHardware" Style="{StaticResource NavButton}" Content="▤   About my PC"/>
                    <Button x:Name="NavHistory" Style="{StaticResource NavButton}" Foreground="#22D3EE" FontWeight="SemiBold" ToolTip="See what the Cleaner did, open the reports, and undo changes to settings"><Grid HorizontalAlignment="Stretch"><TextBlock Text="◷   Cleaning history" VerticalAlignment="Center" HorizontalAlignment="Left" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/><Viewbox Width="46" Height="46" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,-10,0,-10" IsHitTestVisible="False"><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="HsBlue" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#DDF0FF" Offset="0"/><GradientStop Color="#6FAEFF" Offset="0.2"/><GradientStop Color="#1F5FE0" Offset="0.55"/><GradientStop Color="#0B3AA8" Offset="0.85"/><GradientStop Color="#4F8CF0" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="HsGold" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF4B8" Offset="0"/><GradientStop Color="#F2B91C" Offset="0.45"/><GradientStop Color="#9A6000" Offset="1"/></LinearGradientBrush><RadialGradientBrush x:Key="HsDial" GradientOrigin="0.4,0.3"><GradientStop Color="#FFFFFF" Offset="0"/><GradientStop Color="#DCEBFF" Offset="0.7"/><GradientStop Color="#9CBDEB" Offset="1"/></RadialGradientBrush><LinearGradientBrush x:Key="HsGloss" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#F2FFFFFF" Offset="0"/><GradientStop Color="#1FFFFFFF" Offset="0.6"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="7" ShadowDepth="4" Direction="270" Opacity="0.6"/></Canvas.Effect><Ellipse Canvas.Left="13" Canvas.Top="16" Width="38" Height="38" Fill="#05215E"/><Ellipse Canvas.Left="13" Canvas.Top="14" Width="38" Height="38" Fill="{StaticResource HsBlue}" Stroke="#CFF3FF" StrokeThickness="1.4"/><Ellipse Canvas.Left="17" Canvas.Top="18" Width="30" Height="30" Fill="{StaticResource HsDial}" Stroke="#0A2E8A" StrokeThickness="1"/><Line X1="32" Y1="33" X2="32" Y2="23" Stroke="#0B3AA8" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Line X1="32" Y1="33" X2="39" Y2="37" Stroke="#0B3AA8" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="29.4" Canvas.Top="30.4" Width="5.2" Height="5.2" Fill="{StaticResource HsGold}" Stroke="White" StrokeThickness="0.6"/><Path Data="M9,36 A24,24 0 1 1 15,50" Stroke="#7A4A00" StrokeThickness="9" StrokeStartLineCap="Round" StrokeEndLineCap="Round"><Path.RenderTransform><TranslateTransform Y="3"/></Path.RenderTransform></Path><Path Data="M9,36 A24,24 0 1 1 15,50" Stroke="{StaticResource HsGold}" StrokeThickness="7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Path Data="M9,36 A24,24 0 1 1 15,50" Stroke="#FFF9C9" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"><Path.RenderTransform><TranslateTransform X="-1.8" Y="-1.8"/></Path.RenderTransform></Path><Polygon Points="0,32 16,37 11,23" Fill="{StaticResource HsGold}" Stroke="#FFF6B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Path Data="M18,26 A15,15 0 0 1 46,26 C41,22 37,21 32,21 C27,21 23,22 18,26 Z" Fill="{StaticResource HsGloss}"/></Canvas></Viewbox></Grid></Button>
                    <TextBlock x:Name="NavHeadUpdate" Text="UPDATE" Foreground="#FFFF33" FontSize="12.5" FontWeight="ExtraBold" Margin="20,16,0,4"/>
                    <Button x:Name="NavAppUpdates" Style="{StaticResource WingetNavButton}" Content="⭳   Update my apps" Margin="10,4,10,4" ToolTip="Update every app with winget, in a colour PowerShell window"/>
                    <Button x:Name="NavNoteButton" Content="Please read first  :)" Style="{StaticResource HeroGreenButton}" Margin="10,10,10,4" Padding="14,11" FontSize="15" FontWeight="Bold" ToolTip="Click to read a short, friendly note"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5BE584" Offset="0"/><GradientStop Color="#13A64A" Offset="1"/></LinearGradientBrush></Button.Background></Button>
                </StackPanel>
                </ScrollViewer>
                <Border x:Name="ResetReliabilityButton" Height="30" CornerRadius="15" Grid.Row="1" VerticalAlignment="Bottom" Margin="26,0,26,8" HorizontalAlignment="Stretch" BorderBrush="#0A4F8F" BorderThickness="2"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#8FE3FF" Offset="0"/><GradientStop Color="#28B8FF" Offset="0.48"/><GradientStop Color="#0E8CF0" Offset="0.52"/><GradientStop Color="#0560C0" Offset="1"/></LinearGradientBrush></Border.Background><Border.Effect><DropShadowEffect Color="#00B3FF" BlurRadius="16" ShadowDepth="0" Opacity="0.6"/></Border.Effect><Border IsHitTestVisible="False" Height="10" VerticalAlignment="Top" Margin="8,2,8,0" CornerRadius="8"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#D0FFFFFF" Offset="0"/><GradientStop Color="#10FFFFFF" Offset="1"/></LinearGradientBrush></Border.Background></Border></Border>
                <Border x:Name="NavMoreUp" Grid.Row="1" Visibility="Collapsed" VerticalAlignment="Top" HorizontalAlignment="Center" Margin="0,6,0,0" Padding="22,7" CornerRadius="16" Cursor="Hand" ToolTip="Back to the top of the menu"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5B9BFF" Offset="0"/><GradientStop Color="#1F5FE0" Offset="1"/></LinearGradientBrush></Border.Background><Border.Effect><DropShadowEffect Color="#0A1A4A" BlurRadius="10" ShadowDepth="3" Direction="270" Opacity="0.55"/></Border.Effect><TextBlock Text="▲   Back to the top" Foreground="White" FontSize="14" FontWeight="Bold"/></Border>
                <Border x:Name="NavMoreHint" Grid.Row="1" Visibility="Collapsed" VerticalAlignment="Bottom" Height="64" Cursor="Hand" ToolTip="Scroll down for more tools"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0015253D" Offset="0"/><GradientStop Color="#F015253D" Offset="0.62"/><GradientStop Color="#FF15253D" Offset="1"/></LinearGradientBrush></Border.Background><TextBlock Text="▼   More tools below" Foreground="#FFC04D" FontSize="14" FontWeight="ExtraBold" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,8"/></Border>
                <StackPanel Grid.Row="2" Margin="16,14,16,24"><Border x:Name="RunStrip" Visibility="Collapsed" Background="#12306B" BorderBrush="#2E6DEB" BorderThickness="1" CornerRadius="9" Padding="12,10" Margin="0,0,0,12" Cursor="Hand" ToolTip="Click to go to the progress page"><StackPanel><TextBlock x:Name="RunStripTitle" Text="Working..." Foreground="White" FontWeight="SemiBold" FontSize="13"/><TextBlock x:Name="RunStripDetail" Text="" Foreground="#B9C9DD" FontSize="11" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/><TextBlock x:Name="RunStripCleaning" Text="" Visibility="Collapsed" Foreground="#B9C9DD" FontSize="11" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/><TextBlock x:Name="RunStripHint" Text="Click here to see it working" Foreground="#2BE37A" FontSize="11" FontWeight="SemiBold" Margin="0,4,0,6"/><ProgressBar x:Name="RunStripBar" Height="27" Minimum="0" Maximum="100" Value="0" Foreground="#2BE37A" Background="#2A3F66" BorderThickness="0"><ProgressBar.Template><ControlTemplate TargetType="ProgressBar"><Grid><Border CornerRadius="13" BorderBrush="#0A1426" BorderThickness="3"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0B1630" Offset="0"/><GradientStop Color="#22345C" Offset="0.5"/><GradientStop Color="#3A5080" Offset="1"/></LinearGradientBrush></Border.Background></Border><Border x:Name="PART_Track" Margin="3"><Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="10" Background="{TemplateBinding Foreground}"><Grid><Border CornerRadius="10"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#99FFFFFF" Offset="0"/><GradientStop Color="#22FFFFFF" Offset="0.48"/><GradientStop Color="#33000000" Offset="0.52"/><GradientStop Color="#99000000" Offset="1"/></LinearGradientBrush></Border.Background></Border><Border IsHitTestVisible="False" CornerRadius="10"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><LinearGradientBrush.RelativeTransform><TranslateTransform x:Name="ShimmerMove" X="-1"/></LinearGradientBrush.RelativeTransform><GradientStop Color="#00FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="0.38"/><GradientStop Color="#B0FFFFFF" Offset="0.5"/><GradientStop Color="#00FFFFFF" Offset="0.62"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Border.Background></Border></Grid><Border.Effect><DropShadowEffect x:Name="PulseGlow" Color="White" BlurRadius="10" ShadowDepth="0" Opacity="0.45"/></Border.Effect></Border></Border></Grid></ControlTemplate></ProgressBar.Template></ProgressBar></StackPanel></Border><Border x:Name="ActivateWrap" Margin="0,0,0,14" CornerRadius="8" Background="#1E4FA8" BorderBrush="#7FB0FF" BorderThickness="1" Padding="8,10" HorizontalAlignment="Stretch" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform x:Name="ActivateScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform><StackPanel><TextBlock x:Name="TrialCountdown" Text="" HorizontalAlignment="Center" Foreground="#D7E6FF" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,6" Visibility="Collapsed"/><Button x:Name="ActivateButton" Content="&#128273;  Activate this product" HorizontalAlignment="Center" Background="Transparent" BorderThickness="0" Cursor="Hand" Foreground="White" FontSize="14" FontWeight="Bold" Padding="0"/></StackPanel></Border><TextBlock x:Name="AdminStatus" Foreground="#9FB0C9" FontSize="12"/></StackPanel>
            </Grid>
        </Border>

        <Grid Grid.Column="1" Margin="34,26,34,28">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="0,0,0,20"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Orientation="Horizontal"><StackPanel><TextBlock x:Name="PageEyebrow" Text="THIS PC" Style="{StaticResource MutedText}" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="PageTitle" Text="Dashboard" Style="{StaticResource TitleText}"/></StackPanel><Border x:Name="AISearchBox" Visibility="Collapsed" Width="300" Height="40" CornerRadius="20" Background="White" BorderBrush="#7C3AED" BorderThickness="2" Margin="28,8,0,0" VerticalAlignment="Center"><Grid><TextBlock Text="🔍" FontSize="14" Margin="14,0,0,0" VerticalAlignment="Center" HorizontalAlignment="Left" Foreground="#7C3AED"/><TextBlock x:Name="AISearchHint" Text="Search AI items (Copilot, Edge...)" Margin="40,0,12,0" VerticalAlignment="Center" Foreground="#98A2B3" FontSize="13" IsHitTestVisible="False"/><TextBox x:Name="AISearchText" Background="Transparent" BorderThickness="0" Margin="38,0,12,0" VerticalContentAlignment="Center" FontSize="13" Foreground="#101828"/></Grid></Border><Border x:Name="DiskWarning" Visibility="Collapsed" Cursor="Hand" MinWidth="560" CornerRadius="24" Background="#FFF1F2" BorderThickness="3" Padding="20,10" Margin="28,6,0,0" VerticalAlignment="Center"><Border.BorderBrush><SolidColorBrush Color="#E5384A"/></Border.BorderBrush><Border.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><ColorAnimation Storyboard.TargetProperty="BorderBrush.Color" From="#E5384A" To="#1E90FF" Duration="0:0:0.35"/></Storyboard></BeginStoryboard></EventTrigger></Border.Triggers><StackPanel Orientation="Horizontal"><Ellipse Width="28" Height="28" Fill="#E5384A" Stroke="White" StrokeThickness="3" Margin="0,0,8,0" VerticalAlignment="Center"><Ellipse.Effect><DropShadowEffect ShadowDepth="0" BlurRadius="20" Opacity="0.9" Color="#E5384A"/></Ellipse.Effect><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.05" Duration="0:0:0.35"/></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Width="28" Height="28" Fill="#1E90FF" Stroke="White" StrokeThickness="3" Margin="0" VerticalAlignment="Center"><Ellipse.Effect><DropShadowEffect ShadowDepth="0" BlurRadius="20" Opacity="0.9" Color="#1E90FF"/></Ellipse.Effect><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><DoubleAnimation Storyboard.TargetProperty="Opacity" From="0.05" To="1" Duration="0:0:0.35"/></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><StackPanel VerticalAlignment="Center" Margin="16,0,0,0"><TextBlock x:Name="DiskWarningTitle" FontSize="20" FontWeight="ExtraBold" Foreground="#B42318"/></StackPanel><TextBlock x:Name="DiskWarningMore" Text="More info - click here" FontSize="16" FontWeight="SemiBold" Foreground="#1E5BD8" TextDecorations="Underline" Cursor="Hand" VerticalAlignment="Center" Margin="22,0,0,0"/></StackPanel></Border></StackPanel><Border Grid.Column="1" CornerRadius="16" Background="#E7F6EF" Padding="12,7" VerticalAlignment="Center"><TextBlock Text="●  Protected mode" Foreground="{StaticResource Success}" FontSize="12"/></Border></Grid>

            <Grid Grid.Row="1">
                <ScrollViewer x:Name="PageDashboard" VerticalScrollBarVisibility="Auto"><StackPanel>
<Border x:Name="UpdateBanner" Visibility="Collapsed" Background="#12C25B" CornerRadius="12" Padding="20,14" Margin="0,0,0,16"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Orientation="Horizontal" VerticalAlignment="Center"><TextBlock Text="&#10004;" Foreground="White" FontSize="22" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,12,0"/><TextBlock x:Name="UpdateBannerText" Text="There is a new update" Foreground="White" FontSize="18" FontWeight="Bold" VerticalAlignment="Center" TextWrapping="Wrap"/></StackPanel><Button x:Name="UpdateBannerButton" Grid.Column="1" Content="See what is new and update" Style="{StaticResource HeroButton}" Foreground="#0B7A3B" Margin="16,0,0,0"/></Grid></Border>
<Border Style="{StaticResource Card}" Effect="{DynamicResource DR3DShadow}" Padding="34" Margin="0,0,0,18" Background="{StaticResource HeroBrush}" BorderBrush="#2447B8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Border Grid.RowSpan="2" Margin="-34" CornerRadius="14" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}" BorderThickness="3,3,3,9" BorderBrush="#99FFFFFF"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#66FFFFFF" Offset="0"/><GradientStop Color="#14FFFFFF" Offset="0.30"/><GradientStop Color="#00000000" Offset="0.55"/><GradientStop Color="#99000820" Offset="1"/></LinearGradientBrush></Border.Background></Border><StackPanel HorizontalAlignment="Center"><TextBlock Text="START HERE" Effect="{DynamicResource DR3DHeroText}" HorizontalAlignment="Center" Foreground="#FFFF33" FontSize="12.5" FontWeight="ExtraBold"/><Grid HorizontalAlignment="Center" Margin="0,8,6,14"><TextBlock Text="Make my PC cleaner" Foreground="#0A1D78" FontSize="32" FontWeight="ExtraBold" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"><TextBlock.RenderTransform><TranslateTransform X="6" Y="6"/></TextBlock.RenderTransform><TextBlock.Effect><BlurEffect Radius="4"/></TextBlock.Effect></TextBlock><TextBlock Text="Make my PC cleaner" Foreground="#0A1D78" FontSize="32" FontWeight="ExtraBold" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"><TextBlock.RenderTransform><TranslateTransform X="4" Y="4"/></TextBlock.RenderTransform></TextBlock><TextBlock Text="Make my PC cleaner" Foreground="#1A35A8" FontSize="32" FontWeight="ExtraBold" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"><TextBlock.RenderTransform><TranslateTransform X="3" Y="3"/></TextBlock.RenderTransform></TextBlock><TextBlock Text="Make my PC cleaner" Foreground="#2447B8" FontSize="32" FontWeight="ExtraBold" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"><TextBlock.RenderTransform><TranslateTransform X="2" Y="2"/></TextBlock.RenderTransform></TextBlock><TextBlock Text="Make my PC cleaner" Foreground="#3A5FD0" FontSize="32" FontWeight="ExtraBold" IsHitTestVisible="False" Visibility="{DynamicResource DR3DParts}"><TextBlock.RenderTransform><TranslateTransform X="1" Y="1"/></TextBlock.RenderTransform></TextBlock><TextBlock Text="Make my PC cleaner" FontSize="32" FontWeight="ExtraBold"><TextBlock.Foreground><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFFFFF" Offset="0"/><GradientStop Color="#F4F8FF" Offset="0.48"/><GradientStop Color="#BFD4FF" Offset="0.52"/><GradientStop Color="#FFFFFF" Offset="1"/></LinearGradientBrush></TextBlock.Foreground></TextBlock></Grid><TextBlock Text="One click. We only do the safe things, and we ask you before anything starts." Effect="{DynamicResource DR3DHeroText}" Foreground="#C9D9FF" FontSize="16" TextWrapping="Wrap" MaxWidth="560" HorizontalAlignment="Center" TextAlignment="Center"/><WrapPanel Orientation="Horizontal" Margin="0,24,0,0" HorizontalAlignment="Center"><Button x:Name="SafeCleanButton" Content="Make my PC cleaner" Style="{StaticResource HeroGreenButton}" FontSize="15" FontWeight="Bold" Padding="20,9" Margin="0,0,10,10"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5BE584" Offset="0"/><GradientStop Color="#13A64A" Offset="1"/></LinearGradientBrush></Button.Background></Button><Button x:Name="SafePreviewButton" Content="Show me first" Style="{StaticResource HeroGreenButton}" Padding="18,9" Margin="0,0,10,10"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0E5A2D" Offset="0"/><GradientStop Color="#02240F" Offset="1"/></LinearGradientBrush></Button.Background></Button><Button x:Name="HeroUninstallButton" Style="{StaticResource HeroGreenButton}" Margin="0,0,10,10" ToolTip="Open the DRDirect Uninstaller Program to remove programs you no longer want"><StackPanel Orientation="Horizontal"><TextBlock Text="⌫" FontSize="14" Foreground="White" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock Text="DRDirect Uninstaller Program" Foreground="White" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Button></WrapPanel><TextBlock Text="✓  Settings changes can be undone.   ✓  Your files and passwords are never touched." Effect="{DynamicResource DR3DHeroText}" Foreground="White" FontSize="13.5" FontWeight="SemiBold" Margin="0,20,0,0" TextWrapping="Wrap" HorizontalAlignment="Center" TextAlignment="Center"/></StackPanel><Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Grid.Column="0" Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0,10,12,0"><CheckBox x:Name="SoundSwitch" Style="{StaticResource DRSwitch}" Effect="{DynamicResource DR3DHeroText}" Content="Sound" Margin="0,0,14,0" VerticalAlignment="Center" ToolTip="Sounds: a soft chime when a clean finishes, and a small tick when you point at a button"/><CheckBox x:Name="Buttons3DSwitch" Style="{StaticResource DRSwitch}" Effect="{DynamicResource DR3DHeroText}" Content="3D look" Margin="0,0,14,0" VerticalAlignment="Center" ToolTip="Turn the raised 3D look of the Cleaner on or off"/><CheckBox x:Name="Max3DSwitch" Style="{StaticResource DRSwitch}" Effect="{DynamicResource DR3DHeroText}" Content="Max 3D" Margin="0,0,14,0" VerticalAlignment="Center" ToolTip="Even deeper 3D: bigger shadows and thicker raised edges. Turns the 3D look on too."/></StackPanel><Button x:Name="HeroUpdateButton" Content="Check for updates" Style="{StaticResource HeroGreenButton}" Grid.Column="1" Margin="0,10,0,0" HorizontalAlignment="Right" VerticalAlignment="Top" Padding="18,9" ToolTip="Look for a newer version of the Cleaner"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#D2700F" Offset="0"/><GradientStop Color="#8F3800" Offset="1"/></LinearGradientBrush></Button.Background></Button></Grid></Grid></Border>
<UniformGrid Columns="3" Margin="0,0,0,22">
                            <Border x:Name="LastCleanCard" Style="{StaticResource Card}" Margin="0,0,12,0" BorderBrush="{StaticResource Violet}" BorderThickness="5,1,1,1"><Grid><StackPanel><StackPanel Orientation="Horizontal"><Border Style="{StaticResource StatIcon}" Background="{StaticResource VioletSoft}"><TextBlock Text="◷" Foreground="{StaticResource Violet}" FontSize="19" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="LAST CLEAN" Foreground="{StaticResource Violet}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock x:Name="LastCleanValue" Text="Not yet" FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock x:Name="LastCleanHint" Text="Shows here after your first clean" Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap"/><TextBlock x:Name="LastCleanQuickScan" Style="{StaticResource MutedText}" FontSize="12" Margin="0,10,0,0" TextWrapping="Wrap" Visibility="Collapsed"/><TextBlock x:Name="LastCleanFullScan" Style="{StaticResource MutedText}" FontSize="12" Margin="0,2,0,0" TextWrapping="Wrap" Visibility="Collapsed"/></StackPanel><Ellipse x:Name="LastCleanLightBlue" Width="14" Height="14" Fill="#1E90FF" Margin="-12,-12,0,0" HorizontalAlignment="Left" VerticalAlignment="Top" Visibility="Collapsed"><Ellipse.Effect><DropShadowEffect Color="#1E90FF" BlurRadius="14" ShadowDepth="0" Opacity="0.9"/></Ellipse.Effect></Ellipse><Ellipse x:Name="LastCleanLightRed" Width="14" Height="14" Fill="#E02424" Margin="0,-12,-12,0" HorizontalAlignment="Right" VerticalAlignment="Top" Visibility="Collapsed"><Ellipse.Effect><DropShadowEffect Color="#E02424" BlurRadius="14" ShadowDepth="0" Opacity="0.9"/></Ellipse.Effect></Ellipse></Grid></Border>
                            <Border Style="{StaticResource Card}" Margin="0,0,12,0" BorderBrush="{StaticResource Teal}" BorderThickness="5,1,1,1"><StackPanel><StackPanel Orientation="Horizontal"><Border Style="{StaticResource StatIcon}" Background="{StaticResource TealSoft}"><TextBlock Text="▰" Foreground="{StaticResource Teal}" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="FREE SPACE" Foreground="{StaticResource Teal}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock x:Name="FreeSpaceText" Text="Checking…" FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock Text="On your main drive" Style="{StaticResource MutedText}" FontSize="12"/></StackPanel></Border>
                            <Border x:Name="HealthCard" Style="{StaticResource Card}" BorderBrush="{StaticResource Amber}" BorderThickness="5,1,1,1"><StackPanel><StackPanel Orientation="Horizontal"><Border x:Name="HealthIconBox" Style="{StaticResource StatIcon}" Background="{StaticResource AmberSoft}"><TextBlock x:Name="HealthIcon" Text="⬡" Foreground="{StaticResource Amber}" FontSize="18" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="HealthLabel" Text="WINDOWS HEALTH" Foreground="{StaticResource Amber}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock x:Name="WindowsStatusText" Text="Checking..." FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock x:Name="WindowsStatusHint" Text="Takes a few seconds. Nothing is changed." Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap"/><Button x:Name="HealthCheckButton" Content="↻  Check again" Cursor="Hand" HorizontalAlignment="Left" Margin="0,10,0,0" Visibility="Collapsed" ToolTip="Look again, for example after fixing something. Nothing is changed."><Button.Template><ControlTemplate TargetType="Button"><TextBlock x:Name="LinkText" Text="{TemplateBinding Content}" Foreground="#2563EB" FontSize="13" FontWeight="SemiBold" Background="Transparent"/><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="LinkText" Property="TextDecorations" Value="Underline"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Button.Template></Button></StackPanel></Border>
                        </UniformGrid>
<Border x:Name="DashMoreHint" Visibility="Collapsed" Style="{StaticResource Card}" Padding="22,16" Margin="0,0,0,22" BorderBrush="#F08200" BorderThickness="2"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel VerticalAlignment="Center"><TextBlock Text="There are more tools here" FontSize="18" FontWeight="ExtraBold" Foreground="#9A4B00"/><TextBlock Text="Find duplicate files, speed and space, security, drive and memory checks, Hibernate, app updates and more." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,12,0"/></StackPanel><Button x:Name="DashShowAllButton" Grid.Column="1" Style="{StaticResource HeroGreenButton}" Padding="18,10" FontSize="15" FontWeight="Bold" Content="＋  Show all tools" VerticalAlignment="Center"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFC04D" Offset="0"/><GradientStop Color="#F08200" Offset="1"/></LinearGradientBrush></Button.Background></Button></Grid></Border>
<TextBlock x:Name="DashOtherTitle" Text="Other things you can do" FontSize="18" FontWeight="ExtraBold" Margin="0,0,0,10"/>
<UniformGrid x:Name="DashOtherGrid" Columns="3" Margin="0,0,0,14"><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,12,0"><StackPanel><TextBlock Text="Check my PC" FontSize="18" FontWeight="ExtraBold"/><TextBlock Text="Checks your drives (SSD and NVMe too), memory, processor and heat in one go. Nothing is changed." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="40"/><Button x:Name="ScanButton" Content="Check my PC" Style="{StaticResource HeroGreenButton}" FontSize="14" Padding="20,9" HorizontalAlignment="Left"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#4FC3FF" Offset="0"/><GradientStop Color="#1E6FE8" Offset="1"/></LinearGradientBrush></Button.Background></Button></StackPanel></Border><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,12,0"><StackPanel><TextBlock Text="Past results" FontSize="18" FontWeight="ExtraBold"/><TextBlock Text="Look at what the Cleaner did before." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="40"/><Button x:Name="LastReportButton" Content="See past results" Style="{StaticResource HeroGreenButton}" FontSize="14" Padding="20,9" HorizontalAlignment="Left"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#3EE0C8" Offset="0"/><GradientStop Color="#0E9F8A" Offset="1"/></LinearGradientBrush></Button.Background></Button></StackPanel></Border><Border Style="{StaticResource Card}" Padding="22" Margin="0,0,12,0"><StackPanel><TextBlock Text="Update the Cleaner" FontSize="18" FontWeight="ExtraBold"/><TextBlock Text="Look for a newer version of the Cleaner." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="40"/><Button x:Name="CheckUpdatesButton" Content="Update this program" Style="{StaticResource HeroGreenButton}" FontSize="14" Padding="20,9" HorizontalAlignment="Left"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFC04D" Offset="0"/><GradientStop Color="#F08200" Offset="1"/></LinearGradientBrush></Button.Background></Button></StackPanel></Border></UniformGrid>
<StackPanel x:Name="DashMsTools" Margin="0,0,0,22"><TextBlock Text="MS Tools" FontSize="18" FontWeight="ExtraBold" Margin="0,0,0,10"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Left"><Button x:Name="SmartAppControlButton" Style="{StaticResource HeroGreenButton}" FontSize="14" Padding="20,9" Width="250" Height="46" VerticalAlignment="Top" HorizontalContentAlignment="Center" VerticalContentAlignment="Center" Foreground="White" HorizontalAlignment="Left" Margin="0,0,14,0" ToolTip="Opens the Windows page where Smart App Control is switched on or off. The Cleaner changes nothing itself."><TextBlock Text="Smart App Control" Foreground="White" FontWeight="SemiBold" VerticalAlignment="Center"/></Button><Button x:Name="PCManagerButton" Style="{StaticResource HeroGreenButton}" FontSize="14" Padding="20,9" Width="250" Height="46" VerticalAlignment="Top" HorizontalContentAlignment="Center" VerticalContentAlignment="Center" Foreground="White" HorizontalAlignment="Left" Margin="0,0,0,0" ToolTip="Opens Microsoft PC Manager, or its Microsoft Store page if it is not installed"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Grid Width="22" Height="22" Margin="0,0,10,0" VerticalAlignment="Center" Effect="{DynamicResource DR3DText}"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions><Rectangle Margin="0,0,1,1" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle><Rectangle Grid.Column="1" Margin="1,0,0,1" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle><Rectangle Grid.Row="1" Margin="0,1,1,0" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle><Rectangle Grid.Row="1" Grid.Column="1" Margin="1,1,0,0" RadiusX="1.5" RadiusY="1.5" Stroke="#0A5A2C" StrokeThickness="0.6"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#B6FFD2" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.45"/><GradientStop Color="#0B7A3B" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle></Grid><TextBlock Text="Microsoft PC Manager" Foreground="White" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Button></StackPanel><TextBlock Text="If it did not do the job, or you want your PC spotless, use DRDirect PC Cleaner for a deeper clean-up." Style="{StaticResource MutedText}" TextWrapping="Wrap" MaxWidth="560" HorizontalAlignment="Left" Margin="0,10,0,0"/></StackPanel>
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
                                <StackPanel><TextBlock x:Name="PresetSafeDate" HorizontalAlignment="Center" Style="{StaticResource MutedText}" FontSize="12" Margin="0,0,0,4"/><Button x:Name="PresetSafe" Style="{StaticResource GlossyChoiceButton}" Padding="16,12" Margin="0,0,10,8"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5BE584" Offset="0"/><GradientStop Color="#13A64A" Offset="1"/></LinearGradientBrush></Button.Background><StackPanel Orientation="Horizontal"><Viewbox x:Name="ScanBroomSafe" Width="34" Height="34" Margin="0,-8,8,-8" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.85" IsHitTestVisible="False"><Viewbox.RenderTransform><RotateTransform Angle="0"/></Viewbox.RenderTransform><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="BrH" MappingMode="Absolute" StartPoint="27,0" EndPoint="37,0"><GradientStop Color="#C8F7D8" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.3"/><GradientStop Color="#0B7A3B" Offset="0.65"/><GradientStop Color="#064A22" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrHay" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF3C4" Offset="0"/><GradientStop Color="#F0D58A" Offset="0.5"/><GradientStop Color="#C99A3E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrChrome" MappingMode="Absolute" StartPoint="21,0" EndPoint="43,0"><GradientStop Color="#6B7A92" Offset="0"/><GradientStop Color="#FFFFFF" Offset="0.25"/><GradientStop Color="#B9C6DA" Offset="0.5"/><GradientStop Color="#4A5A73" Offset="0.8"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="5" Direction="270" Opacity="0.65"/></Canvas.Effect><Canvas><Canvas.RenderTransform><RotateTransform Angle="35" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="#064A22" StrokeThickness="11" StrokeStartLineCap="Round"/><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="{StaticResource BrH}" StrokeThickness="8" StrokeStartLineCap="Round"/><Line X1="29.6" Y1="5" X2="29.6" Y2="35" Stroke="#CCFFFFFF" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="30" Canvas.Top="3.6" Width="4" Height="4" Fill="#E6FFFFFF"/><Polygon Points="22,45.0 42,45.0 49,63.0 46,65.0 43,63.0 40,66.0 37,63.0 34,66.0 31,63.0 28,66.0 25,63.0 22,66.0 19,63.0 16,65.0 15,63.0" Fill="#5A3A0E" StrokeLineJoin="Round"/><Polygon Points="22,42 42,42 49,60 46,62 43,60 40,63 37,60 34,63 31,60 28,63 25,60 22,63 19,60 16,62 15,60" Fill="{StaticResource BrHay}" Stroke="#FFF1B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Line X1="24" Y1="44" X2="19" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="27" Y1="44" X2="23" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="30" Y1="44" X2="28" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="33" Y1="44" X2="33" Y2="61" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="36" Y1="44" X2="38" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="39" Y1="44" X2="43" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="41" Y1="44" X2="46" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Rectangle Canvas.Left="21" Canvas.Top="39" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="#2A3548"/><Rectangle Canvas.Left="21" Canvas.Top="35" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="{StaticResource BrChrome}" Stroke="#FFFFFF" StrokeThickness="1.2"/><Line X1="22" Y1="38.5" X2="42" Y2="38.5" Stroke="#664A5A73" StrokeThickness="1"/><Line X1="22" Y1="41.5" X2="42" Y2="41.5" Stroke="#664A5A73" StrokeThickness="1"/><Rectangle Canvas.Left="23" Canvas.Top="36" Width="18" Height="2.4" RadiusX="1.2" RadiusY="1.2" Fill="#E6FFFFFF"/></Canvas><Canvas x:Name="ScanDustSafe" Visibility="Collapsed"><Ellipse Canvas.Left="-4" Canvas.Top="52" Width="14" Height="14" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.0"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-8" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="4" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.4"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.4"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-4" Duration="0:0:1.4"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.84"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.4"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="10" Canvas.Top="50" Width="16" Height="16" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.8"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.8"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="4" Duration="0:0:1.8"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.08"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.8"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-8" Canvas.Top="48" Width="10" Height="10" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.1"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-12" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="14" Canvas.Top="56" Width="12" Height="12" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.2"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.9"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="8" Duration="0:0:1.9"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.14"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.9"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="2" Canvas.Top="58" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.9"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.3"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="0" Duration="0:0:1.3"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.78"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.3"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-6" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.3"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.5"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-10" Duration="0:0:1.5"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.9"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.5"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="12" Canvas.Top="46" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.55"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.7"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="6" Duration="0:0:1.7"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.02"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.7"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="6" Canvas.Top="50" Width="13" Height="13" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.5"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-6" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse></Canvas></Canvas></Viewbox><TextBlock Text="SAFE SCAN" Foreground="White" FontSize="15" FontWeight="Bold"/></StackPanel></Button></StackPanel>
                                <StackPanel><TextBlock x:Name="PresetMediumDate" HorizontalAlignment="Center" Style="{StaticResource MutedText}" FontSize="12" Margin="0,0,0,4"/><Button x:Name="PresetMedium" Style="{StaticResource GlossyChoiceButton}" Padding="16,12" Margin="0,0,10,8"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#4FC3FF" Offset="0"/><GradientStop Color="#1E6FE8" Offset="1"/></LinearGradientBrush></Button.Background><StackPanel Orientation="Horizontal"><Viewbox x:Name="ScanBroomMedium" Width="34" Height="34" Margin="0,-8,8,-8" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.85" IsHitTestVisible="False"><Viewbox.RenderTransform><RotateTransform Angle="0"/></Viewbox.RenderTransform><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="BrH" MappingMode="Absolute" StartPoint="27,0" EndPoint="37,0"><GradientStop Color="#B8DBFF" Offset="0"/><GradientStop Color="#3F7FF0" Offset="0.3"/><GradientStop Color="#0B3AA8" Offset="0.65"/><GradientStop Color="#05215E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrHay" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF3C4" Offset="0"/><GradientStop Color="#F0D58A" Offset="0.5"/><GradientStop Color="#C99A3E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrChrome" MappingMode="Absolute" StartPoint="21,0" EndPoint="43,0"><GradientStop Color="#6B7A92" Offset="0"/><GradientStop Color="#FFFFFF" Offset="0.25"/><GradientStop Color="#B9C6DA" Offset="0.5"/><GradientStop Color="#4A5A73" Offset="0.8"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="5" Direction="270" Opacity="0.65"/></Canvas.Effect><Canvas><Canvas.RenderTransform><RotateTransform Angle="35" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="#05215E" StrokeThickness="11" StrokeStartLineCap="Round"/><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="{StaticResource BrH}" StrokeThickness="8" StrokeStartLineCap="Round"/><Line X1="29.6" Y1="5" X2="29.6" Y2="35" Stroke="#CCFFFFFF" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="30" Canvas.Top="3.6" Width="4" Height="4" Fill="#E6FFFFFF"/><Polygon Points="22,45.0 42,45.0 49,63.0 46,65.0 43,63.0 40,66.0 37,63.0 34,66.0 31,63.0 28,66.0 25,63.0 22,66.0 19,63.0 16,65.0 15,63.0" Fill="#5A3A0E" StrokeLineJoin="Round"/><Polygon Points="22,42 42,42 49,60 46,62 43,60 40,63 37,60 34,63 31,60 28,63 25,60 22,63 19,60 16,62 15,60" Fill="{StaticResource BrHay}" Stroke="#FFF1B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Line X1="24" Y1="44" X2="19" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="27" Y1="44" X2="23" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="30" Y1="44" X2="28" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="33" Y1="44" X2="33" Y2="61" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="36" Y1="44" X2="38" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="39" Y1="44" X2="43" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="41" Y1="44" X2="46" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Rectangle Canvas.Left="21" Canvas.Top="39" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="#2A3548"/><Rectangle Canvas.Left="21" Canvas.Top="35" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="{StaticResource BrChrome}" Stroke="#FFFFFF" StrokeThickness="1.2"/><Line X1="22" Y1="38.5" X2="42" Y2="38.5" Stroke="#664A5A73" StrokeThickness="1"/><Line X1="22" Y1="41.5" X2="42" Y2="41.5" Stroke="#664A5A73" StrokeThickness="1"/><Rectangle Canvas.Left="23" Canvas.Top="36" Width="18" Height="2.4" RadiusX="1.2" RadiusY="1.2" Fill="#E6FFFFFF"/></Canvas><Canvas x:Name="ScanDustMedium" Visibility="Collapsed"><Ellipse Canvas.Left="-4" Canvas.Top="52" Width="14" Height="14" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.0"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-8" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="4" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.4"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.4"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-4" Duration="0:0:1.4"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.84"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.4"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="10" Canvas.Top="50" Width="16" Height="16" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.8"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.8"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="4" Duration="0:0:1.8"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.08"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.8"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-8" Canvas.Top="48" Width="10" Height="10" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.1"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-12" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="14" Canvas.Top="56" Width="12" Height="12" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.2"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.9"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="8" Duration="0:0:1.9"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.14"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.9"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="2" Canvas.Top="58" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.9"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.3"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="0" Duration="0:0:1.3"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.78"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.3"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-6" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.3"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.5"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-10" Duration="0:0:1.5"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.9"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.5"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="12" Canvas.Top="46" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.55"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.7"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="6" Duration="0:0:1.7"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.02"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.7"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="6" Canvas.Top="50" Width="13" Height="13" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.5"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-6" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse></Canvas></Canvas></Viewbox><TextBlock Text="MEDIUM SCAN" Foreground="White" FontSize="15" FontWeight="Bold"/></StackPanel></Button></StackPanel>
                                <StackPanel><TextBlock x:Name="PresetAdvancedDate" HorizontalAlignment="Center" Style="{StaticResource MutedText}" FontSize="12" Margin="0,0,0,4"/><Button x:Name="PresetAdvanced" Style="{StaticResource GlossyChoiceButton}" Padding="16,12" Margin="0,0,0,8"><Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FF8A80" Offset="0"/><GradientStop Color="#D32020" Offset="1"/></LinearGradientBrush></Button.Background><StackPanel Orientation="Horizontal"><Viewbox x:Name="ScanBroomAdvanced" Width="34" Height="34" Margin="0,-8,8,-8" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.85" IsHitTestVisible="False"><Viewbox.RenderTransform><RotateTransform Angle="0"/></Viewbox.RenderTransform><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="BrH" MappingMode="Absolute" StartPoint="27,0" EndPoint="37,0"><GradientStop Color="#FFC4C4" Offset="0"/><GradientStop Color="#FF4040" Offset="0.3"/><GradientStop Color="#9B1010" Offset="0.65"/><GradientStop Color="#5A0808" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrHay" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF3C4" Offset="0"/><GradientStop Color="#F0D58A" Offset="0.5"/><GradientStop Color="#C99A3E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrChrome" MappingMode="Absolute" StartPoint="21,0" EndPoint="43,0"><GradientStop Color="#6B7A92" Offset="0"/><GradientStop Color="#FFFFFF" Offset="0.25"/><GradientStop Color="#B9C6DA" Offset="0.5"/><GradientStop Color="#4A5A73" Offset="0.8"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="5" Direction="270" Opacity="0.65"/></Canvas.Effect><Canvas><Canvas.RenderTransform><RotateTransform Angle="35" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="#5A0808" StrokeThickness="11" StrokeStartLineCap="Round"/><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="{StaticResource BrH}" StrokeThickness="8" StrokeStartLineCap="Round"/><Line X1="29.6" Y1="5" X2="29.6" Y2="35" Stroke="#CCFFFFFF" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="30" Canvas.Top="3.6" Width="4" Height="4" Fill="#E6FFFFFF"/><Polygon Points="22,45.0 42,45.0 49,63.0 46,65.0 43,63.0 40,66.0 37,63.0 34,66.0 31,63.0 28,66.0 25,63.0 22,66.0 19,63.0 16,65.0 15,63.0" Fill="#5A3A0E" StrokeLineJoin="Round"/><Polygon Points="22,42 42,42 49,60 46,62 43,60 40,63 37,60 34,63 31,60 28,63 25,60 22,63 19,60 16,62 15,60" Fill="{StaticResource BrHay}" Stroke="#FFF1B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Line X1="24" Y1="44" X2="19" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="27" Y1="44" X2="23" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="30" Y1="44" X2="28" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="33" Y1="44" X2="33" Y2="61" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="36" Y1="44" X2="38" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="39" Y1="44" X2="43" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="41" Y1="44" X2="46" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Rectangle Canvas.Left="21" Canvas.Top="39" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="#2A3548"/><Rectangle Canvas.Left="21" Canvas.Top="35" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="{StaticResource BrChrome}" Stroke="#FFFFFF" StrokeThickness="1.2"/><Line X1="22" Y1="38.5" X2="42" Y2="38.5" Stroke="#664A5A73" StrokeThickness="1"/><Line X1="22" Y1="41.5" X2="42" Y2="41.5" Stroke="#664A5A73" StrokeThickness="1"/><Rectangle Canvas.Left="23" Canvas.Top="36" Width="18" Height="2.4" RadiusX="1.2" RadiusY="1.2" Fill="#E6FFFFFF"/></Canvas><Canvas x:Name="ScanDustAdvanced" Visibility="Collapsed"><Ellipse Canvas.Left="-4" Canvas.Top="52" Width="14" Height="14" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.0"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-8" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="4" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.4"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.4"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-4" Duration="0:0:1.4"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.84"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.4"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="10" Canvas.Top="50" Width="16" Height="16" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.8"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.8"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="4" Duration="0:0:1.8"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.08"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.8"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-8" Canvas.Top="48" Width="10" Height="10" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.1"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-12" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="14" Canvas.Top="56" Width="12" Height="12" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.2"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.9"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="8" Duration="0:0:1.9"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.14"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.9"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="2" Canvas.Top="58" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.9"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.3"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="0" Duration="0:0:1.3"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.78"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.3"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-6" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.3"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.5"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-10" Duration="0:0:1.5"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.9"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.5"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="12" Canvas.Top="46" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.55"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.7"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="6" Duration="0:0:1.7"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.02"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.7"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="6" Canvas.Top="50" Width="13" Height="13" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.5"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-6" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse></Canvas></Canvas></Viewbox><TextBlock Text="ADVANCED SCAN" Foreground="White" FontSize="15" FontWeight="Bold"/><Viewbox x:Name="ScanBroomAdvanced2" Width="34" Height="34" Margin="8,-8,0,-8" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.85" IsHitTestVisible="False"><Viewbox.LayoutTransform><ScaleTransform ScaleX="-1"/></Viewbox.LayoutTransform><Viewbox.RenderTransform><RotateTransform Angle="0"/></Viewbox.RenderTransform><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="BrH" MappingMode="Absolute" StartPoint="27,0" EndPoint="37,0"><GradientStop Color="#FFC4C4" Offset="0"/><GradientStop Color="#FF4040" Offset="0.3"/><GradientStop Color="#9B1010" Offset="0.65"/><GradientStop Color="#5A0808" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrHay" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF3C4" Offset="0"/><GradientStop Color="#F0D58A" Offset="0.5"/><GradientStop Color="#C99A3E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrChrome" MappingMode="Absolute" StartPoint="21,0" EndPoint="43,0"><GradientStop Color="#6B7A92" Offset="0"/><GradientStop Color="#FFFFFF" Offset="0.25"/><GradientStop Color="#B9C6DA" Offset="0.5"/><GradientStop Color="#4A5A73" Offset="0.8"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="5" Direction="270" Opacity="0.65"/></Canvas.Effect><Canvas><Canvas.RenderTransform><RotateTransform Angle="35" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="#5A0808" StrokeThickness="11" StrokeStartLineCap="Round"/><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="{StaticResource BrH}" StrokeThickness="8" StrokeStartLineCap="Round"/><Line X1="29.6" Y1="5" X2="29.6" Y2="35" Stroke="#CCFFFFFF" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="30" Canvas.Top="3.6" Width="4" Height="4" Fill="#E6FFFFFF"/><Polygon Points="22,45.0 42,45.0 49,63.0 46,65.0 43,63.0 40,66.0 37,63.0 34,66.0 31,63.0 28,66.0 25,63.0 22,66.0 19,63.0 16,65.0 15,63.0" Fill="#5A3A0E" StrokeLineJoin="Round"/><Polygon Points="22,42 42,42 49,60 46,62 43,60 40,63 37,60 34,63 31,60 28,63 25,60 22,63 19,60 16,62 15,60" Fill="{StaticResource BrHay}" Stroke="#FFF1B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Line X1="24" Y1="44" X2="19" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="27" Y1="44" X2="23" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="30" Y1="44" X2="28" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="33" Y1="44" X2="33" Y2="61" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="36" Y1="44" X2="38" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="39" Y1="44" X2="43" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="41" Y1="44" X2="46" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Rectangle Canvas.Left="21" Canvas.Top="39" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="#2A3548"/><Rectangle Canvas.Left="21" Canvas.Top="35" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="{StaticResource BrChrome}" Stroke="#FFFFFF" StrokeThickness="1.2"/><Line X1="22" Y1="38.5" X2="42" Y2="38.5" Stroke="#664A5A73" StrokeThickness="1"/><Line X1="22" Y1="41.5" X2="42" Y2="41.5" Stroke="#664A5A73" StrokeThickness="1"/><Rectangle Canvas.Left="23" Canvas.Top="36" Width="18" Height="2.4" RadiusX="1.2" RadiusY="1.2" Fill="#E6FFFFFF"/></Canvas><Canvas x:Name="ScanDustAdvanced2" Visibility="Collapsed"><Ellipse Canvas.Left="-4" Canvas.Top="52" Width="14" Height="14" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.0"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-8" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="4" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.4"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.4"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-4" Duration="0:0:1.4"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.84"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.4"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="10" Canvas.Top="50" Width="16" Height="16" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.8"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.8"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="4" Duration="0:0:1.8"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.08"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.8"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-8" Canvas.Top="48" Width="10" Height="10" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.1"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-12" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="14" Canvas.Top="56" Width="12" Height="12" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.2"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.9"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="8" Duration="0:0:1.9"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.14"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.9"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="2" Canvas.Top="58" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.9"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.3"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="0" Duration="0:0:1.3"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.78"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.3"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-6" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.3"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.5"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-10" Duration="0:0:1.5"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.9"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.5"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="12" Canvas.Top="46" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.55"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.7"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="6" Duration="0:0:1.7"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.02"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.7"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="6" Canvas.Top="50" Width="13" Height="13" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.5"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-6" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse></Canvas></Canvas></Viewbox></StackPanel></Button></StackPanel>
                            </UniformGrid>
                            <TextBlock x:Name="PresetDescription" Text="Choose a level, or select individual tasks below." Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0"/>
                        </StackPanel>
                    </Border>
                    <ScrollViewer x:Name="PlanScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel>
                    <Grid Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="TaskIntro" Text="Select exactly what you want to run. Nothing starts until you review and confirm the plan." Style="{StaticResource MutedText}" TextWrapping="Wrap"/><Border Grid.Column="1" Background="{StaticResource BlueSoft}" CornerRadius="14" Padding="12,6"><TextBlock x:Name="SelectionSummary" Text="0 selected" Foreground="{StaticResource Blue}" FontSize="12"/></Border></Grid>
                    <StackPanel x:Name="TaskList"/>
                    </StackPanel></ScrollViewer>
                    <Border x:Name="PlanMoreUp" Grid.Row="1" Visibility="Collapsed" VerticalAlignment="Top" HorizontalAlignment="Center" Margin="0,8,0,8" Padding="22,7" CornerRadius="16" Cursor="Hand" ToolTip="Scroll up"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5B9BFF" Offset="0"/><GradientStop Color="#1F5FE0" Offset="1"/></LinearGradientBrush></Border.Background><Border.Effect><DropShadowEffect Color="#0A1A4A" BlurRadius="10" ShadowDepth="3" Direction="270" Opacity="0.55"/></Border.Effect><TextBlock Text="▲   More above" Foreground="White" FontSize="14" FontWeight="Bold"/></Border><Border x:Name="PlanMoreDown" Grid.Row="1" Visibility="Collapsed" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,8,0,8" Padding="22,7" CornerRadius="16" Cursor="Hand" ToolTip="Scroll down"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5B9BFF" Offset="0"/><GradientStop Color="#1F5FE0" Offset="1"/></LinearGradientBrush></Border.Background><Border.Effect><DropShadowEffect Color="#0A1A4A" BlurRadius="10" ShadowDepth="3" Direction="270" Opacity="0.55"/></Border.Effect><TextBlock Text="▼   More below" Foreground="White" FontSize="14" FontWeight="Bold"/></Border></Grid>
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
                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center"><Viewbox x:Name="BannerBroomSafe" Visibility="Collapsed" Width="60" Height="60" Margin="0,-10,6,-10" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.85" IsHitTestVisible="False"><Viewbox.RenderTransform><RotateTransform x:Name="BrushSwingS" Angle="-20"/></Viewbox.RenderTransform><Viewbox.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><DoubleAnimation Storyboard.TargetName="BrushSwingS" Storyboard.TargetProperty="Angle" From="-20" To="20" Duration="0:0:0.7"><DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction></DoubleAnimation></Storyboard></BeginStoryboard></EventTrigger></Viewbox.Triggers><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="BrH" MappingMode="Absolute" StartPoint="27,0" EndPoint="37,0"><GradientStop Color="#C8F7D8" Offset="0"/><GradientStop Color="#2BE37A" Offset="0.3"/><GradientStop Color="#0B7A3B" Offset="0.65"/><GradientStop Color="#064A22" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrHay" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF3C4" Offset="0"/><GradientStop Color="#F0D58A" Offset="0.5"/><GradientStop Color="#C99A3E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrChrome" MappingMode="Absolute" StartPoint="21,0" EndPoint="43,0"><GradientStop Color="#6B7A92" Offset="0"/><GradientStop Color="#FFFFFF" Offset="0.25"/><GradientStop Color="#B9C6DA" Offset="0.5"/><GradientStop Color="#4A5A73" Offset="0.8"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="5" Direction="270" Opacity="0.65"/></Canvas.Effect><Canvas><Canvas.RenderTransform><RotateTransform Angle="35" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="#064A22" StrokeThickness="11" StrokeStartLineCap="Round"/><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="{StaticResource BrH}" StrokeThickness="8" StrokeStartLineCap="Round"/><Line X1="29.6" Y1="5" X2="29.6" Y2="35" Stroke="#CCFFFFFF" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="30" Canvas.Top="3.6" Width="4" Height="4" Fill="#E6FFFFFF"/><Polygon Points="22,45.0 42,45.0 49,63.0 46,65.0 43,63.0 40,66.0 37,63.0 34,66.0 31,63.0 28,66.0 25,63.0 22,66.0 19,63.0 16,65.0 15,63.0" Fill="#5A3A0E" StrokeLineJoin="Round"/><Polygon Points="22,42 42,42 49,60 46,62 43,60 40,63 37,60 34,63 31,60 28,63 25,60 22,63 19,60 16,62 15,60" Fill="{StaticResource BrHay}" Stroke="#FFF1B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Line X1="24" Y1="44" X2="19" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="27" Y1="44" X2="23" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="30" Y1="44" X2="28" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="33" Y1="44" X2="33" Y2="61" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="36" Y1="44" X2="38" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="39" Y1="44" X2="43" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="41" Y1="44" X2="46" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Rectangle Canvas.Left="21" Canvas.Top="39" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="#2A3548"/><Rectangle Canvas.Left="21" Canvas.Top="35" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="{StaticResource BrChrome}" Stroke="#FFFFFF" StrokeThickness="1.2"/><Line X1="22" Y1="38.5" X2="42" Y2="38.5" Stroke="#664A5A73" StrokeThickness="1"/><Line X1="22" Y1="41.5" X2="42" Y2="41.5" Stroke="#664A5A73" StrokeThickness="1"/><Rectangle Canvas.Left="23" Canvas.Top="36" Width="18" Height="2.4" RadiusX="1.2" RadiusY="1.2" Fill="#E6FFFFFF"/></Canvas><Ellipse Canvas.Left="-4" Canvas.Top="52" Width="14" Height="14" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.0"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-8" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="4" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.4"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.4"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-4" Duration="0:0:1.4"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.84"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.4"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="10" Canvas.Top="50" Width="16" Height="16" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.8"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.8"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="4" Duration="0:0:1.8"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.08"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.8"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-8" Canvas.Top="48" Width="10" Height="10" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.1"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-12" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="14" Canvas.Top="56" Width="12" Height="12" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.2"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.9"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="8" Duration="0:0:1.9"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.14"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.9"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="2" Canvas.Top="58" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.9"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.3"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="0" Duration="0:0:1.3"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.78"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.3"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-6" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.3"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.5"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-10" Duration="0:0:1.5"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.9"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.5"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="12" Canvas.Top="46" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.55"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.7"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="6" Duration="0:0:1.7"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.02"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.7"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="6" Canvas.Top="50" Width="13" Height="13" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.5"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-6" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse></Canvas></Viewbox><Viewbox x:Name="BannerBroomMedium" Width="60" Height="60" Margin="0,-10,6,-10" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.85" IsHitTestVisible="False"><Viewbox.RenderTransform><RotateTransform x:Name="BrushSwingM" Angle="-20"/></Viewbox.RenderTransform><Viewbox.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><DoubleAnimation Storyboard.TargetName="BrushSwingM" Storyboard.TargetProperty="Angle" From="-20" To="20" Duration="0:0:0.7"><DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction></DoubleAnimation></Storyboard></BeginStoryboard></EventTrigger></Viewbox.Triggers><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="BrH" MappingMode="Absolute" StartPoint="27,0" EndPoint="37,0"><GradientStop Color="#B8DBFF" Offset="0"/><GradientStop Color="#3F7FF0" Offset="0.3"/><GradientStop Color="#0B3AA8" Offset="0.65"/><GradientStop Color="#05215E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrHay" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF3C4" Offset="0"/><GradientStop Color="#F0D58A" Offset="0.5"/><GradientStop Color="#C99A3E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrChrome" MappingMode="Absolute" StartPoint="21,0" EndPoint="43,0"><GradientStop Color="#6B7A92" Offset="0"/><GradientStop Color="#FFFFFF" Offset="0.25"/><GradientStop Color="#B9C6DA" Offset="0.5"/><GradientStop Color="#4A5A73" Offset="0.8"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="5" Direction="270" Opacity="0.65"/></Canvas.Effect><Canvas><Canvas.RenderTransform><RotateTransform Angle="35" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="#05215E" StrokeThickness="11" StrokeStartLineCap="Round"/><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="{StaticResource BrH}" StrokeThickness="8" StrokeStartLineCap="Round"/><Line X1="29.6" Y1="5" X2="29.6" Y2="35" Stroke="#CCFFFFFF" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="30" Canvas.Top="3.6" Width="4" Height="4" Fill="#E6FFFFFF"/><Polygon Points="22,45.0 42,45.0 49,63.0 46,65.0 43,63.0 40,66.0 37,63.0 34,66.0 31,63.0 28,66.0 25,63.0 22,66.0 19,63.0 16,65.0 15,63.0" Fill="#5A3A0E" StrokeLineJoin="Round"/><Polygon Points="22,42 42,42 49,60 46,62 43,60 40,63 37,60 34,63 31,60 28,63 25,60 22,63 19,60 16,62 15,60" Fill="{StaticResource BrHay}" Stroke="#FFF1B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Line X1="24" Y1="44" X2="19" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="27" Y1="44" X2="23" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="30" Y1="44" X2="28" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="33" Y1="44" X2="33" Y2="61" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="36" Y1="44" X2="38" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="39" Y1="44" X2="43" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="41" Y1="44" X2="46" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Rectangle Canvas.Left="21" Canvas.Top="39" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="#2A3548"/><Rectangle Canvas.Left="21" Canvas.Top="35" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="{StaticResource BrChrome}" Stroke="#FFFFFF" StrokeThickness="1.2"/><Line X1="22" Y1="38.5" X2="42" Y2="38.5" Stroke="#664A5A73" StrokeThickness="1"/><Line X1="22" Y1="41.5" X2="42" Y2="41.5" Stroke="#664A5A73" StrokeThickness="1"/><Rectangle Canvas.Left="23" Canvas.Top="36" Width="18" Height="2.4" RadiusX="1.2" RadiusY="1.2" Fill="#E6FFFFFF"/></Canvas><Ellipse Canvas.Left="-4" Canvas.Top="52" Width="14" Height="14" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.0"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-8" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="4" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.4"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.4"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-4" Duration="0:0:1.4"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.84"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.4"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="10" Canvas.Top="50" Width="16" Height="16" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.8"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.8"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="4" Duration="0:0:1.8"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.08"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.8"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-8" Canvas.Top="48" Width="10" Height="10" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.1"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-12" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="14" Canvas.Top="56" Width="12" Height="12" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.2"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.9"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="8" Duration="0:0:1.9"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.14"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.9"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="2" Canvas.Top="58" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.9"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.3"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="0" Duration="0:0:1.3"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.78"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.3"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-6" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.3"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.5"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-10" Duration="0:0:1.5"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.9"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.5"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="12" Canvas.Top="46" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.55"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.7"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="6" Duration="0:0:1.7"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.02"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.7"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="6" Canvas.Top="50" Width="13" Height="13" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.5"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-6" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse></Canvas></Viewbox><Viewbox x:Name="BannerBroomAdvanced" Visibility="Collapsed" Width="60" Height="60" Margin="0,-10,6,-10" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.85" IsHitTestVisible="False"><Viewbox.RenderTransform><RotateTransform x:Name="BrushSwingA1" Angle="-20"/></Viewbox.RenderTransform><Viewbox.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><DoubleAnimation Storyboard.TargetName="BrushSwingA1" Storyboard.TargetProperty="Angle" From="-20" To="20" Duration="0:0:0.7"><DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction></DoubleAnimation></Storyboard></BeginStoryboard></EventTrigger></Viewbox.Triggers><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="BrH" MappingMode="Absolute" StartPoint="27,0" EndPoint="37,0"><GradientStop Color="#FFC4C4" Offset="0"/><GradientStop Color="#FF4040" Offset="0.3"/><GradientStop Color="#9B1010" Offset="0.65"/><GradientStop Color="#5A0808" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrHay" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF3C4" Offset="0"/><GradientStop Color="#F0D58A" Offset="0.5"/><GradientStop Color="#C99A3E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrChrome" MappingMode="Absolute" StartPoint="21,0" EndPoint="43,0"><GradientStop Color="#6B7A92" Offset="0"/><GradientStop Color="#FFFFFF" Offset="0.25"/><GradientStop Color="#B9C6DA" Offset="0.5"/><GradientStop Color="#4A5A73" Offset="0.8"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="5" Direction="270" Opacity="0.65"/></Canvas.Effect><Canvas><Canvas.RenderTransform><RotateTransform Angle="35" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="#5A0808" StrokeThickness="11" StrokeStartLineCap="Round"/><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="{StaticResource BrH}" StrokeThickness="8" StrokeStartLineCap="Round"/><Line X1="29.6" Y1="5" X2="29.6" Y2="35" Stroke="#CCFFFFFF" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="30" Canvas.Top="3.6" Width="4" Height="4" Fill="#E6FFFFFF"/><Polygon Points="22,45.0 42,45.0 49,63.0 46,65.0 43,63.0 40,66.0 37,63.0 34,66.0 31,63.0 28,66.0 25,63.0 22,66.0 19,63.0 16,65.0 15,63.0" Fill="#5A3A0E" StrokeLineJoin="Round"/><Polygon Points="22,42 42,42 49,60 46,62 43,60 40,63 37,60 34,63 31,60 28,63 25,60 22,63 19,60 16,62 15,60" Fill="{StaticResource BrHay}" Stroke="#FFF1B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Line X1="24" Y1="44" X2="19" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="27" Y1="44" X2="23" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="30" Y1="44" X2="28" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="33" Y1="44" X2="33" Y2="61" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="36" Y1="44" X2="38" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="39" Y1="44" X2="43" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="41" Y1="44" X2="46" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Rectangle Canvas.Left="21" Canvas.Top="39" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="#2A3548"/><Rectangle Canvas.Left="21" Canvas.Top="35" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="{StaticResource BrChrome}" Stroke="#FFFFFF" StrokeThickness="1.2"/><Line X1="22" Y1="38.5" X2="42" Y2="38.5" Stroke="#664A5A73" StrokeThickness="1"/><Line X1="22" Y1="41.5" X2="42" Y2="41.5" Stroke="#664A5A73" StrokeThickness="1"/><Rectangle Canvas.Left="23" Canvas.Top="36" Width="18" Height="2.4" RadiusX="1.2" RadiusY="1.2" Fill="#E6FFFFFF"/></Canvas><Ellipse Canvas.Left="-4" Canvas.Top="52" Width="14" Height="14" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.0"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-8" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="4" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.4"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.4"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-4" Duration="0:0:1.4"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.84"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.4"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="10" Canvas.Top="50" Width="16" Height="16" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.8"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.8"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="4" Duration="0:0:1.8"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.08"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.8"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-8" Canvas.Top="48" Width="10" Height="10" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.1"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-12" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="14" Canvas.Top="56" Width="12" Height="12" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.2"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.9"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="8" Duration="0:0:1.9"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.14"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.9"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="2" Canvas.Top="58" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.9"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.3"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="0" Duration="0:0:1.3"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.78"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.3"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-6" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.3"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.5"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-10" Duration="0:0:1.5"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.9"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.5"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="12" Canvas.Top="46" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.55"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.7"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="6" Duration="0:0:1.7"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.02"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.7"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="6" Canvas.Top="50" Width="13" Height="13" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.5"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-6" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse></Canvas></Viewbox><Viewbox x:Name="BannerBroomAdvanced2" Visibility="Collapsed" Width="60" Height="60" Margin="6,-10,0,-10" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.85" IsHitTestVisible="False"><Viewbox.LayoutTransform><ScaleTransform ScaleX="-1"/></Viewbox.LayoutTransform><Viewbox.RenderTransform><RotateTransform x:Name="BrushSwingA2" Angle="-20"/></Viewbox.RenderTransform><Viewbox.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><DoubleAnimation Storyboard.TargetName="BrushSwingA2" Storyboard.TargetProperty="Angle" From="-20" To="20" Duration="0:0:0.7"><DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction></DoubleAnimation></Storyboard></BeginStoryboard></EventTrigger></Viewbox.Triggers><Canvas Width="64" Height="64"><Canvas.Resources><LinearGradientBrush x:Key="BrH" MappingMode="Absolute" StartPoint="27,0" EndPoint="37,0"><GradientStop Color="#FFC4C4" Offset="0"/><GradientStop Color="#FF4040" Offset="0.3"/><GradientStop Color="#9B1010" Offset="0.65"/><GradientStop Color="#5A0808" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrHay" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF3C4" Offset="0"/><GradientStop Color="#F0D58A" Offset="0.5"/><GradientStop Color="#C99A3E" Offset="1"/></LinearGradientBrush><LinearGradientBrush x:Key="BrChrome" MappingMode="Absolute" StartPoint="21,0" EndPoint="43,0"><GradientStop Color="#6B7A92" Offset="0"/><GradientStop Color="#FFFFFF" Offset="0.25"/><GradientStop Color="#B9C6DA" Offset="0.5"/><GradientStop Color="#4A5A73" Offset="0.8"/><GradientStop Color="#C9D5E8" Offset="1"/></LinearGradientBrush></Canvas.Resources><Canvas.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="5" Direction="270" Opacity="0.65"/></Canvas.Effect><Canvas><Canvas.RenderTransform><RotateTransform Angle="35" CenterX="32" CenterY="32"/></Canvas.RenderTransform><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="#5A0808" StrokeThickness="11" StrokeStartLineCap="Round"/><Line X1="32" Y1="3" X2="32" Y2="37" Stroke="{StaticResource BrH}" StrokeThickness="8" StrokeStartLineCap="Round"/><Line X1="29.6" Y1="5" X2="29.6" Y2="35" Stroke="#CCFFFFFF" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="30" Canvas.Top="3.6" Width="4" Height="4" Fill="#E6FFFFFF"/><Polygon Points="22,45.0 42,45.0 49,63.0 46,65.0 43,63.0 40,66.0 37,63.0 34,66.0 31,63.0 28,66.0 25,63.0 22,66.0 19,63.0 16,65.0 15,63.0" Fill="#5A3A0E" StrokeLineJoin="Round"/><Polygon Points="22,42 42,42 49,60 46,62 43,60 40,63 37,60 34,63 31,60 28,63 25,60 22,63 19,60 16,62 15,60" Fill="{StaticResource BrHay}" Stroke="#FFF1B8" StrokeThickness="1.2" StrokeLineJoin="Round"/><Line X1="24" Y1="44" X2="19" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="27" Y1="44" X2="23" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="30" Y1="44" X2="28" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="33" Y1="44" X2="33" Y2="61" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="36" Y1="44" X2="38" Y2="60" Stroke="#A87B2A" StrokeThickness="1"/><Line X1="39" Y1="44" X2="43" Y2="60" Stroke="#FFF3C4" StrokeThickness="1"/><Line X1="41" Y1="44" X2="46" Y2="59" Stroke="#A87B2A" StrokeThickness="1"/><Rectangle Canvas.Left="21" Canvas.Top="39" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="#2A3548"/><Rectangle Canvas.Left="21" Canvas.Top="35" Width="22" Height="10" RadiusX="3" RadiusY="3" Fill="{StaticResource BrChrome}" Stroke="#FFFFFF" StrokeThickness="1.2"/><Line X1="22" Y1="38.5" X2="42" Y2="38.5" Stroke="#664A5A73" StrokeThickness="1"/><Line X1="22" Y1="41.5" X2="42" Y2="41.5" Stroke="#664A5A73" StrokeThickness="1"/><Rectangle Canvas.Left="23" Canvas.Top="36" Width="18" Height="2.4" RadiusX="1.2" RadiusY="1.2" Fill="#E6FFFFFF"/></Canvas><Ellipse Canvas.Left="-4" Canvas.Top="52" Width="14" Height="14" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.0"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-8" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="4" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.4"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.4"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-4" Duration="0:0:1.4"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.84"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.4"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="10" Canvas.Top="50" Width="16" Height="16" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.8"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.8"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="4" Duration="0:0:1.8"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.08"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.8"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-8" Canvas.Top="48" Width="10" Height="10" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.1"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-12" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="14" Canvas.Top="56" Width="12" Height="12" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.2"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.9"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="8" Duration="0:0:1.9"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.14"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.9"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="2" Canvas.Top="58" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.9"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.3"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="0" Duration="0:0:1.3"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.78"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.3"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="-6" Canvas.Top="56" Width="11" Height="11" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.3"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.5"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-10" Duration="0:0:1.5"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.9"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.5"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="12" Canvas.Top="46" Width="9" Height="9" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.55"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.7"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="6" Duration="0:0:1.7"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:1.02"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.7"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Canvas.Left="6" Canvas.Top="50" Width="13" Height="13" Fill="#FFF8E6" Stroke="#D9CBA0" StrokeThickness="0.8" Opacity="0"><Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" BeginTime="0:0:1.5"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" From="0" To="-46" Duration="0:0:1.6"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="0" To="-6" Duration="0:0:1.6"/><DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity"><LinearDoubleKeyFrame Value="0" KeyTime="0:0:0"/><LinearDoubleKeyFrame Value="0.95" KeyTime="0:0:0.15"/><LinearDoubleKeyFrame Value="0.7" KeyTime="0:0:0.96"/><LinearDoubleKeyFrame Value="0" KeyTime="0:0:1.6"/></DoubleAnimationUsingKeyFrames></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse></Canvas></Viewbox></StackPanel>
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
                    <Grid Grid.Row="3" Margin="0,16,0,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Border x:Name="RunRestartPanel" Grid.Row="0" Grid.ColumnSpan="3" Visibility="Collapsed" Background="#EEF4FF" BorderBrush="#C7D7F5" BorderThickness="1" CornerRadius="10" Padding="14,10" Margin="0,0,0,12"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="When the clean-up finishes, restart Windows:" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,14,0"/><ComboBox x:Name="RunRestartCombo" Grid.Column="1" MinWidth="290" FontSize="13" Padding="10,6" SelectedIndex="0"><ComboBoxItem Tag="0" Content="I will restart myself, when I am ready"/><ComboBoxItem Tag="10" Content="Right away (10 seconds after it finishes)"/><ComboBoxItem Tag="300" Content="In 5 minutes after it finishes"/><ComboBoxItem Tag="600" Content="In 10 minutes after it finishes"/><ComboBoxItem Tag="-1" Content="Shut down my PC when it finishes"/></ComboBox></Grid></Border><TextBlock Grid.Row="1" x:Name="ProgressSafetyText" Text="Long-running Windows commands finish before the next task begins." Style="{StaticResource MutedText}" FontSize="12" VerticalAlignment="Center"/><Button x:Name="RestartButton" Grid.Row="1" Grid.Column="1" Content="Restart now" Style="{StaticResource PrimaryButton}" Margin="0,0,10,0" Visibility="Collapsed"/><Button x:Name="CancelPlanButton" Grid.Row="1" Grid.Column="2" Content="Stop after current task" Style="{StaticResource SecondaryButton}"/></Grid>
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
                        <StackPanel x:Name="RestartDelayPanel" Grid.Row="0" Margin="0,0,0,16" Visibility="Collapsed"><TextBlock Text="When should Windows restart or shut down after the clean?" FontWeight="SemiBold" Margin="0,0,0,6"/>
                            <ComboBox x:Name="RestartDelayCombo" SelectedIndex="0" FontSize="14" Padding="10,7">
                                <ComboBoxItem Tag="0" Content="I will restart myself, when I am ready"/>
                                <ComboBoxItem Tag="10" Content="Right away (10 seconds after it finishes)"/>
                                <ComboBoxItem Tag="300" Content="In 5 minutes after it finishes"/>
                                <ComboBoxItem Tag="600" Content="In 10 minutes after it finishes"/>
                                <ComboBoxItem Tag="-1" Content="Shut down my PC when it finishes (60 seconds, you can cancel)"/>
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
    param($closingSender, $closingArgs)
    # Closing the Cleaner while the Uninstaller or the Duplicate Finder is open caused an error, so the X waits
    # until they are closed. An update restart (DRForceClose) and the test mode are the only ways around it.
    if (-not $script:DRForceClose -and -not $TestMode) {
        try {
            $openTools = New-Object System.Collections.ArrayList
            $finderOpen = Get-Process -Name 'powershell', 'DRDirect*' -ErrorAction SilentlyContinue |
                Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -eq 'DRDirect Duplicate Finder' } | Select-Object -First 1
            if ($finderOpen) { [void]$openTools.Add('the Duplicate Finder') }
            $uninstallerOpen = Get-Process -Name 'BCUninstaller' -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
            if ($uninstallerOpen) { [void]$openTools.Add('the Uninstaller') }
            if ($openTools.Count) {
                $closingArgs.Cancel = $true
                [void][Windows.MessageBox]::Show(('Close {0} first, then you can close the Cleaner.' -f ($openTools -join ' and ')), 'DRDirect PC Cleaner', 'OK', 'Information')
                return
            }
        } catch { }
    }
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
@('PlanScroll','PlanMoreUp','PlanMoreDown','NavMoreUp','BannerBroomSafe','BannerBroomMedium','BannerBroomAdvanced','BannerBroomAdvanced2','NavModeText','ScanBroomSafe','ScanBroomMedium','ScanBroomAdvanced','ScanBroomAdvanced2','NavScroll','NavMoreHint','NavHeadClean','NavHeadFix','NavHeadCheck','DashMoreHint','DashShowAllButton','NavModeToggle','NavHeadUpdate','DashOtherTitle','DashOtherGrid','DashMsTools','SmartAppControlButton','NavSmartApp','NavFullScan','DashMoreOptions','SoundSwitch','Max3DSwitch','CrazyNuttySwitch','DashNoteButton','NavNoteButton','ResetReliabilityButton','AISearchBox','AISearchText','AISearchHint','RestartDelayPanel','RestartDelayCombo','CustomTitleBar','TitleDragArea','TitleMinButton','TitleMaxButton','TitleCloseButton','NavDashboard','NavCleanup','NavRepair','NavSecurity','NavHealth','NavMemory','NavPowerHeat','NavSpeed','NavHibernate','UpdateBanner','UpdateBannerText','DiskWarning','DiskWarningTitle','DiskWarningMore','UpdateBannerButton','HeroUpdateButton','RunRestartPanel','RunRestartCombo','RunStrip','RunStripTitle','RunStripDetail','RunStripCleaning','RunStripHint','NavCleanDust','ScanDustSafe','ScanDustMedium','ScanDustAdvanced','ScanDustAdvanced2','RunStripBar','NavHistory','NavProgress','ActivateButton','ActivateWrap','ActivateScale','TrialCountdown','AdminStatus','VersionText','PageTitle','PageEyebrow','FreeSpaceText','WindowsStatusText','LastCleanCard','LastCleanLightBlue','LastCleanLightRed','LastCleanValue','LastCleanHint','LastCleanQuickScan','LastCleanFullScan','CleanCheckAllButton','CleanCheckOffButton','PresetSafeDate','PresetMediumDate','PresetAdvancedDate','ScanButton','HealthCheckButton','HealthCard','HealthIconBox','HealthIcon','HealthLabel','WindowsStatusHint','LastReportButton','TestModeBanner','PageDashboard','PageTasks','TaskIntro','SelectionSummary','CleanupPresetPanel','PresetSafe','PresetMedium','PresetAdvanced','PresetDescription','TaskList','ReviewButton','PageProgress','ProgressScanLevel','ProgressHeading','ProgressMessage','ProgressPercent','OverallProgress','ProgressList','CleaningAnimation','CleaningCaption','CleanDone','CleanDoneScale','CleanDoneTick','CleanDoneSub','ProgressSafetyText','RestartButton','CancelPlanButton','PageHistory','OpenReportsButton','ClearHistoryButton','HistoryList','DashboardHistoryList','DashboardHistoryButton','NavHardware','PageHardware','PageAppUpdates','NavAppUpdates','AppUpdatesStatus','ListAppUpdatesButton','UpdateAllAppsButton','HardwareList','CheckDriversButton','PCManagerButton','NavDuplicates','NavUninstaller','HeroUninstallButton','NavAI','PageDuplicates','OpenDuplicatesButton','CheckUpdatesButton','DuplicateStatus','BusyOverlay','OverlayTitle','OverlayMessage','OverlayProgress','OverlayPercent','OverlayContinueButton','ConfirmOverlay','ConfirmList','ConfirmWarning','ConfirmWarningText','ConfirmationCheck','ConfirmBackButton','ConfirmRunButton','SafeCleanButton','UndoAllButton','SafePreviewButton','SafePlanList','SafePlanRunButton','UndoAllDashButton','SafePlanTitle','SafePlanNote','SafeLevelSafeButton','SafeLevelMediumButton','SafeLevelAdvancedButton','Buttons3DSwitch') | ForEach-Object { $ui[$_] = Get-Control $_ }

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
$script:DRRunTaskIds = @()
$script:DRRunCheckWasDue = $false
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
$script:DRShutdownMode = $false
$script:DRAdvancedShutdownOffered = $false
$script:restartCountdownBaseMessage = ''
$analysisMode = $false
$analysisTotal = 0
$analysisDone = 0
$cleanupPreset = 'Custom'
# The level the person last chose. Unticking a box drops the preset to Custom,
# but it must not reveal cookie cleanup on a Safe or Medium sweep.
$cleanupLevel = 'Custom'
$runScanLevel = ''
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
    $ui.PageTitle.Text = switch ($Name) { 'Cleanup' {'Clean my PC'} 'Repair' {'Fix Windows problems'} 'Security' {'Check my security and privacy'} 'Health' {'Check my drives'} 'Memory' {'Check my memory'} 'Speed' {'Speed and space'} 'Hibernate' {'Hibernate'} 'Hardware' {'About my PC'} 'History' {'Cleaning history'} 'Duplicates' {'Find duplicate files'} 'AI' {'Switch off AI'} 'AppUpdates' {'Update my apps'} 'Progress' {'Maintenance progress'} default {$Name} }
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
        $caution = 'This erases every trace of the websites you have visited, in every browser, and then wipes the free space so it cannot be recovered. It removes your history, cookies, site data, saved searches and the record of open tabs. You will be signed out of every website, so make sure you know all your email addresses and passwords first. Close your browsers before you run it. Saved passwords and bookmarks are kept. This cannot be undone. Only tick it if you are sure and ready to do so. DRDirect is not responsible for any sign-in or password you cannot get back.'
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
    $isAdvancedRun = ($script:cleanupPreset -eq 'Advanced')
    $ui.RestartDelayPanel.Visibility = if ($needsRestartHere -or $isAdvancedRun) { 'Visible' } else { 'Collapsed' }
    if ($isAdvancedRun -and -not $script:DRAdvancedShutdownOffered) {
        # The Advanced scan is the one people leave running, so it starts with shutting the PC down afterwards picked.
        $shutItem = @($ui.RestartDelayCombo.Items | Where-Object { [int]$_.Tag -eq -1 } | Select-Object -First 1)
        if ($shutItem.Count) { $ui.RestartDelayCombo.SelectedItem = $shutItem[0] }
        $script:DRAdvancedShutdownOffered = $true
    }
    if ($needsRestartHere) { $warnings.Add('When everything has finished, Windows needs to restart or shut down. Choose below which, and when. You get a countdown first, and you can cancel it or go sooner.') }
    if ($isAdvancedRun) { $warnings.Add('The Advanced scan is set to shut this PC down when it finishes, after a 60 second countdown you can cancel. Pick another choice below if you do not want that.') }
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
$script:DRCheckValidDays = 14
# A check can be run any time. Within 7 days it shows its tick (or warning); from 7 to 30 days a small green dot says it
# passed but a week has gone by; after 30 days, or if it was never run, a big red dot says it needs checking.
$script:DRCheckDueDays = 14
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

function Set-DRBannerBrooms {
    param([string]$Preset)
    # The cleaning banner shows the broom for the scan being run: green for Safe, blue for Medium,
    # and two red ones for Advanced.
    try {
        $ui.BannerBroomSafe.Visibility = if ($Preset -eq 'Safe') { 'Visible' } else { 'Collapsed' }
        $ui.BannerBroomMedium.Visibility = if ($Preset -notin @('Safe','Advanced')) { 'Visible' } else { 'Collapsed' }
        $ui.BannerBroomAdvanced.Visibility = if ($Preset -eq 'Advanced') { 'Visible' } else { 'Collapsed' }
        $ui.BannerBroomAdvanced2.Visibility = if ($Preset -eq 'Advanced') { 'Visible' } else { 'Collapsed' }
    } catch { }
}

# Ticking one more task (Check my security, say) makes the plan "Custom"; the colours, brooms and dust still follow the scan button that was pressed.
function Get-DRRunScanLevel {
    param([string]$Preset)
    if ($Preset -in @('Safe','Medium','Advanced')) { return $Preset }
    if ($script:cleanupLevel -in @('Safe','Medium','Advanced')) { return $script:cleanupLevel }
    return $Preset
}

function Set-ProgressScanLevel {
    param([string]$Preset)
    $barLevel = Get-DRRunScanLevel -Preset $Preset
    Set-DRBannerBrooms -Preset $barLevel

    # The bar in the bottom-left box takes the colour of the scan: bright green, bright blue, bright red.
    try {
        $barInk = switch ($barLevel) { 'Safe' { '#00FF66' } 'Medium' { '#00B3FF' } 'Advanced' { '#FF1744' } default { '#2BE37A' } }
        $ui.RunStripBar.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString($barInk)
    } catch { }

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

function Set-DRScanBroomsAlive {
    param([bool]$Alive, [string]$Preset = '')
    # Only the broom of the scan that is running sweeps; the others stand still, and all stand still when no cleanup runs.
    $sweeping = switch ($Preset) { 'Safe' { @('ScanBroomSafe') } 'Medium' { @('ScanBroomMedium') } 'Advanced' { @('ScanBroomAdvanced','ScanBroomAdvanced2') } default { @() } }
    foreach ($name in 'ScanBroomSafe','ScanBroomMedium','ScanBroomAdvanced','ScanBroomAdvanced2') {
        try {
            $rotate = $ui[$name].RenderTransform
            if ($Alive -and ($sweeping -contains $name)) {
                $swing = New-Object Windows.Media.Animation.DoubleAnimation(-16, 16, [TimeSpan]::FromMilliseconds(650))
                $swing.AutoReverse = $true
                $swing.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
                $swing.EasingFunction = New-Object Windows.Media.Animation.SineEase
                $rotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $swing)
            }
            else { $rotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null) }
        } catch { }
    }
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
    $script:DRShutdownMode = ($script:restartDelaySeconds -lt 0)
    $script:DRAdvancedShutdownOffered = $false
    # A Windows restore point goes first whenever the plan really changes something.
    Remove-DRConflictingSelections
    $selection['safety.restore-point'] = $false
    $changing = @($catalog | Where-Object { $selection[$_.Id] -and $_.Category -in @('Cleanup','Repair','Hibernate','AI') -and $_.Risk -ne 'Guided' -and $_.Id -notin @('ai.check','repair.restore-point') })
    if ($changing.Count -and (@($catalog | Where-Object Id -eq 'safety.restore-point').Count) -and -not $selection['repair.restore-point'] -and (Test-DRAdministrator)) { $selection['safety.restore-point'] = $true }
    $selected = @($catalog | Where-Object { $selection[$_.Id] })
    # Remember what this run really does: a one-click check puts the person's earlier ticks back while it
    # finishes, and those must not make the check ask for a restart.
    $script:DRRunTaskIds = @($selected | ForEach-Object { [string]$_.Id })
    # A Check button that shows a red dot (not checked for 14 days, or never) asks for a restart once its check
    # is done. One that still shows its green tick never does.
    $script:DRRunCheckWasDue = $false
    try {
        $savedChecks = Read-DRCheckStatus
        foreach ($checkId in @($script:DRRunTaskIds | Where-Object { $script:DRCheckMarks.ContainsKey($_) })) {
            if (-not $savedChecks.ContainsKey($checkId) -or ((Get-Date) - $savedChecks[$checkId].Date).TotalDays -gt $script:DRCheckValidDays) { $script:DRRunCheckWasDue = $true }
        }
    } catch { }
    $runQueue.Clear(); foreach ($task in $selected) { $runQueue.Enqueue($task.Id) }
    if (Test-Path -LiteralPath $script:childPidFile) { Remove-Item -LiteralPath $script:childPidFile -Force -ErrorAction SilentlyContinue }
    $runEvents.Clear(); $runStartedAt = Get-Date; $cancelAfterTask = $false
    Set-Variable -Name runStartedAt -Value $runStartedAt -Scope Script
    Set-Variable -Name cancelAfterTask -Value $false -Scope Script
    $ui.ProgressList.Children.Clear(); foreach ($task in $selected) { $ui.ProgressList.Children.Add((New-ProgressRow $task)) | Out-Null }
    if ($ui.CleaningAnimation) { $ui.CleaningAnimation.Visibility='Visible' }
    $script:runScanLevel = Get-DRRunScanLevel -Preset $script:cleanupPreset
    Set-DRScanBroomsAlive $true -Preset $script:runScanLevel
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
    # After any run, Windows protection (firewall, Defender real-time, Windows Update) is checked and switched
    # back on if something left it off. Another antivirus or firewall in charge, or a policy, is left alone.
    if (-not $TestRoot -and (Test-DRAdministrator)) {
        try {
            foreach ($securityEvent in @(Repair-DRSecurityProtection -TaskId 'security.after-clean')) {
                if ($securityEvent -and $securityEvent.State) { $runEvents.Add($securityEvent) }
            }
        } catch { }
    }
    [string[]]$selectedIds = @(
        $catalog |
            Where-Object { $script:DRRunTaskIds -contains $_.Id } |
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
    Set-DRScanBroomsAlive $false
    if (-not $cancelAfterTask) { Invoke-DRCleanReveal -TaskCount $selectedIds.Count -ChecksOnly:([bool]$onlyChecks) }
    $needsRestart = (-not $cancelAfterTask) -and ((@($selectedIds | Where-Object { $script:DRNoRestartTaskIds -notcontains $_ }).Count -gt 0) -or $script:DRRunCheckWasDue)
    if ($script:DRShutdownMode -and -not $cancelAfterTask) { $needsRestart = $true }

    $ui.RestartButton.Visibility = if ($needsRestart) {
        'Visible'
    }
    else {
        'Collapsed'
    }
    $ui.RunRestartPanel.Visibility = 'Collapsed'
    $ui.RestartButton.IsEnabled = $true
    $ui.RestartButton.Content = $(if ($script:DRShutdownMode) { 'Shut down now' } else { 'Restart now' })
    if ($needsRestart) {
        $ui.CancelPlanButton.Content = $(if ($script:DRShutdownMode) { 'Cancel shut down' } else { 'Restart later' })
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
        if ($script:DRShutdownMode) {
            Start-DRRestartCountdown -Seconds 60 -BaseMessage $ui.ProgressSafetyText.Text -Shutdown
        } elseif ($script:restartDelaySeconds -gt 0) {
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
        # The dust on the Clean my PC broom only drifts while a Safe, Medium or Advanced cleaning is running.
        $dustWanted = if ($busyNow -and ($script:runScanLevel -in @('Safe','Medium','Advanced'))) { 'Visible' } else { 'Collapsed' }
        if ($ui.NavCleanDust.Visibility -ne $dustWanted) { $ui.NavCleanDust.Visibility = $dustWanted }
        $scanDustOn = if ($busyNow) { switch ($script:runScanLevel) { 'Safe' { @('ScanDustSafe') } 'Medium' { @('ScanDustMedium') } 'Advanced' { @('ScanDustAdvanced','ScanDustAdvanced2') } default { @() } } } else { @() }
        foreach ($dustName in 'ScanDustSafe','ScanDustMedium','ScanDustAdvanced','ScanDustAdvanced2') {
            $dustVis = if ($scanDustOn -contains $dustName) { 'Visible' } else { 'Collapsed' }
            if ($ui[$dustName].Visibility -ne $dustVis) { $ui[$dustName].Visibility = $dustVis }
        }
        if ($busyNow) {
            $ui.RunStrip.Visibility = 'Visible'
            $ui.RunStripTitle.Text = 'Working... ' + $ui.ProgressPercent.Text
            $ui.RunStripDetail.Text = [string]$ui.ProgressMessage.Text
            $ui.RunStripBar.Value = [double]$ui.OverallProgress.Value
            $ui.RunStripHint.Visibility = if ($script:currentCategory -eq 'Progress') { 'Collapsed' } else { 'Visible' }
            # Cleaning jobs in the same run get their own line, so a long repair doesn't hide them.
            $cleanIds = @($catalog | Where-Object { $selection[$_.Id] -and $_.Category -eq 'Cleanup' } | ForEach-Object { [string]$_.Id })
            if ($cleanIds.Count -gt 0) {
                $cleanLeft = @($runQueue | Where-Object { $cleanIds -contains [string]$_ }).Count
                $cleanNow = $activeTaskId -and ($cleanIds -contains [string]$activeTaskId)
                if ($cleanNow) { $cleanLeft++ }
                $cleanDone = [Math]::Max(0, $cleanIds.Count - $cleanLeft)
                $cleanText = 'Cleaning: ' + $cleanDone + ' of ' + $cleanIds.Count + ' cleanup jobs done'
                if ($cleanNow) { $cleanText += ' ' + [char]0x00B7 + ' now ' + [string]$ui.CleaningCaption.Text }
                elseif ($cleanLeft -gt 0) { $cleanText += ' ' + [char]0x00B7 + ' waiting its turn' }
                $ui.RunStripCleaning.Text = $cleanText; $ui.RunStripCleaning.Visibility = 'Visible'
            } else { $ui.RunStripCleaning.Visibility = 'Collapsed' }
        } elseif ($script:DRFinishedUnseen) {
            $ui.RunStrip.Visibility = 'Visible'
            $ui.RunStripTitle.Text = [string][char]0x2714 + '  Finished. Click to see it'
            $ui.RunStripDetail.Text = [string]$ui.ProgressHeading.Text
            $ui.RunStripBar.Value = 100
            $ui.RunStripCleaning.Visibility = 'Collapsed'; $ui.RunStripHint.Visibility = 'Collapsed'
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
    try { $choice = $ui.RunRestartCombo.SelectedItem; if ($choice) { $script:restartDelaySeconds = [int]$choice.Tag; $script:DRShutdownMode = ($script:restartDelaySeconds -lt 0) } } catch { }
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

$pkgs = @(); $idCol = -1; $verCol = -1; $availCol = -1; $srcCol = -1; $inTable = $false
foreach ($l in $raw) {
    $l = ($l -split "`r")[-1]                       # drop spinner prefixes
    if ($l -match '^Name\s+Id\s+Version') {
        if ($pkgs.Count -gt 0) { break }            # 2nd table = needs explicit targeting
        $idCol = $l.IndexOf('Id'); $verCol = $l.IndexOf('Version'); $inTable = $false
        $availCol = $l.IndexOf('Available'); $srcCol = $l.IndexOf('Source')
        continue
    }
    if ($idCol -ge 0 -and $l -match '^-{5,}') { $inTable = $true; continue }
    if ($inTable) {
        if ($l -match 'upgrades? available' -or $l.Trim() -eq '') { $inTable = $false; continue }
        if ($l.Length -gt $verCol) {
            $offered = ''
            if ($availCol -gt $verCol -and $l.Length -gt $availCol) {
                $end = if ($srcCol -gt $availCol -and $l.Length -ge $srcCol) { $srcCol } else { $l.Length }
                $offered = $l.Substring($availCol, $end - $availCol).Trim()
            }
            $pkgs += [pscustomobject]@{
                Name      = $l.Substring(0, $idCol).Trim()
                Id        = $l.Substring($idCol, $verCol - $idCol).Trim()
                Available = $offered
            }
        }
    }
}

# Windows Update or an installer can put a newer PowerShell 7 on this PC than winget has on record, and winget
# then offers a version that is already here. Compare with the copy that is really installed and leave it be.
foreach ($ps7 in @($pkgs | Where-Object { $_.Id -eq 'Microsoft.PowerShell' -and $_.Available })) {
    try {
        $pwshExe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = (Get-Command pwsh.exe -ErrorAction Stop).Source }
        $toVersion = { param($t) $n = @(($t -replace '[^0-9.].*$', '') -split '\.') + '0', '0', '0', '0'; [version]($n[0..3] -join '.') }
        $have = & $toVersion (Get-Item -LiteralPath $pwshExe).VersionInfo.ProductVersion
        $offer = & $toVersion $ps7.Available
        if ($have -ge $offer) {
            Write-Host (RGB 150 150 255 "⏭️  $($ps7.Name) - version $have is already installed, winget just has not caught up")
            $pkgs = @($pkgs | Where-Object { $_.Id -ne 'Microsoft.PowerShell' })
        }
    } catch { }
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
            'Clear-DRStaleTemp', 'Get-DRFileHashWithRetry', 'Invoke-DRFeedWeb', 'Update-DRUninstallerFromFeed'
        $code = ($names | ForEach-Object { "function $_ {`r`n$((Get-Command $_ -CommandType Function).Definition)`r`n}" }) -join "`r`n"

        $script:DRUnUpdateRunspace = [RunspaceFactory]::CreateRunspace()
        $script:DRUnUpdateRunspace.Open()
        foreach ($name in 'DRUpdateFeed', 'DRUpdateRef', 'DRUpdateHeaders', 'DRUpdateMirror', 'DRUpdatePublicKey') {
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
        $tickSamples[$i] = [int16](1000 * $envelope * ([math]::Sin(2 * [math]::PI * 330 * $t) + 0.8 * [math]::Sin(2 * [math]::PI * 165 * $t)))
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
    $ui.NavModeText.Text = if ($Simple) { '＋  Show all tools' } else { '－  Show fewer tools' }
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
$ui.NavScroll.Add_ScrollChanged({ $ui.NavMoreUp.Visibility = if ($ui.NavScroll.VerticalOffset -gt 4) { 'Visible' } else { 'Collapsed' } })
$ui.NavMoreUp.Add_MouseLeftButtonUp({ $ui.NavScroll.ScrollToVerticalOffset(0) })

# "More above" / "More below" pills for the other pages that scroll (the Dashboard and the long lists), the same as the plan list has.
function Add-DRScrollPills {
    param($Scroller)
    if (-not $Scroller) { return }
    $parent = [Windows.LogicalTreeHelper]::GetParent($Scroller)
    if ($parent -isnot [Windows.Controls.Grid]) { return }
    $ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'
    $make = {
        param([string]$Text, [string]$Vertical, [string]$Tip)
        [Windows.Markup.XamlReader]::Parse(("<Border $ns Visibility=""Collapsed"" VerticalAlignment=""$Vertical"" HorizontalAlignment=""Center"" Margin=""0,8,0,8"" Padding=""22,7"" CornerRadius=""16"" Cursor=""Hand"" ToolTip=""$Tip"" Panel.ZIndex=""50"">" +
            '<Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#5B9BFF" Offset="0"/><GradientStop Color="#1F5FE0" Offset="1"/></LinearGradientBrush></Border.Background>' +
            '<Border.Effect><DropShadowEffect Color="#0A1A4A" BlurRadius="10" ShadowDepth="3" Direction="270" Opacity="0.55"/></Border.Effect>' +
            "<TextBlock Text=""$Text"" Foreground=""White"" FontSize=""14"" FontWeight=""Bold""/></Border>"))
    }
    $up = & $make ([string][char]0x25B2 + '   More above') 'Top' 'Scroll up'
    $down = & $make ([string][char]0x25BC + '   More below') 'Bottom' 'Scroll down'
    foreach ($pill in @($up, $down)) {
        [Windows.Controls.Grid]::SetRow($pill, [Windows.Controls.Grid]::GetRow($Scroller))
        [Windows.Controls.Grid]::SetColumn($pill, [Windows.Controls.Grid]::GetColumn($Scroller))
        [Windows.Controls.Grid]::SetRowSpan($pill, [Windows.Controls.Grid]::GetRowSpan($Scroller))
        [Windows.Controls.Grid]::SetColumnSpan($pill, [Windows.Controls.Grid]::GetColumnSpan($Scroller))
        [void]$parent.Children.Add($pill)
    }
    $update = {
        $shown = $Scroller.IsVisible
        $up.Visibility = if ($shown -and $Scroller.VerticalOffset -gt 4) { 'Visible' } else { 'Collapsed' }
        $down.Visibility = if ($shown -and $Scroller.ScrollableHeight -gt 4 -and $Scroller.VerticalOffset -lt ($Scroller.ScrollableHeight - 4)) { 'Visible' } else { 'Collapsed' }
    }.GetNewClosure()
    $Scroller.Add_ScrollChanged($update)
    $Scroller.Add_IsVisibleChanged($update)
    $Scroller.Add_SizeChanged($update)
    & $update
    $up.Add_MouseLeftButtonUp({ $Scroller.ScrollToVerticalOffset([Math]::Max(0, $Scroller.VerticalOffset - ($Scroller.ViewportHeight * 0.85))) }.GetNewClosure())
    $down.Add_MouseLeftButtonUp({ $Scroller.ScrollToVerticalOffset([Math]::Min($Scroller.ScrollableHeight, $Scroller.VerticalOffset + ($Scroller.ViewportHeight * 0.85))) }.GetNewClosure())
}
try {
    Add-DRScrollPills $ui.PageDashboard
    foreach ($listName in 'HardwareList', 'ProgressList') {
        $listBox = $window.FindName($listName)
        if ($listBox) { Add-DRScrollPills ([Windows.LogicalTreeHelper]::GetParent($listBox)) }
    }
} catch { }
# The plan list gets the same pills: one page up or down at a time
$ui.PlanScroll.Add_ScrollChanged({
    $sv = $ui.PlanScroll
    $ui.PlanMoreUp.Visibility = if ($sv.VerticalOffset -gt 4) { 'Visible' } else { 'Collapsed' }
    $ui.PlanMoreDown.Visibility = if (($sv.ScrollableHeight -gt 4) -and ($sv.VerticalOffset -lt ($sv.ScrollableHeight - 4))) { 'Visible' } else { 'Collapsed' }
})
$ui.PlanMoreUp.Add_MouseLeftButtonUp({ $sv = $ui.PlanScroll; $sv.ScrollToVerticalOffset([Math]::Max(0, $sv.VerticalOffset - ($sv.ViewportHeight * 0.85))) })
$ui.PlanMoreDown.Add_MouseLeftButtonUp({ $sv = $ui.PlanScroll; $sv.ScrollToVerticalOffset([Math]::Min($sv.ScrollableHeight, $sv.VerticalOffset + ($sv.ViewportHeight * 0.85))) })
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

# The taskbar icon gets an orange badge and flashes until the window is opened, so a waiting update shows even when the Cleaner is behind other windows.
if (-not ('DRTaskbarFlash' -as [type])) {
    Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class DRTaskbarFlash {
    [StructLayout(LayoutKind.Sequential)] public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
    public static void Flash(IntPtr hwnd) {
        FLASHWINFO info = new FLASHWINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        info.hwnd = hwnd; info.dwFlags = 2 | 12; info.uCount = uint.MaxValue; info.dwTimeout = 0;
        FlashWindowEx(ref info);
    }
}
"@
}
function Set-DRTaskbarUpdateBadge {
    param([bool]$On)
    try {
        if (-not $window.TaskbarItemInfo) { $window.TaskbarItemInfo = New-Object Windows.Shell.TaskbarItemInfo }
        if (-not $On) { $window.TaskbarItemInfo.Overlay = $null; $window.TaskbarItemInfo.Description = ''; return }
        $visual = New-Object Windows.Media.DrawingVisual
        $dc = $visual.RenderOpen()
        $fill = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#FF8A00'))
        $dc.DrawEllipse($fill, (New-Object Windows.Media.Pen ([Windows.Media.Brushes]::White), 2), (New-Object Windows.Point 16, 16), 14, 14)
        $face = New-Object Windows.Media.Typeface 'Segoe UI'
        $mark = New-Object Windows.Media.FormattedText '!', ([Globalization.CultureInfo]::InvariantCulture), ([Windows.FlowDirection]::LeftToRight), $face, 22, ([Windows.Media.Brushes]::White), 1.0
        $mark.SetFontWeight([Windows.FontWeights]::Bold)
        $dc.DrawText($mark, (New-Object Windows.Point (16 - $mark.Width / 2), (16 - $mark.Height / 2)))
        $dc.Close()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap 32, 32, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        $bitmap.Freeze()
        $window.TaskbarItemInfo.Overlay = $bitmap
        $window.TaskbarItemInfo.Description = 'A new version of DRDirect PC Cleaner is ready'
        $handle = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
        if ($handle -ne [IntPtr]::Zero) { [DRTaskbarFlash]::Flash($handle) }
    } catch { }
}
# A waiting update must be impossible to miss: both update buttons flash
# green and yellow, pulse in size and glow until it is installed.
$script:DRUpdateFlashOn = $false
$script:DRUpdateFlashSaved = @{}
function Start-DRUpdateFlash {
    if ($script:DRUpdateFlashOn) { return }
    $script:DRUpdateFlashOn = $true
    $script:DRUpdateFlashSaved = @{}
    Set-DRTaskbarUpdateBadge $true
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
    Set-DRTaskbarUpdateBadge $false
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
        'A kind and respectful request: if possible, please write down the e-mail address and password you use for every website or service you sign up with, and keep them in a safe place. Recovering a lost account is not always possible. This is important. Thank you.',
        '',
        '- DRDirect'
    ) -join [Environment]::NewLine
    # A plain message box draws emoji in white, so the thumbs up is a coloured Segoe icon glyph in our own small window.
    $win = New-Object Windows.Window
    $win.Title = 'Please read first'
    $win.SizeToContent = 'WidthAndHeight'
    $win.MaxWidth = 560
    $win.ResizeMode = 'NoResize'
    $win.WindowStartupLocation = 'CenterScreen'
    $win.Topmost = $true
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = '24,20,24,16'
    $body = New-Object Windows.Controls.TextBlock
    $body.Text = $text
    $body.TextWrapping = 'Wrap'
    $body.FontSize = 14
    $panel.Children.Add($body) | Out-Null
    $thumb = New-Object Windows.Controls.TextBlock
    $thumb.Text = [string][char]0xE8E1
    $thumb.FontFamily = New-Object Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    $thumb.FontSize = 34
    $thumb.Foreground = [Windows.Media.Brushes]::DarkOrange
    $thumb.HorizontalAlignment = 'Left'
    $thumb.Margin = '0,8,0,0'
    $panel.Children.Add($thumb) | Out-Null
    $ok = New-Object Windows.Controls.Button
    $ok.Content = 'OK'
    $ok.Width = 90
    $ok.Padding = '0,5,0,5'
    $ok.HorizontalAlignment = 'Right'
    $ok.Margin = '0,8,0,0'
    $ok.IsDefault = $true
    $ok.IsCancel = $true
    $panel.Children.Add($ok) | Out-Null
    $win.Content = $panel
    [void]$win.ShowDialog()
}
# Owner-only: clears the crash history Reliability Monitor draws. Only a salted hash of the password is kept here.
$script:DRResetSalt = 'jzY6qABxSZRWhKhIaB+DCQ=='
$script:DRResetHash = 'FrOK88j12U/O7Fw7NbMoaes6GOOHSrAo0sspW0/FKF4='
function Test-DRResetPassword {
    param([string]$Password)
    if ([string]::IsNullOrEmpty($Password)) { return $false }
    $derive = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, [Convert]::FromBase64String($script:DRResetSalt), 100000)
    $given = $derive.GetBytes(32)
    $expected = [Convert]::FromBase64String($script:DRResetHash)
    $diff = 0
    for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($given[$i] -bxor $expected[$i]) }
    return ($diff -eq 0)
}
# The owner's windows show normally in remote sessions, so the person working remotely can see and use them.
if (-not ('DRCapture' -as [type])) {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class DRCapture { [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity); }'
}
function Set-DRNoCapture {
    param($TargetWindow)
    try {
        $handle = (New-Object Windows.Interop.WindowInteropHelper($TargetWindow)).EnsureHandle()
        [void][DRCapture]::SetWindowDisplayAffinity($handle, 0)
    } catch { }
}
function Read-DRResetPassword {
    $dialog = New-Object Windows.Window
    $dialog.Title = 'Owner password'
    $dialog.SizeToContent = 'WidthAndHeight'
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.ResizeMode = 'NoResize'
    Set-DRNoCapture $dialog
    try { $dialog.Owner = $window } catch { }
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = '20'
    $label = New-Object Windows.Controls.TextBlock
    $label.Text = 'Enter the owner password:'
    $label.Margin = '0,0,0,10'
    $box = New-Object Windows.Controls.PasswordBox
    $box.MinWidth = 280
    $box.Margin = '0,0,0,14'
    $ok = New-Object Windows.Controls.Button
    $ok.Content = 'OK'
    $ok.IsDefault = $true
    $ok.Padding = '18,5'
    $ok.HorizontalAlignment = 'Right'
    $ok.Add_Click({ $dialog.DialogResult = $true })
    [void]$panel.Children.Add($label); [void]$panel.Children.Add($box); [void]$panel.Children.Add($ok)
    $dialog.Content = $panel
    $dialog.Add_ContentRendered({ $box.Focus() | Out-Null })
    if ($dialog.ShowDialog()) { return $box.Password }
    return $null
}
function Clear-DRReliabilityHistory {
    # Every path hangs off these folders; stop if any is missing.
    foreach ($name in 'ProgramData','SystemDrive','SystemRoot') {
        if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is not set - nothing was deleted." }
    }
    $werRoots = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER'),
        (Join-Path $env:SystemRoot 'System32\config\systemprofile\AppData\Local\Microsoft\Windows\WER')
    )
    foreach ($profile in (Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) {
        $werRoots += (Join-Path $profile.FullName 'AppData\Local\Microsoft\Windows\WER')
    }
    try { Stop-Service -Name WerSvc -Force -ErrorAction Stop } catch { }
    foreach ($root in $werRoots) {
        foreach ($sub in 'ReportArchive','ReportQueue') {
            $folder = Join-Path $root $sub
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
            # Only the report folders inside a WER folder are emptied, never the folder itself.
            if ((Split-Path -Leaf (Split-Path -Parent $folder)) -ne 'WER') { continue }
            Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $failed = @()
    foreach ($log in 'Application','System','Setup') {
        & wevtutil.exe cl $log 2>$null
        if ($LASTEXITCODE -ne 0) { $failed += $log }
    }
    foreach ($log in @(& wevtutil.exe el | Where-Object { $_ -match 'Reliab' })) { & wevtutil.exe cl $log 2>$null }
    return $failed
}
function Invoke-DRReliabilityReset {
    if (-not (Test-DRAdministrator)) {
        [void][Windows.MessageBox]::Show('Open the Cleaner as administrator first - clearing the logs needs it.', 'Reset Reliability Monitor', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
        return
    }
    $sure = [Windows.MessageBox]::Show("This wipes the crash reports and Windows event logs on THIS PC, so Reliability Monitor starts again with a clean chart.`n`nIt cannot be undone. Files, programs, passwords and logins are not touched.`n`nClear it now?", 'Reset Reliability Monitor', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning)
    if ($sure -ne [Windows.MessageBoxResult]::Yes) { return }
    try {
        $failed = @(Clear-DRReliabilityHistory)
        $msg = if ($failed.Count) { 'Could not clear: ' + ($failed -join ', ') + '.' } else { 'Done. Restart the PC, then open Reliability Monitor again. The chart can take up to 24 hours to redraw.' }
    } catch { $msg = "Stopped: $($_.Exception.Message)" }
    [void][Windows.MessageBox]::Show($msg, 'Reset Reliability Monitor', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
}
# The owner's menu, shown only after the password: the Windows monitors used when helping a customer, and the reset.
function Show-DROwnerMenu {
    $menu = New-Object Windows.Window
    $menu.Title = 'Owner tools'
    $menu.SizeToContent = 'WidthAndHeight'
    $menu.WindowStartupLocation = 'CenterOwner'
    $menu.ResizeMode = 'NoResize'
    Set-DRNoCapture $menu
    try { $menu.Owner = $window } catch { }
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = '20'
    $items = @(
        @{ Text = '1.  Performance Monitor  -  live line graphs';                 Args = '' },
        @{ Text = '2.  Resource Monitor  -  what is slowing the PC down';         Args = '/res' },
        @{ Text = '3.  Reliability Monitor  -  day-by-day crash chart';           Args = '/rel' },
        @{ Text = '4.  Health report  -  60-second check, warnings at the top';   Args = '/report' }
    )
    foreach ($item in $items) {
        $button = New-Object Windows.Controls.Button
        $button.Content = $item.Text
        $button.Tag = $item.Args
        $button.Padding = '14,8'
        $button.Margin = '0,0,0,8'
        $button.HorizontalContentAlignment = 'Left'
        $button.MinWidth = 380
        $button.Add_Click({
            param($sender, $e)
            try {
                if ([string]::IsNullOrEmpty([string]$sender.Tag)) { Start-Process -FilePath 'perfmon.exe' } else { Start-Process -FilePath 'perfmon.exe' -ArgumentList ([string]$sender.Tag) }
            } catch { }
        })
        [void]$panel.Children.Add($button)
    }
    $reset = New-Object Windows.Controls.Button
    $reset.Content = '5.  Reset Reliability Monitor...'
    $reset.Padding = '14,8'
    $reset.Margin = '0,10,0,0'
    $reset.HorizontalContentAlignment = 'Left'
    $reset.Add_Click({ Invoke-DRReliabilityReset })
    [void]$panel.Children.Add($reset)
    $menu.Content = $panel
    [void]$menu.ShowDialog()
}
function Invoke-DROwnerEntry {
    $typed = Read-DRResetPassword
    if ($null -eq $typed) { return }
    if (-not (Test-DRResetPassword $typed)) {
        [void][Windows.MessageBox]::Show('That password is not right.', 'Owner tools', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning)
        return
    }
    Show-DROwnerMenu
}
# Anywhere else: clicking the version text five times in a row opens the password box.
$script:DROwnerClicks = 0
$script:DROwnerFirstClick = [datetime]::MinValue
$ui.VersionText.Add_MouseLeftButtonUp({
    $now = Get-Date
    if (($now - $script:DROwnerFirstClick).TotalSeconds -gt 4) { $script:DROwnerFirstClick = $now; $script:DROwnerClicks = 0 }
    $script:DROwnerClicks++
    if ($script:DROwnerClicks -lt 5) { return }
    $script:DROwnerClicks = 0
    Invoke-DROwnerEntry
})
# The blue strip shows only on the owner's own PCs (matched by hashed PC ID, never the ID itself); everywhere else the five clicks are the way in.
$script:DROwnerPcHashes = @('5CA7C38401F6CC2DB76FC1AA3C26895A2E789A7421CB495C7169FC37E0BC2709', '97E60D52D0832D37D20CA488269FB7470875FB4167859A78D4243C245666B2CB')
function Test-DROwnerPc {
    try {
        foreach ($id in @(Get-DRThisPcBlockIds)) {
            $hash = ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$id)) | ForEach-Object { $_.ToString('X2') }) -join ''
            if ($script:DROwnerPcHashes -contains $hash) { return $true }
        }
    } catch { }
    return $false
}
$ui.ResetReliabilityButton.Visibility = 'Visible'
$ui.ResetReliabilityButton.Add_MouseLeftButtonUp({ Invoke-DROwnerEntry })
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
        $ui.RestartButton.Content = $(if ($script:DRShutdownMode) { 'Shut down now' } else { 'Restart now' })
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
    param([ValidateRange(0,60)][int]$DelaySeconds = 5, [switch]$Shutdown)

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

    $comment = if ($Shutdown) { 'DRDirect PC Cleaner maintenance completed. Shutting down as you asked.' } else { 'DRDirect PC Cleaner maintenance completed. Restarting to finish Windows maintenance.' }
    $mode = if ($Shutdown) { '/s' } else { '/r' }
    $argumentLine = '{2} /t {0} /f /c "{1}"' -f $DelaySeconds, $comment.Replace('"', "'"), $mode
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
        [string]$BaseMessage = '',
        [switch]$Shutdown
    )

    Stop-DRRestartCountdown
    $script:DRShutdownMode = [bool]$Shutdown
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
        $ui.ProgressSafetyText.Text = $prefix + $(if ($script:DRShutdownMode) { "Windows will shut down in $clock because the clean is done. Save your work. Click Shut down now to go sooner, or Cancel shut down to stop it." } else { "Windows will restart in $clock to finish the repairs. Save your work. Click Restart now to go sooner, or Restart later to cancel." })
        $ui.RestartButton.Content = "$(if ($script:DRShutdownMode) { 'Shut down now' } else { 'Restart now' }) ($clock)"
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
            $ui.ProgressSafetyText.Text = $prefix + $(if ($script:DRShutdownMode) { "Windows will shut down in $clock because the clean is done. Save your work. Click Shut down now to go sooner, or Cancel shut down to stop it." } else { "Windows will restart in $clock to finish the repairs. Save your work. Click Restart now to go sooner, or Restart later to cancel." })
            $ui.RestartButton.Content = "$(if ($script:DRShutdownMode) { 'Shut down now' } else { 'Restart now' }) ($clock)"

            if (@(1800, 600, 300, 60) -contains $script:restartSecondsLeft) {
                Show-DRRestartNotice -Urgent:($script:restartSecondsLeft -le 300)
            }
            return
        }

        Stop-DRRestartCountdown
        $ui.RestartButton.IsEnabled = $false
        $ui.RestartButton.Content = $(if ($script:DRShutdownMode) { 'Shutting down…' } else { 'Restarting…' })
        $ui.ProgressSafetyText.Text = $(if ($script:DRShutdownMode) { 'The countdown has finished. Windows is shutting down now.' } else { 'The countdown has finished. Windows is restarting now.' })

        if ($TestMode) {
            $ui.RestartButton.IsEnabled = $true
            $ui.RestartButton.Content = $(if ($script:DRShutdownMode) { 'Shut down now' } else { 'Restart now' })
            $ui.ProgressSafetyText.Text = 'TEST MODE: the automatic restart was not performed.'
            return
        }

        try {
            Invoke-DRDirectRestartNow -DelaySeconds 0 -Shutdown:$script:DRShutdownMode
        }
        catch {
            $ui.RestartButton.IsEnabled = $true
            $ui.RestartButton.Content = $(if ($script:DRShutdownMode) { 'Shut down now' } else { 'Restart now' })
            $message = 'Automatic restart failed: ' + $_.Exception.Message + "`n`nPlease restart Windows manually from the Start menu."
            $ui.ProgressSafetyText.Text = $message
            [Windows.MessageBox]::Show($message, 'DRDirect PC Cleaner', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
        }
    })

    $timer.Start()
}

$ui.RestartButton.Add_Click({
    $answer = [Windows.MessageBox]::Show(
        $(if ($script:DRShutdownMode) { 'Save all open work before shutting down. Shut down this PC now?' } else { 'Save all open work before restarting. Restart this PC now?' }),
        $(if ($script:DRShutdownMode) { 'Confirm shut down' } else { 'Confirm restart' }),
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
        $ui.RestartButton.Content = $(if ($script:DRShutdownMode) { 'Shutting down…' } else { 'Restarting…' })
        $ui.ProgressSafetyText.Text = $(if ($script:DRShutdownMode) { 'Windows shut down scheduled for 5 seconds. Save any remaining work now.' } else { 'Windows restart scheduled for 5 seconds. Save any remaining work now.' })
        Invoke-DRDirectRestartNow -DelaySeconds 5 -Shutdown:$script:DRShutdownMode
    }
    catch {
        $ui.RestartButton.IsEnabled = $true
        $ui.RestartButton.Content = $(if ($script:DRShutdownMode) { 'Shut down now' } else { 'Restart now' })
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

    # The Finder's Back to the Cleaner button starts the Cleaner again if it was closed, so it needs to know where it is.
    try {
        $cleanerExe = Get-DRCleanerLauncherPath
        if ($cleanerExe) {
            if (-not (Test-Path -LiteralPath 'HKCU:\Software\DRDirect\PC Cleaner')) { New-Item -Path 'HKCU:\Software\DRDirect\PC Cleaner' -Force | Out-Null }
            Set-ItemProperty -LiteralPath 'HKCU:\Software\DRDirect\PC Cleaner' -Name 'CleanerExe' -Value ([string]$cleanerExe)
        }
    } catch { }

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
                $script:DRForceClose = $true
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
        $names = 'Get-DRUpdateRoot', 'Clear-DRStaleTemp', 'Get-DRFileHashWithRetry', 'Invoke-DRFeedWeb', 'Install-DRUpdate'
        $code = ($names | ForEach-Object { "function $_ {`r`n$((Get-Command $_ -CommandType Function).Definition)`r`n}" }) -join "`r`n"

        $script:DRInstallRunspace = [RunspaceFactory]::CreateRunspace()
        $script:DRInstallRunspace.Open()
        foreach ($name in 'DRUpdateFeed', 'DRUpdateRef', 'DRUpdateHeaders', 'DRUpdateMirror', 'DRUpdatableFiles') {
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
# The update icon by the clock. A closed program cannot mark its own taskbar icon, so a small helper
# (offered once, switched off from its own right-click menu) sits in the tray and turns yellow when a
# newer version is waiting. The helper's script is kept here so every update can refresh it.
$script:DRTrayScriptText = @'
# A small tray icon for DRDirect PC Cleaner. It sits by the clock, turns yellow when a newer
# version is waiting, and opens the Cleaner when clicked. It only reads the version number;
# nothing is downloaded or installed from here.
param([string]$SimulateOffered)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$ErrorActionPreference = 'Stop'

$mutex = New-Object Threading.Mutex($false, 'Local\DRDirectCleanerTray')
if (-not $mutex.WaitOne(0)) { return }

$root = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner'
$exe = Join-Path $env:ProgramFiles 'DRDirect PC Cleaner\DRDirect PC Cleaner.exe'
$installedFile = Join-Path $root 'Scripts\installed.json'
$stateFile = Join-Path $root 'tray_last.txt'
$logFile = Join-Path $root 'tray_log.txt'
$script:LastLogged = ''
function Write-TrayLog {
    param([string]$Text)
    # Only changes are written, and the file is kept short.
    if ($Text -eq $script:LastLogged) { return }
    $script:LastLogged = $Text
    try {
        if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 50KB) { Remove-Item -LiteralPath $logFile -Force }
        Add-Content -LiteralPath $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
    } catch { }
}

# The Cleaner's own icon, plus a copy with a yellow mark for "update ready".
$baseIcon = if (Test-Path -LiteralPath $exe) { [Drawing.Icon]::ExtractAssociatedIcon($exe) } else { [Drawing.SystemIcons]::Application }
$baseBitmap = New-Object Drawing.Bitmap 32, 32
$graphics = [Drawing.Graphics]::FromImage($baseBitmap)
$graphics.InterpolationMode = 'HighQualityBicubic'
$graphics.DrawImage($baseIcon.ToBitmap(), 0, 0, 32, 32)
$graphics.Dispose()
$markBitmap = $baseBitmap.Clone()
$graphics = [Drawing.Graphics]::FromImage($markBitmap)
$graphics.SmoothingMode = 'AntiAlias'
$graphics.FillEllipse([Drawing.Brushes]::Gold, 15, 15, 16, 16)
$graphics.DrawEllipse((New-Object Drawing.Pen ([Drawing.Color]::FromArgb(60, 40, 0)), 2), 15, 15, 16, 16)
$graphics.Dispose()
$normalIcon = [Drawing.Icon]::FromHandle($baseBitmap.GetHicon())
$markedIcon = [Drawing.Icon]::FromHandle($markBitmap.GetHicon())

function Get-OfferedVersion {
    if ($SimulateOffered) { return [version]$SimulateOffered }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 `
            -Uri 'https://api.github.com/repos/Phears/drdirect-cleaner-updates/contents/update_manifest.json?ref=main' `
            -Headers @{ Accept = 'application/vnd.github.raw'; 'User-Agent' = 'DRDirect-Tray' }
        $text = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString([byte[]]$response.Content) } else { [string]$response.Content }
        return [version](([string]($text.TrimStart([char]0xFEFF) | ConvertFrom-Json).version).Trim())
    } catch { return $null }
}

function Get-InstalledVersion {
    try { return [version]([string](Get-Content -LiteralPath $installedFile -Raw | ConvertFrom-Json).version) } catch { return $null }
}

$notify = New-Object Windows.Forms.NotifyIcon
$notify.Icon = $normalIcon
$notify.Text = 'DRDirect PC Cleaner'
$notify.Visible = $true

# The Cleaner's launcher refuses to start when it inherits another PyInstaller program's markers
# (this helper may have been started by the Cleaner), so it is asked to treat this as a fresh start.
# The Cleaner needs administrator rights, so it is started the normal way and Windows shows its usual box.
$script:LastOpened = [datetime]::MinValue
function Open-Cleaner {
    # A double-click sends two clicks; open it once.
    if (((Get-Date) - $script:LastOpened).TotalSeconds -lt 4) { return }
    $script:LastOpened = Get-Date
    try {
        [Environment]::SetEnvironmentVariable('PYINSTALLER_RESET_ENVIRONMENT', '1', 'Process')
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
    } catch { }
    finally { [Environment]::SetEnvironmentVariable('PYINSTALLER_RESET_ENVIRONMENT', $null, 'Process') }
}

$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Open DRDirect PC Cleaner', $null, { Open-Cleaner })
[void]$menu.Items.Add('Close this icon', $null, { $notify.Visible = $false; [Windows.Forms.Application]::Exit() })
[void]$menu.Items.Add('Stop starting with Windows', $null, {
    try { Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) 'DRDirect Tray.lnk') -Force -ErrorAction SilentlyContinue } catch { }
    try { Set-Content -LiteralPath (Join-Path $root 'tray_choice.txt') -Value 'no' -Encoding ASCII } catch { }
    $notify.Visible = $false
    [Windows.Forms.Application]::Exit()
})
$notify.ContextMenuStrip = $menu
$notify.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Open-Cleaner } })
$notify.Add_BalloonTipClicked({ Open-Cleaner })

# The network check is every 30 minutes; the installed version is re-read every minute, so the yellow
# mark clears soon after an update is installed.
$script:OfferedVersion = $null
$script:Ticks = 0
function Update-Tray {
    $installed = Get-InstalledVersion
    $offered = $script:OfferedVersion
    Write-TrayLog ("installed=$installed offered=$offered")
    if ($installed -and $offered -and $offered -gt $installed) {
        $notify.Icon = $markedIcon
        $notify.Text = "DRDirect PC Cleaner: update ready ($offered)"
        $last = if (Test-Path -LiteralPath $stateFile) { (Get-Content -LiteralPath $stateFile -Raw).Trim() } else { '' }
        if ($last -ne $offered.ToString()) {
            $notify.ShowBalloonTip(10000, 'DRDirect PC Cleaner', "Version $offered is ready. Click here, then press Check for updates.", [Windows.Forms.ToolTipIcon]::Info)
            if (-not $SimulateOffered) { Set-Content -LiteralPath $stateFile -Value $offered.ToString() -Encoding ASCII }
        }
    } else {
        $notify.Icon = $normalIcon
        $notify.Text = 'DRDirect PC Cleaner'
    }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
    $timer.Interval = 60 * 1000
    try {
        # Ask every 30 minutes, or every 5 minutes until a first answer arrives. A failed check (no network,
        # or GitHub's hourly limit) never throws away the last good answer.
        if ($script:Ticks % 30 -eq 0 -or ($null -eq $script:OfferedVersion -and $script:Ticks % 5 -eq 0)) {
            $answer = Get-OfferedVersion
            if ($answer) { $script:OfferedVersion = $answer }
            else { Write-TrayLog 'version check failed (no network or GitHub limit); keeping the last answer' }
        }
        $script:Ticks++
        Update-Tray
    } catch { }
})
$timer.Start()

[Windows.Forms.Application]::Run()
$notify.Dispose()
'@
function Install-DRTrayHelper {
    $root = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $scriptPath = Join-Path $root 'DRDirect Tray.ps1'
    $text = $script:DRTrayScriptText.Replace("`r`n", "`n").Replace("`n", "`r`n")
    $current = if (Test-Path -LiteralPath $scriptPath -PathType Leaf) { [IO.File]::ReadAllText($scriptPath).TrimStart([char]0xFEFF) } else { $null }
    if ($current -ne $text) { [IO.File]::WriteAllText($scriptPath, $text, [Text.UTF8Encoding]::new($true)) }
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'DRDirect Tray.lnk'
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $scriptPath + '"'
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'DRDirect PC Cleaner update icon'
    $shortcut.Save()
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + $scriptPath + '"'))
}
function Invoke-DRTrayOffer {
    $root = Join-Path $env:LOCALAPPDATA 'DRDirect PC Cleaner'
    $choiceFile = Join-Path $root 'tray_choice.txt'
    $choice = if (Test-Path -LiteralPath $choiceFile -PathType Leaf) { (Get-Content -LiteralPath $choiceFile -Raw).Trim() } else { '' }
    if ($choice -eq 'no') { return }
    if ($choice -eq 'yes') { Install-DRTrayHelper; return }
    $answer = [Windows.MessageBox]::Show("Show a small DRDirect icon by the clock that turns yellow when a new version of the Cleaner is ready?`n`nIt starts with Windows and only checks the version number. You can switch it off any time from its right-click menu.", 'DRDirect PC Cleaner', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question, [Windows.MessageBoxResult]::No)
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if ($answer -eq [Windows.MessageBoxResult]::Yes) {
        Set-Content -LiteralPath $choiceFile -Value 'yes' -Encoding ASCII
        Install-DRTrayHelper
    } else {
        Set-Content -LiteralPath $choiceFile -Value 'no' -Encoding ASCII
    }
}
$script:DRTrayOffered = $false
$window.Add_ContentRendered({
    if ($script:DRTrayOffered -or $TestMode) { return }
    $script:DRTrayOffered = $true
    try { Invoke-DRTrayOffer } catch { }
})
    # The scan-button brooms stand still until a cleanup runs; then only that scan's broom sweeps.
    Set-DRScanBroomsAlive $false
    [void]$window.ShowDialog()
}
