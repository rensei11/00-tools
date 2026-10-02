$ErrorActionPreference = 'Stop'

$manifestUrl = 'https://raw.githubusercontent.com/rensei11/00-tools/main/black-codex-recovery/ai_voice_entry_repair_v9.json'
$expectedVersion = '2026-10-02-v9-entry-repair'
$logPath = Join-Path $env:TEMP 'rensei_ai_voice_direct_repair_log.txt'
$appUrl = 'http://127.0.0.1:7862/'

$repairFiles = @(
    'Start Fandom Tool.cmd',
    'start_fandom_tool.cmd',
    'start_local.ps1',
    'startup_update_check.ps1',
    'update_and_start.ps1',
    'updater_bootstrap.ps1'
)

function Write-Log {
    param([string]$Line)
    [System.IO.File]::AppendAllText(
        $logPath,
        ([DateTime]::Now.ToString('s') + ' ' + $Line + [Environment]::NewLine),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Test-ToolDir {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'app.py') -PathType Leaf)) {
        return $false
    }

    foreach ($marker in @('start_local.ps1', 'updater_bootstrap.ps1', 'start_fandom_tool.cmd', 'Start Fandom Tool.cmd')) {
        if (Test-Path -LiteralPath (Join-Path $Path $marker) -PathType Leaf) {
            return $true
        }
    }
    return $false
}

function Resolve-ToolDir {
    $candidates = New-Object 'System.Collections.Generic.List[string]'

    foreach ($candidate in @(
        'D:\AI生成ファイル\Irodori-TTS',
        'D:\AI生成ファイル\Irodori-TTS\Fandom音声ツール',
        'D:\_fandom_voice_tool_link'
    )) {
        if (-not $candidates.Contains($candidate)) {
            $candidates.Add($candidate) | Out-Null
        }
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($desktop in @(
            [Environment]::GetFolderPath('Desktop'),
            [Environment]::GetFolderPath('CommonDesktopDirectory')
        )) {
            if (-not $desktop -or -not (Test-Path -LiteralPath $desktop -PathType Container)) {
                continue
            }
            foreach ($shortcut in @(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
                try {
                    $target = [string]$shell.CreateShortcut($shortcut.FullName).TargetPath
                    $leaf = [IO.Path]::GetFileName($target)
                    if ($leaf -in @('start_fandom_tool.cmd', 'Start Fandom Tool.cmd')) {
                        $parent = Split-Path -Parent $target
                        if ($parent -and -not $candidates.Contains($parent)) {
                            $candidates.Add($parent) | Out-Null
                        }
                    }
                } catch {
                }
            }
        }
    } catch {
    }

    foreach ($candidate in @($candidates)) {
        if (Test-ToolDir $candidate) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $root = 'D:\AI生成ファイル\Irodori-TTS'
    if (Test-Path -LiteralPath $root -PathType Container) {
        foreach ($launcher in @(
            Get-ChildItem -LiteralPath $root -Filter 'start_fandom_tool.cmd' -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 30
        )) {
            $candidate = $launcher.Directory.FullName
            if (Test-ToolDir $candidate) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }
    }

    throw 'AI voice tool folder could not be resolved from the known D-drive root, junction, or desktop shortcut.'
}

function Write-RepairFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $parent = Split-Path -Parent $Path
    if ($parent) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }

    if ($extension -eq '.cmd' -or $extension -eq '.bat') {
        foreach ($character in $Content.ToCharArray()) {
            if ([int][char]$character -gt 127) {
                throw ('Non-ASCII text was found in command file payload: ' + [IO.Path]::GetFileName($Path))
            }
        }
        [IO.File]::WriteAllText($Path, $Content, [Text.Encoding]::ASCII)
        return
    }

    if ($extension -eq '.ps1') {
        $text = $Content.TrimStart([char]0xFEFF)
        [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($true)))

        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$tokens,
            [ref]$errors
        )
        if (@($errors).Count -ne 0) {
            throw ('Windows PowerShell 5.1 parse failed for: ' + [IO.Path]::GetFileName($Path))
        }

        $bytes = [IO.File]::ReadAllBytes($Path)
        if (
            $bytes.Length -ge 6 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF -and
            $bytes[3] -eq 0xEF -and $bytes[4] -eq 0xBB -and $bytes[5] -eq 0xBF
        ) {
            throw ('Duplicate UTF-8 BOM detected in: ' + [IO.Path]::GetFileName($Path))
        }
        return
    }

    throw ('Unsupported repair file type: ' + $extension)
}

function Test-AppReady {
    try {
        $response = Invoke-WebRequest -Uri $appUrl -UseBasicParsing -TimeoutSec 2
        return ($response.StatusCode -eq 200)
    } catch {
        return $false
    }
}

try {
    [IO.File]::WriteAllText($logPath, '', (New-Object Text.UTF8Encoding($false)))
    Write-Log 'DIRECT_ENTRY_REPAIR_START'

    $toolDir = Resolve-ToolDir
    Write-Log ('TOOL_DIR=' + $toolDir)

    $response = Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -TimeoutSec 60
    $payload = $response.Content | ConvertFrom-Json

    if ([string]$payload.version -ne $expectedVersion) {
        throw ('Unexpected public version: ' + [string]$payload.version)
    }

    foreach ($name in $repairFiles) {
        if ($null -eq $payload.files.PSObject.Properties[$name]) {
            throw ('Required repair file is missing from public payload: ' + $name)
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupRoot = Join-Path $toolDir ('_repair_backup\entry_' + $stamp)
    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null

    foreach ($name in $repairFiles) {
        $destination = Join-Path $toolDir $name
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            Copy-Item -LiteralPath $destination -Destination (Join-Path $backupRoot $name) -Force
        }
        $content = [string]$payload.files.PSObject.Properties[$name].Value
        Write-RepairFile -Path $destination -Content $content
    }

    Write-Log ('SHELL_REPAIRED version=' + $expectedVersion)

    $launcher = Join-Path $toolDir 'Start Fandom Tool.cmd'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw 'Supported launcher was not restored.'
    }

    $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @(
        '/d',
        '/c',
        ('""{0}""' -f $launcher)
    ) -WorkingDirectory $toolDir -PassThru -Wait

    if ($process.ExitCode -ne 0) {
        throw ('Supported launcher exited with code ' + $process.ExitCode)
    }

    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (Test-AppReady) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 1
    }

    if (-not $ready) {
        throw 'Supported launcher returned success but localhost was not ready.'
    }

    Write-Log 'DIRECT_ENTRY_REPAIR_SUCCESS'
    Write-Host 'AI音声ツールの入口を復旧し、起動確認まで成功しました。'
    exit 0
}
catch {
    Write-Log ('DIRECT_ENTRY_REPAIR_FAILED ' + $_.Exception.Message)
    Write-Host 'AI音声ツールの入口復旧は完了しませんでした。'
    Write-Host $_.Exception.Message
    Write-Host ''
    Write-Host '詳細ログ:'
    Write-Host $logPath
    exit 1
}
