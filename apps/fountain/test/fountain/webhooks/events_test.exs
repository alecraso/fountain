defmodule Fountain.Webhooks.EventsTest do
  @moduledoc """
  The catalogue against the code (#700, ADR 0024).

  The whole claim of hanging dispatch off `publish_stage/4` is that a new
  lifecycle outcome cannot be added without webhook subscribers seeing it.
  That claim is invisible to the compiler: add a `publish_stage(conv, "quota",
  "exceeded")` call and nothing breaks, the event is dispatched with a type
  nobody can subscribe to by name, and the docs page is quietly wrong.

  So this reads the call sites out of the source, the way `docs_test.go` reads
  the CLI tree, and fails when one produces a type the catalogue does not
  name. It is the same shape of guard as the audit guardrail: the rule is
  enforced rather than merely written down.
  """

  use ExUnit.Case, async: true

  alias Fountain.Webhooks.Events

  # Where publish_stage/4 is called from. A new file calling it belongs here.
  @sources [
    "lib/fountain/conversations.ex",
    "lib/fountain/conversations/conversation_server.ex",
    "lib/fountain/conversations/reapply.ex",
    "lib/fountain/conversations/checkpoints.ex",
    "lib/fountain/conversations/reattachment.ex",
    "lib/fountain/conversations/provisioning.ex",
    "lib/fountain/conversations/egress.ex",
    "lib/fountain/conversations/turn_machine.ex",
    "lib/fountain/conversations/pending.ex",
    "lib/fountain/conversations/lifecycle.ex",
    "lib/fountain/conversations/connection.ex",
    "lib/fountain/conversations/output.ex"
  ]

  # publish_stage(<anything>, "<stage>", "<status>"
  @call_site ~r/publish_stage\(\s*[^,]+,\s*"([a-z_]+)",\s*"([a-z_]+)"/

  defp app_dir do
    Application.app_dir(:fountain) |> Path.join("../../../../apps/fountain") |> Path.expand()
  end

  defp published_pairs do
    for source <- @sources,
        path = Path.join(app_dir(), source),
        File.exists?(path),
        [_, stage, status] <- Regex.scan(@call_site, File.read!(path)),
        uniq: true,
        do: {stage, status}
  end

  test "the source actually reachable from here has publish_stage call sites" do
    # Guard the guard: a broken path or a changed call shape would make every
    # assertion below vacuously true.
    assert length(published_pairs()) > 20
  end

  # A retired stage keeps its `publish_stage/4` call sites until the code
  # holding them is deleted, but nothing can reach them — the two exclusive
  # things that could are already gone. It must be out of the catalogue and out
  # of the docs by then, so the two assertions below skip it in both
  # directions, and the test after this one pins that it really is retired
  # rather than merely missing.
  defp retired_stages, do: MapSet.new(Events.retired(), fn {stage, _statuses} -> stage end)

  test "every stage transition in the source is in the catalogue" do
    retired = retired_stages()

    missing =
      published_pairs()
      |> Enum.reject(fn {stage, _status} -> MapSet.member?(retired, stage) end)
      |> Enum.map(fn {stage, status} -> Events.type(stage, status) end)
      |> Enum.reject(&Events.known?/1)
      |> Enum.sort()

    assert missing == [], """
    These stage transitions are published but are not in the webhook
    catalogue, so nobody can subscribe to them by name and the docs page
    does not list them:

      #{Enum.join(missing, "\n  ")}

    Add them to `Fountain.Webhooks.Events`, and to the table in
    docs/reference/webhooks.md. If the stage is being retired instead, put it
    in `@retired` and mark it historical on the docs page.
    """
  end

  test "a retired stage is out of the catalogue while its call sites remain" do
    # The transitional state this suite has to allow, asserted rather than
    # assumed: `caller_tool` is still published from `Pending` and is already
    # unreachable, so it must be retired vocabulary and not a catalogue entry.
    assert Enum.any?(published_pairs(), fn {stage, _} -> stage == "caller_tool" end),
           "no caller_tool call site left — drop it from @retired and from this test"

    refute Events.known?("conversation.caller_tool.started")
    refute List.keymember?(Events.catalogue(), "caller_tool", 0)
    assert List.keymember?(Events.retired(), "caller_tool", 0)
  end

  test "the catalogue names nothing the source cannot produce" do
    # The other direction. A stale entry is a documented event that never
    # arrives, which is worse than an undocumented one.
    published = MapSet.new(published_pairs(), fn {s, st} -> Events.type(s, st) end)

    # `turn.done` and `turn.failed` also come from a conditional call site the
    # regex cannot read, and both are in `published` from other call sites.
    # A retired stage is deliberately absent from `types/0`, so it cannot be
    # stale here; this direction only sees what the catalogue still names.
    stale = Enum.reject(Events.types(), &MapSet.member?(published, &1))

    assert stale == [],
           "these catalogue entries match no publish_stage call site: #{inspect(stale)}"
  end

  describe "filters" do
    test "an exact type matches only itself" do
      assert Events.matches?(["conversation.turn.done"], "conversation.turn.done")
      refute Events.matches?(["conversation.turn.done"], "conversation.turn.failed")
    end

    test "a stage wildcard matches every status of that stage" do
      filters = ["conversation.turn.*"]

      assert Events.matches?(filters, "conversation.turn.done")
      assert Events.matches?(filters, "conversation.turn.interrupted")
      refute Events.matches?(filters, "conversation.provision.done")
    end

    test "a bare star matches everything" do
      for type <- Events.types(), do: assert(Events.matches?(["*"], type))
    end

    test "an empty filter matches nothing" do
      refute Events.matches?([], "conversation.turn.done")
    end

    test "a typo is not a valid filter" do
      refute Events.valid_filter?("conversation.turn.finished")
      refute Events.valid_filter?("conversation.tunr.done")
      refute Events.valid_filter?("conversation.*")
      refute Events.valid_filter?("**")
      refute Events.valid_filter?(nil)
    end

    # ADR 0057 (#2252). The catalogue stopped emitting `caller_tool` when the
    # tool bridge was retired, but the vocabulary still accepts it: every
    # endpoint update re-validates the whole `event_types` array, so an
    # endpoint that still subscribes to a retired type would otherwise be
    # refused the next time its owner changed the URL.
    test "a retired type stays a valid filter, so a stale endpoint stays editable" do
      for type <- ["conversation.caller_tool.started", "conversation.caller_tool.done"] do
        assert Events.valid_filter?(type)
      end

      assert Events.valid_filter?("conversation.caller_tool.*")
    end

    test "but a retired type is not emitted, and is not in the catalogue" do
      refute "conversation.caller_tool.started" in Events.types()
      refute "conversation.caller_tool.done" in Events.types()
      refute List.keymember?(Events.catalogue(), "caller_tool", 0)
      refute Events.known?("conversation.caller_tool.started")

      # It is a bare star's business too: `*` delivers what is emitted, and a
      # retired type is never emitted, so nothing reaches a subscriber.
      refute Enum.any?(Events.types(), &String.starts_with?(&1, "conversation.caller_tool."))

      # Guard the guard: the retired list is not simply empty.
      assert List.keymember?(Events.retired(), "caller_tool", 0)
    end

    test "a typo inside a retired stage is still refused" do
      refute Events.valid_filter?("conversation.caller_tool.finished")
      refute Events.valid_filter?("conversation.caller_tul.done")
    end

    test "the three shapes are valid filters" do
      assert Events.valid_filter?("*")
      assert Events.valid_filter?("conversation.turn.*")
      assert Events.valid_filter?("conversation.turn.done")
    end
  end

  test "the defaults are the three an integrator usually wants, and all real" do
    assert Events.defaults() == [
             "conversation.turn.done",
             "conversation.turn.failed",
             "conversation.provision.failed"
           ]

    for type <- Events.defaults(), do: assert(Events.known?(type))
  end
end
