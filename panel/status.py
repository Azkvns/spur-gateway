"""Read gateway health file for the panel."""

from __future__ import annotations

from pathlib import Path

_KNOWN_STATES = frozenset({"ok", "down", "reconnecting"})


def read_health(path: str | None) -> dict:
    """Parse a spur-gw health file into a panel-friendly dict.

    Does not touch the network or environment variables.
    """
    absent = {
        "state": "unknown",
        "reason": "gateway-not-running",
        "server": "",
        "updated": "",
        "source": "absent",
    }
    if path is None:
        return absent

    health_path = Path(path)
    if not health_path.is_file():
        return absent

    text = health_path.read_text(encoding="utf-8")
    parsed: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in {"state", "reason", "server", "updated"}:
            parsed[key] = value

    state = parsed.get("state", "")
    reason = parsed.get("reason", "")
    if state not in _KNOWN_STATES:
        state = "unknown"
        reason = "unreadable"

    return {
        "state": state,
        "reason": reason,
        "server": parsed.get("server", ""),
        "updated": parsed.get("updated", ""),
        "source": "file",
    }
