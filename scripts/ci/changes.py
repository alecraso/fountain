#!/usr/bin/env python3
"""Select documentation and SDK checks from one conservative, NUL-delimited diff."""

import re
import subprocess
import sys


LANGUAGES = frozenset({"elixir", "python", "typescript", "swift"})
# SDK-local docs and tooling take precedence over the unrelated-path allowlist.
OWNED_FILES = {
    "elixir": {"docs/elixir-sdk.md", "scripts/elixir-sdk-release.exs",
               ".github/workflows/elixir-sdk-publish.yml",
               ".github/workflows/elixir-sdk-release-gate.yml"},
    "python": {"docs/python-sdk.md", ".github/workflows/python-sdk-publish.yml",
               ".github/workflows/python-sdk-release-gate.yml"},
    "typescript": {"docs/sdk.md", "scripts/sdk-release.mjs", "scripts/sdk-publish-tag.mjs",
                   "scripts/sdk-publish-tag.test.mjs", ".github/workflows/sdk-publish.yml",
                   ".github/workflows/sdk-release-gate.yml"},
    "swift": {"docs/swift-sdk.md", "Package.swift", "Package.resolved", ".swift-format"},
}
# Only test trees go here, never a whole app. `ee/lib/fountain_web/` must keep
# fanning out: it can move the OpenAPI document, which every SDK is generated
# against.
UNRELATED_PREFIXES = (
    "docs/", "decisions/", "assets/", "apps/fountain/assets/",
    "apps/fountain/lib/fountain_web/live/", "apps/fountain/lib/fountain_web/components/",
    "apps/fountain/test/", "apps/fountain_buzz/test/", "apps/fountain_support/test/",
    "apps/fountain_google/test/",
    "ee/test/",
)
UNRELATED_FILES = {
    "apps/fountain/lib/fountain/telemetry.ex", "apps/fountain/lib/fountain/telemetry_tick.ex",
    "apps/fountain/lib/fountain_web/telemetry.ex",
}


# Only these extension manuals have registered documentation suites.
MANUAL_EXTENSIONS = ("fountain_buzz", "fountain_google", "fountain_microsoft", "fountain_slack")
CONTRIBUTOR_FILES = {"CLAUDE.md", "CONTRIBUTING.md", "SETUP.md", "scripts/ci/README.md"}


def contributor_doc(path):
    return path in CONTRIBUTOR_FILES or (
        path.endswith(".md") and path.startswith(("contributing/", "standards/"))
    )


def manual_doc(path):
    # README's diagram alt text is checked by Fountain.DocsTest.
    return path == "README.md" or path.startswith(
        ("docs/", *(f"apps/{app}/docs/" for app in MANUAL_EXTENSIONS))
    )


def valid_paths(paths):
    return bool(paths) and all(
        path and not path.startswith("/") and not re.search(r"[\x00-\x1f\x7f]", path)
        and not any(part in {"", ".", ".."} for part in path.split("/"))
        for path in paths
    )


def classify_docs(paths):
    if not valid_paths(paths):
        return {"docs_only": False, "manual_docs": True, "cli_docs": False}
    sdk_readmes = {f"sdk/{language}/README.md" for language in LANGUAGES}
    return {
        "docs_only": all(contributor_doc(p) or manual_doc(p) or p in sdk_readmes for p in paths),
        "manual_docs": any(manual_doc(p) for p in paths),
        "cli_docs": any(p == "docs/cli.md" or p.startswith("docs/cli/") for p in paths),
    }


def classify_sdks(paths):
    selected = set()
    if not valid_paths(paths):
        return LANGUAGES
    for path in paths:
        owner = next((language for language in LANGUAGES
                      if path.startswith(f"sdk/{language}/") or path in OWNED_FILES[language]), None)
        if owner:
            selected.add(owner)
        elif not (contributor_doc(path) or manual_doc(path) or path in UNRELATED_FILES
                  or path.startswith(UNRELATED_PREFIXES)):
            # Shared contract/conformance, API implementation, build config,
            # CI policy and every unregistered path require every SDK.
            return LANGUAGES
    return frozenset(selected)


def changed_paths(base):
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        return []
    try:
        result = subprocess.run(
            ["git", "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
             "--name-only", "-z", base, "HEAD", "--"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout
        if not result or not result.endswith(b"\0"):
            return []
        paths = result[:-1].decode("utf-8").split("\0")
        return paths if valid_paths(paths) else []
    except (OSError, subprocess.CalledProcessError, UnicodeDecodeError):
        return []


if __name__ == "__main__":
    paths = changed_paths(sys.argv[1]) if len(sys.argv) == 2 else []
    outputs = classify_docs(paths)
    selected = classify_sdks(paths)
    outputs.update({f"sdk_{language}": language in selected for language in sorted(LANGUAGES)})
    # Never write paths or other diff-controlled text to GITHUB_OUTPUT.
    for key, value in outputs.items():
        print(f"{key}={str(value).lower()}")
