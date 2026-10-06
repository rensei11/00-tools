$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logPath = Join-Path $env:TEMP 'rensei_franz_phase2_flac_log.txt'
$moduleUrl = 'https://raw.githubusercontent.com/rensei11/05-AI-voice/06b40de143f1f7d34d5157454651f02712b20d82/standard_reference_service.py'
$appBase = 'http://127.0.0.1:18762'
$referenceRootWin = 'D:\AI生成ファイル\Irodori-TTS\参照音声'
$character = 'フランツ'
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
    Write-Phase2Log 'Phase2 Franz legacy migration: START'

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
        throw 'Franz character folder was not found. No migration was started.'
    }
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        throw 'Franz audio-list metadata was not found. No migration was started.'
    }

    $wavCount = @(Get-ChildItem -LiteralPath $charRoot -File -Filter '*.wav' -ErrorAction Stop).Count
    $flacCount = @(Get-ChildItem -LiteralPath $charRoot -File -Filter '*.flac' -ErrorAction Stop).Count
    if ($wavCount -ne 20 -or $flacCount -ne 0) {
        throw ('Franz audio counts changed from the audited state. wav=' + $wavCount + ' flac=' + $flacCount + '. No migration was started.')
    }

    foreach ($seconds in @(30, 60, 90, 120)) {
        $pt = Join-Path $refDir (($seconds.ToString()) + '秒.pt')
        $json = Join-Path $refDir (($seconds.ToString()) + '秒.json')
        if (-not (Test-Path -LiteralPath $pt -PathType Leaf) -or -not (Test-Path -LiteralPath $json -PathType Leaf)) {
            throw ('Franz ' + $seconds + '-second reference pair is incomplete. No migration was started.')
        }
    }
    if (-not (Test-Path -LiteralPath $emotionCache -PathType Leaf)) {
        throw 'Franz emotion2vec cache was not found. No migration was started.'
    }

    try {
        $speakersBefore = Invoke-RestMethod -Uri ($appBase + '/speakers') -Method Get -TimeoutSec 3
    }
    catch {
        throw 'AI voice tool is not running. Start it first, then run this file again. No migration was started.'
    }
    if (@($speakersBefore.speakers) -notcontains $character) {
        throw 'Franz is not available for generation before migration. No migration was started.'
    }
    Write-Phase2Log ('Preflight: audited Franz state confirmed / wav=' + $wavCount + ' / flac=' + $flacCount)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $moduleText = (Invoke-WebRequest -UseBasicParsing -Uri $moduleUrl -TimeoutSec 30).Content
    foreach ($required in @(
        "PHASE2_LEGACY_PILOT_CHARACTER = 'フランツ'",
        'def _phase2_legacy_pilot_preflight',
        'def migrate_legacy_existing_wavs',
        'wav_cleanup_leftovers'
    )) {
        if ($moduleText.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw ('Pinned migration module is missing required guard: ' + $required)
        }
    }
    $moduleB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($moduleText))

    $pythonTemplate = @'
import base64
import json
from pathlib import Path

source = base64.b64decode("__MODULE_B64__").decode("utf-8")
namespace = {"__name__": "standard_reference_service"}
exec(compile(source, "standard_reference_service.py", "exec"), namespace)

StandardReferenceService = namespace["StandardReferenceService"]

class Collector:
    def __init__(self, root):
        self.reference_root = Path(root)

    def character_metadata_path(self, name):
        return self.reference_root / name / "\u97f3\u58f0\u4e00\u89a7.json"

    @staticmethod
    def _record_filename(item):
        raw = str(item.get("local_filename") or item.get("filename") or item.get("path") or "").strip()
        return raw.replace("\\", "/").rsplit("/", 1)[-1]

    @staticmethod
    def _read_json(path, default):
        try:
            return json.loads(Path(path).read_text(encoding="utf-8-sig"))
        except Exception:
            return default

    @staticmethod
    def _write_json(path, data):
        path = Path(path)
        temp = path.with_suffix(path.suffix + ".tmp")
        temp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        temp.replace(path)

root = Path("/mnt/d/AI\u751f\u6210\u30d5\u30a1\u30a4\u30eb/Irodori-TTS/\u53c2\u7167\u97f3\u58f0")
character = "\u30d5\u30e9\u30f3\u30c4"
service = StandardReferenceService(Collector(root))
result = service.migrate_legacy_existing_wavs(character)
print("PHASE2_RESULT=" + json.dumps(result, ensure_ascii=True, separators=(",", ":")))
'@
    $python = $pythonTemplate.Replace('__MODULE_B64__', $moduleB64)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wsl
    $psi.Arguments = ('-e ' + $pythonPath + ' -')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $process.StandardInput.Write($python)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Phase2Log ('WSL stdout: ' + ($stdout.Trim() -replace "[\r\n]+", ' / '))
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-Phase2Log ('WSL stderr: ' + ($stderr.Trim() -replace "[\r\n]+", ' / '))
    }
    if ($process.ExitCode -ne 0) {
        throw ('Migration process stopped with exit code ' + $process.ExitCode + '.')
    }

    $resultLine = @($stdout -split "[\r\n]+" | Where-Object { $_ -like 'PHASE2_RESULT=*' } | Select-Object -Last 1)
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
        throw 'Post-migration Franz WAV generation did not return an output file.'
    }
    Write-Phase2Log ('Post-migration generation: PASS / ' + [string]$generated.file)

    $savedMiB = [Math]::Round(([double]$migration.saved_bytes / 1MB), 2)
    $wavAfter = @(Get-ChildItem -LiteralPath $charRoot -File -Filter '*.wav' -ErrorAction Stop).Count
    $flacAfter = @(Get-ChildItem -LiteralPath $charRoot -File -Filter '*.flac' -ErrorAction Stop).Count
    Write-Phase2Log ('Storage reduced: ' + [string]$savedMiB + ' MiB')
    Write-Phase2Log ('Direct file counts after migration: wav=' + $wavAfter + ' / flac=' + $flacAfter)
    Write-Phase2Log 'PHASE2_FRANZ=SUCCESS'
    exit 0
}
catch {
    Write-Phase2Log ('ERROR: ' + $_.Exception.Message)
    if ($migrationCommitted) {
        Write-Phase2Log 'PHASE2_FRANZ=MIGRATED_VERIFICATION_FAILED'
        exit 2
    }
    Write-Phase2Log 'PHASE2_FRANZ=STOPPED'
    exit 1
}
