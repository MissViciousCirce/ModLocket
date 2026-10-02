# Synthetic comparison and list-only storage checks. No real API key or HTTP.
$originalKey=${function:Get-CurseForgeKey}
$originalBatch=${function:Invoke-CurseForgeBatch}
function Get-CurseForgeKey { return '' }
function Invoke-CurseForgeBatch { throw 'Unexpected network transport in an isolated test.' }
function New-OnlineRows([int]$Count) {
    @(for($i=0;$i -lt $Count;$i++){
        [pscustomobject]@{ModId=[string](123456+$i);InstalledFileId='100';PublishedFileId='';OnlineState='Not checked';OnlineCheckedUtc=''}
    })
}
Run-Test 'Local comparison needs no full backup and preserves every live file' {
    $p=New-Fixture; $before=@(Get-SafeFiles $p.ArkRoot | ForEach-Object { $_.FullName+':'+(Get-Sha256 $_.FullName) })
    $r=Invoke-GuardAction $p 'Updates'
    Assert-True ($r.Status -eq 'ModComparison' -and $r.ModCount -eq 1 -and $r.OnlineMode -eq 'Not connected' -and $r.CanSaveList) 'Local comparison unavailable.'
    Assert-True ($r.Rows[0].BackupComparison -eq 'Not backed up' -and -not $r.IntegrityVerified -and -not $r.SteamRequested) 'Unexpected approval.'
    $after=@(Get-SafeFiles $p.ArkRoot | ForEach-Object { $_.FullName+':'+(Get-Sha256 $_.FullName) })
    Assert-True (($before -join '|') -ceq ($after -join '|')) 'Read-only comparison wrote data.'
}
Run-Test 'Comparison exposes changed file identity without restoring old backup' {
    $p=New-Fixture; $s=Seed-Snapshot $p; $ph=Get-Sha256 $p.Pointer
    [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'),(Join-Path $p.ModsDir '123456_200'))
    [IO.File]::WriteAllText((Index-Path $p),'{"mods":[{"modId":123456,"fileId":200,"status":"valid"}]}')
    $r=Get-ModComparison $p -LocalOnly
    Assert-True ($r.Rows[0].InstalledFileId -eq '200' -and $r.Rows[0].BackupFileId -eq '100' -and $r.Rows[0].BackupComparison -eq 'Different file ID') 'Version comparison is wrong.'
    Assert-True (-not(Test-Path (Join-Path $p.ModsDir '123456_100'))) 'An obsolete folder was restored.'
    Assert-PriorIntact $p $s $ph
}
Run-Test 'Missing library still compares known backup identities without recreating it' {
    $p=New-Fixture; [void](Seed-Snapshot $p); [IO.File]::Delete((Index-Path $p))
    $r=Get-ModComparison $p -LocalOnly
    Assert-True ($r.ModCount -eq 1 -and $r.Rows[0].InstalledFileId -eq '' -and $r.Rows[0].LocalState -like 'Library missing*') 'Missing library called installed.'
    Assert-True (-not(Test-Path (Index-Path $p))) 'Library was recreated.'
}
Run-Test 'Missing local mod folder is reported while IDs remain recorded' {
    $p=New-Fixture; [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'),(Join-Path $p.ArkRoot 'missing-mod'))
    $r=Get-ModComparison $p -LocalOnly
    Assert-True ($r.Rows[0].LocalState -eq 'Mod folder missing') 'Missing directory overlooked.'
}
Run-Test 'A saved list uses no payload snapshot and never grants protected launch' {
    $p=New-Fixture; $hash=Get-Sha256 (Index-Path $p); $r=Get-ModComparison $p -LocalOnly
    $BackupApproval=$r.SaveApproval; $saved=Invoke-GuardAction $p 'SaveModList'
    Assert-True ($saved.Status -eq 'ModListSaved' -and (Get-Item $saved.Path).Length -lt 10000) 'List is unexpectedly large.'
    Assert-True (-not(Test-Path $p.Pointer) -and -not(Test-Path (Join-Path $p.GuardRoot 'Snapshots'))) 'Full backup created.'
    Assert-True ((Get-Sha256 (Index-Path $p)) -eq $hash -and (Get-ModListState $p).Mods.Count -eq 1) 'List save modified installed metadata.'
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
}
Run-Test 'Saving a list preserves full snapshot bytes and selected pointer' {
    $p=New-Fixture; $s=Seed-Snapshot $p; $ph=Get-Sha256 $p.Pointer
    $r=Get-ModComparison $p -LocalOnly; [void](Save-ModListSnapshot $p $r.SaveApproval)
    Assert-PriorIntact $p $s $ph
}
Run-Test 'Saved-only missing mods remain known after local removal and a second save' {
    $p=New-Fixture; $r=Get-ModComparison $p -LocalOnly; $first=Save-ModListSnapshot $p $r.SaveApproval
    [IO.File]::WriteAllText((Index-Path $p),'{"mods":[]}')
    $r=Get-ModComparison $p -LocalOnly
    Assert-True ($r.ModCount -eq 1 -and $r.Rows[0].LocalState -eq 'Absent from local library') 'Remembered missing mod vanished.'
    $second=Save-ModListSnapshot $p $r.SaveApproval
    Assert-True ((Get-ModListState $p).Mods[0].FileId -eq '100' -and (Test-Path $first.Path) -and $first.Path -ne $second.Path) 'Previous identity or list lost.'
}
Run-Test 'Changed local metadata invalidates list save approval' {
    $p=New-Fixture; $r=Get-ModComparison $p -LocalOnly
    [IO.File]::AppendAllText((Index-Path $p),' ')
    Expect-Blocked { Save-ModListSnapshot $p $r.SaveApproval }
    Assert-True ((Get-ModListState $p).Mods.Count -eq 0) 'Stale list was saved.'
}
Run-Test 'Changed selected backup invalidates list save approval' {
    $p=New-Fixture; $r=Get-ModComparison $p -LocalOnly; [void](Seed-Snapshot $p)
    Expect-Blocked { Save-ModListSnapshot $p $r.SaveApproval }
}
Run-Test 'Invalid and duplicate library identities disable list saving' {
    foreach($json in @('{"mods":[{"modId":123456,"fileId":1.2}]}','{"mods":[{"modId":123456,"fileId":100},{"modId":123456,"fileId":200}]}','{"mods":[{"modId":"bad","fileId":100}]}')){
        $p=New-Fixture; [IO.File]::WriteAllText((Index-Path $p),$json)
        $r=Get-ModComparison $p -LocalOnly
        Assert-True (-not $r.CanSaveList -and $r.InvalidIdentityCount -gt 0) 'Invalid identity accepted.'
        Expect-Blocked { Save-ModListSnapshot $p $r.SaveApproval }
    }
}
Run-Test 'List file IDs preserve integers larger than floating point precision' {
    $p=New-Fixture; [IO.File]::WriteAllText((Index-Path $p),'{"mods":[{"modId":123456,"fileId":4515822747893123456,"status":"valid"}]}')
    $r=Get-ModComparison $p -LocalOnly; [void](Save-ModListSnapshot $p $r.SaveApproval)
    Assert-True ((Get-ModListState $p).Mods[0].FileId -ceq '4515822747893123456') 'Large integer was rounded.'
}
Run-Test 'Corrupt newest list blocks rather than silently selecting an older list' {
    $p=New-Fixture; $r=Get-ModComparison $p -LocalOnly; $saved=Save-ModListSnapshot $p $r.SaveApproval
    [IO.File]::WriteAllText($saved.Path,'{broken')
    Expect-Blocked { Get-ModComparison $p -LocalOnly }
}
Run-Test 'Interrupted list publication leaves the previous complete list usable' {
    $p=New-Fixture; $r=Get-ModComparison $p -LocalOnly; $first=Save-ModListSnapshot $p $r.SaveApproval
    $r=Get-ModComparison $p -LocalOnly; $writer=${function:Write-NewJson}
    function Write-NewJson($Path,$Value){ & $writer $Path $Value; throw 'TEST: interruption before publication' }
    Expect-Blocked { Save-ModListSnapshot $p $r.SaveApproval }
    Assert-True ((Get-ModListState $p).Path -ceq $first.Path) 'Interrupted list became current.'
}
Run-Test 'Comparison refuses running ARK and ambiguous account libraries' {
    $p=New-Fixture; $script:ArkRunning=$true; Expect-Blocked { Get-ModComparison $p -LocalOnly }; $script:ArkRunning=$false
    [IO.Directory]::CreateDirectory((Join-Path $p.UserDataRoot 'another')) | Out-Null
    [IO.File]::Copy((Index-Path $p),(Join-Path $p.UserDataRoot 'another/library.json'))
    Expect-Blocked { Get-ModComparison $p -LocalOnly }
}
Run-Test 'No IDs produces no network request or save approval' {
    $rows=@(); $r=Add-CurseForgeComparison $rows 'synthetic-test-key'
    Assert-True ($r.Mode -eq 'No known mods') 'Empty collection treated as live success.'
    $p=New-Fixture; [IO.File]::WriteAllText((Index-Path $p),'{"mods":[]}')
    $r=Get-ModComparison $p -LocalOnly
    Assert-True (-not $r.CanSaveList -and $r.ModCount -eq 0) 'Empty list can be saved.'
}
Run-Test 'Published ID matches and differences stay metadata-only conclusions' {
    function Invoke-CurseForgeBatch { [pscustomobject]@{data=@([pscustomobject]@{id=123456;gameId=83374;isAvailable=$true;mainFileId=100},[pscustomobject]@{id=123457;gameId=83374;isAvailable=$true;mainFileId=200})} }
    $rows=New-OnlineRows 2; $r=Add-CurseForgeComparison $rows 'synthetic-test-key'
    Assert-True ($r.Mode -eq 'Live metadata check' -and $rows[0].OnlineState -eq 'Matches published main file ID' -and $rows[1].OnlineState -eq 'Published file differs; review update') 'Incorrect version result.'
}
Run-Test 'Unavailable API projects and unknown file IDs never count as current' {
    function Invoke-CurseForgeBatch { [pscustomobject]@{data=@([pscustomobject]@{id=123456;gameId=83374;isAvailable=$true;mainFileId=0},[pscustomobject]@{id=123457;gameId=83374;isAvailable=$false;mainFileId=100})} }
    $rows=New-OnlineRows 3; $r=Add-CurseForgeComparison $rows 'synthetic-test-key'
    Assert-True ($r.Mode -eq 'Partial live check' -and $rows[0].OnlineState -eq 'Published file unknown' -and $rows[1].OnlineState -eq 'Unavailable through API' -and $rows[2].OnlineState -eq 'Unavailable through API') 'Unknown result called current.'
}
Run-Test 'Wrong game and duplicate API projects invalidate the complete batch' {
    foreach($mode in @('wrong-game','duplicate')){
        function Invoke-CurseForgeBatch {
            $m=[pscustomobject]@{id=123456;gameId=$(if($mode -eq 'wrong-game'){1}else{83374});isAvailable=$true;mainFileId=100}
            [pscustomobject]@{data=$(if($mode -eq 'duplicate'){@($m,$m)}else{@($m)})}
        }
        $rows=New-OnlineRows 1; $r=Add-CurseForgeComparison $rows 'synthetic-test-key'
        Assert-True ($r.Mode -eq 'Partial live check' -and $rows[0].OnlineState -eq 'Online check failed' -and -not $rows[0].PublishedFileId) 'Mismatched project accepted.'
    }
}
Run-Test 'API failures stop later batches and never expose response secrets' {
    $script:batchCalls=0
    function Invoke-CurseForgeBatch { $script:batchCalls++; throw 'synthetic-private-secret' }
    $rows=New-OnlineRows 101; $r=Add-CurseForgeComparison $rows 'synthetic-test-key'
    Assert-True ($script:batchCalls -eq 1 -and $rows[100].OnlineState -eq 'Not checked after request failure' -and $r.Mode -eq 'Partial live check') 'Failed request retried or results claimed.'
    Assert-True (($script:Messages -join '|') -notmatch 'synthetic-private-secret') 'HTTP failure details leaked.'
}
Run-Test 'Requests batch 101 known projects without losing identities' {
    $script:batchSizes=New-Object 'Collections.Generic.List[int]'
    function Invoke-CurseForgeBatch($Ids,$ApiKey){
        $script:batchSizes.Add($Ids.Count)
        [pscustomobject]@{data=@($Ids | ForEach-Object {[pscustomobject]@{id=[long]$_;gameId=83374;isAvailable=$true;mainFileId=100}})}
    }
    $rows=New-OnlineRows 101; $r=Add-CurseForgeComparison $rows 'synthetic-test-key'
    Assert-True (($script:batchSizes -join ',') -eq '50,50,1' -and $r.Mode -eq 'Live metadata check') 'Batch coverage failed.'
    Assert-True (@($rows | Where-Object {$_.PublishedFileId -eq '100'}).Count -eq 101) 'Rows omitted.'
}
Run-Test 'Local mutation during an online check invalidates the report' {
    $p=New-Fixture
    function Get-CurseForgeKey { 'synthetic-test-key' }
    function Invoke-CurseForgeBatch {
        [IO.File]::AppendAllText((Index-Path $p),' ')
        [pscustomobject]@{data=@([pscustomobject]@{id=123456;gameId=83374;isAvailable=$true;mainFileId=100})}
    }
    Expect-Blocked { Get-ModComparison $p }
}
Run-Test 'Official transport uses fixed HTTPS POST and blocks redirects' {
    function Invoke-RestMethod {
        param($Uri,$Method,$ContentType,$Headers,$Body,$TimeoutSec,$MaximumRedirection,$ErrorAction)
        Assert-True ($Uri -ceq 'https://api.curseforge.com/v1/mods' -and $Method -eq 'Post' -and $MaximumRedirection -eq 0 -and $TimeoutSec -eq 15) 'Unexpected request policy.'
        $json=ConvertFrom-Json $Body
        Assert-True ($Headers['x-api-key'] -eq 'synthetic-test-key' -and $json.modIds[0] -eq 123456 -and $json.filterPcOnly -eq $false) 'Incorrect auth or IDs.'
        [pscustomobject]@{data=@()}
    }
    [void](& $originalBatch @('123456') 'synthetic-test-key')
}
Run-Test 'Official transport rejects malformed IDs and sanitizes errors' {
    Expect-Blocked { & $originalBatch @('../123456') 'synthetic-test-key' }
    function Invoke-RestMethod { throw 'synthetic-private-secret' }
    try { & $originalBatch @('123456') 'synthetic-test-key'; throw 'Transport unexpectedly succeeded' }
    catch { Assert-True ($_.Exception.Message -like 'CurseForge could not*' -and $_.Exception.Message -notmatch 'synthetic-private-secret') 'Unsafe transport error.' }
}
${function:Get-CurseForgeKey}=$originalKey
${function:Invoke-CurseForgeBatch}=$originalBatch
