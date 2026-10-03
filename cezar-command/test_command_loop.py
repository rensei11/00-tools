from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("command_loop", HERE / "command_loop.py")
assert SPEC is not None and SPEC.loader is not None
command_loop = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(command_loop)


class CommandLoopTests(unittest.TestCase):
    def test_workflow_has_independent_audit_and_bounded_retry(self) -> None:
        definition = command_loop.workflow("change one file")
        steps = definition["steps"]
        self.assertEqual([step["id"] for step in steps], ["implement", "audit", "audit-gate"])
        self.assertEqual(steps[0]["runner"], "codex")
        self.assertEqual(steps[1]["runner"], "codex")
        self.assertIn("NEW agent session", steps[1]["prompt"])
        self.assertEqual(steps[2]["onFail"], {"retry": "implement", "max": 2})
        self.assertTrue(definition["autonomous"])
        self.assertTrue(definition["worktree"])

    def test_audit_gate_accepts_only_empty_issue_pass(self) -> None:
        command = command_loop.workflow("x")["steps"][2]["command"]
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            audit = root / ".cezar-command-audit.json"
            audit.write_text(
                json.dumps({"status": "PASS", "issues": [], "evidence": ["checked"]}),
                encoding="utf-8",
            )
            completed = subprocess.run(command, cwd=root, shell=True, check=False)
            self.assertEqual(completed.returncode, 0)
            self.assertFalse(audit.exists())

    def test_audit_gate_rejects_fail_and_keeps_evidence(self) -> None:
        command = command_loop.workflow("x")["steps"][2]["command"]
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            audit = root / ".cezar-command-audit.json"
            audit.write_text(
                json.dumps({"status": "FAIL", "issues": ["missing"], "evidence": ["diff"]}),
                encoding="utf-8",
            )
            completed = subprocess.run(command, cwd=root, shell=True, check=False)
            self.assertNotEqual(completed.returncode, 0)
            self.assertTrue(audit.exists())

    def test_audit_gate_rejects_pass_with_issues(self) -> None:
        command = command_loop.workflow("x")["steps"][2]["command"]
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            audit = root / ".cezar-command-audit.json"
            audit.write_text(
                json.dumps({"status": "PASS", "issues": ["still broken"], "evidence": []}),
                encoding="utf-8",
            )
            completed = subprocess.run(command, cwd=root, shell=True, check=False)
            self.assertNotEqual(completed.returncode, 0)

    def test_discover_project_matches_exact_root(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            repo = Path(raw).resolve()
            response = {
                "projects": [
                    {"id": "target", "root": str(repo), "status": "ok"},
                    {"id": "other", "root": str(repo.parent / "other"), "status": "ok"},
                ],
                "bootProject": "other",
                "projectsDir": str(repo.parent),
            }
            with mock.patch.object(command_loop, "http_json", return_value=response):
                self.assertEqual(command_loop.discover_project("http://cezar", repo), "target")

    def test_final_summary_never_turns_failed_run_into_pass(self) -> None:
        failed = command_loop.final_summary(
            {"status": "failed", "steps": [{"id": "audit-gate", "status": "failed"}]},
            "run-1",
            "project-1",
        )
        self.assertEqual(failed["status"], "FAIL")
        done = command_loop.final_summary(
            {"status": "done", "steps": [{"id": "audit-gate", "status": "done"}]},
            "run-2",
            "project-1",
        )
        self.assertEqual(done["status"], "PASS")

    def test_conversation_id_from_url(self) -> None:
        client = {"url": "https://chatgpt.com/c/01234567-89ab-cdef-0123-456789abcdef"}
        self.assertEqual(
            command_loop.conversation_id(client),
            "01234567-89ab-cdef-0123-456789abcdef",
        )


if __name__ == "__main__":
    unittest.main()
