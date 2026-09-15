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

    test "a stale claim is side-effect-free: it reports recovery, not reuse" do
      # #2286 round 5 finding 4: maybe_reuse_sandbox/1 does no provider I/O
      # and no write of its own. Recovery is compute, gated by the caller
      # before it runs at all.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      at = stale_claim()

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          machine_name: "test-park-claim-stale-probe",
          park_claimed_at: at
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      reject(&Managoat.Sandbox.Sprites.get/1)
      reject(&Managoat.Sandbox.Sprites.resume/1)

      assert {:recover_stale_park, sandbox_id, ^at} = Wake.maybe_reuse_sandbox(conv)
      assert sandbox_id == sandbox.id

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

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      refute match?({:error, :sandbox_parking}, Wake.wake_conversation(conv.id))

      reloaded = Repo.reload!(sandbox)
      refute reloaded.park_claimed_at
      refute reloaded.last_resumed_at
      assert reloaded.woken_at
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

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      # last_resumed_at is :utc_datetime (second precision); truncate the
      # same way to compare fairly.
      before = DateTime.utc_now() |> DateTime.truncate(:second)

      refute match?({:error, _}, Wake.wake_conversation(conv.id))
      assert_received {:resumed, _handle}

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      refute reloaded.park_claimed_at
      assert reloaded.last_resumed_at
      assert DateTime.compare(reloaded.last_resumed_at, before) in [:gt, :eq]
      assert reloaded.woken_at
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

  describe "the suspended-account gate runs before recovery (#2286 round 5 finding 4)" do
    test "a suspended account's wake onto a stale-claimed row is refused, and recovery never runs" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          machine_name: "test-park-claim-suspended-account",
          park_claimed_at: stale_claim()
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      user
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      reject(&Managoat.Sandbox.Sprites.get/1)
      reject(&Managoat.Sandbox.Sprites.resume/1)
      reject(&Horde.DynamicSupervisor.start_child/2)

      assert {:error, :account_suspended} = Wake.wake_conversation(conv.id)

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      assert reloaded.park_claimed_at
    end
  end

  describe "recovery is a serialized takeover with an exact-stamp CAS (#2286 round 5 finding 1)" do
    test "a fresh reaper claim (T1) wins the takeover lock before this wake's stale observation (T0) reaches it" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      t0 = stale_claim()

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          machine_name: "test-park-claim-t0-t1",
          park_claimed_at: t0
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      assert {:recover_stale_park, sandbox_id, ^t0} = Wake.maybe_reuse_sandbox(conv)
      assert sandbox_id == sandbox.id

      # A fresh reaper claim (T1) — live, not stale — wins the race for the
      # takeover lock before this wake's recovery reaches it.
      t1 = DateTime.utc_now()
      {:ok, _} = Conversations.update_sandbox(sandbox, %{park_claimed_at: t1})

      reject(&Managoat.Sandbox.Sprites.get/1)
      reject(&Managoat.Sandbox.Sprites.resume/1)
      reject(&Horde.DynamicSupervisor.start_child/2)

      assert {:error, :sandbox_parking} = Wake.wake_conversation(conv.id)

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      assert reloaded.park_claimed_at == t1
    end
  end

  describe "the final locked re-read validates full admissibility (#2286 round 5 finding 3)" do
    test "a reset fence winning the lock after the probe refuses the wake and starts no server" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :running, raw: %{name: sandbox.machine_name}}}
      end)

      reject(&Horde.DynamicSupervisor.start_child/2)

      # check_spend/1 runs after maybe_reuse_sandbox/1's probe (which sees
      # no claim, no fence) and before the locked re-read — the same
      # window the round 4 wake-registration regression used, here landing
      # a reset fence instead of a park claim.
      stub(Fountain.Billing, :check_spend, fn _user_id ->
        Ecto.Changeset.change(sandbox, reset_requested_at: DateTime.utc_now())
        |> Repo.update!()

        :ok
      end)

      assert {:error, :sandbox_reset_pending} = Wake.wake_conversation(conv.id)

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      assert reloaded.reset_requested_at
    end

    test "a teardown fence winning the lock after the probe refuses the wake and starts no server" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :running, raw: %{name: sandbox.machine_name}}}
      end)

      reject(&Horde.DynamicSupervisor.start_child/2)

      stub(Fountain.Billing, :check_spend, fn _user_id ->
        now = DateTime.utc_now()

        Ecto.Changeset.change(sandbox,
          reset_requested_at: now,
          teardown_requested_at: now
        )
        |> Repo.update!()

        :ok
      end)

      assert {:error, :sandbox_reset_pending} = Wake.wake_conversation(conv.id)

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      assert reloaded.teardown_requested_at
    end

    test "recovery's fallback never turns a missing row into reuse" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      t0 = stale_claim()

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          machine_name: "test-park-claim-missing",
          park_claimed_at: t0
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      assert {:recover_stale_park, sandbox_id, ^t0} = Wake.maybe_reuse_sandbox(conv)
      assert sandbox_id == sandbox.id

      Repo.delete!(sandbox)

      reject(&Managoat.Sandbox.Sprites.get/1)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      refute match?({:error, :sandbox_parking}, Wake.wake_conversation(conv.id))
      assert Conversations._unsafe_get_sandbox(sandbox_id) == nil
    end

    test "recovery's fallback maps a terminal row to :create_new, never reuse" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      t0 = stale_claim()

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          machine_name: "test-park-claim-terminal",
          park_claimed_at: t0
        )

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      assert {:recover_stale_park, sandbox_id, ^t0} = Wake.maybe_reuse_sandbox(conv)
      assert sandbox_id == sandbox.id

      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "terminated"})

      reject(&Managoat.Sandbox.Sprites.get/1)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      refute match?({:error, :sandbox_parking}, Wake.wake_conversation(conv.id))

      refute Repo.reload!(sandbox).id ==
               Conversations.get_conversation(conv.id, user.id).sandbox_id
    end
  end
end
