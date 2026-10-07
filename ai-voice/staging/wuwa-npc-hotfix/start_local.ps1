param(
    [switch]$NoBrowser,
    [switch]$SkipUpdateCheck
)

$ErrorActionPreference = 'Stop'

$url = 'http://127.0.0.1:7862/'
$toolDir = $PSScriptRoot
$startupLogPath = Join-Path $toolDir '_last_startup.log'
$startupStdoutPath = Join-Path $toolDir '_last_startup_stdout.log'
$pythonPath = '/home/rensei/Irodori-TTS/.venv/bin/python'
$extensionDistributionHelper = Join-Path $toolDir 'complete_extension_distribution.ps1'
$updatePayloadPath = Join-Path $toolDir '_update_payload.json'

function Test-LocalApp {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
        return ($response.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Wait-LocalApp {
    for ($attempt = 0; $attempt -lt 80; $attempt++) {
        if (Test-LocalApp) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-EncodedToolPath {
    $fullPath = [System.IO.Path]::GetFullPath($toolDir)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($fullPath)
    return [System.Convert]::ToBase64String($bytes)
}

function Test-EncodedToolPathInWsl {
    param([string]$EncodedPath)

    $probeCode = 'import base64,ntpath,os,sys;p=base64.b64decode(sys.argv[1]).decode("utf-8");d,t=ntpath.splitdrive(p);w=("/mnt/"+d[0].lower()+"/"+t.lstrip("\\/").replace("\\","/")) if d else "";print("FANDOM_TOOL_OK" if os.path.isdir(w) else "FANDOM_TOOL_MISSING")'  # storage-policy: external-read
    $probe = & wsl.exe -d Ubuntu -- $pythonPath -c $probeCode $EncodedPath 2>$null
    return (($LASTEXITCODE -eq 0) -and (($probe -join '') -eq 'FANDOM_TOOL_OK'))
}

function Start-AppWithEncodedToolPath {
    param([string]$EncodedPath)

    $startCode = 'import base64,ntpath,os,sys;p=base64.b64decode(sys.argv[1]).decode("utf-8");d,t=ntpath.splitdrive(p);w=("/mnt/"+d[0].lower()+"/"+t.lstrip("\\/").replace("\\","/")) if d else "";os.chdir(w);os.execv(sys.executable,[sys.executable,"app_wuwa.py"])'  # storage-policy: external-read
    $arguments = @('-d', 'Ubuntu', '--', $pythonPath, '-c', $startCode, $EncodedPath)
    Start-Process -FilePath 'wsl.exe' -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $startupStdoutPath -RedirectStandardError $startupLogPath | Out-Null
}

function Write-StartupFailureLog {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $startupLogPath) {
        $text = Get-Content -LiteralPath $startupLogPath -Raw -ErrorAction SilentlyContinue
        if ($text) {
            $parts.Add($text.TrimEnd()) | Out-Null
        }
    }
    if (Test-Path -LiteralPath $startupStdoutPath) {
        $text = Get-Content -LiteralPath $startupStdoutPath -Raw -ErrorAction SilentlyContinue
        if ($text) {
            $parts.Add($text.TrimEnd()) | Out-Null
        }
    }
    if ($parts.Count -gt 0) {
        Set-Content -LiteralPath $startupLogPath -Value ($parts -join [Environment]::NewLine) -Encoding UTF8
    }
}

try {
    if (
        $SkipUpdateCheck -and
        (Test-Path -LiteralPath $extensionDistributionHelper) -and
        (Test-Path -LiteralPath $updatePayloadPath)
    ) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $extensionDistributionHelper
        if ($LASTEXITCODE -ne 0) {
            throw 'Chrome extension distribution completion failed.'
        }
    }

    if (Test-LocalApp) {
        if (-not $NoBrowser) {
            Start-Process -FilePath $url -Verb Open
        }
        exit 0
    }

    $appPath = Join-Path $toolDir 'app_wuwa.py'
    if (-not (Test-Path -LiteralPath $appPath)) {
        throw "app_wuwa.py was not found: $appPath"
    }

    Remove-Item -LiteralPath $startupLogPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startupStdoutPath -Force -ErrorAction SilentlyContinue

    $encodedToolPath = Get-EncodedToolPath
    if (-not (Test-EncodedToolPathInWsl $encodedToolPath)) {
        throw 'Tool path could not be opened from WSL.'
    }
    Start-AppWithEncodedToolPath $encodedToolPath

    if (-not (Wait-LocalApp)) {
        Write-StartupFailureLog
        throw 'Local startup failed. Check _last_startup.log.'
    }

    if (-not $NoBrowser) {
        Start-Process -FilePath $url -Verb Open
    }
    exit 0
} catch {
    Write-Host $_.Exception.Message
    exit 1
}
