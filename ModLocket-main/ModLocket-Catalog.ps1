# Metadata comparison only. These actions cannot approve launch or change installed mods.
. (Join-Path $PSScriptRoot 'ModLocket-CurseForge.ps1')
function Get-ModListState($Paths) {
    $root=Join-SafePath $Paths.GuardRoot 'ModLists'
    Assert-NoLinks $root
    if (-not (Test-Path -LiteralPath $root)) { return [pscustomobject]@{Path='';Hash='none';Mods=@()} }
    $files=@(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -cmatch '^[0-9]{17}-[0-9a-f]{32}\.json$' } | Sort-Object Name -Descending)
    if (-not $files.Count) { return [pscustomobject]@{Path='';Hash='none';Mods=@()} }
    $path=$files[0].FullName; $hash=Get-Sha256 $path; $data=Read-JsonRoot $path
    if ($data.Kind -cne 'ModList' -or $data.SchemaVersion -ne 1 -or $data.GameId -ne 83374 -or
        -not (Test-SamePath $data.ArkRoot $Paths.ArkRoot) -or $data.Mods -isnot [Array]) { throw 'Saved mod-list format or installation identity is invalid.' }
    $seen=@{}
    foreach($mod in $data.Mods) {
        if ($mod.ModId -isnot [string] -or $mod.ModId -cnotmatch '^[1-9][0-9]{4,8}$' -or
            $mod.FileId -isnot [string] -or $mod.FileId -cnotmatch '^[1-9][0-9]{0,19}$' -or
            $mod.Name -isnot [string] -or $seen.ContainsKey($mod.ModId)) { throw 'Saved mod list has invalid or duplicate identities.' }
        $seen[$mod.ModId]=$true
    }
    if ((Get-Sha256 $path) -cne $hash) { throw 'Saved mod list changed during the check.' }
    return [pscustomobject]@{Path=$path;Hash=$hash;Mods=@($data.Mods)}
}
function Get-CatalogInputs($Paths) {
    Assert-ArkClosed
    $backup=Get-BackupPointerState $Paths
    if ($backup.Snapshot) { Assert-SnapshotMetadata $backup.Snapshot }
    $saved=Get-ModListState $Paths
    $library=$null; $libraryHash='missing'; $libraryPath=''
    Assert-NoLinks $Paths.UserDataRoot
    $indexes=if(Test-Path -LiteralPath $Paths.UserDataRoot){@(Get-SafeFiles $Paths.UserDataRoot | Where-Object {$_.Name -ieq 'library.json'})}else{@()}
    if ($indexes.Count -gt 1) { throw 'More than one ARK library was found. Account selection needs review.' }
    if ($indexes.Count -eq 1) {
        $libraryPath=$indexes[0].FullName; $libraryHash=Get-Sha256 $libraryPath
        $library=Get-LibraryData $libraryPath
        if ((Get-Sha256 $libraryPath) -cne $libraryHash) { throw 'ARK library changed during the check.' }
    }
    $tokenText=ConvertTo-Json -Compress -InputObject @($Paths.ArkRoot,$libraryPath,$libraryHash,$backup.Hash,$saved.Hash)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$token=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($tokenText)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    return [pscustomobject]@{Backup=$backup;Saved=$saved;Library=$library;Token=$token}
}
function Get-CatalogRows($Paths,$Inputs) {
    $ids=@{}; $backed=@{}; $saved=@{}
    if($Inputs.Backup.Snapshot){foreach($m in $Inputs.Backup.Snapshot.Manifest.Mods){$ids[[string]$m.ModId]=$true;$backed[[string]$m.ModId]=$m}}
    foreach($m in $Inputs.Saved.Mods){$ids[$m.ModId]=$true;$saved[$m.ModId]=$m}
    if($Inputs.Library){foreach($id in $Inputs.Library.Records.Keys){$ids[$id]=$true}}
    foreach($id in @($ids.Keys | Sort-Object)) {
        $entry=if($Inputs.Library){$Inputs.Library.Records[$id]}else{$null}
        $old=$backed[$id]; $remembered=$saved[$id]
        $name=if($entry){$entry.Name}elseif($remembered){$remembered.Name}else{$old.Name}
        $installed=if($entry){[string]$entry.FileId}else{''}
        $local=if(-not $Inputs.Library){'Library missing; installed state unknown'}elseif(-not $entry){'Absent from local library'}elseif($entry.Issues.Count){'Needs review: '+($entry.Issues -join '; ')}else{'Recorded locally'}
        if($entry -and $entry.Issues.Count -eq 0) {
            try {
                if($entry.Profile -ceq 'ASA' -and -not (Test-RecordedModPath $Paths $entry)){throw 'Unexpected path'}
                $folder=$entry.ModId+'_'+$entry.FileId
                if(-not (Test-Path -LiteralPath (Join-SafePath $Paths.ModsDir $folder) -PathType Container)){$local='Mod folder missing'}
            } catch {$local='Recorded path needs review'}
        }
        $backupFile=if($old){[string]$old.FileId}else{''}
        $savedFile=if($remembered){[string]$remembered.FileId}else{''}
        [pscustomobject]@{
            ModId=[string]$id;Name=[string]$name;InstalledFileId=$installed;BackupFileId=$backupFile;SavedListFileId=$savedFile
            BackupComparison=$(if(-not $old){'Not backed up'}elseif(-not $entry){'Installed identity unknown'}elseif($backupFile -ceq $installed){'Same recorded ID'}else{'Different file ID'})
            SavedListComparison=$(if(-not $remembered){'Not on saved list'}elseif(-not $entry){'Installed identity unknown'}elseif($savedFile -ceq $installed){'Same recorded ID'}else{'Different file ID'})
            LocalState=$local;PublishedFileId='';OnlineState='Not checked';OnlineCheckedUtc=''
        }
    }
}
function Add-CurseForgeComparison([object[]]$Rows,[string]$ApiKey) {
    if(-not $Rows.Count){return [pscustomobject]@{Mode='No known mods';Message='No mod IDs were found in the local library, saved list or selected backup. No online request was made.'}}
    if(-not $ApiKey){return [pscustomobject]@{Mode='Not connected';Message='Local comparison only. Add an approved CurseForge API key for a live check.'}}
    $failures=New-Object 'Collections.Generic.List[string]'; $done=0
    for($offset=0;$offset -lt $Rows.Count;$offset+=50) {
        $batch=@($Rows | Select-Object -Skip $offset -First 50)
        Write-StageProgress 'Checking CurseForge' $done $Rows.Count
        try {
            $response=Invoke-CurseForgeBatch @($batch | ForEach-Object {$_.ModId}) $ApiKey
            if($null -eq $response -or $response.data -isnot [Array]) { throw 'CurseForge returned an unsupported response.' }
            $requested=@{};foreach($row in $batch){$requested[$row.ModId]=$true}
            $mods=@{}
            foreach($mod in $response.data) {
                $id=[string]$mod.id
                if(-not $requested.ContainsKey($id) -or $mods.ContainsKey($id) -or [string]$mod.gameId -cne '83374'){throw 'CurseForge returned mismatched or duplicate project data.'}
                $mods[$id]=$mod
            }
            $checked=[DateTime]::UtcNow.ToString('o')
            foreach($row in $batch) {
                $row.OnlineCheckedUtc=$checked; $mod=$mods[$row.ModId]
                if(-not $mod -or $mod.isAvailable -isnot [bool] -or -not $mod.isAvailable){$row.OnlineState='Unavailable through API';continue}
                $fileId=[string]$mod.mainFileId
                if($fileId -cnotmatch '^[1-9][0-9]{0,9}$'){$row.OnlineState='Published file unknown';continue}
                $row.PublishedFileId=$fileId
                $row.OnlineState=if(-not $row.InstalledFileId){'Installed identity unknown'}elseif($row.InstalledFileId -ceq $fileId){'Matches published main file ID'}else{'Published file differs; review update'}
            }
        } catch {
            # Transport helper uses sanitized errors; never echo HTTP bodies or credentials.
            $failures.Add('One or more requests failed. Online results are unknown for those mods.')
            foreach($row in $batch){$row.OnlineState='Online check failed';$row.PublishedFileId='';$row.OnlineCheckedUtc=''}
            Write-Warn 'CurseForge request failed. Check API access or connectivity; no mod or backup files were changed.'
            # Do not hammer the provider after an auth/rate-limit/network error.
            foreach($row in @($Rows | Select-Object -Skip ($offset+$batch.Count))){$row.OnlineState='Not checked after request failure'}
            break
        }
        $done+=$batch.Count
    }
    Write-StageProgress 'Checking CurseForge' $done $Rows.Count
    $unknown=@($Rows | Where-Object {$_.OnlineState -notin @('Matches published main file ID','Published file differs; review update')}).Count
    return [pscustomobject]@{Mode=$(if($failures.Count -or $unknown){'Partial live check'}else{'Live metadata check'});Message='Published main-file IDs are compared exactly. A different ID needs review; compatible platform, server version, ownership and file integrity are not verified.'}
}
function Get-ModComparison($Paths,[switch]$LocalOnly) {
    $inputs=Get-CatalogInputs $Paths; $rows=@(Get-CatalogRows $Paths $inputs)
    $key=''; $keyProblem=''
    if(-not $LocalOnly){try{$key=Get-CurseForgeKey}catch{$keyProblem='Saved API access could not be opened. Re-enter the key in Check for Updates.'}}
    try{$online=Add-CurseForgeComparison $rows $key}finally{$key=$null}
    if($keyProblem){$online.Message=$keyProblem}
    if((Get-CatalogInputs $Paths).Token -cne $inputs.Token){throw 'Local library or selected lists changed during the check. Run it again.'}
    $attention=@($rows | Where-Object {$_.LocalState -cne 'Recorded locally' -or $_.BackupComparison -eq 'Different file ID' -or $_.SavedListComparison -eq 'Different file ID' -or $_.OnlineState -ne 'Matches published main file ID'}).Count
    $invalid=if($inputs.Library){@($inputs.Library.Entries | Where-Object {$_.ModId -cnotmatch '^[1-9][0-9]{4,8}$' -or $_.FileId -cnotmatch '^[1-9][0-9]{0,19}$' -or ($_.Issues -contains 'Duplicate project ID')}).Count}else{0}
    Write-Info "$($rows.Count) known mods. CurseForge: $($online.Mode)."
    Write-Info $online.Message
    Write-Info 'Saved-list snapshots contain IDs and names only. They cannot restore files offline.'
    return [pscustomobject]@{Status='ModComparison';Rows=$rows;ModCount=$rows.Count;AttentionCount=$attention;OnlineMode=$online.Mode;OnlineMessage=$online.Message;CheckedUtc=[DateTime]::UtcNow.ToString('o');SaveApproval=$inputs.Token;CanSaveList=($rows.Count -gt 0 -and $invalid -eq 0);InvalidIdentityCount=$invalid;IntegrityVerified=$false;SteamRequested=$false}
}
function Save-ModListSnapshot($Paths,[string]$Approval) {
    if($Approval -cnotmatch '^[0-9a-f]{64}$'){throw 'Review the mod comparison before saving the list.'}
    $inputs=Get-CatalogInputs $Paths
    if($inputs.Token -cne $Approval){throw 'The reviewed mod list changed. Run Check for Updates again.'}
    $rows=@(Get-CatalogRows $Paths $inputs)
    if(-not $rows.Count){throw 'There are no known mod IDs to save.'}
    if($inputs.Library -and @($inputs.Library.Entries | Where-Object {$_.ModId -cnotmatch '^[1-9][0-9]{4,8}$' -or $_.FileId -cnotmatch '^[1-9][0-9]{0,19}$' -or ($_.Issues -contains 'Duplicate project ID')}).Count){throw 'Invalid or duplicate local identities must be reviewed before saving.'}
    $mods=@(foreach($row in $rows){
        $id=if($row.InstalledFileId){$row.InstalledFileId}elseif($row.SavedListFileId){$row.SavedListFileId}else{$row.BackupFileId}
        [pscustomobject]@{ModId=$row.ModId;FileId=$id;Name=$row.Name}
    })
    # Append a new tiny record. Prior lists, full snapshots and current-snapshot.json stay intact.
    $root=Join-SafePath $Paths.GuardRoot 'ModLists';Assert-NoLinks $root
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Assert-ArkClosed
    if((Get-CatalogInputs $Paths).Token -cne $Approval){throw 'The reviewed state changed before saving. No list was saved.'}
    $path=Join-SafePath $root ([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')+'-'+[guid]::NewGuid().ToString('N')+'.json')
    # Interrupted writes are not visible as completed lists. Publish on this volume
    # only after the staged file is complete and the reviewed inputs still match.
    $staging=$path+'.pending'
    Write-NewJson $staging ([pscustomobject]@{Kind='ModList';SchemaVersion=1;GameId=83374;ArkRoot=$Paths.ArkRoot;CreatedUtc=[DateTime]::UtcNow.ToString('o');Mods=$mods})
    Assert-ArkClosed
    if((Get-CatalogInputs $Paths).Token -cne $Approval){throw 'The reviewed state changed before publication. No completed list was saved.'}
    Assert-NoLinks $root
    [IO.File]::Move($staging,$path)
    Write-Good "Saved $($mods.Count) mod identities in $((Get-Item -LiteralPath $path).Length) bytes. No mod payloads copied. Previously remembered missing mods stay on the list."
    return [pscustomobject]@{Status='ModListSaved';Path=$path;ModCount=$mods.Count;SteamRequested=$false}
}
