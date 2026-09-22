#!/usr/bin/env python3
"""Dispatch release.yml after a GITHUB_TOKEN squash merge.

Pushes made with the default token do not start on: push workflows.
workflow_dispatch is the exception, so this waits until the PR is on main
and then starts the release workflow.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time

BOT_MERGERS = {"app/github-actions", "github-actions[bot]"}
WAIT_SECONDS = 20 * 60
POLL_SECONDS = 5


def should_dispatch(merged_by: str, message: str) -> bool:
    if "[skip release]" in message:
        return False
    return merged_by in BOT_MERGERS


def _gh(args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    print("+", " ".join(args), flush=True)
    result = subprocess.run(args, check=False, text=True, capture_output=True)
    if result.returncode != 0:
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="" if result.stderr.endswith("\n") else "\n")
        if check:
            result.check_returncode()
    return result


def _gh_json(args: list[str]):
    result = _gh(args)
    if not result.stdout.strip():
        return None
    return json.loads(result.stdout)


def _matching_prs(repo: str, sha: str) -> list[dict]:
    pulls = _gh_json(["api", f"repos/{repo}/commits/{sha}/pulls"]) or []
    matched = []
    for pr in pulls:
        head_repo = ((pr.get("head") or {}).get("repo") or {}).get("full_name")
        if head_repo == repo and not pr.get("draft"):
            matched.append(pr)
    return matched


def _view(repo: str, number: int) -> dict:
    return _gh_json(
        [
            "pr",
            "view",
            str(number),
            "--repo",
            repo,
            "--json",
            "state,isDraft,mergedBy,mergeCommit,mergeStateStatus,title",
        ]
    )


def _merge_message(repo: str, view: dict) -> str:
    merge = view.get("mergeCommit") or {}
    oid = merge.get("oid") or ""
    if not oid:
        return view.get("title") or ""
    commit = _gh_json(["api", f"repos/{repo}/commits/{oid}"])
    return (commit.get("commit") or {}).get("message") or ""


def _release_already_started(repo: str, sha: str) -> bool:
    runs = _gh_json(
        [
            "run",
            "list",
            "--repo",
            repo,
            "--workflow",
            "release.yml",
            "--commit",
            sha,
            "--limit",
            "10",
            "--json",
            "status,conclusion",
        ]
    ) or []
    for run in runs:
        if run.get("status") in {"queued", "in_progress", "pending", "waiting", "requested"}:
            return True
        if run.get("conclusion") == "success":
            return True
    return False


def _finish_merged(repo: str, view: dict) -> None:
    login = ((view.get("mergedBy") or {}).get("login")) or ""
    message = _merge_message(repo, view)
    oid = ((view.get("mergeCommit") or {}).get("oid")) or ""
    if not should_dispatch(login, message):
        print(f"not dispatching (merged by {login or 'unknown'})")
        return
    if oid and _release_already_started(repo, oid):
        print(f"release already started for {oid}")
        return
    _gh(["workflow", "run", "release.yml", "--repo", repo, "--ref", "main"])
    print("dispatched release.yml")


def _release_pr(repo: str, number: int) -> None:
    deadline = time.time() + WAIT_SECONDS
    auto_enabled = False
    updated = False
    while True:
        view = _view(repo, number)
        if view.get("isDraft"):
            print(f"PR #{number} is a draft")
            return
        state = view.get("state")
        if state == "MERGED":
            _finish_merged(repo, view)
            return
        if state != "OPEN":
            print(f"PR #{number} is {state}")
            return
        status = view.get("mergeStateStatus")
        if status == "DIRTY":
            print(f"PR #{number} has conflicts")
            return
        if status == "CLEAN":
            merged = _gh(
                ["pr", "merge", str(number), "--repo", repo, "--squash", "--delete-branch"],
                check=False,
            )
            if merged.returncode == 0:
                if time.time() >= deadline:
                    print(f"::warning::timed out waiting for PR #{number} to merge")
                    return
                time.sleep(2)
                continue
        elif status == "BEHIND":
            if not updated:
                _gh(
                    ["api", "--method", "PUT", f"repos/{repo}/pulls/{number}/update-branch"],
                    check=False,
                )
                updated = True
        else:
            updated = False
        if not auto_enabled:
            _gh(
                [
                    "pr",
                    "merge",
                    str(number),
                    "--repo",
                    repo,
                    "--squash",
                    "--auto",
                    "--delete-branch",
                ],
                check=False,
            )
            auto_enabled = True
        if time.time() >= deadline:
            print(f"::warning::timed out waiting for PR #{number} to merge")
            return
        time.sleep(POLL_SECONDS)


def main() -> None:
    repo = os.environ["REPO"]
    sha = os.environ["HEAD_SHA"]
    if not sha:
        sys.exit("HEAD_SHA is empty")
    prs = _matching_prs(repo, sha)
    if not prs:
        print(f"no same-repo PR for {sha}")
        return
    for pr in prs:
        _release_pr(repo, int(pr["number"]))


if __name__ == "__main__":
    main()
