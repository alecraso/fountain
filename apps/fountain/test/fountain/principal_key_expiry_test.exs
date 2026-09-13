defmodule Fountain.PrincipalKeyExpiryTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Accounts.ApiKey

  test "a legacy writer's principal key with no expiry receives 30 days" do
    user = insert_verified_user()
    earliest = database_deadline()
    {key, raw} = legacy_insert(user.id, "legacy")

    # The old issuer did not send an expiry or request that generated value
    # back. Authentication and management read the persisted deadline.
    persisted = Repo.reload!(key)
    assert_deadline(persisted, earliest)
    assert {:ok, _, authenticated} = Accounts.authenticate_api_key(raw)
    assert authenticated.expires_at == persisted.expires_at
  end

  test "explicit principal deadlines and unbounded non-principal keys are preserved" do
    user = insert_verified_user()
    deadline = DateTime.utc_now() |> DateTime.add(60) |> DateTime.truncate(:second)

    {:ok, {key, _}} =
      Accounts.create_api_key(user.id, "anonymous", scopes: ["principal"], expires_at: deadline)

    assert Repo.reload!(key).expires_at == deadline

    for scope <- ["full", "sprite"] do
      {:ok, {other, _}} = Accounts.create_api_key(user.id, scope, scopes: [scope])
      assert is_nil(Repo.reload!(other).expires_at)
    end
  end

  test "an old update cannot clear a principal deadline or add principal scope without one" do
    user = insert_verified_user()
    {:ok, {key, _}} = Accounts.create_api_key(user.id, "changed")

    earliest = database_deadline()

    from(k in ApiKey, where: k.id == ^key.id)
    |> Repo.update_all(set: [scopes: ["principal"]])

    assert_deadline(Repo.reload!(key), earliest)
    earliest = database_deadline()

    from(k in ApiKey, where: k.id == ^key.id)
    |> Repo.update_all(set: [expires_at: nil])

    assert_deadline(Repo.reload!(key), earliest)
  end

  test "ordinary key use does not extend an expired principal credential" do
    user = insert_verified_user()
    past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

    {:ok, {key, raw}} =
      Accounts.create_api_key(user.id, "expired", scopes: ["principal"], expires_at: past)

    Accounts.touch_api_key(raw)
    assert Repo.reload!(key).expires_at == past
    assert {:error, :expired} = Accounts.authenticate_api_key(raw)
  end

  test "a legacy write gets its full window even in an older transaction" do
    user = insert_verified_user()
    # Advance beyond the transaction's timestamp(0) second. This is the clock
    # behavior under test, not a wait for an asynchronous side effect.
    Repo.query!("SELECT pg_sleep(1.1)")
    earliest = database_deadline()
    {key, _} = legacy_insert(user.id, "delayed")

    assert_deadline(Repo.reload!(key), earliest)
  end

  test "current issuers must explicitly provide principal expiry" do
    user = insert_verified_user()

    for opts <- [
          [scopes: ["principal"]],
          [scopes: ["principal"], expires_at: nil],
          [scopes: ["full", "principal"]]
        ] do
      assert {:error, changeset} = Accounts.create_api_key(user.id, "missing expiry", opts)
      assert errors_on(changeset).expires_at == ["can't be blank"]
    end

    assert Repo.all(ApiKey) == []
  end

  test "the permanent CHECK is validated and rejects unbounded active keys without the trigger" do
    user = insert_verified_user()
    deadline = DateTime.utc_now() |> DateTime.add(60) |> DateTime.truncate(:second)

    {:ok, {principal, _}} =
      Accounts.create_api_key(user.id, "principal", scopes: ["principal"], expires_at: deadline)

    {:ok, {full, _}} = Accounts.create_api_key(user.id, "full")
    {:ok, {_sprite, _}} = Accounts.create_api_key(user.id, "sprite", scopes: ["sprite"])
    {:ok, {revoked, _}} = Accounts.create_api_key(user.id, "revoked history")
    {:ok, revoked} = Accounts.revoke_api_key(user.id, revoked.id)

    assert %{rows: [[true]]} =
             Repo.query!("""
             SELECT convalidated FROM pg_constraint
             WHERE conrelid = 'api_keys'::regclass
               AND conname = 'api_keys_active_principal_expiry_required'
             """)

    # LIKE copies the actual CHECK and NOT NULL constraints, but no triggers.
    # Each SQL sandbox connection owns this temporary table; no global trigger
    # is disabled and rollback discards the probe even if an assertion fails.
    Repo.query!("""
    CREATE TEMP TABLE principal_expiry_probe
    (LIKE api_keys INCLUDING DEFAULTS INCLUDING CONSTRAINTS) ON COMMIT DROP
    """)

    Repo.query!(
      "INSERT INTO principal_expiry_probe SELECT * FROM api_keys WHERE user_id = $1",
      [Ecto.UUID.dump!(user.id)]
    )

    for {sql, args} <- [
          {"UPDATE principal_expiry_probe SET expires_at = NULL WHERE id = $1",
           [Ecto.UUID.dump!(principal.id)]},
          {"UPDATE principal_expiry_probe SET scopes = ARRAY['principal'] WHERE id = $1",
           [Ecto.UUID.dump!(full.id)]},
          {"UPDATE principal_expiry_probe SET scopes = ARRAY['full', NULL, 'principal'] WHERE id = $1",
           [Ecto.UUID.dump!(full.id)]},
          {"""
           INSERT INTO principal_expiry_probe
           (id, user_id, name, key_hash, key_prefix, scopes, inserted_at, updated_at)
           VALUES ($1, $2, 'missing', 'hash', 'prefix', ARRAY['principal'], now(), now())
           """, [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(user.id)]}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
               Repo.query(sql, args, mode: :savepoint)

      assert name == "api_keys_active_principal_expiry_required"
    end

    # Revoked NULL history is legal. Revocation cannot be cleared to make it
    # authenticate without first supplying a deadline.
    Repo.query!(
      "UPDATE principal_expiry_probe SET scopes = ARRAY['principal'] WHERE id = $1",
      [Ecto.UUID.dump!(revoked.id)]
    )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE principal_expiry_probe SET revoked_at = NULL WHERE id = $1",
               [Ecto.UUID.dump!(revoked.id)], mode: :savepoint)

    # Scopes already have their own NOT NULL invariant; SQL's unknown truth
    # value cannot hide a principal-bearing scope list from the CHECK above.
    assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
             Repo.query(
               "UPDATE principal_expiry_probe SET scopes = NULL WHERE id = $1",
               [Ecto.UUID.dump!(full.id)], mode: :savepoint)

    assert Repo.reload!(principal).expires_at == deadline
    assert is_nil(Repo.reload!(full).expires_at)
    assert is_nil(Repo.reload!(revoked).expires_at)
  end

  defp legacy_insert(user_id, name) do
    {changeset, raw} = Accounts.build_api_key(user_id, name, scopes: ["principal"])
    # Reproduce a pre-validation writer at the persistence boundary. The
    # retained DB trigger supplies expiry; current application validation is
    # deliberately bypassed rather than weakening the shared issuer.
    key = changeset |> Ecto.Changeset.apply_changes() |> Repo.insert!()
    {key, raw}
  end

  defp database_deadline do
    %{rows: [[deadline]]} =
      Repo.query!("""
      SELECT date_trunc('second', clock_timestamp() AT TIME ZONE 'UTC') + INTERVAL '30 days'
      """)

    DateTime.from_naive!(deadline, "Etc/UTC")
  end

  defp assert_deadline(key, earliest) do
    latest = database_deadline()
    assert %DateTime{} = key.expires_at
    assert DateTime.compare(key.expires_at, earliest) in [:eq, :gt]
    assert DateTime.compare(key.expires_at, latest) in [:eq, :lt]
  end
end
