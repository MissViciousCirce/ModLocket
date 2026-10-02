# Loaded by ModLocket-Core.ps1. Management never modifies ARK's library index.
function Get-BackupPointerState($Paths) {
    Assert-NoLinks $Paths.Pointer
    if (-not (Test-Path -LiteralPath $Paths.Pointer)) {
        return [pscustomobject]@{ Id=''; Hash='none'; Snapshot=$null }
    }
    $hash = Get-Sha256 $Paths.Pointer
    $snapshot = Load-Snapshot $Paths
    if ((Get-Sha256 $Paths.Pointer) -cne $hash) { throw 'Backup selection changed. Open Manage Backups again.' }
    return [pscustomobject]@{ Id=$snapshot.Id; Hash=$hash; Snapshot=$snapshot }
}
function Get-ManagementToken($Paths, [string]$Kind, [string]$Id, [string]$PointerHash, [object[]]$Layout) {
    $json = ConvertTo-Json -Depth 8 -Compress -InputObject ([ordered]@{
        Root=$Paths.ArkRoot; Kind=$Kind; Id=$Id; Pointer=$PointerHash; Layout=@($Layout)
    })
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-ManagementLayout([string]$Root) {
    # Include empty directories, which also matter when reviewing deletion.
    $queue = New-Object 'Collections.Generic.Queue[string]'; $queue.Enqueue($Root)
    Assert-NoLinks $Root
    $rows = New-Object 'Collections.Generic.List[object]'
    while ($queue.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $queue.Dequeue() -Force -ErrorAction Stop)) {
            $relative = Get-RelativeName $Root $item.FullName
            Assert-NoLinks $item.FullName
            # Folder timestamps can change after copying without any file/layout
            # change (observed on Windows). Track folder paths/types, not times.
            # File timestamps and metadata checksums remain part of the review.
            $length = 0L; $ticks = 0L; $checksum = ''
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
            else {
                $length = $item.Length; $ticks = $item.LastWriteTimeUtc.Ticks
                if ($relative -in @('manifest.json','pending.json')) { $checksum = Get-Sha256 $item.FullName }
            }
            $rows.Add([pscustomobject]@{ Path=$relative; Directory=[bool]$item.PSIsContainer; Length=$length; Ticks=$ticks; Checksum=$checksum })
        }
    }
    return @($rows | Sort-Object Path)
}
function Get-RepairLeftovers($Paths, $Snapshot) {
    if (-not $Snapshot -or -not (Test-Path -LiteralPath $Paths.ModsDir)) { return }
    $expected = @{}; foreach ($file in $Snapshot.Manifest.Files) { $expected[[string]$file.Path] = $true }
    foreach ($file in @(Get-SafeFiles $Paths.ModsDir | Sort-Object FullName)) {
        $relative = Get-RelativeName $Paths.ModsDir $file.FullName
        if ($relative -cmatch '^(.*)\.modlocket-[0-9a-f]{32}\.tmp$' -and
            $expected.ContainsKey($Matches[1]) -and -not $expected.ContainsKey($relative)) {
            [pscustomobject]@{ Path=$relative; Length=[long]$file.Length; Ticks=$file.LastWriteTimeUtc.Ticks }
        }
    }
}
function Get-BackupManager($Paths) {
    Assert-ArkClosed
    $state = Get-BackupPointerState $Paths
    $items = New-Object 'Collections.Generic.List[object]'
    $total = 0L; $ignored = 0
    Assert-NoLinks $Paths.SnapshotsRoot
    if (Test-Path -LiteralPath $Paths.SnapshotsRoot) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $Paths.SnapshotsRoot -Force | Sort-Object Name)) {
            Assert-NoLinks $folder.FullName
            if (-not $folder.PSIsContainer -or $folder.Name -cnotmatch '^[0-9a-f]{32}$') { $ignored++; continue }
            Write-StageProgress 'Reading backup sizes'
            $layout = @(Get-ManagementLayout $folder.FullName)
            $bytes = [long](($layout | Measure-Object Length -Sum).Sum); $total += $bytes
            $valid = $false; $count = 0; $created = $folder.CreationTimeUtc.ToString('o')
            $description = 'Incomplete or damaged'; $pending = $false
            try {
                $manifest = Read-JsonRoot (Join-Path $folder.FullName 'manifest.json')
                Assert-Manifest $Paths $manifest $folder.Name
                Assert-SnapshotMetadata ([pscustomobject]@{Root=$folder.FullName;Manifest=$manifest})
                $valid = $true; $count = $manifest.Mods.Count; $created = [string]$manifest.CreatedUtc
                $description = 'Saved; contents not rechecked'
            } catch { $description = 'Incomplete or damaged' }
            if (Test-Path -LiteralPath (Join-Path $folder.FullName 'pending.json')) {
                try {
                    $record = Read-JsonRoot (Join-Path $folder.FullName 'pending.json')
                    $pending = ($record.SchemaVersion -eq 1 -and $record.Kind -ceq 'Snapshot' -and
                        $record.Id -ceq $folder.Name -and (Test-SamePath $record.ArkRoot $Paths.ArkRoot))
                } catch { $pending = $false }
                if ($pending -and $folder.Name -cne $state.Id) { $description = 'Interrupted; verification required' }
            }
            $current = ($folder.Name -ceq $state.Id)
            if ($current) { $description = 'Current - protected from deletion' }
            $items.Add([pscustomobject]@{
                Kind='Snapshot'; Id=$folder.Name; CreatedUtc=$created; State=$description; Bytes=$bytes; ModCount=$count
                Current=$current; CanDelete=([bool](-not $current -and ($state.Id -or (($pending -or @($layout | Where-Object {-not $_.Directory}).Count -eq 0) -and -not $valid))))
                CanSelect=([bool]($valid -and -not $current)); Approval=(Get-ManagementToken $Paths 'Snapshot' $folder.Name $state.Hash $layout)
            })
        }
    }
    $leftovers = @(Get-RepairLeftovers $Paths $state.Snapshot)
    if ($leftovers.Count) {
        $items.Add([pscustomobject]@{
            Kind='RepairStaging'; Id='repair-staging'; CreatedUtc=''; State="Interrupted repair: $($leftovers.Count) temporary files"
            Bytes=[long](($leftovers | Measure-Object Length -Sum).Sum); ModCount=0; Current=$false; CanDelete=$false; CanSelect=$false
            Approval=(Get-ManagementToken $Paths 'RepairStaging' 'repair-staging' $state.Hash $leftovers)
        })
    }
    $recovery = Join-SafePath $Paths.GuardRoot 'Recovery'
    $recoveryBytes = 0L
    if (Test-Path -LiteralPath $recovery) { $recoveryBytes = [long]((@(Get-SafeFiles $recovery) | Measure-Object Length -Sum).Sum) }
    Assert-ArkClosed
    if ((Get-BackupPointerState $Paths).Hash -cne $state.Hash) { throw 'Backup selection changed during review. Open Manage Backups again.' }
    return [pscustomobject]@{ Status='BackupManager'; Items=$items.ToArray(); TotalBytes=$total; RecoveryBytes=$recoveryBytes; IgnoredItems=$ignored; CurrentId=$state.Id }
}
function Get-ApprovedManagementItem($Paths, [string]$Id, [string]$Approval) {
    if ($Id -cnotmatch '^(?:[0-9a-f]{32}|repair-staging)$' -or $Approval -cnotmatch '^[0-9a-f]{64}$') { throw 'A reviewed backup selection is required.' }
    $review = Get-BackupManager $Paths
    $matches = @($review.Items | Where-Object { $_.Id -ceq $Id })
    if ($matches.Count -ne 1 -or $matches[0].Approval -cne $Approval) { throw 'Backup contents or selection changed. Open Manage Backups again; nothing was changed.' }
    return $matches[0]
}
function Remove-ManagedSnapshot($Paths, [string]$Id, [string]$Approval) {
    $item = Get-ApprovedManagementItem $Paths $Id $Approval
    if ($item.Kind -cne 'Snapshot' -or -not $item.CanDelete -or $item.Current) { throw 'The current backup, or an unprotected last backup, cannot be deleted.' }
    if (-not (Confirm-Action "Permanently delete backup $Id? This cannot be undone.")) { throw 'Deletion cancelled.' }
    # Revalidate after a CLI confirmation as well. The caller holds the operation lock.
    $item = Get-ApprovedManagementItem $Paths $Id $Approval
    if (-not $item.CanDelete -or $item.Current) { throw 'This backup is now protected.' }
    $root = Join-SafePath $Paths.SnapshotsRoot $Id
    $layout = @(Get-ManagementLayout $root)
    $pointerHash = (Get-BackupPointerState $Paths).Hash
    $count = @($layout | Where-Object {-not $_.Directory}).Count; $done = 0
    # Never recursively delete: enumerate checked files, then empty directories.
    foreach ($row in @($layout | Where-Object {-not $_.Directory} | Sort-Object { if ($_.Path -ceq 'pending.json') { 1 } else { 0 } }, Path)) {
        Assert-ArkClosed
        if (($pointerHash -ceq 'none' -and (Test-Path -LiteralPath $Paths.Pointer)) -or
            ($pointerHash -cne 'none' -and (Get-Sha256 $Paths.Pointer) -cne $pointerHash)) { throw 'Backup selection changed; deletion stopped.' }
        $path = Join-SafePath $root $row.Path
        [IO.File]::Delete($path); $done++; Write-StageProgress 'Removing older backup' $done $count
    }
    foreach ($row in @($layout | Where-Object {$_.Directory} | Sort-Object { $_.Path.Length } -Descending)) {
        Assert-ArkClosed; [IO.Directory]::Delete((Join-SafePath $root $row.Path), $false)
    }
    Assert-ArkClosed; Assert-NoLinks $root; [IO.Directory]::Delete($root, $false)
    Write-Good 'Selected older copy removed. The current backup and installed mods were preserved.'
    return [pscustomobject]@{Status='SnapshotRemoved';SnapshotId=$Id}
}
function Select-ManagedSnapshot($Paths, [string]$Id, [string]$Approval) {
    $item = Get-ApprovedManagementItem $Paths $Id $Approval
    if ($item.Kind -cne 'Snapshot' -or -not $item.CanSelect) { throw 'That copy cannot be selected.' }
    if (-not (Confirm-Action 'Fully verify and select this backup? Installed mods will not be changed.')) { throw 'Selection cancelled.' }
    [void](Get-ApprovedManagementItem $Paths $Id $Approval)
    $root = Join-SafePath $Paths.SnapshotsRoot $Id
    $manifest = Read-JsonRoot (Join-SafePath $root 'manifest.json')
    Assert-Manifest $Paths $manifest $Id
    $snapshot = [pscustomobject]@{Id=$Id;Root=$root;Manifest=$manifest}
    Assert-SnapshotContent $snapshot
    [void](Get-ApprovedManagementItem $Paths $Id $Approval)
    Commit-SnapshotPointer $Paths $snapshot
    Write-Good 'Verified backup selected. Installed mods were not changed. Launch still requires matching installed versions.'
    return [pscustomobject]@{Status='SnapshotSelected';SnapshotId=$Id}
}
function Move-RepairLeftovers($Paths, [string]$Approval) {
    [void](Get-ApprovedManagementItem $Paths 'repair-staging' $Approval)
    if (-not (Confirm-Action 'Move recognised interrupted repair files out of the mod folders? Their bytes will be retained in Recovery.')) { throw 'Cleanup cancelled.' }
    [void](Get-ApprovedManagementItem $Paths 'repair-staging' $Approval)
    $state = Get-BackupPointerState $Paths
    $files = @(Get-RepairLeftovers $Paths $state.Snapshot)
    $root = Join-SafePath $Paths.GuardRoot ('Recovery/' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Write-NewJson (Join-SafePath $root 'recovery.json') ([pscustomobject]@{ SchemaVersion=1; ArkRoot=$Paths.ArkRoot; CreatedUtc=[DateTime]::UtcNow.ToString('o'); Files=$files })
    $done = 0
    foreach ($file in $files) {
        Assert-ArkClosed
        if ((Get-BackupPointerState $Paths).Hash -cne $state.Hash) { throw 'Backup selection changed. Cleanup stopped; moved files remain in Recovery.' }
        $source = Join-SafePath $Paths.ModsDir $file.Path
        $target = Join-SafePath $root ('Files/' + $file.Path)
        [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
        [IO.File]::Move($source, $target)
        $done++; Write-StageProgress 'Moving interrupted repair files' $done $files.Count
    }
    Write-Good "Temporary repair files moved to: $root. Run Verify + Repair to finish recovery."
    return [pscustomobject]@{Status='RepairStagingMoved';FileCount=$done;RecoveryPath=$root}
}
