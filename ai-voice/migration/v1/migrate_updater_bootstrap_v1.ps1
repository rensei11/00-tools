param(
    [string]$SearchRoot = 'D:\AI生成ファイル\Irodori-TTS',
    [string]$BundlePath = '',
    [string]$ExpectedBundleHash = 'd66151ec1c786ae14682b8a8b5dd5a6b9e389cf991f0a62f90b14872fa521874',
    [string]$BootstrapIndexPath = '',
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$bundleUrl = 'https://raw.githubusercontent.com/rensei11/00-tools/5a9032a3f4921fab95d7b0db68dec5ba58b8a54a/ai-voice/bootstrap/v1/bootstrap-bundle.json'
$requiredFiles = @(
    'Start Fandom Tool.cmd',
    'start_fandom_tool.cmd',
    'updater_bootstrap.ps1',
    'startup_update_check.ps1',
    'update_and_start.ps1'
)
$excludedDirectoryNames = @(
    '音声',
    '参照音声',
    '事前計算',
    '調査用データ',
    '_backup',
    '_repair_backup',
    '_update_repo',
    '_update_zip',
    '_update_bootstrap_work',
    '_updater_bootstrap_backup',
    'node_modules',
    '.git'
)

function Get-CandidateScore {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath (Join-Path $Path 'app.py') -PathType Leaf)) {
        return -1
    }

    $score = 0
    $markers = @(
        @('voice_core.py', 8),
        @('conversation_mode.py', 5),
        @('chatgpt_link.py', 5),
        @('acquisition_core.py', 5),
        @('paths.py', 4),
        @('start_local.ps1', 4),
        @('speakers.json', 3),
        @('Start Fandom Tool.cmd', 2),
        @('start_fandom_tool.cmd', 2),
        @('update_and_start.ps1', 1)
    )
    foreach ($marker in $markers) {
        if (Test-Path -LiteralPath (Join-Path $Path ([string]$marker[0])) -PathType Leaf) {
            $score += [int]$marker[1]
        }
    }
    return $score
}

function Resolve-ToolRoot {
    param([string]$Root)

    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) {
        throw ('Search root was not found: ' + $fullRoot)
    }

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue([pscustomobject]@{ Path = $fullRoot; Depth = 0 })

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $path = [string]$item.Path
        $depth = [int]$item.Depth

        $score = Get-CandidateScore $path
        if ($score -ge 10) {
            $candidates.Add([pscustomobject]@{ Path = $path; Score = $score }) | Out-Null
        }

        if ($depth -ge 6) {
            continue
        }

        foreach ($child in @(Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue)) {
            if ($excludedDirectoryNames -contains $child.Name) {
                continue
            }
            $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = $depth + 1 })
        }
    }

    if ($candidates.Count -eq 0) {
        throw ('AI voice tool program folder was not found under: ' + $fullRoot)
    }

    $ranked = @($candidates | Sort-Object @{ Expression = { -[int]$_.Score } }, @{ Expression = { ([string]$_.Path).Length } }, @{ Expression = { [string]$_.Path } })

    if ($ranked.Count -gt 1 -and [int]$ranked[0].Score -eq [int]$ranked[1].Score) {
        $paths = @($ranked | Select-Object -First 5 | ForEach-Object { [string]$_.Path })
        throw ('Multiple equally strong AI voice tool folders were found: ' + ($paths -join ' | '))
    }

    return [string]$ranked[0].Path
}

function Get-Sha256 {
    param([string]$Path)
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToLowerInvariant()
}

function Write-StableFile {
    param([string]$Path, [string]$Content)

    $contentWithoutBom = $Content.TrimStart([char]0xFEFF)
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    if ($extension -eq '.cmd' -or $extension -eq '.bat') {
        foreach ($char in $contentWithoutBom.ToCharArray()) {
            if ([int][char]$char -gt 127) {
                throw ('Non-ASCII text in batch launcher: ' + [System.IO.Path]::GetFileName($Path))
            }
        }
        [System.IO.File]::WriteAllText($Path, $contentWithoutBom, [System.Text.Encoding]::ASCII)
        return
    }

    if ($extension -eq '.ps1') {
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($Path, $contentWithoutBom, $utf8Bom)
        return
    }

    throw ('Unsupported stable updater file type: ' + $Path)
}

function Assert-PowerShellParses {
    param([string]$Path)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw ('PowerShell parse failed after bootstrap migration: ' + $errors[0].Message)
    }
}

$toolRoot = $null
$logPath = $null
$bundleTemp = $null

try {
    Write-Host 'MIGRATION_STAGE resolve-tool-root'
    $toolRoot = Resolve-ToolRoot $SearchRoot
    Write-Host ('MIGRATION_STAGE tool-root=' + $toolRoot)
    $logPath = Join-Path $toolRoot '_updater_bootstrap_migration.log'
    [System.IO.File]::WriteAllText($logPath, '', (New-Object System.Text.UTF8Encoding($false)))

    Add-Content -LiteralPath $logPath -Value 'STAGE=prepare-bundle' -Encoding UTF8
    Write-Host 'MIGRATION_STAGE prepare-bundle'
    $bundleTemp = Join-Path $toolRoot '_updater_bootstrap_bundle_v1.json'
    if ([string]::IsNullOrWhiteSpace($BundlePath)) {
        Invoke-WebRequest -Uri $bundleUrl -OutFile $bundleTemp -UseBasicParsing -TimeoutSec 60
    } else {
        $source = [System.IO.Path]::GetFullPath($BundlePath)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw ('Bootstrap bundle was not found: ' + $source)
        }
        Copy-Item -LiteralPath $source -Destination $bundleTemp -Force
    }

    Add-Content -LiteralPath $logPath -Value 'STAGE=verify-bundle' -Encoding UTF8
    Write-Host 'MIGRATION_STAGE verify-bundle'
    $actualHash = Get-Sha256 $bundleTemp
    if ($actualHash -ne $ExpectedBundleHash.ToLowerInvariant()) {
        throw ('Bootstrap bundle SHA-256 mismatch. expected=' + $ExpectedBundleHash + ' actual=' + $actualHash)
    }

    $bundle = [System.IO.File]::ReadAllText($bundleTemp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$bundle.schema -ne 1 -or [string]$bundle.version -ne 'bootstrap-v1') {
        throw 'Unsupported bootstrap bundle.'
    }

    foreach ($name in $requiredFiles) {
        if ($null -eq $bundle.files.PSObject.Properties[$name]) {
            throw ('Bootstrap bundle is missing: ' + $name)
        }
    }

    Add-Content -LiteralPath $logPath -Value 'STAGE=install-stable-shell' -Encoding UTF8
    Write-Host 'MIGRATION_STAGE install-stable-shell'
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupRoot = Join-Path $toolRoot ('_updater_bootstrap_backup\migration-v1-' + $stamp)
    [System.IO.Directory]::CreateDirectory($backupRoot) | Out-Null

    foreach ($name in $requiredFiles) {
        $destination = Join-Path $toolRoot $name
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            Copy-Item -LiteralPath $destination -Destination (Join-Path $backupRoot $name) -Force
        }
        Write-StableFile -Path $destination -Content ([string]$bundle.files.PSObject.Properties[$name].Value)
    }

    Add-Content -LiteralPath $logPath -Value 'STAGE=parse-stable-shell' -Encoding UTF8
    Write-Host 'MIGRATION_STAGE parse-stable-shell'
    Assert-PowerShellParses (Join-Path $toolRoot 'updater_bootstrap.ps1')
    Assert-PowerShellParses (Join-Path $toolRoot 'startup_update_check.ps1')
    Assert-PowerShellParses (Join-Path $toolRoot 'update_and_start.ps1')

    Add-Content -LiteralPath $logPath -Value 'STAGE=run-bootstrap' -Encoding UTF8
    Write-Host 'MIGRATION_STAGE run-bootstrap'
    $bootstrap = Join-Path $toolRoot 'updater_bootstrap.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bootstrap, '-ForceUpdate')
    if ($NoLaunch) {
        $arguments += '-NoLaunch'
    }
    if (-not [string]::IsNullOrWhiteSpace($BootstrapIndexPath)) {
        $arguments += '-IndexPath'
        $arguments += [System.IO.Path]::GetFullPath($BootstrapIndexPath)
    }

    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ('Independent updater bootstrap returned exit code ' + $LASTEXITCODE)
    }
    Add-Content -LiteralPath $logPath -Value 'STAGE=bootstrap-complete' -Encoding UTF8
    Write-Host 'MIGRATION_STAGE bootstrap-complete'

    @(
        'MIGRATION_SUCCESS'
        ('TOOL_ROOT=' + $toolRoot)
        ('BACKUP=' + $backupRoot)
    ) | Add-Content -LiteralPath $logPath -Encoding UTF8

    Write-Host 'AI voice updater bootstrap migration completed.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($logPath)) {
        $fallback = [System.IO.Path]::GetFullPath($SearchRoot)
        if (Test-Path -LiteralPath $fallback -PathType Container) {
            $logPath = Join-Path $fallback '_updater_bootstrap_migration.log'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($logPath)) {
        @('MIGRATION_FAILED', $message) | Set-Content -LiteralPath $logPath -Encoding UTF8
    }
    Write-Host 'AI voice updater bootstrap migration failed.'
    Write-Host $message
    exit 1
}
finally {
    if ($bundleTemp -and (Test-Path -LiteralPath $bundleTemp -PathType Leaf)) {
        Remove-Item -LiteralPath $bundleTemp -Force -ErrorAction SilentlyContinue
    }
}
