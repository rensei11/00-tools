$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$referenceRoot = 'D:\AI生成ファイル\Irodori-TTS\参照音声'
$toolRoot = 'D:\AI生成ファイル\Irodori-TTS\Fandom音声ツール'
$candidates = @('パイモン', 'フランツ', 'メリル', 'レクイエム')

function Get-JsonFilesForCharacter {
    param(
        [string]$Character,
        [string]$CharacterRoot
    )

    $result = @()

    if (Test-Path -LiteralPath $CharacterRoot -PathType Container) {
        $result += @(
            Get-ChildItem -LiteralPath $CharacterRoot -File -Filter '*.json' -Recurse -ErrorAction Stop |
                ForEach-Object {
                    [PSCustomObject]@{
                        scope = 'character'
                        path = $_.FullName
                    }
                }
        )
    }

    $speakerPath = Join-Path $toolRoot 'speakers.json'
    if (Test-Path -LiteralPath $speakerPath -PathType Leaf) {
        $result += [PSCustomObject]@{
            scope = 'tool'
            path = $speakerPath
        }
    }

    $emotionPools = Join-Path $toolRoot 'shared_results\emotion_pools'
    if (Test-Path -LiteralPath $emotionPools -PathType Container) {
        $result += @(
            Get-ChildItem -LiteralPath $emotionPools -File -Filter '*.json' -ErrorAction Stop |
                ForEach-Object {
                    [PSCustomObject]@{
                        scope = 'tool'
                        path = $_.FullName
                    }
                }
        )
    }

    if ($Character -eq 'パイモン') {
        $legacyPaimon = Join-Path $toolRoot 'shared_results\paimon_emotion_pools.json'
        if (Test-Path -LiteralPath $legacyPaimon -PathType Leaf) {
            $result += [PSCustomObject]@{
                scope = 'tool'
                path = $legacyPaimon
            }
        }
    }

    return @(
        $result |
            Sort-Object path -Unique
    )
}

function Get-DisplayPath {
    param(
        [string]$Scope,
        [string]$Path,
        [string]$CharacterRoot
    )

    if ($Scope -eq 'character' -and $Path.StartsWith($CharacterRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($CharacterRoot.Length).TrimStart('\')
    }
    if ($Scope -eq 'tool' -and $Path.StartsWith($toolRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($toolRoot.Length).TrimStart('\')
    }
    return $Path
}

try {
    Write-Host 'PHASE2_LEGACY_AUDIT=START'
    Write-Host ('REFERENCE_ROOT=' + $referenceRoot)
    Write-Host ('TOOL_ROOT=' + $toolRoot)

    if (-not (Test-Path -LiteralPath $referenceRoot -PathType Container)) {
        throw 'Official reference-audio root was not found.'
    }

    foreach ($character in $candidates) {
        $characterRoot = Join-Path $referenceRoot $character
        if (-not (Test-Path -LiteralPath $characterRoot -PathType Container)) {
            Write-Host ('CHARACTER|' + $character + '|status=MISSING')
            continue
        }

        if ((Get-Item -LiteralPath $characterRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Host ('CHARACTER|' + $character + '|status=REPARSE_POINT_SKIPPED')
            continue
        }

        $wavFiles = @(
            Get-ChildItem -LiteralPath $characterRoot -File -Filter '*.wav' -ErrorAction Stop |
                Sort-Object Name
        )
        $wavNames = @($wavFiles | ForEach-Object { $_.Name })
        $jsonFiles = @(Get-JsonFilesForCharacter -Character $character -CharacterRoot $characterRoot)

        $jsonWithRefs = 0
        $distinctReferenced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

        foreach ($json in $jsonFiles) {
            $text = [IO.File]::ReadAllText([string]$json.path, [Text.Encoding]::UTF8)
            $matched = @()

            foreach ($wavName in $wavNames) {
                if ($text.IndexOf($wavName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $matched += $wavName
                    [void]$distinctReferenced.Add($wavName)
                }
            }

            if ($matched.Count -gt 0) {
                $jsonWithRefs += 1
                $display = Get-DisplayPath -Scope ([string]$json.scope) -Path ([string]$json.path) -CharacterRoot $characterRoot
                Write-Host (
                    'REF|' + $character +
                    '|scope=' + [string]$json.scope +
                    '|json=' + $display +
                    '|wav_names=' + $matched.Count
                )
            }
        }

        $unreferenced = @(
            $wavNames |
                Where-Object { -not $distinctReferenced.Contains($_) }
        )

        Write-Host (
            'CHARACTER|' + $character +
            '|status=OK' +
            '|wav=' + $wavNames.Count +
            '|json_scanned=' + $jsonFiles.Count +
            '|json_with_wav_refs=' + $jsonWithRefs +
            '|distinct_wav_referenced=' + $distinctReferenced.Count +
            '|wav_unreferenced=' + $unreferenced.Count
        )

        $standardManifests = @(
            30, 60, 90, 120 |
                ForEach-Object { Join-Path (Join-Path $characterRoot '参照セット') (($_.ToString()) + '秒.json') }
        )
        foreach ($manifest in $standardManifests) {
            if (Test-Path -LiteralPath $manifest -PathType Leaf) {
                $text = [IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8)
                $count = 0
                foreach ($wavName in $wavNames) {
                    if ($text.IndexOf($wavName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $count += 1
                    }
                }
                Write-Host (
                    'STANDARD_MANIFEST|' + $character +
                    '|json=' + (Split-Path $manifest -Leaf) +
                    '|wav_names=' + $count
                )
            }
        }

        $emotionCache = Join-Path $characterRoot 'emotion2vec_plus_base_embeddings.json'
        if (Test-Path -LiteralPath $emotionCache -PathType Leaf) {
            $text = [IO.File]::ReadAllText($emotionCache, [Text.Encoding]::UTF8)
            $count = 0
            foreach ($wavName in $wavNames) {
                if ($text.IndexOf($wavName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $count += 1
                }
            }
            Write-Host ('EMOTION2VEC|' + $character + '|wav_names=' + $count)
        }
    }

    Write-Host 'READ_ONLY_CONFIRMATION=No files were created, modified, moved, renamed, or deleted.'
    Write-Host 'PHASE2_LEGACY_AUDIT=SUCCESS'
    exit 0
}
catch {
    Write-Host ('ERROR: ' + $_.Exception.Message)
    Write-Host 'PHASE2_LEGACY_AUDIT=FAILED'
    exit 1
}
