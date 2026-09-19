[CmdletBinding()]
param([switch]$Install, [switch]$UiCheck)
$script:UiCheck = [bool]$UiCheck

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::ThrowException)
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$AppName = 'ModLocket for ASA'
$AppVersion = '4.0.0-online.4 - CONNECTION PREVIEW'
$ScriptRoot = Split-Path -Parent $PSCommandPath
$CoreScript = Join-Path $ScriptRoot 'ModLocket-Core.ps1'
Add-Type -Path (Join-Path $ScriptRoot 'ModLocket-Worker.cs')
$script:CancelRequested = $false
$script:ClosePromptActive = $false
$BrandImagePath = Join-Path $ScriptRoot 'ViciousCirceLogo.png'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'ModLocketSafetyPreview'
$LegacyInstallRoot = Join-Path $env:LOCALAPPDATA 'ModNestForASA'
$AppSettingsPath = Join-Path $InstallRoot 'app-settings.json'

function New-Color([string]$Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }

$Colors = @{
    Background = New-Color '#120F1B'; Card = New-Color '#1D1829'; CardSoft = New-Color '#17131F'
    Lavender = New-Color '#3B2852'; Purple = New-Color '#B29AE3'; Pink = New-Color '#3B2852'
    PinkHot = New-Color '#4A3465'; Mint = New-Color '#244B50'; MintHot = New-Color '#2E5E64'
    Blue = New-Color '#34415E'; BlueHot = New-Color '#405071'; Butter = New-Color '#4A4147'
    ButterHot = New-Color '#5A4E55'; Peach = New-Color '#523647'; PeachHot = New-Color '#664254'
    Text = New-Color '#F2ECFA'; Muted = New-Color '#B6AAC4'; Border = New-Color '#403650'
    Shadow = New-Color '#0B0910'; Success = New-Color '#9FE7D1'; Warning = New-Color '#E6C886'
    Error = New-Color '#F18A9B'; Header = New-Color '#21172F'
    Ice = New-Color '#8ED7F0'; IceHot = New-Color '#B9E9F8'; IceText = New-Color '#132B38'
}

# Use the approved original PNG directly; no logo regeneration or cropping.
. (Join-Path $ScriptRoot 'ModLocket-Theme.ps1')
. (Join-Path $ScriptRoot 'ModLocket-Comparison-UI.ps1')
function Get-BrandCrop {
    if (-not (Test-Path -LiteralPath $BrandImagePath)) { return $null }
    return [System.Drawing.Image]::FromFile($BrandImagePath)
}

function Get-SteamRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($registryPath in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $item = Get-ItemProperty -Path $registryPath -ErrorAction Stop
            foreach ($property in @('SteamPath', 'InstallPath')) {
                if ($item.$property) {
                    $candidate = [IO.Path]::GetFullPath([string]$item.$property)
                    if (-not $roots.Contains($candidate)) { $roots.Add($candidate) }
                }
            }
        } catch { }
    }
    foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        foreach ($relative in @('Steam', 'SteamLibrary', 'Program Files (x86)\Steam', 'Program Files\Steam')) {
            $candidate = Join-Path $drive.Root $relative
            if ((Test-Path -LiteralPath $candidate) -and -not $roots.Contains($candidate)) { $roots.Add($candidate) }
        }
    }
    foreach ($steamRoot in @($roots.ToArray())) {
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf)) { continue }
        foreach ($line in Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue) {
            if ($line -match '^\s*"path"\s*"(.+)"') {
                $candidate = $Matches[1].Replace('\\', '\')
                if ((Test-Path -LiteralPath $candidate) -and -not $roots.Contains($candidate)) { $roots.Add($candidate) }
            }
        }
    }
    return $roots.ToArray()
}

function Test-ArkRoot([string]$Path) {
    return $Path -and (Test-Path -LiteralPath (Join-Path $Path 'ShooterGame\Binaries\Win64\ArkAscended.exe'))
}

function Get-SavedArkRoot {
    if (-not (Test-Path -LiteralPath $AppSettingsPath)) { return $null }
    try {
        $settings = [IO.File]::ReadAllText($AppSettingsPath) | ConvertFrom-Json
        if (Test-ArkRoot ([string]$settings.ArkRoot)) { return [string]$settings.ArkRoot }
    } catch { }
    return $null
}

function Find-ArkRoot {
    $saved = Get-SavedArkRoot
    if ($saved) { return $saved }
    foreach ($steamRoot in Get-SteamRoots) {
        $candidate = Join-Path $steamRoot 'steamapps\common\ARK Survival Ascended'
        if (Test-ArkRoot $candidate) { return $candidate }
    }
    return $null
}

function Save-ArkRoot([string]$Path) {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    $json = [pscustomobject]@{ ArkRoot = $Path } | ConvertTo-Json
    [IO.File]::WriteAllText($AppSettingsPath, $json, (New-Object Text.UTF8Encoding($false)))
}

function Select-ArkRoot {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the ARK Survival Ascended folder containing ShooterGame.'
    $dialog.ShowNewFolderButton = $false
    try {
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $selected = [IO.Path]::GetFullPath($dialog.SelectedPath)
        if (-not (Test-ArkRoot $selected)) {
            (Show-ThemedMessage 'That folder does not contain ARK Survival Ascended. In Steam, right-click ARK, choose Manage, then Browse local files.' 'ARK folder not found') | Out-Null
            return $null
        }
        Save-ArkRoot $selected
        return $selected
    } finally { $dialog.Dispose() }
}

function Set-RoundedRegion {
    param([System.Windows.Forms.Control]$Control, [int]$Radius)
    $diameter = $Radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
    $path.AddArc($Control.Width - $diameter - 1, 0, $diameter, $diameter, 270, 90)
    $path.AddArc($Control.Width - $diameter - 1, $Control.Height - $diameter - 1, $diameter, $diameter, 0, 90)
    $path.AddArc(0, $Control.Height - $diameter - 1, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    $Control.Region = New-Object System.Drawing.Region($path)
    $path.Dispose()
}

function New-RoundedCard {
    param(
        [System.Windows.Forms.Control]$Parent, [int]$Left, [int]$Top, [int]$Width, [int]$Height,
        [int]$Radius = 24, [System.Drawing.Color]$BackColor = $Colors.Card
    )
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($Left, $Top)
    $panel.Size = New-Object System.Drawing.Size($Width, $Height)
    $panel.BackColor = $BackColor
    Set-RoundedRegion $panel $Radius
    $Parent.Controls.Add($panel)
    Enable-CardArtwork $panel
    $panel.BringToFront()
    return $panel
}

function Install-ModLocketApp {
    throw 'Installation is disabled for this safety checkpoint. Extract it separately and run the fixture tests first. Your installed app has not been changed.'
}

if ($Install) {
    try { Install-ModLocketApp }
    catch {
        (Show-ThemedMessage $_.Exception.Message 'ModLocket installation failed' -Owner $null) | Out-Null
        exit 1
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $CoreScript)) {
    (Show-ThemedMessage 'The ModLocket repair engine must be in the same folder as this app.' 'Missing repair engine' -Owner $null) | Out-Null
    exit 1
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "$AppName - $AppVersion"
$form.ClientSize = New-Object System.Drawing.Size(1200, 760)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Colors.Background
$form.ForeColor = $Colors.Text
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.AutoScaleDimensions = New-Object Drawing.SizeF 96,96
$form.AutoScaleMode = 'Dpi'
$form.Add_HandleCreated({param($sender,$e);[ModLocketWindowTheme]::Apply($sender.Handle)})
$iconPath = Join-Path $ScriptRoot 'ModLocket.ico'
if (Test-Path -LiteralPath $iconPath) { $form.Icon = New-Object System.Drawing.Icon -ArgumentList $iconPath }

$header = New-RoundedCard $form 20 18 1160 160 24 $Colors.Header

$brandImage = Get-BrandCrop
$brandBadge = New-Object System.Windows.Forms.PictureBox
$brandBadge.Location = New-Object System.Drawing.Point(16, 3)
$brandBadge.Size = New-Object System.Drawing.Size(160, 154)
$brandBadge.BackColor = [System.Drawing.Color]::Transparent
$brandBadge.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$brandBadge.Image = $brandImage
$header.Controls.Add($brandBadge)

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(182, 29)
$title.Size = New-Object System.Drawing.Size(670, 58)
$title.Text = 'MODLOCKET FOR ASA'
$title.Font = New-Object System.Drawing.Font('Georgia', 30)
$title.ForeColor = $Colors.Text
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Location = New-Object System.Drawing.Point(187, 91)
$subtitle.Size = New-Object System.Drawing.Size(660, 28)
$subtitle.Text = 'Your mod backup, repair, and launch companion'
$subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
$subtitle.ForeColor = $Colors.Muted
$header.Controls.Add($subtitle)

$statusPill = New-Object System.Windows.Forms.Label
$statusPill.Location = New-Object System.Drawing.Point(940, 40)
$statusPill.Size = New-Object System.Drawing.Size(190, 40)
$statusPill.Text = ([char]0x25CF) + '  READY, SURVIVOR'
$statusPill.TextAlign = 'MiddleCenter'
$statusPill.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$statusPill.BackColor = $Colors.Success
$statusPill.ForeColor = New-Color '#173B36'
Set-RoundedRegion $statusPill 21
$header.Controls.Add($statusPill)

$creatorTag = New-Object System.Windows.Forms.Label
$creatorTag.Location = New-Object System.Drawing.Point(940, 94)
$creatorTag.Size = New-Object System.Drawing.Size(190, 22)
$creatorTag.Text = 'By ViciousCirce'
$creatorTag.TextAlign = 'MiddleCenter'
$creatorTag.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Italic)
$creatorTag.ForeColor = $Colors.Purple
$header.Controls.Add($creatorTag)

$actionsPanel = New-RoundedCard $form 20 198 530 508 22 $Colors.Card

$actionsTitle = New-Object System.Windows.Forms.Label
$actionsTitle.Location = New-Object System.Drawing.Point(26, 20)
$actionsTitle.Size = New-Object System.Drawing.Size(430, 40)
$actionsTitle.Text = 'Actions'
$actionsTitle.Font = New-Object System.Drawing.Font('Georgia', 21)
$actionsTitle.ForeColor = $Colors.Text
$actionsPanel.Controls.Add($actionsTitle)

function New-ActionButton {
    param(
        [string]$Title, [string]$Description, [int]$Left, [int]$Top, [int]$Width, [int]$Height,
        [System.Drawing.Color]$BaseColor, [System.Drawing.Color]$HoverColor, [int]$Radius = 22
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Location = New-Object System.Drawing.Point($Left, $Top)
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.UseVisualStyleBackColor = $false
    $button.TabStop = $true
    $button.BackColor = $BaseColor
    $button.ForeColor = $Colors.Text
    $button.TextAlign = 'MiddleCenter'
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
    $button.Text = "$Title`r`n$Description"
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Tag = [pscustomobject]@{ Normal = $BaseColor; Hover = $HoverColor }
    Set-RoundedRegion $button $Radius
    $button.Add_MouseEnter({ param($sender, $eventArgs); $sender.BackColor = $sender.Tag.Hover })
    $button.Add_MouseLeave({ param($sender, $eventArgs); $sender.BackColor = $sender.Tag.Normal })
    Enable-ButtonArtwork $button
    $actionsPanel.Controls.Add($button)
    return $button
}

$launchButton = New-ActionButton 'LAUNCH ARK' 'Quick file and version check' 24 70 482 88 $Colors.Ice $Colors.IceHot 16
$launchButton.ForeColor = $Colors.IceText
$launchButton.Font = New-Object Drawing.Font('Segoe UI Semibold',13)
$backupButton = New-ActionButton 'BACKUP' 'Save your current mods' 24 180 234 90 $Colors.Lavender $Colors.PinkHot 16
$inventoryButton = New-ActionButton 'MY MOD LIST' 'Export IDs and names' 272 180 234 90 $Colors.Blue $Colors.BlueHot 16
$manageButton = New-ActionButton 'MANAGE BACKUPS' 'Saved copies and storage' 24 288 234 90 $Colors.Butter $Colors.ButterHot 16
$restoreButton = New-ActionButton 'RESTORE MISSING FILES' 'Check, restore + launch' 272 288 234 90 $Colors.Peach $Colors.PeachHot 16
$restoreButton.Font = New-Object Drawing.Font('Segoe UI Semibold',9.5)
$updatesButton = New-ActionButton 'CHECK FOR UPDATES' 'Compare local and published versions' 24 410 482 72 $Colors.Mint $Colors.MintHot 16

# Hover shows timing help. Keyboard users explicitly press the info button; focus alone stays quiet.
$restoreInfo = New-Object Windows.Forms.Button
$restoreInfo.Text = 'i'
$restoreInfo.AccessibleName = 'About Restore Missing Files'
$restoreInfo.Location = New-Object Drawing.Point 472,321
$restoreInfo.Size = New-Object Drawing.Size 24,24
$restoreInfo.FlatStyle = 'Flat'; $restoreInfo.FlatAppearance.BorderSize=0
$restoreInfo.BackColor=$Colors.Peach; $restoreInfo.ForeColor=$Colors.Purple
$restoreInfo.Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
$restoreInfo.UseVisualStyleBackColor=$false
$restoreInfo.TabStop=$true
$restoreInfo.AccessibleDescription='Explains what Restore Missing Files does and how long it can take.'
Enable-InfoArtwork $restoreInfo $restoreButton
$restoreInfo.Cursor=[Windows.Forms.Cursors]::Hand
$actionsPanel.Controls.Add($restoreInfo)
$restoreInfo.BringToFront()
$restoreHelp = 'Checks your backup and restores missing mod files before launching ARK. This can take a few minutes, especially with large mod collections.'
$restoreTip=New-Object Windows.Forms.ToolTip
$restoreTip.InitialDelay=350; $restoreTip.ReshowDelay=100; $restoreTip.AutoPopDelay=20000; $restoreTip.ShowAlways=$false
$restoreTip.BackColor=$Colors.CardSoft; $restoreTip.ForeColor=$Colors.Text
$restoreTip.OwnerDraw=$true
$restoreTip.Add_Popup({param($sender,$e)
    # Native hover only: do not show on focus changes after an action finishes.
    $mouse=$restoreInfo.PointToClient([Windows.Forms.Cursor]::Position)
    if (-not $restoreInfo.Enabled -or -not $restoreInfo.ClientRectangle.Contains($mouse)) {$e.Cancel=$true;return}
    $e.ToolTipSize=New-Object Drawing.Size 400,96
})
$restoreTip.Add_Draw({param($sender,$e)
    $brush=New-Object Drawing.SolidBrush($Colors.CardSoft)
    $pen=New-Object Drawing.Pen($Colors.Purple,1)
    $font=New-Object Drawing.Font('Segoe UI',10)
    try{
        $e.Graphics.FillRectangle($brush,$e.Bounds)
        $e.Graphics.DrawRectangle($pen,0,0,($e.Bounds.Width-1),($e.Bounds.Height-1))
        $bounds=New-Object Drawing.Rectangle 10,8,($e.Bounds.Width-20),($e.Bounds.Height-16)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics,$e.ToolTipText,$font,$bounds,$Colors.Text,[Windows.Forms.TextFormatFlags]::WordBreak)
    }finally{$brush.Dispose();$pen.Dispose();$font.Dispose()}
})
$restoreTip.SetToolTip($restoreInfo,$restoreHelp)
$restoreInfo.Add_MouseLeave({$restoreTip.Hide($restoreInfo)})
$restoreInfo.Add_Leave({$restoreTip.Hide($restoreInfo)})
$form.Add_Deactivate({$restoreTip.Hide($restoreInfo)})
$restoreButton.Add_EnabledChanged({
    $restoreInfo.Enabled=$restoreButton.Enabled
    if (-not $restoreInfo.Enabled) {$restoreTip.Hide($restoreInfo)}
})
$restoreInfo.Add_Click({
    $restoreTip.Hide($restoreInfo)
    [void](Show-ThemedMessage $restoreHelp 'Restore Missing Files')
})

$logPanel = New-RoundedCard $form 568 198 612 508 22 $Colors.Card

$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Location = New-Object System.Drawing.Point(26, 20)
$logTitle.Size = New-Object System.Drawing.Size(110, 40)
$logTitle.Text = 'Status'
$logTitle.Font = New-Object System.Drawing.Font('Georgia', 21)
$logTitle.ForeColor = $Colors.Text
$logPanel.Controls.Add($logTitle)

$progressLabel = New-Object System.Windows.Forms.Label
$progressLabel.Location = New-Object System.Drawing.Point(139, 28)
$progressLabel.Size = New-Object System.Drawing.Size(337, 25)
$progressLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$progressLabel.ForeColor = $Colors.Ice
$progressLabel.Text = 'Idle'
$progressLabel.AutoEllipsis = $true
$logPanel.Controls.Add($progressLabel)
$elapsedLabel = New-Object System.Windows.Forms.Label
$elapsedLabel.Location = New-Object System.Drawing.Point(26, 87)
$elapsedLabel.Size = New-Object System.Drawing.Size(556, 24)
$elapsedLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$elapsedLabel.ForeColor = $Colors.Muted
$elapsedLabel.Text = 'Percentages describe the current stage.'
$logPanel.Controls.Add($elapsedLabel)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Location = New-Object System.Drawing.Point(505, 22)
$clearButton.Size = New-Object System.Drawing.Size(80, 32)
$clearButton.Text = 'Clear'
$clearButton.FlatStyle = 'Flat'
$clearButton.FlatAppearance.BorderSize = 0
$clearButton.UseVisualStyleBackColor = $false
$clearButton.TabStop = $true
$clearButton.BackColor = $Colors.CardSoft
$clearButton.ForeColor = $Colors.Muted
$clearButton.Cursor = [System.Windows.Forms.Cursors]::Hand
Set-RoundedRegion $clearButton 16
$logPanel.Controls.Add($clearButton)

$logFrame = New-Object System.Windows.Forms.Panel
$logFrame.Location = New-Object System.Drawing.Point(25, 122)
$logFrame.Size = New-Object System.Drawing.Size(562, 360)
$logFrame.BackColor = $Colors.CardSoft
Enable-LogFrameArtwork $logFrame
Set-RoundedRegion $logFrame 18
$logPanel.Controls.Add($logFrame)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(14, 12)
$logBox.Size = New-Object System.Drawing.Size(534, 336)
$logBox.Anchor = 'Top, Bottom, Left, Right'
$logBox.BackColor = $Colors.CardSoft
$logBox.ForeColor = $Colors.Text
$logBox.BorderStyle = 'None'
$logBox.ReadOnly = $true
$logBox.DetectUrls = $false
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
# Keep the text control rectangular and inset from the rounded outer frame.
$logFrame.Controls.Add($logBox)

$footer = New-Object System.Windows.Forms.Label
$footer.Location = New-Object System.Drawing.Point(20, 724)
$footer.Size = New-Object System.Drawing.Size(1160, 24)
$footer.Text = ([char]0x2726) + '   Protecting your purchased skins, custom mods, and tiny digital dinosaurs   ' + ([char]0x2726)
$footer.ForeColor = $Colors.Muted
$footer.Font = New-Object System.Drawing.Font('Georgia', 10)
$footer.TextAlign = 'MiddleCenter'
$form.Controls.Add($footer)
Enable-FooterSnakes $footer

Enable-MoonlitHeader $header
foreach($label in @($title,$subtitle,$creatorTag,$actionsTitle,$logTitle,$progressLabel,$elapsedLabel)) {$label.BackColor=[Drawing.Color]::Transparent}
$script:stageBar=New-Object Windows.Forms.Panel
$script:stageBar.Location=New-Object Drawing.Point 26,68
$script:stageBar.Size=New-Object Drawing.Size 560,10
$script:stageBar.BackColor=$Colors.CardSoft; $script:stageBar.Tag=-2
$script:stageBar.Add_Paint({param($sender,$e)
    $percent=[int]$sender.Tag
    $brush=New-Object Drawing.SolidBrush($Colors.Purple)
    try {
        if($percent-ge0){$e.Graphics.FillRectangle($brush,0,0,[int]($sender.Width*$percent/100),$sender.Height)}
        elseif($percent-eq-1){$x=[int](([Environment]::TickCount -band 2147483647)/12)%($sender.Width+80)-80;$e.Graphics.FillRectangle($brush,$x,0,80,$sender.Height)}
    }finally{$brush.Dispose()}
})
$logPanel.Controls.Add($script:stageBar)

$actionButtons = @($launchButton, $backupButton, $inventoryButton, $manageButton, $restoreButton, $updatesButton)
$script:ActiveWorker = $null
$script:ExitCode = $null
$script:ActiveAction = $null
$script:ActionResult = $null
$script:ActionClock = $null
$script:LastWorkerUpdate = 0.0
$script:ArkRoot = if ($UiCheck) { $null } else { Find-ArkRoot }

function Add-LogLine {
    param([string]$Text, [System.Drawing.Color]$Color = $Colors.Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { $logBox.AppendText("`r`n"); return }
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor = $Color
    $logBox.AppendText("$Text`r`n")
    $logBox.SelectionColor = $logBox.ForeColor
    $logBox.ScrollToCaret()
}

function Set-StatusPill([ValidateSet('Standby', 'Working', 'Cleared', 'QuickLaunched', 'Attention')][string]$State) {
    switch ($State) {
        'Standby' {
            $statusPill.Text = ([char]0x25CF) + '  READY, SURVIVOR'
            $statusPill.BackColor = $Colors.Success
            $statusPill.ForeColor = New-Color '#173B36'
        }
        'Working' {
            $label = switch ($script:ActiveAction) {
                'Setup' { 'SAVING BACKUP' }
                'Refresh' { 'SAVING BACKUP' }
                'PlanBackup' { 'REVIEWING BACKUP' }
                'ManageBackups' { 'READING BACKUPS' }
                'RemoveSnapshot' { 'REMOVING BACKUP' }
                'SelectSnapshot' { 'VERIFYING BACKUP' }
                'CleanRepairStaging' { 'CLEANING UP' }
                'PlanSetup' { 'REVIEWING BACKUP' }
                'PlanRefresh' { 'REVIEWING BACKUP' }
                'Inventory' { 'EXPORTING LIST' }
                'Updates' { 'CHECKING VERSIONS' }
                'SaveModList' { 'SAVING MOD LIST' }
                default { 'CHECKING MODS' }
            }
            $statusPill.Text = ([char]0x25CF) + '  ' + $label
            $statusPill.BackColor = $Colors.Warning
            $statusPill.ForeColor = New-Color '#3C311B'
        }
        'Cleared' {
            $statusPill.Text = ([char]0x25CF) + '  READY, SURVIVOR'
            $statusPill.BackColor = $Colors.Success
            $statusPill.ForeColor = New-Color '#173B36'
        }
        'QuickLaunched' {
            $statusPill.Text = ([char]0x25CF) + '  LAUNCH REQUESTED'
            $statusPill.BackColor = $Colors.Ice
            $statusPill.ForeColor = $Colors.IceText
        }
        'Attention' {
            $statusPill.Text = ([char]0x25CF) + '  NEEDS ATTENTION'
            $statusPill.BackColor = $Colors.Error
            $statusPill.ForeColor = New-Color '#3D1720'
        }
    }
}

function Set-BusyState([bool]$Busy) {
    foreach ($button in $actionButtons) { $button.Enabled = -not $Busy }
    $clearButton.Enabled = -not $Busy
    if (-not $Busy -and $null -ne $script:stageBar) { $script:stageBar.Tag=-2; $script:stageBar.Invalidate() }
    if ($Busy) { Set-StatusPill 'Working' }
}

function Confirm-Choice {
    param([string]$Message, [string]$Title = 'Please confirm')
    $result = Show-ThemedMessage $Message $Title -Question
    return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

function Ensure-ArkRoot {
    if (Test-ArkRoot $script:ArkRoot) { return $true }
    $script:ArkRoot = Find-ArkRoot
    if (-not $script:ArkRoot) { $script:ArkRoot = Select-ArkRoot }
    if (-not $script:ArkRoot) {
        Add-LogLine 'ARK folder selection was cancelled.' $Colors.Warning
        return $false
    }
    Update-BackupButton
    Add-LogLine "ARK folder: $script:ArkRoot" $Colors.Muted
    return $true
}

function Update-BackupButton {
    $backupButton.Text = "BACKUP`r`nSave your current mods"
}

function Start-GuardAction {
    param(
        [ValidateSet('PlanBackup', 'ManageBackups', 'RemoveSnapshot', 'SelectSnapshot', 'CleanRepairStaging', 'PlanSetup', 'PlanRefresh', 'Setup', 'QuickLaunch', 'Launch', 'Inventory', 'Updates', 'SaveModList', 'Refresh', 'FullRestore')][string]$Action,
        [switch]$AssumeYes, [string]$DisplayName, [string]$BackupApproval, [string]$TargetId, [string]$ManagementApproval
    )
    if ($script:ActiveWorker) { return }
    if (-not (Ensure-ArkRoot)) { return }
    $script:ExitCode = $null
    $script:ActionResult = $null
    $script:ActiveAction = $Action
    $script:ActionClock = [Diagnostics.Stopwatch]::StartNew()
    $script:LastWorkerUpdate = 0.0
    $progressLabel.Text = 'Starting...'
    $script:stageBar.Tag=-1; $script:stageBar.Invalidate()
    Add-LogLine ''
    Add-LogLine $DisplayName $Colors.Purple
    Add-LogLine "Started: $(Get-Date -Format 'h:mm:ss tt')" $Colors.Muted
    Set-BusyState $true
    try {
        $script:CancelRequested = $false
        $script:LaunchApprovalNotBefore = [DateTime]::MinValue
        $command = "& '" + $CoreScript.Replace("'", "''") + "' -Action '" + $Action + "' -ArkRoot '" + $script:ArkRoot.Replace("'", "''") + "' -DeferSteamLaunch"
        if ($AssumeYes) { $command += ' -Yes' }
        if ($BackupApproval) {
            if ($BackupApproval -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid backup review result.' }
            $command += " -BackupApproval '" + $BackupApproval + "'"
        }
        if ($ManagementApproval) {
            if ($ManagementApproval -cnotmatch '^[0-9a-f]{64}$' -or $TargetId -cnotmatch '^(?:[0-9a-f]{32}|repair-staging)$') { throw 'Invalid backup management selection.' }
            $command += " -TargetId '" + $TargetId + "' -ManagementApproval '" + $ManagementApproval + "'"
        }
        $command += '; exit $LASTEXITCODE'
        $script:ActiveWorker = [ModLocket.OwnedWorker]::Start((Join-Path $PSHOME 'powershell.exe'), $command, (Join-Path $ScriptRoot 'ModLocket-Worker-Entry.ps1'))
    }
    catch {
        Add-LogLine ("Could not start the action: " + $_.Exception.Message) $Colors.Error
        if ($script:ActionClock) { $script:ActionClock.Stop() }
        $progressLabel.Text = 'Could not start'
        Set-BusyState $false
        Set-StatusPill 'Attention'
        $script:ActiveAction = $null
    }
}

function Test-BackupReviewResult($Result, [string]$ExpectedAction) {
    if ($null -eq $Result -or $Result.Status -cne 'BackupReview' -or
        $ExpectedAction -cnotin @('Setup','Refresh') -or $Result.Action -cne $ExpectedAction -or
        [string]$Result.Approval -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Result.ModCount -cnotmatch '^[1-9][0-9]*$' -or
        [string]$Result.FileCount -cnotmatch '^[1-9][0-9]*$' -or
        [string]$Result.CopyBytes -cnotmatch '^[0-9]+$' -or
        [string]$Result.RequiredBytes -cnotmatch '^[1-9][0-9]*$' -or
        [string]$Result.AvailableBytes -cnotmatch '^[0-9]+$' -or
        $Result.EnoughSpace -isnot [bool] -or $Result.Changes -isnot [Array]) { return $false }
    foreach ($change in $Result.Changes) {
        if ($change.Kind -cnotin @('Added','Removed','Version changed') -or
            [string]$change.ModId -cnotmatch '^[1-9][0-9]{4,8}$' -or $change.Name -isnot [string]) { return $false }
    }
    return $true
}
function Get-BackupReviewText($Review) {
    $lines = New-Object 'Collections.Generic.List[string]'
    foreach ($change in $Review.Changes) {
        $name = ([string]$change.Name) -replace '[\x00-\x1f]', ' '
        $lines.Add("$($change.Kind): $name [$($change.ModId)]")
        if ($change.Kind -ceq 'Version changed') { $lines.Add("    File $($change.Before) -> $($change.After)") }
    }
    if (-not $lines.Count) { $lines.Add('No additions, removals, or version changes detected.') }
    return $lines -join "`r`n"
}
function Show-BackupReview($Review) {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Review backup changes'
    $dialog.ClientSize = New-Object System.Drawing.Size 640, 500
    $dialog.StartPosition = 'CenterParent'; $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
    $summary = New-Object System.Windows.Forms.Label
    $summary.Location = New-Object System.Drawing.Point 18, 15
    $summary.Size = New-Object System.Drawing.Size 604, 105
    $summary.Text = ("{0} mods / {1} files`r`nNew backup: {2:N1} GiB | Required with reserve: {3:N1} GiB | Free: {4:N1} GiB`r`n`r`nEarlier backups stay on disk. Removed mods will no longer be protected by the new backup. This does not download mod updates." -f $Review.ModCount, $Review.FileCount, ($Review.CopyBytes/1GB), ($Review.RequiredBytes/1GB), ($Review.AvailableBytes/1GB))
    $details = New-Object System.Windows.Forms.TextBox
    $details.Location = New-Object System.Drawing.Point 18, 125
    $details.Size = New-Object System.Drawing.Size 604, 265
    $details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
    $details.Text = Get-BackupReviewText $Review
    $removed = @($Review.Changes | Where-Object { $_.Kind -ceq 'Removed' }).Count
    $confirm = New-Object System.Windows.Forms.CheckBox
    $confirm.Location = New-Object System.Drawing.Point 18, 400
    $confirm.Size = New-Object System.Drawing.Size 604, 32
    $confirm.Text = "I intentionally removed the $removed mods listed above."
    $confirm.Visible = ($removed -gt 0)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Location = New-Object System.Drawing.Point 350, 447
    $cancel.Size = New-Object System.Drawing.Size 130, 34
    $cancel.Text = 'Cancel'; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $save = New-Object System.Windows.Forms.Button
    $save.Location = New-Object System.Drawing.Point 492, 447
    $save.Size = New-Object System.Drawing.Size 130, 34
    $save.Text = 'Save backup'; $save.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $save.Enabled = ($Review.EnoughSpace -and $removed -eq 0)
    if (-not $Review.EnoughSpace) { $summary.Text += "`r`nNot enough free space. Saving is disabled." }
    $confirm.Add_CheckedChanged({ $save.Enabled = ($Review.EnoughSpace -and $confirm.Checked) }.GetNewClosure())
    $dialog.Controls.AddRange(@($summary,$details,$confirm,$cancel,$save))
    $dialog.AcceptButton = $cancel; $dialog.CancelButton = $cancel
    Set-DialogTheme $dialog
    try { return $dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK }
    finally { $dialog.Dispose() }
}
function Test-BackupManagerResult($Result) {
    if ($null -eq $Result -or $Result.Status -cne 'BackupManager' -or $Result.Items -isnot [Array] -or
        [string]$Result.TotalBytes -cnotmatch '^[0-9]+$' -or [string]$Result.RecoveryBytes -cnotmatch '^[0-9]+$') { return $false }
    $ids = @{}
    foreach ($item in $Result.Items) {
        if ($item.Kind -cnotin @('Snapshot','RepairStaging') -or $ids.ContainsKey([string]$item.Id) -or
            [string]$item.Approval -cnotmatch '^[0-9a-f]{64}$' -or [string]$item.Bytes -cnotmatch '^[0-9]+$' -or
            $item.State -isnot [string] -or $item.Current -isnot [bool] -or $item.CanDelete -isnot [bool] -or $item.CanSelect -isnot [bool]) { return $false }
        if (($item.Kind -ceq 'Snapshot' -and [string]$item.Id -cnotmatch '^[0-9a-f]{32}$') -or
            ($item.Kind -ceq 'RepairStaging' -and $item.Id -cne 'repair-staging') -or
            ($item.Current -and ($item.CanDelete -or $item.CanSelect))) { return $false }
        $ids[[string]$item.Id] = $true
    }
    return $true
}
function Show-BackupManager($Review) {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Manage backups'; $dialog.ClientSize = New-Object System.Drawing.Size 780, 505
    $dialog.StartPosition = 'CenterParent'; $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
    $summary = New-Object System.Windows.Forms.Label
    $summary.Location = New-Object System.Drawing.Point 18, 15; $summary.Size = New-Object System.Drawing.Size 744, 70
    $summary.Text = ("Saved copies: {0:N2} GiB | Recovery folder: {1:N2} GiB`r`nThe current backup cannot be deleted. Selecting an older copy fully verifies it first.`r`nSelecting a backup does not change installed mods or download updates." -f ($Review.TotalBytes/1GB), ($Review.RecoveryBytes/1GB))
    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point 18, 92; $list.Size = New-Object System.Drawing.Size 744, 255
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false
    [void]$list.Columns.Add('Created (local time)',145); [void]$list.Columns.Add('State',305)
    [void]$list.Columns.Add('GiB',70); [void]$list.Columns.Add('Mods',55); [void]$list.Columns.Add('Copy ID',145)
    foreach ($entry in $Review.Items) {
        $date = '-'
        try { if ($entry.CreatedUtc) { $date = ([DateTime]::Parse($entry.CreatedUtc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } catch { $date = 'Unknown' }
        $row = New-Object System.Windows.Forms.ListViewItem $date
        [void]$row.SubItems.Add($entry.State); [void]$row.SubItems.Add(('{0:N2}' -f ($entry.Bytes/1GB)))
        [void]$row.SubItems.Add([string]$entry.ModCount); [void]$row.SubItems.Add($entry.Id)
        $row.Tag = $entry; [void]$list.Items.Add($row)
    }
    $detail = New-Object System.Windows.Forms.Label
    $detail.Location = New-Object System.Drawing.Point 18, 358; $detail.Size = New-Object System.Drawing.Size 744, 75
    $detail.Text = 'Select a row to see its actions. Closing this window changes nothing.'
    if (-not $Review.Items.Count) { $detail.Text = 'No saved copies or recognised interrupted repairs were found.' }
    if ($Review.IgnoredItems -gt 0) { $detail.Text += "`r`nUnrecognised items were left alone." }
    $close = New-Object System.Windows.Forms.Button
    $close.Location = New-Object System.Drawing.Point 642, 453; $close.Size = New-Object System.Drawing.Size 120, 34
    $close.Text = 'Close'; $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $select = New-Object System.Windows.Forms.Button
    $select.Location = New-Object System.Drawing.Point 18, 453; $select.Size = New-Object System.Drawing.Size 205, 34
    $select.Text = 'Verify and select'; $select.Enabled = $false
    $delete = New-Object System.Windows.Forms.Button
    $delete.Location = New-Object System.Drawing.Point 237, 453; $delete.Size = New-Object System.Drawing.Size 175, 34
    $delete.Text = 'Delete older copy'; $delete.Enabled = $false
    $list.Add_SelectedIndexChanged({
        $select.Enabled = $false; $delete.Enabled = $false
        if ($list.SelectedItems.Count -eq 1) {
            $entry = $list.SelectedItems[0].Tag
            $detail.Text = "Selected: $($entry.Id)`r`n$($entry.State)"
            $delete.Enabled = $entry.CanDelete
            $select.Text = if ($entry.Kind -ceq 'RepairStaging') { 'Move repair leftovers' } else { 'Verify and select' }
            $select.Enabled = ($entry.CanSelect -or $entry.Kind -ceq 'RepairStaging')
            if ($entry.Kind -ceq 'RepairStaging') { $detail.Text += "`r`nTemporary files will be preserved in Recovery. Then run Restore Missing Files." }
        }
    }.GetNewClosure())
    $select.Add_Click({
        if ($list.SelectedItems.Count -ne 1) { return }
        $entry = $list.SelectedItems[0].Tag
        $cleanup = ($entry.Kind -ceq 'RepairStaging')
        $message = if ($cleanup) { 'Move recognised temporary repair files into Recovery? Their contents are kept; installed final files and the mod index are left alone.' }
            else { 'Verify every file and select this backup? This can take several minutes. Installed mods will not change. Launch will remain blocked if their versions do not match this copy.' }
        $answer = Show-ThemedMessage $message 'Confirm backup action' -Question -Owner $dialog
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            $action = if ($cleanup) {'CleanRepairStaging'} else {'SelectSnapshot'}
            $dialog.Tag = [pscustomobject]@{Action=$action;Id=$entry.Id;Approval=$entry.Approval;DisplayName=$select.Text}
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }
    }.GetNewClosure())
    $delete.Add_Click({
        if ($list.SelectedItems.Count -ne 1) { return }
        $entry = $list.SelectedItems[0].Tag
        if (-not $entry.CanDelete -or $entry.Current) { return }
        $message = ("Permanently delete this copy?`r`n{0}`r`nSize: {1:N2} GiB`r`n`r`nThis cannot be undone. The current backup and installed mods are preserved." -f $entry.Id,($entry.Bytes/1GB))
        $answer = Show-ThemedMessage $message 'Delete older backup' -Question -Owner $dialog
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            $dialog.Tag = [pscustomobject]@{Action='RemoveSnapshot';Id=$entry.Id;Approval=$entry.Approval;DisplayName='Remove selected older copy'}
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }
    }.GetNewClosure())
    $dialog.Controls.AddRange(@($summary,$list,$detail,$select,$delete,$close))
    $dialog.AcceptButton = $close; $dialog.CancelButton = $close
    Set-DialogTheme $dialog
    try { if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.Tag } }
    finally { $dialog.Dispose() }
}
function Test-VerifiedLaunchResult($Result) {
    return ($null -ne $Result -and $Result.Status -ceq 'Verified' -and
        $Result.SteamRequested -is [bool] -and $Result.SteamRequested -eq $true -and
        [string]$Result.SnapshotId -cmatch '^[0-9a-f]{32}$' -and
        [string]$Result.ModCount -match '^[1-9]\d*$' -and
        [string]$Result.FilesChecked -match '^[1-9]\d*$' -and
        -not [string]::IsNullOrWhiteSpace([string]$Result.CheckedUtc))
}
function Test-QuickLaunchResult($Result) {
    return ($null -ne $Result -and $Result.Status -ceq 'QuickChecked' -and
        $Result.SteamRequested -is [bool] -and $Result.SteamRequested -eq $true -and
        $Result.IntegrityVerified -is [bool] -and $Result.IntegrityVerified -eq $false -and
        $Result.BackupContentsVerified -is [bool] -and $Result.BackupContentsVerified -eq $false -and
        $Result.OnlineUpdatesVerified -is [bool] -and $Result.OnlineUpdatesVerified -eq $false -and
        [string]$Result.SnapshotId -cmatch '^[0-9a-f]{32}$' -and
        [string]$Result.ModCount -match '^[1-9]\d*$' -and
        [string]$Result.FilesChecked -match '^[1-9]\d*$' -and
        [string]$Result.FilesRestored -ceq '0' -and
        -not [string]::IsNullOrWhiteSpace([string]$Result.CheckedUtc))
}
function Get-LogSeverity([string]$Line) {
    if ($Line -match '^\[ERROR\]|ERROR:|Exception') { return 'Error' }
    if ($Line -match '^\[!\]') { return 'Warning' }
    if ($Line -match '^\[OK\]') { return 'Success' }
    if ($Line -match '^\[i\]') { return 'Purple' }
    return 'Text'
}
function Receive-CoreLine([string]$Line) {
    if ($Line.StartsWith('__MODLOCKET_PROGRESS__=')) {
        if ($script:CancelRequested) { return }
        $progress = ConvertFrom-ProgressLine $Line
        if ($null -ne $progress) {
            $progressLabel.Text = if ($progress.Percent -ge 0) { "Stage: $($progress.Stage) - $($progress.Percent)%" } else { "$($progress.Stage)..." }
            if ($null -ne $script:stageBar) { $script:stageBar.Tag=[int]$progress.Percent; $script:stageBar.Invalidate() }
            if ($script:ActionClock) { $script:LastWorkerUpdate = $script:ActionClock.Elapsed.TotalSeconds }
        }
        return
    }
    if ($Line -match '^__MODLOCKET_EXIT_CODE__=(\d+)$') { $script:ExitCode = [int]$Matches[1]; return }
    if ($Line.StartsWith('__MODLOCKET_RESULT__=')) {
        try { $script:ActionResult = $Line.Substring(21) | ConvertFrom-Json -ErrorAction Stop }
        catch { $script:ActionResult = $null; Add-LogLine 'Malformed result from the core; readiness will not be assumed.' $Colors.Error }
        return
    }
    Add-LogLine $Line $Colors[(Get-LogSeverity $Line)]
}
function ConvertFrom-ProgressLine([string]$Line) {
    if (-not $Line.StartsWith('__MODLOCKET_PROGRESS__=')) { return $null }
    try {
        $item = $Line.Substring('__MODLOCKET_PROGRESS__='.Length) | ConvertFrom-Json -ErrorAction Stop
        if ($item.Stage -isnot [string] -or [string]::IsNullOrWhiteSpace($item.Stage) -or
            $item.Stage.Length -gt 80 -or $item.Stage -match '[\x00-\x1f]' -or
            ($item.Percent -isnot [int] -and $item.Percent -isnot [long])) { return $null }
        if ($item.Percent -lt -1 -or $item.Percent -gt 100) { return $null }
        return $item
    } catch { return $null }
}

function Test-DeferredLaunchResult($Result, [string]$Action) {
    if ($null -eq $Result -or $Result.SteamRequested -isnot [bool] -or $Result.SteamRequested -ne $false -or
        $Result.NeedsSteamLaunch -isnot [bool] -or $Result.NeedsSteamLaunch -ne $true) { return $false }
    $candidate = $Result.PSObject.Copy()
    $candidate.SteamRequested = $true
    if ($Action -ceq 'QuickLaunch') { return Test-QuickLaunchResult $candidate }
    if ($Action -ceq 'Launch') { return Test-VerifiedLaunchResult $candidate }
    return $false
}
function Invoke-DeferredHandoff($Result, [string]$Action) {
    if ($script:CancelRequested -or $script:ClosePromptActive) { throw 'Launch cancelled or close choice pending.' }
    if (-not (Test-DeferredLaunchResult $Result $Action)) { throw 'The worker did not provide a valid launch approval.' }
    $checked = [DateTime]::Parse([string]$Result.CheckedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    if ($script:LaunchApprovalNotBefore -and $checked -lt $script:LaunchApprovalNotBefore) {
        throw 'The check finished while the close dialog was open. Click Launch again for a fresh check.'
    }
    # GUI owns this final decision; workers and their job never start Steam.
    Start-Process 'steam://rungameid/2399830' -ErrorAction Stop
    $Result.SteamRequested = $true
    $Result.NeedsSteamLaunch = $false
}
function Show-CloseChoice {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Close ModLocket?'
    $dialog.ClientSize = New-Object System.Drawing.Size 540, 240
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point 20, 20
    $label.Size = New-Object System.Drawing.Size 496, 140
    $label.Text = "Stop the current operation and close?`n`nCompleted backups stay available. An unfinished backup will not be selected. A repair may leave temporary files that need review."
    $keep = New-Object System.Windows.Forms.Button
    $keep.Text = 'Keep working'; $keep.Size = New-Object System.Drawing.Size 130, 34
    $keep.Location = New-Object System.Drawing.Point 248, 182
    $keep.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close anyway'; $close.Size = New-Object System.Drawing.Size 130, 34
    $close.Location = New-Object System.Drawing.Point 390, 182
    $close.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.AddRange(@($label, $keep, $close))
    $dialog.AcceptButton = $keep; $dialog.CancelButton = $keep
    Set-DialogTheme $dialog
    try { return $dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK }
    finally { $dialog.Dispose() }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    if (-not $script:ActiveWorker) { return }
    $script:stageBar.Invalidate()
    try {
        if ($script:ActionClock) {
            $seconds = [int]$script:ActionClock.Elapsed.TotalSeconds
            $since = [int]($script:ActionClock.Elapsed.TotalSeconds - $script:LastWorkerUpdate)
            $elapsedLabel.Text = "Elapsed: $($seconds)s | Last progress: $($since)s ago | Stage percentage"
        }
        foreach ($entry in @($script:ActiveWorker.Drain())) {
            Receive-CoreLine ([string]$entry)
        }

        if ($script:ClosePromptActive) { return }
        if ($script:CancelRequested -and $script:StopClock.Elapsed.TotalSeconds -gt 5) {
            # A stuck output reader must not trap the close button. Kernel close
            # still terminates every process associated with this job.
            $script:ActiveWorker.Dispose()
            $script:ActiveWorker = $null
            $form.Close()
            return
        }
        if ($script:ActiveWorker.Finished) {
            foreach ($entry in @($script:ActiveWorker.Drain())) {
                Receive-CoreLine ([string]$entry)
            }
            $script:ExitCode = $script:ActiveWorker.ExitCode
            $jobState = 'Completed'
            $completedAction = $script:ActiveAction
            $script:ActiveWorker.Dispose()
            $script:ActiveWorker = $null
            $script:ActiveAction = $null
            Set-BusyState $false
            Update-BackupButton
            if ($script:CancelRequested) { $form.Close(); return }
            if ($completedAction -in @('PlanBackup','PlanSetup','PlanRefresh')) {
                if ($script:ActionClock) { $script:ActionClock.Stop() }
                $saveAction = if ($completedAction -ceq 'PlanBackup') { [string]$script:ActionResult.Action } elseif ($completedAction -ceq 'PlanSetup') { 'Setup' } else { 'Refresh' }
                if ($script:ExitCode -ne 0 -or -not (Test-BackupReviewResult $script:ActionResult $saveAction)) {
                    throw 'Backup review did not complete. No new backup was started.'
                }
                $review = $script:ActionResult
                $progressLabel.Text = 'Review before saving'
                Set-StatusPill 'Standby'
                Add-LogLine (Get-BackupReviewText $review) $Colors.Text
                if (Show-BackupReview $review) {
                    Start-GuardAction -Action $saveAction -AssumeYes -BackupApproval $review.Approval -DisplayName 'Save reviewed backup'
                } else {
                    $progressLabel.Text = 'Backup unchanged'
                    Add-LogLine 'Backup review cancelled. No new backup was created.' $Colors.Muted
                }
                return
            }
            if ($completedAction -ceq 'ManageBackups') {
                if ($script:ActionClock) { $script:ActionClock.Stop() }
                if ($script:ExitCode -ne 0 -or -not (Test-BackupManagerResult $script:ActionResult)) { throw 'Could not read backup list. No files were changed.' }
                $progressLabel.Text = 'Review saved copies'; Set-StatusPill 'Standby'
                $choice = Show-BackupManager $script:ActionResult
                if ($choice) {
                    Start-GuardAction -Action $choice.Action -AssumeYes -TargetId $choice.Id -ManagementApproval $choice.Approval -DisplayName $choice.DisplayName
                } else { $progressLabel.Text = 'Backups unchanged' }
                return
            }
            if ($completedAction -in @('RemoveSnapshot','SelectSnapshot','CleanRepairStaging') -and $script:ExitCode -eq 0) {
                $expected = @{RemoveSnapshot='SnapshotRemoved';SelectSnapshot='SnapshotSelected';CleanRepairStaging='RepairStagingMoved'}
                if ($null -eq $script:ActionResult -or $script:ActionResult.Status -cne $expected[$completedAction]) { throw 'Backup management result was incomplete.' }
                Start-GuardAction -Action ManageBackups -DisplayName 'Refresh backup list'
                return
            }
            if ($completedAction -eq 'Updates' -and $script:ExitCode -eq 0 -and $script:ActionResult.Status -ceq 'ModComparison') {
                if ($script:ActionClock) { $script:ActionClock.Stop() }
                $progressLabel.Text='Comparison complete'; $script:stageBar.Tag=100; $script:stageBar.Invalidate()
                if ($script:ActionResult.OnlineMode -eq 'Live metadata check' -and $script:ActionResult.AttentionCount -eq 0) { Set-StatusPill 'Standby' } else { Set-StatusPill 'Attention' }
                if (Show-ModComparison $script:ActionResult) {
                    if (Confirm-Choice 'Save a small list of mod IDs, names and recorded versions? Previously remembered missing mods stay listed. No mod files are copied, so this list cannot restore files offline.' 'Save mod list only') {
                        Start-GuardAction -Action SaveModList -DisplayName 'Save lightweight mod list' -BackupApproval ([string]$script:ActionResult.SaveApproval)
                    }
                }
                return
            }
            if ($completedAction -in @('QuickLaunch', 'Launch') -and $script:ExitCode -eq 0) {
                Invoke-DeferredHandoff $script:ActionResult $completedAction
            }
            if ($script:ActionClock) { $script:ActionClock.Stop() }
            $verifiedLaunch = Test-VerifiedLaunchResult $script:ActionResult
            $quickLaunch = Test-QuickLaunchResult $script:ActionResult
            if ($jobState -eq 'Completed' -and $script:ExitCode -eq 0 -and $null -ne $script:ActionResult -and
                $script:ActionResult.Status -cne 'Blocked' -and ($completedAction -ne 'Launch' -or $verifiedLaunch) -and
                ($completedAction -ne 'QuickLaunch' -or $quickLaunch)) {
                Add-LogLine 'Done.' $Colors.Success
                $progressLabel.Text = 'Complete - 100%'
                $script:stageBar.Tag=100; $script:stageBar.Invalidate()
                if ($completedAction -eq 'Launch') {
                    Set-StatusPill 'Cleared'
                    Add-LogLine ("Last local verification: " + $script:ActionResult.CheckedUtc + '. Not continuous monitoring or an online update guarantee.') $Colors.Muted
                }
                elseif ($completedAction -eq 'QuickLaunch') {
                    Set-StatusPill 'QuickLaunched'
                    Add-LogLine 'Quick launch checks versions, file names and sizes. Full content verification was not performed.' $Colors.Muted
                }
                elseif ($script:ActionResult.AttentionCount -gt 0) {
                    Set-StatusPill 'Attention'
                    Add-LogLine 'Report completed with findings that need attention. Exporting a list does not verify installed files.' $Colors.Warning
                }
                else { Set-StatusPill 'Standby' }
            }
            else {
                $progressLabel.Text = 'Stopped - needs attention'
                Set-StatusPill 'Attention'
                Add-LogLine 'That action did not finish successfully. Check the red message above.' $Colors.Error
            }
        }
    }
    catch {
        if ($script:ActionClock) { $script:ActionClock.Stop() }
        $progressLabel.Text = 'Stopped - needs attention'
        Add-LogLine ("The status window hit a problem: " + $_.Exception.Message) $Colors.Error
        if ($script:ActiveWorker) {
            $script:ActiveWorker.Dispose()
            $script:ActiveWorker = $null
        }
        Set-BusyState $false
        Set-StatusPill 'Attention'
        $script:ActiveAction = $null
    }
})
$timer.Start()

$clearButton.Add_Click({ $logBox.Clear() })
$launchButton.Add_Click({ Start-GuardAction -Action QuickLaunch -DisplayName 'Quick launch' })
$backupButton.Add_Click({ Start-GuardAction -Action PlanBackup -DisplayName 'Review mod backup' })
$inventoryButton.Add_Click({ Start-GuardAction -Action Inventory -DisplayName 'Export mod list' })
$updatesButton.Add_Click({
    try { if (Show-UpdateConnection) { Start-GuardAction -Action Updates -DisplayName 'Compare saved, installed and published mod versions' } }
    catch { [void](Show-ThemedMessage $_.Exception.Message 'CurseForge connection') }
})
$manageButton.Add_Click({ Start-GuardAction -Action ManageBackups -DisplayName 'Manage saved backups' })
$restoreButton.Add_Click({
    if (Confirm-Choice "This hashes the entire backup and installed collection, recovers missing files only when versions match, then launches ARK.`n`nIt can take several minutes. Changed or extra files block launch; existing files are not overwritten.`n`nRun full verification and launch?" 'Restore Missing Files') {
        Start-GuardAction -Action Launch -DisplayName 'Full verification, missing-file repair and launch'
    }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $script:ActiveWorker) { return }
    $eventArgs.Cancel = $true
    if ($script:CancelRequested -or $script:ClosePromptActive) { return }
    $script:ClosePromptActive = $true
    try { $close = Show-CloseChoice }
    finally { $script:ClosePromptActive = $false }
    $script:LaunchApprovalNotBefore = [DateTime]::UtcNow
    if ($close) {
        $script:CancelRequested = $true
        $script:StopClock = [Diagnostics.Stopwatch]::StartNew()
        $script:ActionResult = $null
        $progressLabel.Text = 'Stopping - closing when work has stopped'
        Add-LogLine 'Stopping this operation. No new Steam launch will be requested.' $Colors.Warning
        try { $script:ActiveWorker.Stop() }
        catch {
            # Closing the last job handle is a second kernel-enforced stop path.
            $script:ActiveWorker.Dispose()
            $script:ActiveWorker = $null
            $eventArgs.Cancel = $false
        }
    }
})

Add-LogLine 'ModLocket - Online comparison preview 04.' $Colors.Warning
if ($script:ArkRoot) { Add-LogLine "ARK found: $script:ArkRoot" $Colors.Muted }
else { Add-LogLine 'ARK will be located when you choose an action.' $Colors.Warning }
Add-LogLine 'Launch ARK checks file names, sizes and saved versions without reading every mod file.' $Colors.Muted
Add-LogLine 'Restore Missing Files performs the slower full hash check and can restore missing files. Neither mode checks online updates.' $Colors.Muted
Update-BackupButton
Add-LogLine 'Check for Updates compares saved and installed IDs; add approved CurseForge access for live metadata. Save mod list only needs no full file backup.' $Colors.Muted

if ($UiCheck) {
    [void](Show-UpdateConnection)
    $sampleRow=[pscustomobject]@{Name='Sample mod';ModId='123456';InstalledFileId='100';BackupFileId='100';SavedListFileId='';PublishedFileId='101';LocalState='Recorded locally';OnlineState='Published file differs; review update';BackupComparison='Same recorded ID';SavedListComparison='Not on saved list';OnlineCheckedUtc='Sample only'}
    [void](Show-ModComparison ([pscustomobject]@{ModCount=1;OnlineMode='Sample only';OnlineMessage='No connection or real data is used in this interface check.';InvalidIdentityCount=0;Rows=@($sampleRow);CanSaveList=$false}))
    $demo=[pscustomobject]@{Status='BackupManager';Items=@();TotalBytes=0;RecoveryBytes=0;IgnoredItems=0;CurrentId=''}
    [void](Show-BackupManager $demo)
    $review=[pscustomobject]@{ModCount=0;FileCount=0;CopyBytes=0;RequiredBytes=0;AvailableBytes=0;Changes=@();EnoughSpace=$false}
    [void](Show-BackupReview $review)
    [void](Show-CloseChoice)
    [void](Show-ThemedMessage $restoreHelp 'Restore Missing Files' -Question)
    $form.Add_Shown({$form.BeginInvoke([Action]{$form.Close()}) | Out-Null})
}
try { [void]$form.ShowDialog() }
finally { if ($script:ActiveWorker) { $script:ActiveWorker.Dispose(); $script:ActiveWorker = $null } }
$timer.Stop()
$timer.Dispose()
$restoreTip.Dispose()
if ($footer.Tag -and $footer.Tag.SnakeImage) { $footer.Tag.SnakeImage.Dispose() }
if ($header.BackgroundImage) { $header.BackgroundImage.Dispose() }
if ($brandImage) { $brandImage.Dispose() }

if ($UiCheck) { Write-Output 'PASS | Interface and dark dialogs opened and closed with sample data only.' }
