#!/usr/bin/env python3
"""Unittests for docker/render_config.py (VLESS → sing-box JSON)."""

from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "docker" / "render_config.py"
FIXTURES = ROOT / "tests" / "fixtures"
REALITY_LINK = (
    "vless://11111111-1111-1111-1111-111111111111@nl.example.test:443"
    "?security=reality&sni=www.cloudflare.com&fp=firefox"
    "&pbk=PUBLICKEYEXAMPLE&sid=abcd1234&type=tcp&flow=xtls-rprx-vision"
    "#Netherlands-st-1"
)
RESERVED = frozenset({"proxy", "direct", "block", "in", "dns-out"})


def load_module():
    spec = importlib.util.spec_from_file_location("render_config", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise FileNotFoundError(MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RenderConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_decode_raw_vless_link(self):
        body = (FIXTURES / "vless-reality.txt").read_text(encoding="utf-8")
        lines = self.mod.decode_subscription(body)
        self.assertEqual(lines[0], REALITY_LINK)

    def test_decode_base64_subscription(self):
        body = (FIXTURES / "sub-b64.txt").read_text(encoding="utf-8")
        lines = self.mod.decode_subscription(body)
        self.assertEqual(lines[0], REALITY_LINK)

    def test_parse_reality_vision_fields(self):
        outbound = self.mod.parse_vless(REALITY_LINK, "Netherlands-st-1")
        self.assertEqual(outbound["type"], "vless")
        self.assertEqual(outbound["tag"], "Netherlands-st-1")
        self.assertEqual(outbound["uuid"], "11111111-1111-1111-1111-111111111111")
        self.assertEqual(outbound["server"], "nl.example.test")
        self.assertEqual(outbound["server_port"], 443)
        self.assertEqual(outbound["flow"], "xtls-rprx-vision")
        self.assertTrue(outbound["tls"]["enabled"])
        self.assertEqual(outbound["tls"]["server_name"], "www.cloudflare.com")
        self.assertEqual(outbound["tls"]["utls"]["fingerprint"], "firefox")
        self.assertEqual(outbound["tls"]["reality"]["public_key"], "PUBLICKEYEXAMPLE")
        self.assertEqual(outbound["tls"]["reality"]["short_id"], "abcd1234")

    def test_parse_vless_default_port_and_peer_sni(self):
        link = (
            "vless://11111111-1111-1111-1111-111111111111@nl.example.test"
            "?security=reality&peer=www.cloudflare.com&pbk=PUBLICKEYEXAMPLE"
            "&sid=abcd1234#noport"
        )
        outbound = self.mod.parse_vless(link, "noport")
        self.assertEqual(outbound["server_port"], 443)
        self.assertEqual(outbound["tls"]["server_name"], "www.cloudflare.com")

    def test_parse_grpc_transport(self):
        link = (
            "vless://11111111-1111-1111-1111-111111111111@grpc.example.test:443"
            "?security=tls&sni=grpc.example.test&type=grpc"
            "&serviceName=GunService#grpc-1"
        )
        outbound = self.mod.parse_vless(link, "grpc-1")
        self.assertEqual(outbound["transport"]["type"], "grpc")
        self.assertEqual(outbound["transport"]["service_name"], "GunService")

    def test_parse_ws_transport(self):
        link = (
            "vless://11111111-1111-1111-1111-111111111111@ws.example.test:443"
            "?security=tls&sni=ws.example.test&type=ws&path=/vless"
            "&host=ws.example.test#ws-1"
        )
        outbound = self.mod.parse_vless(link, "ws-1")
        self.assertEqual(outbound["transport"]["type"], "ws")
        self.assertEqual(outbound["transport"]["path"], "/vless")
        self.assertEqual(outbound["transport"]["headers"]["Host"], "ws.example.test")

    def test_parse_xhttp_transport_and_extra(self):
        body = (FIXTURES / "vless-xhttp.txt").read_text(encoding="utf-8").strip()
        outbound = self.mod.parse_vless(body, "xhttp-1")
        self.assertEqual(outbound["server"], "xhttp.example.test")
        self.assertEqual(outbound["server_port"], 8008)
        self.assertNotIn("tls", outbound)
        transport = outbound["transport"]
        self.assertEqual(transport["type"], "xhttp")
        self.assertEqual(transport["path"], "/collect")
        self.assertEqual(transport["host"], "api.example.test")
        self.assertEqual(transport["mode"], "stream-up")
        self.assertEqual(transport["sc_max_each_post_bytes"], 1000000)
        self.assertEqual(transport["sc_min_posts_interval_ms"], 30)
        self.assertEqual(transport["x_padding_bytes"], "100-1000")

    def test_parse_httpupgrade_transport(self):
        link = (
            "vless://11111111-1111-1111-1111-111111111111@hu.example.test:443"
            "?security=tls&sni=hu.example.test&type=httpupgrade"
            "&path=/upgrade&host=hu.example.test&fp=chrome#hu-1"
        )
        outbound = self.mod.parse_vless(link, "hu-1")
        self.assertEqual(outbound["transport"]["type"], "httpupgrade")
        self.assertEqual(outbound["transport"]["path"], "/upgrade")
        self.assertEqual(outbound["transport"]["host"], "hu.example.test")
        self.assertTrue(outbound["tls"]["enabled"])

    def test_skip_unknown_transport_with_warning(self):
        bad = (
            "vless://11111111-1111-1111-1111-111111111111@bad.example.test:443"
            "?security=none&type=kcp#bad-kcp"
        )
        err = io.StringIO()
        with redirect_stderr(err):
            outbounds = self.mod.parse_links([bad, REALITY_LINK])
        self.assertEqual(len(outbounds), 1)
        self.assertEqual(outbounds[0]["tag"], "Netherlands-st-1")
        self.assertNotIn("transport", outbounds[0])
        stderr = err.getvalue().lower()
        self.assertIn("warning", stderr)
        self.assertIn("kcp", stderr)

    def test_xhttp_parsed_but_deferred_from_pool(self):
        body = (FIXTURES / "vless-xhttp.txt").read_text(encoding="utf-8").strip()
        err = io.StringIO()
        with redirect_stderr(err):
            outbounds = self.mod.parse_links([body, REALITY_LINK])
        self.assertEqual(len(outbounds), 1)
        self.assertEqual(outbounds[0]["tag"], "Netherlands-st-1")
        self.assertIn("deferred", err.getvalue().lower())
        self.assertIn("xhttp", err.getvalue().lower())

    def test_reality_without_pbk_is_skipped(self):
        link = (
            "vless://11111111-1111-1111-1111-111111111111@nl.example.test:443"
            "?security=reality&sni=www.cloudflare.com&type=tcp#no-pbk"
        )
        err = io.StringIO()
        with redirect_stderr(err):
            outbounds = self.mod.parse_links([link, REALITY_LINK])
        self.assertEqual(len(outbounds), 1)
        self.assertIn("pbk", err.getvalue().lower())

    def test_query_plus_and_percent_2b_survive(self):
        raw_link = (
            "vless://11111111-1111-1111-1111-111111111111@nl.example.test:443"
            "?security=reality&sni=www.cloudflare.com&fp=firefox"
            "&pbk=ab+c/DE==&type=ws&path=/vless+ws#plus-raw"
        )
        raw = self.mod.parse_vless(raw_link, "plus-raw")
        self.assertEqual(raw["tls"]["reality"]["public_key"], "ab+c/DE==")
        self.assertEqual(raw["transport"]["path"], "/vless+ws")

        encoded_link = (
            "vless://11111111-1111-1111-1111-111111111111@nl.example.test:443"
            "?security=reality&sni=www.cloudflare.com&fp=firefox"
            "&pbk=ab%2Bc/DE==&type=ws&path=/vless%2Bws#plus-pct"
        )
        encoded = self.mod.parse_vless(encoded_link, "plus-pct")
        self.assertEqual(encoded["tls"]["reality"]["public_key"], "ab+c/DE==")
        self.assertEqual(encoded["transport"]["path"], "/vless+ws")

    def test_unique_tags(self):
        used: set[str] = set()
        first = self.mod.tag_for(REALITY_LINK, 0, used)
        second = self.mod.tag_for(REALITY_LINK, 1, used)
        self.assertEqual(first, "Netherlands-st-1")
        self.assertNotEqual(first, second)
        self.assertEqual({first, second}, used)

    def test_reserved_tag_direct_is_renamed(self):
        link = REALITY_LINK.rsplit("#", 1)[0] + "#direct"
        used: set[str] = set()
        tag = self.mod.tag_for(link, 0, used)
        self.assertNotIn(tag, RESERVED)
        outbounds = self.mod.parse_links([link])
        self.assertEqual(outbounds[0]["tag"], tag)
        config = self.mod.render_config(outbounds)
        tags = [item["tag"] for item in config["outbounds"]]
        self.assertIn("direct", tags)
        self.assertIn("proxy", tags)
        self.assertEqual(tags.count("direct"), 1)
        selector = config["outbounds"][0]
        self.assertEqual(selector["type"], "selector")
        self.assertEqual(selector["outbounds"], [tag])

    def test_skip_ss_with_warning(self):
        err = io.StringIO()
        with redirect_stderr(err):
            outbounds = self.mod.parse_links(
                ["ss://example-skip", "", "# comment", REALITY_LINK]
            )
        self.assertEqual(len(outbounds), 1)
        self.assertEqual(outbounds[0]["tag"], "Netherlands-st-1")
        stderr = err.getvalue().lower()
        self.assertIn("warning", stderr)
        self.assertIn("ss", stderr)

    def test_zero_outbounds_is_error(self):
        err = io.StringIO()
        with redirect_stderr(err), self.assertRaises(ValueError):
            self.mod.parse_links(["ss://only-shadowsocks", "# none"])
        self.assertIn("warning", err.getvalue().lower())

    def test_mock_config_has_no_selector(self):
        config = self.mod.render_config([], mock=True)
        types = [item["type"] for item in config["outbounds"]]
        tags = [item["tag"] for item in config["outbounds"]]
        self.assertEqual(types, ["direct"])
        self.assertEqual(tags, ["direct"])
        self.assertEqual(config["route"]["final"], "direct")
        self.assertNotIn("clash_api", config.get("experimental", {}))
        inbound_types = {item["type"] for item in config["inbounds"]}
        self.assertEqual(inbound_types, {"socks", "http"})
        ports = {item["type"]: item["listen_port"] for item in config["inbounds"]}
        self.assertEqual(ports["socks"], 1090)
        self.assertEqual(ports["http"], 8128)

    def test_live_config_has_selector_listing_all_tags(self):
        outbounds = self.mod.parse_links([REALITY_LINK])
        config = self.mod.render_config(outbounds)
        selector = config["outbounds"][0]
        self.assertEqual(selector["type"], "selector")
        self.assertEqual(selector["tag"], "proxy")
        self.assertEqual(selector["outbounds"], ["Netherlands-st-1"])
        self.assertIs(selector["interrupt_exist_connections"], False)
        self.assertEqual(config["outbounds"][1]["tag"], "Netherlands-st-1")
        self.assertEqual(config["outbounds"][-1], {"type": "direct", "tag": "direct"})
        self.assertEqual(config["route"]["final"], "proxy")
        self.assertEqual(
            config["experimental"]["clash_api"]["external_controller"],
            "127.0.0.1:9090",
        )
        inbound_types = [item["type"] for item in config["inbounds"]]
        self.assertEqual(inbound_types, ["socks", "http"])

    def test_cli_mock_reads_stdin_writes_json(self):
        result = subprocess.run(
            [sys.executable, str(MODULE_PATH), "--mock"],
            input="",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout)
        self.assertEqual(config["route"]["final"], "direct")
        self.assertEqual([item["tag"] for item in config["outbounds"]], ["direct"])
        self.assertNotIn("clash_api", config.get("experimental", {}))

    def _inbound_ports(self, config):
        return {item["type"]: item["listen_port"] for item in config["inbounds"]}

    def test_cli_mock_honors_port_flags(self):
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--mock",
                "--socks-port",
                "1190",
                "--http-port",
                "8228",
            ],
            input="",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        ports = self._inbound_ports(json.loads(result.stdout))
        self.assertEqual(ports["socks"], 1190)
        self.assertEqual(ports["http"], 8228)

    def test_cli_live_honors_port_flags(self):
        body = (FIXTURES / "vless-reality.txt").read_text(encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--socks-port",
                "1191",
                "--http-port",
                "8229",
            ],
            input=body,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        ports = self._inbound_ports(json.loads(result.stdout))
        self.assertEqual(ports["socks"], 1191)
        self.assertEqual(ports["http"], 8229)


    def _run_cli(self, body):
        return subprocess.run(
            [sys.executable, str(MODULE_PATH)],
            input=body,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_cli_zero_outbounds_reports_one_line(self):
        result = self._run_cli("")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(len(result.stderr.strip().splitlines()), 1, result.stderr)

    def test_cli_undecodable_body_reports_one_line(self):
        result = self._run_cli("not a subscription at all")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(len(result.stderr.strip().splitlines()), 1, result.stderr)


if __name__ == "__main__":
    unittest.main()
