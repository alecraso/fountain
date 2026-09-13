defmodule Fountain.AgentSourceDeletionTest do
  use Fountain.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.{Agents, Audit, Environments, Vaults}
  alias Fountain.Agents.Agent

  test "environment deletion snapshots only changed owned agents and preserves history" do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    keep = insert_env(user_id: user.id)

    both =
      insert_agent(
        user_id: user.id,
        environment_id: env.id,
        allowed_environment_ids: [env.id, keep.id]
      )

    default = insert_agent(user_id: user.id, environment_id: env.id)
    allowlisted = insert_agent(user_id: user.id, allowed_environment_ids: [env.id])

    unaffected =
      insert_agent(user_id: user.id, environment_id: keep.id, allowed_environment_ids: [])

    unrestricted = insert_agent(user_id: user.id)
    cotenant = insert_agent(allowed_environment_ids: [env.id])
    originals = Map.new([both, default, allowlisted], &{&1.id, versions(&1)})

    assert {:ok, _} = Environments.delete_environment(env, actor: "api")
    assert Repo.reload!(both).environment_id == nil
    assert Repo.reload!(both).allowed_environment_ids == [keep.id]
    assert Repo.reload!(default).allowed_environment_ids == nil
    assert Repo.reload!(allowlisted).allowed_environment_ids == []

    for agent <- [both, default, allowlisted] do
      assert [latest | history] = versions(agent)
      assert latest.version == 2
      assert latest.config == Agents.snapshot_config(Repo.reload!(agent))
      assert history == originals[agent.id]
      assert [audit] = updates(agent)
      assert audit.actor == "api"

      assert audit.metadata["changed"] in [
               ["allowed_environment_ids", "environment_id"],
               ["environment_id"],
               ["allowed_environment_ids"]
             ]
    end

    for agent <- [unaffected, unrestricted, cotenant] do
      assert Agents.snapshot_config(Repo.reload!(agent)) == Agents.snapshot_config(agent)
      assert [_] = versions(agent)
      assert updates(agent) == []
    end

    # A stale form's unrelated edit cannot attribute this cleanup to itself.
    assert {:ok, edited} = Agents.update_agent(both, %{description: "later edit"})
    assert [v3, v2, _] = versions(both)
    assert v3.config == Agents.snapshot_config(edited)
    assert v3.config["environment_id"] == v2.config["environment_id"]
    assert v3.config["allowed_environment_ids"] == v2.config["allowed_environment_ids"]
  end

  test "vault deletion preserves empty versus unrestricted access and snapshots generated access" do
    user = insert_verified_user()
    vault = insert_vault(user_id: user.id)
    keep = insert_vault(user_id: user.id)
    only = insert_agent(user_id: user.id, allowed_vault_ids: [vault.id])
    mixed = insert_agent(user_id: user.id, allowed_vault_ids: [vault.id, keep.id])
    unrestricted = insert_agent(user_id: user.id)
    empty = insert_agent(user_id: user.id, allowed_vault_ids: [])
    cotenant = insert_agent(allowed_vault_ids: [vault.id])

    assert {:ok, _} = Vaults.delete_vault(vault)
    assert Repo.reload!(only).allowed_vault_ids == []
    assert Repo.reload!(mixed).allowed_vault_ids == [keep.id]

    for agent <- [only, mixed] do
      assert [latest, old] = versions(agent)
      assert latest.config == Agents.snapshot_config(Repo.reload!(agent))
      assert latest.vault_access == "allowlist"
      assert Repo.reload!(agent).vault_access == "allowlist"
      assert vault.id in old.config["allowed_vault_ids"]
    end

    for agent <- [unrestricted, empty, cotenant] do
      assert Agents.snapshot_config(Repo.reload!(agent)) == Agents.snapshot_config(agent)
      assert [_] = versions(agent)
      assert updates(agent) == []
    end
  end

  test "reference cleanup does not revalidate unrelated historical runtime settings" do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, environment_id: env.id)
    agent |> change(runtime: "historical-disabled-runtime") |> Repo.update!()

    assert {:ok, _} = Environments.delete_environment(env)
    current = Repo.reload!(agent)
    assert current.runtime == "historical-disabled-runtime"
    assert current.environment_id == nil
    assert [latest, _] = versions(agent)
    assert latest.config == Agents.snapshot_config(current)
  end

  for failure <- [:source_delete, :version_insert] do
    test "#{failure} failure rolls back source, references, snapshots and audits" do
      Sandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        env = insert_env(user_id: user.id)
        agent = insert_agent(user_id: user.id, environment_id: env.id)

        try do
          case unquote(failure) do
            :source_delete ->
              Repo.query!(
                "CREATE TABLE source_delete_blocker (id uuid REFERENCES environments(id))"
              )

              Repo.query!("INSERT INTO source_delete_blocker VALUES ($1)", [
                Ecto.UUID.dump!(env.id)
              ])

            :version_insert ->
              Repo.query!(
                "ALTER TABLE agent_versions ADD CONSTRAINT source_version_failure CHECK (version < 2) NOT VALID"
              )
          end

          assert_raise Ecto.ConstraintError, fn -> Environments.delete_environment(env) end
          assert Repo.reload!(env)
          assert Agents.snapshot_config(Repo.reload!(agent)) == Agents.snapshot_config(agent)
          assert [_] = versions(agent)
          assert updates(agent) == []

          refute Repo.exists?(
                   from a in Audit.Event,
                     where: a.resource_id == ^env.id and a.action == "environment.deleted"
                 )
        after
          case unquote(failure) do
            :source_delete ->
              Repo.query!("DROP TABLE IF EXISTS source_delete_blocker")

            :version_insert ->
              Repo.query!(
                "ALTER TABLE agent_versions DROP CONSTRAINT IF EXISTS source_version_failure"
              )
          end

          cleanup(user)
        end
      end)
    end
  end

  for phase <- ["environments", "agents"] do
    test "an edit racing deletion at the #{phase} lock keeps the newest snapshot current" do
      Sandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        env = insert_env(user_id: user.id)
        agent = insert_agent(user_id: user.id, environment_id: env.id)
        deleting = independent(fn -> Environments.delete_environment(env) end, unquote(phase))

        try do
          assert_receive {:backend, deleting_pid, deleting_backend}, 5_000
          assert deleting_pid == deleting.pid
          assert_receive {:locked, ^deleting_pid}, 5_000

          editing =
            independent(fn -> Agents.update_agent(agent, %{description: "concurrent edit"}) end)

          try do
            assert_receive {:backend, editing_pid, editing_backend}, 5_000
            assert editing_pid == editing.pid

            if unquote(phase) == "agents" do
              await_blocked(editing_backend, deleting_backend)
            else
              assert {:ok, _} = Task.await(editing, 5_000)
            end

            send(deleting.pid, :continue)
            assert {:ok, _} = Task.await(deleting, 5_000)
            if unquote(phase) == "agents", do: assert({:ok, _} = Task.await(editing, 5_000))
            current = Repo.reload!(agent)
            assert current.environment_id == nil
            assert current.description == "concurrent edit"
            assert [v3, v2, v1] = versions(agent)
            assert {v3.version, v2.version, v1.version} == {3, 2, 1}
            assert v3.config == Agents.snapshot_config(current)
          after
            Task.shutdown(editing, :brutal_kill)
          end
        after
          Task.shutdown(deleting, :brutal_kill)
          cleanup(user)
        end
      end)
    end
  end

  test "concurrent new and changed environment FKs cannot slip past the cleanup scan" do
    Sandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      # This agent is already in the cleanup set through its allowlist.
      # Editing its default environment must not lock the agent before the
      # source: that would deadlock with deletion's source-then-agent order.
      agent = insert_agent(user_id: user.id, allowed_environment_ids: [env.id])
      initial_count = Repo.aggregate(from(a in Agent, where: a.user_id == ^user.id), :count)
      deleting = independent(fn -> Environments.delete_environment(env) end, "environments")

      try do
        assert_receive {:backend, deleting_pid, deleting_backend}, 5_000
        assert deleting_pid == deleting.pid
        assert_receive {:locked, ^deleting_pid}, 5_000
        editing = independent(fn -> Agents.update_agent(agent, %{environment_id: env.id}) end)

        creating =
          independent(fn ->
            Agents.create_agent(agent_attrs(user_id: user.id, environment_id: env.id))
          end)

        try do
          for task <- [editing, creating] do
            pid = task.pid
            assert_receive {:backend, ^pid, backend}, 5_000
            await_blocked(backend, deleting_backend)
          end

          send(deleting.pid, :continue)
          assert {:ok, _} = Task.await(deleting, 5_000)

          for task <- [editing, creating] do
            assert {:error, changeset} = Task.await(task, 5_000)
            assert Keyword.has_key?(changeset.errors, :environment_id)
          end

          assert Repo.aggregate(from(a in Agent, where: a.user_id == ^user.id), :count) ==
                   initial_count

          current = Repo.reload!(agent)
          assert current.environment_id == nil
          assert current.allowed_environment_ids == []
          assert [latest, _] = versions(agent)
          assert latest.config == Agents.snapshot_config(current)
        after
          Task.shutdown(editing, :brutal_kill)
          Task.shutdown(creating, :brutal_kill)
        end
      after
        Task.shutdown(deleting, :brutal_kill)
        cleanup(user)
      end
    end)
  end

  defp independent(fun, pause_table \\ nil) do
    owner = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        handler = {__MODULE__, make_ref()}

        if pause_table do
          :telemetry.attach(
            handler,
            [:fountain, :repo, :query],
            &__MODULE__.after_query/4,
            {self(), owner, pause_table, handler}
          )
        end

        try do
          fun.()
        after
          if pause_table, do: :telemetry.detach(handler)
        end
      end)
    end)
  end

  # Pause only after PostgreSQL has acquired the selected deletion row lock.
  def after_query(_, _, %{query: query}, {worker, owner, table, handler}) do
    if self() == worker and String.contains?(query, ~s(FROM "#{table}")) and
         String.ends_with?(query, "FOR UPDATE") do
      :telemetry.detach(handler)
      send(owner, {:locked, self()})

      receive do
        :continue -> :ok
      after
        10_000 -> send(owner, :lock_release_timed_out)
      end
    end
  end

  defp await_blocked(waiter, holder),
    do: await_blocked(waiter, holder, System.monotonic_time(:millisecond) + 5_000)

  defp await_blocked(waiter, holder, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT $2 = ANY(pg_blocking_pids($1))", [waiter, holder])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline, "expected PostgreSQL lock wait"
      Process.sleep(5)
      await_blocked(waiter, holder, deadline)
    end
  end

  defp versions(agent), do: Agents.list_agent_versions(agent.id, agent.user_id)

  defp updates(agent) do
    Repo.all(
      from a in Audit.Event, where: a.resource_id == ^agent.id and a.action == "agent.updated"
    )
  end

  defp cleanup(user) do
    Repo.delete_all(from a in Audit.Event, where: a.user_id == ^user.id)
    Repo.delete_all(from a in Agent, where: a.user_id == ^user.id)
    Repo.delete_all(from e in Environments.Environment, where: e.user_id == ^user.id)
    Repo.delete_all(from v in Vaults.Vault, where: v.user_id == ^user.id)
    Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
  end
end
