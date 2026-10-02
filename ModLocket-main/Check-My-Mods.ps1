[CmdletBinding()]
param([string]$ArkRoot)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'ModLocket-Core.ps1') -LibraryOnly -ArkRoot $ArkRoot
    if (-not $ArkRoot) {
        $candidate = 'F:\steam\steamapps\common\ARK Survival Ascended'
        if (Test-Path -LiteralPath (Join-Path $candidate 'ShooterGame/Binaries/Win64/ArkAscended.exe') -PathType Leaf) { $ArkRoot = $candidate }
        else {
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Select ARK Survival Ascended for a READ-ONLY library check.'
            $dialog.ShowNewFolderButton = $false
            try {
                if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw 'Folder selection cancelled.' }
                $ArkRoot = $dialog.SelectedPath
            } finally { $dialog.Dispose() }
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ArkRoot 'ShooterGame/Binaries/Win64/ArkAscended.exe') -PathType Leaf)) { throw 'Selected folder does not contain the ARK executable.' }
    Write-Host "ModLocket $ScriptVersion | READ-ONLY CHECK"
    Write-Host 'Reads the current index and top-level folder names. Does not hash mod payloads, repair, back up, delete, download, or launch anything.'
    $result = Invoke-GuardAction (Get-Paths $ArkRoot) 'Inspect'
    Write-Host "CHECK COMPLETE | Entries: $($result.ModCount) | Findings: $($result.AttentionCount)"
    Write-Host 'A completed inspection is not a Ready result. Return this report for review before using the test build for backup or launch.'
    exit 0
} catch {
    Write-Host ('CHECK BLOCKED | ' + $_.Exception.Message)
    exit 1
}
