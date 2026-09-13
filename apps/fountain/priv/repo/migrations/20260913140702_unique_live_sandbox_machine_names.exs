defmodule Fountain.Repo.Migrations.UniqueLiveSandboxMachineNames do
  use Ecto.Migration

  # Keep the advisory migration lock while existing replicas continue writing.
  # Historical rows may reuse a name after retirement; live rows may not.
  @disable_ddl_transaction true

  def change do
    create unique_index(:sandboxes, [:provider, :sprite_name],
             name: :sandboxes_live_machine_name_index,
             where: "status NOT IN ('terminated', 'failed')",
             concurrently: true
           )
  end
end
