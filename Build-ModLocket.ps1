[CmdletBinding()]
param(
    [string]$SourceDirectory = $PSScriptRoot,
    [string]$OutputDirectory,
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')][string]$FileVersion = '4.0.0.4',
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath $SourceDirectory).Path
if(-not $OutputDirectory){$OutputDirectory=Join-Path $source 'dist'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
# Explicit app-only allowlist. No recursive packaging of user folders, keys or backups.
$required=@('ModLocket.ps1','ModLocket-Core.ps1','ModLocket-Backups.ps1',
    'ModLocket-Theme.ps1','ModLocket-Worker.cs','ModLocket-Worker-Entry.ps1',
    'ViciousCirceLogo.png','ModLocket.ico','Footer-Snake.png','Moonlit-Header.png')
$optional=@('ModLocket-Catalog.ps1','ModLocket-CurseForge.ps1','ModLocket-Comparison-UI.ps1',
    'VERSION.txt','LICENSE.txt','PRIVACY.txt','ARTWORK.md')
foreach($name in $required){
    if(-not(Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)){
        throw "Missing $name. Put this build script beside ModLocket.ps1 in the extracted application folder."
    }
}
$files=@($required)+@($optional | Where-Object {Test-Path -LiteralPath (Join-Path $source $_) -PathType Leaf})
foreach($name in $files){
    if(((Get-Item -LiteralPath (Join-Path $source $name)).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Linked source file is not supported: $name"}
}
if(-not $PrepareOnly){
    if($env:OS -ne 'Windows_NT'){throw 'Build the EXE using Windows PowerShell 5.1 on Windows.'}
    Import-Module ps2exe -RequiredVersion 1.0.18 -ErrorAction Stop
}
[IO.Directory]::CreateDirectory($output) | Out-Null
$exe=Join-Path $output 'ModLocket.exe'
$bootstrap=Join-Path $output 'ModLocket-Bootstrap.ps1'
if((Test-Path -LiteralPath $exe) -or (Test-Path -LiteralPath $bootstrap)){
    throw 'This output folder already contains a build. Move it aside or choose -OutputDirectory with a new folder.'
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$memory=New-Object IO.MemoryStream
$zip=New-Object IO.Compression.ZipArchive($memory,[IO.Compression.ZipArchiveMode]::Create,$true)
try {
    foreach($name in $files){
        $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
        $stream=$entry.Open()
        try{$bytes=[IO.File]::ReadAllBytes((Join-Path $source $name));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    }
}finally{$zip.Dispose()}
try{$payload=[Convert]::ToBase64String($memory.ToArray())}finally{$memory.Dispose()}
# Keep the original app in a normal powershell.exe host: PSCommandPath,
# sibling modules and the owned cancellation worker retain their semantics.
$template=@'
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$runtime=$null; $child=$null; $known=@()
try {
    if(-not $env:LOCALAPPDATA){throw 'Windows local application storage is unavailable.'}
    $root=Join-Path $env:LOCALAPPDATA 'ModLocketSafetyPreview/Runtime'
    # Reject redirected ancestors; never unpack into ARK or its backup directory.
    $probe=[IO.Path]::GetFullPath($root)
    while($probe){
        if(Test-Path -LiteralPath $probe){
            if(((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'The runtime path contains a link or junction.'}
        }
        $parent=Split-Path -Path $probe -Parent
        if($parent -eq $probe){break};$probe=$parent
    }
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $runtime=Join-Path $root ([guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($runtime) | Out-Null
    $payloadBytes=[Convert]::FromBase64String('__PAYLOAD__')
    $memory=New-Object IO.MemoryStream(,$payloadBytes)
    $zip=New-Object IO.Compression.ZipArchive($memory,[IO.Compression.ZipArchiveMode]::Read,$false)
    try {
        foreach($entry in $zip.Entries){
            if($entry.FullName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$'){throw 'Invalid packaged filename.'}
            $destination=Join-Path $runtime $entry.FullName
            $inputStream=$entry.Open()
            try{
                $outputStream=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $known+=$destination
                try{$inputStream.CopyTo($outputStream)}finally{$outputStream.Dispose()}
            }finally{$inputStream.Dispose()}
        }
    }finally{$zip.Dispose();$memory.Dispose()}
    $main=Join-Path $runtime 'ModLocket.ps1'
    # An encoded command handles spaces and apostrophes in Windows user paths.
    $command="& '"+$main.Replace("'","''")+"'"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $shell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $child=Start-Process -FilePath $shell -ArgumentList @('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
    $child.WaitForExit()
    if($child.ExitCode -ne 0){throw "ModLocket exited with code $($child.ExitCode). Try Start-With-Log.cmd in the source folder for details."}
}catch{
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'ModLocket could not finish',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)
}finally{
    # Delete only this launch's known extracted files after the app exits.
    # Abrupt termination may leave a small runtime folder; it is never a backup.
    if($runtime -and (-not $child -or $child.HasExited)){
        try{
            if(((Get-Item -LiteralPath $runtime -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0){
                foreach($path in $known){
                    if((Test-Path -LiteralPath $path -PathType Leaf) -and (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)){
                        [IO.File]::Delete($path)
                    }
                }
                [IO.Directory]::Delete($runtime,$false)
            }
        }catch{}
    }
    if($child){$child.Dispose()}
}
'@
$scriptText=$template.Replace('__PAYLOAD__',$payload)
[IO.File]::WriteAllText($bootstrap,$scriptText,(New-Object Text.UTF8Encoding($true)))
if($PrepareOnly){Write-Output "Prepared bootstrap for inspection: $bootstrap";return}
Invoke-ps2exe -inputFile $bootstrap -outputFile $exe -x64 -STA -noConsole -DPIAware `
    -iconFile (Join-Path $source 'ModLocket.ico') -title 'ModLocket for ASA' `
    -description 'Mod backup, repair, and launch companion' -company 'ViciousCirce' `
    -product 'ModLocket for ASA' -version $FileVersion
if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'The compiler did not produce ModLocket.exe.'}
[IO.File]::Delete($bootstrap)
Write-Host "Built: $exe" -ForegroundColor Green
Write-Host 'Test this EXE locally before sharing it. Your source files and existing backups were not changed.'
