defmodule Fountain.Conversations.ConversationServerSizeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  `ConversationServer` only shrinks.

  Tracker #1369 refactors the server by subtraction: each sub-issue moves a
  function family into a module under `Fountain.Conversations.*` and lowers
  `@pin` to the file's new length in the PR that lands on `main` (see below
  for a stack). The pin is the file's line count on `main` at the last move,
  so a change that makes the file longer fails here and has to say why.

  The size ceiling only shrinks: the number
  is not a target, it is a record of where the file is, and the only edit it
  accepts is downward. Lower it when you move something out; never raise it.

  **A stack in flight does not move it.** The pin is the length on `main`, and
  a number measured against a branch is stale the moment any link below it
  grows the file, which is what review rounds do. #1565 lowered it mid-stack to
  the tip's exact length, left zero headroom, and went red two rounds later
  when a fix four PRs down added lines. That lowering was backed out before
  merge. Land the shrink first, then lower the pin in a follow-up, when the
  number has stopped moving.

  That is what this pin is mid-way through. #1749 and #1751 each lowered it
  to their own tip's exact length while the #1766/#1767 campaign was in
  flight below them, which left `main` at 2646 with the file also at 2646 —
  no room for the next line anyone adds, and a campaign already ~68 lines
  over it with nothing red anywhere (#2032). Each of its PRs is green
  against its own base, the merges conflict on nothing, and `count <= @pin`
  only fails at the moment the last one lands.
  """

  # 2364 → 2223. Retiring the tool bridge (ADR 0057, #2252) took the four
  # parked-call entry points, their `handle_call` clauses, the deadline
  # handler and the `caller_calls` field out of the server; `Pending` lost
  # the other half in the same change. The file is 2213 lines on this branch.
  #
  # 2223 is that 2213 plus 10 lines, the same headroom every previous pin
  # kept for review rounds. This is a deletion, not a move, so nothing is in
  # flight below the file — but if stage 3 of the retirement lands after
  # this, it lowers the pin again.
  @pin 2223

  @server "apps/fountain/lib/fountain/conversations/conversation_server.ex"

  test "the server is no longer than the pin" do
    root = Path.expand("../../../../..", __DIR__)
    lines = root |> Path.join(@server) |> File.read!() |> String.split("\n")
    # `String.split/2` yields one more element than there are newlines, so
    # this is `wc -l` for a file that ends in a newline.
    count = length(lines) - 1

    assert count <= @pin,
           "#{@server} is #{count} lines, over the pin of #{@pin}. " <>
             "The server only shrinks (#1369): move the new code into a " <>
             "Fountain.Conversations.* module rather than raising the pin."
  end
end
