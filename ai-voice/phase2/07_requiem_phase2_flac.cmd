@echo off
setlocal EnableExtensions

set "BASE=%~dp0"
set "SCRIPT=%BASE%requiem_phase2_flac_v1.ps1"

echo REQUIEM PHASE2 FLAC MIGRATION

if not exist "%SCRIPT%" goto package_failed

if "%REQUIEM_PHASE2_PACKAGE_SELF_TEST%"=="1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -PackageSelfTest
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
)
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" goto success
if "%RC%"=="2" goto migrated_verify_failed

:failed
echo.
echo Phase2 migration stopped before confirmed completion.
echo Detailed log: %TEMP%\rensei_requiem_phase2_flac_log.txt
if not "%REQUIEM_PHASE2_PACKAGE_SELF_TEST%"=="1" pause
exit /b 1

:migrated_verify_failed
echo.
echo FLAC migration completed, but a post-migration verification failed.
echo Do not run this migration again. Send the screen output to ChatGPT.
echo Detailed log: %TEMP%\rensei_requiem_phase2_flac_log.txt
if not "%REQUIEM_PHASE2_PACKAGE_SELF_TEST%"=="1" pause
exit /b 2

:package_failed
echo.
echo Phase2 package is incomplete: requiem_phase2_flac_v1.ps1 was not found beside this CMD.
if not "%REQUIEM_PHASE2_PACKAGE_SELF_TEST%"=="1" pause
exit /b 1

:success
echo.
if "%REQUIEM_PHASE2_PACKAGE_SELF_TEST%"=="1" (
  echo Phase2 Requiem package self-test completed successfully.
) else (
  echo Phase2 Requiem migration and verification completed successfully.
  pause
)
exit /b 0
