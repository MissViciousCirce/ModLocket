@echo off
setlocal
echo Checking the interface with sample data only. No real mods are accessed.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0ModLocket.ps1" -UiCheck > "%~dp0Interface-Check.txt" 2>&1
set "MODLOCKET_UI_EXIT=%ERRORLEVEL%"
type "%~dp0Interface-Check.txt"
echo Interface exit code: %MODLOCKET_UI_EXIT%
pause
exit /b %MODLOCKET_UI_EXIT%
