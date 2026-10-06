$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = 'D:\AI生成ファイル\Irodori-TTS\参照音声'

function Test-NonEmptyDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }
    return @(
        Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction Stop |
            Select-Object -First 1
    ).Count -gt 0
}

function Read-Producer {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
        return [string]$obj.producer
    }
    catch {
        return 'UNREADABLE_JSON'
    }
}

try {
    Write-Host 'PHASE2_INVENTORY=START'
    Write-Host ('ROOT=' + $root)

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw 'Official reference-audio root was not found.'
    }

    $rows = @()
    $folders = @(
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop |
            Sort-Object Name
    )

    foreach ($folder in $folders) {
        if (($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Host ('SKIP_REPARSE|' + $folder.Name)
            continue
        }

        $name = $folder.Name
        $metaPath = Join-Path $folder.FullName '音声一覧.json'
        $refDir = Join-Path $folder.FullName '参照セット'
        $refPt = Join-Path $refDir '120秒.pt'
        $refJson = Join-Path $refDir '120秒.json'
        $precomputed = Join-Path $folder.FullName '事前計算'
        $emotionCache = Join-Path $folder.FullName 'emotion2vec_plus_base_embeddings.json'
        $emotionRefs = Join-Path $refDir '感情別'

        $audio = @(
            Get-ChildItem -LiteralPath $folder.FullName -File -ErrorAction Stop |
                Where-Object { @('.wav', '.flac', '.ogg', '.oga', '.mp3') -contains $_.Extension.ToLowerInvariant() }
        )
        $wavCount = @($audio | Where-Object { $_.Extension -ieq '.wav' }).Count
        $flacCount = @($audio | Where-Object { $_.Extension -ieq '.flac' }).Count
        $otherCount = $audio.Count - $wavCount - $flacCount

        $legacy = @()
        foreach ($seconds in @(30, 60, 90)) {
            foreach ($suffix in @('.pt', '.json')) {
                $candidate = Join-Path $refDir (($seconds.ToString()) + '秒' + $suffix)
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $legacy += (($seconds.ToString()) + '秒' + $suffix)
                }
            }
        }
        if (Test-NonEmptyDirectory -Path $precomputed) {
            $legacy += '事前計算'
        }
        if (Test-Path -LiteralPath $emotionCache -PathType Leaf) {
            $legacy += 'emotion2vec'
        }
        if (Test-NonEmptyDirectory -Path $emotionRefs) {
            $legacy += '感情別参照'
        }

        $producer = Read-Producer -Path $refJson
        $hasPt = Test-Path -LiteralPath $refPt -PathType Leaf
        $hasJson = Test-Path -LiteralPath $refJson -PathType Leaf
        $hasMeta = Test-Path -LiteralPath $metaPath -PathType Leaf

        $category = 'NO_PHASE2_TARGET'
        if ($wavCount -gt 0 -and $hasPt -and $hasJson) {
            if ($producer -eq 'clean_rebuild_standard_v1' -and $legacy.Count -eq 0) {
                $category = 'CLEAN_PILOT_CANDIDATE'
            }
            else {
                $category = 'LEGACY_MIGRATION_CANDIDATE'
            }
        }
        elseif ($wavCount -gt 0) {
            $category = 'WAV_WITHOUT_120S_REFERENCE'
        }
        elseif ($hasPt -and $hasJson) {
            $category = 'REFERENCE_WITHOUT_WAV'
        }

        $legacyText = ''
        if ($legacy.Count -gt 0) {
            $legacyText = $legacy -join ','
        }

        $row = [PSCustomObject]@{
            character = $name
            category = $category
            wav = $wavCount
            flac = $flacCount
            other = $otherCount
            metadata = [bool]$hasMeta
            reference_pt = [bool]$hasPt
            reference_json = [bool]$hasJson
            producer = $producer
            legacy = $legacyText
        }
        $rows += $row

        Write-Host (
            'CHAR|' + $name +
            '|category=' + $category +
            '|wav=' + $wavCount +
            '|flac=' + $flacCount +
            '|other=' + $otherCount +
            '|metadata=' + [string][int][bool]$hasMeta +
            '|reference_pt=' + [string][int][bool]$hasPt +
            '|reference_json=' + [string][int][bool]$hasJson +
            '|producer=' + $producer +
            '|legacy=' + $legacyText
        )
    }

    $clean = @($rows | Where-Object { $_.category -eq 'CLEAN_PILOT_CANDIDATE' })
    $legacyCandidates = @($rows | Where-Object { $_.category -eq 'LEGACY_MIGRATION_CANDIDATE' })

    Write-Host ('CLEAN_PILOT_CANDIDATES=' + $clean.Count)
    foreach ($row in $clean) {
        Write-Host ('CLEAN_CANDIDATE|' + $row.character + '|wav=' + $row.wav + '|flac=' + $row.flac)
    }

    Write-Host ('LEGACY_MIGRATION_CANDIDATES=' + $legacyCandidates.Count)
    foreach ($row in $legacyCandidates) {
        Write-Host (
            'LEGACY_CANDIDATE|' + $row.character +
            '|wav=' + $row.wav +
            '|producer=' + $row.producer +
            '|legacy=' + $row.legacy
        )
    }

    Write-Host ('CHARACTER_COUNT=' + $rows.Count)
    Write-Host 'READ_ONLY_CONFIRMATION=No files were created, modified, moved, or deleted under the reference-audio root.'
    Write-Host 'PHASE2_INVENTORY=SUCCESS'
    exit 0
}
catch {
    Write-Host ('ERROR: ' + $_.Exception.Message)
    Write-Host 'PHASE2_INVENTORY=FAILED'
    exit 1
}
