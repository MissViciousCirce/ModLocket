@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Personal.Tests.ps1"
pause
