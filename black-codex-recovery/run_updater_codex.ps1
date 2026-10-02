$ErrorActionPreference = 'Stop'

$logPath = Join-Path $env:TEMP 'rensei_updater_codex_log.txt'
$taskId = 'updater-hardening-v2'
$branch = 'codex/updater-hardening-v1'
$jobRepoWsl = '/home/rensei/codex-chase/jobs/' + $taskId + '/05-AI-voice'
$testRoot = Join-Path $env:TEMP ('rensei_updater_candidate_test_' + [Guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $env:TEMP ('rensei_updater_candidate_backup_' + [Guid]::NewGuid().ToString('N'))
$backupState = @{}
$toolRoot = $null
$candidateCommit = ''
$restored = $false

function Add-RunLog {
    param([string]$Text)
    [IO.File]::AppendAllText(
        $logPath,
        ([DateTime]::Now.ToString('s') + ' ' + $Text + [Environment]::NewLine),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Get-ToolRoot {
    $rootName = 'AI' + [char]0x751F + [char]0x6210 + [char]0x30D5 + [char]0x30A1 + [char]0x30A4 + [char]0x30EB
    $leafName = 'Fandom' + [char]0x97F3 + [char]0x58F0 + [char]0x30C4 + [char]0x30FC + [char]0x30EB
    $root = Join-Path 'D:\' $rootName
    $root = Join-Path $root 'Irodori-TTS'
    $root = Join-Path $root $leafName
    if (-not (Test-Path -LiteralPath (Join-Path $root 'app.py') -PathType Leaf)) {
        throw 'AI voice tool program folder was not found at the registered D-drive path.'
    }
    return $root
}

function Get-WslJobWindowsRoot {
    $tail = 'home\rensei\codex-chase\jobs\' + $taskId + '\05-AI-voice'
    foreach ($prefix in @('\\wsl.localhost\Ubuntu\', '\\wsl$\Ubuntu\')) {
        $candidate = $prefix + $tail
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return $candidate
        }
    }
    throw 'The guarded updater job clone could not be opened from Windows.'
}

function Copy-WslFileBytes {
    param(
        [string]$Relative,
        [string]$Destination
    )
    if ($Relative -notmatch '^[A-Za-z0-9_./-]+$') {
        throw ('Unsafe candidate path: ' + $Relative)
    }
    $source = $jobRepoWsl.TrimEnd('/') + '/' + $Relative
    $encoded = (& wsl.exe -d Ubuntu -- bash -lc ("base64 -w0 -- '" + $source + "'") | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encoded)) {
        throw ('Could not export candidate file from WSL: ' + $Relative)
    }
    $bytes = [Convert]::FromBase64String($encoded)
    [IO.File]::WriteAllBytes($Destination, $bytes)
}

function Backup-And-InstallCandidate {
    param([string[]]$Files)

    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null
    foreach ($relative in $Files) {
        $destination = Join-Path $toolRoot $relative
        $backup = Join-Path $backupRoot $relative
        $exists = Test-Path -LiteralPath $destination -PathType Leaf
        $backupState[$relative] = $exists
        if ($exists) {
            [IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backup -Force
        }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Copy-WslFileBytes -Relative $relative -Destination $destination
    }
}

function Restore-OriginalFiles {
    foreach ($relative in @($backupState.Keys)) {
        $destination = Join-Path $toolRoot $relative
        $backup = Join-Path $backupRoot $relative
        if ([bool]$backupState[$relative]) {
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                Copy-Item -LiteralPath $backup -Destination $destination -Force
            }
        } else {
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        }
    }
    $script:restored = $true
}

function Read-LogTail {
    param([string]$Path, [int]$Limit = 20000)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $text) {
        return ''
    }
    if ($text.Length -le $Limit) {
        return $text
    }
    return $text.Substring($text.Length - $Limit)
}

function Write-ResultAndPush {
    param(
        [string]$Status,
        [string]$Message
    )

    try {
        $jobWin = Get-WslJobWindowsRoot
        $resultDir = Join-Path $jobWin 'codex-control'
        [IO.Directory]::CreateDirectory($resultDir) | Out-Null
        $resultPath = Join-Path $resultDir 'updater-local-test-result.json'

        $payload = [ordered]@{
            status = $Status
            tested_at = [DateTime]::UtcNow.ToString('o')
            task_id = $taskId
            branch = $branch
            candidate_commit = $candidateCommit
            message = $Message
            restored_originals = $restored
            update_status = Read-LogTail (Join-Path $toolRoot '_update_status.txt') 4000
            update_log = Read-LogTail (Join-Path $toolRoot '_update_bootstrap_log.txt')
            startup_log = Read-LogTail (Join-Path $toolRoot '_last_startup.log')
            startup_stdout = Read-LogTail (Join-Path $toolRoot '_last_startup_stdout.log')
        }
        $json = ($payload | ConvertTo-Json -Depth 6) + [Environment]::NewLine
        [IO.File]::WriteAllText($resultPath, $json, (New-Object System.Text.UTF8Encoding($false)))

        & wsl.exe -d Ubuntu -- git -C $jobRepoWsl add -- codex-control/updater-local-test-result.json | Out-Null
        & wsl.exe -d Ubuntu -- git -C $jobRepoWsl diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            & wsl.exe -d Ubuntu -- git -C $jobRepoWsl commit -m 'Record updater local test result' | Out-Null
            if ($LASTEXITCODE -eq 0) {
                & wsl.exe -d Ubuntu -- git -C $jobRepoWsl push origin ('HEAD:' + $branch) | Out-Null
            }
        }
    }
    catch {
        Add-RunLog ('RESULT_PUSH_ERROR ' + $_.Exception.Message)
    }
}

function Write-CandidateIndex {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $manifestPath = Join-Path $testRoot 'manifest.json'
    $indexPath = Join-Path $testRoot 'index.json'

    $files = [ordered]@{
        'app.py' = [IO.File]::ReadAllText((Join-Path $toolRoot 'app.py'), [Text.Encoding]::UTF8)
        'start_local.ps1' = [IO.File]::ReadAllText((Join-Path $toolRoot 'start_local.ps1'), [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    }
    $manifest = [ordered]@{
        version = 'candidate-test-v2'
        files = $files
    }
    $manifestJson = ($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine
    [IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))

    $hash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $index = [ordered]@{
        schema = 1
        version = 'candidate-test-v2'
        manifest_path = 'manifest.json'
        manifest_sha256 = $hash
    }
    $indexJson = ($index | ConvertTo-Json -Depth 4) + [Environment]::NewLine
    [IO.File]::WriteAllText($indexPath, $indexJson, (New-Object System.Text.UTF8Encoding($false)))
    return $indexPath
}

function Test-LocalReady {
    $url = 'http://127.0.0.1:7862/'
    for ($i = 0; $i -lt 80; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                return $true
            }
        } catch {
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

try {
    [IO.File]::WriteAllText($logPath, '', (New-Object System.Text.UTF8Encoding($false)))
    Add-RunLog 'START'

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
git -C "$REPO" show origin/main:tools/run_black_codex_updater.py | python3 - --control-repo "$REPO"
'@

    Add-RunLog 'CODEX_BEGIN'
    & wsl.exe -d Ubuntu -- bash -lc $script 2>&1 | Tee-Object -FilePath $logPath -Append
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        throw ('WSL updater runner exited with code ' + $rc + '.')
    }

    $candidateCommit = (& wsl.exe -d Ubuntu -- git -C $jobRepoWsl rev-parse HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $candidateCommit -notmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve the guarded updater candidate commit.'
    }
    Add-RunLog ('CANDIDATE ' + $candidateCommit)

    $toolRoot = Get-ToolRoot
    $deployFiles = @(
        'app.py',
        'start_local.ps1',
        'start_fandom_tool.cmd',
        'startup_update_check.ps1',
        'update_and_start.ps1',
        'updater_bootstrap.ps1'
    )
    Backup-And-InstallCandidate -Files $deployFiles
    Add-RunLog 'CANDIDATE_INSTALLED'

    $manualUpdater = Join-Path $toolRoot 'update_and_start.ps1'
    $manualText = Get-Content -LiteralPath $manualUpdater -Raw -ErrorAction Stop
    if ($manualText -notmatch 'RENSEI_UPDATER_TEST_INDEX') {
        throw 'Candidate updater does not contain the guarded test-index hook.'
    }

    $indexPath = Write-CandidateIndex
    $oldTestIndex = $env:RENSEI_UPDATER_TEST_INDEX
    try {
        $env:RENSEI_UPDATER_TEST_INDEX = $indexPath
        Add-RunLog 'LOCAL_UPDATE_BEGIN'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manualUpdater
        $updateRc = $LASTEXITCODE
    }
    finally {
        if ($null -eq $oldTestIndex) {
            Remove-Item Env:RENSEI_UPDATER_TEST_INDEX -ErrorAction SilentlyContinue
        } else {
            $env:RENSEI_UPDATER_TEST_INDEX = $oldTestIndex
        }
    }

    if ($updateRc -ne 0) {
        throw ('Candidate updater returned exit code ' + $updateRc + '.')
    }
    if (-not (Test-LocalReady)) {
        throw 'Candidate update returned success but localhost did not become ready.'
    }

    Add-RunLog 'LOCAL_TEST_SUCCESS'
    Write-ResultAndPush -Status 'DONE' -Message 'Candidate updater completed one guarded local update and localhost became ready.'
    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Add-RunLog 'SUCCESS'
    exit 0
}
catch {
    $message = $_.Exception.Message
    Add-RunLog ('ERROR ' + $message)

    if ($null -ne $toolRoot -and $backupState.Count -gt 0) {
        try {
            Restore-OriginalFiles
            Add-RunLog 'ORIGINAL_FILES_RESTORED'
        }
        catch {
            Add-RunLog ('RESTORE_ERROR ' + $_.Exception.Message)
        }
    }

    if ($null -ne $toolRoot) {
        Write-ResultAndPush -Status 'FAILED' -Message $message
    }

    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host 'Updater repair failed.'
    Write-Host $message
    Write-Host ''
    Write-Host 'Details were saved automatically.'
    Write-Host $logPath
    exit 1
}
