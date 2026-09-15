defmodule Fountain.Repo.Migrations.AddSandboxParkClaim do
  use Ecto.Migration

  def change do
    alter table(:sandboxes) do
      add :park_claimed_at, :utc_datetime_usec
      # #2286 round 5: a durable publication of a wake's own registration,
      # committed under the sandbox's advisory lock alongside starting the
      # server. Horde registry propagation is asynchronous, so
      # `ConversationServer.whereis/1` can read `nil` on a node other than
      # the one that just registered it; this column is what the reaper's
      # abandoned-sweep grace predicate checks instead, so it stays off a
      # freshly woken row regardless of which node it runs on.
      add :woken_at, :utc_datetime_usec
    end
  end
end
