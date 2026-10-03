$ErrorActionPreference = 'Stop'

$logPath = Join-Path $env:TEMP 'rensei_cezar_command_center.log'
$repo = '/home/rensei/cezar-command-center/00-tools'

function Write-Log {
    param([string]$Message)
    [IO.File]::AppendAllText(
        $logPath,
        ((Get-Date).ToString('s') + ' ' + $Message + [Environment]::NewLine),
        (New-Object Text.UTF8Encoding($false))
    )
}

try {
    [IO.File]::WriteAllText($logPath, '', (New-Object Text.UTF8Encoding($false)))

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe was not found.'
    }

    $script = @'
set -e
ROOT=/home/rensei/cezar-command-center
REPO=$ROOT/00-tools
mkdir -p "$ROOT"
if [ ! -d "$REPO/.git" ]; then
  env GIT_TERMINAL_PROMPT=0 git clone --branch main --single-branch https://github.com/rensei11/00-tools.git "$REPO"
else
  if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
    echo "Control repository has local changes." >&2
    exit 21
  fi
  env GIT_TERMINAL_PROMPT=0 git -C "$REPO" fetch origin main
  git -C "$REPO" switch main
  git -C "$REPO" merge --ff-only origin/main
fi
exec python3 "$REPO/cezar-command/bootstrap_local.py" --control-repo "$REPO"
'@

    Write-Log 'START'
    $output = & wsl.exe -d Ubuntu -- bash -lc $script 2>&1
    $rc = $LASTEXITCODE
    foreach ($line in @($output)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Write-Host $line
            Write-Log ([string]$line)
        }
    }
    Write-Log ('EXIT=' + $rc)

    if ($rc -ne 0) {
        throw ('Cezar command center startup failed with exit code ' + $rc + '.')
    }

    Write-Host 'CEZAR COMMAND CENTER READY'
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-Log ('BLOCKED: ' + $message)
    Write-Host 'CEZAR COMMAND CENTER BLOCKED'
    Write-Host $message
    Write-Host ''
    Write-Host 'Log:'
    Write-Host $logPath
    exit 1
}
