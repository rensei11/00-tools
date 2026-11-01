from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
def repository_blob(path: str) -> bytes:
    # On Windows Git may turn the checked-out JSON newlines into CRLF.
    # The updater downloads commit-pinned Git blob bytes, not checkout bytes.
    return subprocess.check_output(["git", "show", "HEAD:" + path], cwd=root)


manifest_bytes = repository_blob("ai-voice/releases/2026-11-02-v2.31.json")
legacy_bytes = repository_blob("fandom-voice-tool-latest.json")
expected_sha = "6c5516dac16135be5caeb3fad7d1138201d4e999722d0af27458df4821da3b44"
assert hashlib.sha256(manifest_bytes).hexdigest() == expected_sha
assert manifest_bytes == legacy_bytes
payload = json.loads(manifest_bytes)
assert payload["version"] == "v2.31"
files = payload["files"]
assert len(files) == 163
assert 'APP_VERSION = "v2.31"' in files["app.py"]
assert 'DISPLAY_VERSION = "v2.31"' in files["app.py"]
launcher = files["start_local.ps1"]
assert "System.Web.Script.Serialization.JavaScriptSerializer" in launcher
assert "$response.Content | ConvertFrom-Json" not in launcher
for excluded in (
    "speakers.json", "games.json", "pronunciation_dictionary.jsonl",
    "pronunciation_dictionary.json", "generation_history.jsonl",
    "updater_bootstrap.ps1", "start_fandom_tool.cmd",
    "update_and_start.ps1", "startup_update_check.ps1"
):
    assert excluded not in files, excluded
for filename, content in files.items():
    if filename.lower().endswith((".cmd", ".bat")):
        content.encode("ascii")
    if filename.lower().endswith(".ps1"):
        assert not content.startswith("\ufeff")
print("AI_VOICE_V231_MANIFEST=PASS")
