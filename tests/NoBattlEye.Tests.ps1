$ErrorActionPreference='Stop'
$path=Join-Path (Split-Path $PSScriptRoot -Parent) 'ModLocket.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'GUI syntax failed.'}
$fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DeferredHandoff'},$true)
Invoke-Expression $fn.Extent.Text
function Test-DeferredLaunchResult {param($Result,$Action) return $script:approved}
function Start-Process {param($FilePath,$ErrorAction) if($script:fail){throw 'Simulated Steam failure'}; $script:uri=$FilePath;$script:count++}
$script:CancelRequested=$false;$script:ClosePromptActive=$false;$script:LaunchApprovalNotBefore=$null;$script:approved=$true;$script:count=0
foreach($action in @('QuickLaunch','Launch')){
 $result=[pscustomobject]@{SteamRequested=$false;NeedsSteamLaunch=$true;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
 Invoke-DeferredHandoff $result $action
 if($script:uri -cne 'steam://launch/2399830/option1' -or -not $result.SteamRequested -or $result.NeedsSteamLaunch){throw 'No-BattlEye handoff failed'}
}
foreach($condition in @('cancel','close','invalid','stale','failure')){
 $script:CancelRequested=($condition -eq 'cancel');$script:ClosePromptActive=($condition -eq 'close');$script:approved=($condition -ne 'invalid');$script:fail=($condition -eq 'failure')
 $script:LaunchApprovalNotBefore=if($condition -eq 'stale'){[DateTime]::UtcNow.AddMinutes(1)}else{$null}
 $before=$script:count;$blocked=$false
 $result=[pscustomobject]@{SteamRequested=$false;NeedsSteamLaunch=$true;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
 try{Invoke-DeferredHandoff $result 'QuickLaunch'}catch{$blocked=$true}
 if(-not $blocked -or $script:count -ne $before -or $result.SteamRequested){throw "Failed guard: $condition"}
}
Write-Output 'PASS: both GUI launch paths request No BattlEye; cancellation, close dialog, invalid/stale approval and launch failure remain blocked. No game launched.'
