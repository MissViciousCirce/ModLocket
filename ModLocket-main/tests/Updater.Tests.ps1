$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ModLocket-Core.ps1') -LibraryOnly
Initialize-UpdateHelpers
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('modlocket-updates-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
$script:failed=0;$script:passed=0
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Block([scriptblock]$Work){$caught=$false;try{& $Work|Out-Null}catch{$caught=$true};Assert $caught 'Expected operation to fail.'}
function Test([string]$Name,[scriptblock]$Work){
    try{& $Work;$script:passed++;Write-Host "PASS $Name"}catch{$script:failed++;Write-Host "FAIL $Name : $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}
}
function Assert-ArkClosed {if($script:running){throw 'Test ARK running.'}}
function Assert-FreeSpace {param($Destination,$RequiredBytes);if($script:full){throw 'Test disk full.'}}
function Get-CurseForgeKey {return 'fixture-key-not-real'}
$realCommit=${function:Commit-ModUpdateLibrary}
function Commit-ModUpdateLibrary($Pending,$Library){if($script:interrupt){throw 'Test crash before metadata commit.'};& $realCommit $Pending $Library}
function Receive-ModArchive($Url,$Destination,$Length,$ApiKey){
    if($script:networkFail){throw 'Test network interruption.'}
    [IO.File]::Copy($script:archive,$Destination,$false)
    if($script:corrupt){[IO.File]::AppendAllText($Destination,'bad')}
}
function Invoke-CurseForgeBatch {param($Ids,$ApiKey);return [pscustomobject]@{data=@([pscustomobject]@{id=123456;gameId=83374;isAvailable=$true;isPremium=$false;allowModDistribution=$script:distribution;latestFiles=@($script:file)})}}
function Invoke-CurseForgeGet($Route,$ApiKey){
    if($Route -eq 'mods/123456/files/200'){return [pscustomobject]@{data=$script:file}}
    if($Route -eq 'mods/123456/files/200/download-url'){if($script:denyUrl){throw 'Fixture download access denied'};return [pscustomobject]@{data='https://edge.forgecdn.net/files/0/200/test-windows.zip'}}
    throw ('Unexpected route '+$Route)
}
function Fixture {
    $script:distribution=$null;$script:denyUrl=$false;$script:running=$false;$script:full=$false;$script:interrupt=$false;$script:networkFail=$false;$script:corrupt=$false
    $p=Get-Paths (Join-Path $testRoot ([guid]::NewGuid().ToString('N')))
    [IO.Directory]::CreateDirectory((Join-Path $p.ModsDir '123456_100/Fixture'))|Out-Null
    [IO.Directory]::CreateDirectory($p.UserDataRoot)|Out-Null
    [IO.File]::WriteAllText((Join-Path $p.ModsDir '123456_100/Fixture/old.pak'),'old-data')
    $payload=Join-Path $p.ArkRoot 'payload';[IO.Directory]::CreateDirectory((Join-Path $payload 'Fixture'))|Out-Null
    [IO.File]::WriteAllText((Join-Path $payload 'Fixture/new.pak'),'new-package-data')
    $script:archive=Join-Path $p.ArkRoot 'download.zip';[IO.Compression.ZipFile]::CreateFromDirectory($payload,$script:archive)
    $script:file=[pscustomobject]@{id=200;modId=123456;gameId=83374;isAvailable=$true;fileStatus=4;releaseType=1;isServerPack=$false;fileName='fixture-windows 2.zip';fileLength=(Get-Item $script:archive).Length;fileSizeOnDisk=16;modules=@([pscustomobject]@{name='Fixture';fingerprint=123});hashes=@([pscustomobject]@{algo=1;value=(Get-FileHash $script:archive -Algorithm SHA1).Hash});dependencies=@();gameVersions=@('Windows')}
    $json='{"installedMods":[{"details":{"id":123456,"gameId":83374,"name":"Fixture"},"installedFile":{"id":100,"modId":123456,"gameId":83374},"latestUpdatedFile":{"id":200},"pathOnDisk":"83374/123456_100","status":"OutOfDate","unmanaged":false,"enabled":false,"users":["owner"],"dateInstalled":"old","downloadInfo":null}],"untouched":4515822747893123456}'
    [IO.File]::WriteAllText((Join-Path $p.UserDataRoot 'library.json'),$json)
    return $p
}
function CheckOriginal($p,$hash){Assert ((Get-Sha256 (Find-LibraryJson $p.UserDataRoot)) -ceq $hash) 'Metadata changed on failure.';Assert (Test-Path (Join-Path $p.ModsDir '123456_100/Fixture/old.pak')) 'Old payload lost.';Assert (-not(Test-Path (Join-Path $p.ModsDir '123456_200'))) 'New live folder left after failure.'}
try{
 Test 'Complete approved update preserves old version, ownership and large integers' {
    $p=Fixture;$before=Get-Sha256 (Find-LibraryJson $p.UserDataRoot);$plan=Get-ModUpdatePlan $p
    Assert ($plan.UpdateCount -eq 1) ('No plan: '+($plan.Rows|ConvertTo-Json -Compress))
    $result=Install-ModUpdates $p $plan.Id $plan.Approval
    Assert ($result.Status -ceq 'UpdatesInstalled') 'No success result.'
    $s=Get-UpdateInput $p;Assert ($s.Library.Records['123456'].FileId -ceq '200') 'Wrong installed ID.'
    $raw=[IO.File]::ReadAllText($s.Path);Assert ($raw.Contains('4515822747893123456')) 'Large integer changed.';Assert ($raw.Contains('"enabled":false') -and $raw.Contains('"users":["owner"]')) 'User preferences changed.'
    Assert (Test-Path (Join-Path $result.RecoveryPath 'previous/123456_100/Fixture/old.pak')) 'Recovery copy missing.'
    Assert (Test-Path (Join-Path $p.ModsDir '123456_200/Fixture/new.pak')) 'New package missing.'
    Assert (-not(Test-Path $p.Pointer)) 'Backup selection modified.'
 }
 Test 'Current restricted mod is current without download permission or archive metadata' {
    $p=Fixture;$script:distribution=$false;$script:denyUrl=$true;$script:file.id=100;$script:file.hashes=@();$script:file.modules=@()
    $plan=Get-ModUpdatePlan $p
    Assert ($plan.UpdateCount -eq 0 -and $plan.AttentionCount -eq 0 -and $plan.Rows[0].State -eq 'Current') 'Current restricted mod misclassified.'
 }
 Test 'New restricted version is visible but never offered for installation' {
    $p=Fixture;$script:distribution=$false;$hash=Get-Sha256 (Find-LibraryJson $p.UserDataRoot)
    $plan=Get-ModUpdatePlan $p
    Assert ($plan.UpdateCount -eq 0 -and $plan.Rows[0].Available -eq '200' -and $plan.Rows[0].State -eq 'Update blocked') 'Restriction or release identity lost.'
    CheckOriginal $p $hash
 }
 Test 'Denied official URL is excluded during planning' {
    $p=Fixture;$script:denyUrl=$true;$plan=Get-ModUpdatePlan $p
    Assert ($plan.UpdateCount -eq 0 -and $plan.AttentionCount -eq 1 -and $plan.Rows[0].Reason -match 'download access denied') 'Inaccessible update was offered.'
 }
 Test 'Network failure leaves library and installed files untouched' {$p=Fixture;$hash=Get-Sha256 (Find-LibraryJson $p.UserDataRoot);$plan=Get-ModUpdatePlan $p;$script:networkFail=$true;Block {Install-ModUpdates $p $plan.Id $plan.Approval};CheckOriginal $p $hash}
 Test 'Truncated or corrupted archive never installs' {$p=Fixture;$hash=Get-Sha256 (Find-LibraryJson $p.UserDataRoot);$plan=Get-ModUpdatePlan $p;$script:corrupt=$true;Block {Install-ModUpdates $p $plan.Id $plan.Approval};CheckOriginal $p $hash}
 Test 'Interruption after directory publication rolls back before metadata commit' {$p=Fixture;$hash=Get-Sha256 (Find-LibraryJson $p.UserDataRoot);$plan=Get-ModUpdatePlan $p;$script:interrupt=$true;Block {Install-ModUpdates $p $plan.Id $plan.Approval};CheckOriginal $p $hash}
 Test 'Stale local state rejects installation' {$p=Fixture;$plan=Get-ModUpdatePlan $p;$lib=Find-LibraryJson $p.UserDataRoot;[IO.File]::AppendAllText($lib,' ');$hash=Get-Sha256 $lib;Block {Install-ModUpdates $p $plan.Id $plan.Approval};CheckOriginal $p $hash}
 Test 'Running ARK and full disk block mutation' {$p=Fixture;$hash=Get-Sha256 (Find-LibraryJson $p.UserDataRoot);$plan=Get-ModUpdatePlan $p;$script:running=$true;Block {Install-ModUpdates $p $plan.Id $plan.Approval};$script:running=$false;$script:full=$true;Block {Install-ModUpdates $p $plan.Id $plan.Approval};CheckOriginal $p $hash}
 Test 'WindowsServer and unavailable builds are rejected' {$p=Fixture;$script:file.fileName='fixture-windowsserver 2.zip';Assert (-not(Test-WindowsClientFile $script:file)) 'Server release accepted.';$script:file.fileName='fixture-windows 2.zip';$script:file.isAvailable=$false;Block {Assert-UpdateFile $script:file '123456'}}
 Test 'Pending installs are excluded without changing status' {$p=Fixture;$lib=Find-LibraryJson $p.UserDataRoot;[IO.File]::WriteAllText($lib,[IO.File]::ReadAllText($lib).Replace('OutOfDate','Pending'));$hash=Get-Sha256 $lib;$plan=Get-ModUpdatePlan $p;Assert ($plan.UpdateCount -eq 0 -and $plan.AttentionCount -eq 1) 'Pending install accepted.';CheckOriginal $p $hash}
 Test 'ZIP traversal and links are rejected' {
    $p=Fixture;$bad=Join-Path $p.ArkRoot 'evil.zip';$zip=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Create);[void]$zip.CreateEntry('../escape.pak');$zip.Dispose()
    $script:file.fileLength=(Get-Item $bad).Length;$script:file.hashes[0].value=(Get-FileHash $bad -Algorithm SHA1).Hash
    Block {Expand-VerifiedMod $script:file $bad (Join-Path $p.ArkRoot 'extract')};Assert (-not(Test-Path (Join-Path $p.ArkRoot 'escape.pak'))) 'Archive escaped root.'
 }
 Test 'Same-size checksum tampering is rejected' {
    $p=Fixture;$script:file.hashes[0].value=('0'*40)
    Block {Expand-VerifiedMod $script:file $script:archive (Join-Path $p.ArkRoot 'extract')}
 }
 Test 'Case-colliding ZIP paths and symbolic links are rejected' {
    $p=Fixture
    foreach($kind in @('case','link')){
        $bad=Join-Path $p.ArkRoot ($kind+'.zip');$zip=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Create)
        if($kind -eq 'case'){[void]$zip.CreateEntry('Fixture/A.pak');[void]$zip.CreateEntry('Fixture/a.pak')}
        else{$entry=$zip.CreateEntry('Fixture/link');$entry.ExternalAttributes=-1610612736}
        $zip.Dispose();$script:file.fileLength=(Get-Item $bad).Length;$script:file.hashes[0].value=(Get-FileHash $bad -Algorithm SHA1).Hash
        Block {Expand-VerifiedMod $script:file $bad (Join-Path $p.ArkRoot ('extract-'+$kind))}
    }
 }
 Test 'Next operation recovers a process killed before metadata commit' {
    $p=Fixture;$hash=Get-Sha256 (Find-LibraryJson $p.UserDataRoot);$plan=Get-ModUpdatePlan $p
    $recover=${function:Repair-InterruptedUpdates};$script:interrupt=$true
    try{function Repair-InterruptedUpdates {};Block {Install-ModUpdates $p $plan.Id $plan.Approval}}
    finally{${function:Repair-InterruptedUpdates}=$recover;$script:interrupt=$false}
    Assert (Test-Path (Join-Path $p.ModsDir '123456_200')) 'Crash fixture did not publish a folder.'
    Repair-InterruptedUpdates $p;CheckOriginal $p $hash
 }
 Test 'Next operation finishes archiving after metadata committed' {
    $p=Fixture;$plan=Get-ModUpdatePlan $p;$complete=${function:Complete-UpdateRecovery}
    try{function Complete-UpdateRecovery {throw 'Test kill after metadata commit.'};Block {Install-ModUpdates $p $plan.Id $plan.Approval}}
    finally{${function:Complete-UpdateRecovery}=$complete}
    Assert ((Get-UpdateInput $p).Library.Records['123456'].FileId -ceq '200') 'Commit fixture failed.'
    Repair-InterruptedUpdates $p
    Assert (-not(Test-Path (Join-Path $p.ModsDir '123456_100'))) 'Old folder remained live after recovery.'
    $dir=@(Get-UpdateTransactions $p)[0].FullName
    Assert (Test-Path (Join-Path $dir 'previous/123456_100/Fixture/old.pak')) 'Old data lost after recovery.'
 }
 Test 'Recovery never overwrites metadata changed by another application' {
    $p=Fixture;$plan=Get-ModUpdatePlan $p;$recover=${function:Repair-InterruptedUpdates};$script:interrupt=$true
    try{function Repair-InterruptedUpdates {};Block {Install-ModUpdates $p $plan.Id $plan.Approval}}
    finally{${function:Repair-InterruptedUpdates}=$recover;$script:interrupt=$false}
    $lib=Find-LibraryJson $p.UserDataRoot;[IO.File]::AppendAllText($lib,' ');$changed=Get-Sha256 $lib
    Block {Repair-InterruptedUpdates $p};Assert ((Get-Sha256 $lib) -ceq $changed) 'Externally changed metadata overwritten.'
 }
 Test 'API key only goes to approved HTTPS CDN hosts' {foreach($url in @('http://edge.forgecdn.net/files/a','https://edge.forgecdn.net.evil.test/files/a','https://user@edge.forgecdn.net/files/a','https://edge.forgecdn.net/files/a?api-key=secret','https://127.0.0.1/files/a')){Block {Assert-DownloadUri $url}};[void](Assert-DownloadUri 'https://edge.forgecdn.net/files/1/2/a.zip')}
 Test 'Metadata patch rejects duplicate keys and stale download bookkeeping' {
    $p=Fixture;$raw=[IO.File]::ReadAllText((Find-LibraryJson $p.UserDataRoot));$f=ConvertTo-Json -Depth 40 -Compress $script:file
    Block {[ModLocket.JsonPatch]::Update($raw.Replace('"unmanaged":false','"unmanaged":false,"unmanaged":false'),'123456',$f,'"83374/123456_200"','"now"')}
    Block {[ModLocket.JsonPatch]::Update($raw.Replace('"downloadInfo":null','"downloadInfo":{"url":"pending"}'),'123456',$f,'"83374/123456_200"','"now"')}
 }
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force}
Write-Host "$script:passed passed; $script:failed failed"
if($script:failed){exit 1}
