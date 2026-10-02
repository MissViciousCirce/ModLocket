# Synthetic fixtures only. Management operations must preserve live mod/index bytes.
function Get-ManagedItem($Paths, [string]$Id) { return (Get-BackupManager $Paths).Items | Where-Object {$_.Id -ceq $Id} }
function Run-ManagedAction($Paths, [string]$Name, $Item) {
    $TargetId = $Item.Id; $ManagementApproval = $Item.Approval
    Invoke-GuardAction $Paths $Name
}
function Add-RepairTemp($Paths, [string]$Base='123456_100/main.pak') {
    $relative = $Base + '.modlocket-' + [guid]::NewGuid().ToString('N') + '.tmp'
    $path = Join-SafePath $Paths.ModsDir $relative
    [IO.File]::WriteAllText($path,'partial repair payload')
    return $path
}
Run-Test 'Combined backup plans first creation then update without making a copy' {
    $p=New-Fixture
    Assert-True ((Invoke-GuardAction $p 'PlanBackup').Action -ceq 'Setup') 'Wrong first action.'
    Assert-True (-not (Test-Path $p.GuardRoot)) 'Planning created backup state.'
    [void](Seed-Snapshot $p); $before=@(Get-ChildItem $p.SnapshotsRoot).Count
    Assert-True ((Invoke-GuardAction $p 'PlanBackup').Action -ceq 'Refresh') 'Wrong existing action.'
    Assert-True (@(Get-ChildItem $p.SnapshotsRoot).Count -eq $before) 'Planning made a copy.'
}
Run-Test 'Unreadable existing selection cannot fall back to first-time backup' {
    $p=New-Fixture; [void](Seed-Snapshot $p)
    [IO.File]::WriteAllText($p.Pointer,'broken'); $hash=Get-Sha256 $p.Pointer
    Expect-Blocked {Invoke-GuardAction $p 'PlanBackup'}
    Expect-Blocked {Invoke-GuardAction $p 'ManageBackups'}
    Assert-True ((Get-Sha256 $p.Pointer) -ceq $hash) 'Pointer overwritten.'
}
Run-Test 'Empty manager is read-only and its zero-row result survives JSON' {
    $p=New-Fixture; $r=Invoke-GuardAction $p 'ManageBackups'
    Assert-True ($r.Items.Count -eq 0 -and -not (Test-Path $p.GuardRoot) -and -not (Test-Path $p.Lock)) 'Empty view mutated state.'
    $round=ConvertFrom-Json (ConvertTo-Json -Depth 8 -InputObject $r)
    Assert-True (Test-BackupManagerResult $round) 'Zero rows lost.'
}
Run-Test 'Manager protects current copy and accurately totals file sizes' {
    $p=New-Fixture; $s=Seed-Snapshot $p; $hash=Get-Sha256 $p.Pointer
    $r=Invoke-GuardAction $p 'ManageBackups'; $item=$r.Items[0]
    $bytes=[long]((@(Get-SafeFiles $s.Root) | Measure-Object Length -Sum).Sum)
    Assert-True ($r.Items.Count -eq 1 -and $item.Current -and -not $item.CanDelete -and -not $item.CanSelect -and $r.TotalBytes -eq $bytes) 'Current copy/size incorrect.'
    Expect-Blocked {Run-ManagedAction $p 'RemoveSnapshot' $item}
    Assert-PriorIntact $p $s $hash
    Assert-True (Test-BackupManagerResult (ConvertFrom-Json (ConvertTo-Json -Depth 8 -InputObject $r))) 'One row lost.'
}
Run-Test 'Removing reviewed older backup preserves selected copy and live files' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh'); $current=Load-Snapshot $p
    $hash=Get-Sha256 $p.Pointer; $index=Get-Sha256 (Index-Path $p)
    $item=Get-ManagedItem $p $old.Id
    Assert-True ($item.CanDelete -and $item.CanSelect -and -not $item.Current) 'Older copy unavailable.'
    $r=Run-ManagedAction $p 'RemoveSnapshot' $item
    Assert-True ($r.Status -ceq 'SnapshotRemoved' -and -not (Test-Path $old.Root)) 'Old copy remained.'
    Assert-PriorIntact $p $current $hash; Assert-TreeMatches $p.ModsDir $current.Manifest.Files
    Assert-True ((Get-Sha256 (Index-Path $p)) -ceq $index) 'Index changed.'
}
Run-Test 'Changed backup layout invalidates deletion review before any deletion' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh')
    $item=Get-ManagedItem $p $old.Id
    [IO.File]::WriteAllText((Join-Path $old.Root 'new.txt'),'new content')
    Expect-Blocked {Run-ManagedAction $p 'RemoveSnapshot' $item}
    Assert-SnapshotContent $old
    Assert-True (Test-Path (Join-Path $old.Root 'new.txt')) 'New content deleted.'
}
foreach ($directoryChange in @('added','renamed')) {
    Run-Test "Empty directory $directoryChange after review blocks deletion" {
        $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh')
        $empty=Join-Path $old.Root 'reviewed-empty'; [IO.Directory]::CreateDirectory($empty) | Out-Null
        $item=Get-ManagedItem $p $old.Id
        $changed=Join-Path $old.Root 'changed-empty'
        if ($directoryChange -ceq 'added') { [IO.Directory]::CreateDirectory($changed) | Out-Null }
        else { [IO.Directory]::Move($empty,$changed) }
        Expect-Blocked {Run-ManagedAction $p 'RemoveSnapshot' $item}
        Assert-SnapshotContent $old
        Assert-True (Test-Path -LiteralPath $changed) 'Changed directory was removed.'
    }
}
foreach ($fileChange in @('timestamp','length')) {
    Run-Test "Backup file $fileChange change after review blocks deletion" {
        $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh')
        $file=Join-Path $old.Root 'Mods/123456_100/main.pak'
        $originalTime=[IO.File]::GetLastWriteTimeUtc($file)
        $item=Get-ManagedItem $p $old.Id
        if ($fileChange -ceq 'timestamp') { [IO.File]::SetLastWriteTimeUtc($file,$originalTime.AddHours(-2)) }
        else {
            [IO.File]::AppendAllText($file,' changed length')
            # Isolate the length guard from the file timestamp guard.
            [IO.File]::SetLastWriteTimeUtc($file,$originalTime)
        }
        $changedHash=Get-Sha256 $file
        Expect-Blocked {Run-ManagedAction $p 'RemoveSnapshot' $item}
        Assert-True ((Get-Sha256 $file) -ceq $changedHash) 'Reviewed file was removed or changed.'
        Assert-True (Test-Path -LiteralPath (Join-Path $old.Root 'manifest.json')) 'Deletion began before stale review was rejected.'
    }
}
Run-Test 'Changed pending marker blocks deletion even with matching length and timestamp' {
    $p=New-Fixture; $script:CopyFailure='partial'
    try { Expect-Blocked {Invoke-GuardAction $p 'Setup'} } finally { $script:CopyFailure=$null }
    $item=(Get-BackupManager $p).Items[0]
    $pending=Join-SafePath (Join-SafePath $p.SnapshotsRoot $item.Id) 'pending.json'
    $bytes=[IO.File]::ReadAllBytes($pending); $originalTime=[IO.File]::GetLastWriteTimeUtc($pending)
    # Keep the marker valid, with identical size/time, to isolate its checksum guard.
    $whitespace=[Array]::IndexOf($bytes,[byte]10)
    Assert-True ($whitespace -ge 0) 'Expected formatted marker JSON.'
    $bytes[$whitespace]=[byte]9; [IO.File]::WriteAllBytes($pending,$bytes)
    [IO.File]::SetLastWriteTimeUtc($pending,$originalTime)
    $changedHash=Get-Sha256 $pending
    Assert-True ((Get-ManagedItem $p $item.Id).CanDelete) 'Marker edit changed eligibility instead of only its checksum.'
    Expect-Blocked {Run-ManagedAction $p 'RemoveSnapshot' $item}
    Assert-True ((Get-Sha256 $pending) -ceq $changedHash) 'Changed marker was removed.'
}
Run-Test 'Newly selected backup cannot be deleted with an older review' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh')
    $item=Get-ManagedItem $p $old.Id; Commit-SnapshotPointer $p $old
    Expect-Blocked {Run-ManagedAction $p 'RemoveSnapshot' $item}
    Assert-SnapshotContent $old
}
Run-Test 'Cross-installation management approval is rejected' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh'); $item=Get-ManagedItem $p $old.Id
    $q=New-Fixture; [void](Seed-Snapshot $q)
    Expect-Blocked {Run-ManagedAction $q 'RemoveSnapshot' $item}
    Assert-SnapshotContent $old
}
Run-Test 'No management operation accepts an unreviewed or traversal target' {
    $p=New-Fixture; [void](Seed-Snapshot $p)
    foreach ($id in @('../current','..','/outside','repair-staging')) {
        $item=[pscustomobject]@{Id=$id;Approval=('a'*64)}
        Expect-Blocked {Run-ManagedAction $p 'RemoveSnapshot' $item}
    }
    Expect-Blocked {Invoke-GuardAction $p 'RemoveSnapshot'}
}
Run-Test 'Incomplete copy after interrupted backup can be removed without touching current' {
    $p=New-Fixture; $s=Seed-Snapshot $p; $hash=Get-Sha256 $p.Pointer
    $script:CopyFailure='before'; Expect-Blocked {Invoke-GuardAction $p 'Refresh'}; $script:CopyFailure=$null
    $item=@((Get-BackupManager $p).Items | Where-Object {-not $_.Current})[0]
    Assert-True ($item.CanDelete -and -not $item.CanSelect) 'Interrupted copy misclassified.'
    [void](Run-ManagedAction $p 'RemoveSnapshot' $item)
    Assert-PriorIntact $p $s $hash
}
Run-Test 'Interrupted first backup can be discarded then first setup retried' {
    $p=New-Fixture; $script:CopyFailure='partial'
    # Exercise the formerly broken flag branch even on Linux.
    $priorCopyMode=$script:NativeCopyEnabled; $script:NativeCopyEnabled=$true
    try { Expect-Blocked {Invoke-GuardAction $p 'Setup'} }
    finally { $script:NativeCopyEnabled=$priorCopyMode; $script:CopyFailure=$null }
    Assert-True (-not (Test-Path $p.Pointer)) 'An interrupted initial backup became selected.'
    $items=@((Get-BackupManager $p).Items)
    Assert-True ($items.Count -eq 1) 'Expected exactly one incomplete copy.'
    $item=$items[0]
    $staging=Join-SafePath $p.SnapshotsRoot $item.Id
    Assert-True (@(Get-SafeFiles (Join-Path $staging 'Mods')).Count -eq 1) 'Fault injection did not leave exactly one copied payload.'
    Assert-True (-not (Test-Path (Join-Path $staging 'manifest.json'))) 'Interrupted copy incorrectly completed its manifest.'
    Assert-True ($item.CanDelete -and -not $item.CanSelect) 'Incomplete initial copy not manageable.'
    # Windows diagnostic reproduced a folder-only timestamp change between reviews.
    # Force that change deterministically on every platform, without touching files.
    $directories=@(Get-ChildItem -LiteralPath $staging -Directory -Recurse -Force)
    Assert-True ($directories.Count -gt 0) 'No folders available for timestamp regression.'
    foreach ($directory in $directories) {
        [IO.Directory]::SetLastWriteTimeUtc($directory.FullName, $directory.LastWriteTimeUtc.AddHours(-2))
    }
    [void](Run-ManagedAction $p 'RemoveSnapshot' $item)
    Assert-True (-not (Test-Path $p.Pointer)) 'Deletion created a pointer.'
    [void](Seed-Snapshot $p)
}
Run-Test 'Completed copy with lost pointer is protected from deletion and can be reselected' {
    $p=New-Fixture; $s=Seed-Snapshot $p; [IO.File]::Delete($p.Pointer)
    $item=(Get-BackupManager $p).Items[0]
    Assert-True (-not $item.CanDelete -and $item.CanSelect) 'Unselected last copy was offered for deletion.'
    [void](Run-ManagedAction $p 'SelectSnapshot' $item)
    Assert-True ((Load-Snapshot $p).Id -ceq $s.Id) 'Recovery selection failed.'
}
Run-Test 'Older backup is deeply verified before selection and installed mods stay unchanged' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh')
    $index=Get-Sha256 (Index-Path $p)
    [void](Run-ManagedAction $p 'SelectSnapshot' (Get-ManagedItem $p $old.Id))
    Assert-True ((Load-Snapshot $p).Id -ceq $old.Id) 'Older copy not selected.'
    Assert-True ((Get-Sha256 (Index-Path $p)) -ceq $index -and $script:Launches -eq 0) 'Selection changed game state.'
    Assert-TreeMatches $p.ModsDir $old.Manifest.Files
}
Run-Test 'Corrupt old payload cannot become current even when sizes match' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh'); $current=Load-Snapshot $p; $hash=Get-Sha256 $p.Pointer
    $path=Join-Path $old.Root 'Mods/123456_100/main.pak'
    [IO.File]::WriteAllText($path,('x'*(Get-Item $path).Length))
    $item=Get-ManagedItem $p $old.Id
    Expect-Blocked {Run-ManagedAction $p 'SelectSnapshot' $item}
    Assert-PriorIntact $p $current $hash
}
Run-Test 'Selecting old version never downgrades installed files and subsequent launch blocks' {
    $p=New-Fixture; $old=Seed-Snapshot $p
    [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'),(Join-Path $p.ModsDir '123456_101'))
    [IO.File]::WriteAllText((Index-Path $p),'{"mods":[{"modId":123456,"fileId":101,"status":"valid","name":"Fixture"}]}')
    $script:BackupApproval=(Get-BackupReview $p $true).Approval; [void](Invoke-GuardAction $p 'Refresh')
    [void](Run-ManagedAction $p 'SelectSnapshot' (Get-ManagedItem $p $old.Id))
    Expect-Blocked {Invoke-GuardAction $p 'QuickLaunch'}
    Assert-True (Test-Path (Join-Path $p.ModsDir '123456_101/main.pak')) 'Installed version changed.'
    Assert-True (-not (Test-Path (Join-Path $p.ModsDir '123456_100'))) 'Old version was installed.'
}
Run-Test 'Recognised repair leftovers are moved intact and normal repair can resume' {
    $p=New-Fixture; $s=Seed-Snapshot $p; $hash=Get-Sha256 $p.Pointer; $index=Get-Sha256 (Index-Path $p)
    [IO.File]::Delete((Join-Path $p.ModsDir '123456_100/main.pak'))
    $temp=Add-RepairTemp $p; $tempHash=Get-Sha256 $temp
    Expect-Blocked {Invoke-GuardAction $p 'QuickLaunch'}
    $item=Get-ManagedItem $p 'repair-staging'
    $result=Run-ManagedAction $p 'CleanRepairStaging' $item
    Assert-True (-not (Test-Path $temp) -and $result.FileCount -eq 1) 'Temporary file not moved.'
    $retained=@(Get-SafeFiles (Join-Path $result.RecoveryPath 'Files'))
    Assert-True ($retained.Count -eq 1 -and (Get-Sha256 $retained[0].FullName) -ceq $tempHash) 'Temporary bytes were lost.'
    Assert-PriorIntact $p $s $hash
    Assert-True ((Get-Sha256 (Index-Path $p)) -ceq $index -and $script:Launches -eq 0) 'Cleanup touched index or launched.'
    $r=Invoke-GuardAction $p 'Launch'; Assert-True ($r.FilesRestored -eq 1) 'Repair could not resume.'
}
Run-Test 'Unknown temporary-looking file is not offered for cleanup' {
    $p=New-Fixture; [void](Seed-Snapshot $p); $temp=Add-RepairTemp $p '123456_100/unrelated.bin'
    $r=Get-BackupManager $p
    Assert-True (@($r.Items | Where-Object {$_.Kind -ceq 'RepairStaging'}).Count -eq 0 -and (Test-Path $temp)) 'Unrelated file selected.'
}
Run-Test 'Changed repair leftovers invalidate cleanup approval' {
    $p=New-Fixture; [void](Seed-Snapshot $p); $temp=Add-RepairTemp $p
    $item=Get-ManagedItem $p 'repair-staging'; [IO.File]::AppendAllText($temp,'changed')
    Expect-Blocked {Run-ManagedAction $p 'CleanRepairStaging' $item}
    Assert-True (Test-Path $temp) 'Changed file moved without review.'
}
Run-Test 'Active operation lock blocks deletion selection and cleanup' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh'); [void](Add-RepairTemp $p)
    $item=Get-ManagedItem $p $old.Id; $repair=Get-ManagedItem $p 'repair-staging'
    $lock=Enter-OperationLock $p
    try {
        Expect-Blocked {Run-ManagedAction $p 'RemoveSnapshot' $item}
        Expect-Blocked {Run-ManagedAction $p 'SelectSnapshot' $item}
        Expect-Blocked {Run-ManagedAction $p 'CleanRepairStaging' $repair}
    } finally {$lock.Dispose()}
    Assert-SnapshotContent $old
}
Run-Test 'ARK running blocks all management before any mutation' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh')
    $item=Get-ManagedItem $p $old.Id; $script:ArkRunning=$true
    Expect-Blocked {Run-ManagedAction $p 'RemoveSnapshot' $item}
    Expect-Blocked {Run-ManagedAction $p 'SelectSnapshot' $item}
    Expect-Blocked {Invoke-GuardAction $p 'ManageBackups'}
    $script:ArkRunning=$false; Assert-SnapshotContent $old
}
Run-Test 'Manager rejects forged current-delete flags and malformed result rows' {
    $p=New-Fixture; [void](Seed-Snapshot $p); $r=Get-BackupManager $p
    $r.Items[0].CanDelete=$true
    Assert-True (-not (Test-BackupManagerResult $r)) 'Unsafe current flags accepted.'
    $r.Items[0].CanDelete=$false; $r.Items[0].Approval='bad'
    Assert-True (-not (Test-BackupManagerResult $r)) 'Invalid token accepted.'
}
Run-Test 'Link inserted into reviewed older copy blocks deletion and preserves external files' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh')
    $item=Get-ManagedItem $p $old.Id
    $outside=Join-Path $p.ArkRoot 'outside'; [IO.Directory]::CreateDirectory($outside) | Out-Null
    $valuable=Join-Path $outside 'keep.txt'; [IO.File]::WriteAllText($valuable,'untouched')
    $type=if($env:OS -eq 'Windows_NT'){'Junction'}else{'SymbolicLink'}
    New-Item -ItemType $type -Path (Join-Path $old.Root 'linked') -Target $outside -ErrorAction Stop | Out-Null
    Expect-Blocked {Run-ManagedAction $p 'RemoveSnapshot' $item}
    Assert-True ([IO.File]::ReadAllText($valuable) -ceq 'untouched') 'External target changed.'
    Assert-True (Test-Path (Join-Path $old.Root 'manifest.json')) 'Snapshot partially deleted before link rejection.'
}
Run-Test 'Complete initial copy interrupted before commit can be verified and selected' {
    $p=New-Fixture; $script:CommitFailure=$true
    Expect-Blocked {Invoke-GuardAction $p 'Setup'}; $script:CommitFailure=$false
    $item=(Get-BackupManager $p).Items[0]
    Assert-True ($item.CanSelect -and -not $item.CanDelete -and $item.State -match 'Interrupted') 'Uncommitted complete copy misclassified.'
    [void](Run-ManagedAction $p 'SelectSnapshot' $item)
    Assert-SnapshotContent (Load-Snapshot $p)
}
