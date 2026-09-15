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

    test "a stale claim with the provider running is dropped without a resume" do
      # #2286 round 4 finding 2: a stale claim is not just ignored — it is
      # reconciled against the provider. Running means the reaper's suspend
      # call never reached (or never finished) the provider before that run
      # ended; there is nothing to undo, just a bogus claim to drop.
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

      reject(&Managoat.Sandbox.Sprites.resume/1)

      assert {:reuse, sandbox_id} = Wake.maybe_reuse_sandbox(conv)
      assert sandbox_id == sandbox.id

      reloaded = Repo.reload!(sandbox)
      refute reloaded.park_claimed_at
      refute reloaded.last_resumed_at

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      refute match?({:error, :sandbox_parking}, Wake.wake_conversation(conv.id))
    end

    test "a stale claim with the provider suspended resumes the machine and restarts the clock" do
      # The crash-after-suspend case: the reaper's provider suspend call
      # actually succeeded before that run ended without finalizing. The
      # machine is genuinely parked; this is the resume it never got to
      # record, so last_resumed_at restarts the max-lifetime clock rather
      # than silently including the parked interval.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          machine_name: "test-park-claim-crash",
          park_claimed_at: stale_claim()
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :suspended, raw: %{name: "test-park-claim-crash"}}}
      end)

      test_pid = self()

      stub(Managoat.Sandbox.Sprites, :resume, fn handle ->
        send(test_pid, {:resumed, handle})
        {:ok, handle}
      end)

      # last_resumed_at is :utc_datetime (second precision); truncate the
      # same way to compare fairly.
      before = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:reuse, sandbox_id} = Wake.maybe_reuse_sandbox(conv)
      assert sandbox_id == sandbox.id
      assert_received {:resumed, _handle}

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      refute reloaded.park_claimed_at
      assert reloaded.last_resumed_at
      assert DateTime.compare(reloaded.last_resumed_at, before) in [:gt, :eq]
    end
  end

  describe "the wake-check-to-registration window (#2286 round 4 finding 1b)" do
    test "a claim written after maybe_reuse_sandbox/1's own check is still caught before registering" do
      # maybe_reuse_sandbox/1's check ran and passed — no claim existed yet.
      # wake_conversation_for/3 then runs check_not_suspended, check_spend,
      # check_saved_inference and wake_suspended_sandbox/2 before ever
      # reaching the locked registration; stubbing check_spend to write the
      # claim mid-flight, as a side effect, simulates the reaper's claim
      # step landing in exactly that window — the same real gap the review
      # found, without depending on real inter-process timing to reproduce.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :running, raw: %{name: sandbox.machine_name}}}
      end)

      assert {:reuse, _} = Wake.maybe_reuse_sandbox(conv)

      reject(&Horde.DynamicSupervisor.start_child/2)

      stub(Fountain.Billing, :check_spend, fn _user_id ->
        {:ok, _} = Conversations.update_sandbox(sandbox, %{park_claimed_at: DateTime.utc_now()})
        :ok
      end)

      assert {:error, :sandbox_parking} = Wake.wake_conversation(conv.id)

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      assert reloaded.park_claimed_at
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
