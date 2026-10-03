from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


class SmokeError(RuntimeError):
    pass


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
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
    if completed.returncode:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise SmokeError(
            f"command failed ({completed.returncode}): {' '.join(args)}\n{detail}"
        )
    return completed


def http_json(
    method: str,
    url: str,
    payload: dict[str, Any] | None = None,
    timeout: float = 5.0,
) -> Any:
    data = None
    headers = {"accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["content-type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise SmokeError(f"HTTP {exc.code} {url}: {body[:1000]}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise SmokeError(f"cannot reach {url}: {exc}") from exc


def wait_json(url: str, timeout_seconds: float) -> Any:
    deadline = time.monotonic() + timeout_seconds
    last: Exception | None = None
    while time.monotonic() < deadline:
        try:
            return http_json("GET", url, timeout=2.0)
        except Exception as exc:
            last = exc
            time.sleep(0.5)
    raise SmokeError(f"service did not become ready: {url}; last={last}")


def project_id(base_url: str, repo: Path) -> str:
    data = http_json("GET", f"{base_url}/api/v1/projects")
    projects = data.get("projects") if isinstance(data, dict) else None
    if not isinstance(projects, list):
        raise SmokeError(f"invalid project list: {data}")

    wanted = str(repo.resolve()).replace("\\", "/").rstrip("/").lower()
    for item in projects:
        if not isinstance(item, dict):
            continue
        root = item.get("root")
        pid = str(item.get("id") or "").strip()
        if not isinstance(root, str) or not pid:
            continue
        normalized = root.replace("\\", "/").rstrip("/").lower()
        if normalized == wanted:
            return pid

    boot = str(data.get("bootProject") or "").strip() if isinstance(data, dict) else ""
    if boot:
        return boot
    raise SmokeError(f"test repository was not registered by Cezar: {data}")


def run_id(created: Any) -> str:
    if isinstance(created, dict):
        value = created.get("id")
        if isinstance(value, str) and value:
            return value
        nested = created.get("run")
        if isinstance(nested, dict):
            value = nested.get("id")
            if isinstance(value, str) and value:
                return value
    raise SmokeError(f"run creation returned no id: {created}")


def wait_run(
    base_url: str,
    pid: str,
    rid: str,
    timeout_seconds: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    quoted_pid = urllib.parse.quote(pid, safe="")
    quoted_rid = urllib.parse.quote(rid, safe="")
    url = f"{base_url}/api/v1/p/{quoted_pid}/runs/{quoted_rid}"
    last: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        data = http_json("GET", url)
        if not isinstance(data, dict):
            raise SmokeError(f"invalid run record: {data}")
        last = data
        status = str(data.get("status") or "").lower()
        if status == "done":
            return data
        if status in {"failed", "cancelled"}:
            raise SmokeError(f"smoke run ended as {status}: {data}")
        time.sleep(0.5)
    raise SmokeError(f"smoke run timed out: {last}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cezar-bin", required=True)
    parser.add_argument("--port", type=int, default=4399)
    args = parser.parse_args()

    binary = Path(args.cezar_bin).expanduser().resolve()
    if not binary.is_file():
        raise SmokeError(f"Cezar binary was not found: {binary}")

    with tempfile.TemporaryDirectory(prefix="cezar-command-smoke-") as raw:
        root = Path(raw)
        repo = root / "repo"
        home = root / "cez-home"
        repo.mkdir()
        home.mkdir()

        run(["git", "init", "-q", "-b", "main"], cwd=repo)
        run(["git", "config", "user.email", "cezar-smoke@example.invalid"], cwd=repo)
        run(["git", "config", "user.name", "Cezar Smoke"], cwd=repo)
        (repo / "README.md").write_text("cezar smoke\n", encoding="utf-8")
        run(["git", "add", "README.md"], cwd=repo)
        run(["git", "commit", "-q", "-m", "smoke base"], cwd=repo)

        env = os.environ.copy()
        env.update(
            {
                "CEZ_HOME": str(home),
                "CEZ_DRY_RUN": "1",
                "CEZ_NO_BANNER": "1",
                "CEZ_AUTOMATIONS": "0",
            }
        )
        log = root / "cezar.log"
        handle = log.open("wb")
        process = subprocess.Popen(
            [
                str(binary),
                "serve",
                "--repo",
                str(repo),
                "--port",
                str(args.port),
                "--no-open",
            ],
            cwd=str(repo),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=handle,
            stderr=subprocess.STDOUT,
        )
        handle.close()

        base_url = f"http://127.0.0.1:{args.port}"
        try:
            health = wait_json(f"{base_url}/api/v1/health", 30.0)
            if not isinstance(health, dict):
                raise SmokeError(f"invalid health payload: {health}")

            pid = project_id(base_url, repo)
            quoted_pid = urllib.parse.quote(pid, safe="")
            created = http_json(
                "POST",
                f"{base_url}/api/v1/p/{quoted_pid}/runs",
                {
                    "task": "Cezar command center smoke test",
                    "steps": [
                        {
                            "id": "probe",
                            "name": "Probe",
                            "command": "python3 -c \"print('CEZAR_COMMAND_SMOKE_OK')\"",
                        }
                    ],
                    "worktree": True,
                    "autonomous": True,
                    "generateFollowups": False,
                },
                timeout=10.0,
            )
            rid = run_id(created)
            finished = wait_run(base_url, pid, rid, 30.0)

            retry_created = http_json(
                "POST",
                f"{base_url}/api/v1/p/{quoted_pid}/runs",
                {
                    "task": "Cezar retry smoke test",
                    "steps": [
                        {
                            "id": "prepare",
                            "name": "Prepare attempt",
                            "command": (
                                "python3 -c \"from pathlib import Path;"
                                "p=Path('retry-count.txt');"
                                "n=int(p.read_text())+1 if p.exists() else 1;"
                                "p.write_text(str(n))\""
                            ),
                        },
                        {
                            "id": "gate",
                            "name": "Fail once then pass",
                            "command": (
                                "python3 -c \"from pathlib import Path;import sys;"
                                "n=int(Path('retry-count.txt').read_text());"
                                "sys.exit(0 if n>=2 else 1)\""
                            ),
                            "onFail": {"retry": "prepare", "max": 2},
                        },
                    ],
                    "worktree": True,
                    "autonomous": True,
                    "generateFollowups": False,
                },
                timeout=10.0,
            )
            retry_rid = run_id(retry_created)
            retry_finished = wait_run(base_url, pid, retry_rid, 30.0)

            print(
                json.dumps(
                    {
                        "status": "PASS",
                        "project_id": pid,
                        "run_id": rid,
                        "cezar_status": finished.get("status"),
                        "retry_run_id": retry_rid,
                        "retry_status": retry_finished.get("status"),
                    }
                )
            )
            return 0
        finally:
            process.terminate()
            try:
                process.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5.0)
            if process.returncode not in (0, -15):
                detail = log.read_text(encoding="utf-8", errors="replace")
                if detail:
                    print(detail[-4000:], flush=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SmokeError as exc:
        print(f"SMOKE=BLOCKED: {exc}")
        raise SystemExit(1)
