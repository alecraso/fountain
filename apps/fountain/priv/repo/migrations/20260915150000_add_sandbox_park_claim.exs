defmodule Fountain.Repo.Migrations.AddSandboxParkClaim do
  use Ecto.Migration

  def change do
    alter table(:sandboxes) do
      add :park_claimed_at, :utc_datetime_usec
    end
  end
end
