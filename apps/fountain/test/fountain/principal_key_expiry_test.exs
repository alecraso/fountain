defmodule Fountain.PrincipalKeyExpiryTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Accounts.ApiKey

  test "the compatibility trigger and function have been retired" do
    assert %{rows: [[0]]} =
             Repo.query!("""
             SELECT count(*) FROM pg_trigger
             WHERE tgrelid = 'api_keys'::regclass AND tgname = 'bound_principal_key_expiry'
             """)

    assert %{rows: [[nil]]} =
             Repo.query!("SELECT to_regprocedure('fountain_bound_principal_key_expiry()')")
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

  test "ordinary key use does not extend an expired principal credential" do
    user = insert_verified_user()
    past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

    {:ok, {key, raw}} =
      Accounts.create_api_key(user.id, "expired", scopes: ["principal"], expires_at: past)

    Accounts.touch_api_key(raw)
    assert Repo.reload!(key).expires_at == past
    assert {:error, :expired} = Accounts.authenticate_api_key(raw)
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

  test "the permanent CHECK rejects missing expiry, cleared deadlines and unbounded reactivation" do
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

    for {sql, args} <- [
          {"UPDATE api_keys SET expires_at = NULL WHERE id = $1",
           [Ecto.UUID.dump!(principal.id)]},
          {"UPDATE api_keys SET scopes = ARRAY['principal'] WHERE id = $1",
           [Ecto.UUID.dump!(full.id)]},
          {"UPDATE api_keys SET scopes = ARRAY['full', NULL, 'principal'] WHERE id = $1",
           [Ecto.UUID.dump!(full.id)]},
          {"""
           INSERT INTO api_keys
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
      "UPDATE api_keys SET scopes = ARRAY['principal'] WHERE id = $1",
      [Ecto.UUID.dump!(revoked.id)]
    )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE api_keys SET revoked_at = NULL WHERE id = $1",
               [Ecto.UUID.dump!(revoked.id)],
               mode: :savepoint
             )

    # Scopes already have their own NOT NULL invariant; SQL's unknown truth
    # value cannot hide a principal-bearing scope list from the CHECK above.
    assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
             Repo.query(
               "UPDATE api_keys SET scopes = NULL WHERE id = $1",
               [Ecto.UUID.dump!(full.id)],
               mode: :savepoint
             )

    assert Repo.reload!(principal).expires_at == deadline
    assert is_nil(Repo.reload!(full).expires_at)
    assert is_nil(Repo.reload!(revoked).expires_at)
  end
end
