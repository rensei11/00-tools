from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

import command_loop


TASK_PATH = "cezar-command/task.json"


class DispatchError(RuntimeError):
    pass


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"
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
        raise DispatchError(
            f"command failed ({completed.returncode}): {' '.join(args)}\n{detail}"
        )
    return completed


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["git", *args], cwd=repo, check=check)


def read_task(control_repo: Path) -> dict[str, Any]:
    git(control_repo, "fetch", "origin", "main", "--quiet")
    raw = git(control_repo, "show", f"origin/main:{TASK_PATH}").stdout
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise DispatchError(f"{TASK_PATH} is invalid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise DispatchError(f"{TASK_PATH} must contain one JSON object.")
    return data


def required_text(task: dict[str, Any], key: str) -> str:
    value = task.get(key)
    if not isinstance(value, str) or not value.strip():
        raise DispatchError(f"task field '{key}' is required.")
    return value.strip()


def safe_slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-._")
    if not slug:
        raise DispatchError("Could not create a safe repository folder name.")
    return slug


def runtime_root() -> Path:
    return Path.home() / "cezar-command-center" / "runtime"


def load_processed() -> set[str]:
    path = runtime_root() / "processed.json"
    if not path.is_file():
        return set()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return set()
    if not isinstance(data, list):
        return set()
    return {str(item) for item in data}


def save_processed(processed: set[str]) -> None:
    root = runtime_root()
    root.mkdir(parents=True, exist_ok=True)
    path = root / "processed.json"
    tmp = root / "processed.tmp"
    tmp.write_text(
        json.dumps(sorted(processed), ensure_ascii=True, indent=2) + "\n",
        encoding="ascii",
    )
    tmp.replace(path)


def ensure_target_repo(task: dict[str, Any]) -> tuple[Path, str]:
    branch = str(task.get("target_branch") or "main").strip() or "main"
    configured = task.get("target_repo")
    repo: Path

    if isinstance(configured, str) and configured.strip():
        repo = Path(configured).expanduser().resolve()
        if not (repo / ".git").exists():
            raise DispatchError(f"target_repo is not a Git repository: {repo}")
    else:
        github_repo = required_text(task, "target_github")
        root = Path.home() / "cezar-command-center" / "projects"
        root.mkdir(parents=True, exist_ok=True)
        repo = root / safe_slug(github_repo.replace("/", "__"))
        expected = f"https://github.com/{github_repo}.git"
        if (repo / ".git").exists():
            origin = git(repo, "remote", "get-url", "origin").stdout.strip()
            if origin != expected:
                raise DispatchError(
                    f"Unexpected origin for target clone: {origin}"
                )
        else:
            run(
                [
                    "git",
                    "clone",
                    "--branch",
                    branch,
                    "--single-branch",
                    expected,
                    str(repo),
                ]
            )

    if git(repo, "status", "--porcelain").stdout.strip():
        raise DispatchError(
            f"Target repository has local changes; refusing to overwrite them: {repo}"
        )

    git(repo, "config", "user.name", "Cezar Command Center")
    git(repo, "config", "user.email", "cezar-command@users.noreply.github.com")

    git(repo, "fetch", "origin", branch)
    current = git(repo, "branch", "--show-current").stdout.strip()
    remote_ref = f"origin/{branch}"
    if current != branch:
        exists = git(
            repo,
            "show-ref",
            "--verify",
            "--quiet",
            f"refs/heads/{branch}",
            check=False,
        ).returncode == 0
        if exists:
            git(repo, "switch", branch)
        else:
            git(repo, "switch", "-c", branch, "--track", remote_ref)
    git(repo, "merge", "--ff-only", remote_ref)
    return repo, branch


def write_result(task_id: str, summary: dict[str, Any]) -> Path:
    root = runtime_root() / "results"
    root.mkdir(parents=True, exist_ok=True)
    path = root / f"{safe_slug(task_id)}.json"
    path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return path


def notify_blocked(
    bridge_url: str,
    task_id: str,
    message: str,
) -> None:
    summary = {
        "status": "BLOCKED",
        "task_id": task_id,
        "reason": message,
    }
    try:
        command_loop.send_to_commander(bridge_url, summary)
    except Exception:
        pass


def execute_task(
    task: dict[str, Any],
    cezar_url: str,
    bridge_url: str,
) -> int:
    if task.get("enabled") is not True:
        print("No enabled Cezar command task.", flush=True)
        return 0

    task_id = required_text(task, "task_id")
    processed = load_processed()
    if task_id in processed:
        print(f"task_id={task_id} already processed; no duplicate run.", flush=True)
        return 0

    prompt = required_text(task, "prompt")
    timeout_seconds = int(task.get("timeout_seconds") or 3600)
    push = task.get("push") is not False
    return_to_chatgpt = task.get("return_to_chatgpt") is not False

    repo, branch = ensure_target_repo(task)
    project_id = command_loop.ensure_project(cezar_url, repo)
    created = command_loop.start_run(cezar_url, project_id, prompt)
    run_id = command_loop.run_id_from(created)
    print(
        f"task_id={task_id} project_id={project_id} run_id={run_id}",
        flush=True,
    )

    run_record = command_loop.wait_run(
        cezar_url,
        project_id,
        run_id,
        timeout_seconds,
    )
    summary = command_loop.final_summary(run_record, run_id, project_id)
    summary["task_id"] = task_id
    summary["target_github"] = task.get("target_github")
    summary["target_repo"] = str(repo)
    summary["target_branch"] = branch

    if summary["status"] == "PASS" and push:
        summary["git"] = command_loop.commit_and_push(
            cezar_url,
            project_id,
            run_id,
        )

    result_path = write_result(task_id, summary)
    summary["local_result"] = str(result_path)

    processed.add(task_id)
    save_processed(processed)

    if return_to_chatgpt:
        command_loop.send_to_commander(bridge_url, summary)

    print(json.dumps(summary, ensure_ascii=False), flush=True)
    return 0 if summary["status"] == "PASS" else 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--control-repo", default=".")
    parser.add_argument(
        "--cezar-url",
        default=command_loop.DEFAULT_CEZAR_URL,
    )
    parser.add_argument(
        "--bridge-url",
        default=command_loop.DEFAULT_BRIDGE_URL,
    )
    args = parser.parse_args()

    control_repo = Path(args.control_repo).expanduser().resolve()
    try:
        task = read_task(control_repo)
        return execute_task(
            task,
            args.cezar_url.rstrip("/"),
            args.bridge_url.rstrip("/"),
        )
    except (DispatchError, command_loop.CommandLoopError, ValueError) as exc:
        task_id = "unknown"
        try:
            task_id = required_text(locals().get("task", {}), "task_id")
        except Exception:
            pass
        write_result(
            task_id,
            {
                "status": "BLOCKED",
                "task_id": task_id,
                "reason": str(exc),
            },
        )
        notify_blocked(args.bridge_url.rstrip("/"), task_id, str(exc))
        print(f"BLOCKED: {exc}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
