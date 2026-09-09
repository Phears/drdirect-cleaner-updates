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
        Title="DRDirect PC Cleaner" Width="1280" Height="820" MinWidth="880" MinHeight="620"
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
        <Grid.ColumnDefinitions><ColumnDefinition Width="224"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
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
                <StackPanel Grid.Row="1" x:Name="Navigation">
                    <Button x:Name="NavDashboard" Style="{StaticResource NavButton}" Tag="Active" Content="⌂   Dashboard"/>
                    <Button x:Name="NavCleanup" Style="{StaticResource NavButton}" Content="✦   Cleanup"/>
                    <Button x:Name="NavRepair" Style="{StaticResource NavButton}" Content="⚒   Windows repair"/>
                    <Button x:Name="NavSecurity" Style="{StaticResource NavButton}" Content="⬡   Security"/>
                    <Button x:Name="NavHealth" Style="{StaticResource NavButton}" Content="▰   Drive health"/>
                    <Button x:Name="NavProgress" Style="{StaticResource NavButton}" Content="◐   Maintenance progress" Visibility="Collapsed"/>
                    <Button x:Name="NavHardware" Style="{StaticResource NavButton}" Content="▤   Hardware"/>
                    <Button x:Name="NavHistory" Style="{StaticResource NavButton}" Content="◷   History"/>
                    <Button x:Name="NavDuplicates" Style="{StaticResource NavButton}" Content="⧉   Duplicate finder"/>
                </StackPanel>
                <StackPanel Grid.Row="2" Margin="24,14,20,24"><Border x:Name="ActivateWrap" Margin="0,0,0,14" CornerRadius="8" Background="#1E4FA8" BorderBrush="#7FB0FF" BorderThickness="1" Padding="14,10" HorizontalAlignment="Stretch" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform x:Name="ActivateScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform><StackPanel><TextBlock x:Name="TrialCountdown" Text="" HorizontalAlignment="Center" Foreground="#D7E6FF" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,6" Visibility="Collapsed"/><Button x:Name="ActivateButton" Content="&#128273;  Activate this product" HorizontalAlignment="Center" Background="Transparent" BorderThickness="0" Cursor="Hand" Foreground="White" FontSize="15" FontWeight="Bold" Padding="0"/></StackPanel></Border><TextBlock x:Name="AdminStatus" Foreground="#9FB0C9" FontSize="12"/></StackPanel>
            </Grid>
        </Border>

        <Grid Grid.Column="1" Margin="34,26,34,28">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="0,0,0,20"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="PageEyebrow" Text="THIS PC" Style="{StaticResource MutedText}" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="PageTitle" Text="Dashboard" Style="{StaticResource TitleText}"/></StackPanel><Border Grid.Column="1" CornerRadius="16" Background="#E7F6EF" Padding="12,7" VerticalAlignment="Center"><TextBlock Text="●  Protected mode" Foreground="{StaticResource Success}" FontSize="12"/></Border></Grid>

            <Grid Grid.Row="1">
                <ScrollViewer x:Name="PageDashboard" VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <UniformGrid Columns="3" Margin="0,0,0,18">
                            <Border Style="{StaticResource Card}" Margin="0,0,12,0" BorderBrush="{StaticResource Violet}" BorderThickness="5,1,1,1"><StackPanel><StackPanel Orientation="Horizontal"><Border Style="{StaticResource StatIcon}" Background="{StaticResource VioletSoft}"><TextBlock Text="◷" Foreground="{StaticResource Violet}" FontSize="19" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="LAST MAINTENANCE" Foreground="{StaticResource Violet}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock Text="Not run yet" FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock Text="History will appear after a run" Style="{StaticResource MutedText}" FontSize="12"/></StackPanel></Border>
                            <Border Style="{StaticResource Card}" Margin="0,0,12,0" BorderBrush="{StaticResource Teal}" BorderThickness="5,1,1,1"><StackPanel><StackPanel Orientation="Horizontal"><Border Style="{StaticResource StatIcon}" Background="{StaticResource TealSoft}"><TextBlock Text="▰" Foreground="{StaticResource Teal}" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="FREE SPACE ON C:" Foreground="{StaticResource Teal}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock x:Name="FreeSpaceText" Text="Checking…" FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock Text="Current Windows drive" Style="{StaticResource MutedText}" FontSize="12"/></StackPanel></Border>
                            <Border Style="{StaticResource Card}" BorderBrush="{StaticResource Amber}" BorderThickness="5,1,1,1"><StackPanel><StackPanel Orientation="Horizontal"><Border Style="{StaticResource StatIcon}" Background="{StaticResource AmberSoft}"><TextBlock Text="⬡" Foreground="{StaticResource Amber}" FontSize="18" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="WINDOWS STATUS" Foreground="{StaticResource Amber}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/></StackPanel><TextBlock x:Name="WindowsStatusText" Text="Not checked" FontSize="23" FontWeight="SemiBold" Margin="0,12,0,2"/><TextBlock Text="Run analysis for details" Style="{StaticResource MutedText}" FontSize="12"/></StackPanel></Border>
                        </UniformGrid>
                        <Border Style="{StaticResource Card}" Padding="34" Background="{StaticResource HeroBrush}" BorderBrush="#2447B8">
                            <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="170"/></Grid.ColumnDefinitions>
                                <StackPanel VerticalAlignment="Center"><TextBlock Text="SAFE ANALYSIS" Foreground="#A8C4FF" FontSize="11" FontWeight="Bold"/><TextBlock Text="See what can be improved before changing anything" Foreground="White" FontSize="27" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,10,0,10"/><TextBlock Text="Estimate recoverable space and review Windows maintenance options. Analysis does not delete files, change settings, or start repairs." Foreground="#C9D9FF" TextWrapping="Wrap" MaxWidth="600" HorizontalAlignment="Left"/><StackPanel Orientation="Horizontal" Margin="0,26,0,0"><Button x:Name="ScanButton" Content="Analyze this PC" Style="{StaticResource HeroButton}"/><Button x:Name="LastReportButton" Content="Open reports" Style="{StaticResource HeroGhostButton}" Margin="10,0,0,0"/><Button x:Name="CheckUpdatesButton" Content="Check for updates" Style="{StaticResource HeroGhostButton}" Margin="10,0,0,0"/></StackPanel></StackPanel>
                                <Grid Grid.Column="1"><Ellipse Width="140" Height="140" Fill="#26FFFFFF" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" From="1" To="1.14" Duration="0:0:2.2"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" From="1" To="1.14" Duration="0:0:2.2"/><DoubleAnimation Storyboard.TargetProperty="Opacity" From="0.95" To="0.4" Duration="0:0:2.2"/></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Width="104" Height="104" Fill="#33FFFFFF" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform><Ellipse.Triggers><EventTrigger RoutedEvent="Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" From="1" To="1.07" Duration="0:0:2.2" BeginTime="0:0:0.35"/><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" From="1" To="1.07" Duration="0:0:2.2" BeginTime="0:0:0.35"/></Storyboard></BeginStoryboard></EventTrigger></Ellipse.Triggers></Ellipse><Ellipse Width="72" Height="72" Fill="White"/><TextBlock Text="⌕" Foreground="#1E40AF" FontSize="38" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Grid>
                            </Grid>
                        </Border>
                        <Border Style="{StaticResource Card}" Margin="0,18,0,0">
                            <StackPanel>
                                <Grid Margin="0,0,0,4">
                                    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <StackPanel Orientation="Horizontal">
                                        <Border Style="{StaticResource StatIcon}" Background="{StaticResource BlueSoft}"><TextBlock Text="&#9634;" Foreground="{StaticResource Blue}" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                                        <TextBlock Text="RECENT ACTIVITY" Foreground="{StaticResource Blue}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/>
                                    </StackPanel>
                                    <Button x:Name="DashboardHistoryButton" Grid.Column="1" Content="See all" Style="{StaticResource SecondaryButton}" VerticalAlignment="Center"/>
                                </Grid>
                                <StackPanel x:Name="DashboardHistoryList" Margin="0,10,0,0"/>
                            </StackPanel>
                        </Border>
                        <Border x:Name="TestModeBanner" Style="{StaticResource Card}" Background="#FFF4E3" BorderBrush="#F0C98C" Margin="0,18,0,0" Visibility="Collapsed"><TextBlock Text="TEST MODE is active. External Windows operations are simulated and file deletion is limited to the supplied test folder." Foreground="{StaticResource Warning}" TextWrapping="Wrap"/></Border>
                    </StackPanel>
                </ScrollViewer>

                <Grid x:Name="PageTasks" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="TaskIntro" Text="Select exactly what you want to run. Nothing starts until you review and confirm the plan." Style="{StaticResource MutedText}" TextWrapping="Wrap"/><Border Grid.Column="1" Background="{StaticResource BlueSoft}" CornerRadius="14" Padding="12,6"><TextBlock x:Name="SelectionSummary" Text="0 selected" Foreground="{StaticResource Blue}" FontSize="12"/></Border></Grid>
                    <Border x:Name="CleanupPresetPanel" Grid.Row="1" Style="{StaticResource Card}" Padding="16" Margin="0,0,0,14" Visibility="Visible">
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
                    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="TaskList"/></ScrollViewer>
                    <Grid Grid.Row="3" Margin="0,16,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Destructive actions always require final confirmation." Style="{StaticResource MutedText}" FontSize="12" VerticalAlignment="Center"/><Button x:Name="ReviewButton" Grid.Column="1" Content="Review selected plan" Style="{StaticResource PrimaryButton}" IsEnabled="False"/></Grid>
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
                    <ProgressBar x:Name="OverallProgress" Grid.Row="1" Height="8" Minimum="0" Maximum="100" Value="0" Margin="0,96,0,18" Foreground="{StaticResource Blue}" Background="#DEE5F0" BorderThickness="0"/>
                    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="ProgressList"/></ScrollViewer>
                    <Grid Grid.Row="3" Margin="0,16,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="ProgressSafetyText" Text="Long-running Windows commands finish before the next task begins." Style="{StaticResource MutedText}" FontSize="12" VerticalAlignment="Center"/><Button x:Name="RestartButton" Grid.Column="1" Content="Restart now" Style="{StaticResource PrimaryButton}" Margin="0,0,10,0" Visibility="Collapsed"/><Button x:Name="CancelPlanButton" Grid.Column="2" Content="Stop after current task" Style="{StaticResource SecondaryButton}"/></Grid>
                </Grid>

                <Grid x:Name="PageHistory" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Grid Margin="0,0,0,14"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Reports are stored locally and include selected tasks, timestamps, results, warnings, and errors." Style="{StaticResource MutedText}" TextWrapping="Wrap"/><Button x:Name="OpenReportsButton" Grid.Column="1" Content="Open reports folder" Style="{StaticResource SecondaryButton}"/><Button x:Name="ClearHistoryButton" Grid.Column="2" Content="Clear all history" Style="{StaticResource DangerButton}" Margin="10,0,0,0"/></Grid>
                    <Border Grid.Row="1" Style="{StaticResource Card}"><StackPanel x:Name="HistoryList"/></Border>
                </Grid>

                <Grid x:Name="PageHardware" Visibility="Collapsed">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Grid Margin="0,0,0,14"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="What is inside this PC, and where there is room to improve it. Nothing here is changed or installed." Style="{StaticResource MutedText}" TextWrapping="Wrap" VerticalAlignment="Center"/><Button x:Name="CheckDriversButton" Grid.Column="1" Content="Check for driver updates" Style="{StaticResource SecondaryButton}" Margin="10,0,0,0"/></Grid>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="HardwareList"/></ScrollViewer>
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
                    <Grid Grid.Row="3" Margin="0,20,0,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><CheckBox x:Name="ConfirmationCheck" Content="I reviewed this plan and approve the selected changes."/><StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0"><Button x:Name="ConfirmBackButton" Content="Go back" Style="{StaticResource SecondaryButton}"/><Button x:Name="ConfirmRunButton" Content="Run selected tasks" Style="{StaticResource PrimaryButton}" Margin="10,0,0,0" IsEnabled="False"/></StackPanel></Grid>
                </Grid>
            </Border>
        </Grid>
    </Grid>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

function Get-Control { param([string]$Name) $window.FindName($Name) }

$ui = @{}
@('CustomTitleBar','TitleDragArea','TitleMinButton','TitleMaxButton','TitleCloseButton','NavDashboard','NavCleanup','NavRepair','NavSecurity','NavHealth','NavHistory','NavProgress','ActivateButton','ActivateWrap','ActivateScale','TrialCountdown','AdminStatus','VersionText','PageTitle','PageEyebrow','FreeSpaceText','WindowsStatusText','ScanButton','LastReportButton','TestModeBanner','PageDashboard','PageTasks','TaskIntro','SelectionSummary','CleanupPresetPanel','PresetSafe','PresetMedium','PresetAdvanced','PresetDescription','TaskList','ReviewButton','PageProgress','ProgressScanLevel','ProgressHeading','ProgressMessage','ProgressPercent','OverallProgress','ProgressList','CleaningAnimation','CleaningCaption','ProgressSafetyText','RestartButton','CancelPlanButton','PageHistory','OpenReportsButton','ClearHistoryButton','HistoryList','DashboardHistoryList','DashboardHistoryButton','NavHardware','PageHardware','HardwareList','CheckDriversButton','NavDuplicates','PageDuplicates','OpenDuplicatesButton','CheckUpdatesButton','DuplicateStatus','BusyOverlay','OverlayTitle','OverlayMessage','OverlayProgress','OverlayPercent','OverlayContinueButton','ConfirmOverlay','ConfirmList','ConfirmWarning','ConfirmWarningText','ConfirmationCheck','ConfirmBackButton','ConfirmRunButton') | ForEach-Object { $ui[$_] = Get-Control $_ }

$catalog = @(Get-DRTaskCatalog)
$selection = @{}
$analysis = @{}
$currentCategory = 'Dashboard'
$script:driverPanel = $null
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
    $ui.PageTasks.Visibility = if ($Name -in @('Cleanup','Repair','Security','Health')) { 'Visible' } else { 'Collapsed' }
    $ui.PageProgress.Visibility = if ($Name -eq 'Progress') { 'Visible' } else { 'Collapsed' }
    $ui.PageHistory.Visibility = if ($Name -eq 'History') { 'Visible' } else { 'Collapsed' }
    $ui.PageDuplicates.Visibility = if ($Name -eq 'Duplicates') { 'Visible' } else { 'Collapsed' }
    $ui.PageHardware.Visibility = if ($Name -eq 'Hardware') { 'Visible' } else { 'Collapsed' }
    $ui.PageTitle.Text = switch ($Name) { 'Health' {'Drive health'} 'Progress' {'Maintenance progress'} 'Duplicates' {'Duplicate finder'} 'Hardware' {'Hardware'} default {$Name} }
    $script:currentCategory = $Name
    $ui.CleanupPresetPanel.Visibility = if ($Name -eq 'Cleanup') { 'Visible' } else { 'Collapsed' }
    $navMap = @{ Dashboard='NavDashboard'; Cleanup='NavCleanup'; Repair='NavRepair'; Security='NavSecurity'; Health='NavHealth'; History='NavHistory'; Progress='NavProgress'; Duplicates='NavDuplicates'; Hardware='NavHardware' }
    foreach ($key in $navMap.Keys) { $ui[$navMap[$key]].Tag = if ($key -eq $Name) { 'Active' } else { $null } }
    if ($Name -in @('Cleanup','Repair','Security','Health')) { Show-TaskCategory $Name }
    if ($Name -eq 'History') { Show-History }
    if ($Name -eq 'Dashboard') { Show-DashboardHistory }
    if ($Name -eq 'Hardware') { Show-Hardware }

    $activePage = switch ($Name) {
        'Dashboard' { $ui.PageDashboard }
        'Progress'  { $ui.PageProgress }
        'History'   { $ui.PageHistory }
        'Duplicates' { $ui.PageDuplicates }
        'Hardware'  { $ui.PageHardware }
        default     { $ui.PageTasks }
    }
    Start-DRFadeIn -Element $activePage
    Start-DRFadeIn -Element $ui.PageTitle -Shift 8 -Seconds 0.26 -Delay 0.04
}

function Get-CleanupPresetDescription {
    param([string]$Preset)

    if ($Preset -eq 'Safe') {
        return 'Regular cleanup: temporary files, browser caches, Recycle Bin, hidden Recycle Bin folders, and Prefetch.'
    }

    if ($Preset -eq 'Medium') {
        return 'Full cleanup: Safe plus Windows Disk Cleanup.'
    }

    if ($Preset -eq 'Advanced') {
        return 'Everything in Medium plus cookies/site data, a Defender quick scan, and full Windows repair: restore point, DISM, SFC, and Windows Update repair. The network reset stays manual.'
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
    $safeIds = @(
        'cleanup.windows-temp',
        'cleanup.browser-cache',
        'cleanup.recycle-bin',
        'cleanup.hidden-recycle-folders',
        'cleanup.prefetch'
    )
    $mediumIds = $safeIds + @('cleanup.disk-cleanup')
    # The cloud caches join Advanced, the level meant to reclaim everything.
    # They only ever appear for a service that is installed, and clearing one
    # costs nothing but re-downloading files that were already cached.
    $advancedIds = $mediumIds + @(
        'cleanup.cookies',
        'cleanup.cloud-icloud',
        'cleanup.cloud-google',
        'cleanup.cloud-onedrive',
        'cleanup.cloud-dropbox',
        'cleanup.cloud-mega'
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
        # The network reset is included. Saved wireless networks and their
        # passwords are untouched, so a home machine on DHCP reconnects by
        # itself after the restart. Two cases still need care: a PC on a static
        # address or manual DNS has to have those re-entered, and a remote
        # session drops while the address renews.
        return (($advancedIds -contains $Task.Id) -or
                $Task.Category -eq 'Repair' -or
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
    $titlePanel = New-Object Windows.Controls.StackPanel -Property @{ Orientation='Horizontal' }
    $name = New-Object Windows.Controls.TextBlock -Property @{ Text=$Task.Name; FontWeight='SemiBold'; FontSize=15; VerticalAlignment='Center' }
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

    if ($isLoud) {
        $caution = 'You might have to sign in again to websites and webmail after this runs.'
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
    $meta.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$value; FontWeight='SemiBold'; HorizontalAlignment='Right' })) | Out-Null
    $sub = if ($analysis.ContainsKey($Task.Id) -and $analysis[$Task.Id].ItemCount -gt 0) { "$($analysis[$Task.Id].ItemCount) location(s)" } elseif ($Task.RequiresAdmin) { 'Administrator' } else { 'Current user' }
    $meta.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$sub; Foreground='#667085'; FontSize=11; HorizontalAlignment='Right'; Margin='0,4,0,0' })) | Out-Null

    $grid.Children.Add($check) | Out-Null; $grid.Children.Add($copy) | Out-Null; $grid.Children.Add($meta) | Out-Null
    $border.Child = $grid
    return $border
}

function Get-VisibleTasksForCategory {
    param([string]$Category)

    $tasks = @($catalog | Where-Object Category -eq $Category)

    # Each ordered level only lists what it will actually run. Cookie cleanup is
    # the one task that signs the person out, so the row exists on Advanced and
    # nowhere else, Custom included. Disk Cleanup does not appear until Medium.
    $hidden = @()
    if ($script:cleanupLevel -ne 'Advanced') { $hidden = @('cleanup.cookies') }
    if ($script:cleanupLevel -eq 'Safe')     { $hidden += 'cleanup.disk-cleanup' }

    # A cloud cache row is only worth showing when that service is actually set
    # up here. Offering to clear a Dropbox cache on a PC without Dropbox is a
    # row that can only ever report "nothing to do".
    foreach ($task in $tasks) {
        $service = Get-DRPropertyValue -InputObject $task -Name 'CloudService'
        if ($service -and -not (Test-DRCloudServicePresent $service)) { $hidden += $task.Id }
    }

    if ($Category -eq 'Cleanup' -and $hidden.Count) {
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
        'OneDrive'     { @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial, "$env:LOCALAPPDATA\Microsoft\OneDrive") }
        'Dropbox'      { @("$env:LOCALAPPDATA\Dropbox", (Join-Path $env:USERPROFILE 'Dropbox')) }
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
    }
    $visible = @(Get-VisibleTasksForCategory -Category $Category)
    # A row that is not on screen must not run. Dropping to Safe after ticking
    # cookie cleanup on Advanced would otherwise leave it selected but invisible.
    if ($Category -eq 'Cleanup') {
        $visibleIds = @($visible | ForEach-Object { $_.Id })
        foreach ($task in @($catalog | Where-Object Category -eq 'Cleanup')) {
            if ($visibleIds -notcontains $task.Id) { $selection[$task.Id] = $false }
        }
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
    if ($script:currentCategory -in @('Cleanup','Repair','Security','Health')) {
        $ui.SelectionSummary.Text = if ($total -gt $here) { "$here selected here, $total in total" } else { "$here selected" }
    } else {
        $ui.SelectionSummary.Text = "$total selected"
    }

    $ui.ReviewButton.IsEnabled = $total -gt 0
}

function Show-Confirmation {
    $selected = @($catalog | Where-Object { $selection[$_.Id] })
    $ui.ConfirmList.Children.Clear()
    foreach ($task in $selected) {
        $row = New-Object Windows.Controls.Border -Property @{ BorderBrush='#E3E8F0'; BorderThickness='0,0,0,1'; Padding='0,10' }
        $grid = New-Object Windows.Controls.Grid
        $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='*' }))
        $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='Auto' }))
        $grid.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text=$task.Name; FontWeight='SemiBold' })) | Out-Null
        $risk = New-Object Windows.Controls.TextBlock -Property @{ Text=$task.Risk; Foreground='#667085'; FontSize=12 }
        [Windows.Controls.Grid]::SetColumn($risk,1); $grid.Children.Add($risk) | Out-Null
        $row.Child = $grid; $ui.ConfirmList.Children.Add($row) | Out-Null
    }
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($selected.Risk -contains 'SignOut') { $warnings.Add('Cookie cleanup can end active website and webmail sessions.') }
    if ($selected.Id -contains 'cleanup.recycle-bin') { $warnings.Add('Recycle Bin contents will be permanently removed.') }
    if ($selected.Id -contains 'security.remove-exclusions') { $warnings.Add('All configured Defender exclusions will be exported to a backup and then removed.') }
    if (@($selected).Count -gt 0) { $warnings.Add('When everything has finished, Windows needs to restart. You will get a one-hour countdown first, and you can cancel it or restart sooner.') }
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
    $grid.Children.Add($dot) | Out-Null; $grid.Children.Add($panel) | Out-Null; $border.Child = $grid
    return $border
}

function Set-ProgressRowState {
    param([string]$TaskId,[string]$State,[string]$Message)
    $row = @($ui.ProgressList.Children | Where-Object Tag -eq $TaskId | Select-Object -First 1)
    if (-not $row) { return }
    $dot = $row.Child.Children[0]; $text = $row.Child.Children[1].Children[1]
    $dot.Fill = switch ($State) { 'Started' {'#2563EB'} 'Progress' {'#2563EB'} 'Completed' {'#16835B'} 'Failed' {'#C63C3C'} 'Warning' {'#A86412'} default {'#98A2B3'} }
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
    $selected = @($catalog | Where-Object { $selection[$_.Id] })
    $runQueue.Clear(); foreach ($task in $selected) { $runQueue.Enqueue($task.Id) }
    if (Test-Path -LiteralPath $script:childPidFile) { Remove-Item -LiteralPath $script:childPidFile -Force -ErrorAction SilentlyContinue }
    $runEvents.Clear(); $runStartedAt = Get-Date; $cancelAfterTask = $false
    Set-Variable -Name runStartedAt -Value $runStartedAt -Scope Script
    Set-Variable -Name cancelAfterTask -Value $false -Scope Script
    $ui.ProgressList.Children.Clear(); foreach ($task in $selected) { $ui.ProgressList.Children.Add((New-ProgressRow $task)) | Out-Null }
    if ($ui.CleaningAnimation) { $ui.CleaningAnimation.Visibility='Visible' }
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

    if ($cancelAfterTask) {
        $ui.ProgressHeading.Text = 'Plan stopped safely'
        $ui.ProgressMessage.Text = 'No additional tasks were started.'
    }
    elseif ($failed) {
        $ui.ProgressHeading.Text = 'Maintenance finished with warnings'
        $ui.ProgressMessage.Text = "$($selectedIds.Count) selected task(s) finished."
    }
    else {
        $ui.ProgressHeading.Text = 'Maintenance complete'
        $ui.ProgressMessage.Text = "$($selectedIds.Count) selected task(s) finished."
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
    $needsRestart = (-not $cancelAfterTask) -and ($selectedIds.Count -gt 0)

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
        Start-DRRestartCountdown -Seconds 10800 -BaseMessage $ui.ProgressSafetyText.Text
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

            if (-not [string]::IsNullOrWhiteSpace([string]$sender.Tag)) {
                Start-Process -FilePath ([string]$sender.Tag) | Out-Null
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
$ui.NavHealth.Add_Click({ Set-Page 'Health' })
$ui.NavHardware.Add_Click({ Set-Page 'Hardware' })
$ui.CheckDriversButton.Add_Click({ Start-DRDriverCheck })
$ui.NavHistory.Add_Click({ Set-Page 'History' })
$ui.NavDuplicates.Add_Click({ Set-Page 'Duplicates' })
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
    try {
        $shown = try { Get-DRInstalledVersion } catch { $null }
        $ui.VersionText.Text = if ($shown -and "$shown" -ne '0.0.0') { "Version $shown" } else { 'Version 1.0' }
    } catch { }

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

    $finder = Resolve-DRDuplicateFinderPath
    if (-not $finder) {
        $ui.DuplicateStatus.Text = "Could not find 'DRDirect Duplicate Finder.ps1' beside the application."
        return
    }
    # The path contains spaces, so it must arrive at powershell.exe quoted.
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $trialFlag = ''
    try { if (Test-DRTrialMode) { $trialFlag = ' -TrialMode' } } catch { }
    $psArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"{1}' -f $finder, $trialFlag

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
    try {
        if (Test-Path -LiteralPath $stampFile) {
            $last = ([System.IO.File]::ReadAllText($stampFile)).Trim()
            if ($last -eq (Get-Date).ToString('yyyy-MM-dd')) { return }
        }
    } catch { }

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
        $runspace = [RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = 'MTA'; $runspace.ThreadOptions = 'ReuseThread'; $runspace.Open()
        $ps = [PowerShell]::Create(); $ps.Runspace = $runspace
        $null = $ps.AddScript($probe.ToString()).AddArgument($installed.ToString())
        $async = $ps.BeginInvoke()

        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(500)
        $timer.Add_Tick({
            if (-not $async.IsCompleted) { return }
            $timer.Stop()
            try {
                $line = [string](@($ps.EndInvoke($async)) | Select-Object -Last 1)
                if ($line -like 'AVAILABLE*') {
                    $version = ($line -split ' ')[1]
                    $ui.CheckUpdatesButton.Content = "Update available - $version"
                    $ui.CheckUpdatesButton.FontWeight = 'Bold'
                    $ui.CheckUpdatesButton.ToolTip =
                        "Version $version is ready. Click to see what changed and install it."
                }
                try { [System.IO.File]::WriteAllText($stampFile, (Get-Date).ToString('yyyy-MM-dd')) } catch { }
            } catch { }
            try { $ps.Dispose(); $runspace.Close(); $runspace.Dispose() } catch { }
        })
        $timer.Start()
    } catch { }
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
        $result = Install-DRUpdate -Manifest $check.Manifest
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
        $ui.CheckUpdatesButton.Content = 'Check for updates'
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
    if ($ui.ConfirmList.Children.Count -ne 1) { throw 'GUI smoke test could not build a one-item confirmation plan.' }
    $ui.ConfirmOverlay.Visibility = 'Collapsed'
    Set-Page 'Dashboard'
    $pollTimer.Stop()
    $window.Close()
    Write-Output 'DRDirect PC Cleaner GUI initialized successfully.'
} else {
    Apply-CleanupPreset -Preset 'Safe'
    # Ask once a day, quietly, so a waiting update is visible on the button
    # rather than only to someone who thinks to go looking for it.
    try { Start-DRQuietUpdateCheck } catch { }
    [void]$window.ShowDialog()
}
