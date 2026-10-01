@echo off
setlocal EnableExtensions

set "PS1=%TEMP%\rensei_black_codex_recovery.ps1"
del /q "%PS1%" >nul 2>nul

curl.exe -L --fail --silent --show-error "https://raw.githubusercontent.com/rensei11/00-tools/main/black-codex-recovery/run_black_codex.ps1" -o "%PS1%"
if errorlevel 1 (
  echo Failed to download the recovery script.
  exit /b 1
)

powershell.exe -NoProfile -File "%PS1%"
set "RC=%ERRORLEVEL%"

del /q "%PS1%" >nul 2>nul
exit /b %RC%
