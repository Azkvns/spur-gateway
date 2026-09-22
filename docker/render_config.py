#!/usr/bin/env python3
"""Render a sing-box JSON config from a VLESS subscription body."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_DOCKER_DIR = Path(__file__).resolve().parent
if str(_DOCKER_DIR) not in sys.path:
    sys.path.insert(0, str(_DOCKER_DIR))

from render_lib.singbox import ListenPorts, render_config
from render_lib.subscription import decode_subscription
from render_lib.vless import parse_links, parse_vless, tag_for

__all__ = [
    "decode_subscription",
    "parse_vless",
    "tag_for",
    "parse_links",
    "render_config",
    "main",
]


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
    ports = ListenPorts(socks=args.socks_port, http=args.http_port)
    if args.mock:
        config = render_config([], ports=ports, mock=True)
    else:
        try:
            outbounds = parse_links(decode_subscription(body))
        except ValueError as exc:
            # binascii.Error and UnicodeDecodeError are ValueError subclasses:
            # the CLI reports one line instead of a traceback.
            print(f"render_config: {exc}", file=sys.stderr)
            return 1
        config = render_config(outbounds, ports=ports)
    json.dump(config, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
