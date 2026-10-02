@echo off
setlocal EnableExtensions

set "SCRIPT=%TEMP%\rensei_ai_voice_updater_migration.ps1"
set "LOG=%TEMP%\rensei_ai_voice_updater_migration_entry.log"
set "URL=https://raw.githubusercontent.com/rensei11/00-tools/42166ad15db7638145b8995727ada12f6f716ad4/ai-voice/bootstrap/v1/migrate_updater_bootstrap_v1.ps1"

> "%LOG%" echo AI voice updater recovery started.

where powershell.exe >nul 2>&1
if errorlevel 1 goto no_powershell

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%SCRIPT%'" >>"%LOG%" 2>&1
if errorlevel 1 goto download_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" >>"%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto migration_failed

del /q "%SCRIPT%" >nul 2>&1
echo AI voice updater recovery completed.
exit /b 0

:no_powershell
echo Windows PowerShell was not found.
echo See log: %LOG%
pause
exit /b 1

:download_failed
echo Updater recovery download failed.
echo See log: %LOG%
pause
exit /b 1

:migration_failed
echo AI voice updater recovery failed.
echo See log: %LOG%
pause
exit /b %RC%
