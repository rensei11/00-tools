@echo off
setlocal EnableExtensions

set "LOG=%TEMP%\rensei_black_codex_recovery_log.txt"
set "BRIDGE=%TEMP%\rensei_codex_windows_bridge.ps1"
set "BRIDGE_LOG=%TEMP%\rensei_codex_windows_bridge.log"
set "BRIDGE_ERR=%TEMP%\rensei_codex_windows_bridge_error.log"

del /q "%LOG%" "%BRIDGE%" "%BRIDGE_LOG%" "%BRIDGE_ERR%" >nul 2>nul

echo BLACK CODEX
echo Preparing the existing guarded runner...

wsl.exe -d Ubuntu -- bash -lc "set -eu; if [ ! -d /home/rensei/codex-chase/05-AI-voice/.git ]; then mkdir -p /home/rensei/codex-chase; git clone https://github.com/rensei11/05-AI-voice.git /home/rensei/codex-chase/05-AI-voice >/dev/null 2>&1; fi; git -C /home/rensei/codex-chase/05-AI-voice fetch origin >/dev/null 2>&1; git -C /home/rensei/codex-chase/05-AI-voice show origin/main:tools/codex_windows_bridge.ps1" > "%BRIDGE%"
if errorlevel 1 (
  echo Failed to prepare the existing Windows bridge.
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:TEMP+'\rensei_codex_windows_bridge.ps1';$s=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF);[IO.File]::WriteAllText($p,$s,(New-Object Text.UTF8Encoding($true)));$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);if(@($e).Count-ne 0){exit 21};$b=[IO.File]::ReadAllBytes($p);if($b.Length-ge 6 -and $b[0]-eq 0xEF -and $b[1]-eq 0xBB -and $b[2]-eq 0xBF -and $b[3]-eq 0xEF -and $b[4]-eq 0xBB -and $b[5]-eq 0xBF){exit 22}"
if errorlevel 1 (
  echo Windows PowerShell 5.1 bridge preflight failed.
  echo Black Codex was not started.
  pause
  exit /b 1
)

start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BRIDGE%" -IdleMinutes 120 > "%BRIDGE_LOG%" 2> "%BRIDGE_ERR%"
timeout /t 2 /nobreak >nul

echo Running the real WSL Codex task...
wsl.exe -d Ubuntu -- bash -lc "set -eu; git -C /home/rensei/codex-chase/05-AI-voice fetch origin >/dev/null 2>&1; git -C /home/rensei/codex-chase/05-AI-voice show origin/main:tools/run_black_codex.py | python3 - --control-repo /home/rensei/codex-chase/05-AI-voice" > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo Black Codex task did not complete.
  echo Details were saved automatically.
  echo %LOG%
  echo.
  pause
  exit /b %RC%
)

echo.
echo Black Codex task completed.
echo.
pause
exit /b 0
