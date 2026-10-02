$ErrorActionPreference = 'Stop'

$manifestUrl = 'https://raw.githubusercontent.com/rensei11/00-tools/main/fandom-voice-tool-latest.json'
$expectedVersion = '2026-10-02-v7'
$logPath = Join-Path $env:TEMP 'rensei_ai_voice_direct_repair_log.txt'

function Write-TextFile {
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
        [IO.File]::WriteAllText($Path, $Content, [Text.Encoding]::ASCII)
        return
    }

    if ($extension -eq '.ps1') {
        $utf8Bom = New-Object Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($Path, $Content, $utf8Bom)
        return
    }

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Test-ToolDir {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath (Join-Path $Path 'app.py') -PathType Leaf)) {
        return $false
    }

    $markers = @(
        'start_local.ps1',
        'startup_update_check.ps1',
        'update_and_start.ps1',
        'Start Fandom Tool.cmd',
        'start_fandom_tool.cmd'
    )

    foreach ($marker in $markers) {
        if (Test-Path -LiteralPath (Join-Path $Path $marker) -PathType Leaf) {
            return $true
        }
    }

    return $false
}

function Resolve-ToolDir {
    $root = 'D:\AI生成ファイル\Irodori-TTS'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw 'D:\AI生成ファイル\Irodori-TTS was not found.'
    }

    $preferred = @(
        (Join-Path $root 'Fandom音声ツール'),
        $root
    )

    foreach ($candidate in $preferred) {
        if (Test-ToolDir $candidate) {
            return $candidate
        }
    }

    $rootDepth = ($root.TrimEnd('\') -split '\\').Count
    $matches = New-Object 'System.Collections.Generic.List[string]'

    foreach ($app in @(Get-ChildItem -LiteralPath $root -Filter 'app.py' -File -Recurse -ErrorAction SilentlyContinue)) {
        $dir = $app.Directory.FullName
        $depth = ($dir.TrimEnd('\') -split '\\').Count - $rootDepth
        if ($depth -gt 4) {
            continue
        }
        if (Test-ToolDir $dir) {
            if (-not $matches.Contains($dir)) {
                $matches.Add($dir) | Out-Null
            }
        }
    }

    if ($matches.Count -eq 1) {
        return $matches[0]
    }

    if ($matches.Count -gt 1) {
        $ranked = @(
            $matches |
                Sort-Object @{
                    Expression = {
                        $score = 0
                        if (Test-Path -LiteralPath (Join-Path $_ 'update_and_start.ps1') -PathType Leaf) { $score += 4 }
                        if (Test-Path -LiteralPath (Join-Path $_ 'startup_update_check.ps1') -PathType Leaf) { $score += 3 }
                        if (Test-Path -LiteralPath (Join-Path $_ 'Start Fandom Tool.cmd') -PathType Leaf) { $score += 2 }
                        if (Test-Path -LiteralPath (Join-Path $_ 'start_fandom_tool.cmd') -PathType Leaf) { $score += 1 }
                        return -$score
                    }
                },
                @{ Expression = { $_.Length } }
        )

        if ($ranked.Count -ge 1) {
            return [string]$ranked[0]
        }
    }

    throw 'AI voice tool folder was not found under D:\AI生成ファイル\Irodori-TTS.'
}

try {
    $toolDir = Resolve-ToolDir

    $response = Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -TimeoutSec 30
    $payload = $response.Content | ConvertFrom-Json

    if ([string]$payload.version -ne $expectedVersion) {
        throw ('Unexpected public version: ' + [string]$payload.version)
    }

    $properties = @($payload.files.PSObject.Properties)
    if ($properties.Count -ne 130) {
        throw ('Unexpected public file count: ' + $properties.Count)
    }

    foreach ($required in @(
        'app.py',
        'Start Fandom Tool.cmd',
        'start_fandom_tool.cmd',
        'start_local.ps1',
        'startup_update_check.ps1',
        'update_and_start.ps1'
    )) {
        if ($null -eq $payload.files.PSObject.Properties[$required]) {
            throw ('Required repair file is missing from public payload: ' + $required)
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupRoot = Join-Path $toolDir ('_repair_backup\' + $stamp)
    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null

    foreach ($property in $properties) {
        $relative = [string]$property.Name
        $content = [string]$property.Value

        if ([string]::IsNullOrWhiteSpace($relative)) {
            throw 'Public payload contains an empty path.'
        }
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains('..')) {
            throw ('Unsafe public payload path: ' + $relative)
        }

        $destination = Join-Path $toolDir $relative
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $backup = Join-Path $backupRoot $relative
            $backupParent = Split-Path -Parent $backup
            if ($backupParent) {
                [IO.Directory]::CreateDirectory($backupParent) | Out-Null
            }
            Copy-Item -LiteralPath $destination -Destination $backup -Force
        }

        Write-TextFile -Path $destination -Content $content
    }

    $appPath = Join-Path $toolDir 'app.py'
    $versionLine = Get-Content -LiteralPath $appPath |
        Where-Object { $_ -match '^APP_VERSION\s*=' } |
        Select-Object -First 1

    if (-not $versionLine -or $versionLine -notmatch [regex]::Escape($expectedVersion)) {
        throw 'Repair wrote files but app.py did not report v7.'
    }

    @(
        'DIRECT_REPAIR_SUCCESS'
        ('VERSION=' + $expectedVersion)
        ('TOOL_DIR=' + $toolDir)
        ('BACKUP=' + $backupRoot)
    ) | Set-Content -LiteralPath $logPath -Encoding UTF8

    $launcher = Join-Path $toolDir 'Start Fandom Tool.cmd'
    Start-Process -FilePath $launcher -WorkingDirectory $toolDir
    exit 0
}
catch {
    @(
        'DIRECT_REPAIR_FAILED'
        $_.Exception.Message
    ) | Set-Content -LiteralPath $logPath -Encoding UTF8

    Write-Host 'AI voice tool direct repair failed.'
    Write-Host $_.Exception.Message
    Write-Host ''
    Write-Host 'Details were saved to:'
    Write-Host $logPath
    exit 1
}
