@echo off
setlocal EnableExtensions

set "SCRIPT=%TEMP%\rensei_ai_voice_updater_migration.ps1"
set "LOG=%TEMP%\rensei_ai_voice_updater_migration_entry.log"
set "URL=https://raw.githubusercontent.com/rensei11/00-tools/4dacea95ec1b8903f212ff06b96b95913d5946f9/ai-voice/bootstrap/v1/migrate_updater_bootstrap_v1.ps1"

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
echo Log: %LOG%
exit /b 0

:no_powershell
>>"%LOG%" echo ERROR: powershell.exe was not found.
if exist "%LOG%" type "%LOG%"
echo See log: %LOG%
pause
exit /b 1

:download_failed
>>"%LOG%" echo ERROR: updater recovery download failed.
if exist "%LOG%" type "%LOG%"
echo See log: %LOG%
pause
exit /b 1

:migration_failed
>>"%LOG%" echo ERROR: updater recovery returned exit code %RC%.
if exist "%LOG%" type "%LOG%"
echo See log: %LOG%
pause
exit /b %RC%
