from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

AUDIO_SUFFIXES = {".wav", ".ogg", ".oga", ".mp3", ".flac"}
EXPECTED_CHARACTER = "メリル"
EXPECTED_WAV_COUNT = 46
EXPECTED_STANDARD_REF_COUNT = 29
EXPECTED_EMOTION_CACHE_COUNT = 29
EXPECTED_EMOTION_REFS = {"gentle.json": 23, "surprised.json": 19}


def hash_file(path: Path) -> str:
    h = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except Exception:
        return default


def write_json(path: Path, data: Any) -> None:
    path = Path(path)
    temp = path.with_name("." + path.name + ".phase2tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(path)


def record_filename(item: dict[str, Any]) -> str:
    raw = str(
        item.get("local_filename")
        or item.get("filename")
        or item.get("path")
        or ""
    ).strip()
    return raw.replace("\\", "/").rsplit("/", 1)[-1]


def source_key(item: dict[str, Any]) -> str:
    return str(
        item.get("source_key")
        or item.get("file_title")
        or item.get("id")
        or item.get("source_filename")
        or item.get("filename")
        or ""
    )


def compress_wav(path: Path) -> Path | None:
    import soundfile as sf

    path = Path(path)
    info = sf.info(path)
    if (
        path.suffix.lower() != ".wav"
        or info.subtype not in {"PCM_16", "PCM_24"}
        or path.stat().st_size < 524288
    ):
        return None

    dest = path.with_suffix(".flac")
    if dest.exists():
        return None

    temp = path.with_name("." + path.stem + "_" + uuid.uuid4().hex + ".flac")
    try:
        with sf.SoundFile(path) as inp, sf.SoundFile(
            temp,
            "w",
            samplerate=info.samplerate,
            channels=info.channels,
            format="FLAC",
            subtype=info.subtype,
        ) as out:
            while True:
                data = inp.read(65536, dtype="int32", always_2d=True)
                if not len(data):
                    break
                out.write(data)

        check = sf.info(temp)
        if (check.frames, check.samplerate, check.channels) != (
            info.frames,
            info.samplerate,
            info.channels,
        ):
            raise ValueError("FLACの再生時間・形式が一致しません。")

        with sf.SoundFile(path) as before, sf.SoundFile(temp) as after:
            while True:
                left = before.read(65536, dtype="int32", always_2d=True)
                right = after.read(65536, dtype="int32", always_2d=True)
                if left.shape != right.shape or not (left == right).all():
                    raise ValueError("FLACのPCMが一致しません。")
                if not len(left):
                    break

        if temp.stat().st_size >= path.stat().st_size:
            return None

        os.link(temp, dest)
        return dest
    finally:
        temp.unlink(missing_ok=True)


def _scan_tool_json_references(tool_root: Path, wav_names: set[str]) -> list[str]:
    hits: list[str] = []
    if not tool_root.is_dir():
        return hits

    for path in tool_root.rglob("*.json"):
        if not path.is_file():
            continue
        raw = path.read_text(encoding="utf-8-sig", errors="replace")
        if any(name in raw for name in wav_names):
            hits.append(str(path.relative_to(tool_root)))
    return hits


def _preflight(root: Path, tool_root: Path, character: str) -> dict[str, Any]:
    if character != EXPECTED_CHARACTER:
        raise ValueError("旧方式Phase2実機移行は現在、メリル1人だけに制限しています。")

    root = Path(root).resolve()
    folder = root / character
    meta_path = folder / "音声一覧.json"

    if folder.is_symlink() or meta_path.is_symlink():
        raise ValueError("保護対象にリンクがあるため旧方式Phase2移行を停止しました。")
    if not folder.is_dir() or not meta_path.is_file():
        raise ValueError("メリルの既存データを確認できないため停止しました。")

    ref_dir = folder / "参照セット"
    manifest_data: dict[Path, dict[str, Any]] = {}
    for seconds in (30, 60, 90, 120):
        pt = ref_dir / f"{seconds}秒.pt"
        manifest = ref_dir / f"{seconds}秒.json"
        if not pt.is_file() or not manifest.is_file():
            raise ValueError(f"{seconds}秒参照PT/JSONがそろっていないため停止しました。")

    precomputed = folder / "事前計算"
    if not precomputed.is_dir() or not any(p.is_file() for p in precomputed.rglob("*")):
        raise ValueError("事前計算が見つからないため旧方式Phase2移行を停止しました。")

    emotion_cache_path = folder / "emotion2vec_plus_base_embeddings.json"
    if not emotion_cache_path.is_file():
        raise ValueError("emotion2vecキャッシュが見つからないため停止しました。")

    emotion_dir = ref_dir / "感情別"
    emotion_manifests = (
        sorted(p for p in emotion_dir.glob("*.json") if p.is_file())
        if emotion_dir.is_dir()
        else []
    )
    if not emotion_manifests:
        raise ValueError("感情別参照JSONが見つからないため停止しました。")

    data = read_json(meta_path, None)
    if not isinstance(data, dict) or not isinstance(data.get("files"), list):
        raise ValueError("音声一覧.jsonを安全に読めません。")

    rows = [item for item in data["files"] if isinstance(item, dict)]
    wavs = sorted(
        (
            p
            for p in folder.iterdir()
            if p.is_file() and p.suffix.lower() == ".wav"
        ),
        key=lambda p: p.name.casefold(),
    )
    flacs = [
        p
        for p in folder.iterdir()
        if p.is_file() and p.suffix.lower() == ".flac"
    ]
    if len(wavs) != EXPECTED_WAV_COUNT or flacs:
        raise ValueError(
            f"メリルの音声件数が実機監査時から変化しています："
            f"WAV={len(wavs)} / FLAC={len(flacs)}"
        )

    by_local: dict[str, list[dict[str, Any]]] = {}
    for item in rows:
        filename = record_filename(item)
        if filename:
            by_local.setdefault(filename, []).append(item)

    for wav in wavs:
        if len(by_local.get(wav.name, [])) != 1:
            raise ValueError(f"音声一覧との対応が一意でないため停止しました：{wav.name}")
        conflicts = [
            p.name
            for p in folder.iterdir()
            if p.is_file()
            and p != wav
            and p.stem.casefold() == wav.stem.casefold()
            and p.suffix.lower() in AUDIO_SUFFIXES
        ]
        if conflicts:
            raise ValueError(
                f"同じ名前の別音声形式があるため停止しました："
                f"{wav.name} / {','.join(conflicts)}"
            )

    wav_names = {p.name for p in wavs}

    for seconds in (30, 60, 90, 120):
        path = ref_dir / f"{seconds}秒.json"
        value = read_json(path, None)
        if not isinstance(value, dict) or not isinstance(value.get("files"), list):
            raise ValueError(f"{seconds}秒参照JSONのfilesを安全に読めません。")
        names = [str(x) for x in value["files"]]
        if (
            len(names) != EXPECTED_STANDARD_REF_COUNT
            or any(name not in wav_names for name in names)
        ):
            raise ValueError(
                f"{seconds}秒参照JSONが実機監査時の29件と一致しません。"
            )
        manifest_data[path] = value

    if {path.name for path in emotion_manifests} != set(EXPECTED_EMOTION_REFS):
        raise ValueError("感情別参照JSONの構成が実機監査時から変化しています。")

    emotion_data: dict[Path, dict[str, Any]] = {}
    for path in emotion_manifests:
        value = read_json(path, None)
        if not isinstance(value, dict) or not isinstance(value.get("files_in_order"), list):
            raise ValueError(f"感情別参照JSONを安全に読めません：{path.name}")
        names = [str(x) for x in value["files_in_order"]]
        if (
            len(names) != EXPECTED_EMOTION_REFS[path.name]
            or any(name not in wav_names for name in names)
        ):
            raise ValueError(
                f"感情別参照JSONが実機監査時と一致しません：{path.name}"
            )
        emotion_data[path] = value

    emotion_cache = read_json(emotion_cache_path, None)
    items = emotion_cache.get("items") if isinstance(emotion_cache, dict) else None
    if not isinstance(items, dict) or len(items) != EXPECTED_EMOTION_CACHE_COUNT:
        raise ValueError("emotion2vecキャッシュが実機監査時の29件と一致しません。")
    for filename, item in items.items():
        if (
            filename not in wav_names
            or not isinstance(item, dict)
            or not isinstance(item.get("embedding"), list)
            or not item.get("embedding")
        ):
            raise ValueError(
                f"emotion2vecキャッシュに想定外の対応があります：{filename}"
            )

    allowed_json = {meta_path.resolve(), emotion_cache_path.resolve()}
    allowed_json.update(path.resolve() for path in manifest_data)
    allowed_json.update(path.resolve() for path in emotion_data)

    for path in folder.rglob("*.json"):
        if not path.is_file() or path.resolve() in allowed_json:
            continue
        raw = path.read_text(encoding="utf-8-sig", errors="replace")
        found = [name for name in wav_names if name in raw]
        if found:
            raise ValueError(
                f"想定外JSONがWAV名を参照しています：{path.relative_to(folder)}"
            )

    external_hits = _scan_tool_json_references(Path(tool_root), wav_names)
    if external_hits:
        raise ValueError(
            "ツール側JSONがメリルWAV名を参照しているため停止しました："
            + ",".join(external_hits)
        )

    selected_before = {
        source_key(item): item.get("selected")
        for item in rows
    }

    protected = [
        p
        for p in folder.rglob("*")
        if p.is_file() and p.suffix.lower() == ".pt"
    ]
    protected_hashes = {str(p): hash_file(p) for p in protected}

    return {
        "folder": folder,
        "meta_path": meta_path,
        "data": data,
        "rows": rows,
        "by_local": by_local,
        "wavs": wavs,
        "manifest_data": manifest_data,
        "emotion_data": emotion_data,
        "emotion_cache_path": emotion_cache_path,
        "emotion_cache": emotion_cache,
        "selected_before": selected_before,
        "protected_hashes": protected_hashes,
    }


def migrate(
    root: Path,
    tool_root: Path,
    character: str = EXPECTED_CHARACTER,
    compressor: Callable[[Path], Path | None] = compress_wav,
) -> dict[str, Any]:
    state = _preflight(Path(root), Path(tool_root), character)

    folder: Path = state["folder"]
    meta_path: Path = state["meta_path"]
    data: dict[str, Any] = state["data"]
    by_local: dict[str, list[dict[str, Any]]] = state["by_local"]
    wavs: list[Path] = state["wavs"]
    manifest_data: dict[Path, dict[str, Any]] = state["manifest_data"]
    emotion_data: dict[Path, dict[str, Any]] = state["emotion_data"]
    emotion_cache_path: Path = state["emotion_cache_path"]
    emotion_cache: dict[str, Any] = state["emotion_cache"]

    json_objects: dict[Path, dict[str, Any]] = {
        meta_path: data,
        emotion_cache_path: emotion_cache,
    }
    json_objects.update(manifest_data)
    json_objects.update(emotion_data)

    original_json = {path: path.read_bytes() for path in json_objects}
    created: list[Path] = []
    mapping: dict[str, str] = {}
    skipped: list[str] = []
    saved_bytes = 0
    deletion_started = False

    try:
        for wav in wavs:
            dest = compressor(wav)
            if dest is None:
                skipped.append(wav.name)
                continue
            created.append(dest)
            mapping[wav.name] = dest.name

        if not mapping:
            raise ValueError("圧縮可能なWAVが1件もありません。")

        now = datetime.now().isoformat(timespec="seconds")

        for old_name, new_name in mapping.items():
            item = by_local[old_name][0]
            wav = folder / old_name
            dest = folder / new_name
            before_size = wav.stat().st_size
            item.setdefault("source_key", source_key(item))
            item.setdefault("source_filename", item.get("filename", old_name))
            item.update(
                local_filename=new_name,
                local_format="flac",
                local_sha256=hash_file(dest),
                path=str(dest),
                phase2_original_filename=old_name,
                phase2_original_size=before_size,
                phase2_original_sha256=hash_file(wav),
                phase2_pcm_verified=True,
                phase2_migrated_at=now,
            )
            saved_bytes += before_size - dest.stat().st_size

        for value in manifest_data.values():
            value["files"] = [
                mapping.get(str(name), str(name))
                for name in value["files"]
            ]

        for value in emotion_data.values():
            value["files_in_order"] = [
                mapping.get(str(name), str(name))
                for name in value["files_in_order"]
            ]

        cache_items = emotion_cache["items"]
        for old_name, new_name in mapping.items():
            if old_name not in cache_items:
                continue
            if new_name in cache_items:
                raise ValueError(
                    f"emotion2vecキャッシュに移行先名が既にあります：{new_name}"
                )
            cache_item = dict(cache_items.pop(old_name))
            cache_item["size"] = (folder / new_name).stat().st_size
            cache_items[new_name] = cache_item
        emotion_cache["phase2_migrated_at"] = now

        for path, value in json_objects.items():
            write_json(path, value)

        for old_name in mapping:
            raw = meta_path.read_text(encoding="utf-8-sig", errors="replace")
            if old_name in raw:
                source_name = by_local[old_name][0].get("source_filename")
                if str(source_name or "") != old_name:
                    raise ValueError(f"音声一覧に旧WAV名が残っています：{old_name}")

        for path in list(manifest_data) + list(emotion_data) + [emotion_cache_path]:
            raw = path.read_text(encoding="utf-8-sig", errors="replace")
            stale = [old_name for old_name in mapping if old_name in raw]
            if stale:
                raise ValueError(
                    f"依存JSONに旧WAV名が残っています："
                    f"{path.name} / {','.join(stale)}"
                )

        protected_after = {
            str(Path(path)): hash_file(Path(path))
            for path in state["protected_hashes"]
        }
        if protected_after != state["protected_hashes"]:
            raise ValueError("既存PTまたは事前計算のハッシュが変化したため停止しました。")

        latest = read_json(meta_path, {})
        latest_rows = [
            item
            for item in latest.get("files", [])
            if isinstance(item, dict)
        ]
        selected_after = {
            source_key(item): item.get("selected")
            for item in latest_rows
        }
        if selected_after != state["selected_before"]:
            raise ValueError("selected状態が変化したため停止しました。")

        deletion_started = True
        leftovers: list[str] = []
        for old_name, new_name in mapping.items():
            wav = folder / old_name
            dest = folder / new_name
            if not dest.is_file():
                raise ValueError(f"移行先FLACがありません：{new_name}")
            try:
                wav.unlink()
            except Exception:
                leftovers.append(old_name)

        return {
            "character": character,
            "converted_count": len(mapping),
            "converted": [
                {"wav": old_name, "flac": new_name}
                for old_name, new_name in mapping.items()
            ],
            "skipped": skipped,
            "saved_bytes": saved_bytes,
            "protected_pt_count": len(state["protected_hashes"]),
            "updated_json_count": len(json_objects),
            "wav_cleanup_leftovers": leftovers,
        }
    except Exception as exc:
        if not deletion_started:
            for path, raw in original_json.items():
                try:
                    temp = path.with_name("." + path.name + ".phase2rollback")
                    temp.write_bytes(raw)
                    temp.replace(path)
                except Exception:
                    pass
            for path in created:
                try:
                    path.unlink(missing_ok=True)
                except Exception:
                    pass
        raise ValueError(f"メリル旧方式Phase2移行に失敗しました：{exc}") from exc


def _build_fixture(root: Path, tool_root: Path) -> tuple[Path, list[Path]]:
    folder = root / EXPECTED_CHARACTER
    folder.mkdir(parents=True)

    rows: list[dict[str, Any]] = []
    wavs: list[Path] = []
    for index in range(EXPECTED_WAV_COUNT):
        name = f"meryl_{index:02d}.wav"
        wav = folder / name
        wav.write_bytes((f"wav-{index:02d}-".encode("ascii")) * 100000)
        wavs.append(wav)
        rows.append(
            {
                "filename": name,
                "local_filename": name,
                "file_title": f"File:Meryl{index:02d}",
                "url": f"https://example.invalid/{name}",
                "selected": index % 2 == 0,
            }
        )

    write_json(
        folder / "音声一覧.json",
        {
            "character": EXPECTED_CHARACTER,
            "files": rows,
            "selection_confirmed_at": "self-test",
        },
    )

    ref = folder / "参照セット"
    ref.mkdir()
    used = [wav.name for wav in wavs[:29]]

    for seconds in (30, 60, 90, 120):
        (ref / f"{seconds}秒.pt").write_bytes(
            f"protected-{seconds}".encode("ascii")
        )
        write_json(
            ref / f"{seconds}秒.json",
            {
                "character": EXPECTED_CHARACTER,
                "target_seconds": seconds,
                "actual_seconds": float(seconds),
                "files": used,
            },
        )

    precomputed = folder / "事前計算"
    precomputed.mkdir()
    (precomputed / "meryl_00.pt").write_bytes(b"protected-precomputed")

    emotion_dir = ref / "感情別"
    emotion_dir.mkdir()
    emotion_counts = {"gentle": 23, "surprised": 19}
    for emotion, count in emotion_counts.items():
        (emotion_dir / f"{emotion}.pt").write_bytes(
            ("protected-" + emotion).encode("ascii")
        )
        write_json(
            emotion_dir / f"{emotion}.json",
            {
                "character": EXPECTED_CHARACTER,
                "emotion_key": emotion,
                "files_in_order": [wav.name for wav in wavs[:count]],
            },
        )

    write_json(
        folder / "emotion2vec_plus_base_embeddings.json",
        {
            "model": "iic/emotion2vec_plus_base",
            "items": {
                wav.name: {
                    "size": wav.stat().st_size,
                    "embedding": [float(index), 1.0],
                }
                for index, wav in enumerate(wavs[:29])
            },
        },
    )

    tool_root.mkdir(parents=True, exist_ok=True)
    return folder, wavs


def _fake_compress(path: Path) -> Path:
    dest = path.with_suffix(".flac")
    dest.write_bytes(b"flac-" + path.read_bytes()[:1000])
    return dest


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="meryl_phase2_selftest_") as temp:
        base = Path(temp)
        root = base / "refs"
        tool_root = base / "tool"
        root.mkdir()
        folder, wavs = _build_fixture(root, tool_root)

        protected_before = {
            path: path.read_bytes()
            for path in folder.rglob("*.pt")
        }

        result = migrate(
            root,
            tool_root,
            compressor=_fake_compress,
        )

        assert result["converted_count"] == EXPECTED_WAV_COUNT
        assert result["wav_cleanup_leftovers"] == []
        assert result["skipped"] == []
        assert not any(wav.exists() for wav in wavs)
        assert len(list(folder.glob("*.flac"))) == EXPECTED_WAV_COUNT

        for path, before in protected_before.items():
            assert path.read_bytes() == before

        metadata = read_json(folder / "音声一覧.json", {})
        assert all(
            str(row.get("local_filename", "")).endswith(".flac")
            for row in metadata["files"]
        )

        cache = read_json(
            folder / "emotion2vec_plus_base_embeddings.json",
            {},
        )
        assert len(cache["items"]) == EXPECTED_EMOTION_CACHE_COUNT
        assert all(name.endswith(".flac") for name in cache["items"])

    with tempfile.TemporaryDirectory(prefix="meryl_phase2_block_") as temp:
        base = Path(temp)
        root = base / "refs"
        tool_root = base / "tool"
        root.mkdir()
        folder, wavs = _build_fixture(root, tool_root)
        write_json(folder / "unexpected.json", {"file": wavs[0].name})
        try:
            migrate(root, tool_root, compressor=_fake_compress)
        except ValueError as exc:
            if "想定外JSON" not in str(exc):
                raise
        else:
            raise AssertionError("unexpected JSON reference must block migration")

        assert all(wav.exists() for wav in wavs)
        assert not any(folder.glob("*.flac"))

    print("MERYL_PHASE2_SELF_TEST=PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--root",
        default="/mnt/d/AI生成ファイル/Irodori-TTS/参照音声",
    )
    parser.add_argument(
        "--tool-root",
        default="/mnt/d/AI生成ファイル/Irodori-TTS/Fandom音声ツール",
    )
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    result = migrate(
        Path(args.root),
        Path(args.tool_root),
    )
    print(
        "PHASE2_RESULT="
        + json.dumps(
            result,
            ensure_ascii=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
