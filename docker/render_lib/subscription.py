"""Decode VLESS subscription bodies (raw URI list or base64)."""

from __future__ import annotations

import base64
import json
import re
from urllib.parse import unquote


def parse_query(query: str) -> dict[str, list[str]]:
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


def query_first(qs: dict[str, list[str]], *names: str) -> str:
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


def normalize_extra_json(raw: str) -> dict:
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
