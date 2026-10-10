# Restore backed-up files and missing records, never replace an installed version.
function Get-RestoreSnapshot($Paths, [string]$Id, [string]$ManifestHash) {
    if ($Id -cnotmatch '^[0-9a-f]{32}$' -or $ManifestHash -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid recovery snapshot identity.' }
    $root = Join-SafePath $Paths.SnapshotsRoot $Id
    $manifestPath = Join-SafePath $root 'manifest.json'
    if ((Get-Sha256 $manifestPath) -cne $ManifestHash) { throw 'Recovery snapshot changed.' }
    $manifest = Read-JsonRoot $manifestPath
    Assert-Manifest $Paths $manifest $Id
    $snapshot = [pscustomobject]@{ Id=$Id; Root=$root; Manifest=$manifest }
    Assert-SnapshotMetadata $snapshot
    return $snapshot
}
function Assert-RestoreLibraryState([string]$LibraryPath, [string]$ExpectedHash) {
    Assert-ArkClosed
    if ((Get-Sha256 $LibraryPath) -cne $ExpectedHash) { throw 'ARK installation records changed during recovery. Close ARK and review again; no records were overwritten.' }
}
function Get-ModRestoreReview($Paths) {
    Assert-ArkClosed
    if (-not (Test-Path -LiteralPath $Paths.Pointer -PathType Leaf)) { throw 'No full backup is selected for this ARK folder. A saved mod list cannot restore files. Select a full backup in MANAGE BACKUPS, or install the mods in ARK and click BACKUP first.' }
    $snapshot = Load-Snapshot $Paths
    Assert-SnapshotMetadata $snapshot
    $libraryPath = Find-LibraryJson $Paths.UserDataRoot
    if ((Get-RelativeName $Paths.UserDataRoot $libraryPath) -cne $snapshot.Manifest.LibraryRelativePath) { throw 'The ARK account/path differs from this backup. Select a backup for this account.' }
    $hash = Get-Sha256 $libraryPath
    $library = Get-LibraryData $libraryPath
    $savedPath = Join-SafePath (Join-Path $snapshot.Root 'Metadata') $snapshot.Manifest.LibraryRelativePath
    $saved = Get-LibraryData $savedPath
    Initialize-UpdateHelpers
    # Validate both raw documents without reserializing their records.
    [void][ModLocket.JsonPatch]::RestoreRecords([IO.File]::ReadAllText($libraryPath), [IO.File]::ReadAllText($savedPath), [string[]]@())
    $rows = New-Object 'Collections.Generic.List[object]'
    $targets = New-Object 'Collections.Generic.List[object]'
    $recordIds = New-Object 'Collections.Generic.List[string]'
    $missing = New-Object 'Collections.Generic.List[object]'
    $count = 0
    foreach ($mod in $snapshot.Manifest.Mods) {
        Write-StageProgress 'Reviewing backed-up mods' $count $snapshot.Manifest.Mods.Count
        $count++
        $id = [string]$mod.ModId; $entry = $library.Records[$id]
        $state = 'Already present'; $reason = 'Backed-up files are present.'; $modMissing = @(); $restoreRecord = -not $entry
        try {
            if ($entry -and $entry.FileId -cne [string]$mod.FileId) { throw 'Installed version differs from backup; kept unchanged.' }
            if ($entry) {
                $problems = @($entry.Issues | Where-Object { $_ -cne "ARK status: 'OutOfDate'" })
                if ($problems.Count) { throw ('ARK needs to finish or repair this entry: ' + ($problems -join '; ')) }
            }
            $savedEntry = $saved.Records[$id]
            if ($savedEntry.Profile -ceq 'ASA' -and -not (Test-RecordedModPath $Paths $savedEntry)) { throw 'Backup installation path does not match this ARK folder.' }
            if ($entry -and $entry.Profile -ceq 'ASA' -and -not (Test-RecordedModPath $Paths $entry)) { throw 'Current installation path is unexpected.' }
            $folder = Join-SafePath $Paths.ModsDir ([string]$mod.FolderName)
            if (Test-Path -LiteralPath $Paths.ModsDir) {
                $otherVersions = @(Get-ChildItem -LiteralPath $Paths.ModsDir -Force | Where-Object { $_.Name -like ($id + '_*') -and $_.Name -cne [string]$mod.FolderName })
                if ($otherVersions.Count) { throw 'Another version folder exists; kept unchanged for review in ARK.' }
            }
            $files = @($snapshot.Manifest.Files | Where-Object { ([string]$_.Path).StartsWith([string]$mod.FolderName + '/', [StringComparison]::Ordinal) })
            $expected = @{}; foreach ($file in $files) { $expected[[string]$file.Path] = $file }
            if (Test-Path -LiteralPath $folder) {
                foreach ($live in @(Get-SafeFiles $folder)) {
                    $relative = Get-RelativeName $Paths.ModsDir $live.FullName
                    if (-not $expected.ContainsKey($relative) -or $live.Length -ne [long]$expected[$relative].Length -or (Get-Sha256 $live.FullName) -cne [string]$expected[$relative].Sha256) { throw 'Existing files differ from the backup; kept unchanged.' }
                }
            }
            foreach ($file in $files) {
                $target = Join-SafePath $Paths.ModsDir ([string]$file.Path)
                if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'A folder occupies an expected mod-file path; kept unchanged.' }
            }
            $modMissing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-SafePath $Paths.ModsDir ([string]$_.Path)) -PathType Leaf) })
            if ($restoreRecord -or $modMissing.Count) {
                # Verify the full selected backup mod before offering restoration.
                foreach ($file in $files) {
                    $source = Join-SafePath (Join-Path $snapshot.Root 'Mods') ([string]$file.Path)
                    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -ne [long]$file.Length -or (Get-Sha256 $source) -cne [string]$file.Sha256) { throw 'Backup files are missing or damaged; cannot restore this mod.' }
                }
                $targets.Add([pscustomobject]@{ ModId=$id; FileId=[string]$mod.FileId; FolderName=[string]$mod.FolderName })
                foreach ($file in $modMissing) { $missing.Add($file) }
                if ($restoreRecord) { $recordIds.Add($id) }
                $state = 'Restore from backup'
                $reason = "$($modMissing.Count) missing files" + $(if ($restoreRecord) { ' and missing installation record.' } else { '; existing record kept.' })
            }
        } catch { $state='Needs attention'; $reason=$_.Exception.Message }
        $rows.Add([pscustomobject]@{ ModId=$id; Name=[string]$mod.Name; Version=[string]$mod.FileId; State=$state; Reason=$reason })
    }
    Assert-RestoreLibraryState $libraryPath $hash
    $manifestHash = Get-Sha256 (Join-Path $snapshot.Root 'manifest.json')
    $tokenText = ConvertTo-Json -Depth 12 -Compress -InputObject ([pscustomobject]@{ Snapshot=$snapshot.Id; Manifest=$manifestHash; Library=$hash; Rows=$rows.ToArray(); Missing=$missing.ToArray(); Records=$recordIds.ToArray() })
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $approval=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($tokenText)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    return [pscustomobject]@{ Status='RestoreReview'; SnapshotId=$snapshot.Id; ManifestHash=$manifestHash; LibraryPath=$libraryPath; LibraryHash=$hash; Approval=$approval; Rows=$rows.ToArray(); Mods=$targets.ToArray(); RecordIds=$recordIds.ToArray(); Files=$missing.ToArray(); ModCount=$targets.Count; RecordCount=$recordIds.Count; FileCount=$missing.Count; CopyBytes=[long](($missing | Measure-Object Length -Sum).Sum); AttentionCount=@($rows | Where-Object {$_.State -ceq 'Needs attention'}).Count }
}
function Commit-ModRestoreLibrary([string]$Pending, [string]$Library) { [ModLocket.JsonPatch]::Commit($Pending,$Library) }
function Copy-RestoreFile([string]$Source, [string]$Target, $Expected, [string]$Library, [string]$Hash) {
    Assert-RestoreLibraryState $Library $Hash
    Assert-NoLinks $Source; Assert-NoLinks $Target
    if (Test-Path -LiteralPath $Target) { throw 'A destination appeared during restore; stopped without overwriting it.' }
    if ((Get-Sha256 $Source) -cne [string]$Expected.Sha256) { throw 'Backup file changed during restore.' }
    [IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
    # Temporary bytes stay outside the installed-mod tree, so an interrupted copy
    # cannot be mistaken for a mod file or prevent an idempotent retry.
    $temp = Join-SafePath $script:RestoreStaging ([guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::Copy($Source,$temp,$false)
    if ((Get-Item -LiteralPath $temp).Length -ne [long]$Expected.Length -or (Get-Sha256 $temp) -cne [string]$Expected.Sha256) { throw 'Staged recovery file failed verification.' }
    Assert-RestoreLibraryState $Library $Hash
    Assert-NoLinks $Target
    [IO.File]::Move($temp,$Target)
}
function Complete-ModRestore($Paths, [string]$Transaction) {
    $j = Read-JsonRoot (Join-SafePath $Transaction 'journal.json')
    if ($j.Kind -cne 'MissingModRestore' -or $j.Schema -ne 1 -or -not (Test-SamePath $j.ArkRoot $Paths.ArkRoot)) { throw 'Invalid mod recovery journal.' }
    $snapshot = Get-RestoreSnapshot $Paths ([string]$j.SnapshotId) ([string]$j.ManifestHash)
    $library = Find-LibraryJson $Paths.UserDataRoot
    if ((Get-RelativeName $Paths.UserDataRoot $library) -cne $snapshot.Manifest.LibraryRelativePath -or -not (Test-SamePath $j.LibraryPath $library)) { throw 'ARK account changed since recovery started.' }
    $before = Join-SafePath $Transaction 'library-before.json'; $after = Join-SafePath $Transaction 'library-after.json'
    if ((Get-Sha256 $before) -cne $j.BeforeHash -or (Get-Sha256 $after) -cne $j.AfterHash) { throw 'Recovery metadata copies were modified.' }
    Initialize-UpdateHelpers
    $saved = Join-SafePath (Join-Path $snapshot.Root 'Metadata') $snapshot.Manifest.LibraryRelativePath
    $expectedAfter = [ModLocket.JsonPatch]::RestoreRecords([IO.File]::ReadAllText($before), [IO.File]::ReadAllText($saved), [string[]]@($j.RecordIds))
    if ($expectedAfter -cne [IO.File]::ReadAllText($after)) { throw 'Recovery metadata does not match the reviewed missing records.' }
    $current = Get-Sha256 $library
    if ($current -cne $j.BeforeHash -and $current -cne $j.AfterHash) { throw 'ARK records changed after interrupted recovery. No records will be overwritten. Recovery needs review.' }
    $seen=@{}; $selectedFiles=New-Object 'Collections.Generic.List[object]'
    foreach ($mod in @($j.Mods)) {
        $id=[string]$mod.ModId
        $match=@($snapshot.Manifest.Mods | Where-Object { [string]$_.ModId -ceq $id -and [string]$_.FileId -ceq [string]$mod.FileId -and [string]$_.FolderName -ceq [string]$mod.FolderName })
        if ($match.Count -ne 1 -or $seen.ContainsKey($id)) { throw 'Invalid recovery mod selection.' }; $seen[$id]=$true
        foreach ($file in @($snapshot.Manifest.Files | Where-Object { ([string]$_.Path).StartsWith([string]$mod.FolderName + '/', [StringComparison]::Ordinal) })) { $selectedFiles.Add($file) }
    }
    if (-not $seen.Count) { throw 'Empty recovery selection.' }
    foreach ($id in @($j.RecordIds)) { if (-not $seen.ContainsKey([string]$id)) { throw 'Unselected record in recovery journal.' } }
    $expected=@{}; foreach ($file in $selectedFiles) { $expected[[string]$file.Path]=$file }
    # Reject concurrent or changed content before resuming any interrupted copy.
    foreach ($mod in $j.Mods) {
        $folder=Join-SafePath $Paths.ModsDir ([string]$mod.FolderName)
        if (Test-Path -LiteralPath $Paths.ModsDir) {
            if (@(Get-ChildItem -LiteralPath $Paths.ModsDir -Force | Where-Object { $_.Name -like ([string]$mod.ModId + '_*') -and $_.Name -cne [string]$mod.FolderName }).Count) { throw 'Another version appeared during recovery.' }
        }
        if (Test-Path -LiteralPath $folder) {
            foreach ($live in @(Get-SafeFiles $folder)) {
                $relative=Get-RelativeName $Paths.ModsDir $live.FullName
                if (-not $expected.ContainsKey($relative) -or $live.Length -ne [long]$expected[$relative].Length -or (Get-Sha256 $live.FullName) -cne [string]$expected[$relative].Sha256) { throw 'Existing recovery target differs; nothing will overwrite it.' }
            }
        }
    }
    $remaining=@($selectedFiles | Where-Object { -not (Test-Path -LiteralPath (Join-SafePath $Paths.ModsDir ([string]$_.Path)) -PathType Leaf) })
    Assert-FreeSpace $Paths.ModsDir ([long](($remaining | Measure-Object Length -Sum).Sum) + 1MB)
    $script:RestoreStaging=Join-SafePath $Transaction 'staging'; [IO.Directory]::CreateDirectory($script:RestoreStaging) | Out-Null
    $done=0
    foreach ($file in $remaining) {
        Write-StageProgress 'Restoring backed-up mod files' $done $remaining.Count
        Copy-RestoreFile (Join-SafePath (Join-Path $snapshot.Root 'Mods') ([string]$file.Path)) (Join-SafePath $Paths.ModsDir ([string]$file.Path)) $file $library $current
        $done++
    }
    foreach ($mod in $j.Mods) {
        $prefix=[string]$mod.FolderName+'/'
        $relativeFiles=@($selectedFiles | Where-Object { ([string]$_.Path).StartsWith($prefix,[StringComparison]::Ordinal) } | ForEach-Object { [pscustomobject]@{Path=([string]$_.Path).Substring($prefix.Length);Length=$_.Length;Sha256=$_.Sha256} })
        Assert-TreeMatches (Join-SafePath $Paths.ModsDir ([string]$mod.FolderName)) $relativeFiles
    }
    Assert-RestoreLibraryState $library $current
    if ($current -cne $j.AfterHash) {
        $pending=Join-SafePath (Split-Path $library -Parent) ('modlocket-restore-'+[guid]::NewGuid().ToString('N')+'.json')
        [IO.File]::Copy($after,$pending,$false)
        Assert-RestoreLibraryState $library $current
        Commit-ModRestoreLibrary $pending $library
    }
    Assert-RestoreLibraryState $library ([string]$j.AfterHash)
    Write-NewJson (Join-SafePath $Transaction 'committed.json') ([pscustomobject]@{ CompletedUtc=[DateTime]::UtcNow.ToString('o') })
}
function Repair-InterruptedRestores($Paths) {
    $root=Join-SafePath $Paths.GuardRoot 'RestoreTransactions'
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory)) {
        if ($dir.Name -cnotmatch '^[0-9a-f]{32}$') { continue }
        $journal=Join-SafePath $dir.FullName 'journal.json'
        if ((Test-Path -LiteralPath $journal) -and -not (Test-Path -LiteralPath (Join-SafePath $dir.FullName 'committed.json'))) {
            Write-Warn 'Completing interrupted backup recovery before continuing.'
            Complete-ModRestore $Paths $dir.FullName
        }
    }
}
function Restore-MissingMods($Paths, [string]$Approval) {
    $review=Get-ModRestoreReview $Paths
    if ($Approval -cnotmatch '^[0-9a-f]{64}$' -or $Approval -cne $review.Approval) { throw 'Recovery selection or local files changed. Review RESTORE MISSING MODS again.' }
    if ($review.ModCount -eq 0) { throw 'No missing backed-up mods can be restored.' }
    Assert-FreeSpace $Paths.ModsDir ($review.CopyBytes+1MB)
    $snapshot=Load-Snapshot $Paths
    $saved=Join-SafePath (Join-Path $snapshot.Root 'Metadata') $snapshot.Manifest.LibraryRelativePath
    $transaction=Join-SafePath $Paths.GuardRoot ('RestoreTransactions/'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($transaction) | Out-Null
    Assert-RestoreLibraryState $review.LibraryPath $review.LibraryHash
    $before=Join-SafePath $transaction 'library-before.json'; [IO.File]::Copy($review.LibraryPath,$before,$false)
    if ((Get-Sha256 $before) -cne $review.LibraryHash) { throw 'Installation records changed while saving recovery state.' }
    $newJson=[ModLocket.JsonPatch]::RestoreRecords([IO.File]::ReadAllText($before),[IO.File]::ReadAllText($saved),[string[]]@($review.RecordIds))
    $after=Join-SafePath $transaction 'library-after.json'
    if ($review.RecordCount -eq 0) { [IO.File]::Copy($before,$after,$false) }
    else { [IO.File]::WriteAllText($after,$newJson,(New-Object Text.UTF8Encoding($false))) }
    # Persist the journal before touching installed files; replay is additive.
    Write-NewJson (Join-SafePath $transaction 'journal.json') ([pscustomobject]@{ Schema=1;Kind='MissingModRestore';ArkRoot=$Paths.ArkRoot;LibraryPath=$review.LibraryPath;BeforeHash=$review.LibraryHash;AfterHash=(Get-Sha256 $after);SnapshotId=$review.SnapshotId;ManifestHash=$review.ManifestHash;Mods=$review.Mods;RecordIds=$review.RecordIds })
    Complete-ModRestore $Paths $transaction
    Write-Good "Restored $($review.ModCount) backed-up mods: $($review.FileCount) files and $($review.RecordCount) missing installation records."
    return [pscustomobject]@{ Status='MissingModsRestored';ModCount=$review.ModCount;FileCount=$review.FileCount;RecordCount=$review.RecordCount;AttentionCount=$review.AttentionCount;RecoveryPath=$transaction;SteamRequested=$false }
}
