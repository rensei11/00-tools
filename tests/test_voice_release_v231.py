from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]


def repository_blob(path: str) -> bytes:
    # Windows checkout may convert LF to CRLF. Validate Git blob bytes:
    # these are the bytes served by the immutable release URL.
    return subprocess.check_output(["git", "show", "HEAD:" + path], cwd=root)


index = json.loads(repository_blob("ai-voice/update-index.json"))
assert index["schema"] == 1
match = re.fullmatch(
    r"https://raw\.githubusercontent\.com/rensei11/00-tools/"
    r"([0-9a-f]{40})/ai-voice/releases/([A-Za-z0-9._-]+\.json)",
    index["manifest_url"],
)
assert match is not None, "Manifest URL must be pinned to an immutable commit"
manifest_bytes = repository_blob("ai-voice/releases/" + match.group(2))
legacy_bytes = repository_blob("fandom-voice-tool-latest.json")
assert hashlib.sha256(manifest_bytes).hexdigest() == index["manifest_sha256"]
assert manifest_bytes == legacy_bytes
payload = json.loads(manifest_bytes)
assert payload["version"] == index["version"]
files = payload["files"]
assert "app.py" in files and "start_local.ps1" in files
assert 'APP_VERSION = "' + index["version"] + '"' in files["app.py"]
assert 'DISPLAY_VERSION = "' + index["version"] + '"' in files["app.py"]
launcher = files["start_local.ps1"]
assert "System.Web.Script.Serialization.JavaScriptSerializer" in launcher
assert "$response.Content | ConvertFrom-Json" not in launcher
for excluded in (
    "speakers.json", "games.json", "pronunciation_dictionary.json",
    "generation_history.jsonl", "updater_bootstrap.ps1",
    "start_fandom_tool.cmd", "update_and_start.ps1", "startup_update_check.ps1",
):
    assert excluded not in files, excluded
for filename, body in files.items():
    if filename.lower().endswith((".cmd", ".bat")):
        body.encode("ascii")
    if filename.lower().endswith(".ps1"):
        assert not body.startswith("\ufeff")
print("AI_VOICE_PUBLISHED_MANIFEST=PASS version=" + index["version"])
