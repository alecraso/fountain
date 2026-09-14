# Changelog fragments

A PR that changes something a user or operator can observe adds a file
here instead of editing `CHANGELOG.md`. The release PR rolls every file in
this directory into a dated `## [X.Y.Z]` section of `CHANGELOG.md` and
deletes it. `CHANGELOG.md` itself changes once per release, so two PRs never
edit the same line of it again. CI refuses a PR that edits `CHANGELOG.md`
directly.

## Write one

Name the file after the PR or the issue and what it did:
`2105-retired-urls-404.md`. Any name ending in `.md` works; `README.md` is
the one name that is not a fragment.

Inside, use the changelog's own section headings and bullets. Every bullet
carries its PR or issue number:

```markdown
### Upgrade notes

- **Retired browser URLs now return 404** (#2105). Update bookmarks to the
  configured Conversations or Team app.

### Fixed

- The reaper no longer suspends a sandbox mid-turn (#2101).
```

The sections are `Upgrade notes`, `Added`, `Changed`, `Deprecated`,
`Removed`, `Fixed` and `Security`. A fragment may carry several. Blank
lines between bullets are fine; nested bullets and multi-line bullets are
fine too, indented as they would be in `CHANGELOG.md`.

Links use absolute URLs (`https://managoat.com/docs/...`), because the
rolled changelog is also a manual page at `/docs/changelog`, where a
relative link resolves under `/docs` and the docs suite rejects it.

Check a fragment before pushing:

```sh
python3 scripts/changelog.py check
```

## What does not need one

Internal work a user cannot observe: a guard test, a refactor with no
behaviour change, a dependency bump with no user-visible effect, CI
plumbing. Judge by whether a reader of the release could notice, not by
whether the PR merged.

## At release

The release-bump workflow runs `python3 scripts/changelog.py release
--version X.Y.Z` (with `--require-upgrade-notes` on a minor or major bump;
`- None.` is fine when true). It rolls whatever sits
under `## [Unreleased]` plus every fragment here into the new section, in
the order above, and leaves the `[Unreleased]` stub in place. Preview it
without writing:

```sh
python3 scripts/changelog.py preview --version X.Y.Z
```

To fix a typo in a shipped entry, edit `CHANGELOG.md` directly and put the
`release:manual-changelog` label on the PR; that is the one door past the guard.
The guard reads the labels live, so re-running the `CI policy and alert
tests` job after labelling is enough; no new push is needed.
