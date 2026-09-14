#!/usr/bin/env python3
"""Reconcile repository labels without deleting labels or replacing their IDs."""

import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import quote


def plan_changes(definitions, existing):
    by_name = {label["name"].casefold(): label for label in existing}
    names = set()
    changes = []
    for definition in definitions:
        name = definition["name"]
        if not name or name.casefold() in names:
            raise ValueError(f"Duplicate or empty label name: {name!r}")
        names.add(name.casefold())
        if not re.fullmatch(r"[0-9a-fA-F]{6}", definition["color"]):
            raise ValueError(f"Invalid color for {name}")
        if len(definition["description"]) > 100:
            raise ValueError(f"Description exceeds 100 characters for {name}")
        current = by_name.get(name.casefold())
        previous_name = definition.get("previous_name")
        previous = by_name.get(previous_name.casefold()) if previous_name else None
        if current and previous and current["id"] != previous["id"]:
            raise ValueError(f"Both {previous_name!r} and {name!r} exist; reconcile assignments first")
        current = current or previous
        desired = {key: definition[key] for key in ("name", "color", "description")}
        if current is None:
            changes.append((None, desired))
        elif (current["name"] != name
              or current["color"].lower() != desired["color"].lower()
              or (current.get("description") or "") != desired["description"]):
            changes.append((current["name"], desired))
    return changes


def api(endpoint, method="GET", payload=None):
    args = ["gh", "api", "--method", method, endpoint]
    if payload is None:
        args += ["--paginate", "--slurp"]
    else:
        args += ["--input", "-"]
    result = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--manifest", type=Path, default=Path(".github/labels.json"))
    parser.add_argument("--apply", action="store_true", help="apply changes; default only reports")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        parser.error("--repo must be OWNER/REPOSITORY")
    endpoint = f"repos/{args.repo}/labels"
    pages = api(endpoint + "?per_page=100")
    existing = [label for page in pages for label in page]
    # Validate the complete plan before the first mutation.
    changes = plan_changes(json.loads(args.manifest.read_text()), existing)
    for old_name, desired in changes:
        print(f"{old_name or '(new)'} -> {desired['name']}", flush=True)
        if args.apply:
            if old_name is None:
                api(endpoint, "POST", desired)
            else:
                payload = {"new_name": desired["name"], "color": desired["color"],
                           "description": desired["description"]}
                api(endpoint + "/" + quote(old_name, safe=""), "PATCH", payload)
    if args.apply:
        verified = [label for page in api(endpoint + "?per_page=100") for label in page]
        if plan_changes(json.loads(args.manifest.read_text()), verified):
            raise RuntimeError("Label state changed during synchronization; inspect and rerun")
    print(f"{len(changes)} label changes {'applied and verified' if args.apply else 'planned'}")


if __name__ == "__main__":
    main()
