defmodule Fountain.Workers.SandboxReaperLockOrderTest do
  @moduledoc """
  The reaper's terminal writes (#2255 decision 3) take the same advisory xact
  lock admission does (`Fountain.Conversations.with_sandbox_lock/2`), so they
  cannot race an admission holding it. Each case here holds that lock on an
  independent connection first, then runs the reaper pass that would touch
  the locked sandbox and shows its write is blocked at the database — not
  merely slow — until the lock is released, landing in the same state the
  pass produced before this change.
  """

  use Fountain.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox, as: DBSandbox
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Workers.SandboxReaper

  @lock_namespace 4316

  defp minutes_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n * 60, :second) |> DateTime.truncate(:second)

  defp age_sandbox(sandbox, minutes) do
    ts = minutes_ago(minutes)
    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [updated_at: ts])
    %{sandbox | updated_at: ts}
  end

  test "release_stuck_sandboxes waits for another holder's advisory lock" do
    DBSandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "starting") |> age_sandbox(120)
      owner = self()

      holder = hold_lock(sandbox.id, owner)
      assert_receive {:holder_backend, holder_backend}, 5_000
      assert_receive :locked, 5_000

      reaper =
        Task.async(fn ->
          DBSandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(owner, {:reaper_backend, backend})
            SandboxReaper.release_stuck_sandboxes()
          end)
        end)

      try do
        assert_receive {:reaper_backend, reaper_backend}, 5_000

        await_blocked(
          reaper_backend,
          holder_backend,
          System.monotonic_time(:millisecond) + 5_000
        )

        # Blocked at the database, not merely slow: the write has not
        # committed while the lock is held.
        assert Repo.reload!(sandbox).status == "starting"

        send(holder.pid, :release)

        assert Task.await(reaper, 5_000) == 1
        assert Task.await(holder, 5_000) == {:ok, :ok}

        assert %{status: "failed", terminated_at: %DateTime{}} = Repo.reload!(sandbox)
      after
        Task.shutdown(reaper, :brutal_kill)
        Task.shutdown(holder, :brutal_kill)
        Repo.delete_all(from s in Sandbox, where: s.id == ^sandbox.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end
    end)
  end

  test "sweep_abandoned_sandboxes' park write waits for another holder's advisory lock" do
    DBSandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})

      ts = minutes_ago(60 * 5)

      Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
        set: [inserted_at: ts, updated_at: ts]
      )

      Repo.update_all(
        from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
        set: [inserted_at: ts]
      )

      previous = Application.get_env(:fountain, :sandbox_idle_timeout_minutes)
      previous_lifetime = Application.get_env(:fountain, :sandbox_max_lifetime_hours)
      Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 60)
      Application.put_env(:fountain, :sandbox_max_lifetime_hours, 24)

      owner = self()

      holder = hold_lock(sandbox.id, owner)
      assert_receive {:holder_backend, holder_backend}, 5_000
      assert_receive :locked, 5_000

      reaper =
        Task.async(fn ->
          DBSandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(owner, {:reaper_backend, backend})
            SandboxReaper.sweep_abandoned_sandboxes()
          end)
        end)

      try do
        assert_receive {:reaper_backend, reaper_backend}, 5_000

        await_blocked(
          reaper_backend,
          holder_backend,
          System.monotonic_time(:millisecond) + 5_000
        )

        assert Repo.reload!(sandbox).status == "ready"

        send(holder.pid, :release)

        assert Task.await(reaper, 5_000) == {1, 0}
        assert Task.await(holder, 5_000) == {:ok, :ok}

        reloaded = Repo.reload!(sandbox)
        assert reloaded.status == "suspended"
        refute reloaded.terminated_at
      after
        Task.shutdown(reaper, :brutal_kill)
        Task.shutdown(holder, :brutal_kill)
        Application.put_env(:fountain, :sandbox_idle_timeout_minutes, previous)
        Application.put_env(:fountain, :sandbox_max_lifetime_hours, previous_lifetime)
        Repo.delete_all(from c in Fountain.Conversations.Conversation, where: c.id == ^conv.id)
        Repo.delete_all(from s in Sandbox, where: s.id == ^sandbox.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end
    end)
  end

  # Takes the same advisory lock `Conversations.with_sandbox_lock/2` does, on
  # an independent connection, and holds it until told to release — the same
  # shape `channel_allowance_lock_order_test.exs` and
  # `termination_attach_order_test.exs` use to prove a write waits on it.
  defp hold_lock(sandbox_id, owner) do
    Task.async(fn ->
      DBSandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:holder_backend, backend})

        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
            @lock_namespace,
            :erlang.phash2(sandbox_id)
          ])

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

  defp await_blocked(waiter, holder, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT $2 = ANY(pg_blocking_pids($1))", [waiter, holder])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "no wait on the winning PostgreSQL connection observed"

      Process.sleep(5)
      await_blocked(waiter, holder, deadline)
    end
  end
end
