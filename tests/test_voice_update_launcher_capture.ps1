$ErrorActionPreference = 'Stop'
$updater = Join-Path (Split-Path -Parent $PSScriptRoot) 'ai-voice/bootstrap/v1/migrate_updater_bootstrap_v1.ps1'
$bytes = [IO.File]::ReadAllBytes($updater)
if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) {
    throw 'Updater must remain UTF-8 with BOM.'
}
$source = [IO.File]::ReadAllText($updater, [Text.Encoding]::UTF8)
foreach ($required in @('RedirectStandardOutput = $true', 'RedirectStandardError = $true',
    'ReadToEndAsync()', 'LAUNCHER_', 'MANIFEST_VERIFIED', "Write-Log ('ATTEMPT_BEGIN")) {
    if (-not $source.Contains($required)) { throw ('Missing diagnostic contract: ' + $required) }
}
if ($source.Contains("[System.IO.File]::WriteAllText($logPath, ''")) {
    throw 'Updater must not truncate the previous diagnostic log.'
}
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($updater, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ('Updater parse error: ' + $errors[0].Message) }
foreach ($name in @('Write-Log', 'Start-CurrentApp')) {
    $fn = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true))
    if ($fn.Count -ne 1) { throw ('Function missing: ' + $name) }
    Invoke-Expression $fn[0].Extent.Text
}
$toolDir = Join-Path $env:RUNNER_TEMP ('voice-update-launcher-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($toolDir) | Out-Null
$logPath = Join-Path $toolDir '_update_bootstrap_log.txt'
$NoLaunch = $false
function Test-AppReady { return $true }
try {
    $launcher = Join-Path $toolDir 'start_local.ps1'
    [IO.File]::WriteAllText($launcher,
        'Write-Host "LAUNCHER_FAILURE_MARKER"' + [Environment]::NewLine +
        '[Console]::Error.WriteLine("LAUNCHER_STDERR_MARKER")' + [Environment]::NewLine +
        'exit 1' + [Environment]::NewLine, [Text.Encoding]::ASCII)
    $caught = $false
    try { Start-CurrentApp -SuppressBrowser }
    catch {
        if ($_.Exception.Message -notlike '*exit code 1*') { throw }
        $caught = $true
    }
    if (-not $caught) { throw 'Failing launcher was wrongly accepted.' }
    $log = [IO.File]::ReadAllText($logPath, [Text.Encoding]::UTF8)
    foreach ($required in @('LAUNCHER_EXIT=1', 'LAUNCHER_STDOUT LAUNCHER_FAILURE_MARKER',
        'LAUNCHER_STDERR LAUNCHER_STDERR_MARKER')) {
        if (-not $log.Contains($required)) { throw ('Missing launcher evidence: ' + $required) }
    }
    [IO.File]::WriteAllText($launcher, 'Write-Host "PASS"' + [Environment]::NewLine +
        'exit 0' + [Environment]::NewLine, [Text.Encoding]::ASCII)
    Start-CurrentApp -SuppressBrowser
    $newLog = [IO.File]::ReadAllText($logPath, [Text.Encoding]::UTF8)
    if (-not $newLog.Contains('LAUNCHER_EXIT=0') -or
        -not $newLog.Contains('LAUNCHER_STDOUT LAUNCHER_FAILURE_MARKER')) {
        throw 'The successful launch erased earlier failure evidence.'
    }
    Write-Host 'VOICE_LAUNCHER_CAPTURE=PASS'
}
finally {
    Remove-Item -LiteralPath $toolDir -Recurse -Force -ErrorAction SilentlyContinue
}
