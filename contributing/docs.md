# Writing the manual

`docs/` is the public manual, published at `/docs` and nowhere else. This
page is the one place the guardrails around it are written down; CLAUDE.md
and CONTRIBUTING.md link here rather than repeating them.

## How a page is published

The markdown is embedded at compile time by `Fountain.Docs`, one `use` line
over the `managoat_docs` library (ADR 0037). The macro embeds the pages,
`Managoat.Docs.Markdown` renders them (the sanitising pipeline that `/help`
and agent output share; it returns a binary, callers `Phoenix.HTML.raw/1`
it), and `docs_test.exs` takes its structural checks from
`Managoat.Docs.GuardrailCase`.

There is exactly one publisher. The MkDocs Material site and its GitHub
Pages copy were retired in #1008, and the redirect tombstone that answered
the old URLs died with the move to the `managoat` organization (GitHub Pages
does not follow a transfer redirect; #1814 deleted its generator). Do not
build a second one; ADR 0034 is the standing decision.

The dialect the renderer understands is small (snippet includes,
admonitions, relative `.md` links) and is inherited from the MkDocs site.
Check a page at `/docs` if it uses anything fancier: start the server and
open the route.

## Structural rules, enforced by the suite

`docs_test.exs` runs these on every PR. Run it directly while editing:

```bash
mix test apps/fountain/test/fountain/docs_test.exs
```

- **The nav lives only in `docs/nav.yml`.** `Fountain.Docs` parses the
  `nav:` block at compile time. Keep to the two line shapes the parser reads
  (`  - Title: x.md`, and `  - Section:` with six-space-indented children);
  a line it cannot read raises at compile time. **Sections are one level
  deep**: the sidebar renders a section and its pages, so a sub-section, or a
  page indented past its siblings, raises too. Flatten it into a sibling
  section (`Catalog` is the model) or make it headings on a hub page.
- **A page not in the nav is published nowhere.** The test walks
  `docs/**/*.md` both ways: every page the nav names exists, and every page
  on disk is named. There is no allowlist. A markdown file that should not be
  read at `/docs` belongs somewhere else; `decisions/`, `standards/` and
  `contributing/` are deliberately unpublished.
- **Links and anchors are checked.** Every internal `/docs` link must resolve
  to a page, and every `#anchor` to a heading on that page. The checks are
  `Managoat.Docs.Checks`; the library runs the same template against a
  fixture manual, so a change to a check is tested there first.
- **Anything read at compile time must be `COPY`d into the Docker build
  stage.** The release image holds no `docs/`, only strings baked out of it,
  so a file outside the `COPY` list does not degrade to a broken link:
  `mix release` dies, no image is built, CI stays green and the deploy never
  happens (#884). The test asserts the module's `external_resources/0`
  against the Dockerfile. A file outside `docs/` goes on the
  `extra_resources:` line of `Fountain.Docs`, which is how `CHANGELOG.md` is
  declared.
- **`docs/cli.md` is diffed against the CLI.** `cli/internal/cmd/docs_test.go`
  fails if a command exists that the page does not mention, or the reverse.
  Add a CLI command, add it to `docs/cli.md` in a fenced `bash` block.
- **An extension may own pages** (ADR 0043, #1510). They live in
  `apps/<app>/docs/` with that app's own `nav.yml`, embedded by its own
  `use Managoat.Docs` module and merged into the sidebar by `Fountain.Manual`,
  which is what every renderer asks instead of `Fountain.Docs`. Sections
  merge by title. A core page must not link to an extension page: the core
  test walks the core manual alone, and a core-only distribution would carry
  a dead link. The extension's own suite runs the link checks over the merged
  manual.

## Wording checks, advisory

Three reports run in CI on every change to a page. They advise; findings do
not block a merge. Logs show the first 60 lines and the `prose-advice`
artifact keeps the full output for seven days. Run them locally when you
touch `docs/` or an extension's manual:

```bash
python3 scripts/docs-style.py
vale lint docs $(ls -d apps/*/docs 2>/dev/null)
npm ci --prefix scripts/destink && node scripts/destink/destink.mjs
```

`docs-style.py` and `destink.mjs` find `apps/*/docs` themselves; vale selects
from its path arguments, so those directories are named on the command line.
Each has an empty-or-shrinking backlog file, and a page not on the backlog is
checked in full, so every new page is covered by default.

- **`scripts/docs-style.py`** checks the style sheet,
  [`standards/voice-and-style.md`](../standards/voice-and-style.md): no em
  dashes, no colon-introduced lists, no "simply", "obviously" or "coming
  soon". `scripts/docs-style-allow.txt` is the backlog; cleaning a page means
  deleting its line, and the list only shrinks (#911).
- **`vale`** checks ASD-STE100 Simplified Technical English, the standard in
  [`standards/simplified-technical-english.md`](../standards/simplified-technical-english.md).
  Config is `.vale-ste.yml`; `.valeignore` is the backlog and is empty. The
  linter is [`stuffbucket/vale`](https://github.com/stuffbucket/vale) (MIT,
  pure Go): `brew install stuffbucket/tap/vale`. CI uses the pinned `v0.15.0`
  release binary, checksum-verified, not `go install`, because the jobs pin
  Go from `cli/go.mod` with `GOTOOLCHAIN=local`. Six rules gate: sentence
  length (20 procedural / 25 descriptive), contractions, the passive voice,
  phrasal verbs, one instruction per sentence, and the -ing form.
  `STE.Vocabulary` advises only; its wordset was built for aircraft
  maintenance. Read the standard before you fight the linter: it lists the
  three traps (joined table cells, a code span opening a sentence,
  `anything` matching the -ing rule) and where a suppression comment is
  legitimate.
- **`scripts/destink/destink.mjs`** looks for AI-writing tells. The engine
  is the published [`sentences`](https://github.com/lex00/sentences) package
  (MIT), pinned by the range in `scripts/destink/package.json`; bump it and
  run `npm install --prefix scripts/destink`. `scripts/destink/allow.txt` is
  the backlog and is empty. Two things to know:
  - It lints prose, not markdown. The package's `lint/markdown-prose` export
    blanks code fences, tables, inline code, link targets, HTML blocks and
    admonition directives so every offset still indexes the real file. If a
    finding points at something that is not prose, the fix belongs upstream
    in `lint/markdown-prose`, not in the page.
  - The rule set is opt-in and each entry carries its count. `ENABLED` and
    `DISABLED` in `destink.mjs` list all 46 rules with the number each
    produced over `docs/` and, for the disabled ones, why. A rule added
    upstream between versions arrives off. The gate refuses to run if an id
    named there is missing from the package's registry, which is what a
    rename upstream looks like from here.

## The changelog is a docs page

`CHANGELOG.md` is served at `/docs/changelog`, which is why fragment links
are absolute URLs (a relative link would resolve under `/docs`) and why the
file is on the `extra_resources:` line. How fragments work is in
[`changelog.d/README.md`](../changelog.d/README.md).
