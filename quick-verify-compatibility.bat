@echo off
call "%~dp0scripts\launchers\run-powershell.bat" "%~dp0scripts\test-gateway-e2e.ps1" -RequireModel
