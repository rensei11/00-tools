@echo off
setlocal EnableExtensions

set "RUNNER=%TEMP%\rensei_black_codex_recovery.ps1"
del /q "%RUNNER%" >nul 2>nul

echo BLACK CODEX
echo Preparing guarded recovery runner...
echo Downloading current recovery runner...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -TimeoutSec 45 -Uri 'https://raw.githubusercontent.com/rensei11/00-tools/main/black-codex-recovery/run_black_codex.ps1' -OutFile ($env:TEMP+'\rensei_black_codex_recovery.ps1')"
if errorlevel 1 (
  echo Failed to download the guarded recovery runner.
  pause
  exit /b 1
)

echo Recovery runner downloaded.
echo Checking recovery runner...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:TEMP+'\rensei_black_codex_recovery.ps1';$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);if(@($e).Count-ne 0){exit 21};$s=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8);if($s.IndexOf('Black Codex recovery completed.',[StringComparison]::Ordinal)-lt 0){exit 22}"
if errorlevel 1 (
  echo Recovery runner preflight failed.
  pause
  exit /b 1
)

echo Recovery runner check passed.
echo Starting guarded recovery...

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
