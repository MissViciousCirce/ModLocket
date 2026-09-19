@echo off
setlocal
echo Close ARK and other ModLocket windows before continuing.
echo This runs isolated tests, then a READ-ONLY check of your real mod library.
echo It does not repair, refresh backups, or launch ARK.
echo Running isolated tests. Progress is saved in Windows-Test-Results.txt; this may take a few minutes.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Safety.Tests.ps1" -NativeCopy > "%~dp0Windows-Test-Results.txt" 2>&1
if errorlevel 1 goto testsfailed
echo Tests passed. Reading your mod library now...
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Check-My-Mods.ps1" > "%~dp0ModLocket-ReadOnly-Report.txt" 2>&1
set "MODLOCKET_CHECK_EXIT=%ERRORLEVEL%"
type "%~dp0ModLocket-ReadOnly-Report.txt"
echo.
echo Send ModLocket-ReadOnly-Report.txt and Windows-Test-Results.txt for review.
pause
exit /b %MODLOCKET_CHECK_EXIT%
:testsfailed
type "%~dp0Windows-Test-Results.txt"
echo Tests failed. Your real ARK library was not inspected.
echo Send Windows-Test-Results.txt for review.
pause
exit /b 1
