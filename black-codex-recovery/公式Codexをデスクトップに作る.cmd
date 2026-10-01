@echo off
setlocal EnableExtensions

set "APPID="

for /f "usebackq delims=" %%A in (`powershell.exe -NoProfile -Command "$a=Get-StartApps ^| Where-Object { $_.Name -eq 'ChatGPT' } ^| Select-Object -First 1 -ExpandProperty AppID; if($a){[Console]::Write($a)}"`) do set "APPID=%%A"

if defined APPID goto make_shortcut

where winget.exe >nul 2>&1
if errorlevel 1 goto open_download

winget.exe install --id=9NT1R1C2HH7J --source=msstore --accept-package-agreements --accept-source-agreements --silent
if errorlevel 1 goto open_download

for /l %%I in (1,1,20) do (
  set "APPID="
  for /f "usebackq delims=" %%A in (`powershell.exe -NoProfile -Command "$a=Get-StartApps ^| Where-Object { $_.Name -eq 'ChatGPT' } ^| Select-Object -First 1 -ExpandProperty AppID; if($a){[Console]::Write($a)}"`) do set "APPID=%%A"
  if defined APPID goto make_shortcut
  timeout /t 1 /nobreak >nul
)

goto open_download

:make_shortcut
powershell.exe -NoProfile -Command "$d=[Environment]::GetFolderPath('Desktop'); $w=New-Object -ComObject WScript.Shell; $p=Join-Path $d 'Codex.lnk'; $s=$w.CreateShortcut($p); $s.TargetPath='explorer.exe'; $s.Arguments=('shell:AppsFolder\'+$env:APPID); $s.Description='OpenAI Codex'; $s.Save(); Start-Process $p"
if errorlevel 1 goto failed
exit /b 0

:open_download
start "" "https://chatgpt.com/download/"
echo Automatic setup was not available. The official ChatGPT download page was opened.
pause
exit /b 1

:failed
echo Desktop shortcut creation failed.
pause
exit /b 1
