@echo off
setlocal EnableExtensions

set "PS1=%TEMP%\rensei_updater_codex.ps1"
set "LOG=%TEMP%\rensei_updater_codex_log.txt"
del /q "%PS1%" >nul 2>nul

curl.exe -L --fail --silent --show-error "https://raw.githubusercontent.com/rensei11/00-tools/main/black-codex-recovery/run_updater_codex.ps1" -o "%PS1%"
if errorlevel 1 (
  echo Failed to download the updater Codex script.
  echo See: %LOG%
  pause
  exit /b 1
)

powershell.exe -NoProfile -File "%PS1%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo Updater Codex failed.
  echo See log: %LOG%
  echo.
  pause
  exit /b %RC%
)

del /q "%PS1%" >nul 2>nul
exit /b 0
