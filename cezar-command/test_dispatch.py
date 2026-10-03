from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
SPEC = importlib.util.spec_from_file_location("dispatch", HERE / "dispatch.py")
assert SPEC is not None and SPEC.loader is not None
dispatch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dispatch)


class DispatchTests(unittest.TestCase):
    def test_saved_result_retries_delivery_without_rerunning_cezar(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            results = root / "results"
            results.mkdir(parents=True)
            (results / "task-1.json").write_text(
                json.dumps(
                    {
                        "status": "PASS",
                        "task_id": "task-1",
                        "run_id": "already-finished",
                    }
                ),
                encoding="utf-8",
            )

            with (
                mock.patch.object(dispatch, "runtime_root", return_value=root),
                mock.patch.object(dispatch.command_loop, "send_to_commander") as send,
                mock.patch.object(dispatch, "ensure_target_repo") as ensure_repo,
                mock.patch.object(dispatch.command_loop, "start_run") as start_run,
            ):
                rc = dispatch.execute_task(
                    {
                        "enabled": True,
                        "task_id": "task-1",
                        "return_to_chatgpt": True,
                    },
                    "http://cezar",
                )

            self.assertEqual(rc, 0)
            send.assert_called_once()
            ensure_repo.assert_not_called()
            start_run.assert_not_called()
            processed = json.loads((root / "processed.json").read_text(encoding="ascii"))
            self.assertEqual(processed, ["task-1"])

    def test_failed_delivery_does_not_mark_result_processed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            summary = {
                "status": "PASS",
                "task_id": "task-2",
                "run_id": "already-finished",
            }
            with (
                mock.patch.object(dispatch, "runtime_root", return_value=root),
                mock.patch.object(
                    dispatch.command_loop,
                    "send_to_commander",
                    side_effect=RuntimeError("delivery failed"),
                ),
            ):
                with self.assertRaises(RuntimeError):
                    dispatch.finish_saved_result(
                        "task-2",
                        summary,
                        True,
                    )
            self.assertFalse((root / "processed.json").exists())


if __name__ == "__main__":
    unittest.main()
