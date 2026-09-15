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

  # Every call site, as `{source, stage, status}`, with duplicates kept: the
  # retired-site pin below counts them.
  defp published_sites do
    for source <- @sources,
        path = Path.join(app_dir(), source),
        File.exists?(path),
        [_, stage, status] <- Regex.scan(@call_site, File.read!(path)),
        do: {source, stage, status}
  end

  defp published_pairs do
    published_sites()
    |> Enum.map(fn {_source, stage, status} -> {stage, status} end)
    |> Enum.uniq()
  end

  # The transitional allowance, pinned to the call site (ADR 0057, #2252):
  # `Pending.park/6` and `Pending.resolve_call/5` still publish `caller_tool`,
  # and nothing can reach them — the two things that could are gone. These
  # two, in this file, once each, are the ONLY retired publishes the suite
  # lets through. A retired type is not in the catalogue, `Webhooks` dispatches
  # on `Events.matches?/2` without a catalogue check, and grandfathered filters
  # still name it, so a new emitter — another file, another status, a second
  # copy — would be a delivery nobody can subscribe to by name. Stage 2 deletes
  # both sites; when it does, empty this map and the assertion below becomes
  # "no retired stage is published from anywhere".
  @retired_call_sites %{
    {"lib/fountain/conversations/pending.ex", "caller_tool", "started"} => 1,
    {"lib/fountain/conversations/pending.ex", "caller_tool", "done"} => 1
  }

  test "the source actually reachable from here has publish_stage call sites" do
    # Guard the guard: a broken path or a changed call shape would make every
    # assertion below vacuously true.
    assert length(published_pairs()) > 20
  end

  defp retired_stages, do: MapSet.new(Events.retired(), fn {stage, _statuses} -> stage end)

  test "every stage transition in the source is in the catalogue" do
    # Only the pinned retired sites are exempt. A retired stage published from
    # anywhere else shows up here as missing, which is the right reading: it
    # is a new emitter of a type nobody can subscribe to.
    missing =
      published_sites()
      |> Enum.reject(&Map.has_key?(@retired_call_sites, &1))
      |> Enum.map(fn {_source, stage, status} -> Events.type(stage, status) end)
      |> Enum.reject(&Events.known?/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert missing == [], """
    These stage transitions are published but are not in the webhook
    catalogue, so nobody can subscribe to them by name and the docs page
    does not list them:

      #{Enum.join(missing, "\n  ")}

    Add them to `Fountain.Webhooks.Events`, and to the table in
    docs/reference/webhooks.md. If the stage is being retired instead, put it
    in `@retired` and mark it historical on the docs page. A stage that is
    already retired must not gain a call site: `@retired_call_sites` names the
    only ones allowed, and it only ever shrinks.
    """
  end

  test "the retired stages are published from exactly the pinned sites" do
    retired = retired_stages()

    found =
      published_sites()
      |> Enum.filter(fn {_source, stage, _status} -> MapSet.member?(retired, stage) end)
      |> Enum.frequencies()

    assert found == @retired_call_sites, """
    The retired publish_stage/4 call sites do not match the pin.

      pinned: #{inspect(@retired_call_sites, pretty: true)}
      found:  #{inspect(found, pretty: true)}

    A site that vanished means stage 2 (#2252) has deleted it: remove it from
    `@retired_call_sites`, and leave the map empty once both are gone — that is
    the invariant from then on. A site that appeared, or a second copy of one,
    is a new emitter of a retired type: nothing can subscribe to it by name,
    and `Webhooks` would still deliver it to a grandfathered filter. Do NOT
    drop the stage from `@retired` in either case: the vocabulary stays valid
    until the rollback floor (#2273), so an endpoint still naming it can be
    edited. The `filters` tests cover that state.
    """

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

    # ADR 0057 (#2252). A retired stage is NOT subscribable: an endpoint saved
    # against one would look fine and receive nothing, which is the failure
    # save-time validation exists to prevent. `retired_filter?/1` recognises it
    # only so `Webhooks.Endpoint` can grandfather a value already stored on a
    # row — see `webhooks_test.exs` for both halves of that.
    test "a retired type is not a valid filter" do
      for type <- [
            "conversation.caller_tool.started",
            "conversation.caller_tool.done",
            "conversation.caller_tool.*"
          ] do
        refute Events.valid_filter?(type)
        assert Events.retired_filter?(type)
      end
    end

    test "retired_filter?/1 recognises only retired stages" do
      refute Events.retired_filter?("conversation.turn.done")
      refute Events.retired_filter?("conversation.turn.*")
      refute Events.retired_filter?("conversation.caller_tool.finished")
      refute Events.retired_filter?("*")
      refute Events.retired_filter?(nil)
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
