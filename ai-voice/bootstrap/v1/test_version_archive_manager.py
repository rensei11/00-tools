"""Offline tests: never touch the real Windows installation."""

from __future__ import annotations

import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock


SOURCE = Path(__file__).with_name("version_archive_manager.py")
spec = importlib.util.spec_from_file_location("version_archive_manager", SOURCE)
manager = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(manager)


def release_bytes(version: str, extras: dict[str, str] | None = None) -> bytes:
    return json.dumps({"version": version, "files": {"app.py": "APP_VERSION = '" + version + "'\n", **(extras or {})}},
                      ensure_ascii=False, indent=2).encode("utf-8")


class ArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.tool = Path(self.temp.name) / "installed-app"
        self.tool.mkdir()
        (self.tool / "app.py").write_text("APP_VERSION = 'v2.31'\n", encoding="utf-8")

    def test_archive_new_numbers_preserves_and_verifies_every_blob(self) -> None:
        old = release_bytes("v2.30", {"old.py": "old"})
        new = release_bytes("v2.31", {"new.py": "new"})
        samples = [("2026-11-02-v2.30.json", old), ("2026-11-02-v2.31.json", new)]
        listing = [{"name": name, "sha": manager.git_blob_sha(raw)} for name, raw in samples]
        blobs = {manager.git_blob_sha(raw): raw for _, raw in samples}

        def fake_fetch(url: str) -> object:
            if url == manager.RELEASES_API:
                return listing
            identifier = url.rsplit("/", 1)[-1]
            raw = blobs[identifier]
            return {"sha": identifier, "encoding": "base64", "content": base64.b64encode(raw).decode("ascii")}

        with mock.patch.object(manager, "fetch_json", side_effect=fake_fetch):
            manager.download_all(self.tool)
            manager.download_all(self.tool)

        archive = manager.archive_root(self.tool)
        verified = manager.local_releases(archive)
        self.assertEqual({x["version"] for x in verified}, {"v2.30", "v2.31"})
        self.assertEqual(len(verified), 2)
        manager.restore(self.tool, "v2.30", execute=False)
        self.assertFalse((self.tool / "old.py").exists())
        self.assertEqual((self.tool / "app.py").read_text(encoding="utf-8"), "APP_VERSION = 'v2.31'\n")

        oldest = next(x for x in verified if x["version"] == "v2.30")
        oldest["path"].write_bytes(b"corrupted")
        with self.assertRaisesRegex(ValueError, "Damaged saved release"):
            manager.local_releases(archive)

    def test_ignores_legacy_releases_without_deleting_existing_archive(self) -> None:
        legacy = release_bytes("2026-10-02-v13")
        below_cutoff = release_bytes("v2.19")
        new = release_bytes("v2.20")
        future = release_bytes("v3.0")
        samples = [
            ("2026-10-02-v13.json", legacy),
            ("2026-10-27-v2.19.json", below_cutoff),
            ("2026-10-28-v2.20.json", new),
            ("2026-12-01-v3.0.json", future),
        ]
        listing = [{"name": name, "sha": manager.git_blob_sha(raw)} for name, raw in samples]
        blobs = {manager.git_blob_sha(raw): raw for _, raw in samples}
        requested_blobs = []

        def fake_fetch(url: str) -> object:
            if url == manager.RELEASES_API:
                return listing
            identifier = url.rsplit("/", 1)[-1]
            requested_blobs.append(identifier)
            return {"sha": identifier, "encoding": "base64", "content": base64.b64encode(blobs[identifier]).decode("ascii")}

        archive = manager.archive_root(self.tool)
        legacy_path = archive / "manifests" / ("2026-10-02-v13--" + manager.git_blob_sha(legacy) + ".json")
        manager.write_new_immutable(legacy_path, legacy)
        with mock.patch.object(manager, "fetch_json", side_effect=fake_fetch):
            manager.download_all(self.tool)

        self.assertEqual(set(requested_blobs), {manager.git_blob_sha(new), manager.git_blob_sha(future)})
        self.assertEqual({x["version"] for x in manager.local_releases(archive)}, {"v2.20", "v3.0"})
        self.assertTrue(legacy_path.exists(), "Previously saved legacy archive must never be removed")
        with self.assertRaisesRegex(ValueError, "Only new-number"):
            manager.restore(self.tool, "2026-10-02-v13", execute=False)

    def test_snapshot_copies_code_only_and_never_touches_user_data(self) -> None:
        (self.tool / "speaker.json").write_text("PERSONAL", encoding="utf-8")
        (self.tool / "new.py").write_text("new code", encoding="utf-8")
        archive = manager.archive_root(self.tool)
        snap = manager.snapshot_current(self.tool, archive, {"app.py", "new.py", "gone.py"}, "test")
        self.assertEqual((snap / "files" / "new.py").read_text(encoding="utf-8"), "new code")
        self.assertFalse((snap / "files" / "speaker.json").exists())
        self.assertEqual((self.tool / "speaker.json").read_text(encoding="utf-8"), "PERSONAL")
        record = json.loads((snap / "snapshot.json").read_text(encoding="utf-8"))
        self.assertIn("gone.py", record["absent"])

    def test_rejects_unsafe_manifest_and_non_ascii_batch(self) -> None:
        for extra in ({"../speaker.json": "bad"}, {"参照音声/file.json": "bad"},
                      {"start_fandom_tool.cmd": "bad"}, {"bad.cmd": "日本語"},
                      {"app.py": 123}):
            obj = {"version": "v2.31", "files": {"app.py": "valid", **extra}}
            with self.assertRaises(ValueError):
                manager.inspect_manifest(json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def test_skips_release_files_that_may_hold_local_state(self) -> None:
        raw = release_bytes("v2.31", {"shared_results/paimon.json": "state", "hermes_task.json": "state"})
        version, files = manager.inspect_manifest(raw)
        self.assertEqual(version, "v2.31")
        self.assertEqual(list(files), ["app.py"])

    def test_restore_requires_unique_known_version(self) -> None:
        with self.assertRaisesRegex(ValueError, "found 0"):
            manager.restore(self.tool, "v2.30", execute=False)

    def test_restore_prepares_snapshot_and_verified_index_before_launch(self) -> None:
        root = manager.archive_root(self.tool)
        release = release_bytes("v2.30", {"old.py": "old"})
        hash_id = manager.git_blob_sha(release)
        manager.write_new_immutable(root / "manifests" / ("2026-11-02-v2.30--" + hash_id + ".json"), release)
        (self.tool / "new.py").write_text("keep until safe restore", encoding="utf-8")

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, limit: int) -> bytes:
                return b"# RestoreArchivedVersion supported by mocked updater"

        def pretend_success(arguments, check):
            self.assertIn("-RestoreArchivedVersion", arguments)
            root.joinpath("pinned-version.txt").write_text("v2.30", encoding="ascii")
            return types.SimpleNamespace(returncode=0)

        with mock.patch.object(manager.urllib.request, "urlopen", return_value=Response()), \
             mock.patch.object(manager.subprocess, "run", side_effect=pretend_success):
            manager.restore(self.tool, "v2.30", execute=True)

        snapshots = list((root / "snapshots").iterdir())
        self.assertEqual(len(snapshots), 1)
        self.assertTrue((snapshots[0] / "files" / "app.py").is_file())
        requests = list((root / "requests").glob("*/restore-index.json"))
        self.assertEqual(len(requests), 1)
        request = json.loads(requests[0].read_text(encoding="utf-8"))
        self.assertEqual(request["version"], "v2.30")
        self.assertEqual(request["manifest_sha256"], manager.sha256(release))
        self.assertEqual((self.tool / "app.py").read_text(encoding="utf-8"), "APP_VERSION = 'v2.31'\n")

    def test_immutable_archive_refuses_overwrite(self) -> None:
        path = manager.archive_root(self.tool) / "test.txt"
        manager.write_new_immutable(path, b"original")
        with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
            manager.write_new_immutable(path, b"changed")
        self.assertEqual(path.read_bytes(), b"original")

    def test_windows_entry_points_keep_their_encoding_contracts(self) -> None:
        folder = SOURCE.parent
        batch = (folder / "Voice-Version-Archive.cmd").read_bytes()
        updater = (folder / "migrate_updater_bootstrap_v1.ps1").read_bytes()
        self.assertTrue(batch.isascii(), "Windows batch must be ASCII only")
        self.assertTrue(updater.startswith(b"\xef\xbb\xbf"), "Windows PowerShell 5.1 requires a UTF-8 BOM")
        decoded = updater.decode("utf-8-sig")
        for phrase in ("RestoreArchivedVersion", "PRE_UPDATE_SNAPSHOT_VERIFIED",
                       "SKIP_AUTO_UPDATE_PINNED", "UPDATE_BLOCKED_ARCHIVE_FAILED",
                       "ROLLBACK_BACKUP_PRESERVED"):
            self.assertIn(phrase, decoded)


if __name__ == "__main__":
    unittest.main()
