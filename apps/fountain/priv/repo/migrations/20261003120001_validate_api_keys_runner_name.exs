defmodule Fountain.Repo.Migrations.ValidateApiKeysRunnerName do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # VALIDATE takes SHARE UPDATE EXCLUSIVE, so reads and writes continue.
    # Every existing row has a null name and no `runner` scope, so it passes.
    execute("ALTER TABLE api_keys VALIDATE CONSTRAINT api_keys_runner_name_matches_scope")
  end

  def down, do: :ok
end
