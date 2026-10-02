$ErrorActionPreference = 'Stop'
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'ModLocket-Worker.cs')
    $command = 'Write-Host "HOST-CHECK"; Write-Output "OUTPUT-CHECK"; Write-Host ''__MODLOCKET_PROGRESS__={"Stage":"Testing","Percent":50}''; Write-Error "EXPECTED-TEST-ERROR" -ErrorAction Continue; exit 7'
    $worker = [ModLocket.OwnedWorker]::Start((Join-Path $PSHOME 'powershell.exe'), $command, (Join-Path $PSScriptRoot 'ModLocket-Worker-Entry.ps1'))
    try {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not $worker.Finished) {
            if ($clock.Elapsed.TotalSeconds -gt 20) { throw 'Output test timed out.' }
            Start-Sleep -Milliseconds 50
        }
        $lines = @($worker.Drain()); $text = $lines -join "`n"
        if ($worker.ExitCode -ne 7) { throw 'Exit code not preserved.' }
        if ($lines -notcontains 'HOST-CHECK' -or $lines -notcontains 'OUTPUT-CHECK') { throw 'Normal output missing.' }
        if ($lines -notcontains '__MODLOCKET_PROGRESS__={"Stage":"Testing","Percent":50}') { throw 'Progress marker missing.' }
        if ($text -notmatch '\[ERROR\].*EXPECTED-TEST-ERROR') { throw 'Real error output was lost.' }
        if ($text -match 'CLIXML|<Objs|<Obj ') { throw 'XML still present.' }
        if ($lines -contains '[ERROR] HOST-CHECK') { throw 'Normal output mislabeled as error.' }
        Write-Output 'PASS: readable output, progress, real errors, and exit code preserved.'
        Write-Output 'No ARK files or backups were accessed. No game was launched.'
    } finally { $worker.Dispose() }
    exit 0
} catch { Write-Output ('FAIL: ' + $_.Exception.Message); exit 1 }
