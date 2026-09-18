@echo off
setlocal
set "SELF=%~f0"
set "PSFILE=%TEMP%\ChatGPTMultiView_%RANDOM%_%RANDOM%.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$lines=Get-Content -LiteralPath $env:SELF -Encoding UTF8; $marker=[Array]::IndexOf($lines,'###POWERSHELL###'); if($marker -lt 0){exit 2}; $lines[($marker+1)..($lines.Count-1)] | Set-Content -LiteralPath $env:PSFILE -Encoding UTF8"
if errorlevel 1 (
  echo 起動準備に失敗しました。
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%"
set "EXITCODE=%ERRORLEVEL%"
del /q "%PSFILE%" >nul 2>&1
exit /b %EXITCODE%

###POWERSHELL###
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

function Show-Error([string]$Message) {
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'ChatGPT複数表示',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

$configDir = Join-Path $env:APPDATA 'ChatGPT複数表示'
$configPath = Join-Path $configDir 'settings.json'
New-Item -ItemType Directory -Path $configDir -Force | Out-Null

$urls = @()

if (Test-Path -LiteralPath $configPath) {
    try {
        $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $urls = @($cfg.Urls) | Where-Object { $_ -is [string] -and $_ -match '^https://chatgpt\.com/' }
    }
    catch {
        $urls = @()
    }
}

$changeSettings = $false

if ($urls.Count -ge 2 -and $urls.Count -le 4) {
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "保存済みの $($urls.Count) 個のチャットを開きますか？`r`n`r`nはい：そのまま開く`r`nいいえ：チャットを入れ替える`r`nキャンセル：終了",
        'ChatGPT複数表示',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
        exit 0
    }

    if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
        $changeSettings = $true
        $urls = @()
    }
}

if ($urls.Count -lt 2 -or $urls.Count -gt 4 -or $changeSettings) {
    $countText = [Microsoft.VisualBasic.Interaction]::InputBox(
        "同時に表示するChatGPTチャット数を 2～4 で入力してください。","ChatGPT複数表示","3"
    )

    if ([string]::IsNullOrWhiteSpace($countText)) {
        exit 0
    }

    $count = 0
    if (-not [int]::TryParse($countText, [ref]$count) -or $count -lt 2 -or $count -gt 4) {
        Show-Error 'チャット数は 2、3、4 のどれかにしてください。'
        exit 1
    }

    $urls = @()
    for ($i = 1; $i -le $count; $i++) {
        while ($true) {
            $url = [Microsoft.VisualBasic.Interaction]::InputBox(
                "ChatGPTで表示したいチャットを開き、上のURLをコピーして貼り付けてください。`r`n`r`n$i 個目 / $count 個",
                "ChatGPT複数表示",
                ""
            )

            if ([string]::IsNullOrWhiteSpace($url)) {
                exit 0
            }

            $url = $url.Trim()
            if ($url -match '^https://chatgpt\.com/') {
                $urls += $url
                break
            }

            [System.Windows.Forms.MessageBox]::Show(
                "ChatGPTのURLではないようです。`r`nhttps://chatgpt.com/ で始まるURLを貼り付けてください。",
                'ChatGPT複数表示',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    }

    [PSCustomObject]@{ Urls = $urls } |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $configPath -Encoding UTF8
}

$pf = [Environment]::GetFolderPath('ProgramFiles')
$pfx86 = [Environment]::GetFolderPath('ProgramFilesX86')
$local = $env:LOCALAPPDATA

$candidates = @(
    @{ Path = (Join-Path $pf 'Google\Chrome\Application\chrome.exe'); Proc = 'chrome' },
    @{ Path = (Join-Path $pfx86 'Google\Chrome\Application\chrome.exe'); Proc = 'chrome' },
    @{ Path = (Join-Path $local 'Google\Chrome\Application\chrome.exe'); Proc = 'chrome' },
    @{ Path = (Join-Path $pfx86 'Microsoft\Edge\Application\msedge.exe'); Proc = 'msedge' },
    @{ Path = (Join-Path $pf 'Microsoft\Edge\Application\msedge.exe'); Proc = 'msedge' },
    @{ Path = (Join-Path $local 'Microsoft\Edge\Application\msedge.exe'); Proc = 'msedge' }
)

$browser = $null
$procName = $null
foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate.Path) {
        $browser = $candidate.Path
        $procName = $candidate.Proc
        break
    }
}

if (-not $browser) {
    Show-Error 'Google Chrome または Microsoft Edge が見つかりませんでした。'
    exit 1
}

Add-Type @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class WindowUtil
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(
        IntPtr hWnd,
        int X,
        int Y,
        int nWidth,
        int nHeight,
        bool bRepaint
    );

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public static IntPtr[] GetBrowserWindows(string processName)
    {
        var list = new List<IntPtr>();

        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd))
                return true;

            if (GetWindowTextLength(hWnd) == 0)
                return true;

            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);

            try
            {
                var process = Process.GetProcessById((int)pid);
                if (String.Equals(process.ProcessName, processName, StringComparison.OrdinalIgnoreCase))
                    list.Add(hWnd);
            }
            catch
            {
            }

            return true;
        }, IntPtr.Zero);

        return list.ToArray();
    }
}
"@

$handles = @()

foreach ($url in $urls) {
    $before = @([WindowUtil]::GetBrowserWindows($procName) | ForEach-Object { $_.ToInt64() })

    Start-Process -FilePath $browser -ArgumentList @('--new-window', $url) | Out-Null

    $newHandle = $null
    for ($try = 0; $try -lt 80; $try++) {
        Start-Sleep -Milliseconds 250

        $current = @([WindowUtil]::GetBrowserWindows($procName))
        $newWindows = @($current | Where-Object { $before -notcontains $_.ToInt64() })

        if ($newWindows.Count -gt 0) {
            $newHandle = $newWindows[0]
            break
        }
    }

    if ($null -eq $newHandle) {
        Show-Error 'ChatGPTの新しいウィンドウを確認できませんでした。ブラウザを閉じてから、もう一度実行してください。'
        exit 1
    }

    $handles += $newHandle
}

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$count = $handles.Count
$columnWidth = [Math]::Floor($screen.Width / $count)

for ($i = 0; $i -lt $count; $i++) {
    $x = $screen.Left + ($columnWidth * $i)

    if ($i -eq ($count - 1)) {
        $width = $screen.Right - $x
    }
    else {
        $width = $columnWidth
    }

    [WindowUtil]::ShowWindow($handles[$i], 9) | Out-Null
    [WindowUtil]::MoveWindow(
        $handles[$i],
        $x,
        $screen.Top,
        $width,
        $screen.Height,
        $true
    ) | Out-Null
}
