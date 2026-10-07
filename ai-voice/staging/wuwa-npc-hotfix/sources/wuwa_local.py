from __future__ import annotations

import json
import re
import shutil
from datetime import datetime
from pathlib import Path
from typing import Any

import soundfile as sf

from voice_core import REFERENCE_ROOT, REGISTRY_PATH, safe_name


WUWA_GAME_NAME = "鳴潮"
WUWA_SOURCE_PROVIDER = "wuwa-local"
WUWA_RESOURCE_ROOT_WINDOWS = r"D:\ソーシャルゲーム\Wuthering Waves\Wuthering Waves Game\Client\Saved\Resources\3.6.0\Lang_ja"  # storage-policy: external-read
WUWA_RESEARCH_ROOT_WINDOWS = r"D:\AI生成ファイル\Irodori-TTS\調査用データ\AI音声ツール\鳴潮"
WUWA_PRIMARY_MANIFEST_WINDOWS = WUWA_RESEARCH_ROOT_WINDOWS + r"\NPC名前指定取得\npc-acquisition.json"

# Japanese WAV acquisition was proven for these NPCs before formal UI integration.
WUWA_NPC_CATALOG: tuple[dict[str, Any], ...] = (
    {"name": "チェイス", "speaker_ids": ["250087"]},
    {"name": "N.A.N.A", "speaker_ids": ["100086"]},
    {"name": "I.R.I.S", "speaker_ids": ["100144"]},
    {"name": "マルゲリータ", "speaker_ids": ["1490"]},
    {"name": "アウィディウス", "speaker_ids": ["1580"]},
    {"name": "スターバック", "speaker_ids": ["100053", "100059"]},
    {"name": "フェンリコ", "speaker_ids": ["1590"]},
    {"name": "クリストフォロ", "speaker_ids": ["1603", "50080"]},
    {"name": "ナミポン", "speaker_ids": ["50180"]},
    {"name": "アブ", "speaker_ids": ["1316", "1569"]},
    {"name": "ローズマリー", "speaker_ids": ["50104"]},
    {"name": "フルミーネ", "speaker_ids": ["50068", "50166"]},
    {"name": "アハブ", "speaker_ids": ["100040"]},
    {"name": "S.I.G.M.A.(シグマ)", "speaker_ids": ["100209"]},
)


def _windows_to_wsl(value: str) -> Path:
    match = re.fullmatch(r"([A-Za-z]):[\\/](.*)", str(value or "").strip())
    if not match:
        return Path(str(value or ""))
    tail = match.group(2).replace("\\", "/")
    return Path(f"/mnt/{match.group(1).lower()}/{tail}")  # storage-policy: external-read


def _identity(value: str) -> str:
    text = str(value or "").strip().casefold()
    text = text.replace("（", "(").replace("）", ")")
    return re.sub(r"[\s._・()]+", "", text)


def _catalog_name(value: str) -> str:
    wanted = _identity(value)
    aliases = {
        _identity("S.I.G.M.A."): "S.I.G.M.A.(シグマ)",
        _identity("シグマ"): "S.I.G.M.A.(シグマ)",
        _identity("SIGMA"): "S.I.G.M.A.(シグマ)",
    }
    if wanted in aliases:
        return aliases[wanted]
    for item in WUWA_NPC_CATALOG:
        if _identity(item["name"]) == wanted:
            return str(item["name"])
    return ""


def _reference_folder(character: str) -> Path:
    name = _catalog_name(character) or safe_name(character)
    return REFERENCE_ROOT / WUWA_GAME_NAME / "NPC" / safe_name(name)


def _metadata_path(character: str) -> Path:
    return _reference_folder(character) / "音声一覧.json"


def _read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return default


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def _duration(path: Path) -> float:
    try:
        return round(float(sf.info(str(path)).duration), 3)
    except Exception:
        return 0.0


def _is_acquired(character: str) -> bool:
    folder = _reference_folder(character)
    if _metadata_path(character).is_file():
        return True
    return folder.is_dir() and any(
        item.is_file() and item.suffix.casefold() == ".wav"
        for item in folder.iterdir()
    )


def list_characters() -> list[dict[str, Any]]:
    return [
        {
            "name": str(item["name"]),
            "speaker_ids": list(item["speaker_ids"]),
            "character_type": "npc",
            "acquired": _is_acquired(str(item["name"])),
            "resource_root": WUWA_RESOURCE_ROOT_WINDOWS,
        }
        for item in WUWA_NPC_CATALOG
    ]


def _explicit_name(mapping: dict[str, Any]) -> str:
    for key in ("name_ja", "name", "character", "npc", "speaker_name", "display_name"):
        value = mapping.get(key)
        if isinstance(value, str):
            name = _catalog_name(value)
            if name:
                return name
    return ""


def _wav_path(value: Any) -> Path | None:
    if not isinstance(value, str) or not value.strip().lower().endswith(".wav"):
        return None
    path = _windows_to_wsl(value.strip())
    return path if path.is_file() else None


def _record_from_mapping(mapping: dict[str, Any], character: str) -> dict[str, Any] | None:
    path: Path | None = None
    for key in ("wav", "wav_path", "path", "output", "output_path", "representative_wav", "代表WAV"):
        path = _wav_path(mapping.get(key))
        if path:
            break
    if path is None:
        for value in mapping.values():
            path = _wav_path(value)
            if path:
                break
    if path is None:
        return None

    transcript = ""
    for key in ("transcript", "text", "subtitle", "台詞", "japanese_text"):
        value = mapping.get(key)
        if isinstance(value, str) and value.strip():
            transcript = value.strip()
            break
    wem = ""
    for key in ("wem", "wem_path", "source_wem", "wem_name"):
        value = mapping.get(key)
        if isinstance(value, str) and value.strip():
            wem = value.strip()
            break
    event = ""
    for key in ("event", "event_name", "plot_audio", "plotaudio", "dialogue"):
        value = mapping.get(key)
        if isinstance(value, str) and value.strip():
            event = value.strip()
            break

    seconds = _duration(path)
    return {
        "selected": bool(1.5 <= seconds <= 12.0),
        "label": event or Path(wem).stem or path.stem,
        "transcript": transcript,
        "subtitle": transcript,
        "filename": path.name,
        "original_filename": path.name,
        "path": str(path),
        "duration": seconds,
        "reason": "" if 1.5 <= seconds <= 12.0 else "参照候補は1.5〜12秒のみ",
        "source_game": WUWA_GAME_NAME,
        "source_provider": WUWA_SOURCE_PROVIDER,
        "source_character": character,
        "source_media_id": wem or str(path),
        "source_event_paths": [event] if event else [],
        "source_resource_root": WUWA_RESOURCE_ROOT_WINDOWS,
    }


def _collect_nodes(value: Any, character: str, inherited: str = "") -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if isinstance(value, dict):
        current = _explicit_name(value) or inherited
        if current == character:
            record = _record_from_mapping(value, character)
            if record:
                records.append(record)
        for key, child in value.items():
            key_name = _catalog_name(str(key))
            records.extend(_collect_nodes(child, character, key_name or current))
    elif isinstance(value, list):
        for child in value:
            records.extend(_collect_nodes(child, character, inherited))
    return records


def _existing_records(character: str) -> list[dict[str, Any]]:
    metadata = _read_json(_metadata_path(character), {})
    files = metadata.get("files", []) if isinstance(metadata, dict) else []
    return [
        dict(item)
        for item in files
        if isinstance(item, dict) and Path(str(item.get("path") or "")).is_file()
    ]


def collect_character(character: str, max_events: int = 40) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    name = _catalog_name(character)
    if not name:
        raise ValueError("確認済みの鳴潮NPCを選択してください。")
    limit = max(1, int(max_events))

    existing = _existing_records(name)
    if existing:
        return existing[:limit], {"mode": "existing", "character": name}

    root = _windows_to_wsl(WUWA_RESEARCH_ROOT_WINDOWS)
    primary = _windows_to_wsl(WUWA_PRIMARY_MANIFEST_WINDOWS)
    manifests: list[Path] = []
    if primary.is_file():
        manifests.append(primary)
    if root.is_dir():
        manifests.extend(path for path in root.rglob("*.json") if path.is_file() and path != primary)

    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for manifest in manifests[:250]:
        payload = _read_json(manifest, None)
        if payload is None:
            continue
        for record in _collect_nodes(payload, name):
            identity = str(record.get("source_media_id") or record.get("path") or "")
            if not identity or identity in seen:
                continue
            seen.add(identity)
            records.append(record)
            if len(records) >= limit:
                break
        if len(records) >= limit:
            break
    if not records:
        raise FileNotFoundError(
            f"{name} の確認済みWAVを鳴潮調査マニフェストから見つけられません。"
            f" 日本語resource root: {WUWA_RESOURCE_ROOT_WINDOWS}"
        )
    return records, {
        "mode": "manifest",
        "character": name,
        "resource_root": WUWA_RESOURCE_ROOT_WINDOWS,
        "manifest": WUWA_PRIMARY_MANIFEST_WINDOWS,
    }


def import_selected(character: str, rows: list[list[Any]]) -> tuple[str, list[list[Any]]]:
    name = _catalog_name(character)
    if not name:
        raise ValueError("確認済みの鳴潮NPCを選択してください。")

    registry = _read_json(REGISTRY_PATH, {"speakers": {}})
    speakers = registry.get("speakers", {}) if isinstance(registry, dict) else {}
    if isinstance(speakers, dict) and name in speakers:
        raise FileExistsError(f"{name} は登録済みのため既存speakerを上書きしません。")

    folder = _reference_folder(name)
    metadata_path = _metadata_path(name)
    if folder.exists() and not metadata_path.is_file() and any(folder.iterdir()):
        raise FileExistsError(f"{name} の既存フォルダーを保護するため取り込みません。")

    metadata = _read_json(metadata_path, {})
    if not isinstance(metadata, dict):
        metadata = {}
    existing = metadata.get("files", [])
    existing = [dict(item) for item in existing if isinstance(item, dict)] if isinstance(existing, list) else []
    identities = {
        str(item.get("source_media_id") or item.get("original_filename") or "")
        for item in existing
    }

    selected: list[dict[str, Any]] = []
    for row in rows or []:
        if not row or not bool(row[0]):
            continue
        try:
            item = json.loads(str(row[6]))
        except (ValueError, IndexError) as exc:
            raise ValueError("鳴潮NPC取得一覧の形式が不正です。再取得してください。") from exc
        if item.get("source_game") != WUWA_GAME_NAME or item.get("source_provider") != WUWA_SOURCE_PROVIDER:
            raise ValueError("選択行が鳴潮NPCのローカル取得結果ではありません。")
        if _catalog_name(str(item.get("source_character") or "")) != name:
            raise ValueError("選択行が選択中NPCと一致しません。")
        item["transcript"] = str(row[2] or item.get("transcript") or "")
        item["subtitle"] = item["transcript"]
        item["selected"] = True
        selected.append(item)
    if not selected:
        raise ValueError("取り込む音声を1件以上選択してください。")

    folder.mkdir(parents=True, exist_ok=True)
    added = 0
    for item in selected:
        identity = str(item.get("source_media_id") or item.get("original_filename") or "").strip()
        if identity and identity in identities:
            continue
        source = Path(str(item.get("path") or ""))
        if not source.is_file() or source.suffix.casefold() != ".wav":
            raise FileNotFoundError(f"取得済みWAVがありません: {source.name}")
        destination = folder / safe_name(str(item.get("filename") or source.name), source.name)
        if destination.exists():
            if destination.stat().st_size == source.stat().st_size:
                item["path"] = str(destination)
                item["filename"] = destination.name
                existing.append(item)
                identities.add(identity)
                continue
            suffix = 2
            while destination.exists():
                destination = folder / f"{source.stem}_{suffix}{source.suffix}"
                suffix += 1
        shutil.copy2(source, destination)
        item["path"] = str(destination)
        item["filename"] = destination.name
        item["duration"] = _duration(destination)
        existing.append(item)
        identities.add(identity)
        added += 1

    metadata.update({
        "game": WUWA_GAME_NAME,
        "character": name,
        "character_type": "npc",
        "language": "ja",
        "source_mode": "local-game-assets",
        "source_provider": WUWA_SOURCE_PROVIDER,
        "source_resource_root": WUWA_RESOURCE_ROOT_WINDOWS,
        "updated_at": datetime.now().isoformat(timespec="seconds"),
        "files": existing,
        "download_errors": [],
    })
    _write_json(metadata_path, metadata)
    rows_out = [[
        bool(item.get("selected", True)), str(item.get("label", "")), str(item.get("transcript", "")),
        str(item.get("filename", "")), str(item.get("duration", "")), str(item.get("reason", "")),
        json.dumps(item, ensure_ascii=False),
    ] for item in existing]
    return f"{name}: 鳴潮NPC正式領域へ {added}件追加しました（合計 {len(existing)}件）。", rows_out


__all__ = [
    "WUWA_GAME_NAME",
    "WUWA_SOURCE_PROVIDER",
    "WUWA_NPC_CATALOG",
    "WUWA_RESOURCE_ROOT_WINDOWS",
    "list_characters",
    "collect_character",
    "import_selected",
]
