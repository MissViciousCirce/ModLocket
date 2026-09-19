@echo off
setlocal
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0ModLocket.ps1" > "%~dp0Interface-Startup.txt" 2>&1
set "MODLOCKET_UI_EXIT=%ERRORLEVEL%"
if not "%MODLOCKET_UI_EXIT%"=="0" (
 type "%~dp0Interface-Startup.txt"
 pause
)
exit /b %MODLOCKET_UI_EXIT%
