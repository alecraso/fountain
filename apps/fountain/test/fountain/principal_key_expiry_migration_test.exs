defmodule Fountain.PrincipalKeyExpiryMigrationTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Repo.Migrations.RetirePrincipalKeyExpiryCompatibility, as: Migration

  @version 20_260_913_125_930

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20260913125930_retire_principal_key_expiry_compatibility.exs",
      __DIR__
    )
  end

  setup do
    user = insert_verified_user()
    deadline = DateTime.utc_now() |> DateTime.add(60) |> DateTime.truncate(:second)

    {:ok, {key, _}} =
      Accounts.create_api_key(user.id, "explicit", scopes: ["principal"], expires_at: deadline)

    # Exercise the actual migration against a connection-local schema. The
    # sandbox rolls back the schema, DDL and search path after each test;
    # migrations never disable or recreate the shared api_keys trigger.
    schema = "expiry_migration_#{System.unique_integer([:positive])}"
    Repo.query!(~s(CREATE SCHEMA "#{schema}"))
    Repo.query!(~s|CREATE TABLE "#{schema}".api_keys (LIKE public.api_keys INCLUDING ALL)|)

    Repo.query!(
      ~s(INSERT INTO "#{schema}".api_keys SELECT * FROM public.api_keys WHERE id = $1),
      [
        Ecto.UUID.dump!(key.id)
      ]
    )

    Repo.query!(~s(SET LOCAL search_path TO "#{schema}", public))
    run_migration(:down)

    %{key: key, deadline: deadline}
  end

  test "rollback restores older writes; reapply keeps the CHECK and every assigned deadline",
       ctx do
    # Rollback restores the legacy default before an older application returns.
    Repo.query!("UPDATE api_keys SET expires_at = NULL WHERE id = $1", [
      Ecto.UUID.dump!(ctx.key.id)
    ])

    %{rows: [[assigned]]} = Repo.query!("SELECT expires_at FROM api_keys")

    assert DateTime.diff(DateTime.from_naive!(assigned, "Etc/UTC"), DateTime.utc_now()) in (30 *
                                                                                              86_400 -
                                                                                              5)..(30 *
                                                                                                     86_400)

    run_migration(:up)
    assert %{rows: [[^assigned]]} = Repo.query!("SELECT expires_at FROM api_keys")
    assert %{rows: [[true]]} = constraint_state()

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query("UPDATE api_keys SET expires_at = NULL", [], mode: :savepoint)

    run_migration(:down)
    assert %{rows: [[^assigned]]} = Repo.query!("SELECT expires_at FROM api_keys")
    assert %{rows: [[true]]} = constraint_state()
  end

  test "retirement preserves an explicit deadline in both directions", ctx do
    run_migration(:up)
    run_migration(:down)
    assert %{rows: [[deadline]]} = Repo.query!("SELECT expires_at FROM api_keys")
    assert DateTime.from_naive!(deadline, "Etc/UTC") == ctx.deadline
  end

  test "retirement refuses missing or unvalidated enforcement before dropping compatibility" do
    Repo.query!("ALTER TABLE api_keys DROP CONSTRAINT api_keys_active_principal_expiry_required")
    assert_guard_refuses()

    Repo.query!("""
    ALTER TABLE api_keys ADD CONSTRAINT api_keys_active_principal_expiry_required
    CHECK (revoked_at IS NOT NULL OR NOT ('principal' = ANY(scopes)) OR expires_at IS NOT NULL)
    NOT VALID
    """)

    assert %{rows: [[false]]} = constraint_state()
    assert_guard_refuses()

    Repo.query!(
      "ALTER TABLE api_keys VALIDATE CONSTRAINT api_keys_active_principal_expiry_required"
    )

    run_migration(:up)
    assert %{rows: [[0]]} = trigger_count()
  end

  defp assert_guard_refuses do
    # SQL Sandbox wraps each DDL statement in a savepoint on this connection.
    assert_raise Postgrex.Error, ~r/Validate api_keys_active_principal_expiry_required/, fn ->
      run_migration(:up)
    end

    assert %{rows: [[1]]} = trigger_count()
  end

  defp constraint_state do
    Repo.query!("""
    SELECT convalidated FROM pg_constraint
    WHERE conrelid = 'api_keys'::regclass
      AND conname = 'api_keys_active_principal_expiry_required'
    """)
  end

  defp trigger_count do
    Repo.query!("""
    SELECT count(*) FROM pg_trigger
    WHERE tgrelid = 'api_keys'::regclass AND tgname = 'bound_principal_key_expiry'
    """)
  end

  defp run_migration(direction) do
    # Run the real queued DDL on this test's sandbox connection. The public
    # Migrator starts another transaction/connection and owns schema_migrations;
    # the runner lets this isolated probe leave migration history untouched.
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      Migration,
      :forward,
      direction,
      direction,
      log: false
    )
  end
end
