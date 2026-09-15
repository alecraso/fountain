#!/usr/bin/env python3
"""Run the tests for the files a branch changed: the test stage of precommit.

    python3 scripts/precommit-tests.py            select and run
    python3 scripts/precommit-tests.py --print    select and list, run nothing

The changed set is the working tree against `git merge-base origin/main
HEAD` (committed, staged and unstaged edits) plus untracked files. Each
path selects tests by shape, repo-relative:

  a *_test.exs under apps/<app>/test or ee/test   itself
  apps/<app>/lib/<rest>.ex (.eex, .heex)         apps/<app>/test/<rest>_test.exs, and every
                                                 <stem>_test.exs or <stem>_*_test.exs under
                                                 that app's test tree
  ee/lib/<rest>.ex                               the same under ee/test and apps/fountain/test
  docs/, README.md, CHANGELOG.md, apps/*/docs/   the manual's tests, as scripts/test-docs.sh runs them

Some files are inputs to every test, and a change to one of them runs the
whole suite from the umbrella root instead: mix.exs and mix.lock, config/,
coverage.exs, a test/support tree, a test_helper.exs, a migration. That is
what `mix precommit --full` does by hand.

A lib file that matches no test file is named in the output so the gap is
visible; nothing is selected for it. Paths that are not Elixir (scripts,
workflows, contributor Markdown) select nothing and are listed once. When
the selection is empty the stage passes with that fact on its last line;
CI runs the whole suite on every plan either way.

`mix test` drops a path that matches nothing without failing when at least
one other path matches, so every selected path is checked to exist before
mix sees it (scripts/test-partition.sh learnt this the hard way).

PRECOMMIT_CHANGED_FILES names a file with one repo-relative path per line
and replaces the git query; scripts/ci/test_precommit.py uses it.
"""

import fnmatch
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

# Any of these changed means the whole suite: they are read by every test.
FULL_SUITE_PATTERNS = [
    "mix.exs",
    "mix.lock",
    "coverage.exs",
    "config/*",
    "apps/*/mix.exs",
    "apps/*/test/support/*",
    "apps/*/test/test_helper.exs",
    "*/priv/repo/migrations/*",
    "*/priv/migrations/*",
]

DOCS_PATTERNS = ["docs/*", "README.md", "CHANGELOG.md", "apps/*/docs/*"]

# Mirrors scripts/test-docs.sh; a file that does not exist is dropped.
DOCS_TESTS = [
    "apps/fountain/test/fountain/docs_test.exs",
    "apps/fountain/test/fountain_web/controllers/docs_controller_test.exs",
] + [
    f"apps/{app}/test/{app}/{name}_test.exs"
    for app in ("fountain_buzz", "fountain_google", "fountain_microsoft", "fountain_slack")
    for name in ("docs", "manual")
]

SOURCE_SUFFIXES = (".ex", ".eex", ".heex")


def matches_any(path, patterns):
    # fnmatch's `*` crosses `/`, which is what these patterns want.
    return any(fnmatch.fnmatchcase(path, p) for p in patterns)


class RepoTree:
    """The filesystem questions selection asks, so tests can fake them."""

    def __init__(self, root):
        self.root = pathlib.Path(root)

    def exists(self, path):
        return (self.root / path).is_file()

    def glob(self, base, pattern):
        return sorted(
            p.relative_to(self.root).as_posix() for p in (self.root / base).glob(pattern)
        )


class Selection:
    def __init__(self):
        self.full_reason = None
        self.tests = []  # ordered, unique
        self.unmatched = []  # lib files with no test file
        self.ignored = []  # paths that select nothing by design

    def add(self, path):
        if path not in self.tests:
            self.tests.append(path)


def stem_globs(tree, test_base, stem):
    found = []
    for pattern in (f"**/{stem}_test.exs", f"**/{stem}_*_test.exs"):
        found.extend(tree.glob(test_base, pattern))
    return found


def select(changed, tree):
    sel = Selection()
    docs_touched = False
    for path in changed:
        if matches_any(path, FULL_SUITE_PATTERNS):
            sel.full_reason = sel.full_reason or path
            continue
        if path.endswith("_test.exs") and (
            path.startswith("ee/test/") or fnmatch.fnmatchcase(path, "apps/*/test/*")
        ):
            if tree.exists(path):
                sel.add(path)
            continue
        if matches_any(path, DOCS_PATTERNS):
            docs_touched = True
            continue
        if path.endswith(SOURCE_SUFFIXES) and (
            path.startswith("ee/lib/") or fnmatch.fnmatchcase(path, "apps/*/lib/*")
        ):
            found = tests_for_source(path, tree)
            if found:
                for t in found:
                    sel.add(t)
            else:
                sel.unmatched.append(path)
            continue
        sel.ignored.append(path)
    if docs_touched:
        for t in DOCS_TESTS:
            if tree.exists(t):
                sel.add(t)
    return sel


def tests_for_source(path, tree):
    parts = path.split("/")
    stem = pathlib.PurePosixPath(parts[-1])
    while stem.suffix:
        stem = stem.with_suffix("")
    stem = stem.name
    if path.startswith("ee/lib/"):
        rest = "/".join(parts[2:-1])
        mirror = f"ee/test/{rest}/{stem}_test.exs" if rest else f"ee/test/{stem}_test.exs"
        bases = ["ee/test", "apps/fountain/test"]
    else:
        app = parts[1]
        rest = "/".join(parts[3:-1])
        mirror = f"apps/{app}/test/{rest}/{stem}_test.exs" if rest else f"apps/{app}/test/{stem}_test.exs"
        bases = [f"apps/{app}/test"]
    found = [mirror] if tree.exists(mirror) else []
    for base in bases:
        for t in stem_globs(tree, base, stem):
            if t not in found:
                found.append(t)
    return found


def changed_files():
    listing = os.environ.get("PRECOMMIT_CHANGED_FILES")
    if listing:
        lines = pathlib.Path(listing).read_text().splitlines()
        return [line.strip() for line in lines if line.strip()], "PRECOMMIT_CHANGED_FILES"
    base = None
    for ref in ("origin/main", "main"):
        result = subprocess.run(
            ["git", "merge-base", ref, "HEAD"], cwd=ROOT, capture_output=True, text=True
        )
        if result.returncode == 0:
            base = result.stdout.strip()
            break
    if base is None:
        return None, "no merge base with origin/main or main"
    diff = subprocess.run(
        ["git", "diff", "--name-only", base], cwd=ROOT, capture_output=True, text=True, check=True
    )
    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    )
    paths = []
    for line in diff.stdout.splitlines() + untracked.stdout.splitlines():
        if line and line not in paths:
            paths.append(line)
    return paths, f"working tree against {base[:12]}"


def invocations(tests):
    """Group selected files into one `mix test` per app directory.

    apps/fountain owns ee/test through its test_paths, reached as
    ../../ee/test from that directory; from the umbrella root those paths
    match nothing.
    """
    groups = {}
    for t in tests:
        if t.startswith("ee/test/"):
            groups.setdefault("apps/fountain", []).append("../../" + t)
        else:
            app = "/".join(t.split("/")[:2])
            groups.setdefault(app, []).append(t[len(app) + 1:])
    return groups


def run_mix(args, cwd):
    env = dict(os.environ, MIX_ENV="test")
    return subprocess.call(["mix", *args], cwd=ROOT / cwd, env=env)


def main(argv):
    print_only = "--print" in argv
    changed, source = changed_files()
    if changed is None:
        print(f"precommit-tests: {source}; running the whole suite")
        return 0 if print_only else run_mix(["test"], ".")

    sel = select(changed, RepoTree(ROOT))
    print(f"precommit-tests: {len(changed)} changed path(s), {source}")
    if sel.full_reason:
        print(f"precommit-tests: {sel.full_reason} is an input to every test; running the whole suite")
        return 0 if print_only else run_mix(["test"], ".")

    for path in sel.unmatched:
        print(f"precommit-tests: no test file matches {path}; name one, or run --full")
    if sel.ignored:
        print(f"precommit-tests: no Elixir tests select for: {' '.join(sel.ignored)}")

    missing = [t for t in sel.tests if not (ROOT / t).is_file()]
    if missing:
        print(f"precommit-tests: selected paths do not exist: {' '.join(missing)}", file=sys.stderr)
        return 1

    if not sel.tests:
        print("precommit-tests: 0 test files selected for the changed paths (CI runs the whole suite)")
        return 0

    groups = invocations(sel.tests)
    for cwd, files in groups.items():
        print(f"precommit-tests: {cwd}: mix test {' '.join(files)}")
    if print_only:
        return 0
    for cwd, files in groups.items():
        status = run_mix(["test", *files], cwd)
        if status != 0:
            return status
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
