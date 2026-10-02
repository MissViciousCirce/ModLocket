$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $PSScriptRoot
foreach ($file in Get-ChildItem -LiteralPath $ScriptRoot -Filter '*.ps1' -Recurse) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell syntax errors in $($file.Name): $($errors.Message -join '; ')" }
}
Write-Host 'PASS: PowerShell syntax'
$originalLocal = $env:LOCALAPPDATA
$originalKey = $env:MODLOCKET_CURSEFORGE_API_KEY
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ModLocket-key-test-' + [guid]::NewGuid().ToString('N'))
try {
    $env:LOCALAPPDATA = $tempRoot
    $env:MODLOCKET_CURSEFORGE_API_KEY = $null
    . (Join-Path $ScriptRoot 'ModLocket-Comparison-UI.ps1')
    if ((Get-CurseForgeKey) -ne '') { throw 'Empty profile unexpectedly has a key.' }
    Save-CurseForgeKey 'dummy-key-for-isolated-test'
    $encrypted = [IO.File]::ReadAllText((Get-CurseForgeKeyPath))
    if ($encrypted.Contains('dummy-key-for-isolated-test')) { throw 'Key was saved in plaintext.' }
    # Reload the implementation, as a new launch would.
    . (Join-Path $ScriptRoot 'ModLocket-CurseForge.ps1')
    if ((Get-CurseForgeKey) -cne 'dummy-key-for-isolated-test') { throw 'Saved key did not round-trip.' }
    # No Forms assembly is loaded: this must return before constructing a dialog.
    if ((Show-UpdateConnection) -ne $true) { throw 'Saved-key check did not skip the dialog.' }
    Save-CurseForgeKey 'replacement-dummy-key'
    if ((Get-CurseForgeKey) -cne 'replacement-dummy-key') { throw 'Key replacement failed.' }
    Write-Host 'PASS: encrypted save, reload, replacement, and automatic reuse'
} finally {
    $env:LOCALAPPDATA = $originalLocal
    $env:MODLOCKET_CURSEFORGE_API_KEY = $originalKey
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Host 'No live API request or real mod/backup data was used.'

. (Join-Path $ScriptRoot 'ModLocket-Core.ps1') -LibraryOnly
$probeRoot = [IO.Path]::GetTempPath()
$futurePath = Join-Path $probeRoot ('ModLocket-uncreated-' + [guid]::NewGuid().ToString('N') + '/Snapshots')
$space = Get-DestinationSpace $futurePath
if ($space.AvailableBytes -lt 0 -or $space.TotalFreeBytes -lt $space.AvailableBytes) { throw 'Invalid native space result.' }
if (Test-Path -LiteralPath $futurePath) { throw 'Space query created a folder.' }
Write-Host ('PASS: native destination query: {0:N1} GiB available' -f ($space.AvailableBytes/1GB))
$originalSpaceFunction = ${function:Get-DestinationSpace}
try {
    function Get-DestinationSpace { return [pscustomobject]@{AvailableBytes=500GB;CheckedPath='test'} }
    Assert-FreeSpace 'test' 71GB
    function Get-DestinationSpace { return [pscustomobject]@{AvailableBytes=0L;CheckedPath='test'} }
    $blocked = $false
    try { Assert-FreeSpace 'test' 71GB } catch { $blocked = $true }
    if (-not $blocked) { throw 'Insufficient space did not block backup.' }
    function Get-DestinationSpace { throw 'Simulated query failure' }
    $failed = $false
    try { Assert-FreeSpace 'test' 71GB } catch { $failed = $_.Exception.Message -eq 'Simulated query failure' }
    if (-not $failed) { throw 'Space query failure was hidden.' }
} finally { ${function:Get-DestinationSpace} = $originalSpaceFunction }
Write-Host 'PASS: large byte counts, full-volume protection, and explicit query errors'
