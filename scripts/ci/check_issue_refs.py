#!/usr/bin/env python3
"""Resolve the issue and PR numbers a diff adds, so a made-up one is visible.

`#1006` was cited in 20 places across 13 files as the tracking number for
retiring the GitHub Pages site. It was an unrelated open PR: the number was
invented in the first commit and copied outward, and nothing in CI resolves a
citation, so it survived three green runs and two merges (#1014).

A citation in code is a reference to history, so a newly added `#N` should
resolve and already be closed or merged. Existence alone is not enough: #1006
existed. This script scopes itself to the diff's added lines (2,000-odd
citations already sit in the tree), resolves each number through the GitHub
API and prints one line per citation with its state and title:

    #1006 -> [OPEN] ci(sdk): make CI the only publisher, ... (pull request)
        .github/workflows/ci.yml:44, apps/fountain/lib/fountain/docs.ex:12

Next to a docs comment about MkDocs, that title is wrong at a glance.

Stage 1 (now) comments and does not gate: `--comment` upserts one PR comment
and the exit code is 0 whatever it found. Stage 2 promotes the rule with
`--strict`, which exits 1 on a citation that is open or does not exist. Usage
and API failures exit 2 in either mode.

The regex is the hard part. `#111827` is a hex colour, `&#106;` is a numeric
character reference, and `106` is a plausible issue number. A number counts
only when it is not preceded by `&`, `#` or a word character, has no leading zero,
is not followed by `;` (the CSS `color: #666;` shape) and does not exceed the
repository's highest issue-or-PR number, which drops every six-digit colour.
Stylesheets are skipped outright.

Run from anywhere:

    python3 scripts/ci/check_issue_refs.py --base origin/main
    gh pr diff 1008 | python3 scripts/ci/check_issue_refs.py --diff -

Tested by scripts/ci/test_issue_refs.py, which CI's `workflow-checks` job runs.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

API = "https://api.github.com"
DEFAULT_REPO = "managoat/fountain"
MARKER = "<!-- check-issue-refs -->"
SKIPPED_SUFFIXES = {".css", ".scss"}

# `#N` at a word boundary: not `&#106;` (an entity), not `x#12` (a word),
# not `##3` (a heading), not `#0123` (numbers do not start with zero) and
# not `#666;` (a colour).
CITATION = re.compile(r"(?<![&\w#])#(?!0)(\d+)\b(?!;)")
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def citations(diff, repo=DEFAULT_REPO):
    """Yield (path, line, number) for every `#N` on an added line of a diff.

    `line` is the line number in the new file. Links into this repository
    (`github.com/<repo>/issues/N`, `/pull/N`) count too.
    """
    url = re.compile(r"github\.com/" + re.escape(repo) + r"/(?:issues|pull)/(\d+)\b")
    path = None
    line = None
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            name = raw[4:].split("\t")[0]
            path = None if name == "/dev/null" else re.sub(r"^b/", "", name)
            line = None
            continue
        if raw.startswith("--- ") or raw.startswith("\\"):
            continue
        hunk = HUNK.match(raw)
        if hunk:
            line = int(hunk[1])
            continue
        if path is None or line is None:
            continue
        if raw.startswith("-"):
            continue
        if raw.startswith("+") and Path(path).suffix not in SKIPPED_SUFFIXES:
            text = raw[1:]
            for match in CITATION.finditer(text):
                yield path, line, int(match[1])
            for match in url.finditer(text):
                yield path, line, int(match[1])
        line += 1


def collect(diff, cap, repo=DEFAULT_REPO):
    """Group plausible citations by number: {number: ["path:line", ...]}."""
    found = {}
    for path, line, number in citations(diff, repo):
        if number > cap:
            continue
        where = f"{path}:{line}"
        places = found.setdefault(number, [])
        if where not in places:
            places.append(where)
    return dict(sorted(found.items()))


def token():
    return os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")


def api(method, path, body=None):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "Fountain-issue-ref-check",
    }
    if token():
        headers["Authorization"] = f"Bearer {token()}"
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    request = Request(f"{API}{path}", data=data, headers=headers, method=method)
    with urlopen(request, timeout=20) as response:
        return json.load(response)


def highest_number(repo):
    """The newest issue-or-PR number; both share one sequence."""
    latest = api("GET", f"/repos/{repo}/issues?state=all&sort=created&direction=desc&per_page=1")
    if not latest:
        raise ValueError(f"{repo} has no issues or pull requests")
    return latest[0]["number"]


def resolve(repo, number):
    """What `#number` is: {"state": OPEN|CLOSED|MERGED|MISSING, "title", "kind"}."""
    try:
        item = api("GET", f"/repos/{repo}/issues/{number}")
    except HTTPError as error:
        if error.code in (404, 410):
            return {"state": "MISSING", "title": "", "kind": ""}
        raise
    pull = item.get("pull_request") or {}
    if pull.get("merged_at"):
        state = "MERGED"
    else:
        state = item["state"].upper()
    return {"state": state, "title": item["title"], "kind": "pull request" if pull else "issue"}


def passes(state):
    """The rule with teeth: a citation names history, so it is already closed."""
    return state in {"CLOSED", "MERGED"}


def render(found, resolved):
    """The report as markdown; `found` and `resolved` are keyed by number."""
    if not found:
        return f"{MARKER}\nThis PR adds no new issue or PR citations.\n"
    lines = [MARKER, "### Issue and PR citations added by this PR", ""]
    for number, places in found.items():
        item = resolved[number]
        state = item["state"]
        mark = "" if passes(state) else " :warning:"
        title = f" {item['title']}" if item["title"] else ""
        kind = f" ({item['kind']})" if item["kind"] else ""
        lines.append(f"- #{number} → **{state}**{title}{kind}{mark}")
        shown = ", ".join(f"`{place}`" for place in places[:3])
        more = f", +{len(places) - 3} more" if len(places) > 3 else ""
        lines.append(f"  - {shown}{more}")
    lines += [
        "",
        "A citation in code names history, so a newly added number should already "
        "be closed or merged; a title that does not match the sentence around it "
        "is a made-up number (#1014). This report is advisory.",
    ]
    return "\n".join(lines) + "\n"


def upsert_comment(repo, pr, body):
    """One comment per PR, found by its marker, updated on every run."""
    for comment in api("GET", f"/repos/{repo}/issues/{pr}/comments?per_page=100"):
        if comment["body"].startswith(MARKER):
            api("PATCH", f"/repos/{repo}/issues/comments/{comment['id']}", {"body": body})
            return "updated"
    api("POST", f"/repos/{repo}/issues/{pr}/comments", {"body": body})
    return "created"


def read_diff(args):
    if args.diff is not None:
        return sys.stdin.read() if args.diff == "-" else Path(args.diff).read_text()
    if args.base is None:
        raise SystemExit("usage: give --base <commit> or --diff <file>")
    result = subprocess.run(
        ["git", "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
         "--unified=0", args.base, args.head],
        check=True, capture_output=True, text=True, errors="replace",
    )
    return result.stdout


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", help="diff this commit against --head")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--diff", help="read a unified diff from this file, or - for stdin")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY") or DEFAULT_REPO)
    parser.add_argument("--max", type=int, help="highest plausible number (default: ask the API)")
    parser.add_argument("--pr", type=int, help="the pull request to comment on")
    parser.add_argument("--comment", action="store_true", help="upsert the report as a PR comment")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 when a citation is open or missing")
    args = parser.parse_args(argv)

    try:
        diff = read_diff(args)
        cap = args.max if args.max is not None else highest_number(args.repo)
        found = collect(diff, cap, args.repo)
        with ThreadPoolExecutor(max_workers=4) as pool:
            resolved = dict(zip(found, pool.map(lambda n: resolve(args.repo, n), found)))
    except (OSError, subprocess.CalledProcessError, HTTPError, URLError, ValueError, KeyError) as error:
        print(f"::error::check_issue_refs could not resolve citations: {error}", file=sys.stderr)
        return 2

    for number, item in resolved.items():
        title = f" {item['title']}" if item["title"] else ""
        print(f"#{number} -> [{item['state']}]{title}")
        print("    " + ", ".join(found[number]))
    failing = sorted(n for n, item in resolved.items() if not passes(item["state"]))
    print(f"Checked {len(found)} new citations (numbers up to #{cap}); "
          f"{len(failing)} open or missing")

    body = render(found, resolved)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(body)
    if args.comment:
        if args.pr is None:
            print("::error::--comment needs --pr", file=sys.stderr)
            return 2
        try:
            # A PR with nothing to report gets no comment unless one is
            # already there to correct.
            if found or any(c["body"].startswith(MARKER)
                            for c in api("GET", f"/repos/{args.repo}/issues/{args.pr}/comments?per_page=100")):
                print(f"Comment {upsert_comment(args.repo, args.pr, body)} on #{args.pr}")
        except (HTTPError, URLError) as error:
            # A fork's token is read-only; the step summary still carries it.
            print(f"::warning::could not comment on #{args.pr}: {error}", file=sys.stderr)

    if args.strict and failing:
        for number in failing:
            print(f"::error::#{number} is {resolved[number]['state']}: "
                  "a citation should name a closed issue or merged PR", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
