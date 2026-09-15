#!/usr/bin/env python3
"""Refuse a PR whose commits are missing a Developer Certificate of Origin sign-off.

CONTRIBUTING.md's "Sign your commits (DCO)" step asks for `git commit -s`
on every commit, but nothing enforced it: a PR with no `Signed-off-by:`
trailer passed every gate, and the miss surfaced only when a reviewer read
the raw commit messages, each costing a force-push cycle (#2287, #2288,
#2290).

Two decisions, settled on #2290:

- **Trailer presence, not author match.** A commit fails only for lacking
  a `Signed-off-by:` line; the trailer's identity need not equal the
  commit author. Contributors commit from worktrees and automation where
  `user.email` differs from the sign-off identity, and the sign-off is a
  statement of agreement to the inbound terms, not an authorship claim.
- **Merge commits are skipped.** A merge from `main` into a long-lived
  branch is not itself a contribution, so this walks
  `git rev-list --no-merges base..head`.

Run from the repository root:

    python3 scripts/ci/dco.py --base <base-sha> --head <head-sha>

`--base` and `--head` fall back to the `PR_BASE_SHA` and `HEAD` environment
variables, so `workflow-checks` in `.github/workflows/ci.yml` passes them
explicitly and nothing else needs to. Tested by scripts/ci/test_dco.py,
which CI's `workflow-checks` job runs.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

TRAILER_RE = re.compile(r"^Signed-off-by: .+", re.MULTILINE)


def commits(root: str, base: str, head: str) -> list[str]:
    result = subprocess.run(
        ["git", "rev-list", "--no-merges", f"{base}..{head}"],
        cwd=root, capture_output=True, text=True, check=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def message(root: str, sha: str) -> str:
    result = subprocess.run(
        ["git", "log", "-1", "--format=%B", sha],
        cwd=root, capture_output=True, text=True, check=True,
    )
    return result.stdout


def subject(root: str, sha: str) -> str:
    result = subprocess.run(
        ["git", "log", "-1", "--format=%s", sha],
        cwd=root, capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def unsigned_commits(root: str, base: str, head: str) -> tuple[list[str], list[str]]:
    """Return (every non-merge commit, the ones missing a sign-off trailer)."""
    shas = commits(root, base, head)
    missing = [sha for sha in shas if not TRAILER_RE.search(message(root, sha))]
    return shas, missing


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default=".", help="repository root (default: cwd)")
    parser.add_argument("--base", default=os.environ.get("PR_BASE_SHA"),
                         help="the PR's base commit (default: $PR_BASE_SHA)")
    parser.add_argument("--head", default=os.environ.get("HEAD", "HEAD"),
                         help="the PR's head commit (default: $HEAD, else HEAD)")
    args = parser.parse_args(argv)

    if not args.base:
        parser.error("--base is required (or set PR_BASE_SHA)")

    shas, missing = unsigned_commits(args.root, args.base, args.head)
    if missing:
        print(
            "commit(s) missing a Signed-off-by: trailer "
            "(git commit --amend -s, or git rebase --signoff):",
            file=sys.stderr,
        )
        for sha in missing:
            print(f"  {sha[:7]} {subject(args.root, sha)}", file=sys.stderr)
        return 1

    count = len(shas)
    print(f"{count} commit{'' if count == 1 else 's'} judged, all signed off")
    return 0


if __name__ == "__main__":
    sys.exit(main())
