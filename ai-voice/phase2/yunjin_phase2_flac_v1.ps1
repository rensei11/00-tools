$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logPath = Join-Path $env:TEMP 'rensei_yunjin_phase2_flac_log.txt'
$moduleUrl = 'https://raw.githubusercontent.com/rensei11/05-AI-voice/337cd9042e9855f1e02dffb7390109989d6468ad/standard_reference_service.py'
$appBase = 'http://127.0.0.1:18762'

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
    Write-Phase2Log 'Phase2 Yun Jin migration: START'

    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $wsl -PathType Leaf)) {
        throw 'WSL was not found. No audio files were changed.'
    }

    $pythonPath = '/home/rensei/Irodori-TTS/.venv/bin/python'
    $pythonCheck = & $wsl -e test -x $pythonPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Irodori Python was not found in WSL. No audio files were changed.'
    }

    $char = ([string][char]0x96F2) + ([string][char]0x83EB)

    try {
        $speakers = Invoke-RestMethod -Uri ($appBase + '/speakers') -Method Get -TimeoutSec 3
    }
    catch {
        throw 'AI voice tool is not running. Start it first, then run this file again. No audio files were changed.'
    }
    if (@($speakers.speakers) -notcontains $char) {
        throw 'Yun Jin is not currently available in the voice-generation speaker list. No audio files were changed.'
    }
    Write-Phase2Log 'Preflight: live app and Yun Jin reference are available.'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $moduleText = (Invoke-WebRequest -UseBasicParsing -Uri $moduleUrl -TimeoutSec 30).Content
    foreach ($required in @(
        "PHASE2_PILOT_CHARACTER = '雲菫'",
        'def _phase2_pilot_preflight',
        'def migrate_existing_wavs',
        'phase2_pcm_verified'
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
            return json.loads(Path(path).read_text(encoding="utf-8"))
        except Exception:
            return default

    @staticmethod
    def _write_json(path, data):
        path = Path(path)
        temp = path.with_suffix(path.suffix + ".tmp")
        temp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        temp.replace(path)

root = Path("/mnt/d/AI\u751f\u6210\u30d5\u30a1\u30a4\u30eb/Irodori-TTS/\u53c2\u7167\u97f3\u58f0")
character = "\u96f2\u83eb"
service = StandardReferenceService(Collector(root))
result = service.migrate_existing_wavs(character)
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
        throw ('Migration process stopped safely with exit code ' + $process.ExitCode + '.')
    }

    $resultLine = @($stdout -split "[\r\n]+" | Where-Object { $_ -like 'PHASE2_RESULT=*' } | Select-Object -Last 1)
    if (-not $resultLine) {
        throw 'Migration result was not returned.'
    }
    $migration = ($resultLine.Substring('PHASE2_RESULT='.Length)) | ConvertFrom-Json

    $saved = Invoke-JsonPost -Uri ($appBase + '/voice/load') -Body @{ character = $char } -TimeoutSec 15
    $visible = @($saved.records | ForEach-Object { [string]$_.filename })
    foreach ($entry in @($migration.converted)) {
        if ($visible -notcontains [string]$entry.flac) {
            throw ('Converted FLAC is not visible in the saved-audio list: ' + [string]$entry.flac)
        }
        if ($visible -contains [string]$entry.wav) {
            throw ('Old WAV is still visible after migration: ' + [string]$entry.wav)
        }
    }
    Write-Phase2Log ('Saved-audio check: PASS / visible=' + $visible.Count)

    $safeText = ([string][char]0x3053) + ([string][char]0x3053) + ([string][char]0x3067) + ([string][char]0x5F85) + ([string][char]0x3064) + ([string][char]0x3002)
    $generated = Invoke-JsonPost -Uri ($appBase + '/generate') -Body @{
        characters = @($char)
        text = $safeText
        auto_emotion = $false
    } -TimeoutSec 600
    if ([string]::IsNullOrWhiteSpace([string]$generated.file)) {
        throw 'Post-migration Yun Jin WAV generation did not return an output file.'
    }
    Write-Phase2Log ('Post-migration generation: PASS / ' + [string]$generated.file)

    $savedMiB = [Math]::Round(([double]$migration.saved_bytes / 1MB), 2)
    Write-Phase2Log ('Converted WAV files: ' + [string]$migration.converted_count)
    Write-Phase2Log ('Storage reduced: ' + [string]$savedMiB + ' MiB')
    Write-Phase2Log ('Skipped WAV files: ' + @($migration.skipped).Count)
    Write-Phase2Log ('120-second reference SHA-256 unchanged: ' + [string]$migration.reference_sha256)
    Write-Phase2Log 'PHASE2_YUNJIN=SUCCESS'
    exit 0
}
catch {
    Write-Phase2Log ('ERROR: ' + $_.Exception.Message)
    Write-Phase2Log 'PHASE2_YUNJIN=STOPPED'
    exit 1
}
