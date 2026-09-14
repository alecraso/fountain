#!/usr/bin/env python3
"""The changelog fragments: check them, roll them into CHANGELOG.md at release.

Every PR used to add its bullet at the top of the same subsection under
`## [Unreleased]`, and with ~26 merges a day, two PRs inserting at the same
line was the single most common merge conflict on main. The merge queue
made it worse, since nothing is rebased before the queue builds the merge.
Now a PR adds a file of its own under `changelog.d/` and CHANGELOG.md changes
once per release, in the release PR. Two file adds never conflict.

A fragment is a markdown file that uses the changelog's own section
headings, so there is no second format to learn:

    ### Fixed

    - The reaper no longer suspends a sandbox mid-turn (#1234).

Subcommands:

  check      every fragment parses and names only known sections
  guard      a PR does not edit CHANGELOG.md (a fragment goes in instead)
  normalize  fold a section's repeated `### X` headings into one, in place
             (what hand-resolved conflicts left behind)
  release    roll `[Unreleased]` and the fragments into `## [X.Y.Z] - date`,
             delete the fragments, leave an empty `[Unreleased]` stub
  preview    print what `release` would write, without writing

Run from the repository root. Tested by scripts/ci/test_changelog.py, which
CI's `workflow-checks` job runs.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import re
import subprocess
import sys
from pathlib import Path

FRAGMENT_DIR = "changelog.d"
CHANGELOG = "CHANGELOG.md"

# The order a release section lists its subsections in: Keep a Changelog's,
# with the repo's own "Upgrade notes" first because it is what an operator
# reads before taking a minor.
SECTIONS = (
    "Upgrade notes",
    "Added",
    "Changed",
    "Deprecated",
    "Removed",
    "Fixed",
    "Security",
)

UNRELEASED_HEADING = "## [Unreleased]"

# What sits under `## [Unreleased]` between releases. It is a stub, not a
# place to write: the guard refuses a PR that edits CHANGELOG.md.
UNRELEASED_STUB = (
    "Changes that have merged but not yet shipped are the files under\n"
    "[`changelog.d/`](https://github.com/managoat/fountain/tree/main/changelog.d);\n"
    "the release PR rolls them into a dated section here.\n"
)

_SECTION_RE = re.compile(r"^### (.+?)\s*$")
_RELEASE_RE = re.compile(r"^## \[")


class ChangelogError(Exception):
    pass


# ---------------------------------------------------------------------------
# Parsing


def parse_sections(text: str, *, where: str) -> dict[str, list[str]]:
    """Split a body of `### Section` blocks into {section: [lines]}.

    Repeated headings merge in order of appearance. Text before the first
    heading is an error: a fragment has to say which section it belongs to,
    and a release body that starts with prose was hand-edited into a shape
    the release roll cannot place.
    """
    sections: dict[str, list[str]] = {}
    current: str | None = None
    for number, line in enumerate(text.splitlines(), start=1):
        match = _SECTION_RE.match(line)
        if match:
            current = match.group(1)
            if current not in SECTIONS:
                raise ChangelogError(
                    f"{where}:{number}: unknown section {current!r}; "
                    f"one of: {', '.join(SECTIONS)}"
                )
            sections.setdefault(current, [])
            continue
        if line.startswith("## "):
            raise ChangelogError(
                f"{where}:{number}: a fragment carries `### Section` headings "
                "only; the release heading is written by the release roll"
            )
        if current is None:
            if line.strip() == "":
                continue
            raise ChangelogError(
                f"{where}:{number}: text before the first `### Section` heading"
            )
        sections[current].append(line)
    return {name: _trim(lines) for name, lines in sections.items()}


def _trim(lines: list[str]) -> list[str]:
    """Strip blank lines at both ends and squeeze runs of them inside.

    A repeated heading leaves the blank line that preceded it in the
    section it interrupted, then the blank after it; folded together they
    would be two.
    """
    out: list[str] = []
    for line in lines:
        if line.strip() == "" and (not out or out[-1].strip() == ""):
            continue
        out.append(line)
    while out and out[-1].strip() == "":
        out.pop()
    return out


def _has_bullet(lines: list[str]) -> bool:
    return any(line.startswith("- ") for line in lines)


def render_sections(sections: dict[str, list[str]]) -> str:
    """Emit the sections in canonical order, skipping empty ones."""
    out: list[str] = []
    for name in SECTIONS:
        lines = sections.get(name)
        if not lines:
            continue
        out.append(f"### {name}")
        out.append("")
        out.extend(lines)
        out.append("")
    return "\n".join(out)


def merge_sections(*many: dict[str, list[str]]) -> dict[str, list[str]]:
    merged: dict[str, list[str]] = {}
    for sections in many:
        for name, lines in sections.items():
            if not lines:
                merged.setdefault(name, [])
                continue
            existing = merged.get(name)
            merged[name] = lines if not existing else existing + [""] + lines
    return merged


# ---------------------------------------------------------------------------
# Fragments


def fragment_paths(root: Path) -> list[Path]:
    directory = root / FRAGMENT_DIR
    if not directory.is_dir():
        return []
    return sorted(
        p for p in directory.iterdir()
        if p.suffix == ".md" and p.name != "README.md" and not p.name.startswith(".")
    )


def read_fragments(root: Path) -> dict[str, list[str]]:
    """Parse every fragment; the first unreadable one is the error."""
    merged: dict[str, list[str]] = {}
    for path in fragment_paths(root):
        text = path.read_text(encoding="utf-8")
        where = f"{FRAGMENT_DIR}/{path.name}"
        sections = parse_sections(text, where=where)
        if not sections:
            raise ChangelogError(f"{where}: no `### Section` heading")
        for name, lines in sections.items():
            if not _has_bullet(lines):
                raise ChangelogError(
                    f"{where}: `### {name}` has no `- ` bullet"
                )
        merged = merge_sections(merged, sections)
    return merged


# ---------------------------------------------------------------------------
# CHANGELOG.md


def split_changelog(text: str) -> tuple[str, str, str]:
    """(preamble, unreleased body, the rest starting at the first release).

    The preamble ends with the `## [Unreleased]` heading line.
    """
    lines = text.splitlines(keepends=True)
    try:
        start = next(
            i for i, line in enumerate(lines)
            if line.rstrip("\n") == UNRELEASED_HEADING
        )
    except StopIteration:
        raise ChangelogError(f"{CHANGELOG}: no `{UNRELEASED_HEADING}` heading") from None
    end = next(
        (i for i in range(start + 1, len(lines)) if _RELEASE_RE.match(lines[i])),
        len(lines),
    )
    return "".join(lines[: start + 1]), "".join(lines[start + 1 : end]), "".join(lines[end:])


def unreleased_sections(body: str) -> dict[str, list[str]]:
    """The `[Unreleased]` body as sections; the stub paragraph counts as empty."""
    if body.strip() == UNRELEASED_STUB.strip() or body.strip() == "":
        return {}
    return parse_sections(body, where=f"{CHANGELOG} [Unreleased]")


def normalize_text(text: str) -> str:
    """Fold repeated headings under `[Unreleased]` and put sections in order."""
    preamble, body, rest = split_changelog(text)
    sections = unreleased_sections(body)
    rendered = render_sections(sections) if sections else UNRELEASED_STUB
    return preamble + "\n" + rendered + "\n" + rest


def release_text(
    text: str,
    fragments: dict[str, list[str]],
    *,
    version: str,
    date: str,
    require_upgrade_notes: bool,
) -> str:
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ChangelogError(f"not a SemVer version: {version!r}")
    if f"## [{version}]" in text:
        raise ChangelogError(f"{CHANGELOG} already has a `## [{version}]` section")
    preamble, body, rest = split_changelog(text)
    sections = merge_sections(unreleased_sections(body), fragments)
    if not any(_has_bullet(lines) for lines in sections.values()):
        raise ChangelogError(
            f"nothing to release: `[Unreleased]` is empty and {FRAGMENT_DIR}/ "
            "has no fragments"
        )
    if require_upgrade_notes and not _has_bullet(sections.get("Upgrade notes", [])):
        # Pre-1.0, a minor may break; the changelog header promises such a
        # release carries an "Upgrade notes" section. A minor with genuinely
        # nothing to note still gets the section, saying so; explicit beats
        # absent (the CREDITS_ENABLED flip nearly shipped without one).
        raise ChangelogError(
            "a minor or major release needs an `### Upgrade notes` entry; "
            "a fragment saying `- None.` is fine when true"
        )
    heading = f"## [{version}] - {date}"
    return (
        preamble
        + "\n"
        + UNRELEASED_STUB
        + "\n"
        + heading
        + "\n\n"
        + render_sections(sections)
        + "\n"
        + rest
    )


# ---------------------------------------------------------------------------
# Commands


def cmd_check(root: Path) -> int:
    fragments = read_fragments(root)
    count = len(fragment_paths(root))
    # The Unreleased body has to parse too, or the release roll will refuse.
    unreleased_sections(split_changelog((root / CHANGELOG).read_text(encoding="utf-8"))[1])
    bullets = sum(1 for lines in fragments.values() for l in lines if l.startswith("- "))
    print(f"{count} fragment(s), {bullets} entr{'y' if bullets == 1 else 'ies'}")
    return 0


def changed_files(root: Path, base: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...HEAD"],
        cwd=root, capture_output=True, text=True, check=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def cmd_guard(root: Path, base: str, branch: str, labels: list[str]) -> int:
    """Refuse a PR that edits CHANGELOG.md; the release branch and an
    explicit label are the two doors.

    The label is for the edit that is legitimately to the file itself: a
    typo in a shipped entry, or a link that moved. The release branch is
    where the roll lands.
    """
    if branch.startswith("release/v"):
        print(f"{branch}: the release branch rolls the changelog; skipping the guard")
        return 0
    if any(label in labels for label in ("release:manual-changelog", "changelog:manual")):
        print("release:manual-changelog label present; skipping the guard")
        return 0
    if CHANGELOG in changed_files(root, base):
        print(
            f"{CHANGELOG} changed on this branch. Every PR writes a fragment under\n"
            f"{FRAGMENT_DIR}/ instead (see {FRAGMENT_DIR}/README.md); the release PR\n"
            f"rolls them into CHANGELOG.md. To edit the file itself, put the\n"
            f"`release:manual-changelog` label on the PR.",
            file=sys.stderr,
        )
        return 1
    print(f"{CHANGELOG} untouched")
    return 0


def cmd_normalize(root: Path) -> int:
    path = root / CHANGELOG
    before = path.read_text(encoding="utf-8")
    after = normalize_text(before)
    if after != before:
        path.write_text(after, encoding="utf-8")
        print(f"{CHANGELOG}: normalized [Unreleased]")
    else:
        print(f"{CHANGELOG}: already normalized")
    return 0


def cmd_release(root: Path, version: str, date: str, require_upgrade_notes: bool, write: bool) -> int:
    path = root / CHANGELOG
    before = path.read_text(encoding="utf-8")
    after = release_text(
        before, read_fragments(root),
        version=version, date=date, require_upgrade_notes=require_upgrade_notes,
    )
    if not write:
        # Print the new release section only: the file is thousands of lines.
        section_start = after.index(f"## [{version}]")
        section_end = after.find("\n## [", section_start + 1)
        print(after[section_start: section_end if section_end != -1 else None].rstrip())
        return 0
    path.write_text(after, encoding="utf-8")
    removed = fragment_paths(root)
    for fragment in removed:
        fragment.unlink()
    print(f"{CHANGELOG}: added ## [{version}] - {date}; removed {len(removed)} fragment(s)")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default=".", help="repository root (default: cwd)")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("check", help="validate every fragment")

    guard = sub.add_parser("guard", help="refuse a PR that edits CHANGELOG.md")
    guard.add_argument("--base", required=True, help="the PR's base commit")
    guard.add_argument("--branch", default="", help="the PR's head branch name")
    guard.add_argument("--label", action="append", default=[], help="a PR label (repeatable)")

    sub.add_parser("normalize", help="fold repeated headings under [Unreleased]")

    for name, write in (("release", True), ("preview", False)):
        p = sub.add_parser(name, help=("roll fragments into CHANGELOG.md" if write else "print the section release would add"))
        p.add_argument("--version", required=True, help="X.Y.Z")
        p.add_argument("--date", default=_dt.date.today().isoformat(), help="YYYY-MM-DD (default: today)")
        p.add_argument("--require-upgrade-notes", action="store_true",
                       help="refuse without an Upgrade notes entry (minor and major bumps)")
        p.set_defaults(write=write)

    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    try:
        if args.command == "check":
            return cmd_check(root)
        if args.command == "guard":
            return cmd_guard(root, args.base, args.branch, args.label)
        if args.command == "normalize":
            return cmd_normalize(root)
        return cmd_release(root, args.version, args.date, args.require_upgrade_notes, args.write)
    except ChangelogError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
