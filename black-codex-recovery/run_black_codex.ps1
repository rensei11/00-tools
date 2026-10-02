$ErrorActionPreference = 'Stop'

$logPath = Join-Path $env:TEMP 'rensei_black_codex_recovery_log.txt'
$bridgePath = Join-Path $env:TEMP 'rensei_codex_windows_bridge.ps1'
$bridgeLog = Join-Path $env:TEMP 'rensei_codex_windows_bridge.log'
$bridgeErr = Join-Path $env:TEMP 'rensei_codex_windows_bridge_error.log'

function Write-RecoveryLog {
    param([string]$Message)
    [IO.File]::AppendAllText(
        $logPath,
        ((Get-Date).ToString('s') + ' ' + $Message + [Environment]::NewLine),
        (New-Object Text.UTF8Encoding($false))
    )
}

function Invoke-WslCommand {
    param(
        [string]$Arguments,
        [string]$Stage,
        [AllowNull()][string]$InputText = $null,
        [switch]$AllowFailure
    )

    if ([string]::IsNullOrWhiteSpace($Arguments)) {
        throw ($Stage + ': empty WSL command.')
    }
    if ($Arguments.IndexOf([char]13) -ge 0 -or $Arguments.IndexOf([char]10) -ge 0 -or $Arguments.Contains('"')) {
        throw ($Stage + ': unsafe WSL argument string.')
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'wsl.exe'
    $startInfo.Arguments = '-d Ubuntu -- ' + $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    if ($null -ne $InputText) {
        $startInfo.RedirectStandardInput = $true
        $startInfo.StandardInputEncoding = New-Object Text.UTF8Encoding($false)
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw ($Stage + ': wsl.exe did not start.')
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $InputText) {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
    }

    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()

    foreach ($line in @($stdout, $stderr)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            foreach ($part in ([string]$line -split '\r?\n')) {
                if (-not [string]::IsNullOrWhiteSpace($part)) {
                    Write-RecoveryLog ($Stage + ': ' + $part)
                }
            }
        }
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $detail = $stderr.Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = $stdout.Trim()
        }
        if ([string]::IsNullOrWhiteSpace($detail)) {
            throw ($Stage + ' failed with exit code ' + $exitCode + '.')
        }
        throw ($Stage + ' failed with exit code ' + $exitCode + '. ' + $detail)
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

try {
    [IO.File]::WriteAllText($logPath, '', (New-Object Text.UTF8Encoding($false)))

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe was not found.'
    }

    $probe = "printf 'WSL_READY\\n'"
    $probeOutput = @(Invoke-WslChecked $probe 'wsl-preflight')
    if (($probeOutput -join [Environment]::NewLine) -notmatch 'WSL_READY') {
        throw 'Ubuntu WSL did not return the readiness marker.'
    }

    $prepare = @'
set -euo pipefail
export GIT_TERMINAL_PROMPT=0
command -v git >/dev/null 2>&1 || { echo "git was not found in WSL."; exit 10; }
command -v python3 >/dev/null 2>&1 || { echo "python3 was not found in WSL."; exit 11; }
command -v codex >/dev/null 2>&1 || { echo "codex was not found in WSL."; exit 12; }
if [ ! -d /home/rensei/codex-chase/05-AI-voice/.git ]; then
  mkdir -p /home/rensei/codex-chase
  git clone https://github.com/rensei11/05-AI-voice.git /home/rensei/codex-chase/05-AI-voice >/dev/null 2>&1 || { echo "git clone failed."; exit 14; }
fi
test "$(git -C /home/rensei/codex-chase/05-AI-voice remote get-url origin)" = "https://github.com/rensei11/05-AI-voice.git" || { echo "Unexpected Git origin."; exit 13; }
git -C /home/rensei/codex-chase/05-AI-voice fetch origin >/dev/null 2>&1 || { echo "git fetch failed."; exit 15; }
git -C /home/rensei/codex-chase/05-AI-voice rev-parse --verify origin/main >/dev/null
git -C /home/rensei/codex-chase/05-AI-voice show origin/main:tools/codex_windows_bridge.ps1
'@
    $bridgeSource = @(Invoke-WslChecked $prepare 'bridge-source-preflight')
    $bridgeText = [string]::Join([Environment]::NewLine, @($bridgeSource)).TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($bridgeText)) {
        throw 'Windows bridge source was empty.'
    }
    if ($bridgeText -notmatch 'inspect_update' -or $bridgeText -notmatch 'updater_candidate_test' -or $bridgeText -notmatch 'APP_VERSION_LOCAL' -or $bridgeText -notmatch '_update_bootstrap_log.txt') {
        throw 'Windows bridge source is missing required updater diagnostic operations.'
    }

    [IO.File]::WriteAllText(
        $bridgePath,
        $bridgeText,
        (New-Object Text.UTF8Encoding($true))
    )

    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($bridgePath, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        throw ('Windows PowerShell 5.1 bridge parse failed: ' + $errors[0].Message)
    }

    $bytes = [IO.File]::ReadAllBytes($bridgePath)
    if (
        $bytes.Length -ge 6 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF -and
        $bytes[3] -eq 0xEF -and $bytes[4] -eq 0xBB -and $bytes[5] -eq 0xBF
    ) {
        throw 'Duplicate UTF-8 BOM detected in Windows bridge file.'
    }

    $bridgeAlreadyRunning = @(
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
                ([string]$_.CommandLine).IndexOf('rensei_codex_windows_bridge.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
    )

    foreach ($process in $bridgeAlreadyRunning) {
        Write-RecoveryLog ('Stopping stale managed bridge PID=' + [string]$process.ProcessId)
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 300

    Remove-Item -LiteralPath $bridgeLog, $bridgeErr -Force -ErrorAction SilentlyContinue
    $bridgeProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        ('"{0}"' -f $bridgePath),
        '-IdleMinutes',
        '120'
    ) -WindowStyle Hidden -RedirectStandardOutput $bridgeLog -RedirectStandardError $bridgeErr -PassThru

    Start-Sleep -Seconds 2
    $bridgeProcess.Refresh()
    if ($bridgeProcess.HasExited) {
        $detail = ''
        if (Test-Path -LiteralPath $bridgeErr -PathType Leaf) {
            $detail = ((Get-Content -LiteralPath $bridgeErr -Tail 40 -ErrorAction SilentlyContinue) | Out-String).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($detail) -and (Test-Path -LiteralPath $bridgeLog -PathType Leaf)) {
            $detail = ((Get-Content -LiteralPath $bridgeLog -Tail 40 -ErrorAction SilentlyContinue) | Out-String).Trim()
        }
        throw ('Windows bridge exited during startup. ' + $detail)
    }

    $run = @'
set -euo pipefail
export GIT_TERMINAL_PROMPT=0
git -C /home/rensei/codex-chase/05-AI-voice fetch origin >/dev/null 2>&1 || { echo "git fetch failed."; exit 15; }
git -C /home/rensei/codex-chase/05-AI-voice rev-parse --verify origin/main >/dev/null
git -C /home/rensei/codex-chase/05-AI-voice show origin/main:tools/run_black_codex.py | python3 - --control-repo /home/rensei/codex-chase/05-AI-voice
'@
    $output = @(Invoke-WslChecked $run 'black-codex-runner')
    foreach ($line in $output) { Write-Host ([string]$line) }
    Write-RecoveryLog 'SUCCESS'
    Write-Host 'Black Codex recovery completed.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-RecoveryLog ('FAILED: ' + $message)
    Write-Host 'Black Codex recovery failed.'
    Write-Host $message
    Write-Host ''
    Write-Host 'Details were saved to:'
    Write-Host $logPath
    exit 1
}
