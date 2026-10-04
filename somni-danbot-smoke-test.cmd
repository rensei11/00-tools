@echo off
setlocal EnableExtensions DisableDelayedExpansion
title DanbotNL standalone smoke test

set "RUNNER=%TEMP%\somni-danbot-smoke-test.ps1"
set "URL=https://raw.githubusercontent.com/rensei11/00-tools/main/somni-danbot-smoke-test.ps1"

echo Downloading the DanbotNL test runner...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%RUNNER%'; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 goto :download_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RUNNER%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto :test_failed

exit /b 0

:download_failed
echo.
echo FAILED: Could not download the test runner.
echo No Somni or ComfyUI files were changed.
pause
exit /b 1

:test_failed
echo.
echo FAILED: DanbotNL test did not complete.
echo Check the log path shown above.
pause
exit /b %RC%
