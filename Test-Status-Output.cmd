@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Test-Status-Output.ps1" > "%~dp0Status-Output-Test.txt" 2>&1
type "%~dp0Status-Output-Test.txt"
pause
