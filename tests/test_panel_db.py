#!/usr/bin/env python3
"""Unittests for panel.db (SQLite profiles and probes)."""

from __future__ import annotations

import sqlite3
import tempfile
import time
import unittest
from pathlib import Path

from panel import db


class PanelDbTests(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.path = str(Path(self._tmpdir.name) / "panel.db")
        self.conn = db.connect(self.path)
        self.addCleanup(self.conn.close)
        db.init_db(self.conn)

    def test_init_db_is_idempotent(self):
        db.init_db(self.conn)
        db.init_db(self.conn)
        tables = {
            row["name"]
            for row in self.conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
        self.assertIn("profiles", tables)
        self.assertIn("probes", tables)

    def test_create_profile_returns_ports_and_note(self):
        profile = db.create_profile(
            self.conn, "college", 1090, 8128, "черновик"
        )
        self.assertEqual(profile["name"], "college")
        self.assertEqual(profile["socks_port"], 1090)
        self.assertEqual(profile["http_port"], 8128)
        self.assertEqual(profile["note"], "черновик")
        self.assertIn("id", profile)
        self.assertIn("created_at", profile)
        self.assertIn("updated_at", profile)
        self.assertEqual(profile["created_at"], profile["updated_at"])
        self.assertTrue(profile["created_at"].endswith("Z"))

    def test_duplicate_name_raises_integrity_error(self):
        db.create_profile(self.conn, "college", 1090, 8128, "")
        with self.assertRaises(sqlite3.IntegrityError):
            db.create_profile(self.conn, "college", 1091, 8129, "again")

    def test_update_profile_changes_only_note_and_updated_at(self):
        profile = db.create_profile(self.conn, "college", 1090, 8128, "old")
        time.sleep(1.1)
        updated = db.update_profile(self.conn, profile["id"], {"note": "new"})
        self.assertIsNotNone(updated)
        self.assertEqual(updated["note"], "new")
        self.assertEqual(updated["name"], profile["name"])
        self.assertEqual(updated["socks_port"], profile["socks_port"])
        self.assertEqual(updated["http_port"], profile["http_port"])
        self.assertEqual(updated["created_at"], profile["created_at"])
        self.assertNotEqual(updated["updated_at"], profile["updated_at"])

    def test_update_unknown_profile_returns_none(self):
        self.assertIsNone(db.update_profile(self.conn, 999, {"note": "x"}))

    def test_delete_unknown_profile_returns_false(self):
        self.assertFalse(db.delete_profile(self.conn, 999))

    def test_delete_profile_cascades_probes(self):
        profile = db.create_profile(self.conn, "college", 1090, 8128, "")
        db.add_probe(self.conn, profile["id"], "unknown", "gateway-not-running", "")
        self.assertTrue(db.delete_profile(self.conn, profile["id"]))
        self.assertEqual(db.list_probes(self.conn, profile["id"]), [])

    def test_list_probes_newest_first(self):
        profile = db.create_profile(self.conn, "college", 1090, 8128, "")
        first = db.add_probe(self.conn, profile["id"], "down", "timeout", "a")
        second = db.add_probe(self.conn, profile["id"], "ok", "", "b")
        probes = db.list_probes(self.conn, profile["id"])
        self.assertEqual(len(probes), 2)
        self.assertEqual(probes[0]["id"], second["id"])
        self.assertEqual(probes[1]["id"], first["id"])

    def test_seed_demo_twice_keeps_one_loopback(self):
        db.seed_demo(self.conn)
        db.seed_demo(self.conn)
        profiles = db.list_profiles(self.conn)
        self.assertEqual(len(profiles), 1)
        self.assertEqual(profiles[0]["name"], "loopback")
        self.assertEqual(profiles[0]["socks_port"], 1090)
        self.assertEqual(profiles[0]["http_port"], 8128)
        self.assertEqual(profiles[0]["note"], "Локальный шлюз на этой машине")


if __name__ == "__main__":
    unittest.main()
