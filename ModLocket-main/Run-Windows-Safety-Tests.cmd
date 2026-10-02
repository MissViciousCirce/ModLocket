@echo off
setlocal
echo Running tests in DISPOSABLE temporary folders, not your ARK installation.
echo No Steam or ARK launch will occur. Please wait...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Safety.Tests.ps1" -NativeCopy > "%~dp0Windows-Test-Results.txt" 2>&1
set "MODLOCKET_TEST_EXIT=%ERRORLEVEL%"
type "%~dp0Windows-Test-Results.txt"
echo.
echo Test process exit code: %MODLOCKET_TEST_EXIT%
echo Results are in Windows-Test-Results.txt beside this launcher.
echo Send that file for review. Do not use this build on your real mods yet.
pause
exit /b %MODLOCKET_TEST_EXIT%
