### Changed

- **Changelog entries are now fragment files under `changelog.d/`**, one per
  pull request, and `CHANGELOG.md` is written once per release by the
  release-bump workflow (#2158). A PR that edits `CHANGELOG.md` directly fails
  CI. Every PR used to insert a line at the top of the same `[Unreleased]`
  subsection, which was the most common merge conflict on `main`.
