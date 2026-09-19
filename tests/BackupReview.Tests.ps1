# Loaded by Safety.Tests.ps1; disposable fixtures only.
function Add-ReviewFixtureMod($Paths) {
    [IO.Directory]::CreateDirectory((Join-Path $Paths.ModsDir '234567_200')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $Paths.ModsDir '234567_200/new.pak'), 'new-mod')
    [IO.File]::WriteAllText((Index-Path $Paths), '{"mods":[{"modId":123456,"fileId":100,"name":"Original"},{"modId":234567,"fileId":200,"name":"Second mod"}]}')
}
Run-Test 'First backup review creates no files, lock, or snapshot' {
    $p = New-Fixture; $indexHash = Get-Sha256 (Index-Path $p)
    $before = @(Get-SafeFiles $p.ArkRoot).Count
    $r = Invoke-GuardAction $p 'PlanSetup'
    Assert-True ($r.Status -ceq 'BackupReview' -and $r.Action -ceq 'Setup' -and $r.Changes.Count -eq 1) 'First review incorrect.'
    Assert-True ((Get-Sha256 (Index-Path $p)) -ceq $indexHash -and @(Get-SafeFiles $p.ArkRoot).Count -eq $before) 'Review wrote files.'
    Assert-True (-not (Test-Path -LiteralPath $p.GuardRoot) -and -not (Test-Path -LiteralPath $p.Lock)) 'Review created state.'
    Assert-True ($r.RequiredBytes -eq $r.CopyBytes + 1GB -and $r.FileCount -eq 2) 'Size estimate incorrect.'
}
Run-Test 'Backup review reports added removed and version-changed names' {
    $p = New-Fixture; Add-ReviewFixtureMod $p; [void](Seed-Snapshot $p)
    [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'), (Join-Path $p.ModsDir '123456_101'))
    [IO.Directory]::Move((Join-Path $p.ModsDir '234567_200'), (Join-Path $p.ArkRoot 'removed'))
    [IO.Directory]::CreateDirectory((Join-Path $p.ModsDir '345678_300')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $p.ModsDir '345678_300/new.pak'), 'third-mod')
    [IO.File]::WriteAllText((Index-Path $p), '{"mods":[{"modId":123456,"fileId":101,"name":"Original"},{"modId":345678,"fileId":300,"name":"Third mod"}]}')
    $r = Invoke-GuardAction $p 'PlanRefresh'; $text = Get-BackupReviewText $r
    Assert-True ($r.Changes.Count -eq 3 -and $text -match 'Removed: Second mod' -and $text -match 'Added: Third mod' -and $text -match 'File 100 -> 101') 'Change review incomplete.'
}
Run-Test 'Yes alone cannot silently accept disappeared mod entries' {
    $p = New-Fixture; Add-ReviewFixtureMod $p; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    [IO.Directory]::Move((Join-Path $p.ModsDir '234567_200'), (Join-Path $p.ArkRoot 'removed'))
    [IO.File]::WriteAllText((Index-Path $p), '{"mods":[{"modId":123456,"fileId":100,"name":"Original"}]}')
    Expect-Blocked { Invoke-GuardAction $p 'Refresh' }; Assert-PriorIntact $p $s $hash
    Assert-True (@(Get-ChildItem -LiteralPath $p.SnapshotsRoot -Directory).Count -eq 1) 'Unapproved snapshot started.'
}
Run-Test 'Reviewed additions save a separate complete backup' {
    $p = New-Fixture; $old = Seed-Snapshot $p; Add-ReviewFixtureMod $p
    $script:BackupApproval = (Get-BackupReview $p $true).Approval
    $r = Invoke-GuardAction $p 'Refresh'
    Assert-True ($r.ModCount -eq 2 -and $r.SnapshotId -ne $old.Id) 'Approved review not saved.'
    Assert-SnapshotContent $old; Assert-SnapshotContent (Load-Snapshot $p)
}
Run-Test 'Changed library after review blocks before a new snapshot starts' {
    $p = New-Fixture; $old = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $script:BackupApproval = (Get-BackupReview $p $true).Approval
    Add-ReviewFixtureMod $p
    Expect-Blocked { Invoke-GuardAction $p 'Refresh' }; Assert-PriorIntact $p $old $hash
    Assert-True (@(Get-ChildItem -LiteralPath $p.SnapshotsRoot -Directory).Count -eq 1) 'Stale review started snapshot.'
}
Run-Test 'Changed file size after review requires another review' {
    $p = New-Fixture; $old = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $script:BackupApproval = (Get-BackupReview $p $true).Approval
    [IO.File]::AppendAllText((Join-Path $p.ModsDir '123456_100/main.pak'), '-larger')
    Expect-Blocked { Invoke-GuardAction $p 'Refresh' }; Assert-PriorIntact $p $old $hash
}
Run-Test 'Changed selected backup invalidates a previously reviewed save' {
    $p = New-Fixture; [void](Seed-Snapshot $p)
    $approved = (Get-BackupReview $p $true).Approval
    [void](Invoke-GuardAction $p 'Refresh'); $current = Load-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $script:BackupApproval = $approved
    Expect-Blocked { Invoke-GuardAction $p 'Refresh' }; Assert-PriorIntact $p $current $hash
}
Run-Test 'File layout change during source hashing cannot bypass reviewed sizes' {
    $p = New-Fixture; $old = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $script:BackupApproval = (Get-BackupReview $p $true).Approval
    $nativeManifest = ${function:Get-TreeManifest}
    function Get-TreeManifest([string]$Root) {
        [IO.File]::AppendAllText((Join-Path $Root '123456_100/main.pak'), '-grew-during-hash')
        return & $nativeManifest $Root
    }
    Expect-Blocked { Invoke-GuardAction $p 'Refresh' }; Assert-PriorIntact $p $old $hash
    Assert-True (@(Get-ChildItem -LiteralPath $p.SnapshotsRoot -Directory).Count -eq 1) 'Changed layout started backup.'
}
Run-Test 'Backup approval cannot cross installations' {
    $a = New-Fixture; $b = New-Fixture
    $script:BackupApproval = (Get-BackupReview $a $false).Approval
    Expect-Blocked { Invoke-GuardAction $b 'Setup' }
    Assert-True (-not (Test-Path -LiteralPath $b.Pointer)) 'Cross-installation approval accepted.'
}
Run-Test 'Missing installed folder cannot be accepted as reviewed backup' {
    $p = New-Fixture; $s = Seed-Snapshot $p
    [IO.Directory]::Move((Join-Path $p.ModsDir '123456_100'), (Join-Path $p.ArkRoot 'missing'))
    Expect-Blocked { Invoke-GuardAction $p 'PlanRefresh' }
    Assert-SnapshotContent $s
}
Run-Test 'Review cannot run while ARK is active' {
    $p = New-Fixture; $script:ArkRunning = $true
    Expect-Blocked { Invoke-GuardAction $p 'PlanSetup' }
    Assert-True (-not (Test-Path -LiteralPath $p.GuardRoot)) 'Blocked review created state.'
}
Run-Test 'Review wire result preserves zero and one change and rejects wrong action' {
    $p = New-Fixture
    $one = (Invoke-GuardAction $p 'PlanSetup') | ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json
    Assert-True (Test-BackupReviewResult $one 'Setup') 'One-change result lost structure.'
    [void](Seed-Snapshot $p)
    $zero = (Invoke-GuardAction $p 'PlanRefresh') | ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json
    Assert-True (Test-BackupReviewResult $zero 'Refresh') 'Zero-change result lost structure.'
    Assert-True (-not (Test-BackupReviewResult $zero 'Setup') -and -not (Test-BackupReviewResult $null 'Refresh')) 'Invalid approval accepted.'
    $zero.Approval = 'invalid'
    Assert-True (-not (Test-BackupReviewResult $zero 'Refresh')) 'Malformed review token accepted.'
}
Run-Test 'Index change during staged repair prevents installation of the staged file' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $pointerHash = Get-Sha256 $p.Pointer
    $destination = Join-Path $p.ModsDir '123456_100/main.pak'
    [IO.File]::Move($destination, (Join-Path $p.ArkRoot 'removed-file'))
    $nativeHash = ${function:Get-Sha256}
    function Get-Sha256([string]$Path) {
        $value = & $nativeHash $Path
        if ($Path -match '\.modlocket-[0-9a-f]{32}\.tmp$') {
            [IO.File]::WriteAllText((Index-Path $p), '{"mods":[{"modId":123456,"fileId":101,"name":"Changed during repair"}]}')
        }
        return $value
    }
    Expect-Blocked { Invoke-GuardAction $p 'Launch' }
    Assert-True (-not (Test-Path -LiteralPath $destination)) 'Staged file was installed after index changed.'
    Assert-True ((Get-LibraryData (Index-Path $p)).Records['123456'].FileId -ceq '101') 'Updated index was overwritten.'
    Assert-True ($script:Launches -eq 0) 'Steam requested after index race.'
    Assert-PriorIntact $p $s $pointerHash
}
