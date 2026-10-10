$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ModLocket-Core.ps1') -LibraryOnly
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ModLocket-Restore-UI.ps1')
Initialize-UpdateHelpers
$Yes=$true
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('modlocket-restore-'+[guid]::NewGuid().ToString('N'))
$passed=0;$failed=0
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Block([scriptblock]$Work){$caught=$false;try{& $Work | Out-Null}catch{$caught=$true};Assert $caught 'Expected operation to stop.'}
function Test([string]$Name,[scriptblock]$Work){
    try{& $Work;$script:passed++;Write-Output "PASS $Name"}catch{$script:failed++;Write-Output "FAIL $Name : $($_.Exception.Message)";Write-Output $_.ScriptStackTrace}
}
function Write-StageProgress {}
function Write-Info {}
function Write-Good {}
function Write-Warn {}
function Assert-ArkClosed{if($script:running){throw 'Fixture ARK running.'}}
function Assert-FreeSpace{param($Destination,$RequiredBytes);if($script:full){throw 'Fixture disk full.'}}
function Start-Process{param($FilePath,$ErrorAction);$script:launches++;$script:launchUri=$FilePath}
function Invoke-Robocopy($Source,$Destination){
    [IO.Directory]::CreateDirectory($Destination)|Out-Null
    foreach($file in @(Get-SafeFiles $Source)){
        $target=Join-SafePath $Destination (Get-RelativeName $Source $file.FullName)
        [IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null
        [IO.File]::Copy($file.FullName,$target,$false)
    }
}
$realRestoreCommit=${function:Commit-ModRestoreLibrary}
function Commit-ModRestoreLibrary($Pending,$Library){if($script:interrupt){throw 'Fixture crash before record commit.'};& $realRestoreCommit $Pending $Library}
$realCopy=${function:Copy-RestoreFile}
function Copy-RestoreFile($Source,$Target,$Expected,$Library,$Hash){
    & $realCopy $Source $Target $Expected $Library $Hash
    if($script:copyInterrupt){$script:copyInterrupt=$false;throw 'Fixture crash after first file.'}
    if($script:concurrent){[IO.File]::AppendAllText($Library,' ');$script:concurrent=$false}
}
function Record([string]$Id='123456',[string]$Version='100',[string]$Status='Normal'){
    return ('{{"details":{{"id":{0},"gameId":83374,"name":"Fixture {0}"}},"installedFile":{{"id":{1},"modId":{0},"gameId":83374}},"latestUpdatedFile":{{"id":{1}}},"pathOnDisk":"83374/{0}_{1}","status":"{2}","unmanaged":false,"enabled":false,"users":[4515822747893123456],"downloadInfo":null}}' -f $Id,$Version,$Status)
}
function LibraryPath($p){return Join-Path $p.UserDataRoot 'account/library.json'}
function Set-Live($p,[string[]]$Records){[IO.File]::WriteAllText((LibraryPath $p),('{"installedMods":['+($Records -join ',')+'],"keep":4515822747893123456,"settings":{"current":true}}'))}
function Fixture {
    $script:BackupApproval=$null
    $script:running=$false;$script:full=$false;$script:interrupt=$false;$script:copyInterrupt=$false;$script:concurrent=$false;$script:launches=0;$script:ActiveWorker=$null;$script:prompt=''
    $p=Get-Paths (Join-Path $testRoot ([guid]::NewGuid().ToString('N')))
    [IO.Directory]::CreateDirectory((Join-Path $p.UserDataRoot 'account'))|Out-Null
    foreach($folder in @('123456_100','234567_200')){
        [IO.Directory]::CreateDirectory((Join-Path $p.ModsDir ($folder+'/nested')))|Out-Null
        [IO.File]::WriteAllText((Join-Path $p.ModsDir ($folder+'/main.pak')),'pak-'+$folder)
        [IO.File]::WriteAllText((Join-Path $p.ModsDir ($folder+'/nested/data.bin')),'data-'+$folder)
    }
    Set-Live $p @((Record),(Record '234567' '200'))
    [void](Invoke-GuardAction $p 'Setup')
    return $p
}
function Lose-Mod($p){[IO.Directory]::Delete((Join-Path $p.ModsDir '123456_100'),$true);Set-Live $p @((Record '234567' '200'))}
function Restore($p){$r=Invoke-GuardAction $p 'PlanRestore';$script:BackupApproval=$r.Approval;return Invoke-GuardAction $p 'RestoreMissing'}
function Check-Restored($p){$lib=Get-LibraryData (LibraryPath $p);Assert ($lib.Records.ContainsKey('123456')) 'Record missing.';Assert (([IO.File]::ReadAllText((Join-Path $p.ModsDir '123456_100/main.pak'))) -ceq 'pak-123456_100') 'Payload missing.';Assert ($script:launches -eq 0) 'Recovery unexpectedly launched Steam.'}

Test 'Entire missing mod restores files and exact record, preserving current metadata' {
    $p=Fixture;Lose-Mod $p;$before=[IO.File]::ReadAllText((LibraryPath $p));$pointer=Get-Sha256 $p.Pointer
    $r=Restore $p;Check-Restored $p
    Assert ($r.ModCount -eq 1 -and $r.FileCount -eq 2 -and $r.RecordCount -eq 1) 'Incorrect result counts.'
    $raw=[IO.File]::ReadAllText((LibraryPath $p));Assert ($raw.Contains((Record '234567' '200')) -and $raw.Contains((Record))) 'Existing or restored record changed.'
    Assert ($raw.Contains('"keep":4515822747893123456') -and $raw.Contains('"settings":{"current":true}')) 'Large integer or current preferences changed.'
    Assert ((Get-Sha256 $p.Pointer) -ceq $pointer) 'Selected backup changed.'
}
Test 'Missing record with intact files is reinserted without copying payload' {
    $p=Fixture;Set-Live $p @((Record '234567' '200'));$r=Restore $p;Check-Restored $p
    Assert ($r.FileCount -eq 0 -and $r.RecordCount -eq 1) 'Wrong record-only restore.'
}
Test 'Missing folder with intact record restores payload without rewriting records' {
    $p=Fixture;[IO.Directory]::Delete((Join-Path $p.ModsDir '123456_100'),$true);$hash=Get-Sha256 (LibraryPath $p)
    $r=Restore $p;Check-Restored $p;Assert ($r.RecordCount -eq 0 -and (Get-Sha256 (LibraryPath $p)) -ceq $hash) 'Unnecessary record change.'
}
Test 'All records and whole Mods directory may be missing' {
    $p=Fixture;[IO.Directory]::Delete($p.ModsDir,$true);Set-Live $p @();$r=Restore $p;Check-Restored $p
    Assert ($r.ModCount -eq 2 -and $r.RecordCount -eq 2 -and $r.FileCount -eq 4) 'Full missing collection not restored.'
}
Test 'Unrelated newer mod and its preferences remain unchanged' {
    $p=Fixture;Lose-Mod $p;[IO.Directory]::Move((Join-Path $p.ModsDir '234567_200'),(Join-Path $p.ModsDir '234567_201'))
    Set-Live $p @((Record '234567' '201'));$r=Restore $p;Check-Restored $p
    Assert ($r.AttentionCount -eq 1 -and (Get-LibraryData (LibraryPath $p)).Records['234567'].FileId -ceq '201') 'Newer version downgraded.'
}
Test 'Newly added unrelated mod is retained while old missing mod is recovered' {
    $p=Fixture;Lose-Mod $p;[IO.Directory]::CreateDirectory((Join-Path $p.ModsDir '345678_300'))|Out-Null
    [IO.File]::WriteAllText((Join-Path $p.ModsDir '345678_300/new.pak'),'new')
    Set-Live $p @((Record '234567' '200'),(Record '345678' '300'));[void](Restore $p);Check-Restored $p
    Assert ((Get-LibraryData (LibraryPath $p)).Records.ContainsKey('345678')) 'Added mod removed.'
}
Test 'OutOfDate status and enabled preference survive missing-file restore' {
    $p=Fixture;Set-Live $p @((Record '123456' '100' 'OutOfDate'),(Record '234567' '200'))
    [IO.File]::Delete((Join-Path $p.ModsDir '123456_100/main.pak'));$hash=Get-Sha256 (LibraryPath $p)
    [void](Restore $p);Check-Restored $p;Assert ((Get-Sha256 (LibraryPath $p)) -ceq $hash) 'Status or preference overwritten.'
}
Test 'Pending unrelated mod does not block restoring a different missing mod' {
    $p=Fixture;Lose-Mod $p;Set-Live $p @((Record '234567' '200' 'Pending'));$r=Restore $p;Check-Restored $p
    Assert ($r.AttentionCount -eq 1 -and (Get-LibraryData (LibraryPath $p)).Records['234567'].LibraryStatus -ceq 'Pending') 'Pending state changed.'
}
Test 'Different installed version is skipped even if files are missing' {
    $p=Fixture;[IO.Directory]::Delete((Join-Path $p.ModsDir '123456_100'),$true)
    Set-Live $p @((Record '123456' '101'),(Record '234567' '200'));$r=Get-ModRestoreReview $p
    Assert ($r.ModCount -eq 0 -and $r.AttentionCount -eq 1) 'Downgrade offered.'
}
Test 'Conflicting file content is skipped without overwriting it' {
    $p=Fixture;Set-Live $p @((Record '234567' '200'));$file=Join-Path $p.ModsDir '123456_100/main.pak';[IO.File]::WriteAllText($file,'changed')
    $r=Get-ModRestoreReview $p;Assert ($r.ModCount -eq 0 -and $r.AttentionCount -eq 1) 'Conflict offered for restore.'
    Assert ([IO.File]::ReadAllText($file) -ceq 'changed') 'Existing payload overwritten.'
}
Test 'Damaged backup cannot be offered for recovery' {
    $p=Fixture;Lose-Mod $p;$s=Load-Snapshot $p;[IO.File]::WriteAllText((Join-Path $s.Root 'Mods/123456_100/main.pak'),'bad')
    $r=Get-ModRestoreReview $p;Assert ($r.ModCount -eq 0 -and $r.AttentionCount -eq 1) 'Damaged backup offered.'
}
Test 'Stale preview cannot write into a changed mod library' {
    $p=Fixture;Lose-Mod $p;$r=Get-ModRestoreReview $p;[IO.File]::AppendAllText((LibraryPath $p),' ')
    Block {Restore-MissingMods $p $r.Approval};Assert (-not(Test-Path (Join-Path $p.ModsDir '123456_100'))) 'Stale plan wrote payload.'
}
Test 'An installed file appearing after preview invalidates it' {
    $p=Fixture;Lose-Mod $p;$r=Get-ModRestoreReview $p
    [IO.Directory]::CreateDirectory((Join-Path $p.ModsDir '123456_100'))|Out-Null;[IO.File]::WriteAllText((Join-Path $p.ModsDir '123456_100/main.pak'),'pak-123456_100')
    Block {Restore-MissingMods $p $r.Approval}
}
Test 'Interrupted copy resumes and commits records only after complete verification' {
    $p=Fixture;Lose-Mod $p;$hash=Get-Sha256 (LibraryPath $p);$r=Get-ModRestoreReview $p;$script:copyInterrupt=$true
    Block {Restore-MissingMods $p $r.Approval};Assert ((Get-Sha256 (LibraryPath $p)) -ceq $hash) 'Records published before complete payload.'
    Repair-InterruptedRestores $p;Check-Restored $p;Repair-InterruptedRestores $p
    Assert ((Get-LibraryData (LibraryPath $p)).Entries.Count -eq 2) 'Replay duplicated records.'
}
Test 'Failure before atomic record commit is recoverable' {
    $p=Fixture;Lose-Mod $p;$hash=Get-Sha256 (LibraryPath $p);$r=Get-ModRestoreReview $p;$script:interrupt=$true
    Block {Restore-MissingMods $p $r.Approval};Assert ((Get-Sha256 (LibraryPath $p)) -ceq $hash) 'Failed commit changed records.'
    $script:interrupt=$false;Repair-InterruptedRestores $p;Check-Restored $p
}
Test 'External record changes during recovery stop replay without overwriting them' {
    $p=Fixture;Lose-Mod $p;$r=Get-ModRestoreReview $p;$script:concurrent=$true
    Block {Restore-MissingMods $p $r.Approval};$hash=Get-Sha256 (LibraryPath $p)
    Block {Repair-InterruptedRestores $p};Assert ((Get-Sha256 (LibraryPath $p)) -ceq $hash) 'External record changes overwritten.'
}
Test 'Running ARK and insufficient space prevent writes' {
    $p=Fixture;Lose-Mod $p;$r=Get-ModRestoreReview $p;$script:running=$true;Block {Restore-MissingMods $p $r.Approval}
    $script:running=$false;$script:full=$true;Block {Restore-MissingMods $p $r.Approval}
    Assert (-not(Test-Path (Join-Path $p.ModsDir '123456_100'))) 'Wrote under blocked conditions.'
}
Test 'Missing backup or changed account cannot be guessed' {
    $p=Fixture;[IO.File]::Delete($p.Pointer);Block {Get-ModRestoreReview $p}
    $p=Fixture;[IO.Directory]::Move((Join-Path $p.UserDataRoot 'account'),(Join-Path $p.UserDataRoot 'other'));Block {Get-ModRestoreReview $p}
}
Test 'Duplicate and malformed records are rejected before restoration' {
    $p=Fixture;Set-Live $p @((Record),(Record));Block {Get-ModRestoreReview $p}
    Set-Live $p @('{"details":{"id":null}}');Block {Get-ModRestoreReview $p}
}
Test 'Linked installed destinations are never followed' {
    $p=Fixture;Lose-Mod $p;$outside=Join-Path $p.ArkRoot 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null
    $kind=if($env:OS -eq 'Windows_NT'){'Junction'}else{'SymbolicLink'}
    New-Item -ItemType $kind -Path (Join-Path $p.ModsDir '123456_100') -Target $outside|Out-Null
    $r=Get-ModRestoreReview $p;Assert ($r.ModCount -eq 0 -and $r.AttentionCount -eq 1) 'Linked target accepted.'
    Assert (@(Get-ChildItem $outside).Count -eq 0) 'Wrote through link.'
}
Test 'Exact insertion supports older flat and root-array backup formats' {
    foreach($pair in @(@('{"mods":[],"large":4515822747893123456}','{"mods":[{"modId":123456,"fileId":100}]}'),@('[]','[{"modId":123456,"fileId":100}]'))){
        $raw=[ModLocket.JsonPatch]::RestoreRecords($pair[0],$pair[1],[string[]]@('123456'));Assert ($raw.Contains('"fileId":100')) 'Flat insertion failed.'
    }
    Block {[ModLocket.JsonPatch]::RestoreRecords('{"mods":[]}','{"installedMods":[]}',[string[]]@())}
}

# Exercise the actual UI launch callback without WinForms or a real Steam call.
function Ensure-ArkRoot{return $true}
function Set-StatusPill{}
function Add-LogLine{}
function Show-ThemedMessage($Message,$Title){$script:prompt=$Message}
$Colors=@{Warning='Warning'};$progressLabel=[pscustomobject]@{Text=''}
Test 'Launch anyway accepts OutOfDate and Pending without editing or disabling mods' {
    $p=Fixture;Set-Live $p @((Record '123456' '100' 'OutOfDate'),(Record '234567' '200' 'Pending'));$script:ArkRoot=$p.ArkRoot
    $hash=Get-Sha256 (LibraryPath $p);$fileHash=Get-Sha256 (Join-Path $p.ModsDir '123456_100/main.pak')
    Request-LaunchAnyway
    Assert ($script:launches -eq 1 -and $script:launchUri -ceq 'steam://launch/2399830/option1') 'Steam launch not requested.'
    Assert ((Get-Sha256 (LibraryPath $p)) -ceq $hash -and (Get-Sha256 (Join-Path $p.ModsDir '123456_100/main.pak')) -ceq $fileHash) 'Launch changed mods.'
}
Test 'Launch anyway does not require a snapshot or API key' {
    $p=Fixture;$script:ArkRoot=$p.ArkRoot;[IO.File]::Delete($p.Pointer);Request-LaunchAnyway
    Assert ($script:launches -eq 1) 'Unnecessary backup gate blocked launch.'
}
Test 'Launch anyway refuses active or unfinished writes' {
    $p=Fixture;$script:ArkRoot=$p.ArkRoot;$script:ActiveWorker=[pscustomobject]@{Busy=$true};Request-LaunchAnyway
    Assert ($script:launches -eq 0) 'Raced active worker.';$script:ActiveWorker=$null
    Lose-Mod $p;$r=Get-ModRestoreReview $p;$script:interrupt=$true;Block {Restore-MissingMods $p $r.Approval}
    Request-LaunchAnyway;Assert ($script:launches -eq 0 -and $script:prompt -match 'interrupted') 'Raced interrupted restore.'
}
Write-Output "RESULT: $passed passed; $failed failed."
Write-Output 'These are synthetic recovery/launch tests; they do not verify ARK loading or the Windows UI.'
if($failed){exit 1}
