@echo off
setlocal EnableExtensions

set "SCRIPT=%TEMP%\rensei_franz_phase2_flac.ps1"
set "URL=https://raw.githubusercontent.com/rensei11/00-tools/main/ai-voice/phase2/franz_phase2_flac_v1.ps1"
set "LAUNCHLOG=%TEMP%\rensei_franz_phase2_launcher.log"

del /q "%SCRIPT%" >nul 2>nul
del /q "%LAUNCHLOG%" >nul 2>nul

echo FRANZ PHASE2 FLAC MIGRATION
echo Downloading the guarded migration script...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%SCRIPT%'" >>"%LAUNCHLOG%" 2>&1
if errorlevel 1 goto failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%ERRORLEVEL%"

del /q "%SCRIPT%" >nul 2>nul

if "%RC%"=="0" goto success
if "%RC%"=="2" goto migrated_verify_failed

:failed
echo.
echo Phase2 migration stopped before confirmed completion.
echo Launcher log: %LAUNCHLOG%
echo Detailed log: %TEMP%\rensei_franz_phase2_flac_log.txt
pause
exit /b 1

:migrated_verify_failed
echo.
echo FLAC migration completed, but a post-migration verification failed.
echo Do not run this migration again. Send the screen output to ChatGPT.
echo Detailed log: %TEMP%\rensei_franz_phase2_flac_log.txt
pause
exit /b 2

:success
echo.
echo Phase2 Franz migration and verification completed successfully.
pause
exit /b 0
