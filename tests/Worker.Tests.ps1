# Loaded by Safety.Tests.ps1. Every path is a synthetic fixture under its testRoot.
Add-Type -Path (Join-Path $release 'ModLocket-Worker.cs')
if ($env:OS -ne 'Windows_NT') {
    Write-Output 'SKIP | 12 Windows process-containment/interruption tests (requires Windows kernel).'
    return
}
function Quote-WorkerLiteral([string]$Text) { return "'" + $Text.Replace("'", "''") + "'" }
function Wait-WorkerCondition([scriptblock]$Condition, [string]$Description) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($watch.Elapsed.TotalSeconds -gt 20) { throw "Timed out: $Description" }
        Start-Sleep -Milliseconds 50
    }
}
function New-PausedWorker($Paths, [string]$Hook, [string]$Action) {
    $script:WorkerSignal = Join-Path $Paths.ArkRoot 'checkpoint.txt'
    $cmd = '. ' + (Quote-WorkerLiteral (Join-Path $release 'ModLocket-Core.ps1')) + ' -LibraryOnly -Yes -DeferSteamLaunch; '
    $cmd += '$p=Get-Paths ' + (Quote-WorkerLiteral $Paths.ArkRoot) + '; $signal=' + (Quote-WorkerLiteral $script:WorkerSignal) + '; '
    $cmd += 'function Pause-Checkpoint { [IO.File]::WriteAllText($signal,"paused"); while($true){[Threading.Thread]::Sleep(50)} }; '
    $cmd += 'function Start-Process {throw "A fixture must never launch Steam"}; '
    $cmd += $Hook + '; Invoke-GuardAction $p ' + (Quote-WorkerLiteral $Action)
    return [ModLocket.OwnedWorker]::Start((Join-Path $PSHOME 'powershell.exe'), $cmd, (Join-Path $release 'ModLocket-Worker-Entry.ps1'))
}
function Stop-CheckpointWorker($Worker) {
    Wait-WorkerCondition { Test-Path -LiteralPath $script:WorkerSignal } 'worker checkpoint'
    $Worker.Stop()
    Wait-WorkerCondition { $Worker.Finished } 'all owned processes stopping'
    Assert-True ($Worker.ActiveCount -eq 0 -and $Worker.Cancelled) 'Worker did not stop completely.'
}
Run-Test 'Windows interrupted deletion can resume and never changes current backup' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh')
    $current=Load-Snapshot $p; $hash=Get-Sha256 $p.Pointer; $index=Get-Sha256 (Index-Path $p)
    $hook='$TargetId=' + (Quote-WorkerLiteral $old.Id) + '; $ManagementApproval=((Get-BackupManager $p).Items | Where-Object {$_.Id -ceq $TargetId}).Approval; '
    $hook+='function Write-StageProgress($Stage,$Completed,$Total) {if($Stage -ceq "Removing older backup" -and $Completed -eq 1){Pause-Checkpoint}}'
    $w=New-PausedWorker $p $hook 'RemoveSnapshot'
    try {Stop-CheckpointWorker $w} finally {$w.Dispose()}
    Assert-PriorIntact $p $current $hash
    [void](Run-ManagedAction $p 'RemoveSnapshot' (Get-ManagedItem $p $old.Id))
    Assert-True (-not (Test-Path $old.Root) -and (Get-Sha256 (Index-Path $p)) -ceq $index) 'Deletion did not safely resume.'
}
Run-Test 'Windows interrupted cleanup retains moved bytes and resumes remaining files' {
    $p=New-Fixture; $s=Seed-Snapshot $p; $hash=Get-Sha256 $p.Pointer
    [void](Add-RepairTemp $p); [void](Add-RepairTemp $p '123456_100/nested/data.bin')
    $hook='$ManagementApproval=((Get-BackupManager $p).Items | Where-Object {$_.Kind -ceq "RepairStaging"}).Approval; '
    $hook+='function Write-StageProgress($Stage,$Completed,$Total) {if($Stage -ceq "Moving interrupted repair files" -and $Completed -eq 1){Pause-Checkpoint}}'
    $w=New-PausedWorker $p $hook 'CleanRepairStaging'
    try {Stop-CheckpointWorker $w} finally {$w.Dispose()}
    Assert-PriorIntact $p $s $hash
    Assert-True (@(Get-RepairLeftovers $p $s).Count -eq 1) 'Remaining staging file lost.'
    [void](Run-ManagedAction $p 'CleanRepairStaging' (Get-ManagedItem $p 'repair-staging'))
    $retained=@(Get-SafeFiles (Join-Path $p.GuardRoot 'Recovery') | Where-Object {$_.Name -match '\.tmp$'})
    Assert-True ($retained.Count -eq 2 -and @(Get-RepairLeftovers $p $s).Count -eq 0) 'Cleanup resume lost files.'
    foreach ($file in $retained) {Assert-True ([IO.File]::ReadAllText($file.FullName) -ceq 'partial repair payload') 'Temporary bytes changed.'}
}
Run-Test 'Windows cancelled older-backup verification preserves selection' {
    $p=New-Fixture; $old=Seed-Snapshot $p; [void](Invoke-GuardAction $p 'Refresh')
    $current=Load-Snapshot $p; $hash=Get-Sha256 $p.Pointer
    $hook='$TargetId=' + (Quote-WorkerLiteral $old.Id) + '; $ManagementApproval=((Get-BackupManager $p).Items | Where-Object {$_.Id -ceq $TargetId}).Approval; '
    $hook+='function Assert-SnapshotContent($Snapshot) {Pause-Checkpoint}'
    $w=New-PausedWorker $p $hook 'SelectSnapshot'
    try {Stop-CheckpointWorker $w} finally {$w.Dispose()}
    Assert-PriorIntact $p $current $hash; Assert-SnapshotContent $old
}
Run-Test 'Windows worker emits readable progress and preserves actual errors and exit code' {
    $cmd = 'Write-Host "HOST-CHECK"; Write-Output "OUTPUT-CHECK"; Write-Host ''__MODLOCKET_PROGRESS__={"Stage":"Testing","Percent":50}''; Write-Error "ERROR-CHECK" -ErrorAction Continue; exit 7'
    $w = [ModLocket.OwnedWorker]::Start((Join-Path $PSHOME 'powershell.exe'), $cmd, (Join-Path $release 'ModLocket-Worker-Entry.ps1'))
    try {
        Wait-WorkerCondition {$w.Finished} 'output transport completion'
        $lines = @($w.Drain()); $text = $lines -join "`n"
        Assert-True ($w.ExitCode -eq 7) 'Worker exit code was lost.'
        Assert-True ($lines -contains 'HOST-CHECK' -and $lines -contains 'OUTPUT-CHECK') 'Normal output was lost.'
        Assert-True ($lines -contains '__MODLOCKET_PROGRESS__={"Stage":"Testing","Percent":50}') 'Progress marker was damaged.'
        Assert-True ($text -match '\[ERROR\].*ERROR-CHECK') 'Real error was hidden.'
        Assert-True ($text -notmatch 'CLIXML|<Objs|<Obj ') 'Serialized XML leaked into status output.'
        Assert-True ($lines -notcontains '[ERROR] HOST-CHECK') 'Normal host output was labeled an error.'
    } finally {$w.Dispose()}
}
Run-Test 'Windows cancellation kills owned descendants and leaves unrelated process alone' {
    $p = New-Fixture; $signal = Join-Path $p.ArkRoot 'child.txt'
    $exe = Join-Path $PSHOME 'powershell.exe'
    $sleepArgs = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 60'))
    $si = New-Object Diagnostics.ProcessStartInfo $exe, $sleepArgs
    $si.UseShellExecute = $false; $si.CreateNoWindow = $true
    $unrelated = [Diagnostics.Process]::Start($si); $w = $null; $child = $null
    try {
        $cmd = '$si=New-Object Diagnostics.ProcessStartInfo ' + (Quote-WorkerLiteral $exe) + ', ' + (Quote-WorkerLiteral $sleepArgs) + '; '
        $cmd += '$si.UseShellExecute=$false; $si.CreateNoWindow=$true; $c=[Diagnostics.Process]::Start($si); [IO.File]::WriteAllText(' + (Quote-WorkerLiteral $signal) + ',[string]$c.Id); Start-Sleep -Seconds 60'
        $w = [ModLocket.OwnedWorker]::Start($exe, $cmd, (Join-Path $release 'ModLocket-Worker-Entry.ps1'))
        Wait-WorkerCondition {Test-Path -LiteralPath $signal} 'descendant created'
        $child = [Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($signal))
        Assert-True ($w.ActiveCount -ge 2) 'Descendant not contained.'
        $w.Stop(); Wait-WorkerCondition {$w.Finished} 'descendants terminated'
        Assert-True ($child.HasExited -and -not $unrelated.HasExited) 'Wrong process termination scope.'
    } finally {
        if ($w) {$w.Dispose()}; if ($child) {$child.Dispose()}
        if (-not $unrelated.HasExited) {$unrelated.Kill()}; $unrelated.Dispose()
    }
}
Run-Test 'Windows disposing owner terminates worker without process-name matching' {
    $w = [ModLocket.OwnedWorker]::Start((Join-Path $PSHOME 'powershell.exe'), 'Start-Sleep -Seconds 60', (Join-Path $release 'ModLocket-Worker-Entry.ps1'))
    $process = [Diagnostics.Process]::GetProcessById($w.ProcessId)
    try { $w.Dispose(); Wait-WorkerCondition {$process.HasExited} 'kill-on-close' }
    finally {$w.Dispose(); $process.Dispose()}
}
Run-Test 'Windows interrupted copied backup preserves selected snapshot and live library' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer; $indexHash = Get-Sha256 (Index-Path $p)
    $hook = '$copy=${function:Invoke-Robocopy}; function Invoke-Robocopy($Source,$Destination) { & $copy $Source $Destination; Pause-Checkpoint }'
    $w = New-PausedWorker $p $hook 'Refresh'
    try { Stop-CheckpointWorker $w } finally {$w.Dispose()}
    Assert-PriorIntact $p $s $hash
    Assert-True ((Get-Sha256 (Index-Path $p)) -eq $indexHash) 'Live library changed.'
    Assert-TreeMatches $p.ModsDir $s.Manifest.Files
    $lock = Enter-OperationLock $p; $lock.Dispose()
}
Run-Test 'Windows cancellation before backup commit leaves previous selection intact' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $w = New-PausedWorker $p 'function Commit-SnapshotPointer($Paths,$Snapshot) { Pause-Checkpoint }' 'Refresh'
    try { Stop-CheckpointWorker $w } finally {$w.Dispose()}
    Assert-PriorIntact $p $s $hash
    Assert-TreeMatches $p.ModsDir $s.Manifest.Files
}
Run-Test 'Windows staged repair interruption never exposes partial destination or launches' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer; $indexHash = Get-Sha256 (Index-Path $p)
    $missing = Join-Path $p.ModsDir '123456_100/main.pak'; [IO.File]::Delete($missing)
    $hook = '$hashFn=${function:Get-Sha256}; function Get-Sha256([string]$Path) { if($Path -match "\.modlocket-[0-9a-f]+\.tmp$"){Pause-Checkpoint}; & $hashFn $Path }'
    $w = New-PausedWorker $p $hook 'Launch'
    try { Stop-CheckpointWorker $w } finally {$w.Dispose()}
    Assert-True (-not (Test-Path -LiteralPath $missing)) 'Partial repair destination became visible.'
    Assert-PriorIntact $p $s $hash
    Assert-True ((Get-Sha256 (Index-Path $p)) -eq $indexHash) 'Repair changed index.'
    # Staging leftovers deliberately fail closed rather than being silently adopted.
    Expect-Blocked { Invoke-GuardAction $p 'QuickLaunch' }
}
Run-Test 'Windows cancellation after one repair preserves verified recovered file' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $missing = Join-Path $p.ModsDir '123456_100/main.pak'; [IO.File]::Delete($missing)
    $hook = '$repair=${function:Copy-MissingProtectedFile}; function Copy-MissingProtectedFile($Source,$Destination,$Expected,$LibraryPath,$LibraryHash) { & $repair $Source $Destination $Expected $LibraryPath $LibraryHash; Pause-Checkpoint }'
    $w = New-PausedWorker $p $hook 'Launch'
    try { Stop-CheckpointWorker $w } finally {$w.Dispose()}
    Assert-PriorIntact $p $s $hash
    Assert-TreeMatches $p.ModsDir $s.Manifest.Files
    $r = Invoke-GuardAction $p 'QuickLaunch'
    Assert-True ($r.Status -eq 'QuickChecked') 'Verified recovered file cannot be reused.'
}
Run-Test 'Windows cancellation during source hashing preserves the selected snapshot' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer
    $hook = '$hashFn=${function:Get-Sha256}; function Get-Sha256([string]$Path) { if($Path -match "[\\/]Mods[\\/]83374[\\/]"){Pause-Checkpoint}; & $hashFn $Path }'
    $w = New-PausedWorker $p $hook 'Refresh'
    try { Stop-CheckpointWorker $w } finally {$w.Dispose()}
    Assert-PriorIntact $p $s $hash
    Assert-TreeMatches $p.ModsDir $s.Manifest.Files
}
Run-Test 'Windows cancellation during native Robocopy stops copy and keeps prior backup' {
    $p = New-Fixture; $s = Seed-Snapshot $p; $hash = Get-Sha256 $p.Pointer; $indexHash = Get-Sha256 (Index-Path $p)
    $large = Join-Path $p.ModsDir '123456_100/large-fixture.bin'
    $stream = [IO.File]::Create($large)
    try {$stream.SetLength(16MB)} finally {$stream.Dispose()}
    # Only this synthetic test throttles copying so the child is still active at cancellation.
    $hook = 'function Invoke-Robocopy($Source,$Destination) { [IO.File]::WriteAllText($signal,"copy starting"); & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NP /IPG:100 | Out-Host; if($LASTEXITCODE -ge 8){throw "copy failed"} }'
    $w = New-PausedWorker $p $hook 'Refresh'
    try {
        Wait-WorkerCondition {$w.ActiveCount -ge 2} 'native copy process'
        $w.Stop(); Wait-WorkerCondition {$w.Finished} 'native copy stopped'
        Assert-True ($w.ActiveCount -eq 0) 'Native copy still running.'
    } finally {$w.Dispose()}
    Assert-PriorIntact $p $s $hash
    Assert-True ((Get-Sha256 (Index-Path $p)) -eq $indexHash) 'Live index changed.'
    Assert-True ((Get-Item -LiteralPath $large).Length -eq 16MB) 'Live source changed.'
    foreach ($entry in $s.Manifest.Files) {
        Assert-True ((Get-Sha256 (Join-SafePath $p.ModsDir $entry.Path)) -eq $entry.Sha256) 'Original live file changed.'
    }
    $lock = Enter-OperationLock $p; $lock.Dispose()
}
