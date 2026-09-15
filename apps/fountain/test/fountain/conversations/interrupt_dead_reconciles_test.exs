defmodule Fountain.Conversations.InterruptDeadReconcilesTest do
  use Fountain.DataCase, async: true
  use Mimic

  import Ecto.Query

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.{Interruption, Sandbox}
  alias Fountain.Repo

  # #2175 open decision 1 (Jake, 2026-09-15): interrupting a conversation
  # whose server is dead and whose sandbox can no longer be reused reconciles
  # the orphaned turn; it never provisions a new sandbox on the interrupt's
  # behalf. Before this, `wake_conversation_for/3` treated `:interrupt` the
  # same as `:work` on a `:create_new` probe, so an interrupt on a dead
  # conversation paid to provision a fresh sprite and then timed out to
  # `{:error, :provisioning}` — no test covered that arm.

  test "interrupting a dead conversation with no reusable sandbox reconciles the turn, not provisions" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    # A terminal-status sandbox makes maybe_reuse_sandbox/1 fall straight to
    # :create_new without any provider probe (the same shape the reaper and
    # a dead machine leave behind).
    sandbox = insert_sandbox(user_id: user.id, status: "terminated")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "running"
      )

    turn = insert_turn(conv, status: "running")

    sandbox_count_before = Repo.aggregate(Sandbox, :count)

    reject(&Horde.DynamicSupervisor.start_child/2)

    assert {:error, :not_running} = Interruption.interrupt(conv.id)

    reloaded_turn = Repo.reload!(turn)
    assert reloaded_turn.status == "interrupted"
    refute is_nil(reloaded_turn.orphaned_at)

    reloaded_conv = Repo.reload!(conv)
    assert reloaded_conv.status == "idle"

    assert Repo.aggregate(Sandbox, :count) == sandbox_count_before

    refute Repo.exists?(
             from e in Audit.Event,
               where:
                 e.resource_id == ^conv.id and
                   e.action == "conversation.interrupted"
           )
  end

  test "the same dead-sandbox shape still provisions fresh for a plain prompt (:work)" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "terminated")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "idle"
      )

    owner = self()

    stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
      send(owner, :start_child_called)
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)

    assert {:ok, woken} = Conversations.wake_conversation(conv.id)
    assert_received :start_child_called
    assert woken.sandbox_id != sandbox.id
  end
end
