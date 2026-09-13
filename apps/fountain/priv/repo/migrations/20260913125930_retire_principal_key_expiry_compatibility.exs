defmodule Fountain.Repo.Migrations.RetirePrincipalKeyExpiryCompatibility do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # Operational prerequisite: every writer must already include af1178dd,
    # and all older processes must be drained. Boot migration alone cannot
    # prove that floor; see the principal expiry section of the upgrade guide.
    # Keep the validated permanent invariant throughout trigger retirement.
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'api_keys'::regclass
          AND conname = 'api_keys_active_principal_expiry_required'
          AND contype = 'c' AND convalidated
      ) THEN
        RAISE EXCEPTION 'Validate api_keys_active_principal_expiry_required before retiring expiry compatibility';
      END IF;
    END;
    $$
    """

    execute("DROP TRIGGER bound_principal_key_expiry ON api_keys")
    execute("DROP FUNCTION fountain_bound_principal_key_expiry()")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # Restore compatibility before any older writer is restarted. Neither
    # direction changes the permanent CHECK or any assigned deadline.
    execute """
    CREATE FUNCTION fountain_bound_principal_key_expiry() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.expires_at IS NULL AND 'principal' = ANY(NEW.scopes) THEN
        NEW.expires_at := date_trunc('second', clock_timestamp() AT TIME ZONE 'UTC')
                          + INTERVAL '30 days';
      END IF;
      RETURN NEW;
    END;
    $$
    """

    execute """
    CREATE TRIGGER bound_principal_key_expiry
    BEFORE INSERT OR UPDATE OF scopes, expires_at ON api_keys
    FOR EACH ROW EXECUTE FUNCTION fountain_bound_principal_key_expiry()
    """
  end
end
