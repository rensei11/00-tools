@echo off
setlocal EnableExtensions

wsl.exe -d Ubuntu -- bash -lc "set -e; export PATH=\"$HOME/.local/bin:$PATH\"; if ! command -v hermes >/dev/null 2>&1; then curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash; fi; source ~/.bashrc >/dev/null 2>&1 || true; hermes config set terminal.backend local; hermes config set terminal.timeout 7200; hermes doctor"
if errorlevel 1 goto setup_failed

wsl.exe -d Ubuntu -- bash -lc "source ~/.bashrc >/dev/null 2>&1 || true; exec hermes setup"
exit /b %ERRORLEVEL%

:setup_failed
echo Hermes setup failed.
pause
exit /b 1
