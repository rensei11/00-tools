@echo off
setlocal EnableExtensions

set "LOG=%TEMP%\rensei_updater_codex_log.txt"
set "BRIDGE=%TEMP%\rensei_codex_windows_bridge.ps1"
set "BRIDGE_LOG=%TEMP%\rensei_codex_windows_bridge.log"
set "BRIDGE_ERR=%TEMP%\rensei_codex_windows_bridge_error.log"

del /q "%LOG%" "%BRIDGE%" "%BRIDGE_LOG%" "%BRIDGE_ERR%" >nul 2>nul

echo UPDATER CODEX
echo Preparing guarded updater repair...

wsl.exe -d Ubuntu -- bash -lc "set -eu; ROOT=$HOME/codex-updater; REPO=$ROOT/05-AI-voice; if [ ! -d $REPO/.git ]; then mkdir -p $ROOT; git clone https://github.com/rensei11/05-AI-voice.git $REPO >/dev/null 2>&1; fi; git -C $REPO fetch origin >/dev/null 2>&1; git -C $REPO show origin/main:tools/codex_windows_bridge.ps1" > "%BRIDGE%"
if errorlevel 1 (
  echo Failed to prepare the Windows bridge.
  pause
  exit /b 1
)

start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BRIDGE%" -IdleMinutes 120 > "%BRIDGE_LOG%" 2> "%BRIDGE_ERR%"
timeout /t 2 /nobreak >nul

echo Running the real WSL Codex updater repair...
wsl.exe -d Ubuntu -- bash -lc "set -eu; ROOT=$HOME/codex-updater; REPO=$ROOT/05-AI-voice; git -C $REPO fetch origin >/dev/null 2>&1; git -C $REPO show origin/main:tools/run_black_codex_updater.py | python3 - --control-repo $REPO" > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo Updater Codex repair did not complete.
  echo Details were saved automatically.
  echo %LOG%
  echo.
  pause
  exit /b %RC%
)

echo.
echo Updater Codex repair completed.
echo.
pause
exit /b 0
