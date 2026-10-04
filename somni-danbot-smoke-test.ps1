Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Wait-BeforeClose {
    try {
        [void](Read-Host "Press Enter to close")
    } catch {
    }
}

function Test-Python {
    param([string]$Path)
    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    & $Path -c "import sys; print(sys.version_info[:2])" *> $null
    return ($LASTEXITCODE -eq 0)
}

$Root = $null
$Log = $null

try {
    Write-Host "DanbotNL standalone smoke test"
    Write-Host "Somni and ComfyUI will not be modified."

    $Somni = Get-ChildItem -Path "D:\*\*\Somni" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $Somni) {
        throw "Somni folder was not found under D:\*\*\Somni."
    }

    $Root = Join-Path $Somni.Parent.FullName "DanbotNL-test"
    New-Item -ItemType Directory -Force -Path $Root | Out-Null

    $Log = Join-Path $Root "run.log"
    "DanbotNL smoke test started: $(Get-Date -Format o)" | Set-Content -Path $Log -Encoding UTF8
    "Somni: $($Somni.FullName)" | Add-Content -Path $Log -Encoding UTF8
    "Test root: $Root" | Add-Content -Path $Log -Encoding UTF8

    $Python = $null

    $PyLauncher = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if ($PyLauncher) {
        foreach ($Version in @("3.13", "3.12", "3.11", "3.10", "3")) {
            $Resolved = & $PyLauncher.Source "-$Version" -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $Resolved) {
                $Resolved = ($Resolved | Select-Object -First 1).Trim()
                if (Test-Python $Resolved) {
                    $Python = $Resolved
                    break
                }
            }
        }
    }

    if (-not $Python) {
        foreach ($Name in @("python.exe", "python3.exe")) {
            $Cmd = Get-Command $Name -ErrorAction SilentlyContinue
            if ($Cmd -and (Test-Python $Cmd.Source)) {
                $Python = $Cmd.Source
                break
            }
        }
    }

    if (-not $Python) {
        $CandidateRoots = @(
            "$env:LOCALAPPDATA\Programs\Python",
            "$env:ProgramFiles\Python",
            "$env:ProgramFiles\Python3"
        )
        foreach ($CandidateRoot in $CandidateRoots) {
            if (-not (Test-Path -LiteralPath $CandidateRoot)) { continue }
            $Found = Get-ChildItem -LiteralPath $CandidateRoot -Recurse -File -Filter "python.exe" -ErrorAction SilentlyContinue
            foreach ($Item in $Found) {
                if (Test-Python $Item.FullName) {
                    $Python = $Item.FullName
                    break
                }
            }
            if ($Python) { break }
        }
    }

    if (-not $Python) {
        throw "No usable Windows Python was found."
    }

    "Python: $Python" | Add-Content -Path $Log -Encoding UTF8
    Write-Host "Using Windows Python only as an interpreter:"
    Write-Host $Python

    $PackageDir = Join-Path $Root "packages"
    $CacheDir = Join-Path $Root "hf-cache"
    $PythonScript = Join-Path $Root "danbot_test.py"

    New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

    Write-Host "Downloading the isolated test script..."
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/rensei11/00-tools/main/somni-danbot-smoke-test.py" -OutFile $PythonScript

    $TorchReady = Test-Path -LiteralPath (Join-Path $PackageDir "torch")
    $TransformersReady = Test-Path -LiteralPath (Join-Path $PackageDir "transformers")

    if (-not $TorchReady) {
        Write-Host "Installing CPU Torch into the isolated test folder..."
        & $Python -m pip install --disable-pip-version-check --upgrade --target $PackageDir --index-url "https://download.pytorch.org/whl/cpu" "torch" 2>&1 |
            Out-File -FilePath $Log -Append -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            throw "CPU Torch installation failed. See run.log."
        }
    } else {
        Write-Host "CPU Torch is already installed. Skipping."
    }

    if (-not $TransformersReady) {
        Write-Host "Installing the remaining isolated test dependencies..."
        & $Python -m pip install --disable-pip-version-check --upgrade --target $PackageDir "transformers==4.49.0" "sentencepiece" "protobuf" 2>&1 |
            Out-File -FilePath $Log -Append -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            throw "Dependency installation failed. See run.log."
        }
    } else {
        Write-Host "Remaining dependencies are already installed. Skipping."
    }

    $env:PYTHONPATH = $PackageDir
    $env:HF_HOME = $CacheDir
    $env:HF_HUB_DISABLE_TELEMETRY = "1"
    $env:HF_HUB_DISABLE_SYMLINKS_WARNING = "1"

    Write-Host "Running one Japanese-to-Danbooru-tag conversion..."
    Write-Host "The original prompt will be read from the saved somni_00040 evidence."

    $PreviousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Python $PythonScript $Somni.FullName $Root 2>&1 |
        Out-File -FilePath $Log -Append -Encoding utf8
    $PythonExitCode = $LASTEXITCODE
    $ErrorActionPreference = $PreviousErrorAction

    if ($PythonExitCode -ne 0) {
        throw "DanbotNL conversion failed. See run.log."
    }

    $Result = Join-Path $Root "result.txt"
    if (-not (Test-Path -LiteralPath $Result -PathType Leaf)) {
        throw "The test ended without creating result.txt."
    }

    Write-Host ""
    Write-Host "SUCCESS"
    Write-Host "Result:"
    Write-Host $Result
    Write-Host ""
    Start-Process -FilePath "notepad.exe" -ArgumentList @($Result)
    Wait-BeforeClose
    exit 0
}
catch {
    $Message = $_.Exception.Message
    Write-Host ""
    Write-Host "FAILED"
    Write-Host $Message

    if ($Log) {
        try {
            "FAILED: $Message" | Add-Content -Path $Log -Encoding UTF8
            Write-Host ""
            Write-Host "Log:"
            Write-Host $Log
            Write-Host ""
            Get-Content -LiteralPath $Log -Tail 50 -ErrorAction SilentlyContinue
        } catch {
        }
    }

    Wait-BeforeClose
    exit 1
}
