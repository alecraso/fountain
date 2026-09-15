### Changed

- **`mix precommit` is now `scripts/precommit.sh`**, one process per stage
  with a named-stage summary, and its exit status is the verdict: the run
  stops at the first failing stage and exits with that stage's status.
  `mix precommit --list` prints the stages and `mix precommit credo test`
  runs a subset. It refuses an Elixir that does not match `.tool-versions`
  (`PRECOMMIT_ALLOW_TOOLCHAIN_DRIFT=1` overrides).
- **`CLAUDE.md` shrinks to rules, commands and links.** The CI job table and
  coverage notes moved to `scripts/ci/README.md`, the manual's guardrails and
  prose linters to `contributing/docs.md`, the component-library recipes to
  `contributing/component-libraries.md`, and the flake procedure to
  `CONTRIBUTING.md`, each rule with one home.
- **Component-library extraction is paused** (ADR 0037 addendum) unless an
  independent consumer or a release schedule of its own justifies the
  two-PR coordination cost.
