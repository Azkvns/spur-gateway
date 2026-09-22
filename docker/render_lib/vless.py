"""Parse VLESS subscription links into sing-box outbound dicts."""

from __future__ import annotations

import re
import sys
from urllib.parse import unquote, urlparse

from render_lib.subscription import parse_query, query_first
from render_lib.transports import build_transport, tls_settings

RESERVED_TAGS = frozenset({"proxy", "direct", "block", "in", "dns-out"})
UNSAFE_TAG_CHARS = re.compile(r"[^A-Za-z0-9._-]+")
# Empty / tcp are plain TCP (Vision/Reality). Anything else must be parsed or skipped.
SUPPORTED_TRANSPORTS = frozenset({"", "tcp", "ws", "grpc", "httpupgrade", "xhttp"})
# Live XHTTP outbounds are parsed then dropped from the selector pool: probes
# against this subscription failed under sing-box-extended (Vision-prefer mode).
DEFERRED_POOL_TRANSPORTS = frozenset({"xhttp"})


def parse_vless(link: str, tag: str) -> dict:
    parsed = urlparse(link)
    qs = parse_query(parsed.query)
    transport_type = query_first(qs, "type")
    if transport_type not in SUPPORTED_TRANSPORTS:
        raise ValueError(f"unsupported transport: {transport_type}")

    outbound = {
        "type": "vless",
        "tag": tag,
        "server": parsed.hostname,
        "server_port": parsed.port or 443,
        "uuid": unquote(parsed.username or ""),
    }
    flow = query_first(qs, "flow")
    if flow:
        outbound["flow"] = flow

    tls = tls_settings(qs)
    if tls is not None:
        outbound["tls"] = tls

    transport = build_transport(transport_type, qs)
    if transport is not None:
        outbound["transport"] = transport

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
