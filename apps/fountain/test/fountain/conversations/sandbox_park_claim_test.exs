defmodule Fountain.Conversations.SandboxParkClaimTest do
  @moduledoc """
  The reaper's durable park claim (#2286 round 3): a `ready` sandbox with a
  live `park_claimed_at` refuses a wake or an attach retryably
  (`{:error, :sandbox_parking}`) rather than racing the reaper's provider
  suspend call, which runs outside any database lock. A stale claim (older
  than `Lifecycle.park_claim_ttl/0`) is ignored — the caller proceeds
  exactly as it would with no claim at all.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{Launch, Lifecycle, Wake}

  defp live_claim, do: DateTime.utc_now()

  defp stale_claim,
    do: DateTime.add(DateTime.utc_now(), -(Lifecycle.park_claim_ttl() + 60), :second)

  describe "Wake.maybe_reuse_sandbox/1 honours a park claim" do
    test "a live claim refuses with {:error, :sandbox_parking} and touches nothing" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          machine_name: "test-park-claim-live",
          park_claimed_at: live_claim()
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      reject(&Horde.DynamicSupervisor.start_child/2)
      reject(&Managoat.Sandbox.resume/1)
      reject(&Managoat.Sandbox.Sprites.get/1)

      assert {:error, :sandbox_parking} = Wake.maybe_reuse_sandbox(conv)
      assert {:error, :sandbox_parking} = Wake.wake_conversation(conv.id)

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      assert reloaded.park_claimed_at
    end

    test "a stale claim is ignored — the wake probes exactly as with no claim" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          machine_name: "test-park-claim-stale",
          park_claimed_at: stale_claim()
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :running, raw: %{name: "test-park-claim-stale"}}}
      end)

      assert {:reuse, sandbox_id} = Wake.maybe_reuse_sandbox(conv)
      assert sandbox_id == sandbox.id

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      refute match?({:error, :sandbox_parking}, Wake.wake_conversation(conv.id))
    end
  end

  describe "Launch attach honours a park claim" do
    test "attaching onto a live-claimed sandbox is refused with :sandbox_parking" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          machine_name: "test-park-claim-attach-live",
          agent_id: agent.id,
          environment_id: agent.environment_id,
          park_claimed_at: live_claim()
        )

      assert {:error, :sandbox_parking} =
               Launch.start_conversation(%{
                 "sandbox_id" => sandbox.id,
                 "user_id" => user.id,
                 "agent_id" => agent.id
               })

      assert Conversations._unsafe_get_sandbox(sandbox.id).status == "ready"
    end

    test "attaching onto a stale-claimed sandbox proceeds" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          machine_name: "test-park-claim-attach-stale",
          agent_id: agent.id,
          environment_id: agent.environment_id,
          park_claimed_at: stale_claim()
        )

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      assert {:ok, attached} =
               Launch.start_conversation(%{
                 "sandbox_id" => sandbox.id,
                 "user_id" => user.id,
                 "agent_id" => agent.id
               })

      assert attached.sandbox_id == sandbox.id
    end
  end
end
