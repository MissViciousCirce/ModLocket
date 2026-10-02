param(
    [Parameter(Mandatory=$true)][string]$GateName,
    [Parameter(Mandatory=$true)][string]$CommandBase64
)
$ErrorActionPreference = 'Stop'
# The parent signals only after assignment to its kill-on-close Windows Job.
try {
    $gate = [Threading.EventWaitHandle]::OpenExisting($GateName)
    try { if (-not $gate.WaitOne(15000)) { exit 125 } }
    finally { $gate.Dispose() }
    $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($CommandBase64))
    & ([scriptblock]::Create($command))
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
