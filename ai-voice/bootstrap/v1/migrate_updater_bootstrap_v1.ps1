param(
    [switch]$RepairButton,
    [switch]$ForceUpdate,
    [switch]$NoBrowser,
    [switch]$NoLaunch,
    [string]$IndexPath = '',
    [string]$ToolRoot = 'D:\AI生成ファイル\Irodori-TTS\Fandom音声ツール'
)

$ErrorActionPreference = 'Stop'

$toolDir = [System.IO.Path]::GetFullPath($ToolRoot)

$publicUpdaterUrl = 'https://raw.githubusercontent.com/rensei11/00-tools/main/ai-voice/bootstrap/v1/migrate_updater_bootstrap_v1.ps1'

if (-not $RepairButton -and -not $ForceUpdate -and -not $NoLaunch -and [string]::IsNullOrWhiteSpace($IndexPath)) {
    $RepairButton = $true
}

if ($RepairButton) {
    if (-not (Test-Path -LiteralPath $toolDir -PathType Container)) {
        Write-Host 'UPDATE_BUTTON_REPAIR=FAILED'
        Write-Host ('AI voice tool folder was not found: ' + $toolDir)
        exit 1
    }
    if (-not (Test-Path -LiteralPath (Join-Path $toolDir 'app.py') -PathType Leaf)) {
        Write-Host 'UPDATE_BUTTON_REPAIR=FAILED'
        Write-Host ('AI voice app.py was not found in: ' + $toolDir)
        exit 1
    }

    $destination = Join-Path $toolDir 'update_and_start.ps1'
    $content = @'
$ErrorActionPreference = 'Stop'

$runner = Join-Path $PSScriptRoot '_update_button_runner.ps1'
$sourceUrl = 'https://raw.githubusercontent.com/rensei11/00-tools/main/ai-voice/bootstrap/v1/migrate_updater_bootstrap_v1.ps1'
$headers = @{
    'User-Agent' = 'Rensei-AI-Voice-Update-Button'
    'Cache-Control' = 'no-cache'
    'Pragma' = 'no-cache'
}

try {
    Remove-Item -LiteralPath $runner -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $sourceUrl -OutFile $runner -UseBasicParsing -Headers $headers -TimeoutSec 30

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $runner,
        [ref]$tokens,
        [ref]$errors
    )
    if (@($errors).Count -ne 0) {
        throw ('Downloaded updater parse failed: ' + $errors[0].Message)
    }

    $text = [System.IO.File]::ReadAllText($runner, [System.Text.Encoding]::UTF8)
    foreach ($required in @(
        '[switch]$ForceUpdate',
        '[string]$ToolRoot',
        'api.github.com/repos/rensei11/00-tools/contents/ai-voice/update-index.json?ref=main',
        'FAILED_ROLLED_BACK'
    )) {
        if ($text.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw ('Downloaded updater is missing required contract: ' + $required)
        }
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -ToolRoot $PSScriptRoot -ForceUpdate -NoBrowser
    exit $LASTEXITCODE
}
catch {
    Write-Host $_.Exception.Message
    exit 1
}
finally {
    Remove-Item -LiteralPath $runner -Force -ErrorAction SilentlyContinue
}

'@

    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($destination, $content, $encoding)

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $destination,
        [ref]$tokens,
        [ref]$errors
    )
    if (@($errors).Count -ne 0) {
        Write-Host 'UPDATE_BUTTON_REPAIR=FAILED'
        Write-Host ('Installed update button parse failed: ' + $errors[0].Message)
        exit 1
    }

    $installed = [System.IO.File]::ReadAllText($destination, [System.Text.Encoding]::UTF8)
    if ($installed.IndexOf($publicUpdaterUrl, [StringComparison]::Ordinal) -lt 0) {
        Write-Host 'UPDATE_BUTTON_REPAIR=FAILED'
        Write-Host 'Installed update button does not point to the public updater.'
        exit 1
    }

    Write-Host 'UPDATE_BUTTON_REPAIR=SUCCESS'
    Write-Host ('INSTALLED=' + $destination)
    exit 0
}

$indexApiUrl = 'https://api.github.com/repos/rensei11/00-tools/contents/ai-voice/update-index.json?ref=main'
$appUrl = 'http://127.0.0.1:7862/'
$logPath = Join-Path $toolDir '_update_bootstrap_log.txt'
$statusPath = Join-Path $toolDir '_update_status.txt'
$workRoot = Join-Path $toolDir '_update_bootstrap_work'
$stableShellFiles = @(
    'Start Fandom Tool.cmd',
    'start_fandom_tool.cmd',
    'updater_bootstrap.ps1',
    'startup_update_check.ps1',
    'update_and_start.ps1'
)
$protectedFiles = @(
    'speakers.json',
    'games.json',
    'pronunciation_dictionary.json',
    'generation_history.jsonl'
)
$protectedDirectories = @(
    '参照音声',
    '音声',
    '.git',
    '.github',
    '_backup'
)
$allowedExtensions = @('.py', '.ps1', '.cmd', '.bat', '.js', '.json', '.md')

function Set-Status {
    param([string]$Code)
    [System.IO.File]::WriteAllText(
        $statusPath,
        ($Code + '|' + [DateTime]::Now.ToString('s')),
        [System.Text.Encoding]::ASCII
    )
}

function Write-Log {
    param([string]$Line)
    [System.IO.File]::AppendAllText(
        $logPath,
        ([DateTime]::Now.ToString('s') + ' ' + $Line + [Environment]::NewLine),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Convert-ToolVersion {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    if ($Value -notmatch '^([0-9]{4})-([0-9]{2})-([0-9]{2})-v([0-9]+)$') {
        return $null
    }

    return [pscustomobject]@{
        DateKey = [int]("$($Matches[1])$($Matches[2])$($Matches[3])")
        Revision = [int]$Matches[4]
    }
}

function Test-RemoteVersionIsNewer {
    param(
        [string]$LocalVersion,
        [string]$RemoteVersion
    )

    $local = Convert-ToolVersion $LocalVersion
    $remote = Convert-ToolVersion $RemoteVersion
    if ($null -eq $local -or $null -eq $remote) {
        return $false
    }
    if ($remote.DateKey -gt $local.DateKey) {
        return $true
    }
    if ($remote.DateKey -lt $local.DateKey) {
        return $false
    }
    return ($remote.Revision -gt $local.Revision)
}

function Get-LocalVersion {
    $appPath = Join-Path $toolDir 'app.py'
    if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
        return ''
    }

    $line = Get-Content -LiteralPath $appPath -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^APP_VERSION\s*=' } |
        Select-Object -First 1
    if ($line -and $line -match '([0-9]{4}-[0-9]{2}-[0-9]{2}-v[0-9]+)') {
        return [string]$Matches[1]
    }
    return ''
}

function Get-UpdateIndex {
    if (-not [string]::IsNullOrWhiteSpace($IndexPath)) {
        $full = [System.IO.Path]::GetFullPath($IndexPath)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw ('Local update index was not found: ' + $full)
        }
        return [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }

    $headers = @{
        'User-Agent' = 'Rensei-AI-Voice-Updater'
        'Cache-Control' = 'no-cache'
        'Pragma' = 'no-cache'
    }
    $response = Invoke-WebRequest -Uri $indexApiUrl -UseBasicParsing -Headers $headers -TimeoutSec 20
    $api = $response.Content | ConvertFrom-Json
    if ([string]$api.encoding -ne 'base64' -or [string]::IsNullOrWhiteSpace([string]$api.content)) {
        throw 'Update index response did not contain base64 content.'
    }
    $bytes = [System.Convert]::FromBase64String(([string]$api.content -replace '\s', ''))
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $text | ConvertFrom-Json
}

function Resolve-ManifestSource {
    param([object]$Index)

    if ($null -eq $Index -or [int]$Index.schema -ne 1) {
        throw 'Unsupported update index schema.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Index.version)) {
        throw 'Update index has no version.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Index.manifest_sha256)) {
        throw 'Update index has no manifest hash.'
    }

    if (-not [string]::IsNullOrWhiteSpace($IndexPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$Index.manifest_path)) {
            throw 'Local update index has no manifest_path.'
        }
        $indexDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($IndexPath))
        $manifestPath = [System.IO.Path]::GetFullPath((Join-Path $indexDir ([string]$Index.manifest_path)))
        return [pscustomobject]@{
            Mode = 'file'
            Source = $manifestPath
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Index.manifest_url)) {
        throw 'Update index has no manifest_url.'
    }
    if ([string]$Index.manifest_url -notmatch '^https://raw\.githubusercontent\.com/rensei11/00-tools/[0-9a-f]{40}/ai-voice/releases/[A-Za-z0-9._-]+\.json$') {
        throw 'Update manifest URL is not commit-pinned.'
    }
    return [pscustomobject]@{
        Mode = 'url'
        Source = [string]$Index.manifest_url
    }
}

function Get-Sha256 {
    param([string]$Path)
    return ([System.BitConverter]::ToString(
        ([System.Security.Cryptography.SHA256]::Create()).ComputeHash(
            [System.IO.File]::ReadAllBytes($Path)
        )
    ) -replace '-', '').ToLowerInvariant()
}

function Download-Manifest {
    param(
        [object]$Index,
        [string]$Destination
    )

    $source = Resolve-ManifestSource $Index
    if ([string]$source.Mode -eq 'file') {
        Copy-Item -LiteralPath ([string]$source.Source) -Destination $Destination -Force
    } else {
        Invoke-WebRequest -Uri ([string]$source.Source) -OutFile $Destination -UseBasicParsing -TimeoutSec 60
    }

    $actualHash = Get-Sha256 $Destination
    $expectedHash = ([string]$Index.manifest_sha256).ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw ('Manifest SHA-256 mismatch. expected=' + $expectedHash + ' actual=' + $actualHash)
    }

    $payload = [System.IO.File]::ReadAllText($Destination, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]$payload.version -ne [string]$Index.version) {
        throw 'Update index version does not match manifest version.'
    }
    if ($null -eq $payload.files) {
        throw 'Manifest has no files.'
    }
    return $payload
}

function Get-SafeRelativePath {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'Empty update path.'
    }
    $value = $Name.Replace('/', '\')
    if ($value.StartsWith('\') -or $value -match '^[A-Za-z]:' -or $value.Contains(':')) {
        throw ('Rooted or stream path rejected: ' + $Name)
    }
    $parts = @($value -split '\\')
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..') {
            throw ('Unsafe path segment: ' + $Name)
        }
        if ($part -match '[<>|?*\x00-\x1F]' -or $part.EndsWith('.') -or $part.EndsWith(' ')) {
            throw ('Invalid path segment: ' + $Name)
        }
        if ($protectedDirectories -contains $part) {
            throw ('Protected directory rejected: ' + $Name)
        }
    }

    if ($stableShellFiles -contains $parts[-1]) {
        throw ('Stable updater shell must not be in normal payload: ' + $Name)
    }
    if ($protectedFiles -contains $parts[-1]) {
        throw ('Protected file rejected: ' + $Name)
    }

    $extension = [System.IO.Path]::GetExtension($parts[-1]).ToLowerInvariant()
    if ($allowedExtensions -notcontains $extension) {
        return $null
    }
    return ($parts -join '\')
}

function Get-FullPath {
    param(
        [string]$Root,
        [string]$Relative
    )

    $full = [System.IO.Path]::GetFullPath((Join-Path $Root $Relative))
    $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Path escaped update root: ' + $Relative)
    }

    $cursor = $Root
    $relativeParent = Split-Path -Parent $Relative
    foreach ($part in @($relativeParent -split '\\' | Where-Object { $_ })) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Reparse point in update path: ' + $Relative)
            }
        }
    }
    return $full
}

function Test-AppReady {
    try {
        $response = Invoke-WebRequest -Uri $appUrl -UseBasicParsing -TimeoutSec 2
        return ($response.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Stop-App {
    & wsl.exe -d Ubuntu -- bash -lc "pkill -f '/home/rensei/Irodori-TTS/.venv/bin/python [a]pp.py' || true" | Out-Null  # storage-policy: external-read
}

function Start-CurrentApp {
    param([switch]$SuppressBrowser)

    if ($NoLaunch) {
        return
    }

    $launcher = Join-Path $toolDir 'start_local.ps1'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw 'start_local.ps1 was not found.'
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $launcher,
        '-SkipUpdateCheck'
    )
    if ($SuppressBrowser) {
        $arguments += '-NoBrowser'
    }

    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ('Local launcher failed with exit code ' + $LASTEXITCODE)
    }
}

function Apply-Manifest {
    param(
        [object]$Index,
        [object]$Payload
    )

    $workDir = Join-Path $workRoot ([Guid]::NewGuid().ToString('N'))
    $stageDir = Join-Path $workDir 'stage'
    $backupDir = Join-Path $workDir 'backup'
    $changed = New-Object 'System.Collections.Generic.List[string]'
    $created = New-Object 'System.Collections.Generic.List[string]'
    $applyStarted = $false

    try {
        [System.IO.Directory]::CreateDirectory($stageDir) | Out-Null
        [System.IO.Directory]::CreateDirectory($backupDir) | Out-Null

        $entries = New-Object 'System.Collections.Generic.List[object]'
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($property in $Payload.files.PSObject.Properties) {
            $relative = Get-SafeRelativePath ([string]$property.Name)
            if (-not $relative) {
                continue
            }
            if (-not $seen.Add($relative)) {
                throw ('Duplicate update path: ' + $relative)
            }
            if ($null -eq $property.Value -or $property.Value -isnot [string]) {
                throw ('Invalid content for: ' + $relative)
            }
            $entries.Add([pscustomobject]@{
                Relative = $relative
                Content = [string]$property.Value
            }) | Out-Null
        }

        if ($entries.Count -eq 0) {
            throw 'Manifest has no supported program files.'
        }

        foreach ($entry in $entries) {
            $staged = Get-FullPath $stageDir $entry.Relative
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $staged)) | Out-Null
            $encoding = New-Object System.Text.UTF8Encoding($false)
            if ([System.IO.Path]::GetExtension($staged).ToLowerInvariant() -eq '.ps1') {
                $encoding = New-Object System.Text.UTF8Encoding($true)
            }
            [System.IO.File]::WriteAllText($staged, $entry.Content, $encoding)
        }

        if (Test-AppReady) {
            Stop-App
            Start-Sleep -Milliseconds 500
        }

        Set-Status 'APPLYING'
        $applyStarted = $true

        foreach ($entry in $entries) {
            $relative = $entry.Relative
            $destination = Get-FullPath $toolDir $relative
            $staged = Get-FullPath $stageDir $relative
            $backup = Get-FullPath $backupDir $relative

            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null

            $destinationExists = Test-Path -LiteralPath $destination -PathType Leaf
            if ($destinationExists) {
                [System.IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                $changed.Add($relative) | Out-Null
            } else {
                $created.Add($relative) | Out-Null
            }

            $pendingPath = $destination + '.bootstrap-update-pending'
            Copy-Item -LiteralPath $staged -Destination $pendingPath -Force
            if ($destinationExists) {
                [System.IO.File]::Replace($pendingPath, $destination, $backup)
            } else {
                [System.IO.File]::Move($pendingPath, $destination)
            }
        }

        Set-Status 'RESTARTING'
        Start-CurrentApp -SuppressBrowser:$NoBrowser

        Write-Log ('SUCCESS version=' + [string]$Index.version + ' files=' + $entries.Count)
        Set-Status 'SUCCESS'
        return
    }
    catch {
        Write-Log ('ERROR ' + $_.Exception.Message)

        if ($applyStarted) {
            try {
                Stop-App
                foreach ($relative in $changed) {
                    $destination = Get-FullPath $toolDir $relative
                    $backup = Get-FullPath $backupDir $relative
                    if (Test-Path -LiteralPath $backup -PathType Leaf) {
                        Copy-Item -LiteralPath $backup -Destination $destination -Force
                    }
                }
                foreach ($relative in $created) {
                    $destination = Get-FullPath $toolDir $relative
                    Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
                }

                Start-CurrentApp -SuppressBrowser:$NoBrowser
                Set-Status 'FAILED_ROLLED_BACK'
            }
            catch {
                Write-Log ('ROLLBACK_ERROR ' + $_.Exception.Message)
                Set-Status 'FAILED_ROLLBACK_START'
            }
        } else {
            Set-Status 'FAILED_BEFORE_APPLY'
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    [System.IO.File]::WriteAllText($logPath, '', (New-Object System.Text.UTF8Encoding($false)))
    Set-Status 'CHECKING'

    $index = $null
    $indexError = $null
    try {
        $index = Get-UpdateIndex
    } catch {
        $indexError = $_.Exception.Message
        Write-Log ('INDEX_ERROR ' + $indexError)
    }

    $localVersion = Get-LocalVersion

    if ($null -ne $index) {
        $remoteVersion = [string]$index.version
        if ($ForceUpdate -or (Test-RemoteVersionIsNewer $localVersion $remoteVersion)) {
            [System.IO.Directory]::CreateDirectory($workRoot) | Out-Null
            $manifestPath = Join-Path $workRoot ('manifest-' + [Guid]::NewGuid().ToString('N') + '.json')
            try {
                $payload = Download-Manifest $index $manifestPath
                Apply-Manifest $index $payload
                exit 0
            } finally {
                Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    try {
        Start-CurrentApp -SuppressBrowser:$NoBrowser
        Set-Status 'LOCAL_START_SUCCESS'
        exit 0
    }
    catch {
        $localStartError = $_.Exception.Message
        Write-Log ('LOCAL_START_ERROR ' + $localStartError)

        if ($null -eq $index) {
            throw ('Local startup failed and update index could not be loaded. ' + $localStartError + ' / ' + $indexError)
        }

        [System.IO.Directory]::CreateDirectory($workRoot) | Out-Null
        $manifestPath = Join-Path $workRoot ('repair-' + [Guid]::NewGuid().ToString('N') + '.json')
        try {
            $payload = Download-Manifest $index $manifestPath
            Write-Log ('SELF_REPAIR version=' + [string]$index.version)
            Apply-Manifest $index $payload
            exit 0
        } finally {
            Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Log ('FATAL ' + $_.Exception.Message)
    if (-not $NoLaunch) {
        Write-Host $_.Exception.Message
    }
    exit 1
}
