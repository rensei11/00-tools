$ErrorActionPreference = 'Stop'

$logPath = Join-Path $env:TEMP 'rensei_cezar_command_center.log'
$root = '/home/rensei/cezar-command-center'
$repo = '/home/rensei/cezar-command-center/00-tools'
$extensionRoot = Join-Path $env:LOCALAPPDATA 'RenseiCezarCommand\extension'
$extensionBase = 'https://raw.githubusercontent.com/rensei11/00-tools/main/cezar-command/commander_extension'

function Write-Log {
    param([string]$Message)
    [IO.File]::AppendAllText(
        $logPath,
        ((Get-Date).ToString('s') + ' ' + $Message + [Environment]::NewLine),
        (New-Object Text.UTF8Encoding($false))
    )
}

function Get-ChromePath {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    return $candidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -First 1
}

function Sync-CommanderExtension {
    New-Item -ItemType Directory -Force -Path $extensionRoot | Out-Null
    $files = @(
        'manifest.json',
        'control.js',
        'chatgpt.js',
        'service_worker.js'
    )
    foreach ($name in $files) {
        $url = $extensionBase + '/' + $name
        $target = Join-Path $extensionRoot $name
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 45 -Uri $url -OutFile $target
        if (-not (Test-Path -LiteralPath $target)) {
            throw ('Commander extension file was not downloaded: ' + $name)
        }
    }
}

function Invoke-Wsl {
    param(
        [string[]]$CommandArgs,
        [string]$Stage,
        [switch]$AllowFailure
    )

    Write-Log ($Stage + ': START')
    $fullArgs = @('-d', 'Ubuntu', '--') + $CommandArgs

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & wsl.exe @fullArgs 2>&1
        $rc = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    foreach ($line in @($output)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Write-Host $line
            Write-Log ($Stage + ': ' + [string]$line)
        }
    }
    Write-Log ($Stage + ': EXIT=' + $rc)

    if ($rc -ne 0 -and -not $AllowFailure) {
        throw ($Stage + ' failed with exit code ' + $rc + '.')
    }

    return [pscustomobject]@{
        ExitCode = $rc
        Output = (@($output) -join [Environment]::NewLine)
    }
}

function Register-Commander {
    return Invoke-Wsl -CommandArgs @(
        'python3',
        ($repo + '/cezar-command/commander_link.py'),
        'register'
    ) -Stage 'commander-register' -AllowFailure
}

try {
    [IO.File]::WriteAllText($logPath, '', (New-Object Text.UTF8Encoding($false)))

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe was not found.'
    }

    $chrome = Get-ChromePath
    if (-not $chrome) {
        throw 'Google Chrome was not found.'
    }

    Sync-CommanderExtension

    [void](Invoke-Wsl -CommandArgs @('uname', '-s') -Stage 'wsl-check')
    [void](Invoke-Wsl -CommandArgs @('git', '--version') -Stage 'git-check')
    [void](Invoke-Wsl -CommandArgs @('python3', '--version') -Stage 'python-check')
    [void](Invoke-Wsl -CommandArgs @('mkdir', '-p', $root) -Stage 'root-create')

    $repoCheck = Invoke-Wsl -CommandArgs @('test', '-d', ($repo + '/.git')) -Stage 'repo-check' -AllowFailure
    if ($repoCheck.ExitCode -ne 0) {
        $repoExists = Invoke-Wsl -CommandArgs @('test', '-e', $repo) -Stage 'partial-repo-check' -AllowFailure
        if ($repoExists.ExitCode -eq 0) {
            [void](Invoke-Wsl -CommandArgs @('rm', '-rf', '--', $repo) -Stage 'partial-repo-remove')
        }
        [void](Invoke-Wsl -CommandArgs @(
            'env',
            'GIT_TERMINAL_PROMPT=0',
            'git',
            'clone',
            '--branch',
            'main',
            '--single-branch',
            'https://github.com/rensei11/00-tools.git',
            $repo
        ) -Stage 'repo-clone')
    }
    else {
        $origin = Invoke-Wsl -CommandArgs @('git', '-C', $repo, 'remote', 'get-url', 'origin') -Stage 'repo-origin'
        if ($origin.Output.Trim() -ne 'https://github.com/rensei11/00-tools.git') {
            throw ('Unexpected control repository origin: ' + $origin.Output.Trim())
        }

        [void](Invoke-Wsl -CommandArgs @(
            'env',
            'GIT_TERMINAL_PROMPT=0',
            'git',
            '-C',
            $repo,
            'fetch',
            'origin',
            'main'
        ) -Stage 'repo-fetch')
        [void](Invoke-Wsl -CommandArgs @('git', '-C', $repo, 'switch', 'main') -Stage 'repo-switch')
        [void](Invoke-Wsl -CommandArgs @('git', '-C', $repo, 'reset', '--hard', 'origin/main') -Stage 'repo-reset')
        [void](Invoke-Wsl -CommandArgs @('git', '-C', $repo, 'clean', '-fd') -Stage 'repo-clean')
    }

    $registration = Register-Commander
    if ($registration.ExitCode -ne 0) {
        Write-Host ''
        Write-Host 'ONE-TIME CHROME SETUP REQUIRED'
        Write-Host '1. In chrome://extensions turn on Developer mode.'
        Write-Host '2. Choose Load unpacked.'
        Write-Host ('3. Select this folder: ' + $extensionRoot)
        Write-Host '4. If the extension already exists, press Reload instead.'
        Write-Host '5. Keep this ChatGPT conversation open.'
        Write-Host ''
        Start-Process -FilePath $chrome -ArgumentList @('chrome://extensions/')
        Start-Process -FilePath explorer.exe -ArgumentList @($extensionRoot)
        [void](Read-Host 'After Chrome accepts the extension, press Enter here')

        $registration = Register-Commander
        if ($registration.ExitCode -ne 0) {
            throw 'Commander extension registration failed after the one-time Chrome setup.'
        }
    }

    [void](Invoke-Wsl -CommandArgs @(
        'python3',
        ($repo + '/cezar-command/bootstrap_local.py'),
        '--control-repo',
        $repo,
        '--skip-commander-register'
    ) -Stage 'command-center-start')

    Write-Host 'CEZAR COMMAND CENTER READY'
    Write-Log 'READY'
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-Log ('BLOCKED: ' + $message)
    Write-Host 'CEZAR COMMAND CENTER BLOCKED'
    Write-Host $message
    Write-Host ''
    Write-Host 'Log:'
    Write-Host $logPath
    exit 1
}
