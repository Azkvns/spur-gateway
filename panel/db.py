"""SQLite storage for panel profiles and probes."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from typing import Any

_ALLOWED_UPDATE = frozenset({"name", "socks_port", "http_port", "note"})


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _row_to_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    if row is None:
        return None
    return dict(row)


def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS profiles (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          socks_port INTEGER NOT NULL,
          http_port INTEGER NOT NULL,
          note TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS probes (
          id INTEGER PRIMARY KEY,
          profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
          state TEXT NOT NULL CHECK (state IN ('ok', 'down', 'reconnecting', 'unknown')),
          reason TEXT NOT NULL DEFAULT '',
          server TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL
        );
        """
    )
    conn.commit()


def seed_demo(conn: sqlite3.Connection) -> None:
    row = conn.execute("SELECT COUNT(*) AS n FROM profiles").fetchone()
    if row is not None and row["n"] > 0:
        return
    create_profile(
        conn,
        "loopback",
        1090,
        8128,
        "Локальный шлюз на этой машине",
    )


def create_profile(
    conn: sqlite3.Connection,
    name: str,
    socks_port: int,
    http_port: int,
    note: str,
) -> dict[str, Any]:
    now = _now()
    cur = conn.execute(
        """
        INSERT INTO profiles (name, socks_port, http_port, note, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (name, socks_port, http_port, note, now, now),
    )
    conn.commit()
    profile = get_profile(conn, int(cur.lastrowid))
    assert profile is not None
    return profile


def list_profiles(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute("SELECT * FROM profiles ORDER BY id").fetchall()
    return [dict(row) for row in rows]


def get_profile(conn: sqlite3.Connection, profile_id: int) -> dict[str, Any] | None:
    row = conn.execute(
        "SELECT * FROM profiles WHERE id = ?", (profile_id,)
    ).fetchone()
    return _row_to_dict(row)


def update_profile(
    conn: sqlite3.Connection, profile_id: int, fields: dict[str, Any]
) -> dict[str, Any] | None:
    existing = get_profile(conn, profile_id)
    if existing is None:
        return None
    sets: list[str] = []
    values: list[Any] = []
    for key, value in fields.items():
        if key not in _ALLOWED_UPDATE:
            continue
        sets.append(f"{key} = ?")
        values.append(value)
    if not sets:
        return existing
    sets.append("updated_at = ?")
    values.append(_now())
    values.append(profile_id)
    conn.execute(
        f"UPDATE profiles SET {', '.join(sets)} WHERE id = ?",
        values,
    )
    conn.commit()
    return get_profile(conn, profile_id)


def delete_profile(conn: sqlite3.Connection, profile_id: int) -> bool:
    cur = conn.execute("DELETE FROM profiles WHERE id = ?", (profile_id,))
    conn.commit()
    return cur.rowcount > 0


def add_probe(
    conn: sqlite3.Connection,
    profile_id: int,
    state: str,
    reason: str,
    server: str,
) -> dict[str, Any]:
    now = _now()
    cur = conn.execute(
        """
        INSERT INTO probes (profile_id, state, reason, server, created_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        (profile_id, state, reason, server, now),
    )
    conn.commit()
    row = conn.execute(
        "SELECT * FROM probes WHERE id = ?", (int(cur.lastrowid),)
    ).fetchone()
    assert row is not None
    return dict(row)


def list_probes(
    conn: sqlite3.Connection, profile_id: int, limit: int = 20
) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT * FROM probes
        WHERE profile_id = ?
        ORDER BY id DESC
        LIMIT ?
        """,
        (profile_id, limit),
    ).fetchall()
    return [dict(row) for row in rows]
