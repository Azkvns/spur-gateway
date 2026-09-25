import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".github" / "scripts"))

import dispatch_release  # noqa: E402


class ShouldDispatchTest(unittest.TestCase):
    def test_actions_bot_merge_dispatches(self):
        self.assertTrue(dispatch_release.should_dispatch("app/github-actions", "fix: pages"))

    def test_actions_bot_login_dispatches(self):
        self.assertTrue(
            dispatch_release.should_dispatch("github-actions[bot]", "chore: bump action")
        )

    def test_human_merge_stays_on_push(self):
        self.assertFalse(dispatch_release.should_dispatch("Azkvns", "docs: readme"))

    def test_skip_marker_in_subject(self):
        self.assertFalse(
            dispatch_release.should_dispatch("app/github-actions", "docs: wip [skip release]")
        )

    def test_skip_marker_in_body(self):
        message = "chore: deps\n\n[skip release]\n"
        self.assertFalse(dispatch_release.should_dispatch("app/github-actions", message))


class GhCommandTest(unittest.TestCase):
    def test_invokes_gh_cli(self):
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        with patch("dispatch_release.subprocess.run", return_value=completed) as run:
            dispatch_release._gh(["api", "repos/o/r/commits/abc/pulls"])
        argv = run.call_args.args[0]
        self.assertEqual(argv, ["gh", "api", "repos/o/r/commits/abc/pulls"])


if __name__ == "__main__":
    unittest.main()
