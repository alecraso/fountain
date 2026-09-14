defmodule Fountain.Repo.Migrations.RequireActivePrincipalKeyExpiry do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # Install the permanent invariant without scanning under ALTER TABLE's
    # exclusive lock. The following migration validates after this DDL commits.
    # Retain the legacy BEFORE trigger: boot migrations can run while older
    # replicas still omit expiry. Removing it requires a verified writer floor.
    # Historical revoked keys may have NULL expiry and cannot authenticate.
    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_active_principal_expiry_required
    CHECK (revoked_at IS NOT NULL OR NOT ('principal' = ANY(scopes)) OR expires_at IS NOT NULL)
    NOT VALID
    """
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")
    execute("ALTER TABLE api_keys DROP CONSTRAINT api_keys_active_principal_expiry_required")
    # Keep both the compatibility trigger and every existing expiry unchanged.
  end
end
