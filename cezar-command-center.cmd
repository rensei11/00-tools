@echo off
setlocal EnableExtensions

set "PS1=%TEMP%\rensei_cezar_command_center.ps1"
set "URL=https://raw.githubusercontent.com/rensei11/00-tools/main/cezar-command/start_cezar_command_center.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -TimeoutSec 45 -Uri '%URL%' -OutFile '%PS1%'"
if errorlevel 1 goto download_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%

:download_failed
echo Cezar command center launcher download failed.
pause
exit /b 1
