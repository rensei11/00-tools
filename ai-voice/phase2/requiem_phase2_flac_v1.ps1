param([switch]$PackageSelfTest)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logPath = Join-Path $env:TEMP 'rensei_requiem_phase2_flac_log.txt'
$helperWin = Join-Path $PSScriptRoot 'requiem_phase2_migrate_v1.py'
$appBase = 'http://127.0.0.1:18762'
$referenceRootWin = 'D:\AI生成ファイル\Irodori-TTS\参照音声'
$character = 'レクイエム'
$migrationCommitted = $false

function Write-Phase2Log {
    param([string]$Message)
    $line = ([DateTime]::Now.ToString('s') + ' ' + $Message)
    Write-Host $Message
    [System.IO.File]::AppendAllText(
        $logPath,
        ($line + [Environment]::NewLine),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Invoke-JsonPost {
    param(
        [string]$Uri,
        [object]$Body,
        [int]$TimeoutSec = 30
    )
    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Uri $Uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSec
}

try {
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

    if ($PackageSelfTest) {
        Write-Phase2Log 'Phase2 Requiem package self-test: START'
        if (-not (Test-Path -LiteralPath $helperWin -PathType Leaf)) {
            throw 'Requiem Phase2 package is incomplete: helper Python file was not found.'
        }
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        $helperText = [IO.File]::ReadAllText($helperWin, $utf8Strict)
        foreach ($required in @(
            'EXPECTED_WAV_COUNT = 137',
            'def _preflight(',
            'def migrate(',
            'REQUIEM_PHASE2_SELF_TEST=PASS'
        )) {
            if ($helperText.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
                throw ('Package helper is missing required guard: ' + $required)
            }
        }
        $localPython = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($localPython)) {
            throw 'Python was not found for package self-test.'
        }
        $selfTestOutput = @(& $localPython $helperWin --self-test 2>&1)
        if ($LASTEXITCODE -ne 0 -or (@($selfTestOutput | ForEach-Object { [string]$_ }) -notcontains 'REQUIEM_PHASE2_SELF_TEST=PASS')) {
            throw ('Package helper self-test failed: ' + ((@($selfTestOutput | ForEach-Object { [string]$_ })) -join ' / '))
        }
        Write-Phase2Log 'REQUIEM_PHASE2_PACKAGE_SELF_TEST=PASS'
        exit 0
    }

    Write-Phase2Log 'Phase2 Requiem legacy migration: START'

    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $wsl -PathType Leaf)) {
        throw 'WSL was not found. No migration was started.'
    }

    $pythonPath = '/home/rensei/Irodori-TTS/.venv/bin/python'
    & $wsl -e test -x $pythonPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Irodori Python was not found in WSL. No migration was started.'
    }

    $charRoot = Join-Path $referenceRootWin $character
    $metaPath = Join-Path $charRoot '音声一覧.json'
    $refDir = Join-Path $charRoot '参照セット'
    $emotionCache = Join-Path $charRoot 'emotion2vec_plus_base_embeddings.json'

    if (-not (Test-Path -LiteralPath $charRoot -PathType Container)) {
        throw 'Requiem character folder was not found. No migration was started.'
    }
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        throw 'Requiem audio-list metadata was not found. No migration was started.'
    }

    $wavCount = @(Get-ChildItem -LiteralPath $charRoot -File -Filter '*.wav' -ErrorAction Stop).Count
    $flacCount = @(Get-ChildItem -LiteralPath $charRoot -File -Filter '*.flac' -ErrorAction Stop).Count
    if ($wavCount -ne 137 -or $flacCount -ne 0) {
        throw ('Requiem audio counts changed from the audited state. wav=' + $wavCount + ' flac=' + $flacCount + '. No migration was started.')
    }

    foreach ($seconds in @(30, 60, 90, 120)) {
        $pt = Join-Path $refDir (($seconds.ToString()) + '秒.pt')
        $json = Join-Path $refDir (($seconds.ToString()) + '秒.json')
        if (-not (Test-Path -LiteralPath $pt -PathType Leaf) -or -not (Test-Path -LiteralPath $json -PathType Leaf)) {
            throw ('Requiem ' + $seconds + '-second reference pair is incomplete. No migration was started.')
        }
    }
    if (-not (Test-Path -LiteralPath $emotionCache -PathType Leaf)) {
        throw 'Requiem emotion2vec cache was not found. No migration was started.'
    }

    try {
        $speakersBefore = Invoke-RestMethod -Uri ($appBase + '/speakers') -Method Get -TimeoutSec 3
    }
    catch {
        throw 'AI voice tool is not running. Start it first, then run this file again. No migration was started.'
    }
    if (@($speakersBefore.speakers) -notcontains $character) {
        throw 'Requiem is not available for generation before migration. No migration was started.'
    }
    Write-Phase2Log ('Preflight: audited Requiem state confirmed / wav=' + $wavCount + ' / flac=' + $flacCount)

    if (-not (Test-Path -LiteralPath $helperWin -PathType Leaf)) {
        throw 'Requiem Phase2 package is incomplete: helper Python file was not found.'
    }

    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
    $helperText = [IO.File]::ReadAllText($helperWin, $utf8Strict)
    foreach ($required in @(
        'EXPECTED_WAV_COUNT = 137',
        'def _preflight(',
        'def migrate(',
        'REQUIEM_PHASE2_SELF_TEST=PASS',
        'REQUIEM_PREFLIGHT=',
        'REQUIEM_MIGRATION_ERROR=',
        'PHASE2_RESULT='
    )) {
        if ($helperText.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw ('Public migration helper is missing required guard: ' + $required)
        }
    }

    $helperWsl = (& $wsl -e wslpath -a -u $helperWin | Select-Object -Last 1).Trim()
    if ([string]::IsNullOrWhiteSpace($helperWsl)) {
        throw 'Could not convert the temporary helper path for WSL.'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wsl
    $psi.Arguments = ('-e "' + $pythonPath + '" "' + $helperWsl + '"')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $processExitCode = $process.ExitCode

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Phase2Log ('WSL stdout: ' + ($stdout.Trim() -replace "[\r\n]+", ' / '))
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-Phase2Log ('WSL stderr: ' + ($stderr.Trim() -replace "[\r\n]+", ' / '))
    }

    $outputLines = @($stdout -split "[\r\n]+")
    if ($processExitCode -ne 0) {
        $diagnostic = @(
            $outputLines |
            Where-Object { $_ -like 'REQUIEM_MIGRATION_ERROR=*' } |
            Select-Object -Last 1
        )
        if ($diagnostic) {
            throw [string]$diagnostic
        }
        throw ('Migration process stopped with exit code ' + $processExitCode + '.')
    }

    $resultLine = @($outputLines | Where-Object { $_ -like 'PHASE2_RESULT=*' } | Select-Object -Last 1)
    if (-not $resultLine) {
        throw 'Migration result was not returned.'
    }
    $migration = ($resultLine.Substring('PHASE2_RESULT='.Length)) | ConvertFrom-Json
    $migrationCommitted = $true

    Write-Phase2Log (
        'Migration committed: converted=' + [string]$migration.converted_count +
        ' / skipped=' + [string]@($migration.skipped).Count +
        ' / cleanup_leftovers=' + [string]@($migration.wav_cleanup_leftovers).Count +
        ' / protected_pt=' + [string]$migration.protected_pt_count +
        ' / updated_json=' + [string]$migration.updated_json_count
    )

    $saved = Invoke-JsonPost -Uri ($appBase + '/voice/load') -Body @{ character = $character } -TimeoutSec 20
    $visible = @($saved.records | ForEach-Object { [string]$_.filename })
    foreach ($entry in @($migration.converted)) {
        if ($visible -notcontains [string]$entry.flac) {
            throw ('Converted FLAC is not visible in the saved-audio list: ' + [string]$entry.flac)
        }
        if ($visible -contains [string]$entry.wav) {
            throw ('Old converted WAV is still visible in the saved-audio list: ' + [string]$entry.wav)
        }
    }
    Write-Phase2Log ('Saved-audio check: PASS / visible=' + $visible.Count)

    $safeText = 'ここで待つ。'
    $generated = Invoke-JsonPost -Uri ($appBase + '/generate') -Body @{
        characters = @($character)
        text = $safeText
        auto_emotion = $false
    } -TimeoutSec 600
    if ([string]::IsNullOrWhiteSpace([string]$generated.file)) {
        throw 'Post-migration Requiem WAV generation did not return an output file.'
    }
    Write-Phase2Log ('Post-migration generation: PASS / ' + [string]$generated.file)

    $savedMiB = [Math]::Round(([double]$migration.saved_bytes / 1MB), 2)
    $wavAfter = @(Get-ChildItem -LiteralPath $charRoot -File -Filter '*.wav' -ErrorAction Stop).Count
    $flacAfter = @(Get-ChildItem -LiteralPath $charRoot -File -Filter '*.flac' -ErrorAction Stop).Count
    Write-Phase2Log ('Storage reduced: ' + [string]$savedMiB + ' MiB')
    Write-Phase2Log ('Direct file counts after migration: wav=' + $wavAfter + ' / flac=' + $flacAfter)
    Write-Phase2Log 'PHASE2_REQUIEM=SUCCESS'
    exit 0
}
catch {
    Write-Phase2Log ('ERROR: ' + $_.Exception.Message)
    if ($migrationCommitted) {
        Write-Phase2Log 'PHASE2_REQUIEM=MIGRATED_VERIFICATION_FAILED'
        exit 2
    }
    Write-Phase2Log 'PHASE2_REQUIEM=STOPPED'
    exit 1
}
