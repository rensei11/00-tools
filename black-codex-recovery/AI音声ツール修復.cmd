@echo off
setlocal EnableExtensions

set "PS1=%TEMP%\rensei_ai_voice_direct_repair.ps1"
set "LOG=%TEMP%\rensei_ai_voice_direct_repair_log.txt"
del /q "%PS1%" >nul 2>nul

curl.exe -L --fail --silent --show-error "https://raw.githubusercontent.com/rensei11/00-tools/main/black-codex-recovery/direct_repair_ai_voice.ps1" -o "%PS1%"
if errorlevel 1 (
  echo Failed to download the direct repair script.
  echo See: %LOG%
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo AI voice tool direct repair failed.
  echo See log: %LOG%
  echo.
  pause
  exit /b %RC%
)

del /q "%PS1%" >nul 2>nul
exit /b 0
