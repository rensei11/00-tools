@echo off
setlocal EnableExtensions

set "SCRIPT=%TEMP%\rensei_phase2_inventory.ps1"
set "URL=https://raw.githubusercontent.com/rensei11/00-tools/main/ai-voice/phase2/phase2_readonly_inventory_v1.ps1"

del /q "%SCRIPT%" >nul 2>nul

echo PHASE2 READ-ONLY INVENTORY
echo Downloading the current inventory script...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%SCRIPT%'"
if errorlevel 1 goto failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%ERRORLEVEL%"

del /q "%SCRIPT%" >nul 2>nul

if not "%RC%"=="0" goto failed

echo.
echo Inventory completed successfully.
pause
exit /b 0

:failed
echo.
echo Inventory did not complete.
pause
exit /b 1
