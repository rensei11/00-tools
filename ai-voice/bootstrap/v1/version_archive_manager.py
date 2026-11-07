"""Archive all published AI-voice code releases and restore one deliberately.

Standard-library only. This never copies or deletes model, reference-audio,
generated-audio or speaker/history data. The archive is append-only.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import uuid


REPO_API = "https://api.github.com/repos/rensei11/00-tools"
RELEASES_API = REPO_API + "/contents/ai-voice/releases?ref=main"
UPDATER_URL = (
    "https://raw.githubusercontent.com/rensei11/00-tools/main/"
    "ai-voice/bootstrap/v1/migrate_updater_bootstrap_v1.ps1"
)
ARCHIVE_REL = Path("_backup") / "ai_voice_version_archive"
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
VERSION_RE = re.compile(r"(?:v\d+\.\d+|\d{4}-\d\d-\d\d-v\d+)\Z")
FILE_RE = re.compile(r"\d{4}-\d\d-\d\d-v[\w.]+\.json\Z", re.ASCII)
ALLOWED_SUFFIXES = {".py", ".ps1", ".cmd", ".bat", ".js", ".json", ".md"}
PROTECTED_NAMES = {
    "speakers.json", "games.json", "pronunciation_dictionary.json",
    "generation_history.jsonl", "conversation_auto_queue.json",
    "start fandom tool.cmd", "start_fandom_tool.cmd", "updater_bootstrap.ps1",
    "startup_update_check.ps1", "update_and_start.ps1",
    "hermes_task.json",
}
PROTECTED_DIRS = {
    ".git", ".github", "_backup", "参照音声", "音声", "shared_results",
}
MAX_RESPONSE = 12 * 1024 * 1024


def fetch_json(url: str) -> object:
    if not (url.startswith(REPO_API + "/") or url == RELEASES_API):
        raise ValueError("Unexpected archive API URL")
    req = urllib.request.Request(
        url, headers={"User-Agent": "AI-Voice-Version-Archive/1", "Accept": "application/vnd.github+json"}
    )
    with urllib.request.urlopen(req, timeout=45) as response:
        raw = response.read(MAX_RESPONSE + 1)
    if len(raw) > MAX_RESPONSE:
        raise ValueError("GitHub archive response is unexpectedly large")
    return json.loads(raw.decode("utf-8"))


def git_blob_sha(raw: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(raw)).encode("ascii") + b"\0" + raw).hexdigest()


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def safe_managed_path(filename: str) -> str | None:
    if not isinstance(filename, str) or not filename or "\\" in filename:
        raise ValueError("Unsafe manifest path")
    if ":" in filename or any(ord(char) < 32 for char in filename):
        raise ValueError("Unsafe manifest path")
    path = PurePosixPath(filename)
    parts = filename.split("/")
    if path.is_absolute() or any(p in ("", ".", "..") or p[-1:] in (".", " ") for p in parts):
        raise ValueError("Unsafe manifest path")
    if any(re.search(r"[<>|?*]", part) for part in parts):
        raise ValueError("Unsafe manifest path")
    if "shared_results" in (p.lower() for p in parts[:-1]):
        return None
    if parts[-1].lower() == "hermes_task.json":
        return None
    if any(p.lower() in PROTECTED_DIRS for p in parts[:-1]):
        raise ValueError("Protected directory in manifest")
    if parts[-1].lower() in PROTECTED_NAMES:
        raise ValueError("Protected file in manifest")
    if path.suffix.lower() not in ALLOWED_SUFFIXES:
        return None
    return filename


def inspect_manifest(raw: bytes) -> tuple[str, dict[str, str]]:
    value = json.loads(raw.decode("utf-8-sig"))
    if not isinstance(value, dict) or not isinstance(value.get("files"), dict):
        raise ValueError("Release must contain a files map")
    version = value.get("version")
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        raise ValueError("Invalid release version")
    safe: dict[str, str] = {}
    seen: set[str] = set()
    for name, content in value["files"].items():
        normalized = safe_managed_path(name)
        if normalized is None:
            continue
        if normalized.casefold() in seen:
            raise ValueError("Duplicate Windows release filename")
        seen.add(normalized.casefold())
        if not isinstance(content, str):
            raise ValueError("Non-text release content")
        if normalized.lower().endswith((".cmd", ".bat")) and not content.isascii():
            raise ValueError("Batch file contains non-ASCII text")
        safe[normalized] = content
    if not safe or "app.py" not in safe:
        raise ValueError("Release does not include a usable app.py")
    return version, safe


def archive_root(tool_root: Path) -> Path:
    if not (tool_root / "app.py").is_file():
        raise ValueError("The selected folder does not contain the installed app.py")
    root = tool_root / ARCHIVE_REL
    for part in (tool_root, tool_root / "_backup", root, root / "manifests"):
        if part.exists() and part.is_symlink():
            raise ValueError("Archive directory is a symbolic link")
    (root / "manifests").mkdir(parents=True, exist_ok=True)
    return root


def write_new_immutable(path: Path, raw: bytes) -> None:
    if path.exists():
        if path.read_bytes() != raw:
            raise ValueError("Existing archive is different; refusing to overwrite: " + str(path))
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation: never silently replace a historical archive.
    with path.open("xb") as out:
        out.write(raw)
        out.flush()
        os.fsync(out.fileno())


def local_releases(root: Path) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for path in sorted((root / "manifests").glob("*.json")):
        match = re.fullmatch(r"(.+)--([0-9a-f]{40})\.json", path.name)
        if not match:
            raise ValueError("Unexpected archive filename: " + path.name)
        raw = path.read_bytes()
        if git_blob_sha(raw) != match.group(2):
            raise ValueError("Damaged saved release: " + path.name)
        version, files = inspect_manifest(raw)
        result.append({"path": path, "version": version, "files": files, "sha256": sha256(raw)})
    return result


def download_all(tool_root: Path) -> None:
    root = archive_root(tool_root)
    listing = fetch_json(RELEASES_API)
    if not isinstance(listing, list):
        raise ValueError("Published release listing is unavailable")
    records = []
    for item in listing:
        if not isinstance(item, dict):
            raise ValueError("Unexpected release listing entry")
        name, blob = item.get("name"), item.get("sha")
        if not isinstance(name, str) or not FILE_RE.fullmatch(name):
            continue
        if not isinstance(blob, str) or not SHA_RE.fullmatch(blob):
            raise ValueError("Release has invalid Git object identifier")
        records.append((name, blob))
    if not records:
        raise ValueError("Published release listing was empty")

    for count, (name, blob) in enumerate(records, 1):
        path = root / "manifests" / (name[:-5] + "--" + blob + ".json")
        if path.is_file():
            raw = path.read_bytes()
        else:
            response = fetch_json(REPO_API + "/git/blobs/" + blob)
            if not isinstance(response, dict) or response.get("sha") != blob or response.get("encoding") != "base64":
                raise ValueError("GitHub returned the wrong release blob")
            raw = base64.b64decode(response["content"], validate=False)
        if git_blob_sha(raw) != blob:
            raise ValueError("Release hash mismatch: " + name)
        version, files = inspect_manifest(raw)
        write_new_immutable(path, raw)
        print(f"[{count}/{len(records)}] {version} / {len(files)} files / verified")

    all_local = local_releases(root)
    if len(all_local) < len(records):
        raise ValueError("One or more archived releases could not be verified")
    # This mutable completion marker is only a cache; archived blobs never change.
    complete_path = root / "archive-complete.json"
    complete_temp = root / ("archive-complete-" + uuid.uuid4().hex + ".tmp")
    complete_temp.write_text(json.dumps({
        "completed_at": dt.datetime.now().isoformat(),
        "published": [{"name": name, "sha": blob} for name, blob in records],
    }, indent=2), encoding="utf-8")
    os.replace(complete_temp, complete_path)
    print(f"Archive complete: {len(records)} published releases; saved at {root}")


def list_versions(tool_root: Path) -> None:
    root = archive_root(tool_root)
    releases = local_releases(root)
    for record in releases:
        print(f"{record['version']}: {len(record['files'])} files / verified")
    print(f"Verified local releases: {len(releases)}")


def validate_runtime_path(tool_root: Path, relative: str) -> Path:
    safe_managed_path(relative)
    full = tool_root.joinpath(*relative.split("/"))
    cursor = tool_root
    for part in relative.split("/")[:-1]:
        cursor = cursor / part
        if cursor.exists() and cursor.is_symlink():
            raise ValueError("Symbolic-link path blocks safe restore: " + relative)
    if full.is_symlink():
        raise ValueError("Symbolic-link file blocks safe restore: " + relative)
    return full


def snapshot_current(tool_root: Path, archive: Path, affected: set[str], label: str) -> Path:
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    target = archive / "snapshots" / (stamp + "-" + uuid.uuid4().hex[:8])
    target.mkdir(parents=True, exist_ok=False)
    existing, absent = [], []
    for relative in sorted(affected):
        original = validate_runtime_path(tool_root, relative)
        if original.exists():
            if not original.is_file():
                raise ValueError("Restore would affect a non-file: " + relative)
            destination = target / "files" / Path(*relative.split("/"))
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, destination)
            before_hash = sha256(original.read_bytes())
            if sha256(destination.read_bytes()) != before_hash:
                raise ValueError("Snapshot verification failed: " + relative)
            existing.append({"name": relative, "sha256": before_hash})
        else:
            absent.append(relative)
    metadata = {"label": label, "taken_at": dt.datetime.now().isoformat(),
                "present": existing, "absent": absent}
    write_new_immutable(target / "snapshot.json", json.dumps(metadata, ensure_ascii=False, indent=2).encode("utf-8"))
    return target


def restore(tool_root: Path, requested: str, *, execute: bool) -> None:
    root = archive_root(tool_root)
    releases = local_releases(root)
    matches = [release for release in releases if release["version"] == requested]
    if len(matches) != 1:
        raise ValueError(f"Need exactly one verified archived release for {requested}; found {len(matches)}")
    selected = matches[0]
    target_files = set(selected["files"])
    all_managed = set().union(*(set(item["files"]) for item in releases))
    # Preserve everything not explicitly distributed in a historical release.
    obsolete = sorted(all_managed - target_files)
    affected = target_files | set(obsolete)
    for relative in affected:
        validate_runtime_path(tool_root, relative)
    print(f"Selected: {requested} / replace {len(target_files)} / remove obsolete known files {len(obsolete)}")
    if not execute:
        print("PREVIEW ONLY: no application files changed")
        return

    updater_bytes: bytes
    # Fetch the official updater to a new isolated filename. It must include
    # the exact opt-in restore contract, otherwise fail before any changes.
    req = urllib.request.Request(UPDATER_URL, headers={"User-Agent": "AI-Voice-Version-Archive/1"})
    with urllib.request.urlopen(req, timeout=45) as response:
        updater_bytes = response.read(200_001)
    if len(updater_bytes) > 200_000 or b"RestoreArchivedVersion" not in updater_bytes:
        raise ValueError("Published updater has no supported archive restore operation")
    updater = root / ("verified_restore_updater--" + sha256(updater_bytes) + ".ps1")
    write_new_immutable(updater, updater_bytes)

    backup = snapshot_current(tool_root, root, affected, "before restore to " + requested)
    request_dir = root / "requests" / uuid.uuid4().hex
    request_dir.mkdir(parents=True, exist_ok=False)
    index = {
        "schema": 1,
        "version": selected["version"],
        "manifest_path": os.path.relpath(selected["path"], request_dir).replace("\\", "/"),
        "manifest_sha256": selected["sha256"],
        "remove_paths": obsolete,
    }
    index_path = request_dir / "restore-index.json"
    write_new_immutable(index_path, json.dumps(index, indent=2).encode("utf-8"))
    print("Verified pre-restore snapshot: " + str(backup))
    result = subprocess.run([
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(updater),
        "-ToolRoot", str(tool_root), "-IndexPath", str(index_path), "-RestoreArchivedVersion",
    ], check=False)
    if result.returncode:
        raise RuntimeError(f"Restore failed (exit {result.returncode}); original snapshot retained at {backup}")
    pin = root / "pinned-version.txt"
    if not pin.is_file() or pin.read_text(encoding="ascii").strip() != requested:
        raise RuntimeError("Restored but pinned-version verification failed; do not run automatic update")
    print("Restored and pinned: " + requested)


def unpin(tool_root: Path) -> None:
    pin = archive_root(tool_root) / "pinned-version.txt"
    if pin.is_file():
        if pin.is_symlink():
            raise ValueError("Refusing to change a symbolic-link pin")
        pin.unlink()
    print("Automatic updates enabled again; saved archives are unchanged")


def menu(tool_root: Path) -> None:
    while True:
        print("\nAI音声ツール：過去版の保存と復元")
        print("1. 公開済みの全バージョンを保存・照合")
        print("2. 保存済みバージョン一覧")
        print("3. 指定した過去版へ復元")
        print("4. 過去版の固定を解除し、通常更新へ戻す")
        print("0. 終了")
        choice = input("番号を入力してください: ").strip()
        if choice == "0":
            return
        try:
            if choice == "1":
                download_all(tool_root)
            elif choice == "2":
                list_versions(tool_root)
            elif choice == "3":
                list_versions(tool_root)
                version = input("戻したい版を入力してください（例: v2.30）: ").strip()
                if not VERSION_RE.fullmatch(version):
                    raise ValueError("版の入力形式が正しくありません")
                restore(tool_root, version, execute=False)
                print("復元すると現在のプログラムが置き換わります。")
                print("現在のプログラムは別フォルダーに保存します。音声・キャラクター・履歴は変更しません。")
                confirm = input("実際に復元する場合は『復元する』と入力してください: ").strip()
                if confirm == "復元する":
                    restore(tool_root, version, execute=True)
                else:
                    print("中止しました。")
            elif choice == "4":
                print("固定を解除すると、次回起動時に最新版への更新が再開されます。")
                if input("解除する場合は『解除する』と入力してください: ").strip() == "解除する":
                    unpin(tool_root)
                else:
                    print("中止しました。")
            else:
                print("0～4の番号で選んでください。")
        except (OSError, ValueError, KeyError, RuntimeError, urllib.error.URLError) as exc:
            print("処理を停止しました: " + str(exc), file=sys.stderr)


def main() -> int:
    cli = argparse.ArgumentParser(description="AI voice: archive every release and restore a chosen version")
    cli.add_argument("action", choices=("archive", "list", "preview", "restore", "unpin", "menu"))
    cli.add_argument("--tool-root", type=Path, default=Path(__file__).resolve().parent)
    cli.add_argument("--version", help="Version to preview or restore")
    args = cli.parse_args()
    root = args.tool_root.resolve()
    if args.action == "archive":
        download_all(root)
    elif args.action == "list":
        list_versions(root)
    elif args.action in ("preview", "restore"):
        if not args.version or not VERSION_RE.fullmatch(args.version):
            raise ValueError("A valid --version is required")
        restore(root, args.version, execute=(args.action == "restore"))
    elif args.action == "unpin":
        unpin(root)
    elif args.action == "menu":
        menu(root)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, urllib.error.URLError) as exc:
        print("FAILED: " + str(exc), file=sys.stderr)
        sys.exit(1)
