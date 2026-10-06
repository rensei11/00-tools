@echo off
setlocal EnableExtensions

set "SCRIPT=%TEMP%\rensei_yunjin_phase2_flac.ps1"
set "URL=https://raw.githubusercontent.com/rensei11/00-tools/main/ai-voice/phase2/yunjin_phase2_flac_v1.ps1"
set "LAUNCHLOG=%TEMP%\rensei_yunjin_phase2_launcher.log"

del /q "%SCRIPT%" >nul 2>nul
del /q "%LAUNCHLOG%" >nul 2>nul

echo YUN JIN PHASE2 FLAC MIGRATION
echo Downloading the guarded migration script...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%SCRIPT%'" >>"%LAUNCHLOG%" 2>&1
if errorlevel 1 goto failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%ERRORLEVEL%"

del /q "%SCRIPT%" >nul 2>nul

if not "%RC%"=="0" goto failed

echo.
echo Phase2 migration completed successfully.
pause
exit /b 0

:failed
echo.
echo Phase2 migration did not complete.
echo Launcher log: %LAUNCHLOG%
echo Detailed log: %TEMP%\rensei_yunjin_phase2_flac_log.txt
pause
exit /b 1
