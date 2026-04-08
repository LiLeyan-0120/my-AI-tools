@echo off
setlocal EnableExtensions

if "%~1"=="" (
  echo Missing PowerShell script path.
  pause
  exit /b 1
)

set "SCRIPT_PATH=%~1"

set "PS_EXE="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  set "PS_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
)

if not defined PS_EXE (
  pwsh.exe -NoProfile -Command "exit 0" >nul 2>&1
  if "%ERRORLEVEL%"=="0" (
    set "PS_EXE=pwsh.exe"
  )
)

if not defined PS_EXE (
  echo PowerShell 7 is required but pwsh was not found.
  if not "%NO_PAUSE%"=="1" pause
  exit /b 1
)

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %2 %3 %4 %5 %6 %7 %8 %9
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
  echo Operation failed. Exit code %EXIT_CODE%.
) else (
  echo Operation completed.
)

if not "%NO_PAUSE%"=="1" pause
exit /b %EXIT_CODE%
