param(
    [string]$ToolRoot = 'D:\AI生成ファイル\Irodori-TTS\Fandom音声ツール'
)

$ErrorActionPreference = 'Stop'
$sourceUrl = 'https://raw.githubusercontent.com/rensei11/05-AI-voice/main/update_and_start.ps1'
$destination = Join-Path $ToolRoot 'update_and_start.ps1'
$pending = Join-Path $ToolRoot '_update_and_start.repair-pending.ps1'

function Assert-PowerShellParses {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if (@($errors).Count -ne 0) {
        throw ('PowerShell parse failed: ' + $errors[0].Message)
    }
}

try {
    if (-not (Test-Path -LiteralPath $ToolRoot -PathType Container)) {
        throw ('AI voice tool folder was not found: ' + $ToolRoot)
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ToolRoot 'app.py') -PathType Leaf)) {
        throw ('AI voice app.py was not found in: ' + $ToolRoot)
    }

    Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue

    $headers = @{
        'User-Agent' = 'Rensei-AI-Voice-Repair'
        'Cache-Control' = 'no-cache'
        'Pragma' = 'no-cache'
    }
    Invoke-WebRequest -Uri $sourceUrl -OutFile $pending -UseBasicParsing -Headers $headers -TimeoutSec 30

    Assert-PowerShellParses $pending
    $text = [System.IO.File]::ReadAllText($pending, [System.Text.Encoding]::UTF8)
    foreach ($required in @(
        'Rensei-AI-Voice-Update-Button',
        'raw.githubusercontent.com/rensei11/05-AI-voice/main/updater_bootstrap.ps1',
        '-ForceUpdate',
        '-NoBrowser'
    )) {
        if ($text.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw ('Downloaded update button script is missing: ' + $required)
        }
    }
    if ($text.IndexOf("Join-Path `$PSScriptRoot 'updater_bootstrap.ps1'", [StringComparison]::Ordinal) -ge 0) {
        throw 'Downloaded update button script still depends on the local updater bootstrap.'
    }

    $sourceHash = (Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $pending -Destination $destination -Force
    Assert-PowerShellParses $destination
    $installedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($installedHash -ne $sourceHash) {
        throw 'Installed update button script hash does not match downloaded source.'
    }

    Write-Host 'UPDATE_BUTTON_REPAIR=SUCCESS'
    Write-Host ('INSTALLED=' + $destination)
    exit 0
}
catch {
    Write-Host 'UPDATE_BUTTON_REPAIR=FAILED'
    Write-Host $_.Exception.Message
    exit 1
}
finally {
    Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
}
