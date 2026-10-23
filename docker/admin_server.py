#!/usr/bin/env python3
"""Loopback admin for gateway status, server pin, and SOCKS URL checks."""

from __future__ import annotations

import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

HEALTH_KEYS = ("state", "reason", "server", "updated")
MAX_BODY = 4096


class ClashError(Exception):
    pass


class ClashClient:
    def __init__(self, base: str) -> None:
        text = base.rstrip("/")
        if "://" not in text:
            text = "http://" + text
        self.base = text

    def _open(self, method: str, path: str, payload: object | None = None) -> dict:
        data = None
        headers = {}
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            raise ClashError(str(exc)) from exc
        except urllib.error.URLError as exc:
            raise ClashError(str(exc)) from exc
        if not raw:
            return {}
        parsed = json.loads(raw.decode())
        return parsed if isinstance(parsed, dict) else {}

    def proxy_group(self) -> dict:
        data = self._open("GET", "/proxies/proxy")
        members = data.get("all") or []
        return {"now": data.get("now") or "", "all": [str(item) for item in members]}

    def switch(self, name: str) -> None:
        self._open("PUT", "/proxies/proxy", {"name": name})

    def close_tag(self, tag: str) -> None:
        if not tag or tag == "proxy":
            return
        try:
            data = self._open("GET", "/connections")
        except ClashError:
            return
        for conn in data.get("connections") or []:
            cid = str(conn.get("id") or "")
            chains = conn.get("chains") or []
            if not cid or tag not in chains:
                continue
            quoted = urllib.parse.quote(cid, safe="")
            try:
                self._open("DELETE", "/connections/" + quoted)
            except ClashError:
                continue


def validate_url(raw: object) -> str:
    if not isinstance(raw, str) or not 1 <= len(raw) <= 2048:
        raise ValueError("invalid url")
    parts = urlsplit(raw)
    if parts.scheme not in ("http", "https"):
        raise ValueError("invalid url")
    if parts.username or parts.password or not parts.hostname:
        raise ValueError("invalid url")
    return urlsplit(raw).geturl()


def probe_curl(url: str, socks_port: int, timeout: int) -> dict:
    argv = [
        "curl",
        "-sS",
        "-o",
        "/dev/null",
        "-L",
        "--max-redirs",
        "3",
        "--proto",
        "=http,https",
        "--proto-redir",
        "=http,https",
        "--socks5-hostname",
        f"127.0.0.1:{socks_port}",
        "-m",
        str(timeout),
        "-w",
        "%{http_code} %{time_total}",
        "--",
        url,
    ]
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=float(timeout) + 1,
        )
    except subprocess.TimeoutExpired as exc:
        return {"ok": False, "http_code": 0, "seconds": 0, "error": str(exc)}
    except OSError as exc:
        return {"ok": False, "http_code": 0, "seconds": 0, "error": str(exc)}
    lines = [line for line in (proc.stdout or "").splitlines() if line.strip()]
    last = lines[-1] if lines else ""
    parts = last.split()
    try:
        http_code = int(parts[0]) if parts else 0
    except ValueError:
        http_code = 0
    try:
        seconds = float(parts[1]) if len(parts) > 1 else 0.0
    except ValueError:
        seconds = 0.0
    ok = proc.returncode == 0 and http_code != 0
    error = "" if ok else ((proc.stderr or "").strip() or "probe failed")
    return {"ok": ok, "http_code": http_code, "seconds": seconds, "error": error}


def write_pin(path: str | Path, tag: str) -> None:
    dest = Path(path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".tmp")
    tmp.write_text(tag, encoding="utf-8")
    os.replace(tmp, dest)


def clear_pin(path: str | Path) -> None:
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def read_pin(path: str | Path) -> str:
    try:
        return Path(path).read_text(encoding="utf-8").replace("\r", "").replace("\n", "")
    except FileNotFoundError:
        return ""


def read_health(path: str | Path) -> dict:
    data = {key: "" for key in HEALTH_KEYS}
    try:
        text = Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        return data
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in data:
            data[key] = value
    return data


class AdminApp:
    def __init__(
        self,
        health_path: str | Path,
        pin_path: str | Path,
        socks_port: int,
        timeout: int,
        clash: ClashClient,
        probe=None,
        mock: bool = False,
    ) -> None:
        self.health_path = health_path
        self.pin_path = pin_path
        self.socks_port = socks_port
        self.timeout = timeout
        self.clash = clash
        self.probe = probe
        self.mock = mock

    def status(self) -> dict:
        health = read_health(self.health_path)
        pin = read_pin(self.pin_path)
        body = {
            "state": health["state"],
            "reason": health["reason"],
            "server": health["server"],
            "updated": health["updated"],
            "pinned": bool(pin),
            "pin": pin,
            "mock": self.mock,
            "members": [],
            "clash": "mock" if self.mock else "ok",
        }
        if self.mock:
            return body
        try:
            group = self.clash.proxy_group()
        except ClashError:
            body["clash"] = "unavailable"
            body["members"] = []
            return body
        members = list(group.get("all") or [])
        body["members"] = members
        body["clash"] = "ok"
        now = group.get("now") or ""
        if now:
            body["server"] = now
        if pin and pin not in members:
            clear_pin(self.pin_path)
            pin = ""
        body["pinned"] = bool(pin)
        body["pin"] = pin
        return body

    def switch(self, name: object) -> tuple[int, dict]:
        if self.mock:
            return 409, {"error": "mock"}
        if not isinstance(name, str) or not name or "\n" in name or "\r" in name:
            return 400, {"error": "invalid name"}
        try:
            group = self.clash.proxy_group()
        except ClashError:
            return 502, {"error": "clash"}
        members = group.get("all") or []
        if name not in members:
            return 400, {"error": "unknown server"}
        write_pin(self.pin_path, name)
        now = group.get("now") or ""
        if name != now:
            try:
                self.clash.switch(name)
                self.clash.close_tag(now)
            except ClashError:
                clear_pin(self.pin_path)
                return 502, {"error": "clash"}
        return 200, {"ok": True, "server": name, "pinned": True}

    def unpin(self) -> tuple[int, dict]:
        clear_pin(self.pin_path)
        return 200, {"ok": True, "server": self._server(), "pinned": False}

    def check(self, url: object) -> tuple[int, dict]:
        try:
            clean = validate_url(url)
        except ValueError as exc:
            return 400, {"error": str(exc)}
        runner = self.probe if self.probe is not None else probe_curl
        result = runner(clean, self.socks_port, self.timeout)
        return 200, result

    def _server(self) -> str:
        health_server = read_health(self.health_path)["server"]
        if self.mock:
            return health_server
        try:
            now = self.clash.proxy_group().get("now") or ""
        except ClashError:
            return health_server
        return now or health_server


def html_file() -> Path:
    override = os.environ.get("SPUR_ADMIN_HTML")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent / "admin_page.html"


def _send(handler: BaseHTTPRequestHandler, code: int, payload: bytes, content_type: str) -> None:
    handler.send_response(code)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(payload)))
    handler.end_headers()
    handler.wfile.write(payload)


def _send_json(handler: BaseHTTPRequestHandler, code: int, body: dict) -> None:
    _send(handler, code, json.dumps(body).encode(), "application/json")


def _read_json(handler: BaseHTTPRequestHandler) -> dict | None:
    media = handler.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
    if media != "application/json":
        _send_json(handler, 415, {"error": "content type"})
        return None
    raw_length = handler.headers.get("Content-Length")
    try:
        length = int(raw_length)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        _send_json(handler, 400, {"error": "length"})
        return None
    if length < 0 or length > MAX_BODY:
        _send_json(handler, 400, {"error": "length"})
        return None
    try:
        data = json.loads(handler.rfile.read(length).decode() or "null")
    except (UnicodeError, json.JSONDecodeError):
        _send_json(handler, 400, {"error": "json"})
        return None
    if not isinstance(data, dict):
        _send_json(handler, 400, {"error": "json"})
        return None
    return data


def _handle_get(handler: BaseHTTPRequestHandler, app: AdminApp) -> None:
    path = urllib.parse.urlsplit(handler.path).path
    if path == "/":
        page = html_file().read_bytes()
        _send(handler, 200, page, "text/html; charset=utf-8")
        return
    if path == "/api/status":
        _send_json(handler, 200, app.status())
        return
    _send_json(handler, 404, {"error": "not found"})


def _handle_post(handler: BaseHTTPRequestHandler, app: AdminApp) -> None:
    path = urllib.parse.urlsplit(handler.path).path
    if path not in ("/api/switch", "/api/unpin", "/api/check"):
        _send_json(handler, 404, {"error": "not found"})
        return
    body = _read_json(handler)
    if body is None:
        return
    if path == "/api/switch":
        code, payload = app.switch(body.get("name"))
    elif path == "/api/unpin":
        code, payload = app.unpin()
    else:
        code, payload = app.check(body.get("url"))
    _send_json(handler, code, payload)


def make_server(app: AdminApp, host: str = "0.0.0.0", port: int = 8787) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args) -> None:
            return

        def do_GET(self) -> None:
            _handle_get(self, app)

        def do_POST(self) -> None:
            _handle_post(self, app)

    return ThreadingHTTPServer((host, port), Handler)


def main() -> None:
    port = int(os.environ.get("SPUR_ADMIN_PORT", "8787"))
    mock = os.environ.get("SPUR_MOCK", "0") == "1"
    socks_port = int(os.environ.get("SOCKS_PORT", "1090"))
    timeout = int(os.environ.get("SPUR_HEALTH_TIMEOUT", "8"))
    app = AdminApp(
        health_path=os.environ.get("SPUR_HEALTH_FILE", "/run/spur-gw-health"),
        pin_path=os.environ.get("SPUR_PIN_FILE", "/run/spur-gw-pin"),
        socks_port=socks_port,
        timeout=timeout,
        clash=ClashClient(os.environ.get("SPUR_CLASH_API", "127.0.0.1:9090")),
        mock=mock,
    )
    make_server(app, "0.0.0.0", port).serve_forever()


if __name__ == "__main__":
    main()
