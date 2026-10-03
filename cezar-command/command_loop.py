from __future__ import annotations

import argparse
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_CEZAR_URL = "http://127.0.0.1:4321"
DEFAULT_BRIDGE_URL = "http://127.0.0.1:8080"
TERMINAL = {"done", "failed", "cancelled"}


class CommandLoopError(RuntimeError):
    pass


def http_json(
    method: str,
    url: str,
    payload: dict[str, Any] | None = None,
    timeout: float = 30.0,
    token: str = "",
) -> Any:
    data = None
    headers = {"accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["content-type"] = "application/json"
    if token:
        headers["authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise CommandLoopError(f"HTTP {exc.code} {url}: {body[:1500]}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise CommandLoopError(f"Cannot reach {url}: {exc}") from exc


def discover_project(cezar_url: str, repo_path: Path) -> str:
    data = http_json("GET", f"{cezar_url}/api/v1/projects")
    projects = data.get("projects") if isinstance(data, dict) else None
    if not isinstance(projects, list):
        raise CommandLoopError("Cezar did not return a project list.")

    wanted = str(repo_path.resolve()).replace("\\", "/").rstrip("/").lower()
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
    if len(projects) == 1 and boot:
        only = projects[0]
        if isinstance(only, dict):
            root = only.get("root")
            if isinstance(root, str):
                normalized = root.replace("\\", "/").rstrip("/").lower()
                if normalized == wanted:
                    return boot

    raise CommandLoopError(
        "Target repository is not registered in Cezar. "
        "Register or start Cezar with that repository before this loop."
    )


def ensure_project(cezar_url: str, repo_path: Path) -> str:
    try:
        return discover_project(cezar_url, repo_path)
    except CommandLoopError:
        created = http_json(
            "POST",
            f"{cezar_url}/api/v1/projects",
            {"root": str(repo_path.resolve())},
            timeout=60.0,
        )
        project = created.get("project") if isinstance(created, dict) else None
        project_id = str(project.get("id") or "").strip() if isinstance(project, dict) else ""
        if not project_id:
            raise CommandLoopError(
                f"Cezar could not register target repository: {created}"
            )
        return project_id


def workflow(task: str) -> dict[str, Any]:
    audit_file = ".cezar-command-audit.json"
    implement_prompt = (
        "You are the implementation worker. Execute the original task in this worktree. "
        "Do not redefine or shrink the goal. Keep unrelated files unchanged. "
        f"If {audit_file} exists, read its issues and repair those issues without weakening the original task. "
        "When your implementation turn is complete, end with CEZ:DONE.\n\n"
        "ORIGINAL TASK:\n{{task}}"
    )
    audit_prompt = (
        "You are an independent audit worker in a NEW agent session. "
        "Do not implement, repair, or improve anything. "
        "Inspect the current worktree changes and compare them with the original task. "
        "Do not trust the previous agent's completion claim. "
        f"Write {audit_file} as UTF-8 JSON with exactly these keys: "
        'status ("PASS" or "FAIL"), issues (array of concrete strings), '
        "evidence (array of concrete strings). "
        "PASS is allowed only when every required item in the original task is satisfied. "
        "If evidence is insufficient, use FAIL. End with CEZ:DONE.\n\n"
        "ORIGINAL TASK:\n{{task}}"
    )
    check_command = (
        "python3 -c \"import json,pathlib,sys;"
        "p=pathlib.Path('.cezar-command-audit.json');"
        "d=json.loads(p.read_text(encoding='utf-8')) if p.is_file() else {};"
        "ok=d.get('status')=='PASS' and isinstance(d.get('issues'),list) and len(d.get('issues'))==0;"
        "print(json.dumps(d,ensure_ascii=False));"
        "p.unlink(missing_ok=True) if ok else None;"
        "sys.exit(0 if ok else 1)\""
    )
    return {
        "task": task,
        "steps": [
            {
                "id": "implement",
                "name": "Implement",
                "prompt": implement_prompt,
                "runner": "codex",
            },
            {
                "id": "audit",
                "name": "Independent audit",
                "prompt": audit_prompt,
                "runner": "codex",
            },
            {
                "id": "audit-gate",
                "name": "Audit gate",
                "command": check_command,
                "onFail": {"retry": "implement", "max": 2},
            },
        ],
        "runner": "codex",
        "worktree": True,
        "autonomous": True,
        "generateFollowups": False,
    }


def start_run(cezar_url: str, project_id: str, task: str) -> dict[str, Any]:
    quoted = urllib.parse.quote(project_id, safe="")
    result = http_json(
        "POST",
        f"{cezar_url}/api/v1/p/{quoted}/runs",
        workflow(task),
        timeout=60.0,
    )
    if not isinstance(result, dict):
        raise CommandLoopError("Cezar returned an invalid run response.")
    return result


def run_id_from(result: dict[str, Any]) -> str:
    candidates: list[dict[str, Any]] = [result]
    nested = result.get("run")
    if isinstance(nested, dict):
        candidates.append(nested)
    for candidate in candidates:
        value = candidate.get("id")
        if isinstance(value, str) and value.strip():
            return value.strip()
    raise CommandLoopError(f"Cezar response had no run id: {result}")


def read_run(cezar_url: str, project_id: str, run_id: str) -> dict[str, Any]:
    project = urllib.parse.quote(project_id, safe="")
    run = urllib.parse.quote(run_id, safe="")
    data = http_json("GET", f"{cezar_url}/api/v1/p/{project}/runs/{run}")
    if not isinstance(data, dict):
        raise CommandLoopError("Cezar returned an invalid run record.")
    return data


def wait_run(
    cezar_url: str,
    project_id: str,
    run_id: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    last_status = ""
    while time.monotonic() < deadline:
        run = read_run(cezar_url, project_id, run_id)
        status = str(run.get("status") or "").lower()
        if status != last_status:
            print(f"status={status or 'unknown'}", flush=True)
            last_status = status
        if status in TERMINAL:
            return run
        time.sleep(3.0)
    raise CommandLoopError(
        f"Cezar command loop timed out after {timeout_seconds} seconds."
    )


def commit_and_push(
    cezar_url: str,
    project_id: str,
    run_id: str,
) -> dict[str, Any]:
    project = urllib.parse.quote(project_id, safe="")
    run = urllib.parse.quote(run_id, safe="")
    commit = http_json(
        "POST",
        f"{cezar_url}/api/v1/p/{project}/runs/{run}/git/commit",
        {"message": f"Cezar audited task {run_id}"},
        timeout=60.0,
    )
    push = http_json(
        "POST",
        f"{cezar_url}/api/v1/p/{project}/runs/{run}/git/push",
        {},
        timeout=120.0,
    )
    return {"commit": commit, "push": push}


def final_summary(
    run: dict[str, Any],
    run_id: str,
    project_id: str,
) -> dict[str, Any]:
    steps: list[dict[str, Any]] = []
    raw_steps = run.get("steps")
    if isinstance(raw_steps, list):
        for item in raw_steps:
            if not isinstance(item, dict):
                continue
            steps.append(
                {
                    "id": item.get("id"),
                    "status": item.get("status"),
                    "iterations": item.get("iterations"),
                    "error": item.get("error"),
                }
            )
    status = str(run.get("status") or "unknown").lower()
    return {
        "status": "PASS" if status == "done" else "FAIL",
        "cezar_status": status,
        "run_id": run_id,
        "project_id": project_id,
        "branch": run.get("branch"),
        "base_branch": run.get("baseBranch"),
        "pull_request_url": (
            run.get("pullRequestUrl")
            or run.get("referencedPullRequestUrl")
        ),
        "steps": steps,
        "error": run.get("error"),
    }


def load_env_file(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    result: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip().strip('"').strip("'")
    return result


def bridge_token() -> str:
    return load_env_file(Path.home() / ".bridge-data" / ".env").get("API_TOKEN", "")


def conversation_id(client: dict[str, Any]) -> str:
    for key in ("sessionId", "conversationId"):
        value = client.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    session = client.get("session")
    if isinstance(session, dict):
        for key in ("id", "sessionId", "conversationId"):
            value = session.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    url = str(client.get("url") or "")
    match = re.search(r"/c/([0-9a-fA-F-]{20,})", url)
    return match.group(1) if match else ""


def bridge_target(bridge_url: str) -> tuple[str, str]:
    status = http_json("GET", f"{bridge_url}/setup/status")
    if not isinstance(status, dict):
        raise CommandLoopError("ChatGPT Bridge status response is invalid.")
    if status.get("needsSelection"):
        raise CommandLoopError(
            "Multiple ChatGPT tabs are connected; commander tab is not selected."
        )
    active = status.get("activeClient")
    if not isinstance(active, dict):
        raise CommandLoopError("No ChatGPT commander tab is connected.")

    client_id = str(active.get("id") or "").strip()
    session_id = conversation_id(active)

    if not session_id:
        token = bridge_token()
        sessions = http_json(
            "GET",
            f"{bridge_url}/sessions",
            timeout=15.0,
            token=token,
        )
        items = sessions.get("sessions") if isinstance(sessions, dict) else None
        if (
            isinstance(items, list)
            and len(items) == 1
            and isinstance(items[0], dict)
        ):
            session_id = str(
                items[0].get("id")
                or items[0].get("sessionId")
                or ""
            ).strip()

    if not client_id:
        raise CommandLoopError("Bridge active tab has no client id.")
    if not session_id:
        raise CommandLoopError(
            "Could not identify the ChatGPT commander conversation."
        )
    return client_id, session_id


def verify_commander_bridge(bridge_url: str) -> tuple[str, str]:
    return bridge_target(bridge_url)


def send_to_commander(
    bridge_url: str,
    summary: dict[str, Any],
) -> None:
    client_id, session_id = bridge_target(bridge_url)

    message = (
        "[CEZAR-COMMAND-RESULT]\n"
        + json.dumps(summary, ensure_ascii=False, indent=2)
        + "\nImplementation -> independent audit -> bounded retry loop finished. "
        "Treat this as an automatic handoff, not a user message to relay. "
        "If status is PASS, inspect the named GitHub target and pushed task branch with the "
        "connected GitHub tools, verify repository checks, and merge or apply it when the "
        "original task is actually satisfied. If status is FAIL/BLOCKED, diagnose and continue "
        "through AI-accessible paths. Do not ask the user to copy Codex output or choose an "
        "implementation route."
    )
    result = http_json(
        "POST",
        f"{bridge_url}/browser/passive-prompt",
        {
            "requestId": f"cezar-command-{summary.get('run_id', 'unknown')}",
            "message": message,
            "sessionId": session_id,
            "sourceClientId": client_id,
            "timeoutMs": 60000,
        },
        timeout=70.0,
        token=bridge_token(),
    )
    if not isinstance(result, dict) or result.get("submissionStatus") != "SUBMITTED":
        raise CommandLoopError(
            f"ChatGPT Bridge did not accept the result: {result}"
        )

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--task-file", required=True)
    parser.add_argument("--cezar-url", default=DEFAULT_CEZAR_URL)
    parser.add_argument("--bridge-url", default=DEFAULT_BRIDGE_URL)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--result-file", default="cezar-command-result.json")
    parser.add_argument("--no-push", action="store_true")
    parser.add_argument("--no-chatgpt-return", action="store_true")
    args = parser.parse_args()

    repo = Path(args.repo).expanduser().resolve()
    task_file = Path(args.task_file).expanduser().resolve()
    if not repo.is_dir():
        raise CommandLoopError(f"Repository folder was not found: {repo}")
    if not task_file.is_file():
        raise CommandLoopError(f"Task file was not found: {task_file}")

    task = task_file.read_text(encoding="utf-8").strip()
    if not task:
        raise CommandLoopError("Task file is empty.")

    cezar_url = args.cezar_url.rstrip("/")
    project_id = ensure_project(cezar_url, repo)
    created = start_run(cezar_url, project_id, task)
    run_id = run_id_from(created)
    print(f"run_id={run_id}", flush=True)

    run = wait_run(cezar_url, project_id, run_id, args.timeout)
    summary = final_summary(run, run_id, project_id)

    if summary["status"] == "PASS" and not args.no_push:
        summary["git"] = commit_and_push(cezar_url, project_id, run_id)

    result_path = Path(args.result_file).expanduser().resolve()
    result_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False), flush=True)

    if not args.no_chatgpt_return:
        try:
            send_to_commander(args.bridge_url.rstrip("/"), summary)
            print("chatgpt_return=SUBMITTED", flush=True)
        except CommandLoopError as exc:
            print(f"chatgpt_return=BLOCKED: {exc}", flush=True)
            return 3

    return 0 if summary["status"] == "PASS" else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CommandLoopError as exc:
        print(f"BLOCKED: {exc}", flush=True)
        raise SystemExit(1)
