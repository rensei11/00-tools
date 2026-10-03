from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_CEZAR_URL = "http://127.0.0.1:4321"
TERMINAL = {"done", "failed", "cancelled"}


class CommandLoopError(RuntimeError):
    pass


def http_json(method: str, url: str, payload: dict[str, Any] | None = None, timeout: float = 30.0) -> Any:
    data = None
    headers = {"accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["content-type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise CommandLoopError(f"HTTP {exc.code}: {body[:1500]}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise CommandLoopError(f"Cannot reach Cezar: {exc}") from exc


def discover_project(cezar_url: str, repo_path: Path) -> str:
    data = http_json("GET", f"{cezar_url}/api/v1/projects")
    projects = data.get("projects") if isinstance(data, dict) else None
    if not isinstance(projects, list):
        raise CommandLoopError("Cezar did not return a project list.")

    wanted = str(repo_path.resolve()).replace("\\", "/").rstrip("/").lower()
    matches: list[str] = []
    for item in projects:
        if not isinstance(item, dict):
            continue
        project_id = str(item.get("id") or item.get("projectId") or "").strip()
        values = [
            item.get("path"),
            item.get("repo"),
            item.get("repoPath"),
            item.get("root"),
            item.get("rootPath"),
        ]
        for value in values:
            if not isinstance(value, str):
                continue
            normalized = value.replace("\\", "/").rstrip("/").lower()
            if normalized == wanted and project_id:
                return project_id
        if project_id:
            matches.append(project_id)

    boot = str(data.get("bootProject") or "").strip() if isinstance(data, dict) else ""
    if len(projects) == 1 and boot:
        return boot
    if len(matches) == 1:
        return matches[0]
    raise CommandLoopError(
        "Target repository is not registered in Cezar. Start Cezar with that repository first."
    )


def workflow(task: str) -> dict[str, Any]:
    audit_file = ".cezar-command-audit.json"
    implement_prompt = (
        "You are the implementation worker. Execute the original task in this worktree. "
        "Do not redefine the goal. If " + audit_file + " exists, read its issues and fix them, "
        "but do not weaken the original task. Keep unrelated files unchanged. "
        "When your implementation turn is complete, end with CEZ:DONE.\n\n"
        "ORIGINAL TASK:\n{{task}}"
    )
    audit_prompt = (
        "You are an independent audit worker in a NEW agent session. "
        "Do not implement or repair anything. Inspect the current worktree changes and the original task. "
        "Decide only whether the implementation fully satisfies the original task. "
        "Write " + audit_file + " as UTF-8 JSON with exactly these keys: "
        'status ("PASS" or "FAIL"), issues (array of concrete strings), evidence (array of concrete strings). '
        "PASS is allowed only when no required item is missing. "
        "Do not trust the previous agent's completion claim. End with CEZ:DONE.\n\n"
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
            {"id": "implement", "name": "Implement", "prompt": implement_prompt, "runner": "codex"},
            {"id": "audit", "name": "Independent audit", "prompt": audit_prompt, "runner": "codex"},
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
    for candidate in (result, result.get("run") if isinstance(result.get("run"), dict) else {}):
        value = candidate.get("id") if isinstance(candidate, dict) else None
        if isinstance(value, str) and value.strip():
            return value.strip()
    raise CommandLoopError(f"Cezar response had no run id: {result}")


def read_run(cezar_url: str, project_id: str, run_id: str) -> dict[str, Any]:
    p = urllib.parse.quote(project_id, safe="")
    r = urllib.parse.quote(run_id, safe="")
    data = http_json("GET", f"{cezar_url}/api/v1/p/{p}/runs/{r}")
    if not isinstance(data, dict):
        raise CommandLoopError("Cezar returned an invalid run record.")
    return data


def wait_run(cezar_url: str, project_id: str, run_id: str, timeout_seconds: int) -> dict[str, Any]:
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
    raise CommandLoopError(f"Cezar command loop timed out after {timeout_seconds} seconds.")


def final_summary(run: dict[str, Any], run_id: str, project_id: str) -> dict[str, Any]:
    steps = []
    for item in run.get("steps", []) if isinstance(run.get("steps"), list) else []:
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
        "steps": steps,
        "error": run.get("error"),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--task-file", required=True)
    parser.add_argument("--cezar-url", default=DEFAULT_CEZAR_URL)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--result-file", default="cezar-command-result.json")
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

    project_id = discover_project(args.cezar_url.rstrip("/"), repo)
    created = start_run(args.cezar_url.rstrip("/"), project_id, task)
    run_id = run_id_from(created)
    print(f"run_id={run_id}", flush=True)
    run = wait_run(args.cezar_url.rstrip("/"), project_id, run_id, args.timeout)
    summary = final_summary(run, run_id, project_id)

    result_path = Path(args.result_file).expanduser().resolve()
    result_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False), flush=True)
    return 0 if summary["status"] == "PASS" else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CommandLoopError as exc:
        print(f"BLOCKED: {exc}", flush=True)
        raise SystemExit(1)
