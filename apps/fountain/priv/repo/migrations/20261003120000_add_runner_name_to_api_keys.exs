defmodule Fountain.Repo.Migrations.AddRunnerNameToApiKeys do
  use Ecto.Migration

  # Arugula fork, ADR 0022: a `runner`-scoped key is bound to one runner name.
  #
  # A nullable column is metadata-only. The CHECK pairs the scope with the name
  # in both directions (a runner key has exactly one scope and a name; nothing
  # else has a name), so a row written around the changeset cannot hold a
  # runner key with no binding, or a binding nothing enforces. It is added NOT
  # VALID and validated by the next migration, as the principal-expiry CHECK
  # was, so the scan does not run under the ALTER's exclusive lock.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:api_keys) do
      add :runner_name, :string
    end

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_runner_name_matches_scope
    CHECK (
      (scopes = ARRAY['runner']::varchar[] AND runner_name IS NOT NULL)
      OR (NOT ('runner' = ANY(scopes)) AND runner_name IS NULL)
    )
    NOT VALID
    """
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("ALTER TABLE api_keys DROP CONSTRAINT api_keys_runner_name_matches_scope")

    alter table(:api_keys) do
      remove :runner_name
    end
  end
end
