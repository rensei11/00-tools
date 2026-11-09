@echo off
setlocal
where py.exe >nul 2>nul
if not errorlevel 1 (
    py.exe -3 "%~dp0version_archive_manager.py" menu --tool-root "%~dp0."
    goto finish
)
where python.exe >nul 2>nul
if not errorlevel 1 (
    python.exe "%~dp0version_archive_manager.py" menu --tool-root "%~dp0."
    goto finish
)
echo Python for Windows could not be found.
:finish
pause
endlocal
