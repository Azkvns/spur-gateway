#!/usr/bin/env python3
"""Unittests for panel.status (gateway health file parsing)."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from panel import status


class PanelStatusTests(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.health_path = str(Path(self._tmpdir.name) / "health")

    def _write_health(self, *lines: str) -> None:
        Path(self.health_path).write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_none_path_is_absent(self):
        result = status.read_health(None)
        self.assertEqual(result["source"], "absent")
        self.assertEqual(result["state"], "unknown")
        self.assertEqual(result["reason"], "gateway-not-running")
        self.assertEqual(result["server"], "")
        self.assertEqual(result["updated"], "")

    def test_missing_file_is_absent(self):
        result = status.read_health(self.health_path)
        self.assertEqual(result["source"], "absent")
        self.assertEqual(result["state"], "unknown")
        self.assertEqual(result["reason"], "gateway-not-running")
        self.assertEqual(result["server"], "")
        self.assertEqual(result["updated"], "")

    def test_ok_file_is_parsed(self):
        self._write_health(
            "state=ok",
            "reason=",
            "server=nl",
            "updated=2026-09-22T00:00:00Z",
        )
        result = status.read_health(self.health_path)
        self.assertEqual(result["source"], "file")
        self.assertEqual(result["state"], "ok")
        self.assertEqual(result["reason"], "")
        self.assertEqual(result["server"], "nl")
        self.assertEqual(result["updated"], "2026-09-22T00:00:00Z")

    def test_down_state_is_preserved(self):
        self._write_health(
            "state=down",
            "reason=probe-failed",
            "server=de",
            "updated=2026-09-22T01:00:00Z",
        )
        result = status.read_health(self.health_path)
        self.assertEqual(result["source"], "file")
        self.assertEqual(result["state"], "down")
        self.assertEqual(result["reason"], "probe-failed")
        self.assertEqual(result["server"], "de")
        self.assertEqual(result["updated"], "2026-09-22T01:00:00Z")

    def test_weird_state_is_unreadable(self):
        self._write_health(
            "state=weird",
            "reason=anything",
            "server=nl",
            "updated=2026-09-22T00:00:00Z",
        )
        result = status.read_health(self.health_path)
        self.assertEqual(result["source"], "file")
        self.assertEqual(result["state"], "unknown")
        self.assertEqual(result["reason"], "unreadable")
        self.assertEqual(result["server"], "nl")
        self.assertEqual(result["updated"], "2026-09-22T00:00:00Z")


if __name__ == "__main__":
    unittest.main()
