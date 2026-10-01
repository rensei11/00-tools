$ErrorActionPreference = 'Stop'

$logPath = Join-Path $env:TEMP 'rensei_black_codex_recovery_log.txt'

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    'wsl.exe was not found.' | Set-Content -LiteralPath $logPath -Encoding ASCII
    Write-Host 'wsl.exe was not found.'
    exit 1
}

$script = @'
set -eu
command -v git >/dev/null 2>&1 || { echo "git was not found in WSL."; exit 10; }
command -v python3 >/dev/null 2>&1 || { echo "python3 was not found in WSL."; exit 11; }
command -v codex >/dev/null 2>&1 || { echo "codex was not found in WSL."; exit 12; }

ROOT="$HOME/codex-chase"
REPO="$ROOT/05-AI-voice"

if [ ! -d "$REPO/.git" ]; then
  mkdir -p "$ROOT"
  git clone https://github.com/rensei11/05-AI-voice.git "$REPO"
fi

git -C "$REPO" fetch origin
git -C "$REPO" show origin/main:tools/run_black_codex.py | python3 - --control-repo "$REPO"
'@

& wsl.exe -d Ubuntu -- bash -lc $script 2>&1 | Tee-Object -FilePath $logPath
$rc = $LASTEXITCODE

if ($rc -ne 0) {
    Write-Host ""
    Write-Host "Black Codex recovery failed. Details were saved to:"
    Write-Host $logPath
}

exit $rc
