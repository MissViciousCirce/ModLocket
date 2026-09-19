# ModLocket safety checkpoint. Windows PowerShell 5.1-compatible source.
# No entry-point execution when dot-sourced with -LibraryOnly by the fixture tests.
[CmdletBinding()]
param(
    [ValidateSet('Inspect','PlanBackup','ManageBackups','RemoveSnapshot','SelectSnapshot','CleanRepairStaging','PlanSetup','PlanRefresh','Setup','QuickLaunch','Launch','Inventory','Updates','SaveModList','Refresh','FullRestore')]
    [string]$Action = 'Inspect',
    [string]$ArkRoot,
    [switch]$Yes,
    [switch]$LibraryOnly,
    [switch]$DeferSteamLaunch,
    [string]$BackupApproval,
    [string]$TargetId,
    [string]$ManagementApproval
)
$ErrorActionPreference = 'Stop'
$ScriptVersion = '4.0.0-online.4'
$GameId = 83374
$SteamAppId = 2399830

function Write-Info([string]$Text) { Write-Host "[i] $Text" }
function Write-Good([string]$Text) { Write-Host "[OK] $Text" }
function Write-Warn([string]$Text) { Write-Host "[!] $Text" }
function Write-StageProgress([string]$Stage, [long]$Completed = 0, [long]$Total = 0) {
    $percent = if ($Total -gt 0) { [int][Math]::Floor(100.0 * [Math]::Min($Completed, $Total) / $Total) } else { -1 }
    $key = "$Stage|$percent"
    if ($script:LastProgressKey -ceq $key) { return }
    $script:LastProgressKey = $key
    Write-Host ('__MODLOCKET_PROGRESS__=' + (ConvertTo-Json -Compress -InputObject ([pscustomobject]@{
        Stage = $Stage; Percent = $percent; Completed = $Completed; Total = $Total
    })))
}

function Get-NormalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is not allowed.' }
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}
function Test-SamePath([string]$Left, [string]$Right) {
    return (Get-NormalPath $Left).Equals((Get-NormalPath $Right), [StringComparison]::OrdinalIgnoreCase)
}
function Assert-NoLinks([string]$Path) {
    # Check every existing ancestor, before descending into or creating a path.
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        # Same ancestor checks using direct filesystem calls. No caching:
        # every invocation observes the attributes again. Permission/I/O
        # errors still fail closed; only genuinely absent paths are skipped.
        $attributes = $null
        try { $attributes = [IO.File]::GetAttributes($cursor) }
        catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
        if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Linked folders/files are not supported in this preview: $cursor"
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Join-SafePath([string]$Root, [string]$Relative) {
    # Apply Windows path rules even when fixture tests run on Linux.
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '^[\\/]' -or $Relative -match '[:*?"<>|\x00-\x1f]') {
        throw "Unsafe relative path: $Relative"
    }
    $parts = @($Relative -split '[\\/]')
    foreach ($part in $parts) {
        if (-not $part -or $part -in @('.', '..') -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Unsafe relative path: $Relative"
        }
    }
    $base = Get-NormalPath $Root
    $full = [IO.Path]::GetFullPath((Join-Path $base ($parts -join [IO.Path]::DirectorySeparatorChar)))
    if (-not $full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The requested path escapes its allowed directory.'
    }
    Assert-NoLinks $full
    return $full
}
function Get-RelativeName([string]$Root, [string]$Path) {
    $prefix = (Get-NormalPath $Root) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Path is outside the expected root.' }
    $relative = $full.Substring($prefix.Length).Replace('\', '/')
    [void](Join-SafePath $Root $relative)
    return $relative
}
function Get-SafeFiles([string]$Root) {
    Assert-NoLinks $Root
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Directory is missing: $Root" }
    $queue = New-Object 'Collections.Generic.Queue[string]'
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $queue.Dequeue() -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked content is not supported: $($item.FullName)" }
            [void](Get-RelativeName $Root $item.FullName)
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) } else { $item }
        }
    }
}
function Get-Paths([string]$Root) {
    $rootFull = Get-NormalPath $Root
    Assert-NoLinks $rootFull
    $cf = Join-Path $rootFull 'ShooterGame/Binaries/Win64/ShooterGame'
    # Deliberately separate from all existing ARK_ModGuard / ModNest / ModLocket backups.
    $guard = Join-Path $cf 'ModLocketSafetyPreview'
    [pscustomobject]@{
        ArkRoot = $rootFull; CfRoot = $cf
        ModsDir = Join-Path $cf 'Mods/83374'; UserDataRoot = Join-Path $cf 'ModsUserData'
        GuardRoot = $guard; SnapshotsRoot = Join-Path $guard 'Snapshots'
        Pointer = Join-Path $guard 'current-snapshot.json'
        Lock = Join-Path $cf 'ModLocket.operation.lock'
        InventoryCsv = Join-Path $guard 'ARK_Mods_Installed.csv'
        InventoryTxt = Join-Path $guard 'ARK_Mods_Installed.txt'
    }
}
function Assert-ArkClosed {
    $running = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -match 'ArkAscended|ShooterGame' })
    if ($running.Count -gt 0) { throw 'Close ARK completely before continuing. Do not start it during a check or backup.' }
}
function Enter-OperationLock($Paths) {
    Assert-NoLinks $Paths.Lock
    [IO.Directory]::CreateDirectory($Paths.CfRoot) | Out-Null
    try { return [IO.File]::Open($Paths.Lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another ModLocket operation is active, or its lock cannot be opened. Close other instances and check folder permissions.' }
}
function Confirm-Action([string]$Prompt) {
    if ($Yes) { return $true }
    return (Read-Host "$Prompt [y/N]") -match '^(y|yes)$'
}
function Get-Sha256([string]$Path) {
    Assert-NoLinks $Path
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}
function Read-JsonRoot([string]$Path) {
    Assert-NoLinks $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file is missing: $Path" }
    try {
        # A wrapper preserves zero/one/many root arrays on Windows PowerShell 5.1.
        $wrapped = ConvertFrom-Json -InputObject ('{"value":' + [IO.File]::ReadAllText($Path) + '}') -ErrorAction Stop
        if ($null -eq $wrapped.value) { throw 'Null JSON root.' }
        return ,$wrapped.value
    } catch { throw "Unreadable JSON; no automatic rewrite will be attempted: $Path" }
}
function Write-NewJson([string]$Path, $Value) {
    Assert-NoLinks $Path
    $json = ConvertTo-Json -InputObject $Value -Depth 40
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Find-LibraryJson([string]$Root) {
    $files = @(Get-SafeFiles $Root | Where-Object { $_.Name -ieq 'library.json' })
    if ($files.Count -ne 1) { throw "Expected exactly one library.json, found $($files.Count). Account selection needs review; nothing will be guessed." }
    return $files[0].FullName
}
function Read-LibraryRoot([string]$Path) {
    Assert-NoLinks $Path
    # Validate the original JSON first. Never serialize this parsed object back
    # to ARK. PS 5.1 converts sufficiently large integers to Double.
    [void](Read-JsonRoot $Path)
    $raw = [IO.File]::ReadAllText($Path)
    # JSON strings are consumed whole, so numeric-looking names/paths are left
    # intact. Quote numeric tokens only in this in-memory read-only projection.
    $pattern = '"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
    $exact = [regex]::Replace($raw, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m)
        if ($m.Value.StartsWith('"')) { return $m.Value }
        return '"' + $m.Value + '"'
    })
    $wrapped = ConvertFrom-Json -InputObject ('{"value":' + $exact + '}') -ErrorAction Stop
    return ,$wrapped.value
}
function Get-LibraryData([string]$Path) {
    $root = Read-LibraryRoot $Path
    $kind = 'RootArray'; $propertyName = $null
    if ($root -is [Array]) { $records = @($root) }
    elseif ($root -is [pscustomobject]) {
        # Explicit read-only profiles, NOT heuristic discovery of arbitrary arrays.
        $candidates = @($root.PSObject.Properties | Where-Object { $_.Name -cin @('mods','installedMods') })
        if ($candidates.Count -ne 1 -or $candidates[0].Value -isnot [Array]) {
            throw 'Unsupported library format. This preview does not modify ARK library metadata.'
        }
        $kind = 'PropertyArray'; $propertyName = $candidates[0].Name
        $records = @($candidates[0].Value)
    } else { throw 'Unsupported library JSON root.' }
    $byId = @{}
    $entries = New-Object 'Collections.Generic.List[object]'
    $position = 0
    foreach ($record in $records) {
        $position++
        $issues = New-Object 'Collections.Generic.List[string]'
        $id = ''; $fileId = ''; $name = "Unknown entry $position"; $status = ''; $diskPath = ''; $profile = 'Flat'
        if ($record -isnot [pscustomobject]) { $issues.Add('Malformed library entry') }
        elseif ($propertyName -ceq 'installedMods') {
            $profile = 'ASA'
            $id = [string]$record.details.id; $fileId = [string]$record.installedFile.id
            if ($record.details.name -is [string] -and $record.details.name) { $name = $record.details.name }
            $status = [string]$record.status; $diskPath = [string]$record.pathOnDisk
            if ($record.details -isnot [pscustomobject] -or $record.installedFile -isnot [pscustomobject]) { $issues.Add('Missing nested mod or installed-file details') }
            if ($status -cne 'Normal') { $issues.Add("ARK status: '$status'") }
            if ([string]::IsNullOrWhiteSpace($diskPath)) { $issues.Add('No installed path recorded by ARK') }
            if ($record.unmanaged -isnot [bool] -or $record.unmanaged) { $issues.Add('Unmanaged or unknown management state') }
            if ([string]$record.details.gameId -cne '83374' -or [string]$record.installedFile.gameId -cne '83374') { $issues.Add('Missing or mismatched game identity') }
            if ([string]$record.installedFile.modId -cne $id) { $issues.Add('Installed file belongs to a different or unknown project') }
            # enabled is a load preference, not an integrity/ownership signal.
            # latestUpdatedFile is cached availability, never the installed ID.
        } else {
            $ids = @($record.PSObject.Properties | Where-Object { $_.Name -cin @('modId','projectId','id') })
            $versions = @($record.PSObject.Properties | Where-Object { $_.Name -cin @('installedFileId','fileId','modFileId') })
            if ($ids.Count -eq 1) { $id = [string]$ids[0].Value } else { $issues.Add('Ambiguous mod identity') }
            if ($versions.Count -eq 1) { $fileId = [string]$versions[0].Value } else { $issues.Add('Missing or ambiguous installed-file identity') }
            if ($record.name -is [string] -and $record.name) { $name = $record.name } elseif ($id) { $name = "Mod $id" }
            foreach ($prop in @($record.PSObject.Properties | Where-Object { $_.Name -cin @('status','state') })) {
                $status = [string]$prop.Value
                if ($status -cnotin @('valid','installed','ready','success')) { $issues.Add("Unverified status: '$status'") }
            }
        }
        if ($id -cnotmatch '^[1-9][0-9]{4,8}$') { $issues.Add('Unverified project ID') }
        if ($fileId -cnotmatch '^[1-9][0-9]{0,19}$') { $issues.Add('Unverified installed-file ID; decimal/exponent values are not guessed') }
        $entry = [pscustomobject]@{ ModId = $id; FileId = $fileId; Name = $name; LibraryStatus = $status; Profile = $profile; DiskPath = $diskPath; Issues = $issues }
        $entries.Add($entry)
        if ($id -cmatch '^[1-9][0-9]{4,8}$') {
            if ($byId.ContainsKey($id)) {
                $issues.Add('Duplicate project ID'); $byId[$id].Issues.Add('Duplicate project ID')
            } else { $byId[$id] = $entry }
        }
    }
    return [pscustomobject]@{ Path = $Path; Root = $root; Kind = $kind; PropertyName = $propertyName; Records = $byId; Entries = $entries.ToArray() }
}
function Assert-LibraryVerified($Library) {
    $bad = @($Library.Entries | Where-Object { $_.Issues.Count -gt 0 })
    if ($bad.Count) {
        foreach ($entry in $bad) { Write-Warn "$($entry.Name) [$($entry.ModId)]: $($entry.Issues -join '; ')" }
        throw "$($bad.Count) of $($Library.Entries.Count) library entries need attention. No ready result is permitted."
    }
}
function Test-RecordedModPath($Paths, $Entry) {
    $folder = $Entry.ModId + '_' + $Entry.FileId
    $expected = Join-SafePath $Paths.ModsDir $folder
    $recorded = [string]$Entry.DiskPath
    # Observed ASA pathOnDisk is relative to the parent Mods directory, not
    # to the process working directory. Accept only this exact bounded shape.
    if ($recorded -cmatch '^83374[\\/]([1-9][0-9]{4,8}_[1-9][0-9]{0,19})$') {
        return $Matches[1] -ceq $folder
    }
    if (-not [IO.Path]::IsPathRooted($recorded)) { return $false }
    return Test-SamePath $recorded $expected
}
function Test-EmptyModTemp($Item) {
    # Only the exact top-level .temp directory has been observed. Do not ignore
    # its contents, a file with this name, or linked/reparse-point storage.
    if ($Item.Name -cne '.temp') { return $false }
    Assert-NoLinks $Item.FullName
    if (-not $Item.PSIsContainer) { return $false }
    return @(Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction Stop).Count -eq 0
}
function Get-LiveCatalog($Paths) {
    Write-StageProgress 'Reading mod library'
    Assert-ArkClosed
    $libraryPath = Find-LibraryJson $Paths.UserDataRoot
    $libraryHash = Get-Sha256 $libraryPath
    $library = Get-LibraryData $libraryPath
    Assert-LibraryVerified $library
    if ($library.Records.Count -eq 0) { throw 'The mod library is empty. No ready result or replacement backup will be created.' }
    if (-not (Test-Path -LiteralPath $Paths.ModsDir -PathType Container)) { throw 'The installed mod directory is missing.' }
    [void]@(Get-SafeFiles $Paths.ModsDir)
    $folders = @{}
    $topFolders = @(Get-ChildItem -LiteralPath $Paths.ModsDir -Force)
    $folderCount = 0
    foreach ($folder in $topFolders) {
        Write-StageProgress 'Checking mod folders' $folderCount $topFolders.Count
        $folderCount++
        if (Test-EmptyModTemp $folder) { continue }
        if (-not $folder.PSIsContainer -or $folder.Name -notmatch '^([1-9]\d{4,8})_([1-9]\d{0,19})$') {
            throw "Unrecognized mod-folder layout: $($folder.Name). Stopping rather than guessing its version."
        }
        $id = $Matches[1]; $fileId = $Matches[2]
        if (-not $library.Records.ContainsKey($id) -or $library.Records[$id].FileId -ne $fileId -or $folders.ContainsKey($id)) {
            throw "Mod folder and library versions disagree, or multiple versions exist for ID $id. Resolve this in ARK before continuing."
        }
        $folders[$id] = $folder.Name
    }
    $entryCount = 0
    foreach ($entry in $library.Entries) {
        Write-StageProgress 'Checking saved paths' $entryCount $library.Entries.Count
        $entryCount++
        if ($entry.Profile -eq 'ASA') {
            if (-not (Test-RecordedModPath $Paths $entry)) {
                throw "$($entry.Name) [$($entry.ModId)]: ARK's recorded path does not match the expected project/version folder."
            }
        }
    }
    if ((Get-Sha256 $libraryPath) -ne $libraryHash) { throw 'The mod index changed while it was being read. No action is safe yet.' }
    return [pscustomobject]@{ Library = $library; LibraryHash = $libraryHash; Folders = $folders }
}
function Get-TreeManifest([string]$Root) {
    $entries = New-Object 'Collections.Generic.List[object]'
    Write-StageProgress 'Listing source files'
    $sourceFiles = @(Get-SafeFiles $Root | Sort-Object FullName)
    $total = [long](($sourceFiles | Measure-Object Length -Sum).Sum)
    $done = 0L
    Write-StageProgress 'Hashing source' $done $total
    foreach ($file in $sourceFiles) {
        Assert-ArkClosed
        $entries.Add([pscustomobject]@{
            Path = Get-RelativeName $Root $file.FullName
            Length = [long]$file.Length; Sha256 = Get-Sha256 $file.FullName
        })
        $done += $file.Length
        Write-StageProgress 'Hashing source' $done $total
    }
    return $entries.ToArray()
}
function Assert-TreeMatches([string]$Root, [object[]]$Files) {
    Write-StageProgress 'Listing files for verification'
    $actualFiles = @(Get-SafeFiles $Root)
    if ($actualFiles.Count -ne $Files.Count) { throw "File count differs from the protected snapshot: $Root" }
    $stage = if ($Root -match '[\\/]Snapshots[\\/]') { 'Verifying backup' } else { 'Verifying installed files' }
    $total = [long](($Files | Measure-Object Length -Sum).Sum); $done = 0L
    Write-StageProgress $stage $done $total
    foreach ($expected in $Files) {
        Assert-ArkClosed
        $path = Join-SafePath $Root ([string]$expected.Path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-Item -LiteralPath $path).Length -ne [long]$expected.Length -or
            (Get-Sha256 $path) -ne [string]$expected.Sha256) {
            throw "Content verification failed: $($expected.Path)"
        }
        $done += [long]$expected.Length
        Write-StageProgress $stage $done $total
    }
}
function Assert-FreeSpace([string]$Destination, [long]$RequiredBytes) {
    Assert-NoLinks $Destination
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destination)))
    if (-not $drive.IsReady -or $drive.AvailableFreeSpace -lt ($RequiredBytes + 1GB)) {
        throw 'Not enough free space for a separate backup plus a 1 GB safety margin. Existing snapshots were not changed.'
    }
}
function Invoke-Robocopy([string]$Source, [string]$Destination) {
    Write-StageProgress 'Copying backup (Windows)'
    $sourceFull = (Get-NormalPath $Source) + [IO.Path]::DirectorySeparatorChar
    $destinationFull = (Get-NormalPath $Destination) + [IO.Path]::DirectorySeparatorChar
    if ($sourceFull.StartsWith($destinationFull, [StringComparison]::OrdinalIgnoreCase) -or
        $destinationFull.StartsWith($sourceFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'Overlapping source and destination are forbidden.' }
    [void]@(Get-SafeFiles $Source)
    Assert-NoLinks $Destination
    if (Test-Path -LiteralPath $Destination) { throw 'Backup staging destination must be new.' }
    Assert-ArkClosed
    # Never mirror or purge. Only a fresh staging directory is a permitted destination.
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NP | Out-Host
    if ($LASTEXITCODE -ge 8) { throw "Backup copy failed (Robocopy $LASTEXITCODE). Previous backups are unchanged." }
    Assert-ArkClosed
    [void]@(Get-SafeFiles $Destination)
}
function Assert-Manifest($Paths, $Manifest, [string]$Id) {
    Write-StageProgress 'Validating snapshot'
    if ($Manifest -isnot [pscustomobject] -or $Manifest.SchemaVersion -ne 2 -or
        $Manifest.GameId -ne 83374 -or $Manifest.SnapshotId -cne $Id -or
        -not (Test-SamePath ([string]$Manifest.ArkRoot) $Paths.ArkRoot) -or
        $Manifest.Mods -isnot [Array] -or $Manifest.Mods.Count -eq 0 -or
        $Manifest.Files -isnot [Array] -or $Manifest.Files.Count -eq 0) { throw 'Invalid or incompatible snapshot manifest.' }
    $snapshotRoot = Join-SafePath $Paths.SnapshotsRoot $Id
    [void](Join-SafePath (Join-Path $snapshotRoot 'Metadata') ([string]$Manifest.LibraryRelativePath))
    if ([string]$Manifest.LibrarySha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid library checksum in manifest.' }
    $mods = @{}; $seenFiles = @{}; $fileCounts = @{}
    foreach ($mod in $Manifest.Mods) {
        if ([string]$mod.ModId -notmatch '^[1-9]\d{4,8}$' -or [string]$mod.FileId -notmatch '^[1-9]\d{0,19}$' -or
            $mod.FolderName -cne "$($mod.ModId)_$($mod.FileId)" -or $mods.ContainsKey([string]$mod.ModId)) { throw 'Invalid or duplicate manifest mod.' }
        $mods[[string]$mod.ModId] = $mod; $fileCounts[[string]$mod.FolderName] = 0
    }
    $manifestCount = 0
    foreach ($file in $Manifest.Files) {
        Write-StageProgress 'Validating snapshot' $manifestCount $Manifest.Files.Count
        $manifestCount++
        [void](Join-SafePath (Join-Path $snapshotRoot 'Mods') ([string]$file.Path))
        if ([string]$file.Path -notmatch '^([^/]+)/.+' -or -not $fileCounts.ContainsKey($Matches[1])) { throw 'A manifest file does not belong to a protected mod.' }
        $folderName = $Matches[1]
        if ([string]$file.Length -notmatch '^\d{1,18}$' -or [string]$file.Sha256 -cnotmatch '^[0-9a-f]{64}$' -or $seenFiles.ContainsKey([string]$file.Path)) { throw 'Invalid or duplicate file entry in manifest.' }
        $seenFiles[[string]$file.Path] = $true; $fileCounts[$folderName]++
    }
    foreach ($count in $fileCounts.Values) { if ($count -eq 0) { throw 'Snapshot contains a mod with no files.' } }
}
function Load-Snapshot($Paths) {
    Write-StageProgress 'Reading saved snapshot'
    $pointer = Read-JsonRoot $Paths.Pointer
    if ($pointer -isnot [pscustomobject] -or $pointer.SchemaVersion -ne 1 -or
        [string]$pointer.Current -cnotmatch '^[0-9a-f]{32}$' -or [string]$pointer.ManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid snapshot pointer. Existing snapshots have been left untouched.' }
    $root = Join-SafePath $Paths.SnapshotsRoot ([string]$pointer.Current)
    $manifestPath = Join-SafePath $root 'manifest.json'
    if ((Get-Sha256 $manifestPath) -ne $pointer.ManifestSha256) { throw 'The active snapshot manifest failed its checksum.' }
    $manifest = Read-JsonRoot $manifestPath
    Assert-Manifest $Paths $manifest $pointer.Current
    return [pscustomobject]@{ Id = $pointer.Current; Root = $root; Manifest = $manifest; Pointer = $pointer }
}
function Assert-SnapshotContent($Snapshot) {
    Assert-TreeMatches (Join-Path $Snapshot.Root 'Mods') $Snapshot.Manifest.Files
    Assert-SnapshotMetadata $Snapshot
}
function Assert-SnapshotMetadata($Snapshot) {
    Write-StageProgress 'Checking backup metadata'
    $indexPath = Join-SafePath (Join-Path $Snapshot.Root 'Metadata') $Snapshot.Manifest.LibraryRelativePath
    if ((Get-Sha256 $indexPath) -ne $Snapshot.Manifest.LibrarySha256) { throw 'Backup library metadata failed its checksum.' }
    $library = Get-LibraryData $indexPath
    Assert-LibraryVerified $library
    if ($library.Records.Count -ne $Snapshot.Manifest.Mods.Count) { throw 'Backup library and manifest counts disagree.' }
    foreach ($mod in $Snapshot.Manifest.Mods) {
        if (-not $library.Records.ContainsKey([string]$mod.ModId) -or $library.Records[[string]$mod.ModId].FileId -ne $mod.FileId) { throw 'Backup metadata and manifest versions disagree.' }
    }
}
function Commit-SnapshotPointer($Paths, $Snapshot) {
    Assert-ArkClosed
    Assert-NoLinks $Paths.Pointer
    $prior = if (Test-Path -LiteralPath $Paths.Pointer) { (Load-Snapshot $Paths).Id } else { $null }
    $pointer = [pscustomobject]@{ SchemaVersion = 1; Current = $Snapshot.Id; Previous = $prior; ManifestSha256 = Get-Sha256 (Join-Path $Snapshot.Root 'manifest.json') }
    $temp = Join-SafePath $Paths.GuardRoot ('pointer-' + [guid]::NewGuid().ToString('N') + '.tmp')
    Write-NewJson $temp $pointer
    Assert-ArkClosed
    if (Test-Path -LiteralPath $Paths.Pointer) {
        $recovery = Join-SafePath $Paths.GuardRoot ('pointer-recovery-' + [guid]::NewGuid().ToString('N') + '.json')
        # Same-volume replacement; no delete-then-move fallback on unsupported filesystems.
        [IO.File]::Replace($temp, $Paths.Pointer, $recovery)
    } else { [IO.File]::Move($temp, $Paths.Pointer) }
}
function Get-BackupReview($Paths, [bool]$Refresh) {
    Assert-ArkClosed
    $prior = $null
    $pointerHash = 'none'
    if (Test-Path -LiteralPath $Paths.Pointer) {
        if (-not $Refresh) { throw 'Setup already exists. Use Update Backup.' }
        $pointerHash = Get-Sha256 $Paths.Pointer
        $prior = Load-Snapshot $Paths
    } elseif ($Refresh) { throw 'No safety snapshot exists yet. Use Create Backup.' }
    $catalog = Get-LiveCatalog $Paths
    foreach ($id in $catalog.Library.Records.Keys) {
        if (-not $catalog.Folders.ContainsKey($id)) { throw "Mod $id is indexed but its installed folder is missing. Backup review stopped." }
    }
    $changes = New-Object 'Collections.Generic.List[object]'
    $old = @{}
    if ($prior) { foreach ($mod in $prior.Manifest.Mods) { $old[[string]$mod.ModId] = $mod } }
    foreach ($id in @($old.Keys | Sort-Object)) {
        $current = $catalog.Library.Records[$id]
        if ($null -eq $current) {
            $changes.Add([pscustomobject]@{ Kind='Removed'; ModId=$id; Name=$old[$id].Name; Before=$old[$id].FileId; After='' })
        } elseif ($old[$id].FileId -cne $current.FileId) {
            $changes.Add([pscustomobject]@{ Kind='Version changed'; ModId=$id; Name=$current.Name; Before=$old[$id].FileId; After=$current.FileId })
        }
    }
    foreach ($id in @($catalog.Library.Records.Keys | Sort-Object)) {
        if (-not $old.ContainsKey($id)) {
            $entry = $catalog.Library.Records[$id]
            $changes.Add([pscustomobject]@{ Kind='Added'; ModId=$id; Name=$entry.Name; Before=''; After=$entry.FileId })
        }
    }
    $layout = @(Get-SafeFiles $Paths.ModsDir | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{ Path=Get-RelativeName $Paths.ModsDir $_.FullName; Length=[long]$_.Length }
    })
    if (-not $layout.Count) { throw 'There are no installed files to back up.' }
    $bytes = [long](($layout | Measure-Object Length -Sum).Sum) + (Get-Item -LiteralPath $catalog.Library.Path).Length
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Paths.GuardRoot)))
    if (-not $drive.IsReady) { throw 'The backup drive is not ready.' }
    $available = [long]$drive.AvailableFreeSpace
    $actionName = if ($Refresh) { 'Refresh' } else { 'Setup' }
    # Bind the reviewed list, selected baseline and file sizes to this installation.
    # This is a stale-review check, not an account/security authorization token.
    $state = [ordered]@{ Action=$actionName; Root=$Paths.ArkRoot; Library=$catalog.LibraryHash; Pointer=$pointerHash; Files=$layout }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $token = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $state -Depth 6 -Compress))))).Replace('-','').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    Assert-ArkClosed
    if ((Get-Sha256 $catalog.Library.Path) -cne $catalog.LibraryHash) { throw 'The library changed during review. Review again.' }
    if ($prior) {
        if ((Get-Sha256 $Paths.Pointer) -cne $pointerHash) { throw 'The selected backup changed during review. Review again.' }
    } elseif (Test-Path -LiteralPath $Paths.Pointer) { throw 'A backup was selected during review. Review again.' }
    return [pscustomobject]@{
        Status='BackupReview'; Action=$actionName; Approval=$token; Changes=$changes.ToArray()
        ModCount=$catalog.Library.Records.Count; FileCount=$layout.Count; CopyBytes=$bytes
        RequiredBytes=($bytes + 1GB); AvailableBytes=$available; EnoughSpace=($available -ge ($bytes + 1GB))
        Destination=$Paths.SnapshotsRoot; LibraryHash=$catalog.LibraryHash; PointerHash=$pointerHash
    }
}
function Save-Snapshot($Paths, [bool]$Refresh) {
    Assert-ArkClosed
    $review = Get-BackupReview $Paths $Refresh
    if ($BackupApproval) {
        if ($BackupApproval -cnotmatch '^[0-9a-f]{64}$' -or $BackupApproval -cne $review.Approval) {
            throw 'The mod list, files, or selected backup changed after review. Review again before saving. No new backup was started.'
        }
    } elseif ($Refresh -and $review.Changes.Count -gt 0) {
        throw 'Review the additions, removals, and version changes before updating protection. Use the app Update Backup review; -Yes alone cannot accept list changes.'
    }
    # Fail before hashing a large collection; recheck with actual sizes before copy.
    Assert-FreeSpace $Paths.GuardRoot $review.CopyBytes
    $prior = $null
    if (Test-Path -LiteralPath $Paths.Pointer) {
        if (-not $Refresh) { throw 'Setup already exists. Use Update Backup to create another snapshot.' }
        $prior = Load-Snapshot $Paths
    } elseif ($Refresh) { throw 'No safety snapshot exists yet. Use Create Backup; legacy backups will not be overwritten.' }
    $catalog = Get-LiveCatalog $Paths
    if ($catalog.LibraryHash -cne $review.LibraryHash -or
        ($prior -and (Get-Sha256 $Paths.Pointer) -cne $review.PointerHash)) {
        throw 'The library or selected backup changed after review. No new backup was started.'
    }
    foreach ($id in $catalog.Library.Records.Keys) {
        if (-not $catalog.Folders.ContainsKey($id)) { throw "$($catalog.Library.Records[$id].Name) [$id] has an index entry but no installed folder. No replacement backup was created." }
    }
    if ($prior) {
        $old = @{}; foreach ($mod in $prior.Manifest.Mods) { $old[[string]$mod.ModId] = [string]$mod.FileId }
        foreach ($id in @($old.Keys | Sort-Object)) {
            if (-not $catalog.Library.Records.ContainsKey($id)) { Write-Warn "REMOVED from new protection list: $id" }
            elseif ($old[$id] -ne $catalog.Library.Records[$id].FileId) { Write-Info "VERSION CHANGE: $id ($($old[$id]) -> $($catalog.Library.Records[$id].FileId))" }
        }
        foreach ($id in @($catalog.Library.Records.Keys | Sort-Object)) { if (-not $old.ContainsKey($id)) { Write-Info "ADDED to protection list: $id" } }
    }
    if (-not (Confirm-Action 'Save the current installed collection as a NEW snapshot? Previous backups will be retained.')) { throw 'Backup cancelled.' }
    Write-Info 'Hashing source files. Large collections can take several minutes; do not launch ARK.'
    $files = @(Get-TreeManifest $Paths.ModsDir)
    if ($BackupApproval -and (Get-BackupReview $Paths $Refresh).Approval -cne $BackupApproval) {
        throw 'The reviewed state changed during source hashing. Review again. No new backup was started.'
    }
    $mods = @($catalog.Library.Records.Values | Sort-Object ModId | ForEach-Object {
        [pscustomobject]@{ ModId = $_.ModId; FileId = $_.FileId; Name = $_.Name; FolderName = $catalog.Folders[$_.ModId] }
    })
    $id = [guid]::NewGuid().ToString('N')
    $libraryRelative = Get-RelativeName $Paths.UserDataRoot $catalog.Library.Path
    $manifest = [pscustomobject]@{
        SchemaVersion = 2; SnapshotId = $id; GameId = 83374; ArkRoot = $Paths.ArkRoot
        CreatedUtc = [DateTime]::UtcNow.ToString('o'); Build = $ScriptVersion
        LibraryRelativePath = $libraryRelative; LibrarySha256 = $catalog.LibraryHash
        Mods = $mods; Files = $files
    }
    Assert-Manifest $Paths $manifest $id
    $totalBytes = [long](($files | Measure-Object Length -Sum).Sum) + (Get-Item -LiteralPath $catalog.Library.Path).Length
    Assert-FreeSpace $Paths.GuardRoot $totalBytes
    $root = Join-SafePath $Paths.SnapshotsRoot $id
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Write-NewJson (Join-SafePath $root 'pending.json') ([pscustomobject]@{SchemaVersion=1;Kind='Snapshot';Id=$id;ArkRoot=$Paths.ArkRoot})
    Write-Info "Building separate snapshot: $id. Previous snapshots are not modified or deleted."
    Invoke-Robocopy $Paths.ModsDir (Join-Path $root 'Mods')
    $libraryTarget = Join-SafePath (Join-Path $root 'Metadata') $libraryRelative
    [IO.Directory]::CreateDirectory((Split-Path $libraryTarget -Parent)) | Out-Null
    [IO.File]::Copy($catalog.Library.Path, $libraryTarget, $false)
    Write-NewJson (Join-Path $root 'manifest.json') $manifest
    $snapshot = [pscustomobject]@{ Id = $id; Root = $root; Manifest = $manifest }
    Assert-SnapshotContent $snapshot
    Write-Info 'Rechecking source files before selecting the new snapshot.'
    Assert-TreeMatches $Paths.ModsDir $files
    if ((Get-Sha256 $catalog.Library.Path) -ne $catalog.LibraryHash) { throw 'The index changed during backup. The previous snapshot remains selected.' }
    Commit-SnapshotPointer $Paths $snapshot
    [IO.File]::Delete((Join-SafePath $root 'pending.json'))
    Write-Good "Snapshot committed: $($mods.Count) mods. Earlier snapshots retained; no automatic cleanup is enabled."
    return [pscustomobject]@{ Status = 'SnapshotSaved'; SnapshotId = $id; ModCount = $mods.Count }
}
function Assert-LiveIdentity($Paths, $Snapshot) {
    $catalog = Get-LiveCatalog $Paths
    if ((Get-RelativeName $Paths.UserDataRoot $catalog.Library.Path) -cne $Snapshot.Manifest.LibraryRelativePath) { throw 'The mod-library account/path changed. Launch is blocked.' }
    $differences = New-Object 'Collections.Generic.List[string]'
    $savedIds = @($Snapshot.Manifest.Mods | ForEach-Object { [string]$_.ModId })
    foreach ($mod in $Snapshot.Manifest.Mods) {
        if (-not $catalog.Library.Records.ContainsKey([string]$mod.ModId)) { $differences.Add("$($mod.Name) [$($mod.ModId)]: absent from current library; removal intent unknown") }
        elseif ($catalog.Library.Records[[string]$mod.ModId].FileId -cne [string]$mod.FileId) { $differences.Add("$($mod.Name) [$($mod.ModId)]: installed version changed") }
    }
    foreach ($entry in $catalog.Library.Entries) {
        if ($entry.ModId -notin $savedIds) { $differences.Add("$($entry.Name) [$($entry.ModId)]: not on saved protection list") }
    }
    if ($differences.Count) {
        foreach ($difference in $differences) { Write-Warn $difference }
        throw 'The protection list and current library differ. Review changes in ARK before updating the list. Launch is blocked; no index rewrite or version downgrade was attempted.'
    }
    return $catalog
}
function Copy-MissingProtectedFile([string]$Source, [string]$Destination, $Expected, [string]$LibraryPath, [string]$LibraryHash) {
    Assert-ArkClosed
    Assert-NoLinks $Source; Assert-NoLinks $Destination
    if (Test-Path -LiteralPath $Destination) { throw 'A destination appeared during repair. No existing file was overwritten.' }
    [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent)) | Out-Null
    # Stage next to destination for a same-volume, no-overwrite rename.
    $temp = $Destination + '.modlocket-' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::Copy($Source, $temp, $false)
    if ((Get-Item -LiteralPath $temp).Length -ne $Expected.Length -or (Get-Sha256 $temp) -ne $Expected.Sha256) { throw 'Staged repair failed its checksum. Launch remains blocked.' }
    Assert-ArkClosed
    if ((Get-Sha256 $LibraryPath) -cne $LibraryHash) {
        throw 'The mod index changed while a repair file was staged. The staged file was not installed; launch is blocked.'
    }
    Assert-NoLinks $Destination
    [IO.File]::Move($temp, $Destination)
}
function Invoke-ProtectedLaunch($Paths) {
    Assert-ArkClosed
    $snapshot = Load-Snapshot $Paths
    $catalog = Assert-LiveIdentity $Paths $snapshot
    Write-Info 'Verifying backup and installed file hashes. This is a local snapshot check, not an online update check.'
    Assert-SnapshotContent $snapshot
    $expected = @{}; foreach ($file in $snapshot.Manifest.Files) { $expected[[string]$file.Path] = $file }
    # Complete preflight before any live write: changed/extra existing content blocks repair.
    Write-StageProgress 'Listing installed files'
    $liveFiles = @(Get-SafeFiles $Paths.ModsDir)
    $total = [long](($liveFiles | Measure-Object Length -Sum).Sum); $done = 0L
    Write-StageProgress 'Checking installed contents' $done $total
    foreach ($file in $liveFiles) {
        Assert-ArkClosed
        $relative = Get-RelativeName $Paths.ModsDir $file.FullName
        if (-not $expected.ContainsKey($relative) -or $file.Length -ne $expected[$relative].Length -or
            (Get-Sha256 $file.FullName) -ne $expected[$relative].Sha256) {
            throw "Existing content differs from the snapshot: $relative. No overwrite repair will be attempted in this preview."
        }
        $done += $file.Length
        Write-StageProgress 'Checking installed contents' $done $total
    }
    $missing = @($snapshot.Manifest.Files | Where-Object { -not (Test-Path -LiteralPath (Join-SafePath $Paths.ModsDir $_.Path)) })
    if ($missing.Count) {
        Assert-FreeSpace $Paths.ModsDir ([long](($missing | Measure-Object Length -Sum).Sum))
        $repaired = 0
        foreach ($file in $missing) {
            Write-StageProgress 'Recovering missing files' $repaired $missing.Count
            Assert-ArkClosed
            if ((Get-Sha256 $catalog.Library.Path) -ne $catalog.LibraryHash) { throw 'The mod index changed during repair; launch is blocked.' }
            Copy-MissingProtectedFile (Join-SafePath (Join-Path $snapshot.Root 'Mods') $file.Path) (Join-SafePath $Paths.ModsDir $file.Path) $file $catalog.Library.Path $catalog.LibraryHash
            $repaired++
            Write-StageProgress 'Recovering missing files' $repaired $missing.Count
        }
    }
    Assert-TreeMatches $Paths.ModsDir $snapshot.Manifest.Files
    [void](Assert-LiveIdentity $Paths $snapshot)
    if ((Get-Sha256 $catalog.Library.Path) -ne $catalog.LibraryHash) { throw 'The mod index changed during verification; launch is blocked.' }
    Assert-ArkClosed
    Write-Good "Local snapshot verified: $($snapshot.Manifest.Mods.Count) mods; repaired $($missing.Count) missing files."
    if ($DeferSteamLaunch) { Write-Info 'Local verification complete; returning launch approval to the window.' }
    else { Write-Info 'Requesting Steam launch. This does not prove successful game loading or online currency.' }
    if (-not $DeferSteamLaunch) { Start-Process "steam://rungameid/$SteamAppId" -ErrorAction Stop }
    return [pscustomobject]@{
        Status = 'Verified'; SnapshotId = $snapshot.Id; ModCount = $snapshot.Manifest.Mods.Count
        FilesChecked = $snapshot.Manifest.Files.Count; FilesRestored = $missing.Count
        SteamRequested = (-not [bool]$DeferSteamLaunch); NeedsSteamLaunch = [bool]$DeferSteamLaunch; CheckedUtc = [DateTime]::UtcNow.ToString('o')
    }
}
function Assert-QuickFileLayout($Paths, $Snapshot) {
    # Read-only presence/length check. Deliberately not a content-integrity claim.
    $expected = @{}
    foreach ($file in $Snapshot.Manifest.Files) { $expected[[string]$file.Path] = $file }
    Write-StageProgress 'Checking file names and sizes' 0 $Snapshot.Manifest.Files.Count
    $count = 0
    # Stream discovery so progress appears during the walk, not after it.
    Get-SafeFiles $Paths.ModsDir | ForEach-Object {
        $file = $_
        $relative = Get-RelativeName $Paths.ModsDir $file.FullName
        if (-not $expected.ContainsKey($relative)) {
            throw "Unexpected file: $relative. Review the collection before updating the backup."
        }
        if ($file.Length -ne $expected[$relative].Length) {
            throw "File size changed: $relative. Use Verify + Repair for a full check. Quick launch will not overwrite it."
        }
        $expected.Remove($relative)
        $count++
        Write-StageProgress 'Checking file names and sizes' $count $Snapshot.Manifest.Files.Count
    }
    if ($expected.Count) {
        $sample = @($expected.Keys | Sort-Object | Select-Object -First 3) -join ', '
        throw "Missing $($expected.Count) protected file(s): $sample. Use Verify + Repair to verify the backup and recover missing files."
    }
    return $count
}
function Invoke-QuickLaunch($Paths) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Assert-ArkClosed
    Write-Info 'Quick launch: checking saved versions, file names and sizes. File contents and online updates are not verified.'
    $timings = New-Object 'Collections.Generic.List[object]'
    $stageStart = $clock.Elapsed.TotalSeconds
    $snapshot = Load-Snapshot $Paths
    Assert-SnapshotMetadata $snapshot
    $timings.Add([pscustomobject]@{ Stage = 'Snapshot metadata'; Seconds = [Math]::Round($clock.Elapsed.TotalSeconds - $stageStart, 2) })
    $stageStart = $clock.Elapsed.TotalSeconds
    $catalog = Assert-LiveIdentity $Paths $snapshot
    $timings.Add([pscustomobject]@{ Stage = 'Library and paths'; Seconds = [Math]::Round($clock.Elapsed.TotalSeconds - $stageStart, 2) })
    $stageStart = $clock.Elapsed.TotalSeconds
    $count = Assert-QuickFileLayout $Paths $snapshot
    $timings.Add([pscustomobject]@{ Stage = 'File names and sizes'; Seconds = [Math]::Round($clock.Elapsed.TotalSeconds - $stageStart, 2) })
    $stageStart = $clock.Elapsed.TotalSeconds
    # Recheck metadata and layout at the launch boundary; no mod payload reads.
    [void](Assert-LiveIdentity $Paths $snapshot)
    [void](Assert-QuickFileLayout $Paths $snapshot)
    if ((Get-Sha256 $catalog.Library.Path) -ne $catalog.LibraryHash) {
        throw 'The mod index changed during the quick check; launch is blocked.'
    }
    if ((Load-Snapshot $Paths).Id -cne $snapshot.Id) { throw 'The selected snapshot changed during the quick check.' }
    Assert-ArkClosed
    $timings.Add([pscustomobject]@{ Stage = 'Final rechecks'; Seconds = [Math]::Round($clock.Elapsed.TotalSeconds - $stageStart, 2) })
    $clock.Stop()
    foreach ($timing in $timings) { Write-Info ("Timing: {0} - {1:N2}s" -f $timing.Stage, $timing.Seconds) }
    Write-Good ("Quick check passed: {0} mods, {1} files in {2:N1} seconds. No files were repaired." -f $snapshot.Manifest.Mods.Count, $count, $clock.Elapsed.TotalSeconds)
    Write-Warn 'Matching file names and sizes cannot detect same-size corruption. Use Verify + Repair for full local integrity verification.'
    if ($DeferSteamLaunch) {
        Write-Info 'Quick check complete; returning launch approval to the window.'
        Write-StageProgress 'Awaiting Steam handoff'
    } else {
        Write-Info 'Requesting Steam launch.'
        Write-StageProgress 'Requesting Steam launch'
    }
    if (-not $DeferSteamLaunch) { Start-Process "steam://rungameid/$SteamAppId" -ErrorAction Stop }
    return [pscustomobject]@{
        Status = 'QuickChecked'; SnapshotId = $snapshot.Id; ModCount = $snapshot.Manifest.Mods.Count
        FilesChecked = $count; FilesRestored = 0; IntegrityVerified = $false
        BackupContentsVerified = $false; OnlineUpdatesVerified = $false
        SteamRequested = (-not [bool]$DeferSteamLaunch); NeedsSteamLaunch = [bool]$DeferSteamLaunch; CheckedUtc = [DateTime]::UtcNow.ToString('o')
        DurationSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2)
        StageTimings = $timings.ToArray()
    }
}
function Export-Inventory($Paths) {
    $report = Get-InspectionReport $Paths
    Assert-NoLinks $Paths.GuardRoot
    [IO.Directory]::CreateDirectory($Paths.GuardRoot) | Out-Null
    $rows = @($report.Rows | Sort-Object Name | ForEach-Object {
        # Spreadsheet applications can execute formula-looking CSV cells.
        $safeName = $_.Name -replace '^[=+@\-\t\r\n]', "'`$0"
        [pscustomobject]@{ ModId = $_.ModId; Name = $safeName; FileId = $_.FileId; LibraryStatus = $_.LibraryStatus; FolderPresent = $_.FolderPresent; Findings = $_.Findings; Origin = $_.Origin }
    })
    # Avoid overwriting existing Desktop files; dated exports live in the guard directory.
    $path = Join-SafePath $Paths.GuardRoot ('ModList-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.csv')
    $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    Write-Good "Exported $($report.ModCount) library entries plus $($rows.Count - $report.ModCount) additional findings: $path"
    foreach ($issue in $report.GlobalIssues) { Write-Warn $issue }
    Write-Info 'Includes problem entries. Not a download history, ownership check, file-integrity check, or live update check.'
    return [pscustomobject]@{ Status = 'InventoryExported'; Path = $path; ModCount = $report.ModCount; AttentionCount = $report.AttentionCount }
}
function Show-ModUpdateReport($Paths) {
    $logs = @(Get-SafeFiles $Paths.UserDataRoot | Where-Object { $_.Name -like 'game_83374_*.log' } | Sort-Object LastWriteTimeUtc -Descending)
    if (-not $logs.Count) { throw 'No local ARK scan log was found. This tool does not contact CurseForge.' }
    $log = $logs[0]
    Write-Info "Historical log last written: $($log.LastWriteTimeUtc.ToString('o'))"
    Write-Warn 'This is not a live check. Scan completeness and current mod versions are NOT verified.'
    # Display actual recent evidence, never infer global success from substrings.
    Get-Content -LiteralPath $log.FullName -Tail 300 -ErrorAction Stop |
        Where-Object { $_ -match 'No need to update existing mod:|Mod invalid:|Mod valid:|Set installed mod status|Request to Install mod|Updating existing mod:' } |
        Select-Object -Last 25 | ForEach-Object { Write-Host "[log] $_" }
    return [pscustomobject]@{ Status = 'HistoricalLogOnly'; LogUtc = $log.LastWriteTimeUtc.ToString('o') }
}
function Get-InspectionReport($Paths) {
    Assert-ArkClosed
    $path = Find-LibraryJson $Paths.UserDataRoot
    $hash = Get-Sha256 $path
    $library = Get-LibraryData $path
    $rows = New-Object 'Collections.Generic.List[object]'
    $globalIssues = New-Object 'Collections.Generic.List[string]'
    $folders = @{}
    Assert-NoLinks $Paths.ModsDir
    if (Test-Path -LiteralPath $Paths.ModsDir -PathType Container) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $Paths.ModsDir -Force)) {
            Assert-NoLinks $folder.FullName
            if (Test-EmptyModTemp $folder) { continue }
            if ($folder.PSIsContainer -and $folder.Name -cmatch '^([1-9][0-9]{4,8})_([1-9][0-9]{0,19})$') {
                $folders[$folder.Name] = $folder
            } else { $globalIssues.Add("Unrecognized mod-folder layout: $($folder.Name)") }
        }
    } else { $globalIssues.Add('Installed mod directory is missing') }
    foreach ($entry in $library.Entries) {
        $findings = New-Object 'Collections.Generic.List[string]'
        foreach ($issue in $entry.Issues) { $findings.Add($issue) }
        $folderName = $entry.ModId + '_' + $entry.FileId
        $present = $folders.ContainsKey($folderName)
        if (-not $present) { $findings.Add('Expected version folder missing or identity unverified') }
        if ($entry.Profile -eq 'ASA' -and $entry.DiskPath -and -not $entry.Issues.Count) {
            try {
                if (-not (Test-RecordedModPath $Paths $entry)) {
                    $findings.Add('Recorded path differs from expected project/version folder')
                }
            } catch { $findings.Add('Recorded path is unverified') }
        }
        try { $pathKind = if (-not $entry.DiskPath) { 'Empty' } elseif ([IO.Path]::IsPathRooted($entry.DiskPath)) { 'Absolute' } else { 'Relative' } }
        catch { $pathKind = 'Unverified'; $findings.Add('Recorded path is malformed') }
        $recordedFolder = ($entry.DiskPath.TrimEnd([char[]]'\/') -split '[\\/]')[-1]
        $rows.Add([pscustomobject]@{ ModId = $entry.ModId; Name = $entry.Name; FileId = $entry.FileId; LibraryStatus = $entry.LibraryStatus; FolderPresent = $present; Findings = $findings -join '; '; Origin = 'CurrentLibrary'; RecordedPathKind = $pathKind; RecordedFolder = $recordedFolder })
    }
    foreach ($folderName in @($folders.Keys | Sort-Object)) {
        $parts = $folderName -split '_'; $id = $parts[0]; $version = $parts[1]
        if (-not $library.Records.ContainsKey($id) -or $library.Records[$id].FileId -cne $version) {
            $name = if ($library.Records.ContainsKey($id)) { $library.Records[$id].Name } else { "Mod $id" }
            $rows.Add([pscustomobject]@{ ModId = $id; Name = $name; FileId = $version; LibraryStatus = ''; FolderPresent = $true; Findings = 'Folder has no matching indexed installed version'; Origin = 'UnmatchedFolder' })
        }
    }
    $snapshotCompared = $false
    if (Test-Path -LiteralPath $Paths.Pointer) {
        try {
            $snapshot = Load-Snapshot $Paths
            $snapshotCompared = $true
            foreach ($mod in $snapshot.Manifest.Mods) {
                if (-not $library.Records.ContainsKey([string]$mod.ModId)) {
                    $rows.Add([pscustomobject]@{ ModId = $mod.ModId; Name = $mod.Name; FileId = $mod.FileId; LibraryStatus = 'Absent'; FolderPresent = $folders.ContainsKey([string]$mod.FolderName); Findings = 'On saved list, absent from current library; removal intent unknown'; Origin = 'SavedList' })
                } elseif ($library.Records[[string]$mod.ModId].FileId -cne [string]$mod.FileId) {
                    $globalIssues.Add("$($mod.Name) [$($mod.ModId)]: installed version differs from saved list")
                }
            }
            $savedIds = @($snapshot.Manifest.Mods | ForEach-Object { [string]$_.ModId })
            foreach ($entry in $library.Entries) {
                if ($entry.ModId -notin $savedIds) { $globalIssues.Add("$($entry.Name) [$($entry.ModId)]: not on saved protection list") }
            }
        } catch { $globalIssues.Add('Saved protection list could not be verified; comparison incomplete'); $snapshotCompared = $false }
    }
    if ($library.Entries.Count -eq 0) { $globalIssues.Add('Library is empty') }
    Assert-ArkClosed
    if ((Get-Sha256 $path) -ne $hash) { throw 'Library changed during inspection. Run the check again with ARK closed.' }
    $attention = @($rows | Where-Object { $_.Findings }).Count + $globalIssues.Count
    return [pscustomobject]@{ Status = 'Inspected'; ModCount = $library.Entries.Count; AttentionCount = $attention; Rows = $rows.ToArray(); GlobalIssues = $globalIssues.ToArray(); SnapshotCompared = $snapshotCompared; IntegrityVerified = $false; OnlineUpdatesVerified = $false }
}
function Show-Inspection($Paths) {
    Write-Info 'Read-only inspection: no backup, mod, or index files will be changed.'
    $report = Get-InspectionReport $Paths
    Write-Info "Library entries: $($report.ModCount). Findings needing attention: $($report.AttentionCount)."
    foreach ($row in $report.Rows) {
        $finding = if ($row.Findings) { $row.Findings } else { 'Index and folder identity agree; file contents not checked' }
        Write-Host "$($row.Name) [$($row.ModId)] | Installed file: $($row.FileId) | ARK status: $($row.LibraryStatus) | $finding"
        if ($row.RecordedPathKind) { Write-Host "  Recorded path: $($row.RecordedPathKind); final folder: $($row.RecordedFolder)" }
    }
    foreach ($issue in $report.GlobalIssues) { Write-Warn $issue }
    if (-not $report.SnapshotCompared) { Write-Warn 'No verified saved-list comparison. Mods absent from both this index and a saved list cannot be discovered here.' }
    Write-Warn 'This is not a file-integrity, ownership, or online update check. Inspection cannot set Ready, Survivor.'
    return $report
}
function Invoke-GuardAction($Paths, [string]$RequestedAction) {
    # Inspection is genuinely read-only, including no operation-lock creation.
    if ($RequestedAction -eq 'Inspect') { return Show-Inspection $Paths }
    if ($RequestedAction -eq 'Updates') { return Get-ModComparison $Paths }
    if ($RequestedAction -eq 'PlanBackup') {
        $state = Get-BackupPointerState $Paths
        return Get-BackupReview $Paths ([bool]$state.Id)
    }
    if ($RequestedAction -eq 'ManageBackups') { return Get-BackupManager $Paths }
    if ($RequestedAction -eq 'PlanSetup') { return Get-BackupReview $Paths $false }
    if ($RequestedAction -eq 'PlanRefresh') { return Get-BackupReview $Paths $true }
    $lock = Enter-OperationLock $Paths
    try {
        Assert-ArkClosed
        switch ($RequestedAction) {
            'RemoveSnapshot' { return Remove-ManagedSnapshot $Paths $TargetId $ManagementApproval }
            'SelectSnapshot' { return Select-ManagedSnapshot $Paths $TargetId $ManagementApproval }
            'CleanRepairStaging' { return Move-RepairLeftovers $Paths $ManagementApproval }
            'Setup' { return Save-Snapshot $Paths $false }
            'Refresh' { return Save-Snapshot $Paths $true }
            'Launch' { return Invoke-ProtectedLaunch $Paths }
            'QuickLaunch' { return Invoke-QuickLaunch $Paths }
            'Inventory' { return Export-Inventory $Paths }
            'SaveModList' { return Save-ModListSnapshot $Paths $BackupApproval }
            'Inspect' { return Show-Inspection $Paths }
            'FullRestore' { throw 'Full overwrite restore is disabled in this safety preview. It requires a tested file-and-metadata rollback path.' }
            default { throw 'Unsupported action.' }
        }
    } finally { $lock.Dispose() }
}

. (Join-Path $PSScriptRoot 'ModLocket-Backups.ps1')
. (Join-Path $PSScriptRoot 'ModLocket-Catalog.ps1')

if ($LibraryOnly) { return }
try {
    if (-not $ArkRoot -or -not (Test-Path -LiteralPath (Join-Path $ArkRoot 'ShooterGame/Binaries/Win64/ArkAscended.exe') -PathType Leaf)) {
        throw 'Specify the Steam ASA installation using -ArkRoot, or launch the GUI and select it there.'
    }
    Write-Info "ModLocket $ScriptVersion - experimental safety checkpoint; not for public release."
    $result = Invoke-GuardAction (Get-Paths $ArkRoot) $Action
    Write-Output ('__MODLOCKET_RESULT__=' + (ConvertTo-Json -InputObject $result -Depth 8 -Compress))
    exit 0
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message)
    Write-Output '__MODLOCKET_RESULT__={"Status":"Blocked","SteamRequested":false}'
    exit 1
}
