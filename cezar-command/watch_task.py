from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path


def run_dispatch(
    control_repo: Path,
    cezar_url: str,
) -> int:
    script = control_repo / "cezar-command" / "dispatch.py"
    completed = subprocess.run(
        [
            sys.executable,
            str(script),
            "--control-repo",
            str(control_repo),
            "--cezar-url",
            cezar_url,
        ],
        cwd=str(control_repo),
        check=False,
    )
    return completed.returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--control-repo", required=True)
    parser.add_argument("--cezar-url", required=True)
    parser.add_argument("--interval", type=int, default=20)
    args = parser.parse_args()

    control_repo = Path(args.control_repo).expanduser().resolve()
    if not (control_repo / ".git").exists():
        print("WATCHER=BLOCKED: control repository is not a Git repository", flush=True)
        return 1

    interval = max(10, args.interval)
    print(f"WATCHER=READY interval={interval}", flush=True)

    while True:
        try:
            run_dispatch(
                control_repo,
                args.cezar_url.rstrip("/"),
            )
        except Exception as exc:
            print(f"WATCHER=ERROR: {exc}", flush=True)
        time.sleep(interval)


if __name__ == "__main__":
    raise SystemExit(main())
