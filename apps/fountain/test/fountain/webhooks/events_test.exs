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
    "lib/fountain/conversations/output.ex",
    "lib/fountain/conversations/home_checkpoint.ex"
  ]

  # publish_stage(<anything>, "<stage>", "<status>"
  @call_site ~r/publish_stage\(\s*[^,]+,\s*"([a-z_]+)",\s*"([a-z_]+)"/

  # The looser cousin of @call_site: it reads the stage only, so a call site
  # whose status is a variable or an expression — home_checkpoint.ex's
  # `publish(sandbox, state, meta)`, or turn_machine.ex's `if(...)` — still
  # shows up. It cannot tell us the status, only that the stage is live.
  @stage_only ~r/publish_stage\(\s*[^,]+,\s*"([a-z_]+)"/

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

  # One entry per call site (not uniq), from the fixed @sources list, so the
  # two frequency maps below line up: a stage whose stage-only count exceeds
  # its literal-pair count has at least one call site the literal regex could
  # not read the status of.
  defp stage_call_sites(regex) do
    for source <- @sources,
        path = Path.join(app_dir(), source),
        File.exists?(path),
        stage <- stage_matches(regex, File.read!(path)),
        do: stage
  end

  defp stage_matches(regex, content) do
    Regex.scan(regex, content) |> Enum.map(fn [_, stage | _] -> stage end)
  end

  # Stages that have at least one call site among @sources where the status
  # argument is not a literal string — @call_site cannot see these, so
  # `published_pairs/0` under-reports them. A catalogue entry for one of
  # these stages counts as producible even without a literal (stage, status)
  # pair to point at.
  defp non_literal_status_stages do
    literal = Enum.frequencies(stage_call_sites(@call_site))
    all = Enum.frequencies(stage_call_sites(@stage_only))

    for {stage, count} <- all, count > Map.get(literal, stage, 0), into: MapSet.new() do
      stage
    end
  end

  # The independent, no-fixed-list version: every stage published anywhere
  # under lib/fountain/, found with the stage-only regex. Unlike
  # `published_pairs/0`, a brand new file calling `publish_stage/4` shows up
  # here without anyone adding it to @sources first.
  defp wildcard_stages do
    pattern = Path.join(app_dir(), "lib/fountain/**/*.ex")

    for path <- Path.wildcard(pattern),
        stage <- stage_matches(@stage_only, File.read!(path)),
        uniq: true,
        do: stage
  end

  test "the source actually reachable from here has publish_stage call sites" do
    # Guard the guard: a broken path or a changed call shape would make every
    # assertion below vacuously true.
    assert length(published_pairs()) > 20
  end

  test "guard the guard: the wildcard walk over lib/fountain/ finds stages too" do
    # Same reasoning as above, for the walk that does not depend on @sources.
    assert length(wildcard_stages()) > 10
  end

  defp retired_stages, do: MapSet.new(Events.retired(), fn {stage, _statuses} -> stage end)

  # The invariant once the last emitter is gone, and the one worth stating
  # directly: **retired means no publish sites at all**. The catalogue walk
  # below would not catch a returning emitter on its own — `Webhooks.dispatch`
  # derives the type and calls `Events.matches?/2` without consulting
  # `known?/1`, and a retired exact filter (and `*`) is still a valid
  # subscription, so a re-added `publish_stage(_, "caller_tool", _)` would
  # actually be delivered to a subscriber the retirement promised would never
  # hear from it again.
  test "nothing in the source publishes a retired stage" do
    retired = retired_stages()

    offenders =
      published_pairs()
      |> Enum.filter(fn {stage, _status} -> MapSet.member?(retired, stage) end)
      |> Enum.map(fn {stage, status} -> Events.type(stage, status) end)
      |> Enum.sort()

    assert offenders == [], """
    These retired stages still have `publish_stage/4` call sites:

      #{Enum.join(offenders, "\n  ")}

    A retired stage is never emitted — that is what retiring it means, and
    `Fountain.Webhooks` will deliver one to any endpoint whose filter still
    matches. Remove the call site, or take the stage out of `@retired` and put
    it back in the catalogue and the docs page.
    """
  end

  test "every stage transition in the source is in the catalogue" do
    missing =
      published_pairs()
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

  test "every stage the wildcard walk finds is a catalogue or retired stage" do
    # The independent net: a stage published anywhere under lib/fountain/,
    # regardless of whether @sources names its file or its status is a
    # literal. This is what would have caught `checkpoint` before anyone
    # added home_checkpoint.ex to @sources by hand.
    known = MapSet.new(Events.catalogue(), fn {stage, _statuses} -> stage end)
    retired = retired_stages()

    offenders =
      wildcard_stages()
      |> Enum.reject(&(MapSet.member?(known, &1) or MapSet.member?(retired, &1)))
      |> Enum.sort()

    assert offenders == [], """
    These stages are published somewhere under lib/fountain/ but are not in
    the webhook catalogue or the retired list:

      #{Enum.join(offenders, "\n  ")}

    A computed status kept them off the literal-pair walk above. Add them to
    `Fountain.Webhooks.Events`, and to the table in docs/reference/webhooks.md.
    """
  end

  test "the catalogue names nothing the source cannot produce" do
    # The other direction. A stale entry is a documented event that never
    # arrives, which is worse than an undocumented one.
    published = MapSet.new(published_pairs(), fn {s, st} -> Events.type(s, st) end)
    non_literal = non_literal_status_stages()

    # `turn.done`/`turn.failed` and `checkpoint.done`/`checkpoint.failed` come
    # from call sites whose status is a variable, so the literal-pair regex
    # cannot see them. A catalogue entry counts as producible when either its
    # exact pair is literally published, or its stage has at least one
    # call site the literal regex could not read the status of. A stage that
    # appears at no call site at all is in neither set, so it still fails.
    stale =
      Events.types()
      |> Enum.reject(fn type ->
        MapSet.member?(published, type) or MapSet.member?(non_literal, stage_of(type))
      end)

    assert stale == [],
           "these catalogue entries match no publish_stage call site: #{inspect(stale)}"
  end

  defp stage_of(type) do
    ["conversation", stage, _status] = String.split(type, ".")
    stage
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
