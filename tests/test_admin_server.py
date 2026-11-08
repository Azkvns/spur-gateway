#!/usr/bin/env python3
"""Unittests for docker/admin_server.py."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import threading
import unittest
import unittest.mock
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
MODULE_PATH = ROOT / "docker" / "admin_server.py"


def load_module():
    spec = importlib.util.spec_from_file_location("admin_server", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise ModuleNotFoundError(f"admin_server not found at {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeClash:
    def __init__(self, module):
        self.module = module
        self.now = "nl-1"
        self.members = ["nl-1", "us-1"]
        self.puts = []
        self.closed = []
        self.fail_switch = False
        self.fail_group = False
        self.calls = []

    def proxy_group(self):
        self.calls.append("proxy_group")
        if self.fail_group:
            raise self.module.ClashError("down")
        return {"now": self.now, "all": list(self.members)}

    def switch(self, name):
        self.calls.append("switch")
        if self.fail_switch:
            raise self.module.ClashError("switch failed")
        self.puts.append(name)
        self.now = name

    def close_tag(self, tag):
        self.calls.append("close_tag")
        self.closed.append(tag)


def make_app(module, tmp, clash, probe=None, mock=False, auto_path=None):
    return module.AdminApp(
        health_path=Path(tmp) / "health",
        pin_path=Path(tmp) / "pin",
        lock_path=Path(tmp) / "lock",
        auto_path=Path(tmp) / "auto" if auto_path is None else auto_path,
        socks_port=1090,
        timeout=8,
        clash=clash,
        probe=probe,
        mock=mock,
    )


def write_health(tmp):
    (Path(tmp) / "health").write_text(
        "state=ok\nreason=\nserver=old\nupdated=2026-10-23T00:00:00Z\n",
        encoding="utf-8",
    )


class AdminServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.clash = FakeClash(self.mod)

    def app(self, probe=None, mock=False):
        return make_app(self.mod, self.tmp.name, self.clash, probe=probe, mock=mock)

    def test_status_prefers_clash_now(self):
        write_health(self.tmp.name)
        body = self.app().status()
        self.assertEqual(body["state"], "ok")
        self.assertEqual(body["server"], "nl-1")
        self.assertEqual(body["members"], ["nl-1", "us-1"])
        self.assertFalse(body["pinned"])
        self.assertFalse(body["locked"])
        self.assertEqual(body["lock"], "")
        self.assertEqual(body["clash"], "ok")

    def test_status_when_clash_down(self):
        write_health(self.tmp.name)
        self.clash.fail_group = True
        body = self.app().status()
        self.assertEqual(body["server"], "old")
        self.assertEqual(body["clash"], "unavailable")
        self.assertEqual(body["members"], [])

    def test_switch_writes_pin_and_closes_old(self):
        code, _body = self.app().switch("us-1")
        self.assertEqual(code, 200)
        self.assertEqual((Path(self.tmp.name) / "pin").read_text(encoding="utf-8"), "us-1")
        self.assertEqual(self.clash.puts, ["us-1"])
        self.assertEqual(self.clash.closed, ["nl-1"])

    def test_switch_unknown_does_not_pin(self):
        code, _body = self.app().switch("nope")
        self.assertEqual(code, 400)
        self.assertFalse((Path(self.tmp.name) / "pin").exists())
        self.assertEqual(self.clash.puts, [])

    def test_switch_failure_clears_pin(self):
        self.clash.fail_switch = True
        code, _body = self.app().switch("us-1")
        self.assertEqual(code, 502)
        self.assertFalse((Path(self.tmp.name) / "pin").exists())

    def test_switch_rejects_newline(self):
        code, _body = self.app().switch("nl-1\ninjected")
        self.assertEqual(code, 400)

    def test_mock_switch_is_conflict(self):
        code, body = self.app(mock=True).switch("us-1")
        self.assertEqual(code, 409)
        self.assertEqual(body["error"], "mock")
        self.assertEqual(self.clash.calls, [])

    def test_lock_writes_file_and_switches(self):
        code, body = self.app().lock("us-1")
        self.assertEqual(code, 200)
        self.assertEqual(body["locked"], True)
        self.assertEqual(body["lock"], "us-1")
        self.assertEqual((Path(self.tmp.name) / "lock").read_text(encoding="utf-8"), "us-1")
        self.assertEqual(self.clash.puts, ["us-1"])
        self.assertFalse((Path(self.tmp.name) / "pin").exists())

    def test_lock_unknown_does_not_write(self):
        code, _body = self.app().lock("nope")
        self.assertEqual(code, 400)
        self.assertFalse((Path(self.tmp.name) / "lock").exists())

    def test_lock_failure_keeps_previous_lock(self):
        lock = Path(self.tmp.name) / "lock"
        lock.write_text("nl-1", encoding="utf-8")
        self.clash.fail_switch = True
        code, _body = self.app().lock("us-1")
        self.assertEqual(code, 502)
        self.assertEqual(lock.read_text(encoding="utf-8"), "nl-1")

    def test_status_keeps_lock_when_member_missing(self):
        write_health(self.tmp.name)
        Path(self.tmp.name, "lock").write_text("gone", encoding="utf-8")
        body = self.app().status()
        self.assertTrue(body["locked"])
        self.assertEqual(body["lock"], "gone")
        self.assertTrue((Path(self.tmp.name) / "lock").exists())

    def test_unlock_removes_only_lock(self):
        Path(self.tmp.name, "lock").write_text("nl-1", encoding="utf-8")
        Path(self.tmp.name, "pin").write_text("nl-1", encoding="utf-8")
        code, body = self.app().unlock()
        self.assertEqual(code, 200)
        self.assertFalse(body["locked"])
        self.assertFalse((Path(self.tmp.name) / "lock").exists())
        self.assertTrue((Path(self.tmp.name) / "pin").exists())

    def test_switch_updates_existing_lock(self):
        Path(self.tmp.name, "lock").write_text("nl-1", encoding="utf-8")
        code, _body = self.app().switch("us-1")
        self.assertEqual(code, 200)
        self.assertEqual((Path(self.tmp.name) / "lock").read_text(encoding="utf-8"), "us-1")

    def test_switch_failure_does_not_move_lock(self):
        Path(self.tmp.name, "lock").write_text("nl-1", encoding="utf-8")
        self.clash.fail_switch = True
        code, _body = self.app().switch("us-1")
        self.assertEqual(code, 502)
        self.assertEqual((Path(self.tmp.name) / "lock").read_text(encoding="utf-8"), "nl-1")

    def test_lock_mock_rejected(self):
        code, body = self.app(mock=True).lock("us-1")
        self.assertEqual(code, 409)
        self.assertEqual(body["error"], "mock")

    def test_unpin_removes_file(self):
        pin = Path(self.tmp.name) / "pin"
        pin.write_text("nl-1", encoding="utf-8")
        code, body = self.app().unpin()
        self.assertEqual(code, 200)
        self.assertFalse(body["pinned"])
        self.assertFalse(pin.exists())
        self.assertEqual(self.clash.puts, [])

    def test_validate_url_rejects(self):
        validate = self.mod.validate_url
        for raw in (
            "file:///etc/passwd",
            "ftp://example.com",
            "https://user:pass@example.com",
            "https://",
            "x" * 2049,
            None,
        ):
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError):
                    validate(raw)
        self.assertEqual(validate("https://example.com/a"), "https://example.com/a")

    def test_probe_curl_argv(self):
        captured = {}

        class Proc:
            returncode = 0
            stdout = "204 0.12"
            stderr = ""

        def fake_run(argv, *args, **kwargs):
            captured["argv"] = list(argv)
            return Proc()

        with unittest.mock.patch.object(self.mod.subprocess, "run", fake_run):
            result = self.mod.probe_curl("https://example.com", 1090, 8)
        self.assertTrue(result["ok"])
        self.assertEqual(result["http_code"], 204)
        self.assertAlmostEqual(result["seconds"], 0.12)
        argv = captured["argv"]
        pairs = list(zip(argv, argv[1:]))
        self.assertIn(("--socks5-hostname", "127.0.0.1:1090"), pairs)
        self.assertIn(("--proto", "=http,https"), pairs)
        self.assertIn(("--proto-redir", "=http,https"), pairs)
        self.assertIn(("-o", "/dev/null"), pairs)
        self.assertIn(("--", "https://example.com"), pairs)

    def test_check_uses_probe(self):
        seen = []
        payload = {"ok": True, "http_code": 204, "seconds": 0.2, "error": ""}

        def probe(url, socks_port, timeout):
            seen.append((url, socks_port, timeout))
            return payload

        application = self.app(probe=probe)
        code, body = application.check("https://example.com")
        self.assertEqual(code, 200)
        self.assertEqual(body, payload)
        self.assertEqual(seen, [("https://example.com", 1090, 8)])
        code, _body = application.check("file:///tmp")
        self.assertEqual(code, 400)
        self.assertEqual(seen, [("https://example.com", 1090, 8)])

    def _start(self, application):
        httpd = self.mod.make_server(application, "127.0.0.1", 0)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        host, port = httpd.server_address
        return f"http://{host}:{port}"

    def _request(self, url, data=None, headers=None, method="GET"):
        req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=2) as resp:
                return resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as exc:
            try:
                return exc.code, exc.headers, exc.read()
            finally:
                exc.close()

    def test_http_rejects_form_post(self):
        base = self._start(self.app())
        code, _headers, _body = self._request(
            base + "/api/unpin",
            data=b"name=us-1",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        self.assertEqual(code, 415)
        self.assertFalse((Path(self.tmp.name) / "pin").exists())

    def test_http_switch_and_page(self):
        base = self._start(self.app())
        code, _headers, _body = self._request(
            base + "/api/switch",
            data=json.dumps({"name": "us-1"}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        self.assertEqual(code, 200)
        code, headers, body = self._request(base + "/")
        self.assertEqual(code, 200)
        self.assertIn("text/html", headers.get("Content-Type", ""))
        text = body.decode()
        self.assertIn("Проверить", text)
        self.assertIn("/api/status", text)
        self.assertIsNone(headers.get("Access-Control-Allow-Origin"))

    def test_http_lock_and_unlock(self):
        base = self._start(self.app())
        code, _headers, raw = self._request(
            base + "/api/lock",
            data=json.dumps({"name": "us-1"}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        self.assertEqual(code, 200)
        body = json.loads(raw)
        self.assertEqual(body["lock"], "us-1")
        _code, _headers, raw = self._request(base + "/api/status")
        status = json.loads(raw)
        self.assertTrue(status["locked"])
        code, _headers, raw = self._request(
            base + "/api/unlock",
            data=b"{}",
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        self.assertEqual(code, 200)
        body = json.loads(raw)
        self.assertFalse(body["locked"])
        self.assertFalse((Path(self.tmp.name) / "lock").exists())

    def test_status_auto_defaults_to_all_when_file_missing(self):
        write_health(self.tmp.name)
        body = self.app().status()
        self.assertEqual(body["auto"], [])
        self.assertTrue(body["auto_default"])

    def test_set_auto_writes_only_known_members(self):
        code, body = self.app().set_auto({"names": ["us-1", "us-1"]})
        self.assertEqual(code, 200)
        self.assertEqual(body["auto"], ["us-1"])
        self.assertFalse(body["auto_default"])
        self.assertEqual(
            (Path(self.tmp.name) / "auto").read_text(encoding="utf-8"),
            "us-1\n",
        )
        self.assertEqual(self.clash.puts, [])

    def test_set_auto_unknown_does_not_write(self):
        code, _body = self.app().set_auto({"names": ["nope"]})
        self.assertEqual(code, 400)
        self.assertFalse((Path(self.tmp.name) / "auto").exists())

    def test_set_auto_empty_blocks_everyone(self):
        code, body = self.app().set_auto({"names": []})
        self.assertEqual(code, 200)
        self.assertEqual(body["auto"], [])
        self.assertFalse(body["auto_default"])
        self.assertEqual((Path(self.tmp.name) / "auto").read_text(encoding="utf-8"), "")

    def test_set_auto_default_removes_file(self):
        path = Path(self.tmp.name) / "auto"
        path.write_text("us-1\n", encoding="utf-8")
        code, body = self.app().set_auto({"default": True})
        self.assertEqual(code, 200)
        self.assertTrue(body["auto_default"])
        self.assertFalse(path.exists())

    def test_set_auto_mock_rejected(self):
        code, body = self.app(mock=True).set_auto({"names": ["us-1"]})
        self.assertEqual(code, 409)
        self.assertEqual(body["error"], "mock")

    def test_set_auto_rejects_newline(self):
        code, _body = self.app().set_auto({"names": ["nl-1\ninjected"]})
        self.assertEqual(code, 400)
        self.assertFalse((Path(self.tmp.name) / "auto").exists())

    def test_http_set_auto(self):
        base = self._start(self.app())
        code, _headers, raw = self._request(
            base + "/api/auto",
            data=json.dumps({"names": ["us-1"]}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(raw)["auto"], ["us-1"])
        _code, _headers, raw = self._request(base + "/api/status")
        status = json.loads(raw)
        self.assertEqual(status["auto"], ["us-1"])
        self.assertFalse(status["auto_default"])


if __name__ == "__main__":
    unittest.main()
