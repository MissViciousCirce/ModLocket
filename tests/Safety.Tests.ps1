[CmdletBinding()]
param([switch]$NativeCopy, [string]$LockProbe)
$ErrorActionPreference = 'Stop'
if ($LockProbe) {
    try {
        $handle = [IO.File]::Open($LockProbe, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $handle.Dispose(); exit 0
    } catch { exit 23 }
}
$release = Split-Path $PSScriptRoot -Parent
foreach ($scriptFile in @(Get-ChildItem -LiteralPath $release -Filter '*.ps1') + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1')) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
}
. (Join-Path $release 'ModLocket-Core.ps1') -LibraryOnly
$Yes = $true
$script:NativeCopyEnabled = [bool]$NativeCopy
$script:OriginalCopy = ${function:Invoke-Robocopy}
$script:OriginalCommit = ${function:Commit-SnapshotPointer}
$script:OriginalTreeCheck = ${function:Assert-TreeMatches}
$script:NativeSpaceCheck = ${function:Assert-FreeSpace}
$script:Messages = New-Object 'Collections.Generic.List[string]'
$script:Launches = 0
$script:CopyFailure = $null
$script:CommitFailure = $false
$script:LowSpace = $false
$script:ArkRunning = $false
$script:CopySideEffect = $null
$script:AfterSourceCheck = $null
$script:TestResults = New-Object 'Collections.Generic.List[object]'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ModLocket-Safety-Tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
function Write-Info([string]$Text) { $script:Messages.Add($Text) }
function Write-Good([string]$Text) { $script:Messages.Add($Text) }
function Write-Warn([string]$Text) { $script:Messages.Add($Text) }
function Assert-ArkClosed { if ($script:ArkRunning) { throw 'TEST: ARK started.' } }
function Start-Process { param($FilePath, $ErrorAction); $script:Launches++; if ($script:LaunchFailure) { throw 'TEST: Steam unavailable.' } }
function Assert-FreeSpace($Destination, $RequiredBytes) {
    if ($script:LowSpace) { throw 'TEST: insufficient free space.' }
    # Keep space checks deterministic; native Windows tests separately call the real helper.
}
function Commit-SnapshotPointer($Paths, $Snapshot) {
    if ($script:CommitFailure) { throw 'TEST: interrupted just before pointer replacement.' }
    & $script:OriginalCommit $Paths $Snapshot
}
function Assert-TreeMatches($Root, $Files) {
    & $script:OriginalTreeCheck $Root $Files
    if ($script:AfterSourceCheck -and $Root -like '*/Mods/83374') { & $script:AfterSourceCheck }
}
function Invoke-Robocopy($Source, $Destination) {
    if ($script:CopyFailure -eq 'before') { throw 'TEST: interrupted before copy.' }
    # Deterministic partial-copy injection must run in both test modes.
    # Native process cancellation is exercised separately by Worker.Tests.ps1.
    if ($script:NativeCopyEnabled -and $script:CopyFailure -ne 'partial') { & $script:OriginalCopy $Source $Destination }
    else {
        [IO.Directory]::CreateDirectory($Destination) | Out-Null
        foreach ($file in @(Get-SafeFiles $Source)) {
            $dest = Join-SafePath $Destination (Get-RelativeName $Source $file.FullName)
            [IO.Directory]::CreateDirectory((Split-Path $dest -Parent)) | Out-Null
            [IO.File]::Copy($file.FullName, $dest, $false)
            if ($script:CopyFailure -eq 'partial') { throw 'TEST: interrupted during copy.' }
        }
    }
    if ($script:CopyFailure -eq 'after') { throw 'TEST: interrupted after copy.' }
    if ($script:CopySideEffect) { & $script:CopySideEffect $Source $Destination }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION: $Message" } }
function Expect-Blocked([scriptblock]$Work) {
    $thrown = $false
    try { & $Work | Out-Null } catch { $thrown = $true }
    Assert-True $thrown 'Operation should have been blocked.'
    Assert-True ($script:Launches -eq 0) 'A blocked operation must not launch Steam.'
}
function Run-Test([string]$Name, [scriptblock]$Body) {
    $script:CancelRequested = $false; $script:ClosePromptActive = $false; $script:LaunchApprovalNotBefore = [DateTime]::MinValue
    $script:BackupApproval = $null; $script:TargetId = $null; $script:ManagementApproval = $null
    $script:Launches = 0; $script:CopyFailure = $null; $script:CommitFailure = $false
    $script:LowSpace = $false; $script:ArkRunning = $false; $script:CopySideEffect = $null
    $script:LaunchFailure = $false; $script:AfterSourceCheck = $null; $script:Messages.Clear()
    try { & $Body; $script:TestResults.Add([pscustomobject]@{ Name = $Name; Passed = $true }); Write-Output "PASS | $Name" }
    catch { $script:TestResults.Add([pscustomobject]@{ Name = $Name; Passed = $false }); Write-Output "FAIL | $Name | $($_.Exception.Message)"; Write-Output $_.ScriptStackTrace }
}
function New-Fixture {
    $root = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $p = Get-Paths $root
    [IO.Directory]::CreateDirectory((Join-Path $p.ModsDir '123456_100/nested')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $p.UserDataRoot 'account')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $p.ModsDir '123456_100/main.pak'), 'original-payload')
    [IO.File]::WriteAllText((Join-Path $p.ModsDir '123456_100/nested/data.bin'), 'second-payload')
    [IO.File]::WriteAllText((Join-Path $p.UserDataRoot 'account/library.json'), '{"mods":[{"modId":123456,"fileId":100,"status":"valid","name":"Fixture"}],"unrelated":{"keep":true}}')
    return $p
}
function Seed-Snapshot($Paths) { [void](Invoke-GuardAction $Paths 'Setup'); return Load-Snapshot $Paths }
function Index-Path($Paths) { return Join-Path $Paths.UserDataRoot 'account/library.json' }
function Assert-PriorIntact($Paths, $Snapshot, [string]$PointerHash) {
    Assert-True ((Get-Sha256 $Paths.Pointer) -eq $PointerHash) 'The selected snapshot pointer changed after failure.'
    Assert-True ((Load-Snapshot $Paths).Id -eq $Snapshot.Id) 'Previous snapshot not selected.'
    Assert-SnapshotContent $Snapshot
}

Write-Output "ModLocket safety tests | PowerShell $($PSVersionTable.PSVersion) | Native Robocopy: $NativeCopy"
Write-Output 'Uses only synthetic temporary folders. Never launches Steam, finds ARK, or reads real mod data.'
Run-Test 'Initial snapshot hashes files and keeps library bytes unchanged' {
    $p = New-Fixture; $hash = Get-Sha256 (Index-Path $p); $s = Seed-Snapshot $p
    Assert-SnapshotContent $s
    Assert-True ($s.Manifest.Files.Count -eq 2) 'Expected two files.'
    Assert-True ($hash -eq (Get-Sha256 (Index-Path $p))) 'Live metadata was modified.'
}
Run-Test 'Verified unchanged content returns an explicit result and requests launch once' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $result = Invoke-GuardAction $p 'Launch'
    Assert-True ($result.Status -eq 'Verified' -and $result.FilesChecked -eq 2 -and $script:Launches -eq 1) 'Expected complete verification.'
}
Run-Test 'Missing single file restored with exact hash' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::Delete((Join-Path $p.ModsDir '123456_100/main.pak'))
    $r = Invoke-GuardAction $p 'Launch'
    Assert-True ($r.FilesRestored -eq 1 -and $script:Launches -eq 1) 'Missing file was not safely restored.'
    Assert-TreeMatches $p.ModsDir $s.Manifest.Files
}
Run-Test 'Missing complete mod folder restored only for the indexed protected version' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'), (Join-Path $p.ArkRoot 'removed-fixture'))
    $r = Invoke-GuardAction $p 'Launch'; Assert-True ($r.FilesRestored -eq 2) 'Expected whole-folder missing-file repair.'
}
Run-Test 'Missing live file and missing backup file block launch without writes' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::Delete((Join-Path $p.ModsDir '123456_100/main.pak'))
    [IO.File]::Delete((Join-Path $s.Root 'Mods/123456_100/main.pak'))
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
    Assert-True (-not (Test-Path (Join-Path $p.ModsDir '123456_100/main.pak'))) 'Unexpected restoration from incomplete snapshot.'
}
Run-Test 'Corrupt backup payload blocks even with healthy live files' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::WriteAllText((Join-Path $s.Root 'Mods/123456_100/main.pak'), 'corrupted')
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
}
foreach ($badJson in @('{broken', '{}', '{"mods":[]}', 'null', '{"unknown":[]}', '{"mods":{}}')) {
    Run-Test "Bad or empty live index blocks: $badJson" {
        $p = New-Fixture; $s = Seed-Snapshot $p
        [IO.File]::WriteAllText((Index-Path $p), $badJson)
        Expect-Blocked { Invoke-GuardAction $p 'Launch' }
        Assert-True ([IO.File]::ReadAllText((Index-Path $p)) -eq $badJson) 'Index must not be rewritten.'
    }
}
Run-Test 'Missing whole live index is not guessed or rewritten' {
    $p = New-Fixture; $s = Seed-Snapshot $p; [IO.File]::Delete((Index-Path $p))
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
    Assert-True (-not (Test-Path (Index-Path $p))) 'Index must remain untouched.'
}
Run-Test 'Corrupt backup index blocks launch' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::WriteAllText((Join-Path $s.Root 'Metadata/account/library.json'), '{broken')
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
}
Run-Test 'Empty manifest cannot produce ready result' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::WriteAllText((Join-Path $s.Root 'manifest.json'), '{}')
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
}
Run-Test 'Empty or corrupted active pointer blocks without deleting snapshots' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::WriteAllText($p.Pointer, '{}'); Expect-Blocked { Invoke-GuardAction $p 'Launch' }
    Assert-SnapshotContent $s
}
Run-Test 'Changed installed version does not resurrect older backup folder' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'), (Join-Path $p.ModsDir '123456_200'))
    [IO.File]::WriteAllText((Index-Path $p), '{"mods":[{"modId":123456,"fileId":200,"status":"valid"}]}')
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
    Assert-True (-not (Test-Path (Join-Path $p.ModsDir '123456_100'))) 'Obsolete folder was restored.'
}
Run-Test 'Changed same-length content blocks; it is never overwritten' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $path = Join-Path $p.ModsDir '123456_100/main.pak'
    [IO.File]::WriteAllText($path, 'modified-payload'); Expect-Blocked { Invoke-GuardAction $p 'Launch' }
    Assert-True ([IO.File]::ReadAllText($path) -eq 'modified-payload') 'Existing file was overwritten.'
}
Run-Test 'New files in protected folders require a new verified baseline' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::WriteAllText((Join-Path $p.ModsDir '123456_100/new.bin'), 'new')
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
}
Run-Test 'A second library/account is rejected rather than chosen by timestamp' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.Directory]::CreateDirectory((Join-Path $p.UserDataRoot 'another')) | Out-Null
    [IO.File]::Copy((Index-Path $p), (Join-Path $p.UserDataRoot 'another/library.json'))
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
}
Run-Test 'Repeated setup cannot overwrite an existing snapshot' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }; Assert-PriorIntact $p $s $hash
}
Run-Test 'Successful refresh selects new snapshot and retains prior contents' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::WriteAllText((Join-Path $p.ModsDir '123456_100/main.pak'), 'new-working-content')
    [void](Invoke-GuardAction $p 'Refresh'); $new = Load-Snapshot $p
    Assert-True ($new.Id -ne $s.Id -and $new.Pointer.Previous -eq $s.Id) 'New snapshot not linked to previous.'
    Assert-SnapshotContent $s; Assert-SnapshotContent $new
}
foreach ($failure in @('before', 'partial', 'after')) {
    Run-Test "Interrupted backup ($failure copy) preserves selected snapshot" {
        $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
        $script:CopyFailure = $failure
        # Native copy interruption is simulated after copy for the partial case.
        if ($NativeCopy -and $failure -eq 'partial') { $script:CopyFailure = 'after' }
        Expect-Blocked { Invoke-GuardAction $p 'Refresh' }
        Assert-PriorIntact $p $s $hash
    }
}
Run-Test 'Failure just before pointer commit leaves selected snapshot intact' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $script:CommitFailure = $true; Expect-Blocked { Invoke-GuardAction $p 'Refresh' }
    Assert-PriorIntact $p $s $hash
}
Run-Test 'Low disk space blocks refresh and preserves old snapshot' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $script:LowSpace = $true; Expect-Blocked { Invoke-GuardAction $p 'Refresh' }
    Assert-PriorIntact $p $s $hash
}
Run-Test 'Source payload changed during copy blocks commit' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $script:CopySideEffect = { param($Source,$Destination); [IO.File]::WriteAllText((Join-Path $Source '123456_100/main.pak'), 'changed-mid-copy') }
    Expect-Blocked { Invoke-GuardAction $p 'Refresh' }; Assert-PriorIntact $p $s $hash
}
Run-Test 'Corrupted staged copy is not selected' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $script:CopySideEffect = { param($Source,$Destination); [IO.File]::WriteAllText((Join-Path $Destination '123456_100/main.pak'), 'bad-copy') }
    Expect-Blocked { Invoke-GuardAction $p 'Refresh' }; Assert-PriorIntact $p $s $hash
}
Run-Test 'ARK starting during copy prevents commit' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $script:CopySideEffect = { param($Source,$Destination); $script:ArkRunning = $true }
    Expect-Blocked { Invoke-GuardAction $p 'Refresh' }; $script:ArkRunning = $false; Assert-PriorIntact $p $s $hash
}
Run-Test 'ARK already running blocks all protected actions' {
    $p = New-Fixture; $script:ArkRunning = $true
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
    Assert-True (-not (Test-Path $p.Pointer)) 'Snapshot unexpectedly created.'
}
Run-Test 'Global file lock blocks a second action and releases after failure' {
    $p = New-Fixture; $lock = Enter-OperationLock $p
    try { Expect-Blocked { Invoke-GuardAction $p 'Setup' } } finally { $lock.Dispose() }
    [void](Invoke-GuardAction $p 'Setup')
    Expect-Blocked { Invoke-GuardAction $p 'FullRestore' }
    $lock2 = Enter-OperationLock $p; $lock2.Dispose()
}
Run-Test 'Separate PowerShell process cannot acquire an active installation lock' {
    $p = New-Fixture; $lock = Enter-OperationLock $p
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        & $exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -LockProbe $p.Lock
        Assert-True ($LASTEXITCODE -eq 23) 'Child process bypassed lock.'
    } finally { $lock.Dispose() }
}
Run-Test 'Steam launch failure does not return a verified success object' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $script:LaunchFailure = $true
    $caught = $false; try { $r = Invoke-GuardAction $p 'Launch' } catch { $caught = $true }
    Assert-True $caught 'Expected Steam failure to propagate.'
}
Run-Test 'Full restore is blocked rather than performing an unsafe rollback' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 (Index-Path $p)
    Expect-Blocked { Invoke-GuardAction $p 'FullRestore' }
    Assert-True ((Get-Sha256 (Index-Path $p)) -eq $hash) 'Metadata was changed.'
}
foreach ($relative in @('../escape','/absolute','C:\escape','nested/../../escape','abc:stream','abc./x','NUL.txt','a//b')) {
    Run-Test "Unsafe path rejected: $relative" { Expect-Blocked { Join-SafePath $testRoot $relative } }
}
Run-Test 'Manifest file traversal rejected even with otherwise valid structure' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $s.Manifest.Files[0].Path = '../escape'
    Expect-Blocked { Assert-Manifest $p $s.Manifest $s.Id }
}
Run-Test 'Both directions of source/destination nesting rejected' {
    $p = New-Fixture
    Expect-Blocked { & $script:OriginalCopy $p.ModsDir (Join-Path $p.ModsDir 'nested-copy') }
    Expect-Blocked { & $script:OriginalCopy (Join-Path $p.ModsDir '123456_100') $p.ModsDir }
}
Run-Test 'Reparse or symbolic-link content rejected before traversal' {
    $p = New-Fixture; $target = Join-Path $p.ArkRoot 'outside'; [IO.Directory]::CreateDirectory($target) | Out-Null
    $link = Join-Path $p.ModsDir '123456_100/link'
    $type = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $type -Path $link -Target $target -ErrorAction Stop | Out-Null
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
}
foreach ($status in @('invalid','uninstalled','notready','unsuccessful','unknown',0)) {
    Run-Test "Negative or unknown status is not accepted: $status" {
        $p = New-Fixture
        [IO.File]::WriteAllText((Index-Path $p), ('{"mods":[{"modId":123456,"fileId":100,"status":"' + $status + '"}]}'))
        Expect-Blocked { Invoke-GuardAction $p 'Setup' }
    }
}
Run-Test 'Root array keeps zero/one/many shape without writes' {
    $p = New-Fixture
    foreach ($json in @('[]','[{"modId":123456,"fileId":100}]','[{"modId":123456,"fileId":100},{"modId":234567,"fileId":200}]')) {
        [IO.File]::WriteAllText((Index-Path $p), $json)
        $data = Get-LibraryData (Index-Path $p)
        Assert-True ($data.Root -is [Array]) 'Root array collapsed.'
        Assert-True ([IO.File]::ReadAllText((Index-Path $p)) -eq $json) 'Read changed bytes.'
    }
}
Run-Test 'Ambiguous mod identity and latest-online-only file identity rejected' {
    $p = New-Fixture
    foreach ($json in @('{"mods":[{"modId":123456,"id":234567,"fileId":100}]}','{"mods":[{"modId":123456,"latestFile":{"id":100}}]}')) {
        [IO.File]::WriteAllText((Index-Path $p), $json)
        Expect-Blocked { Invoke-GuardAction $p 'Setup' }
    }
}
Run-Test 'Empty physical mod folder cannot become a protected baseline' {
    $p = New-Fixture
    [IO.File]::Delete((Join-Path $p.ModsDir '123456_100/main.pak'))
    [IO.File]::Delete((Join-Path $p.ModsDir '123456_100/nested/data.bin'))
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
}
Run-Test 'Missing indexed folder cannot replace a complete snapshot' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'), (Join-Path $p.ArkRoot 'uninstalled-fixture'))
    Expect-Blocked { Invoke-GuardAction $p 'Refresh' }; Assert-PriorIntact $p $s $hash
}
Run-Test 'Legacy backup remains byte-for-byte untouched by safety setup' {
    $p = New-Fixture; $legacy = Join-Path $p.CfRoot 'ARK_ModGuard/Backup'
    [IO.Directory]::CreateDirectory($legacy) | Out-Null; $file = Join-Path $legacy 'keep.bin'
    [IO.File]::WriteAllText($file, 'legacy-backup'); $hash = Get-Sha256 $file
    [void](Seed-Snapshot $p); Assert-True ((Get-Sha256 $file) -eq $hash) 'Legacy backup changed.'
}
Run-Test 'Unicode/apostrophe/space paths work with a complete snapshot' {
    $root = Join-Path $testRoot ("O'Brien space-" + [char]0x00E9)
    $original = New-Fixture
    [IO.Directory]::Move($original.ArkRoot, $root); $p = Get-Paths $root
    [void](Seed-Snapshot $p); $r = Invoke-GuardAction $p 'Launch'
    Assert-True ($r.Status -eq 'Verified') 'Special path failed.'
}
Run-Test 'Index changes during staged backup block selection of new snapshot' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $script:CopySideEffect = {
        param($Source,$Destination)
        [IO.File]::WriteAllText((Index-Path $p), '{"mods":[{"modId":123456,"fileId":100}],"changed":true}')
    }
    Expect-Blocked { Invoke-GuardAction $p 'Refresh' }; Assert-PriorIntact $p $s $hash
}
Run-Test 'A newly added mod blocks launch until a new snapshot is explicitly saved' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.Directory]::CreateDirectory((Join-Path $p.ModsDir '234567_200')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $p.ModsDir '234567_200/new.pak'), 'new-mod')
    [IO.File]::WriteAllText((Index-Path $p), '{"mods":[{"modId":123456,"fileId":100},{"modId":234567,"fileId":200}]}')
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
    $script:BackupApproval = (Get-BackupReview $p $true).Approval
    [void](Invoke-GuardAction $p 'Refresh'); $script:BackupApproval = $null
    $r = Invoke-GuardAction $p 'Launch'; Assert-True ($r.ModCount -eq 2) 'New mod not protected.'
    Assert-SnapshotContent $s
}
Run-Test 'Intentional removal becomes new protection list without destroying previous snapshot' {
    $p = New-Fixture
    [IO.Directory]::CreateDirectory((Join-Path $p.ModsDir '234567_200')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $p.ModsDir '234567_200/new.pak'), 'new-mod')
    [IO.File]::WriteAllText((Index-Path $p), '{"mods":[{"modId":123456,"fileId":100},{"modId":234567,"fileId":200}]}')
    $s = Seed-Snapshot $p
    [IO.Directory]::Move((Join-Path $p.ModsDir '234567_200'), (Join-Path $p.ArkRoot 'removed-mod'))
    [IO.File]::WriteAllText((Index-Path $p), '{"mods":[{"modId":123456,"fileId":100}]}')
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
    $script:BackupApproval = (Get-BackupReview $p $true).Approval
    [void](Invoke-GuardAction $p 'Refresh'); $script:BackupApproval = $null; $r = Invoke-GuardAction $p 'Launch'
    Assert-True ($r.ModCount -eq 1 -and -not (Test-Path (Join-Path $p.ModsDir '234567_200'))) 'Removed mod was resurrected.'
    Assert-SnapshotContent $s
}
Run-Test 'Duplicate manifest file entries cannot yield readiness' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    $s.Manifest.Files = @($s.Manifest.Files) + @($s.Manifest.Files[0])
    Expect-Blocked { Assert-Manifest $p $s.Manifest $s.Id }
}
Run-Test 'Snapshot bound to another installation cannot be used' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    $s.Manifest.ArkRoot = Join-Path $testRoot 'another-game'
    Expect-Blocked { Assert-Manifest $p $s.Manifest $s.Id }
}
Run-Test 'Empty update log cannot imply a successful online scan' {
    $p = New-Fixture
    [IO.File]::WriteAllText((Join-Path $p.UserDataRoot 'game_83374_test.log'), '')
    $r = Show-ModUpdateReport $p
    Assert-True ($r.Status -eq 'HistoricalLogOnly' -and $script:Launches -eq 0) 'Historical log claimed live verification.'
}

# Import pure UI helpers, never WinForms or application entry points.
$tokens = $null; $errors = $null
$guiAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $release 'ModLocket.ps1'), [ref]$tokens, [ref]$errors)
foreach ($fn in $guiAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Test-BackupManagerResult','Test-BackupReviewResult','Get-BackupReviewText','Test-VerifiedLaunchResult','Test-QuickLaunchResult','Get-LogSeverity','Receive-CoreLine','ConvertFrom-ProgressLine','Test-DeferredLaunchResult','Invoke-DeferredHandoff') }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$Colors = @{ Text='Text'; Error='Error'; Warning='Warning'; Success='Success'; Purple='Purple' }
function Add-LogLine($Text, $Color) { }
Run-Test 'UI error mentioning successfully remains an error' {
    Assert-True ((Get-LogSeverity '[ERROR] operation did not finish successfully') -eq 'Error') 'Error classified as success.'
    Assert-True ((Get-LogSeverity 'incomplete') -eq 'Text') 'Unstructured text classified as success.'
}
Run-Test 'UI needs a structured verified launch result, not zero exit alone' {
    Assert-True (-not (Test-VerifiedLaunchResult $null)) 'Null result accepted.'
    Assert-True (-not (Test-VerifiedLaunchResult ([pscustomobject]@{Status='Verified'}))) 'Incomplete result accepted.'
    $p = New-Fixture; [void](Seed-Snapshot $p); $r = Invoke-GuardAction $p 'Launch'
    Assert-True (Test-VerifiedLaunchResult $r) 'Real verified result rejected.'
    $r.Status = 'Blocked'; Assert-True (-not (Test-VerifiedLaunchResult $r)) 'Blocked result accepted.'
}
Run-Test 'UI result marker parses completely and malformed marker clears readiness' {
    $p = New-Fixture; [void](Seed-Snapshot $p); $r = Invoke-GuardAction $p 'Launch'
    Receive-CoreLine ('__MODLOCKET_RESULT__=' + (ConvertTo-Json -InputObject $r -Compress))
    Assert-True (Test-VerifiedLaunchResult $script:ActionResult) 'Result marker truncated.'
    Receive-CoreLine '__MODLOCKET_RESULT__={broken'
    Assert-True ($null -eq $script:ActionResult) 'Malformed marker left old success in memory.'
}
Run-Test 'Actual disk-space helper fails closed for impossible capacity request' {
    Expect-Blocked { & $script:NativeSpaceCheck $testRoot ([long]::MaxValue - 1GB) }
}
# Real ASA field names and numeric token shapes observed in the user's index.
# All values/names below are synthetic; no user/account metadata is included.
function Set-AsaFixture($Paths, [string]$FileId = '100', [string]$Status = 'Normal', [string]$Extra = '') {
    $disk = ConvertTo-Json -InputObject (Join-Path $Paths.ModsDir ('123456_' + $FileId)) -Compress
    $json = '{"installedMods":[{"iD":"ABCDEF0123456789ABCDEF0123456789","status":"' + $Status + '","pathOnDisk":' + $disk + ',"enabled":false,"unmanaged":false,"details":{"id":123456,"gameId":83374,"name":"Synthetic ASA Skin"},"installedFile":{"id":' + $FileId + ',"modId":123456,"gameId":83374},"latestUpdatedFile":{"id":999},"users":[]}' + $Extra + ']}'
    [IO.File]::WriteAllText((Index-Path $Paths), $json)
}
Run-Test 'ASA nested identities use installed file, never internal or latest ID' {
    $p = New-Fixture; Set-AsaFixture $p
    $data = Get-LibraryData (Index-Path $p)
    Assert-True ($data.Entries.Count -eq 1 -and $data.Records['123456'].FileId -ceq '100') 'Wrong installed identity.'
    Assert-True ($data.Records['123456'].Issues.Count -eq 0) 'Normal ASA entry rejected.'
    [void](Seed-Snapshot $p); $r = Invoke-GuardAction $p 'Launch'
    Assert-True ($r.Status -eq 'Verified') 'Valid nested schema did not pass protected launch.'
}
Run-Test 'Large integer identity remains exact through snapshot and folder repair' {
    $p = New-Fixture; $fileId = '4541582274789310123'
    [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'), (Join-Path $p.ModsDir ('123456_' + $fileId)))
    Set-AsaFixture $p $fileId
    $hash = Get-Sha256 (Index-Path $p); $s = Seed-Snapshot $p
    Assert-True ($s.Manifest.Mods[0].FileId -ceq $fileId) 'ID rounded in snapshot.'
    [IO.Directory]::Move((Join-Path $p.ModsDir ('123456_' + $fileId)), (Join-Path $p.ArkRoot 'missing'))
    $r = Invoke-GuardAction $p 'Launch'
    Assert-True ($r.FilesRestored -eq 2) 'Large-ID repair failed.'
    Assert-True ((Get-Sha256 (Index-Path $p)) -eq $hash) 'Library bytes changed.'
}
foreach ($fileId in @('4.54158227478931E+18','100.0','-100','0')) {
    Run-Test "Non-canonical installed identity is reported, not guessed: $fileId" {
        $p = New-Fixture; Set-AsaFixture $p $fileId
        $r = Get-InspectionReport $p
        Assert-True ($r.ModCount -eq 1 -and $r.AttentionCount -gt 0) 'Invalid record disappeared.'
        Expect-Blocked { Invoke-GuardAction $p 'Setup' }
    }
}
Run-Test 'Invalid Arcadian-shaped entry remains named alongside every Normal record' {
    $p = New-Fixture
    $bad = ',{"iD":"INVALIDINTERNAL","status":"Invalid","pathOnDisk":"","enabled":true,"unmanaged":false,"details":{"id":1069119,"gameId":83374,"name":"Synthetic broken skin"},"installedFile":{"id":4.54158227478931E+18,"modId":1069119,"gameId":83374}}'
    Set-AsaFixture $p '100' 'Normal' $bad
    $r = Get-InspectionReport $p
    Assert-True ($r.ModCount -eq 2 -and $r.Rows.Count -eq 2) 'Incomplete count.'
    Assert-True ($r.Rows[1].Name -eq 'Synthetic broken skin' -and $r.Rows[1].Findings -match 'Invalid') 'Broken entry not named.'
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
    Assert-True (-not (Test-Path $p.Pointer)) 'Bad baseline committed.'
    $export = Export-Inventory $p; $rows = @(Import-Csv -LiteralPath $export.Path)
    Assert-True ($rows.Count -eq 2 -and $rows[1].LibraryStatus -eq 'Invalid') 'Inventory dropped problem entry.'
}
Run-Test 'Inspection creates no lock, backup, or export and never signals readiness' {
    $p = New-Fixture; Set-AsaFixture $p
    $before = @(Get-TreeManifest $p.ArkRoot)
    $r = Invoke-GuardAction $p 'Inspect'
    Assert-TreeMatches $p.ArkRoot $before
    Assert-True ($r.Status -eq 'Inspected' -and -not $r.IntegrityVerified -and -not $r.OnlineUpdatesVerified) 'Inspection overstated result.'
    Assert-True (-not (Test-VerifiedLaunchResult $r)) 'Inspection marked Ready.'
}
Run-Test 'Absent saved mod is named without assuming intentional uninstall' {
    $p = New-Fixture; Set-AsaFixture $p; [void](Seed-Snapshot $p)
    [IO.File]::WriteAllText((Index-Path $p), '{"installedMods":[]}')
    $r = Get-InspectionReport $p
    $saved = @($r.Rows | Where-Object Origin -eq 'SavedList')
    Assert-True ($saved.Count -eq 1 -and $saved[0].Name -eq 'Synthetic ASA Skin' -and $saved[0].Findings -match 'intent unknown') 'Absent saved mod silently dropped.'
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
}
Run-Test 'ASA path mismatch is reported and blocks backup' {
    $p = New-Fixture; Set-AsaFixture $p
    $path = Index-Path $p
    [IO.File]::WriteAllText($path, ([IO.File]::ReadAllText($path).Replace('123456_100','123456_200')))
    $r = Get-InspectionReport $p
    Assert-True ($r.Rows[0].Findings -match 'Recorded path') 'Path mismatch not reported.'
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
}
Run-Test 'ASA cross-project and cross-game file identities block protection' {
    foreach ($replace in @(@('"modId":123456','"modId":234567'),@('"gameId":83374','"gameId":99999'))) {
        $p = New-Fixture; Set-AsaFixture $p; $path = Index-Path $p
        [IO.File]::WriteAllText($path, ([IO.File]::ReadAllText($path).Replace($replace[0],$replace[1])))
        Expect-Blocked { Invoke-GuardAction $p 'Setup' }
    }
}
Run-Test 'Duplicate project records remain two entries and block setup' {
    $p = New-Fixture
    [IO.File]::WriteAllText((Index-Path $p), '{"mods":[{"modId":123456,"fileId":100},{"modId":123456,"fileId":100}]}')
    $r = Get-InspectionReport $p
    Assert-True ($r.ModCount -eq 2 -and @($r.Rows | Where-Object Findings -match 'Duplicate').Count -eq 2) 'Duplicate lost.'
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
}
Run-Test 'Malformed records are retained as unnamed findings' {
    $p = New-Fixture
    [IO.File]::WriteAllText((Index-Path $p), '{"installedMods":[null,42,{"details":{"name":"Named unknown"}}]}')
    $r = Get-InspectionReport $p
    Assert-True ($r.ModCount -eq 3 -and @($r.Rows | Where-Object Origin -eq 'CurrentLibrary').Count -eq 3) 'Malformed entries disappeared.'
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
}
Run-Test 'Number projection preserves escaped quotes and numeric text in names' {
    $p = New-Fixture
    $json = '{"mods":[{"modId":123456,"fileId":100,"name":"Skin \"12345\" \\ 1e19 \u2665"}]}'
    [IO.File]::WriteAllText((Index-Path $p), $json)
    $data = Get-LibraryData (Index-Path $p)
    Assert-True ($data.Records['123456'].Name -ceq ('Skin "12345" \ 1e19 ' + [char]0x2665)) 'String token damaged.'
    Assert-True ([IO.File]::ReadAllText((Index-Path $p)) -ceq $json) 'Source changed.'
}
Run-Test 'Inspection can explain wholly missing mod directory without creating it' {
    $p = New-Fixture; Set-AsaFixture $p
    [IO.Directory]::Move($p.ModsDir, (Join-Path $p.ArkRoot 'missing-tree'))
    $r = Get-InspectionReport $p
    Assert-True ($r.ModCount -eq 1 -and -not $r.Rows[0].FolderPresent -and $r.GlobalIssues.Count -gt 0) 'Missing tree hidden.'
    Assert-True (-not (Test-Path $p.ModsDir)) 'Inspection created mod directory.'
}
Run-Test 'Invalid saved pointer reports incomplete comparison without Ready' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    [IO.File]::WriteAllText($p.Pointer, '{}')
    $r = Get-InspectionReport $p
    Assert-True (-not $r.SnapshotCompared -and $r.GlobalIssues -match 'comparison incomplete') 'Bad pointer ignored.'
}
Run-Test 'Cached latest-file data is never reported as online verification' {
    $p = New-Fixture; Set-AsaFixture $p
    $r = Get-InspectionReport $p
    Assert-True ($r.Rows[0].FileId -ceq '100' -and -not $r.OnlineUpdatesVerified) 'Cached latest value accepted as installed/current.'
}
Run-Test 'Adjacent huge file IDs cannot compare equal through floating point rounding' {
    $p = New-Fixture; $first = '4541582274789310123'; $next = '4541582274789310124'
    [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'), (Join-Path $p.ModsDir ('123456_' + $first)))
    Set-AsaFixture $p $first; [void](Seed-Snapshot $p)
    [IO.Directory]::Move((Join-Path $p.ModsDir ('123456_' + $first)), (Join-Path $p.ModsDir ('123456_' + $next)))
    Set-AsaFixture $p $next
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
    Assert-True (-not (Test-Path (Join-Path $p.ModsDir ('123456_' + $first)))) 'Old version recreated.'
    $r = Get-InspectionReport $p
    Assert-True (@($r.GlobalIssues | Where-Object { $_ -match 'version differs' }).Count -gt 0) 'Changed version was not reported.'
}
Run-Test 'Relative recorded path is reported without guessed resolution' {
    $p = New-Fixture; Set-AsaFixture $p; $path = Index-Path $p
    $raw = [IO.File]::ReadAllText($path)
    $raw = [regex]::Replace($raw, '"pathOnDisk":"(?:[^"\\]|\\.)*"', '"pathOnDisk":"Mods/83374/123456_100"')
    [IO.File]::WriteAllText($path, $raw)
    $r = Get-InspectionReport $p
    Assert-True ($r.Rows[0].RecordedPathKind -eq 'Relative' -and $r.Rows[0].RecordedFolder -eq '123456_100') 'Path shape not reported.'
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
}
Run-Test 'CSV formula-looking name is escaped and invalid entry still exported' {
    $p = New-Fixture
    [IO.File]::WriteAllText((Index-Path $p), '{"mods":[{"modId":123456,"fileId":100,"status":"invalid","name":"=1+1"}]}')
    $export = Export-Inventory $p; $rows = @(Import-Csv -LiteralPath $export.Path)
    Assert-True ($rows[0].Name -ceq "'=1+1" -and $export.AttentionCount -gt 0) 'Unsafe spreadsheet field or ignored issue.'
}
function Set-RecordedFixturePath($Paths, [string]$Recorded) {
    $path = Index-Path $Paths
    $raw = [IO.File]::ReadAllText($path)
    $encoded = ConvertTo-Json -InputObject $Recorded -Compress
    $replacement = '"pathOnDisk":' + $encoded
    $raw = [regex]::Replace($raw, '"pathOnDisk":"(?:[^"\\]|\\.)*"', [Text.RegularExpressions.MatchEvaluator]{ param($m) return $replacement })
    [IO.File]::WriteAllText($path, $raw)
}
foreach ($recorded in @('83374/123456_100', '83374\123456_100')) {
    Run-Test "Observed ASA relative path supports inspection and protected repair: $recorded" {
        $p = New-Fixture; Set-AsaFixture $p; Set-RecordedFixturePath $p $recorded
        $before = Get-Sha256 (Index-Path $p)
        $report = Get-InspectionReport $p
        Assert-True ($report.AttentionCount -eq 0 -and $report.Rows[0].FolderPresent) 'Observed relative path rejected.'
        [void](Seed-Snapshot $p)
        [IO.File]::Delete((Join-Path $p.ModsDir '123456_100/main.pak'))
        $result = Invoke-GuardAction $p 'Launch'
        Assert-True ($result.FilesRestored -eq 1) 'Expected protected file repair.'
        Assert-True ((Get-Sha256 (Index-Path $p)) -ceq $before) 'Recorded path or index bytes changed.'
    }
}
foreach ($recorded in @('83374/123456_101','83374/234567_100','99999/123456_100','../83374/123456_100','83374/../123456_100','83374/123456_100/extra','83374//123456_100','83374/123456_100:stream')) {
    Run-Test "Relative path cannot escape or substitute project/version: $recorded" {
        $p = New-Fixture; Set-AsaFixture $p; Set-RecordedFixturePath $p $recorded
        $report = Get-InspectionReport $p
        Assert-True ($report.AttentionCount -gt 0) 'Unsafe/mismatched path accepted.'
        Expect-Blocked { Invoke-GuardAction $p 'Setup' }
    }
}
Run-Test 'Relative-path acceptance does not hide OutOfDate status or unknown temp content' {
    $p = New-Fixture; Set-AsaFixture $p '100' 'OutOfDate'; Set-RecordedFixturePath $p '83374/123456_100'
    $temp = Join-Path $p.ModsDir '.temp'
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    [IO.File]::WriteAllText((Join-Path $temp 'pending.bin'), 'leave-alone')
    $before = @(Get-TreeManifest $p.ArkRoot)
    $report = Get-InspectionReport $p
    Assert-True ($report.Rows[0].Findings -match 'OutOfDate' -and $report.GlobalIssues.Count -eq 1) 'Outstanding findings hidden.'
    Assert-TreeMatches $p.ArkRoot $before
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
}
Run-Test 'Empty top-level temp directory is accepted and left untouched' {
    $p = New-Fixture; Set-AsaFixture $p; Set-RecordedFixturePath $p '83374/123456_100'
    $temp = Join-Path $p.ModsDir '.temp'
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $r = Get-InspectionReport $p
    Assert-True ($r.AttentionCount -eq 0) 'Empty .temp was flagged.'
    [void](Seed-Snapshot $p)
    $r = Invoke-GuardAction $p 'Launch'
    Assert-True ($r.Status -eq 'Verified' -and (Test-Path -LiteralPath $temp -PathType Container)) 'Empty directory was removed or blocked launch.'
}
Run-Test 'New temp content blocks protected launch and is preserved' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    $temp = Join-Path $p.ModsDir '.temp'
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $file = Join-Path $temp '.pending'
    [IO.File]::WriteAllText($file, 'preserve')
    $r = Get-InspectionReport $p
    Assert-True ($r.AttentionCount -gt 0) 'Hidden temp content ignored.'
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
    Assert-True ([IO.File]::ReadAllText($file) -ceq 'preserve') 'Temp content changed.'
}
Run-Test 'File named temp is not accepted as an empty directory' {
    $p = New-Fixture; [IO.File]::WriteAllText((Join-Path $p.ModsDir '.temp'), '')
    $r = Get-InspectionReport $p
    Assert-True ($r.AttentionCount -gt 0) 'Non-directory temp accepted.'
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
}
Run-Test 'Linked empty temp is rejected without traversal' {
    $p = New-Fixture; $outside = Join-Path $p.ArkRoot 'outside-empty'
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $type = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $type -Path (Join-Path $p.ModsDir '.temp') -Target $outside -ErrorAction Stop | Out-Null
    Expect-Blocked { Get-InspectionReport $p }
    Expect-Blocked { Invoke-GuardAction $p 'Setup' }
}
Run-Test 'Quick launch reads metadata only and preserves all file bytes' {
    $p = New-Fixture; Set-AsaFixture $p; Set-RecordedFixturePath $p '83374/123456_100'
    $s = Seed-Snapshot $p
    $before = @(Get-TreeManifest $p.ArkRoot)
    $originalHash = ${function:Get-Sha256}
    try {
        function Get-Sha256($Path) {
            if ($Path -match '[\\/]Mods[\\/]') { throw 'TEST: quick launch attempted to hash payload data.' }
            & $originalHash $Path
        }
        $r = Invoke-GuardAction $p 'QuickLaunch'
    } finally { ${function:Get-Sha256} = $originalHash }
    Assert-TreeMatches $p.ArkRoot $before
    Assert-True ($script:Launches -eq 1 -and $r.FilesChecked -eq 2 -and $r.FilesRestored -eq 0) 'Quick launch did not preserve scope.'
    Assert-True (Test-QuickLaunchResult $r) 'Quick result rejected.'
    Assert-True (-not (Test-VerifiedLaunchResult $r)) 'Quick result marked fully verified.'
}
Run-Test 'Quick launch blocks without a selected snapshot' {
    $p = New-Fixture
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
}
Run-Test 'Quick launch blocks missing files without repairing them' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    $path = Join-Path $p.ModsDir '123456_100/main.pak'; [IO.File]::Delete($path)
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
    Assert-True (-not (Test-Path -LiteralPath $path)) 'Quick launch wrote a repair.'
    Assert-SnapshotContent $s
}
Run-Test 'Quick launch blocks a missing whole mod folder' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    [IO.Directory]::Delete((Join-Path $p.ModsDir '123456_100'), $true)
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
}
Run-Test 'Quick launch blocks changed file lengths and preserves the changed file' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    $path = Join-Path $p.ModsDir '123456_100/main.pak'; [IO.File]::WriteAllText($path, 'longer-changed-payload')
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
    Assert-True ([IO.File]::ReadAllText($path) -ceq 'longer-changed-payload') 'Changed file overwritten.'
}
Run-Test 'Quick launch blocks extra content' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    [IO.File]::WriteAllText((Join-Path $p.ModsDir '123456_100/extra.bin'), 'extra')
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
}
Run-Test 'Quick launch blocks installed version changes' {
    $p = New-Fixture; Set-AsaFixture $p; [void](Seed-Snapshot $p)
    [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'), (Join-Path $p.ModsDir '123456_101'))
    Set-AsaFixture $p '101'
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
}
Run-Test 'Quick launch blocks cached OutOfDate status' {
    $p = New-Fixture; Set-AsaFixture $p; [void](Seed-Snapshot $p)
    Set-AsaFixture $p '100' 'OutOfDate'
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
}
Run-Test 'Quick launch blocks corrupt snapshot manifest and metadata' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::AppendAllText((Join-Path $s.Root 'manifest.json'), ' ')
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::AppendAllText((Join-Path $s.Root 'Metadata/account/library.json'), ' ')
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
}
Run-Test 'Same-size damage is explicitly outside quick checking but deep checking blocks it' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    $path = Join-Path $p.ModsDir '123456_100/main.pak'
    [IO.File]::WriteAllText($path, ('X' * (Get-Item -LiteralPath $path).Length))
    $r = Invoke-GuardAction $p 'QuickLaunch'
    Assert-True ($r.Status -ceq 'QuickChecked' -and $r.IntegrityVerified -eq $false -and $r.BackupContentsVerified -eq $false) 'Quick mode overstated guarantees.'
    Assert-True (-not (Test-VerifiedLaunchResult $r)) 'Quick mode reported full verification.'
    $script:Launches = 0
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
}
Run-Test 'Quick launch does not claim backup payload verification' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.File]::WriteAllText((Join-Path $s.Root 'Mods/123456_100/main.pak'), 'damaged')
    $r = Invoke-GuardAction $p 'QuickLaunch'
    Assert-True ($r.BackupContentsVerified -eq $false) 'Backup payload health overstated.'
    $script:Launches = 0
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
}
Run-Test 'Quick launch blocks links under an installed mod' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    $outside = Join-Path $p.ArkRoot 'outside'; [IO.Directory]::CreateDirectory($outside) | Out-Null
    $type = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $type -Path (Join-Path $p.ModsDir '123456_100/link') -Target $outside -ErrorAction Stop | Out-Null
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
}
Run-Test 'Quick launch blocks an active ARK process' {
    $p = New-Fixture; [void](Seed-Snapshot $p); $script:ArkRunning = $true
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
}
Run-Test 'Quick launch obeys the operation lock' {
    $p = New-Fixture; [void](Seed-Snapshot $p); $handle = Enter-OperationLock $p
    try { Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' } }
    finally { $handle.Dispose() }
}
Run-Test 'Quick launch catches a file disappearing between checks' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    $originalLayout = ${function:Assert-QuickFileLayout}; $script:LayoutCalls = 0
    try {
        function Assert-QuickFileLayout($Paths, $Snapshot) {
            $n = & $originalLayout $Paths $Snapshot
            $script:LayoutCalls++
            if ($script:LayoutCalls -eq 1) { [IO.File]::Delete((Join-Path $Paths.ModsDir '123456_100/main.pak')) }
            return $n
        }
        Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
    } finally { ${function:Assert-QuickFileLayout} = $originalLayout }
}
Run-Test 'Quick launch catches an index change at the final boundary' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    $originalLayout = ${function:Assert-QuickFileLayout}; $script:LayoutCalls = 0
    try {
        function Assert-QuickFileLayout($Paths, $Snapshot) {
            $n = & $originalLayout $Paths $Snapshot
            $script:LayoutCalls++
            if ($script:LayoutCalls -eq 2) { [IO.File]::AppendAllText((Index-Path $Paths), ' ') }
            return $n
        }
        Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
    } finally { ${function:Assert-QuickFileLayout} = $originalLayout }
}
Run-Test 'Steam failure cannot produce a quick success result' {
    $p = New-Fixture; [void](Seed-Snapshot $p); $script:LaunchFailure = $true
    $r = $null; $failedLaunch = $false
    try { $r = Invoke-GuardAction $p 'QuickLaunch' } catch { $failedLaunch = $true }
    Assert-True ($failedLaunch -and $null -eq $r -and $script:Launches -eq 1) 'Failed Steam request produced success.'
}
Run-Test 'Quick UI result rejects incomplete or overstated results' {
    Assert-True (-not (Test-QuickLaunchResult $null)) 'Null accepted.'
    Assert-True (-not (Test-QuickLaunchResult ([pscustomobject]@{Status='QuickChecked'}))) 'Incomplete accepted.'
    $p = New-Fixture; [void](Seed-Snapshot $p); $r = Invoke-GuardAction $p 'QuickLaunch'
    Receive-CoreLine ('__MODLOCKET_RESULT__=' + (ConvertTo-Json -InputObject $r -Compress))
    Assert-True (Test-QuickLaunchResult $script:ActionResult) 'Valid quick result marker failed.'
    $r.IntegrityVerified = $true
    Assert-True (-not (Test-QuickLaunchResult $r)) 'Overstated quick result accepted.'
}
Run-Test 'Progress parser accepts stage percentages and unknown totals' {
    $r = ConvertFrom-ProgressLine '__MODLOCKET_PROGRESS__={"Stage":"Checking files","Percent":42}'
    Assert-True ($r.Percent -eq 42 -and $r.Stage -ceq 'Checking files') 'Valid stage percentage rejected.'
    $r = ConvertFrom-ProgressLine '__MODLOCKET_PROGRESS__={"Stage":"Copying backup","Percent":-1}'
    Assert-True ($r.Percent -eq -1) 'Unknown total should remain indeterminate.'
}
Run-Test 'Malformed progress cannot become a completion result' {
    foreach ($text in @('{broken','{"Stage":"Files","Percent":101}','{"Stage":"Files","Percent":-2}',
        '{"Stage":"Files","Percent":"100"}','{"Stage":"Files","Percent":50.5}',
        '{"Stage":"","Percent":50}','{"Stage":123,"Percent":50}','{"Percent":50}',
        '{"Stage":"Files\nDone","Percent":100}')) {
        Assert-True ($null -eq (ConvertFrom-ProgressLine ('__MODLOCKET_PROGRESS__=' + $text))) 'Malformed progress accepted.'
    }
}
Run-Test 'Stage completion cannot set launch readiness' {
    $progressLabel = [pscustomobject]@{ Text = '' }
    $script:ActionClock = [Diagnostics.Stopwatch]::StartNew()
    $script:ActionResult = $null
    Receive-CoreLine '__MODLOCKET_PROGRESS__={"Stage":"Hashing source","Percent":100}'
    Assert-True ($progressLabel.Text -match '100%' -and $null -eq $script:ActionResult) 'Progress created a launch result.'
    Assert-True (-not (Test-VerifiedLaunchResult $script:ActionResult)) 'Progress marked full readiness.'
    Receive-CoreLine '__MODLOCKET_PROGRESS__={"Stage":"Copying backup","Percent":-1}'
    Assert-True ($progressLabel.Text -notmatch '%') 'Unknown total got a made-up percentage.'
    $script:ActionClock = $null
}
Run-Test 'Direct ancestor checks reject links even when target child is absent' {
    $p = New-Fixture
    $outside = Join-Path $p.ArkRoot 'outside'; [IO.Directory]::CreateDirectory($outside) | Out-Null
    $type = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
    $link = Join-Path $p.ArkRoot 'linked'
    New-Item -ItemType $type -Path $link -Target $outside -ErrorAction Stop | Out-Null
    Expect-Blocked { Assert-NoLinks (Join-Path $link 'not-created-yet.bin') }
}
Run-Test 'Direct ancestor checks do not cache prior clean paths' {
    $p = New-Fixture
    $path = Join-Path $p.ArkRoot 'switchable'; [IO.Directory]::CreateDirectory($path) | Out-Null
    Assert-NoLinks $path
    [IO.Directory]::Delete($path)
    $outside = Join-Path $p.ArkRoot 'outside'; [IO.Directory]::CreateDirectory($outside) | Out-Null
    $type = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $type -Path $path -Target $outside -ErrorAction Stop | Out-Null
    Expect-Blocked { Assert-NoLinks $path }
}
Run-Test 'Direct ancestor checks allow new ordinary destinations' {
    $p = New-Fixture
    Assert-NoLinks (Join-Path $p.ArkRoot 'new/folder/file.bin')
}
Run-Test 'Deferred quick launch returns approval without requesting Steam' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    $DeferSteamLaunch = $true
    $r = Invoke-GuardAction $p 'QuickLaunch'
    Assert-True ($script:Launches -eq 0 -and -not $r.SteamRequested -and $r.NeedsSteamLaunch) 'Worker launched Steam.'
    Assert-True (Test-DeferredLaunchResult $r 'QuickLaunch') 'Approval rejected.'
    Assert-True (-not $r.SteamRequested) 'Approval validation mutated the result.'
}
Run-Test 'Deferred deep repair completes without launching Steam' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    [IO.File]::Delete((Join-Path $p.ModsDir '123456_100/main.pak'))
    $DeferSteamLaunch = $true
    $r = Invoke-GuardAction $p 'Launch'
    Assert-True ($r.FilesRestored -eq 1 -and $script:Launches -eq 0 -and -not $r.SteamRequested) 'Unexpected handoff.'
    Assert-True (Test-DeferredLaunchResult $r 'Launch') 'Deep approval rejected.'
}
Run-Test 'GUI consumes valid approval exactly once' {
    $p = New-Fixture; [void](Seed-Snapshot $p); $DeferSteamLaunch = $true
    $r = Invoke-GuardAction $p 'QuickLaunch'
    Invoke-DeferredHandoff $r 'QuickLaunch'
    Assert-True ($script:Launches -eq 1 -and $r.SteamRequested -and -not $r.NeedsSteamLaunch) 'Handoff failed.'
    $blocked = $false
    try { Invoke-DeferredHandoff $r 'QuickLaunch' } catch { $blocked = $true }
    Assert-True ($blocked -and $script:Launches -eq 1) 'Approval reused.'
}
Run-Test 'Closing after worker approval prevents deferred Steam launch' {
    $p = New-Fixture; [void](Seed-Snapshot $p); $DeferSteamLaunch = $true
    $r = Invoke-GuardAction $p 'QuickLaunch'; $script:CancelRequested = $true
    Expect-Blocked { Invoke-DeferredHandoff $r 'QuickLaunch' }
    Assert-True (-not $r.SteamRequested) 'Cancelled result claimed launch.'
}
Run-Test 'Pending close dialog prevents handoff until Keep working' {
    $p = New-Fixture; [void](Seed-Snapshot $p); $DeferSteamLaunch = $true
    $r = Invoke-GuardAction $p 'QuickLaunch'; $script:ClosePromptActive = $true
    Expect-Blocked { Invoke-DeferredHandoff $r 'QuickLaunch' }
    $script:ClosePromptActive = $false
    Invoke-DeferredHandoff $r 'QuickLaunch'
    Assert-True ($script:Launches -eq 1) 'Keep working did not allow completed approval.'
}
Run-Test 'Failed GUI Steam request does not claim launch success' {
    $p = New-Fixture; [void](Seed-Snapshot $p); $DeferSteamLaunch = $true
    $r = Invoke-GuardAction $p 'QuickLaunch'; $script:LaunchFailure = $true
    $blocked = $false
    try { Invoke-DeferredHandoff $r 'QuickLaunch' } catch { $blocked = $true }
    Assert-True ($blocked -and -not $r.SteamRequested) 'Failed shell handoff claimed success.'
}
Run-Test 'Incomplete or wrong-action approval cannot launch Steam' {
    Expect-Blocked { Invoke-DeferredHandoff ([pscustomobject]@{SteamRequested=$false;NeedsSteamLaunch=$true}) 'QuickLaunch' }
    $p = New-Fixture; [void](Seed-Snapshot $p); $DeferSteamLaunch = $true
    $r = Invoke-GuardAction $p 'QuickLaunch'
    Expect-Blocked { Invoke-DeferredHandoff $r 'Launch' }
}
Run-Test 'Approval that predates closing the dialog cannot launch later' {
    $p = New-Fixture; [void](Seed-Snapshot $p); $DeferSteamLaunch = $true
    $r = Invoke-GuardAction $p 'QuickLaunch'
    $script:LaunchApprovalNotBefore = [DateTime]::UtcNow.AddSeconds(1)
    Expect-Blocked { Invoke-DeferredHandoff $r 'QuickLaunch' }
    Assert-True (-not $r.SteamRequested) 'Stale approval launched.'
}
. (Join-Path $PSScriptRoot 'BackupReview.Tests.ps1')
. (Join-Path $PSScriptRoot 'BackupManagement.Tests.ps1')
. (Join-Path $PSScriptRoot 'Catalog.Tests.ps1')
# Native owned-worker and hard-interruption tests are separate from portable fixtures.
. (Join-Path $PSScriptRoot 'Worker.Tests.ps1')
$failed = @($script:TestResults | Where-Object { -not $_.Passed }).Count
Write-Output "RESULT: $($script:TestResults.Count - $failed) passed; $failed failed."
Write-Output "Fixtures retained for inspection: $testRoot"
Write-Output 'Passing these tests is NOT Windows UI, ARK schema, game integration, installer, or public-release approval.'
if ($failed) { exit 1 }; exit 0
