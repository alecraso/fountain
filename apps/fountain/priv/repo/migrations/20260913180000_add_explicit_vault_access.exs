defmodule Fountain.Repo.Migrations.AddExplicitVaultAccess do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # STORED columns rewrite these tables under ACCESS EXCLUSIVE locks. Keep
    # both statements in this transaction: timeout rolls back the entire step.
    # Generation covers old writers atomically throughout a rolling upgrade.
    execute """
    ALTER TABLE agents ADD COLUMN vault_access text GENERATED ALWAYS AS (
      CASE WHEN allowed_vault_ids IS NULL THEN 'all_tenant_vaults'
           ELSE 'allowlist' END
    ) STORED NOT NULL
    """

    # A missing snapshot key preserves the current value on partial restore;
    # JSON null explicitly restores unrestricted access. Do not conflate them
    # or bless malformed historical payloads (rollback revalidates config).
    execute """
    ALTER TABLE agent_versions ADD COLUMN vault_access text GENERATED ALWAYS AS (
      CASE WHEN NOT (config ? 'allowed_vault_ids') THEN 'unchanged'
           WHEN config->'allowed_vault_ids' = 'null'::jsonb THEN 'all_tenant_vaults'
           WHEN jsonb_typeof(config->'allowed_vault_ids') = 'array' THEN 'allowlist'
           ELSE 'invalid' END
    ) STORED NOT NULL
    """
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # Only derived data is removed; the original arrays and snapshot configs
    # survive. This requires readers that do not select the derived columns.
    execute("ALTER TABLE agent_versions DROP COLUMN vault_access")
    execute("ALTER TABLE agents DROP COLUMN vault_access")
  end
end
