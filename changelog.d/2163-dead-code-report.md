### Added

- A dead-code report (#2163). `scripts/dead-code.sh` runs `mix_unused` over the
  server (a compiler tracer `apps/fountain/mix.exs` enables only under
  `MIX_UNUSED=1`) and `deadcode` over the two Go modules, and
  `.github/workflows/dead-code.yml` publishes both on the first of the month.
  Advisory only; CONTRIBUTING.md says how to read the Elixir half, which
  cannot see dynamic dispatch, extension callers or tests.
