@echo off
setlocal EnableExtensions

set "SCRIPT=%TEMP%\rensei_phase2_legacy_dependency_audit.ps1"
set "URL=https://raw.githubusercontent.com/rensei11/00-tools/main/ai-voice/phase2/phase2_legacy_dependency_audit_v1.ps1"

del /q "%SCRIPT%" >nul 2>nul

echo PHASE2 LEGACY DEPENDENCY AUDIT
echo Downloading the current read-only audit script...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%SCRIPT%'"
if errorlevel 1 goto failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%ERRORLEVEL%"

del /q "%SCRIPT%" >nul 2>nul

if not "%RC%"=="0" goto failed

echo.
echo Dependency audit completed successfully.
pause
exit /b 0

:failed
echo.
echo Dependency audit did not complete.
pause
exit /b 1
