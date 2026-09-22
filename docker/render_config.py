#!/usr/bin/env python3
"""Render a sing-box JSON config from a VLESS subscription body."""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
from urllib.parse import unquote, urlparse

RESERVED_TAGS = frozenset({"proxy", "direct", "block", "in", "dns-out"})
UNSAFE_TAG_CHARS = re.compile(r"[^A-Za-z0-9._-]+")
# Empty / tcp are plain TCP (Vision/Reality). Anything else must be parsed or skipped.
SUPPORTED_TRANSPORTS = frozenset({"", "tcp", "ws", "grpc", "httpupgrade", "xhttp"})
# Live XHTTP outbounds are parsed then dropped from the selector pool: probes
# against this subscription failed under sing-box-extended (Vision-prefer mode).
DEFERRED_POOL_TRANSPORTS = frozenset({"xhttp"})
XHTTP_EXTRA_KEY_MAP = {
    "scMaxEachPostBytes": "sc_max_each_post_bytes",
    "scMaxConcurrentPosts": "sc_max_concurrent_posts",
    "scMinPostsIntervalMs": "sc_min_posts_interval_ms",
    "xPaddingBytes": "x_padding_bytes",
    "noGRPCHeader": "no_grpc_header",
    "xmux": "xmux",
}


def _parse_query(query: str) -> dict[str, list[str]]:
    """Split query on ``&``/``=`` and decode with ``unquote`` (not plus).

    Reality ``pbk`` / ``sid`` / WS ``path`` often contain raw ``+`` from
    standard base64; ``parse_qs`` would turn those into spaces.
    """
    qs: dict[str, list[str]] = {}
    if not query:
        return qs
    for part in query.split("&"):
        if not part:
            continue
        if "=" in part:
            raw_key, raw_value = part.split("=", 1)
        else:
            raw_key, raw_value = part, ""
        qs.setdefault(unquote(raw_key), []).append(unquote(raw_value))
    return qs


def _query(qs: dict[str, list[str]], *names: str) -> str:
    for name in names:
        values = qs.get(name)
        if values and values[0]:
            return values[0]
    return ""


def _looks_like_uri_list(body: str) -> bool:
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        return "://" in stripped
    return False


def _decode_base64(body: str) -> str:
    compact = "".join(body.split())
    if not compact:
        return ""
    pad = (-len(compact)) % 4
    compact += "=" * pad
    return base64.urlsafe_b64decode(compact).decode("utf-8")


def decode_subscription(body: str) -> list[str]:
    if _looks_like_uri_list(body):
        return body.splitlines()
    return _decode_base64(body).splitlines()


def _normalize_extra_json(raw: str) -> dict:
    """Parse provider ``extra`` JSON; tolerate JS-ish ``:+123`` number forms."""
    if not raw:
        return {}
    fixed = re.sub(r":\+(\d+)", r":\1", raw)
    fixed = re.sub(r",\+", ",", fixed)
    try:
        data = json.loads(fixed)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _xhttp_transport(qs: dict[str, list[str]]) -> dict:
    transport: dict = {
        "type": "xhttp",
        # sing-box-extended rejects configs that omit padding.
        "x_padding_bytes": "100-1000",
    }
    path = _query(qs, "path")
    if path:
        transport["path"] = path
    host = _query(qs, "host")
    if host:
        transport["host"] = host
    mode = _query(qs, "mode")
    if mode:
        transport["mode"] = mode
    extra = _normalize_extra_json(_query(qs, "extra"))
    for src, dest in XHTTP_EXTRA_KEY_MAP.items():
        if src not in extra:
            continue
        value = extra[src]
        if dest == "xmux" and isinstance(value, dict):
            transport["xmux"] = value
        else:
            transport[dest] = value
    return transport


def parse_vless(link: str, tag: str) -> dict:
    parsed = urlparse(link)
    qs = _parse_query(parsed.query)
    transport_type = _query(qs, "type")
    if transport_type not in SUPPORTED_TRANSPORTS:
        raise ValueError(f"unsupported transport: {transport_type}")

    outbound = {
        "type": "vless",
        "tag": tag,
        "server": parsed.hostname,
        "server_port": parsed.port or 443,
        "uuid": unquote(parsed.username or ""),
    }
    flow = _query(qs, "flow")
    if flow:
        outbound["flow"] = flow

    security = _query(qs, "security")
    if security in {"reality", "tls"}:
        tls: dict = {"enabled": True}
        server_name = _query(qs, "sni", "peer")
        if server_name:
            tls["server_name"] = server_name
        fingerprint = _query(qs, "fp")
        if fingerprint:
            tls["utls"] = {"enabled": True, "fingerprint": fingerprint}
        if security == "reality":
            pbk = _query(qs, "pbk")
            if not pbk:
                raise ValueError("reality link missing pbk")
            tls["reality"] = {
                "enabled": True,
                "public_key": pbk,
                "short_id": _query(qs, "sid"),
            }
        outbound["tls"] = tls

    if transport_type == "grpc":
        outbound["transport"] = {
            "type": "grpc",
            "service_name": _query(qs, "serviceName", "service_name"),
        }
    elif transport_type == "ws":
        transport: dict = {"type": "ws"}
        path = _query(qs, "path")
        if path:
            transport["path"] = path
        host = _query(qs, "host")
        if host:
            transport["headers"] = {"Host": host}
        outbound["transport"] = transport
    elif transport_type == "httpupgrade":
        transport = {"type": "httpupgrade"}
        path = _query(qs, "path")
        if path:
            transport["path"] = path
        host = _query(qs, "host")
        if host:
            transport["host"] = host
        outbound["transport"] = transport
    elif transport_type == "xhttp":
        # Kept for unit tests / future enable; not in SUPPORTED_TRANSPORTS.
        outbound["transport"] = _xhttp_transport(qs)

    return outbound


def tag_for(link: str, index: int, used: set) -> str:
    fragment = unquote(urlparse(link).fragment or "")
    base = UNSAFE_TAG_CHARS.sub("", fragment)
    if not base:
        base = f"node-{index}"
    tag = base
    suffix = 2
    while tag in used or tag in RESERVED_TAGS:
        tag = f"{base}-{suffix}"
        suffix += 1
    used.add(tag)
    return tag


def parse_links(lines: list[str]) -> list[dict]:
    used: set[str] = set()
    outbounds: list[dict] = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not stripped.lower().startswith("vless://"):
            scheme = stripped.split(":", 1)[0]
            print(f"warning: skipping unsupported scheme: {scheme}", file=sys.stderr)
            continue
        tag = tag_for(stripped, index, used)
        try:
            outbound = parse_vless(stripped, tag)
        except ValueError as exc:
            print(f"warning: skipping vless link ({exc}): {tag}", file=sys.stderr)
            used.discard(tag)
            continue
        transport_name = (outbound.get("transport") or {}).get("type") or ""
        if transport_name in DEFERRED_POOL_TRANSPORTS:
            print(
                f"warning: skipping deferred transport {transport_name}: {tag}",
                file=sys.stderr,
            )
            used.discard(tag)
            continue
        outbounds.append(outbound)
    if not outbounds:
        raise ValueError("no vless outbounds parsed")
    return outbounds


def _inbounds(socks_port: int, http_port: int) -> list[dict]:
    return [
        {
            "type": "socks",
            "tag": "socks-in",
            "listen": "0.0.0.0",
            "listen_port": socks_port,
        },
        {
            "type": "http",
            "tag": "http-in",
            "listen": "0.0.0.0",
            "listen_port": http_port,
        },
    ]


def render_config(
    outbounds,
    socks_port=1090,
    http_port=8128,
    clash_host="127.0.0.1",
    clash_port=9090,
    mock=False,
) -> dict:
    config = {"inbounds": _inbounds(socks_port, http_port)}
    if mock:
        config["outbounds"] = [{"type": "direct", "tag": "direct"}]
        config["route"] = {"final": "direct"}
        return config

    tags = [item["tag"] for item in outbounds]
    selector = {
        "type": "selector",
        "tag": "proxy",
        "outbounds": tags,
        "interrupt_exist_connections": False,
    }
    config["outbounds"] = [selector, *outbounds, {"type": "direct", "tag": "direct"}]
    config["route"] = {"final": "proxy"}
    config["experimental"] = {
        "clash_api": {
            "external_controller": f"{clash_host}:{clash_port}",
        }
    }
    return config


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Render sing-box config from VLESS links")
    parser.add_argument(
        "--mock",
        action="store_true",
        help="emit inbounds + direct only, ignore subscription body",
    )
    parser.add_argument(
        "--socks-port",
        type=int,
        default=1090,
        help="SOCKS inbound listen port (default: 1090)",
    )
    parser.add_argument(
        "--http-port",
        type=int,
        default=8128,
        help="HTTP inbound listen port (default: 8128)",
    )
    args = parser.parse_args(argv)
    body = sys.stdin.read()
    if args.mock:
        config = render_config(
            [],
            socks_port=args.socks_port,
            http_port=args.http_port,
            mock=True,
        )
    else:
        try:
            outbounds = parse_links(decode_subscription(body))
        except ValueError as exc:
            # binascii.Error and UnicodeDecodeError are ValueError subclasses:
            # the CLI reports one line instead of a traceback.
            print(f"render_config: {exc}", file=sys.stderr)
            return 1
        config = render_config(
            outbounds,
            socks_port=args.socks_port,
            http_port=args.http_port,
        )
    json.dump(config, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
