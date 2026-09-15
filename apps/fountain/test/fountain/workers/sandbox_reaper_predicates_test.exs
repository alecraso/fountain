defmodule Fountain.Workers.SandboxReaperPredicatesTest do
  @moduledoc """
  A standalone regression for the reaper's date-comparison discipline,
  raised on #2309's review of a since-withdrawn locking change to this
  module: Elixir compares two `DateTime` STRUCTS field-by-field in
  alphabetical key order with `<`, so a naive `<` reads `~U[2026-09-30]`
  (day 30) as "later" than `~U[2026-10-01]` (day 1) — backwards.

  `Fountain.Workers.SandboxReaper` makes every date comparison in SQL today
  (`Ecto.Query`'s `s.updated_at < ^cutoff` compiles to a Postgres `<`, which
  compares timestamps correctly, not an Elixir struct comparison), so
  nothing in this module is broken by this bug right now. This test exists
  so a future Elixir-side comparison added here — the durable
  locking/revalidation work this module needs is deferred to #2307, and
  will need one — reaches for `DateTime.before?/2` from the start, not `<`.
  """

  use ExUnit.Case, async: true

  test "DateTime.before?/2 is not fooled by a day-of-month inversion across a month boundary" do
    earlier = ~U[2026-09-30 12:00:00.000000Z]
    later = ~U[2026-10-01 00:00:00.000000Z]

    refute earlier < later

    assert DateTime.before?(earlier, later)
    refute DateTime.before?(later, earlier)
  end
end
