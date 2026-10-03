from __future__ import annotations

import argparse
import html
import json
import queue
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


EXPECTED_EXTENSION_VERSION = "1.1.0"
SETUP_NOTIFY_PORT = 4398
MAX_PAYLOAD_BYTES = 262_144
REGISTER_TIMEOUT_SECONDS = 8
DELIVER_TIMEOUT_SECONDS = 45


class CommanderLinkError(RuntimeError):
    pass


def windows_powershell() -> str:
    found = shutil.which("powershell.exe")
    if found:
        return found
    fallback = Path(
        "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    )
    if fallback.is_file():
        return str(fallback)
    raise CommanderLinkError("Windows PowerShell was not found.")


def open_control_page(url: str) -> None:
    try:
        parsed = urlparse(url)
        port = parsed.port
    except ValueError as exc:
        raise CommanderLinkError("Invalid localhost control URL.") from exc
    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or parsed.path != "/start"
        or port is None
        or not 1 <= port <= 65535
        or parsed.query
        or parsed.fragment
        or parsed.username
        or parsed.password
    ):
        raise CommanderLinkError(
            "Commander control URL must be http://127.0.0.1:<port>/start."
        )

    powershell = windows_powershell()
    escaped = url.replace("'", "''")
    script = (
        "$candidates=@("
        "(Join-Path $env:ProgramFiles 'Google\\Chrome\\Application\\chrome.exe'),"
        "(Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) "
        "'Google\\Chrome\\Application\\chrome.exe'),"
        "(Join-Path $env:LOCALAPPDATA 'Google\\Chrome\\Application\\chrome.exe')"
        ");"
        "$chrome=$candidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|"
        "Select-Object -First 1;"
        "if(-not $chrome){exit 2};"
        f"Start-Process -FilePath $chrome -ArgumentList @('{escaped}')"
    )
    completed = subprocess.run(
        [
            powershell,
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            script,
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if completed.returncode == 2:
        raise CommanderLinkError("Google Chrome was not found on Windows.")
    if completed.returncode != 0:
        raise CommanderLinkError(
            f"Chrome control page could not be opened ({completed.returncode})."
        )


def handler(
    mode: str,
    message: str,
    result_queue: queue.Queue[dict[str, Any]],
):
    class Handler(BaseHTTPRequestHandler):
        server_version = "RenseiCezarCommanderLink/1.0"

        def log_message(self, format: str, *args: object) -> None:
            return

        def reply(
            self,
            status: int,
            body: str,
            content_type: str = "text/plain; charset=utf-8",
        ) -> None:
            encoded = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self) -> None:
            if urlparse(self.path).path != "/start":
                self.reply(404, "Not found")
                return
            escaped_mode = html.escape(mode, quote=True)
            escaped_message = html.escape(message, quote=True)
            page = f"""<!doctype html>
<html><head><meta charset="utf-8">
<meta name="cezar-command-mode" content="{escaped_mode}">
<meta name="cezar-command-message" content="{escaped_message}">
<title>Rensei Cezar Commander Link</title></head>
<body><p>Connecting the Cezar command center to the registered ChatGPT commander.</p></body>
</html>"""
            self.reply(200, page, "text/html; charset=utf-8")

        def do_POST(self) -> None:
            if urlparse(self.path).path != "/result":
                self.reply(404, "Not found")
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.reply(400, "Invalid Content-Length")
                return
            if not 1 <= length <= MAX_PAYLOAD_BYTES:
                self.reply(400, "Invalid payload size")
                return
            try:
                payload = json.loads(
                    self.rfile.read(length).decode("utf-8")
                )
            except (UnicodeDecodeError, json.JSONDecodeError):
                self.reply(400, "Invalid JSON")
                return
            if not isinstance(payload, dict):
                self.reply(400, "Invalid payload")
                return
            try:
                result_queue.put_nowait(payload)
            except queue.Full:
                self.reply(409, "Result already received")
                return
            self.reply(200, "OK")

    return Handler


def exchange(
    mode: str,
    message: str = "",
    *,
    timeout_seconds: int,
) -> dict[str, Any]:
    result_queue: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=1)
    server = ThreadingHTTPServer(
        ("127.0.0.1", 0),
        handler(mode, message, result_queue),
    )
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_address[1]}/start"

    try:
        open_control_page(url)
        try:
            result = result_queue.get(timeout=timeout_seconds)
        except queue.Empty as exc:
            raise CommanderLinkError(
                "The independent commander Chrome extension did not answer."
            ) from exc

        extension_version = str(result.get("extensionVersion") or "").strip()
        if extension_version != EXPECTED_EXTENSION_VERSION:
            raise CommanderLinkError(
                "Commander extension version mismatch: "
                f"{extension_version or '(missing)'} != "
                f"{EXPECTED_EXTENSION_VERSION}"
            )
        status = str(result.get("status") or "").strip()
        if status == "BLOCKED":
            raise CommanderLinkError(
                str(result.get("error") or "Commander extension blocked.")
            )
        return result
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2.0)


def wait_for_human_registration(
    *,
    port: int = SETUP_NOTIFY_PORT,
    timeout_seconds: int = 300,
) -> dict[str, Any]:
    result_queue: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=1)

    class RegistrationHandler(BaseHTTPRequestHandler):
        server_version = "RenseiCezarCommanderSetup/1.0"

        def log_message(self, format: str, *args: object) -> None:
            return

        def reply(self, status: int, body: str) -> None:
            encoded = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(encoded)

        def do_POST(self) -> None:
            if urlparse(self.path).path != "/register":
                self.reply(404, "Not found")
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.reply(400, "Invalid Content-Length")
                return
            if not 1 <= length <= MAX_PAYLOAD_BYTES:
                self.reply(400, "Invalid payload size")
                return
            try:
                payload = json.loads(
                    self.rfile.read(length).decode("utf-8")
                )
            except (UnicodeDecodeError, json.JSONDecodeError):
                self.reply(400, "Invalid JSON")
                return
            if not isinstance(payload, dict):
                self.reply(400, "Invalid payload")
                return
            try:
                result_queue.put_nowait(payload)
            except queue.Full:
                self.reply(409, "Registration already received")
                return
            self.reply(200, "OK")

    try:
        server = ThreadingHTTPServer(("127.0.0.1", int(port)), RegistrationHandler)
    except OSError as exc:
        raise CommanderLinkError(
            f"One-time commander setup port {port} is unavailable: {exc}"
        ) from exc

    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def probe_existing_registration() -> None:
        try:
            existing = register_commander()
        except Exception:
            return
        try:
            result_queue.put_nowait(existing)
        except queue.Full:
            return

    probe_thread = threading.Thread(
        target=probe_existing_registration,
        daemon=True,
    )
    probe_thread.start()

    try:
        try:
            result = result_queue.get(timeout=timeout_seconds)
        except queue.Empty as exc:
            raise CommanderLinkError(
                "Timed out waiting for the one-time commander registration button."
            ) from exc

        version = str(result.get("extensionVersion") or "").strip()
        if version != EXPECTED_EXTENSION_VERSION:
            raise CommanderLinkError(
                "Commander extension version mismatch during setup: "
                f"{version or '(missing)'} != {EXPECTED_EXTENSION_VERSION}"
            )
        conversation_url = str(result.get("conversationUrl") or "").strip()
        parsed = urlparse(conversation_url)
        if (
            parsed.scheme != "https"
            or parsed.hostname != "chatgpt.com"
            or not parsed.path.startswith("/c/")
        ):
            raise CommanderLinkError(
                "One-time commander registration returned an invalid ChatGPT URL."
            )
        return {
            "status": "REGISTERED",
            "conversationUrl": conversation_url,
            "extensionVersion": version,
        }
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2.0)


def register_commander() -> dict[str, Any]:
    result = exchange(
        "register",
        timeout_seconds=REGISTER_TIMEOUT_SECONDS,
    )
    if result.get("status") != "REGISTERED":
        raise CommanderLinkError(
            f"Commander registration was not confirmed: {result}"
        )
    return result


def deliver_message(message: str) -> dict[str, Any]:
    prompt = str(message or "").strip()
    if not prompt:
        raise CommanderLinkError("Commander message is empty.")
    result = exchange(
        "deliver",
        prompt,
        timeout_seconds=DELIVER_TIMEOUT_SECONDS,
    )
    if result.get("status") != "SUBMITTED":
        raise CommanderLinkError(
            f"Commander delivery was not confirmed: {result}"
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["register", "deliver", "wait-register"])
    parser.add_argument("--message", default="")
    parser.add_argument("--setup-port", type=int, default=SETUP_NOTIFY_PORT)
    args = parser.parse_args()

    try:
        if args.mode == "register":
            result = register_commander()
        elif args.mode == "wait-register":
            result = wait_for_human_registration(port=args.setup_port)
        else:
            result = deliver_message(args.message)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except CommanderLinkError as exc:
        print(f"COMMANDER_LINK=BLOCKED: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
