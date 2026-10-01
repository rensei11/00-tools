$ErrorActionPreference = 'Stop'

$logPath = Join-Path $env:TEMP 'rensei_black_codex_recovery_log.txt'

try {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe was not found.'
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

    $output = & wsl.exe -d Ubuntu -- bash -lc $script 2>&1
    $rc = $LASTEXITCODE
    $output | Tee-Object -FilePath $logPath

    if ($rc -ne 0) {
        throw "WSL runner exited with code $rc."
    }

    'SUCCESS' | Add-Content -LiteralPath $logPath -Encoding ASCII
    exit 0
}
catch {
    $message = $_.Exception.Message
    @(
        'Black Codex recovery failed.'
        $message
    ) | Set-Content -LiteralPath $logPath -Encoding ASCII

    Write-Host 'Black Codex recovery failed.'
    Write-Host $message
    Write-Host ''
    Write-Host 'Details were saved to:'
    Write-Host $logPath
    exit 1
}
