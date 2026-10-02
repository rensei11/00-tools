$ErrorActionPreference = 'Stop'

$logPath = Join-Path $env:TEMP 'rensei_black_codex_recovery_log.txt'
$bridgePath = Join-Path $env:TEMP 'rensei_codex_windows_bridge.ps1'
$bridgeLog = Join-Path $env:TEMP 'rensei_codex_windows_bridge.log'

try {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe was not found.'
    }

    $prepare = @'
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
git -C "$REPO" show origin/main:tools/codex_windows_bridge.ps1
'@

    $bridgeSource = & wsl.exe -d Ubuntu -- bash -lc $prepare 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        throw "Could not prepare the Windows bridge. WSL exited with code $rc."
    }

    $bridgeSource | Set-Content -LiteralPath $bridgePath -Encoding UTF8

    $bridgeAlreadyRunning = @(
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
                ([string]$_.CommandLine).IndexOf(
                    'rensei_codex_windows_bridge.ps1',
                    [StringComparison]::OrdinalIgnoreCase
                ) -ge 0
            } |
            Select-Object -First 1
    )

    if ($bridgeAlreadyRunning.Count -eq 0) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            ('"{0}"' -f $bridgePath),
            '-IdleMinutes',
            '120'
        ) -WindowStyle Hidden -RedirectStandardOutput $bridgeLog -RedirectStandardError $bridgeLog | Out-Null
        Start-Sleep -Seconds 2
    }

    $run = @'
set -eu
ROOT="$HOME/codex-chase"
REPO="$ROOT/05-AI-voice"
git -C "$REPO" fetch origin
git -C "$REPO" show origin/main:tools/run_black_codex.py | python3 - --control-repo "$REPO"
'@

    $output = & wsl.exe -d Ubuntu -- bash -lc $run 2>&1
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
