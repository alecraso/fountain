#!/usr/bin/env bash
# Dead-code reports for the server and the two Go modules. Advisory: nothing
# here gates a merge, and the Elixir half is a list of candidates rather than
# verdicts (CONTRIBUTING.md, "Finding dead code", explains the five shapes it
# gets wrong). `.github/workflows/dead-code.yml` runs this monthly.
#
#   scripts/dead-code.sh            both
#   scripts/dead-code.sh elixir     public functions no compiled module calls
#   scripts/dead-code.sh go         unreachable functions, both Go modules
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
what=${1:-all}

# x/tools ships deadcode; pinned so two runs of the report agree.
DEADCODE_VERSION=${DEADCODE_VERSION:-v0.50.0}

elixir_report() {
  echo "## Elixir: public functions no compiled module calls (mix_unused)"
  echo
  # --force so the tracer sees every module, not just the ones that changed.
  # The compile's own chatter goes to stderr; only the hints are the report.
  (cd "$root/apps/fountain" &&
    MIX_UNUSED=1 MIX_ENV=dev mix compile --force 2>/dev/null |
    grep -A1 -E '^hint: ' | grep -v -- '^--$') || true
}

go_report() {
  echo "## Go: unreachable functions (golang.org/x/tools/cmd/deadcode)"
  echo
  for mod in cli apps/fountain_buzz/cli; do
    echo "### $mod"
    # -test: a function only a test reaches is not unreachable. An exported
    # function in cli/api or cli/credentials may still be one another module
    # imports (apps/fountain_buzz/cli does), so read those lines as API, not
    # dead code.
    (cd "$root/$mod" && go run "golang.org/x/tools/cmd/deadcode@$DEADCODE_VERSION" -test ./...) || true
    echo
  done
}

case "$what" in
  elixir) elixir_report ;;
  go) go_report ;;
  all)
    elixir_report
    echo
    go_report
    ;;
  *)
    echo "usage: $0 [elixir|go|all]" >&2
    exit 2
    ;;
esac
