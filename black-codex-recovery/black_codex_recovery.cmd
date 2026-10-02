@echo off
setlocal EnableExtensions

set "RUNNER=%TEMP%\rensei_black_codex_recovery.ps1"
del /q "%RUNNER%" >nul 2>nul

echo BLACK CODEX
echo Preparing guarded recovery runner...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/rensei11/00-tools/main/black-codex-recovery/run_black_codex.ps1' -OutFile ($env:TEMP+'\rensei_black_codex_recovery.ps1')"
if errorlevel 1 (
  echo Failed to download the guarded recovery runner.
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RUNNER%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo Black Codex recovery did not complete.
  pause
  exit /b %RC%
)

echo.
echo Black Codex recovery completed.
echo.
pause
exit /b 0
