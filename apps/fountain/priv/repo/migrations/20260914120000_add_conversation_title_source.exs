defmodule Fountain.Repo.Migrations.AddConversationTitleSource do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :title_source, :string, null: false, default: "user"
    end
  end
end
