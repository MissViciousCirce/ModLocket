# Shared connection settings. No key is included in the app, report or worker command.
function Get-CurseForgeKeyPath {
    if (-not $env:LOCALAPPDATA) { throw 'Windows local application storage is unavailable.' }
    return Join-Path $env:LOCALAPPDATA 'ModLocketSafetyPreview/curseforge-key.txt'
}
function Get-CurseForgeKey {
    if ($env:MODLOCKET_CURSEFORGE_API_KEY) { return [string]$env:MODLOCKET_CURSEFORGE_API_KEY }
    $path=Get-CurseForgeKeyPath
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $secure=ConvertTo-SecureString -String ([IO.File]::ReadAllText($path)) -ErrorAction Stop
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr); $secure.Dispose() }
    } catch { throw 'The saved CurseForge key could not be opened by this Windows account. Enter it again in Check for Updates.' }
}
function Save-CurseForgeKey([string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key) -or $Key -match '[\r\n]' -or $Key.Length -gt 4096) { throw 'Enter a valid CurseForge API key.' }
    $path=Get-CurseForgeKeyPath
    $secure=ConvertTo-SecureString $Key.Trim() -AsPlainText -Force
    try { $encrypted=ConvertFrom-SecureString $secure -ErrorAction Stop } finally { $secure.Dispose() }
    [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
    [IO.File]::WriteAllText($path,$encrypted)
}
function Invoke-CurseForgeBatch([string[]]$Ids,[string]$ApiKey) {
    # Official fixed HTTPS endpoint only. Never forward credentials through redirects.
    $numbers=@($Ids | ForEach-Object {
        if ($_ -cnotmatch '^[1-9][0-9]{4,8}$') { throw 'Invalid project ID in online request.' }
        [long]$_
    })
    if ($numbers.Count -lt 1 -or $numbers.Count -gt 50) { throw 'Invalid online request batch size.' }
    $body=ConvertTo-Json -Compress -InputObject @{modIds=$numbers;filterPcOnly=$false}
    $oldTls=[Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol=$oldTls -bor [Net.SecurityProtocolType]::Tls12
        return Invoke-RestMethod -Uri 'https://api.curseforge.com/v1/mods' -Method Post -ContentType 'application/json' -Headers @{'x-api-key'=$ApiKey;Accept='application/json'} -Body $body -TimeoutSec 15 -MaximumRedirection 0 -ErrorAction Stop
    } catch {
        $code=0
        try { $code=[int]$_.Exception.Response.StatusCode } catch {}
        if ($code -in @(401,403)) { throw 'CurseForge denied access. The key must be approved for this use and able to read ARK projects.' }
        if ($code -eq 429) { throw 'CurseForge rate limit reached. Try the check later.' }
        throw 'CurseForge could not be reached or returned an invalid response. Online results are unknown; local comparisons remain available.'
    } finally { [Net.ServicePointManager]::SecurityProtocol=$oldTls }
}
