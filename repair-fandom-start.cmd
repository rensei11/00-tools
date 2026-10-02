@echo off
setlocal EnableExtensions

set "SCRIPT=%TEMP%\rensei_ai_voice_update_button_repair.ps1"
set "URL=https://raw.githubusercontent.com/rensei11/00-tools/main/ai-voice/bootstrap/v1/migrate_updater_bootstrap_v1.ps1"

del /q "%SCRIPT%" >nul 2>nul

echo AI VOICE UPDATE BUTTON REPAIR
echo Downloading the current repair script...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%SCRIPT%'"
if errorlevel 1 goto failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%ERRORLEVEL%"
del /q "%SCRIPT%" >nul 2>nul

if not "%RC%"=="0" goto failed

echo.
echo Update button repair completed.
pause
exit /b 0

:failed
echo.
echo Update button repair failed.
pause
exit /b 1
