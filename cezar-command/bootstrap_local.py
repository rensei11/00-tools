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

import command_loop

CEZAR_PACKAGE = "@open-mercato/cezar"
CEZAR_VERSION = "0.13.0"
CEZAR_URL = "http://127.0.0.1:4322"
BRIDGE_URL = "http://127.0.0.1:8080"


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


def version_tuple(text: str) -> tuple[int, int, int]:
    import re

    match = re.search(r"(\d+)\.(\d+)\.(\d+)", text)
    if not match:
        return (0, 0, 0)
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def check_node() -> None:
    node = command("node")
    command("npm")
    version = run([node, "--version"]).stdout.strip()
    if version_tuple(version) < (20, 0, 0):
        raise BootstrapError(f"Node.js 20+ is required; found {version}")


def ensure_codex_wrapper(runtime_root: Path) -> Path:
    runtime_root.mkdir(parents=True, exist_ok=True)
    wrapper = runtime_root / "codex-login-wrapper.sh"
    content = """#!/usr/bin/env bash
set -euo pipefail
if [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc" >/dev/null 2>&1 || true
fi
CODEX_BIN="$(command -v codex || true)"
if [ -z "$CODEX_BIN" ]; then
    echo "Codex command was not found after loading the Ubuntu login environment." >&2
    exit 127
fi
exec "$CODEX_BIN" "$@"
"""
    wrapper.write_text(content, encoding="ascii")
    wrapper.chmod(0o755)

    completed = run([str(wrapper), "--version"])
    version = completed.stdout.strip() or completed.stderr.strip()
    if not version:
        raise BootstrapError("Codex CLI returned no version through the login wrapper.")
    return wrapper


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


def ensure_git_push_auth(control_repo: Path) -> None:
    remote = run(
        ["git", "remote", "get-url", "origin"],
        cwd=control_repo,
    ).stdout.strip()
    if remote != "https://github.com/rensei11/00-tools.git":
        raise BootstrapError(f"Unexpected control repository origin: {remote}")

    completed = run(
        [
            "git",
            "push",
            "--dry-run",
            "origin",
            "HEAD:refs/heads/cezar-auth-probe",
        ],
        cwd=control_repo,
    )
    output = (completed.stdout + "\n" + completed.stderr).strip()
    if "fatal:" in output.lower() or "error:" in output.lower():
        raise BootstrapError(
            "GitHub push authentication dry-run failed: " + output[:1200]
        )


def ensure_runtime_smoke(
    control_repo: Path,
    runtime_root: Path,
    binary: Path,
) -> None:
    marker = runtime_root / "smoke-pass.json"
    smoke_script = control_repo / "cezar-command" / "cezar_smoke_test.py"
    if not smoke_script.is_file():
        raise BootstrapError(f"Cezar smoke test was not found: {smoke_script}")

    revision = run(
        ["git", "rev-parse", "HEAD"],
        cwd=control_repo,
    ).stdout.strip()
    expected = {
        "controlRevision": revision,
        "cezarVersion": CEZAR_VERSION,
    }

    if marker.is_file():
        try:
            current = json.loads(marker.read_text(encoding="utf-8"))
        except Exception:
            current = {}
        if current == expected:
            return

    completed = run(
        [
            sys.executable,
            str(smoke_script),
            "--cezar-bin",
            str(binary),
            "--port",
            "4399",
        ],
        cwd=control_repo,
    )
    if '"status": "PASS"' not in completed.stdout:
        raise BootstrapError(
            "Cezar self-test did not report PASS: "
            + (completed.stdout or completed.stderr).strip()[:1200]
        )

    runtime_root.mkdir(parents=True, exist_ok=True)
    marker.write_text(
        json.dumps(expected, ensure_ascii=True, indent=2) + "\n",
        encoding="ascii",
    )


def verify_return_channel() -> None:
    try:
        command_loop.verify_commander_bridge(BRIDGE_URL)
    except Exception as exc:
        raise BootstrapError(
            f"ChatGPT return channel is not ready: {exc}"
        ) from exc


def ensure_cezar(
    control_repo: Path,
    runtime_root: Path,
    codex_bin: Path,
) -> dict[str, Any]:
    pid_path = runtime_root / "cezar.pid"
    health = try_http_json(f"{CEZAR_URL}/api/v1/health")

    if health is not None:
        if not process_alive(pid_path):
            raise BootstrapError(
                "Port 4322 already has a Cezar service not owned by this command center."
            )
        return health if isinstance(health, dict) else {}

    binary = ensure_cezar_package(runtime_root)
    env = os.environ.copy()
    env.update(
        {
            "CEZ_AUTOMATIONS": "1",
            "CEZ_CODEX_BIN": str(codex_bin),
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


def prepare_agent_probe_repo(runtime_root: Path) -> Path:
    repo = runtime_root / "agent-proof-repo"
    if not (repo / ".git").exists():
        repo.mkdir(parents=True, exist_ok=True)
        run(["git", "init", "-q", "-b", "main"], cwd=repo)
        run(
            ["git", "config", "user.email", "cezar-proof@example.invalid"],
            cwd=repo,
        )
        run(["git", "config", "user.name", "Cezar Proof"], cwd=repo)
        (repo / "README.md").write_text(
            "isolated cezar proof repository\n",
            encoding="utf-8",
        )
        run(["git", "add", "README.md"], cwd=repo)
        run(["git", "commit", "-q", "-m", "proof base"], cwd=repo)
    else:
        run(["git", "switch", "main"], cwd=repo)
        run(["git", "reset", "--hard", "HEAD"], cwd=repo)
        run(["git", "clean", "-fd"], cwd=repo)
    return repo


def ensure_real_codex_probe(
    control_repo: Path,
    runtime_root: Path,
    codex_bin: Path,
) -> None:
    marker = runtime_root / "real-codex-proof-pass.json"
    revision = run(
        ["git", "rev-parse", "HEAD"],
        cwd=control_repo,
    ).stdout.strip()
    codex_version = run([str(codex_bin), "--version"]).stdout.strip()
    expected = {
        "controlRevision": revision,
        "cezarVersion": CEZAR_VERSION,
        "codexVersion": codex_version,
    }

    if marker.is_file():
        try:
            current = json.loads(marker.read_text(encoding="utf-8"))
        except Exception:
            current = {}
        if current == expected:
            return

    repo = prepare_agent_probe_repo(runtime_root)
    project_id = command_loop.ensure_project(CEZAR_URL, repo)
    task = (
        "This is an isolated command-center proof. "
        "Create exactly one file named CEZAR_PROOF.txt. "
        "Its complete content must be exactly CEZAR_REAL_CODEX_PROOF_OK followed by one newline. "
        "Do not modify any other file."
    )
    created = command_loop.start_run(CEZAR_URL, project_id, task)
    run_id = command_loop.run_id_from(created)
    record = command_loop.wait_run(
        CEZAR_URL,
        project_id,
        run_id,
        240,
    )
    summary = command_loop.final_summary(record, run_id, project_id)
    if summary.get("status") != "PASS":
        raise BootstrapError(
            "Real Codex implementation/audit proof did not pass: "
            + json.dumps(summary, ensure_ascii=True)[:1600]
        )

    quoted_project = urllib.parse.quote(project_id, safe="")
    quoted_run = urllib.parse.quote(run_id, safe="")
    changes = http_json(
        "GET",
        f"{CEZAR_URL}/api/v1/p/{quoted_project}/runs/{quoted_run}/changes",
        timeout=15.0,
    )
    files = changes.get("files") if isinstance(changes, dict) else None
    if not isinstance(files, list):
        raise BootstrapError(f"Real Codex proof returned invalid changes: {changes}")

    relevant = [
        item
        for item in files
        if isinstance(item, dict)
    ]
    paths = [str(item.get("path") or "") for item in relevant]
    if paths != ["CEZAR_PROOF.txt"]:
        raise BootstrapError(
            f"Real Codex proof changed unexpected files: {paths}"
        )
    patch = str(relevant[0].get("patch") or "")
    if "CEZAR_REAL_CODEX_PROOF_OK" not in patch:
        raise BootstrapError(
            "Real Codex proof file did not contain the required marker."
        )

    try:
        http_json(
            "POST",
            f"{CEZAR_URL}/api/v1/p/{quoted_project}/runs/{quoted_run}/remove-worktree",
            {},
            timeout=30.0,
        )
    except Exception:
        pass

    runtime_root.mkdir(parents=True, exist_ok=True)
    marker.write_text(
        json.dumps(expected, ensure_ascii=True, indent=2) + "\n",
        encoding="ascii",
    )


def ensure_watcher(control_repo: Path, runtime_root: Path) -> int:
    pid_path = runtime_root / "watcher.pid"
    if process_alive(pid_path):
        return int(pid_path.read_text(encoding="ascii").strip())

    watcher = control_repo / "cezar-command" / "watch_task.py"
    if not watcher.is_file():
        raise BootstrapError(f"Task watcher was not found: {watcher}")

    env = os.environ.copy()
    runtime_root.mkdir(parents=True, exist_ok=True)
    return start_detached(
        [
            sys.executable,
            str(watcher),
            "--control-repo",
            str(control_repo),
            "--cezar-url",
            CEZAR_URL,
            "--bridge-url",
            BRIDGE_URL,
            "--interval",
            "20",
        ],
        cwd=control_repo,
        env=env,
        log_path=runtime_root / "watcher.log",
        pid_path=pid_path,
    )


def write_runtime(
    runtime_root: Path,
    control_repo: Path,
    watcher_pid: int,
    health: dict[str, Any],
) -> None:
    payload = {
        "controlRepo": str(control_repo),
        "cezarUrl": CEZAR_URL,
        "bridgeUrl": BRIDGE_URL,
        "watcherPid": watcher_pid,
        "cezarVersion": str(health.get("version") or CEZAR_VERSION),
        "mode": "local-task-watch",
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
    check_node()
    codex_bin = ensure_codex_wrapper(runtime_root)

    binary = ensure_cezar_package(runtime_root)
    ensure_git_push_auth(control_repo)
    ensure_runtime_smoke(control_repo, runtime_root, binary)
    verify_return_channel()

    health = ensure_cezar(control_repo, runtime_root, codex_bin)
    ensure_real_codex_probe(control_repo, runtime_root, codex_bin)
    watcher_pid = ensure_watcher(control_repo, runtime_root)
    write_runtime(
        runtime_root,
        control_repo,
        watcher_pid,
        health,
    )

    summary = {
        "status": "READY",
        "component": "cezar-command-center",
        "cezar_url": CEZAR_URL,
        "watcher_pid": watcher_pid,
    }
    try:
        command_loop.send_to_commander(BRIDGE_URL, summary)
        print("CHATGPT_RETURN=SUBMITTED")
    except Exception as exc:
        print(f"CHATGPT_RETURN=BLOCKED: {exc}")

    print("CEZAR_COMMAND_CENTER=READY")
    print(f"CEZAR_URL={CEZAR_URL}")
    print(f"WATCHER_PID={watcher_pid}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BootstrapError as exc:
        try:
            command_loop.send_to_commander(
                BRIDGE_URL,
                {
                    "status": "BLOCKED",
                    "component": "cezar-command-center",
                    "reason": str(exc),
                },
            )
        except Exception:
            pass
        print(f"CEZAR_COMMAND_CENTER=BLOCKED\n{exc}", file=sys.stderr)
        raise SystemExit(1)
