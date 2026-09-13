defmodule Fountain.Repo.Migrations.ValidateActivePrincipalKeyExpiry do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # VALIDATE uses SHARE UPDATE EXCLUSIVE, allowing ordinary reads/writes.
    # The earlier backfill bounded every unrevoked principal key, and the
    # retained trigger plus new CHECK protect concurrent writes during the scan.
    # A timeout or invalid row leaves validation pending for an operator retry;
    # do not rewrite deadlines to make validation pass.
    execute("ALTER TABLE api_keys VALIDATE CONSTRAINT api_keys_active_principal_expiry_required")
  end

  def down do
    # PostgreSQL cannot mark a validated CHECK NOT VALID. The preceding
    # migration owns constraint removal; neither rollback changes deadlines.
    :ok
  end
end
