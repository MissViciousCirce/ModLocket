# Explicit Windows-client updates. Never uses guessed CDN paths or premium URLs.
function Initialize-UpdateHelpers {
    if (-not ('ModLocket.JsonPatch' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ModLocket-JsonPatch.cs') }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
function Invoke-CurseForgeGet([string]$Route,[string]$ApiKey) {
    if ($Route -cnotmatch '^mods/[1-9][0-9]{4,8}(?:/files(?:/[1-9][0-9]{0,9}(?:/download-url)?)?)?(?:\?index=[0-9]+&pageSize=50)?$') { throw 'Invalid CurseForge request.' }
    $oldTls=[Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol=$oldTls -bor [Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Uri ('https://api.curseforge.com/v1/'+$Route) -Headers @{'x-api-key'=$ApiKey;Accept='application/json'} -TimeoutSec 30 -MaximumRedirection 0 -ErrorAction Stop
    } catch {
        $code=0;try{$code=[int]$_.Exception.Response.StatusCode}catch{}
        if($code -in @(401,403)){throw 'CurseForge denied file access (401/403). Your key may read project information but lack download access. No installed files were changed.'}
        if($code -eq 429){throw 'CurseForge rate limit reached. Try again later.'}
        throw 'CurseForge file lookup failed. Check connectivity and API permissions.'
    } finally {[Net.ServicePointManager]::SecurityProtocol=$oldTls}
}
function Test-WindowsClientFile($File) {
    # Author-supplied platform labels AND the cooked filename must not conflict.
    $labels=@($File.gameVersions | ForEach-Object {([string]$_).ToLowerInvariant()})
    $name=[string]$File.fileName
    if($File.isServerPack -eq $true -or $name -match '(?i)windows[-_ ]?server|linux|xbox|ps[45]|playstation|gdk' -or @($labels | Where-Object {$_ -match 'server|linux|xbox|playstation|gdk|^ps[45]$'}).Count){return $false}
    return ($labels -contains 'windows' -or $labels -contains 'windowsclient' -or $name -match '(?i)-windows(?:[ ._-]|$)')
}
function Assert-UpdateFile($File,[string]$ModId) {
    if([string]$File.modId -cne $ModId -or [string]$File.gameId -cne '83374' -or [string]$File.id -cnotmatch '^[1-9][0-9]{0,9}$'){throw 'Mismatched download identity.'}
    if($File.isAvailable -isnot [bool] -or -not $File.isAvailable -or $File.fileStatus -notin @(4,10) -or $File.releaseType -ne 1){throw 'File is not an available approved release.'}
    if(-not(Test-WindowsClientFile $File)){throw 'No unambiguous Windows client release was found.'}
    if($File.isEarlyAccessContent -eq $true){throw 'Early-access files must be installed through ARK.'}
    if([string]$File.fileLength -notmatch '^[1-9][0-9]*$' -or [decimal]$File.fileLength -gt 200GB -or [string]$File.fileName -notmatch '(?i)\.zip$'){throw 'Unsupported archive size or format.'}
    $hashes=@($File.hashes | Where-Object {($_.algo -eq 1 -and $_.value -match '^[a-fA-F0-9]{40}$') -or ($_.algo -eq 2 -and $_.value -match '^[a-fA-F0-9]{32}$')})
    if(-not $hashes.Count){throw 'CurseForge supplied no supported archive checksum.'}
    if(-not @($File.modules).Count){throw 'CurseForge supplied no module layout; installation cannot be verified.'}
}
function Get-WindowsUpdateFile([string]$ModId,[string]$ApiKey) {
    $files=New-Object 'Collections.Generic.List[object]'
    for($offset=0;$offset -lt 500;$offset+=50){
        $r=Invoke-CurseForgeGet ('mods/'+$ModId+'/files?index='+$offset+'&pageSize=50') $ApiKey
        if($r.data -isnot [Array] -or $null -eq $r.pagination -or [int]$r.pagination.index -ne $offset){throw 'Unsupported file-list response.'}
        foreach($f in $r.data){if(Test-WindowsClientFile $f){$files.Add($f)}}
        if($offset+$r.data.Count -ge [int]$r.pagination.totalCount){break}
        if($r.data.Count -eq 0){throw 'Incomplete file-list response.'}
    }
    # File IDs increase as files are published. Explicitly refuse downgrades later.
    $candidates=@($files | Where-Object {$_.isAvailable -eq $true -and $_.releaseType -eq 1 -and $_.fileStatus -in @(4,10)} | Sort-Object {[long]$_.id} -Descending)
    if(-not $candidates.Count){throw 'No downloadable Windows client release is exposed by this API key.'}
    $f=$candidates[0];return $f
}
function Get-UpdateInput($Paths) {
    Assert-ArkClosed
    $path=Find-LibraryJson $Paths.UserDataRoot;$hash=Get-Sha256 $path;$lib=Get-LibraryData $path
    if($lib.PropertyName -cne 'installedMods'){throw 'Updates require the ARK installedMods library format.'}
    Initialize-UpdateHelpers
    return [pscustomobject]@{Path=$path;Hash=$hash;Library=$lib}
}
function Get-ModUpdatePlan($Paths) {
    $inputState=Get-UpdateInput $Paths;$key=Get-CurseForgeKey
    if(-not $key){throw 'Add your CurseForge API key in API settings first.'}
    $rows=New-Object 'Collections.Generic.List[object]';$updates=New-Object 'Collections.Generic.List[object]';$done=0
    $projects=@{};$ids=@($inputState.Library.Entries | Where-Object {$_.ModId -cmatch '^[1-9][0-9]{4,8}$'} | ForEach-Object {$_.ModId})
    for($offset=0;$offset -lt $ids.Count;$offset+=50){
        Write-StageProgress 'Checking published projects' $offset $ids.Count
        $batch=@($ids | Select-Object -Skip $offset -First 50)
        $response=Invoke-CurseForgeBatch $batch $key
        if($response.data -isnot [Array]){throw 'Unsupported project response.'}
        foreach($m in $response.data){
            if([string]$m.id -cnotin $batch -or $projects.ContainsKey([string]$m.id) -or [string]$m.gameId -cne '83374'){throw 'Mismatched project response.'}
            $projects[[string]$m.id]=$m
        }
    }
    try {
        foreach($entry in $inputState.Library.Entries){
            Write-StageProgress 'Finding Windows updates' $done $inputState.Library.Entries.Count;$done++
            $reason='';$file=$null;$state='Current'
            try {
                $other=@($entry.Issues | Where-Object {$_ -cne "ARK status: 'OutOfDate'"})
                if($other.Count){throw ($other -join '; ')}
                if(-not(Test-RecordedModPath $Paths $entry)){throw 'ARK recorded an unexpected installed path.'}
                $old=Join-SafePath $Paths.ModsDir ($entry.ModId+'_'+$entry.FileId)
                if(-not(Test-Path -LiteralPath $old -PathType Container)){throw 'Installed folder is missing; repair it in ARK first.'}
                $mod=$projects[$entry.ModId]
                if([string]$mod.id -cne $entry.ModId -or [string]$mod.gameId -cne '83374' -or $mod.isAvailable -ne $true){throw 'Project is unavailable through this key.'}
                if($mod.isPremium -eq $true -or ($mod.premiumDetails -and ($mod.premiumDetails.price -gt 0 -or $mod.premiumDetails.tierPrice -gt 0))){throw 'Premium content must be updated in ARK using your ownership authorization.'}
                $knownWindows=@($mod.latestFiles | Where-Object {(Test-WindowsClientFile $_) -and $_.isAvailable -eq $true -and $_.releaseType -eq 1 -and $_.fileStatus -in @(4,10)} | Sort-Object {[long]$_.id} -Descending)
                if($knownWindows.Count){$file=$knownWindows[0]}
                else{$file=Get-WindowsUpdateFile $entry.ModId $key}
                if([string]$file.modId -cne $entry.ModId -or [string]$file.gameId -cne '83374' -or [string]$file.id -cnotmatch '^[1-9][0-9]{0,9}$'){throw 'Mismatched release identity.'}
                if([decimal]$file.id -lt [decimal]$entry.FileId){throw 'API release is older than the installed file; no downgrade will be attempted.'}
                if([string]$file.id -ceq $entry.FileId){$reason='Installed Windows file matches the available release.'}
                else{
                    if($mod.allowModDistribution -eq $false){$state='Update blocked';throw 'Newer Windows release found, but CurseForge reports third-party distribution disabled. Update this mod in ARK.'}
                    Assert-UpdateFile $file $entry.ModId
                    # Confirm the official endpoint authorizes a URL before offering installation.
                    $downloadUrl=(Invoke-CurseForgeGet ('mods/'+$entry.ModId+'/files/'+$file.id+'/download-url') $key).data
                    if([string]::IsNullOrWhiteSpace([string]$downloadUrl)){throw 'Newer release found, but CurseForge supplied no download URL. Update in ARK or ask CurseForge about access.'}
                    [void](Assert-DownloadUri ([string]$downloadUrl))
                    foreach($dep in @($file.dependencies | Where-Object {$_.relationType -eq 3})){
                        $d=$inputState.Library.Records[[string]$dep.modId]
                        if(-not $d -or $d.LibraryStatus -notin @('Normal','OutOfDate') -or -not(Test-Path -LiteralPath (Join-SafePath $Paths.ModsDir ($d.ModId+'_'+$d.FileId)) -PathType Container)){throw 'A required dependency is missing or incomplete. Install it in ARK first.'}
                    }
                    # Preflight schema patch now, before offering an install.
                    [void][ModLocket.JsonPatch]::Update([IO.File]::ReadAllText($inputState.Path),$entry.ModId,(ConvertTo-Json -Depth 40 -Compress $file),(ConvertTo-Json ('83374/'+$entry.ModId+'_'+$file.id)),(ConvertTo-Json ([DateTime]::UtcNow.ToString('o'))))
                    $state='Update available';$reason='Windows client release; existing version will be retained for recovery.'
                    $updates.Add([pscustomobject]@{ModId=$entry.ModId;Name=$entry.Name;OldFileId=$entry.FileId;File=$file})
                }
            }catch{if($state -ne 'Update blocked'){$state='Needs ARK / unavailable'};$reason=$_.Exception.Message}
            $rows.Add([pscustomobject]@{Name=$entry.Name;ModId=$entry.ModId;Installed=$entry.FileId;Available=$(if($file){[string]$file.id}else{''});State=$state;Reason=$reason})
        }
    } finally {$key=$null}
    if((Get-Sha256 $inputState.Path) -cne $inputState.Hash){throw 'ARK metadata changed during update planning. Check again.'}
    $root=Join-SafePath $Paths.GuardRoot 'UpdatePlans';[IO.Directory]::CreateDirectory($root)|Out-Null
    $id=[guid]::NewGuid().ToString('N');$planPath=Join-SafePath $root ($id+'.json')
    $bytes=[long](($updates | ForEach-Object {$_.File.fileLength} | Measure-Object -Sum).Sum)
    Write-NewJson $planPath ([pscustomobject]@{Kind='WindowsModUpdates';Schema=1;ArkRoot=$Paths.ArkRoot;LibraryPath=$inputState.Path;LibraryHash=$inputState.Hash;CreatedUtc=[DateTime]::UtcNow.ToString('o');Updates=$updates.ToArray()})
    return [pscustomobject]@{Status='UpdatePlan';Id=$id;Approval=(Get-Sha256 $planPath);Rows=$rows.ToArray();UpdateCount=$updates.Count;DownloadBytes=$bytes;AttentionCount=@($rows | Where-Object {$_.State -in @('Needs ARK / unavailable','Update blocked')}).Count;SteamRequested=$false}
}
function Assert-DownloadUri([string]$Url) {
    $uri=$null
    if(-not [uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Host -cnotin @('edge.forgecdn.net','mediafilez.forgecdn.net','media.forgecdn.net') -or $uri.AbsolutePath -notlike '/files/*' -or $uri.Query -or $uri.Fragment){throw 'Download endpoint is not an approved CurseForge file URL.'}
    return $uri
}
function Receive-ModArchive([string]$Url,[string]$Destination,[long]$Length,[string]$ApiKey) {
    $uri=Assert-DownloadUri $Url;Assert-NoLinks $Destination
    $oldTls=[Net.ServicePointManager]::SecurityProtocol
    $response=$null;$output=$null;$inputStream=$null
    try {
        [Net.ServicePointManager]::SecurityProtocol=$oldTls -bor [Net.SecurityProtocolType]::Tls12
        for($redirect=0;$redirect -le 4;$redirect++){
            $request=[Net.HttpWebRequest]::Create($uri);$request.AllowAutoRedirect=$false;$request.Timeout=30000;$request.ReadWriteTimeout=60000
            $request.Headers.Add('x-api-key',$ApiKey);$request.UserAgent='ModLocket/4.0.0-personal.8'
            $response=$request.GetResponse();$code=[int]$response.StatusCode
            if($code -ge 300 -and $code -lt 400){$next=[uri]::new($uri,$response.Headers['Location']);$response.Dispose();$response=$null;$uri=Assert-DownloadUri $next.AbsoluteUri;continue}
            if($code -ne 200){throw 'Unexpected download response.'};break
        }
        if(-not $response -or [int]$response.StatusCode -ne 200){throw 'Too many redirects.'}
        if($response.ContentLength -ge 0 -and $response.ContentLength -ne $Length){throw 'Download length does not match CurseForge metadata.'}
        $inputStream=$response.GetResponseStream();$output=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] 1048576;$total=0L
        while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$read;if($total -gt $Length){throw 'Download exceeds declared size.'};$output.Write($buffer,0,$read);Write-StageProgress 'Downloading update' $total $Length}
        $output.Flush($true);if($total -ne $Length){throw 'Download was incomplete.'}
    }catch{
        $code=0;try{$code=[int]$_.Exception.Response.StatusCode}catch{}
        if($code -in @(401,403)){throw 'CurseForge denied the download (401/403). File-download permission is required; installed mods are unchanged.'}
        throw 'Download failed or was incomplete. Installed mods are unchanged. Check connectivity and download permission.'
    }finally{
        if($output){$output.Dispose()};if($inputStream){$inputStream.Dispose()};if($response){$response.Dispose()};[Net.ServicePointManager]::SecurityProtocol=$oldTls
    }
}
function Expand-VerifiedMod($File,[string]$Archive,[string]$Destination) {
    if((Get-Item -LiteralPath $Archive).Length -ne [long]$File.fileLength){throw 'Archive length mismatch.'}
    foreach($hash in @($File.hashes)){
        $algo=if($hash.algo -eq 1){'SHA1'}elseif($hash.algo -eq 2){'MD5'}else{continue}
        if((Get-FileHash -LiteralPath $Archive -Algorithm $algo).Hash -ine [string]$hash.value){throw 'Archive checksum mismatch. Installed mods are unchanged.'}
    }
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try{
        $seen=@{};$bytes=0L;$files=0
        if($zip.Entries.Count -gt 250000){throw 'Archive has too many entries.'}
        foreach($e in $zip.Entries){
            $name=$e.FullName.TrimEnd('/');if(-not $name){throw 'Empty archive entry.'};[void](Join-SafePath $Destination $name)
            if($seen.ContainsKey($name)){throw 'Archive contains duplicate or case-colliding paths.'};$seen[$name]=$true
            $kind=(([long]$e.ExternalAttributes -shr 16) -band 61440)
            if($kind -notin @(0,32768,16384)){throw 'Archive contains links or unsupported filesystem entries.'}
            $bytes+=$e.Length;if($bytes -gt 400GB){throw 'Archive expanded size exceeds the limit.'}
            if(-not $e.FullName.EndsWith('/')){$files++}
        }
        if(-not $files){throw 'Archive contains no files.'};Assert-FreeSpace $Destination ($bytes+1GB)
        foreach($e in $zip.Entries){
            $dest=Join-SafePath $Destination ($e.FullName.TrimEnd('/'))
            if($e.FullName.EndsWith('/')){[IO.Directory]::CreateDirectory($dest)|Out-Null;continue}
            [IO.Directory]::CreateDirectory((Split-Path $dest -Parent))|Out-Null
            $src=$e.Open();$out=$null
            try{
                $out=[IO.File]::Open($dest,[IO.FileMode]::CreateNew);$buffer=New-Object byte[] 1048576;$written=0L
                while(($read=$src.Read($buffer,0,$buffer.Length)) -gt 0){$written+=$read;if($written -gt $e.Length){throw 'Archive entry exceeds its declared size.'};$out.Write($buffer,0,$read)}
                if($written -ne $e.Length){throw 'Archive entry is truncated.'};$out.Flush($true)
            }finally{if($out){$out.Dispose()};$src.Dispose()}
        }
    }finally{$zip.Dispose()}
    $total=[long]((Get-SafeFiles $Destination | Measure-Object Length -Sum).Sum)
    if($total -ne $bytes){throw 'Extracted size mismatch.'}
    if($File.fileSizeOnDisk -and [long]$File.fileSizeOnDisk -ne $total){throw 'Archive layout/size differs from CurseForge installation metadata.'}
    foreach($module in @($File.modules)){
        $path=Join-SafePath $Destination ([string]$module.name)
        if(-not(Test-Path -LiteralPath $path -PathType Container)){throw 'Archive module layout differs from ARK metadata.'}
    }
    if(-not @(Get-SafeFiles $Destination | Where-Object {$_.Extension -ieq '.pak'}).Count){throw 'No cooked ARK package found in the archive.'}
}
function Get-UpdateTransactions($Paths){
    $root=Join-SafePath $Paths.GuardRoot 'UpdateTransactions'
    if(Test-Path -LiteralPath $root){Assert-NoLinks $root;@(Get-ChildItem -LiteralPath $root -Directory | Where-Object {$_.Name -cmatch '^[0-9a-f]{32}$'})}
}
function Complete-UpdateRecovery($Paths,[string]$Transaction) {
    $journalPath=Join-SafePath $Transaction 'journal.json';$j=Read-JsonRoot $journalPath
    if($j.Kind -cne 'ModUpdateTransaction' -or -not(Test-SamePath $j.ArkRoot $Paths.ArkRoot)){throw 'Invalid update recovery record.'}
    $library=Find-LibraryJson $Paths.UserDataRoot
    if(-not(Test-SamePath $j.LibraryPath $library)){throw 'Update account changed; recovery needs review.'}
    if((Get-Sha256 (Join-SafePath $Transaction 'library-before.json')) -cne $j.BeforeHash -or (Get-Sha256 (Join-SafePath $Transaction 'library-after.json')) -cne $j.AfterHash){throw 'Recovery metadata was modified; no automatic recovery will be attempted.'}
    $current=Get-Sha256 $library
    if($current -cne $j.BeforeHash -and $current -cne $j.AfterHash){throw 'ARK metadata changed after the interrupted update. Recovery needs manual review; no files were overwritten.'}
    Assert-ArkClosed
    foreach($u in $j.Updates){
        if([string]$u.ModId -cnotmatch '^[1-9][0-9]{4,8}$' -or [string]$u.OldFileId -cnotmatch '^[1-9][0-9]{0,19}$' -or [string]$u.NewFileId -cnotmatch '^[1-9][0-9]{0,9}$' -or $u.OldFileId -eq $u.NewFileId){throw 'Invalid update journal identity.'}
        $old=Join-SafePath $Paths.ModsDir ($u.ModId+'_'+$u.OldFileId);$new=Join-SafePath $Paths.ModsDir ($u.ModId+'_'+$u.NewFileId)
        $saved=Join-SafePath $Transaction ('previous/'+$u.ModId+'_'+$u.OldFileId);$staged=Join-SafePath $Transaction ('staged/'+$u.ModId+'_'+$u.NewFileId)
        if($current -ceq $j.AfterHash){
            if(-not(Test-Path -LiteralPath $new -PathType Container)){throw 'Committed update folder missing; recovery needs review.'}
            if(Test-Path -LiteralPath $old){[IO.Directory]::CreateDirectory((Split-Path $saved -Parent))|Out-Null;[IO.Directory]::Move($old,$saved)}
        }else{
            if(-not(Test-Path -LiteralPath $old -PathType Container)){throw 'Original folder missing; recovery needs review.'}
            if(Test-Path -LiteralPath $new){[IO.Directory]::CreateDirectory((Split-Path $staged -Parent))|Out-Null;[IO.Directory]::Move($new,$staged)}
        }
    }
    $marker=if($current -ceq $j.AfterHash){'committed.json'}else{'rolled-back.json'}
    Write-NewJson (Join-SafePath $Transaction $marker) ([pscustomobject]@{CompletedUtc=[DateTime]::UtcNow.ToString('o')})
}
function Repair-InterruptedUpdates($Paths){
    foreach($dir in @(Get-UpdateTransactions $Paths)){
        $journal=Join-SafePath $dir.FullName 'journal.json'
        if((Test-Path -LiteralPath $journal) -and -not(Test-Path -LiteralPath (Join-SafePath $dir.FullName 'committed.json')) -and -not(Test-Path -LiteralPath (Join-SafePath $dir.FullName 'rolled-back.json'))){
            Write-Warn 'Recovering an interrupted mod update before continuing.';Complete-UpdateRecovery $Paths $dir.FullName
        }
    }
}
function Commit-ModUpdateLibrary([string]$Pending,[string]$Library){ [ModLocket.JsonPatch]::Commit($Pending,$Library) }
function Install-ModUpdates($Paths,[string]$PlanId,[string]$Approval){
    if($PlanId -cnotmatch '^[0-9a-f]{32}$' -or $Approval -cnotmatch '^[0-9a-f]{64}$'){throw 'Review the update plan first.'}
    $planPath=Join-SafePath $Paths.GuardRoot ('UpdatePlans/'+$PlanId+'.json')
    if((Get-Sha256 $planPath) -cne $Approval){throw 'Update plan changed. Check again.'}
    $plan=Read-JsonRoot $planPath;$s=Get-UpdateInput $Paths
    if($plan.Kind -cne 'WindowsModUpdates' -or $plan.Schema -ne 1 -or -not(Test-SamePath $plan.ArkRoot $Paths.ArkRoot) -or -not(Test-SamePath $plan.LibraryPath $s.Path) -or $plan.LibraryHash -cne $s.Hash -or ([DateTime]::UtcNow-[DateTime]::Parse($plan.CreatedUtc)).TotalMinutes -gt 30){throw 'Update plan expired or installed state changed. Check again.'}
    if(-not @($plan.Updates).Count){throw 'No updates are selected.'}
    $key=Get-CurseForgeKey;if(-not $key){throw 'API key is missing.'}
    $transaction=Join-SafePath $Paths.GuardRoot ('UpdateTransactions/'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($transaction)|Out-Null
    $raw=[IO.File]::ReadAllText($s.Path);$journalUpdates=New-Object 'Collections.Generic.List[object]';$seen=@{}
    try{
        foreach($u in $plan.Updates){
            if($seen.ContainsKey([string]$u.ModId)){throw 'Duplicate project in update plan.'};$seen[[string]$u.ModId]=$true
            $entry=$s.Library.Records[[string]$u.ModId]
            if(-not $entry -or $entry.FileId -cne [string]$u.OldFileId){throw 'Installed version changed.'}
            $f=(Invoke-CurseForgeGet ('mods/'+$u.ModId+'/files/'+$u.File.id) $key).data;Assert-UpdateFile $f ([string]$u.ModId)
            if([string]$f.id -cne [string]$u.File.id -or [decimal]$f.id -le [decimal]$u.OldFileId -or $f.fileLength -ne $u.File.fileLength -or (ConvertTo-Json -Compress $f.hashes) -cne (ConvertTo-Json -Compress $u.File.hashes)){throw 'Published file changed since review. Check again.'}
            $new=Join-SafePath $Paths.ModsDir ($u.ModId+'_'+$f.id)
            if(Test-Path -LiteralPath $new){throw 'Target version folder already exists; resolve it in ARK first.'}
            $url=(Invoke-CurseForgeGet ('mods/'+$u.ModId+'/files/'+$f.id+'/download-url') $key).data
            [void](Assert-DownloadUri ([string]$url))
            Assert-FreeSpace $transaction ([long]$f.fileLength+[long]$f.fileSizeOnDisk+1GB)
            $archive=Join-SafePath $transaction ($u.ModId+'.zip');$stage=Join-SafePath $transaction ('staged/'+$u.ModId+'_'+$f.id)
            Write-Info ('Downloading '+$u.Name+' ['+$u.ModId+']')
            Receive-ModArchive ([string]$url) $archive ([long]$f.fileLength) $key
            Write-StageProgress 'Verifying and extracting update';Expand-VerifiedMod $f $archive $stage
            $raw=[ModLocket.JsonPatch]::Update($raw,[string]$u.ModId,(ConvertTo-Json -Depth 40 -Compress $f),(ConvertTo-Json ('83374/'+$u.ModId+'_'+$f.id)),(ConvertTo-Json ([DateTime]::UtcNow.ToString('o'))))
            $journalUpdates.Add([pscustomobject]@{ModId=[string]$u.ModId;OldFileId=[string]$u.OldFileId;NewFileId=[string]$f.id})
        }
        Assert-ArkClosed
        if((Get-Sha256 $s.Path) -cne $s.Hash){throw 'ARK metadata changed during download. Nothing was installed.'}
        $before=Join-SafePath $transaction 'library-before.json';[IO.File]::Copy($s.Path,$before,$false)
        $after=Join-SafePath $transaction 'library-after.json';[IO.File]::WriteAllText($after,$raw,(New-Object Text.UTF8Encoding($false)))
        $afterHash=Get-Sha256 $after
        Write-NewJson (Join-SafePath $transaction 'journal.json') ([pscustomobject]@{Kind='ModUpdateTransaction';ArkRoot=$Paths.ArkRoot;LibraryPath=$s.Path;BeforeHash=$s.Hash;AfterHash=$afterHash;Updates=$journalUpdates.ToArray()})
        try{
            foreach($u in $journalUpdates){Assert-ArkClosed;$relative=$u.ModId+'_'+$u.NewFileId;[IO.Directory]::Move((Join-SafePath $transaction ('staged/'+$relative)),(Join-SafePath $Paths.ModsDir $relative))}
            Assert-ArkClosed
            if((Get-Sha256 $s.Path) -cne $s.Hash){throw 'ARK metadata changed at installation. Recovery needs review.'}
            $pending=Join-SafePath (Split-Path $s.Path -Parent) ('modlocket-'+[guid]::NewGuid().ToString('N')+'.json')
            [IO.File]::Copy($after,$pending,$false)
            Commit-ModUpdateLibrary $pending $s.Path
            Complete-UpdateRecovery $Paths $transaction
        }catch{
            $cause=$_.Exception.Message
            try{Repair-InterruptedUpdates $Paths}catch{throw ('Update interrupted; recovery stopped: '+$_.Exception.Message)}
            throw ('Update interrupted: '+$cause)
        }
        Write-Good ('Installed '+$journalUpdates.Count+' Windows mod updates. Previous versions retained at: '+$transaction)
        Write-Info 'Create a fresh backup before protected launch. Existing snapshots still contain the previous versions.'
        return [pscustomobject]@{Status='UpdatesInstalled';UpdatedCount=$journalUpdates.Count;RecoveryPath=$transaction;SteamRequested=$false;NeedsBackup=$true}
    }finally{$key=$null}
}
