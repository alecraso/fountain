defmodule Fountain.Workers.SandboxReaperLockOrderTest do
  @moduledoc """
  The reaper's terminal writes (#2255 decision 3) take the same advisory xact
  lock admission does (`Fountain.Conversations.with_sandbox_lock/2`), so they
  cannot race an admission holding it. But holding the same lock is not
  enough on its own: a reaper pass reads its candidates and their liveness
  and activity *before* it ever reaches the lock, so a fresh admission that
  wins the race and commits between that read and the reaper's own turn at
  the lock must not be overwritten by a now-stale verdict — the review that
  found this called it out directly (adversarial review on #2286).

  Each "admission wins" case here holds the sandbox's advisory lock on an
  independent connection, and — still holding it — commits (or, for
  liveness, simply makes true) exactly what a concurrent admission would:
  a status/`updated_at` change out of the stuck window for the stuck-release
  path; a running conversation and turn with fresh activity for the idle
  path, which the idle bound measures against; and a freshly registered
  `ConversationServer` for the max-lifetime path, whose clock is anchored to
  `inserted_at`/`last_resumed_at` and so is not reset by activity alone.
  Releasing the lock then lets the reaper's own turn proceed, and each case
  asserts the reaper left the row (and any turn) untouched, recorded no
  audit, and — for the idle path — made no provider call.

  Each "unaffected" case holds the same lock but changes nothing under it,
  and asserts the write still happens exactly as it did before revalidation
  was added — the behaviour this file existed to prove in the first place.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox, as: DBSandbox
  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Sandbox, Turn, Wake}
  alias Fountain.Repo
  alias Fountain.Workers.SandboxReaper

  setup :set_mimic_global

  @lock_namespace 4316

  defp minutes_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n * 60, :second) |> DateTime.truncate(:second)

  defp age_sandbox(sandbox, minutes) do
    ts = minutes_ago(minutes)
    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [updated_at: ts])
    %{sandbox | updated_at: ts}
  end

  defp age_ready_sandbox(sandbox, conv, minutes) do
    ts = minutes_ago(minutes)

    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
      set: [inserted_at: ts, updated_at: ts]
    )

    Repo.update_all(from(t in Turn, where: t.conversation_id == ^conv.id), set: [inserted_at: ts])

    Repo.reload!(sandbox)
  end

  defp with_bounds(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  # Takes the same advisory lock `Conversations.with_sandbox_lock/2` does, on
  # an independent connection, runs `commit` while still holding it (a no-op
  # by default), then holds the lock open until told to release — the same
  # shape `channel_allowance_lock_order_test.exs` and
  # `termination_attach_order_test.exs` use to prove a write waits on it.
  defp hold_lock(sandbox_id, owner, commit) do
    Task.async(fn ->
      DBSandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:holder_backend, backend})

        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
            @lock_namespace,
            :erlang.phash2(sandbox_id)
          ])

          commit.()
          send(owner, :locked)

          receive do
            :release -> :ok
          after
            10_000 -> raise "lock not released"
          end
        end)
      end)
    end)
  end

  defp run_reaper(owner, fun) do
    Task.async(fn ->
      DBSandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:reaper_backend, backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(waiter, holder, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT $2 = ANY(pg_blocking_pids($1))", [waiter, holder])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "no wait on the winning PostgreSQL connection observed"

      Process.sleep(5)
      await_blocked(waiter, holder, deadline)
    end
  end

  # Starts the holder and the reaper, waits until the reaper is genuinely
  # blocked on the holder's connection, hands control to `during` for
  # mid-block assertions, releases the holder, then returns
  # `{reaper_result, holder_result}` for post-release assertions.
  defp race(sandbox_id, commit, reaper_fun, during) do
    owner = self()
    holder = hold_lock(sandbox_id, owner, commit)
    assert_receive {:holder_backend, holder_backend}, 5_000
    assert_receive :locked, 5_000

    reaper = run_reaper(owner, reaper_fun)

    try do
      assert_receive {:reaper_backend, reaper_backend}, 5_000
      await_blocked(reaper_backend, holder_backend, System.monotonic_time(:millisecond) + 5_000)
      during.()
      send(holder.pid, :release)
      {Task.await(reaper, 5_000), Task.await(holder, 5_000)}
    after
      Task.shutdown(reaper, :brutal_kill)
      Task.shutdown(holder, :brutal_kill)
    end
  end

  defp sandbox_audit(user_id) do
    Fountain.Audit.list_for_user(user_id, action_prefix: "sandbox.")
  end

  describe "stuck release" do
    test "nothing changes under the lock: the stuck write still happens" do
      DBSandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        sandbox = insert_sandbox(user_id: user.id, status: "starting") |> age_sandbox(120)

        {reaper_result, holder_result} =
          race(sandbox.id, fn -> :ok end, fn -> SandboxReaper.release_stuck_sandboxes() end, fn ->
            assert Repo.reload!(sandbox).status == "starting"
          end)

        assert reaper_result == 1
        assert holder_result == {:ok, :ok}
        assert %{status: "failed", terminated_at: %DateTime{}} = Repo.reload!(sandbox)
        assert [_] = sandbox_audit(user.id)

        Repo.delete_all(from s in Sandbox, where: s.id == ^sandbox.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end)
    end

    test "admission wins: a sandbox that finished provisioning under the lock is left alone" do
      DBSandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        sandbox = insert_sandbox(user_id: user.id, status: "starting") |> age_sandbox(120)

        commit = fn ->
          # What admission/provisioning finishing would commit while holding
          # this same lock: the row is no longer stuck by either measure —
          # its status left `@active_statuses` and its clock reset.
          Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
            set: [status: "ready", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
          )
        end

        {reaper_result, holder_result} =
          race(sandbox.id, commit, fn -> SandboxReaper.release_stuck_sandboxes() end, fn ->
            assert Repo.reload!(sandbox).status == "starting"
          end)

        assert reaper_result == 0
        assert holder_result == {:ok, :ok}

        reloaded = Repo.reload!(sandbox)
        assert reloaded.status == "ready"
        refute reloaded.terminated_at
        assert sandbox_audit(user.id) == []

        Repo.delete_all(from s in Sandbox, where: s.id == ^sandbox.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end)
    end
  end

  describe "idle park" do
    test "nothing changes under the lock: the park write still happens" do
      DBSandbox.unboxed_run(Repo, fn ->
        # The real Sprites.suspend/1 is a no-op ack (`def suspend(%Handle{}),
        # do: :ok`) — no stub needed for the happy path.
        user = insert_verified_user()
        sandbox = insert_sandbox(user_id: user.id, status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
        insert_turn(conv, %{status: "completed"})
        sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

        {reaper_result, holder_result} =
          with_bounds(
            [sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24],
            fn ->
              race(
                sandbox.id,
                fn -> :ok end,
                fn -> SandboxReaper.sweep_abandoned_sandboxes() end,
                fn -> assert Repo.reload!(sandbox).status == "ready" end
              )
            end
          )

        assert reaper_result == {1, 0}
        assert holder_result == {:ok, :ok}

        reloaded = Repo.reload!(sandbox)
        assert reloaded.status == "suspended"
        refute reloaded.terminated_at
        assert [_] = sandbox_audit(user.id)

        Repo.delete_all(from c in Conversation, where: c.id == ^conv.id)
        Repo.delete_all(from s in Sandbox, where: s.id == ^sandbox.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end)
    end

    test "admission wins: a sandbox admission just resumed under the lock is left alone" do
      DBSandbox.unboxed_run(Repo, fn ->
        # Proves the reaper never reaches the provider call, not just that it
        # left the row alone.
        reject(&Managoat.Sandbox.Sprites.suspend/1)

        user = insert_verified_user()
        sandbox = insert_sandbox(user_id: user.id, status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
        insert_turn(conv, %{status: "completed"})
        sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

        commit = fn ->
          # What turn admission commits while holding this same lock: the
          # conversation runs again and its turn is fresh activity.
          Repo.update_all(from(c in Conversation, where: c.id == ^conv.id),
            set: [status: "running"]
          )

          %Turn{}
          |> Turn.changeset(%{
            conversation_id: conv.id,
            turn_number: 2,
            status: "running",
            prompt: "admission wins",
            started_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
          |> Repo.insert!()
        end

        {reaper_result, holder_result} =
          with_bounds(
            [sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24],
            fn ->
              race(
                sandbox.id,
                commit,
                fn -> SandboxReaper.sweep_abandoned_sandboxes() end,
                fn -> assert Repo.reload!(sandbox).status == "ready" end
              )
            end
          )

        assert reaper_result == {0, 0}
        assert holder_result == {:ok, :ok}

        reloaded = Repo.reload!(sandbox)
        assert reloaded.status == "ready"
        refute reloaded.terminated_at
        assert Repo.reload!(conv).status == "running"

        assert [%{turn_number: 1, status: "completed"}, %{turn_number: 2} = fresh_turn] =
                 Repo.all(
                   from t in Turn, where: t.conversation_id == ^conv.id, order_by: t.turn_number
                 )

        assert fresh_turn.status == "running"
        assert sandbox_audit(user.id) == []

        Repo.delete_all(from t in Turn, where: t.conversation_id == ^conv.id)
        Repo.delete_all(from c in Conversation, where: c.id == ^conv.id)
        Repo.delete_all(from s in Sandbox, where: s.id == ^sandbox.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end)
    end

    test "admission wins: a refreshed updated_at under the lock is protected by the grace window" do
      # #2286 finding 2: the outer scan requires updated_at < grace_cutoff,
      # but the locked recheck did not, so a row bookkeeping refreshed
      # (a wake, or anything else that just touches updated_at — no new turn,
      # no live server) while the reaper waited on the lock could still be
      # parked once the lock came free. ready_abandoned?/3 now recomputes the
      # same grace cutoff fresh, from its own `now`.
      DBSandbox.unboxed_run(Repo, fn ->
        reject(&Managoat.Sandbox.Sprites.suspend/1)

        user = insert_verified_user()
        sandbox = insert_sandbox(user_id: user.id, status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
        insert_turn(conv, %{status: "completed"})
        sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

        commit = fn ->
          Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
            set: [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
          )
        end

        {reaper_result, holder_result} =
          with_bounds(
            [sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24],
            fn ->
              race(
                sandbox.id,
                commit,
                fn -> SandboxReaper.sweep_abandoned_sandboxes() end,
                fn -> assert Repo.reload!(sandbox).status == "ready" end
              )
            end
          )

        assert reaper_result == {0, 0}
        assert holder_result == {:ok, :ok}

        reloaded = Repo.reload!(sandbox)
        assert reloaded.status == "ready"
        refute reloaded.park_claimed_at
        assert sandbox_audit(user.id) == []

        Repo.delete_all(from c in Conversation, where: c.id == ^conv.id)
        Repo.delete_all(from s in Sandbox, where: s.id == ^sandbox.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end)
    end
  end

  describe "the durable park claim (#2286 round 3)" do
    test "the row carries a live claim while the provider call is in flight, then finalizes" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

      owner = self()

      stub(Managoat.Sandbox.Sprites, :suspend, fn _handle ->
        send(owner, :suspend_called)

        receive do
          :continue -> :ok
        after
          5_000 -> raise "suspend call never released"
        end
      end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        reaper = Task.async(fn -> SandboxReaper.sweep_abandoned_sandboxes() end)

        assert_receive :suspend_called, 5_000

        # The provider call is genuinely in flight: the row is not yet
        # `suspended` (that only happens once the call is known to have
        # succeeded), but it does carry this run's claim.
        mid_flight = Repo.reload!(sandbox)
        assert mid_flight.status == "ready"
        assert mid_flight.park_claimed_at

        # A wake racing this window is refused, not raced.
        assert {:error, :sandbox_parking} = Wake.maybe_reuse_sandbox(conv)

        send(reaper.pid, :continue)
        assert Task.await(reaper, 5_000) == {1, 0}
      end)

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "suspended"
      refute reloaded.park_claimed_at
      assert [%{action: "sandbox.suspended"}] = sandbox_audit(user.id)
    end

    test "a claim cleared by a competing owner while the provider call is in flight undoes the suspend (round 5 finding 1)" do
      # The claim clearing mid-flight means a wake's recovery (or a fresh
      # reaper claim) already resolved this row as legitimately active
      # while our own suspend call was still resolving — and it just
      # succeeded, so the machine we paused is one somebody else now owns.
      # A plain claim mismatch used to leave the row alone with no
      # compensation; it now undoes the suspend it just made, the same
      # way the live-server branch already did.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

      owner = self()

      stub(Managoat.Sandbox.Sprites, :suspend, fn _handle ->
        send(owner, :suspend_called)

        receive do
          :continue -> :ok
        after
          5_000 -> raise "suspend call never released"
        end
      end)

      stub(Managoat.Sandbox.Sprites, :resume, fn handle ->
        send(owner, {:resumed, handle})
        {:ok, handle}
      end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        reaper = Task.async(fn -> SandboxReaper.sweep_abandoned_sandboxes() end)

        assert_receive :suspend_called, 5_000

        # Simulating a competing owner: something else cleared this run's
        # claim while its provider call was still in flight.
        Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
          set: [park_claimed_at: nil]
        )

        send(reaper.pid, :continue)
        assert Task.await(reaper, 5_000) == {0, 0}
      end)

      assert_receive {:resumed, _handle}, 5_000

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      refute reloaded.park_claimed_at
      assert sandbox_audit(user.id) == []
    end

    test "a provider suspend failure terminates the row and clears the claim" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

      stub(Managoat.Sandbox.Sprites, :suspend, fn _handle -> {:error, :boom} end)

      result =
        with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
          SandboxReaper.sweep_abandoned_sandboxes()
        end)

      assert result == {0, 1}

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "terminated"
      refute reloaded.park_claimed_at
      assert [%{action: "sandbox.expired"}] = sandbox_audit(user.id)
    end

    test "a claim step that finds a live server writes no claim (round 4 finding 1 mirror)" do
      # The review's residual gap (finding 1) is a Horde registry that can
      # lag a fresh registration by a moment; the reaper's own claim step
      # already re-checks liveness fresh under the lock (decision 2's
      # any_server_alive?/1). This pins that it still does, now that the
      # wake side of the same race also takes the lock (finding 1b) — a
      # live server present when the claim step runs must still stop the
      # claim from being written at all.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

      reject(&Managoat.Sandbox.Sprites.suspend/1)

      stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
        if id == conv.id, do: self(), else: nil
      end)

      result =
        with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
          SandboxReaper.sweep_abandoned_sandboxes()
        end)

      assert result == {0, 0}

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      refute reloaded.park_claimed_at
    end

    test "a provider suspend failure while a server is live clears the claim without terminating (round 4 finding 1a)" do
      # The gap the review found: expire_after_failed_suspend/3 used to
      # revalidate only the claim stamp, not liveness or a reset fence —
      # unlike finalize_park/2's revalidation of a successful suspend. A
      # server that registered (a wake winning the residual Horde-registry-
      # lag race) while this failed provider call was resolving must not
      # be marked terminal and left for pass 2 to destroy.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

      stub(Managoat.Sandbox.Sprites, :suspend, fn _handle ->
        stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
          if id == conv.id, do: self(), else: nil
        end)

        {:error, :boom}
      end)

      result =
        with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
          SandboxReaper.sweep_abandoned_sandboxes()
        end)

      assert result == {0, 0}

      reloaded = Repo.reload!(sandbox)
      assert reloaded.status == "ready"
      refute reloaded.park_claimed_at
      assert sandbox_audit(user.id) == []
    end
  end

  describe "recovery is a serialized takeover with an exact-stamp CAS (#2286 round 5 finding 1)" do
    test "a reaper pass leaves a live takeover stamp alone" do
      # Recovery's takeover write (`Wake.claim_stale_park/2`) and an
      # ordinary reaper claim share the same column and the same TTL — a
      # live takeover stamp is exactly as protected against a concurrent
      # reaper claim as an ordinary one already is (round 3).
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

      takeover_stamp = DateTime.utc_now()
      {:ok, _} = Conversations.update_sandbox(sandbox, %{park_claimed_at: takeover_stamp})

      reject(&Managoat.Sandbox.Sprites.suspend/1)

      result =
        with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
          SandboxReaper.sweep_abandoned_sandboxes()
        end)

      assert result == {0, 0}
      assert Repo.reload!(sandbox).park_claimed_at == takeover_stamp
    end

    test "the reaper's own claim taken over mid-suspend: its later success undoes the suspend" do
      # (c): the reaper's suspend call succeeds after its own claim on the
      # row was superseded by a takeover (a wake's recovery, or a fresh
      # reaper claim past the TTL) — finalize_park/2 sees a claim mismatch
      # on a still-`ready` row and compensates, exactly as it does for a
      # live server.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

      owner = self()

      stub(Managoat.Sandbox.Sprites, :suspend, fn _handle ->
        send(owner, :suspend_called)

        receive do
          :continue -> :ok
        after
          5_000 -> raise "suspend call never released"
        end
      end)

      stub(Managoat.Sandbox.Sprites, :resume, fn handle ->
        send(owner, {:resumed, handle})
        {:ok, handle}
      end)

      reaper_result =
        with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
          reaper = Task.async(fn -> SandboxReaper.sweep_abandoned_sandboxes() end)
          assert_receive :suspend_called, 5_000

          # A takeover superseding the reaper's own claim, discovered late
          # — the same write claim_stale_park/2 makes.
          {:ok, _} = Conversations.update_sandbox(sandbox, %{park_claimed_at: DateTime.utc_now()})

          send(reaper.pid, :continue)
          Task.await(reaper, 5_000)
        end)

      assert reaper_result == {0, 0}
      assert_receive {:resumed, _handle}, 5_000
      assert Repo.reload!(sandbox).status == "ready"
    end
  end

  describe "a durable wake marker the reaper can see (#2286 round 5 finding 2)" do
    test "a fresh woken_at keeps a row off both reaper passes even with a stale registry view" do
      # ConversationServer.whereis/1 stubbed to nil the whole time: this is
      # exactly what a Horde registry that has not yet propagated to the
      # reaper's node looks like. woken_at, a database fact, is what keeps
      # the row off the reaper here — not liveness.
      stub(Fountain.Conversations.ConversationServer, :whereis, fn _id -> nil end)

      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

      # A raw update — see the note in the next test on why writing
      # woken_at through Conversations.update_sandbox/2 would confound
      # this with the updated_at check it sits beside.
      Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
        set: [woken_at: DateTime.utc_now()]
      )

      reject(&Managoat.Sandbox.Sprites.suspend/1)

      result =
        with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
          SandboxReaper.sweep_abandoned_sandboxes()
        end)

      assert result == {0, 0}
      assert Repo.reload!(sandbox).status == "ready"
    end

    test "a woken_at older than the grace window is eligible again" do
      stub(Fountain.Conversations.ConversationServer, :whereis, fn _id -> nil end)

      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_ready_sandbox(sandbox, conv, 60 * 5)

      # A raw update: writing woken_at through Conversations.update_sandbox/2
      # would also bump updated_at (Ecto's own timestamp), which alone
      # would exclude this row from the outer scan and defeat the point —
      # isolate the woken_at check from the updated_at one it sits beside.
      stale_woken_at = DateTime.add(DateTime.utc_now(), -30 * 60, :second)

      Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
        set: [woken_at: stale_woken_at]
      )

      result =
        with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
          SandboxReaper.sweep_abandoned_sandboxes()
        end)

      assert result == {1, 0}
      assert Repo.reload!(sandbox).status == "suspended"
    end

    test "a fresh woken_at also keeps a stuck-mid-provision row off release_stuck_sandboxes/0" do
      # stuck_eligible?/2 reads the same woken_at gate — defensively, since
      # nothing on the current provisioning path stamps it on a
      # pending/starting row, but the predicate itself must not silently
      # skip the check just because this shape has not been observed yet.
      stub(Fountain.Conversations.ConversationServer, :whereis, fn _id -> nil end)

      sandbox = insert_sandbox(status: "starting") |> age_sandbox(120)

      Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
        set: [woken_at: DateTime.utc_now()]
      )

      assert SandboxReaper.release_stuck_sandboxes() == 0
      assert Repo.reload!(sandbox).status == "starting"
    end
  end

  describe "chronological, not structural, DateTime comparison (#2286 finding 3)" do
    test "DateTime.before?/2 is not fooled by a day-of-month inversion across a month boundary" do
      # Elixir compares two DateTime STRUCTS with `<` field-by-field in
      # alphabetical key order, so :day is compared before :month and
      # :year — Sept 30 (day 30) then reads as "greater than" Oct 1
      # (day 1) though it is chronologically earlier. stuck_eligible?/2 and
      # ready_abandoned?/3 (both private; this is the comparison itself,
      # the same one they call verbatim) use DateTime.before?/2 instead,
      # never `<`, for exactly this reason.
      earlier = ~U[2026-09-30 12:00:00.000000Z]
      later = ~U[2026-10-01 00:00:00.000000Z]

      refute earlier < later

      assert DateTime.before?(earlier, later)
      refute DateTime.before?(later, earlier)
    end
  end

  describe "expiry" do
    test "nothing changes under the lock: the expire write still happens" do
      DBSandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        sandbox = insert_sandbox(user_id: user.id, status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
        insert_turn(conv, %{status: "completed"})
        sandbox = age_ready_sandbox(sandbox, conv, 60 * 24 * 83)

        {reaper_result, holder_result} =
          with_bounds(
            [sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24],
            fn ->
              race(
                sandbox.id,
                fn -> :ok end,
                fn -> SandboxReaper.sweep_abandoned_sandboxes() end,
                fn -> assert Repo.reload!(sandbox).status == "ready" end
              )
            end
          )

        assert reaper_result == {0, 1}
        assert holder_result == {:ok, :ok}
        assert Repo.reload!(sandbox).status == "terminated"
        assert Repo.reload!(conv).status == "idle"
        assert [_] = sandbox_audit(user.id)

        Repo.delete_all(from c in Conversation, where: c.id == ^conv.id)
        Repo.delete_all(from s in Sandbox, where: s.id == ^sandbox.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end)
    end

    test "admission wins: a server that registered under the lock is left unexpired" do
      # The max-lifetime clock is anchored to `inserted_at`/`last_resumed_at`
      # (a continuous run), not last activity — a fresh turn alone would not
      # reset it, so the race worth proving here is liveness: a server that
      # registers (a reattach in flight) between the scan and the lock, which
      # is exactly what `Lifecycle.any_server_alive?/1` exists to catch fresh.
      DBSandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        sandbox = insert_sandbox(user_id: user.id, status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
        insert_turn(conv, %{status: "completed"})
        sandbox = age_ready_sandbox(sandbox, conv, 60 * 24 * 83)

        {reaper_result, holder_result} =
          with_bounds(
            [sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24],
            fn ->
              race(
                sandbox.id,
                fn -> :ok end,
                fn -> SandboxReaper.sweep_abandoned_sandboxes() end,
                fn ->
                  assert Repo.reload!(sandbox).status == "ready"

                  # Mimic's global mode only lets the test process itself
                  # define a stub, so this runs here rather than inside the
                  # holder task — timed exactly the same way regardless: the
                  # reaper's scan has already run and it is already blocked
                  # on the lock, so this is "the server registered while we
                  # were waiting," not "before we ever looked."
                  stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
                    if id == conv.id, do: self(), else: nil
                  end)
                end
              )
            end
          )

        assert reaper_result == {0, 0}
        assert holder_result == {:ok, :ok}
        assert Repo.reload!(sandbox).status == "ready"
        refute Repo.reload!(sandbox).terminated_at
        assert Repo.reload!(conv).status == "idle"
        assert sandbox_audit(user.id) == []

        Repo.delete_all(from c in Conversation, where: c.id == ^conv.id)
        Repo.delete_all(from s in Sandbox, where: s.id == ^sandbox.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end)
    end
  end
end
