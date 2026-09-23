@echo off
setlocal EnableExtensions

set "TARGET="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
  if exist "%%D:\_fandom_voice_tool_link\update_and_start.ps1" set "TARGET=%%D:\_fandom_voice_tool_link\update_and_start.ps1"
)

if not defined TARGET goto target_missing

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%"
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" exit /b 0

echo Fandom voice tool repair failed.
pause
exit /b %RC%

:target_missing
echo Fandom voice tool link was not found.
pause
exit /b 1
