from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

CEZAR_PACKAGE = "@open-mercato/cezar"
CEZAR_VERSION = "0.13.0"
CEZAR_URL = "http://127.0.0.1:4322"
BRIDGE_URL = "http://127.0.0.1:8080"
AUTOMATION_NAME = "Rensei Cezar Command Center v1"
TRIGGER_LABEL = "cezar-command"


class BootstrapError(RuntimeError):
    pass


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        args,
        cwd=str(cwd) if cwd else None,
        env=env,
        check=False,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
    )
    if check and completed.returncode:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise BootstrapError(
            f"command failed ({completed.returncode}): {' '.join(args)}\n{detail}"
        )
    return completed


def command(name: str) -> str:
    found = shutil.which(name)
    if not found:
        raise BootstrapError(f"required command was not found: {name}")
    return found


def http_json(
    method: str,
    url: str,
    payload: dict[str, Any] | None = None,
    timeout: float = 15.0,
) -> Any:
    data = None
    headers = {"accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["content-type"] = "application/json"
    request = urllib.request.Request(
        url,
        data=data,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise BootstrapError(f"HTTP {exc.code} {url}: {body[:1200]}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise BootstrapError(f"cannot reach {url}: {exc}") from exc


def try_http_json(url: str, timeout: float = 2.0) -> Any | None:
    try:
        return http_json("GET", url, timeout=timeout)
    except BootstrapError:
        return None


def process_alive(pid_path: Path) -> bool:
    if not pid_path.is_file():
        return False
    try:
        pid = int(pid_path.read_text(encoding="ascii").strip())
        os.kill(pid, 0)
        return True
    except (ValueError, OSError):
        return False


def start_detached(
    args: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    log_path: Path,
    pid_path: Path,
) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    handle = log_path.open("ab")
    process = subprocess.Popen(
        args,
        cwd=str(cwd),
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    handle.close()
    pid_path.write_text(str(process.pid) + "\n", encoding="ascii")
    return process.pid


def wait_health(timeout_seconds: float = 60.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    last: Exception | None = None
    while time.monotonic() < deadline:
        try:
            data = http_json("GET", f"{CEZAR_URL}/api/v1/health", timeout=3.0)
            if isinstance(data, dict):
                return data
        except Exception as exc:
            last = exc
        time.sleep(1.0)
    raise BootstrapError(f"Cezar did not become ready: {last}")


def package_binary(runtime_root: Path) -> Path:
    if os.name == "nt":
        return runtime_root / "cezar-package" / "node_modules" / ".bin" / "cezar.cmd"
    return runtime_root / "cezar-package" / "node_modules" / ".bin" / "cezar"


def ensure_cezar_package(runtime_root: Path) -> Path:
    package_root = runtime_root / "cezar-package"
    binary = package_binary(runtime_root)
    package_json = (
        package_root
        / "node_modules"
        / "@open-mercato"
        / "cezar"
        / "package.json"
    )

    if binary.is_file() and package_json.is_file():
        try:
            current = json.loads(package_json.read_text(encoding="utf-8"))
        except Exception:
            current = {}
        if str(current.get("version") or "") == CEZAR_VERSION:
            return binary

    npm = command("npm")
    package_root.mkdir(parents=True, exist_ok=True)
    run(
        [
            npm,
            "install",
            "--prefix",
            str(package_root),
            "--no-audit",
            "--no-fund",
            f"{CEZAR_PACKAGE}@{CEZAR_VERSION}",
        ]
    )
    if not binary.is_file():
        raise BootstrapError(f"Cezar executable was not installed: {binary}")
    return binary


def ensure_cezar(control_repo: Path, runtime_root: Path) -> dict[str, Any]:
    pid_path = runtime_root / "cezar.pid"
    health = try_http_json(f"{CEZAR_URL}/api/v1/health")

    if health is not None:
        if not process_alive(pid_path):
            raise BootstrapError(
                "Port 4322 already has a Cezar service not owned by this command center."
            )
        return health if isinstance(health, dict) else {}

    binary = ensure_cezar_package(runtime_root)
    codex_bin = command("codex")
    env = os.environ.copy()
    env.update(
        {
            "CEZ_AUTOMATIONS": "1",
            "CEZ_CODEX_BIN": codex_bin,
            "CEZ_CODEX_NETWORK": "0",
            "CEZ_NO_BANNER": "1",
        }
    )
    runtime_root.mkdir(parents=True, exist_ok=True)
    start_detached(
        [
            str(binary),
            "--repo",
            str(control_repo),
            "--port",
            "4322",
            "--no-open",
        ],
        cwd=control_repo,
        env=env,
        log_path=runtime_root / "cezar.log",
        pid_path=pid_path,
    )
    return wait_health()


def ensure_trigger_label(control_repo: Path) -> None:
    gh = command("gh")
    completed = run(
        [
            gh,
            "label",
            "create",
            TRIGGER_LABEL,
            "--color",
            "6F42C1",
            "--description",
            "Trigger the independent Cezar command center",
            "--force",
        ],
        cwd=control_repo,
        check=False,
    )
    if completed.returncode:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise BootstrapError(f"could not create trigger label: {detail}")


def control_project_id(control_repo: Path) -> str:
    data = http_json("GET", f"{CEZAR_URL}/api/v1/projects")
    projects = data.get("projects") if isinstance(data, dict) else None
    if not isinstance(projects, list):
        raise BootstrapError("Cezar did not return its project list.")

    wanted = str(control_repo.resolve()).replace("\\", "/").rstrip("/").lower()
    for item in projects:
        if not isinstance(item, dict):
            continue
        project_id = str(item.get("id") or "").strip()
        root = item.get("root")
        if not project_id or not isinstance(root, str):
            continue
        normalized = root.replace("\\", "/").rstrip("/").lower()
        if normalized == wanted:
            return project_id

    boot = str(data.get("bootProject") or "").strip() if isinstance(data, dict) else ""
    if boot:
        return boot
    raise BootstrapError("Could not identify the Cezar control project.")


def ensure_automation(control_repo: Path) -> str:
    project_id = control_project_id(control_repo)
    quoted = urllib.parse.quote(project_id, safe="")
    base = f"{CEZAR_URL}/api/v1/p/{quoted}/automations"

    listing = http_json("GET", base)
    items = listing.get("automations") if isinstance(listing, dict) else None
    if isinstance(items, list):
        for item in items:
            if not isinstance(item, dict):
                continue
            if item.get("name") != AUTOMATION_NAME:
                continue
            automation_id = str(item.get("id") or "").strip()
            if automation_id:
                if not item.get("enabled"):
                    http_json(
                        "POST",
                        f"{base}/{automation_id}/enable",
                        {},
                    )
                return automation_id

    dispatch_command = (
        "python3 cezar-command/dispatch.py "
        f"--control-repo {control_repo} "
        f"--cezar-url {CEZAR_URL} "
        f"--bridge-url {BRIDGE_URL}"
    )
    definition = {
        "name": AUTOMATION_NAME,
        "kind": "github",
        "events": ["issue.labeled"],
        "intervalSeconds": 60,
        "filters": {
            "changedLabels": [TRIGGER_LABEL],
            "lookbackDays": 7,
            "maxRecords": 20,
        },
        "task": {
            "steps": [
                {
                    "id": "dispatch",
                    "name": "Dispatch command",
                    "command": dispatch_command,
                }
            ],
            "worktree": False,
            "autonomous": True,
            "generateFollowups": False,
        },
        "enable": True,
    }
    created = http_json(
        "POST",
        base,
        definition,
        timeout=30.0,
    )
    automation = created.get("automation") if isinstance(created, dict) else None
    automation_id = (
        str(automation.get("id") or "").strip()
        if isinstance(automation, dict)
        else ""
    )
    if not automation_id:
        raise BootstrapError(
            f"Cezar automation creation returned an invalid response: {created}"
        )
    return automation_id

def write_runtime(
    runtime_root: Path,
    control_repo: Path,
    automation_id: str,
    health: dict[str, Any],
) -> None:
    payload = {
        "controlRepo": str(control_repo),
        "cezarUrl": CEZAR_URL,
        "bridgeUrl": BRIDGE_URL,
        "automationId": automation_id,
        "cezarVersion": str(health.get("version") or CEZAR_VERSION),
        "triggerLabel": TRIGGER_LABEL,
        "mode": "command-center",
    }
    path = runtime_root / "runtime.json"
    path.write_text(
        json.dumps(payload, ensure_ascii=True, indent=2) + "\n",
        encoding="ascii",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--control-repo", required=True)
    args = parser.parse_args()

    control_repo = Path(args.control_repo).expanduser().resolve()
    runtime_root = control_repo.parent / "runtime"

    if not (control_repo / ".git").exists():
        raise BootstrapError(f"control repository is not a Git repository: {control_repo}")

    command("git")
    command("python3")
    command("node")
    command("npm")
    command("codex")
    command("gh")

    health = ensure_cezar(control_repo, runtime_root)
    ensure_trigger_label(control_repo)
    automation_id = ensure_automation(control_repo)
    write_runtime(
        runtime_root,
        control_repo,
        automation_id,
        health,
    )

    print("CEZAR_COMMAND_CENTER=READY")
    print(f"CEZAR_URL={CEZAR_URL}")
    print(f"AUTOMATION_ID={automation_id}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BootstrapError as exc:
        print(f"CEZAR_COMMAND_CENTER=BLOCKED\n{exc}", file=sys.stderr)
        raise SystemExit(1)
