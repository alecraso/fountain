#!/usr/bin/env bash
# Regenerate decisions/index.md from ADR frontmatter (OKF spec §8).
#
# `okf index` would do this too, but it sorts by title and truncates the
# description; ADRs read better in number order with their status beside them.
# CI runs this and fails if the committed index differs (see
# .github/workflows/decisions.yml), so edit frontmatter, not the index.
set -euo pipefail
cd "$(dirname "$0")/../decisions"

{
  cat <<'EOF'
# Decisions

Architecture Decision Records for Fountain, one per file, numbered in the
order they were opened. The index lists the decision status and summary;
read each ADR for its implementation status and rationale. The
[template](0001-template.md) describes the small required frontmatter.
`okf validate .` checks the bundle and `okf backlinks . <id>` shows dependencies.
Gaps in numbering are ADRs still on open branches.

## ADRs

| # | Title | ADR status | Description |
|---|-------|------------|-------------|
EOF
  for f in [0-9][0-9][0-9][0-9]-*.md; do
    awk -v file="$f" '
      function unq(s) { sub(/^"/, "", s); sub(/"$/, "", s); gsub(/\\"/, "\"", s); return s }
      NR == 1 && $0 != "---" { exit 1 }
      NR > 1 && $0 == "---" { done = 1 }
      !done && /^adr: /         { adr = unq(substr($0, 6)) }
      !done && /^title: /       { title = unq(substr($0, 8)) }
      !done && /^adr_status: /  { st = unq(substr($0, 13)) }
      !done && /^description: / { desc = unq(substr($0, 14)) }
      END {
        gsub(/\|/, "\\|", title); gsub(/\|/, "\\|", desc)
        printf "| %s | [%s](%s) | %s | %s |\n", adr, title, file, st, desc
      }' "$f"
  done
} > index.md
