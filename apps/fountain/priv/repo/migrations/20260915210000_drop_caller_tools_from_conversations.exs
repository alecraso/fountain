defmodule Fountain.Repo.Migrations.DropCallerToolsFromConversations do
  @moduledoc """
  Drop `conversations.caller_tools` (#2273, the last of ADR 0057 / #2252).

  It held the tool schemas a chat-completions or AG-UI client defined on its
  request, added by `20260826041202_add_caller_tools_to_conversations` for the
  bridge in #1202. #2280 retired the bridge and removed the field from
  `Fountain.Conversations.Conversation`, which made the server a non-reader,
  and v0.18.0 shipped that. The column stayed for that release so a rolling
  deployment could not put a v0.17.x node, whose schema still declared the
  field, against a table without it.

  **The minimum version to upgrade from is v0.18.0.** Every node must be a
  non-reader before this runs. Upgrading a rolling multi-node deployment
  straight from v0.17.x skips the release that made it one, and an old node
  left running would raise on every conversation read.

  `down/0` restores the column with its original type, default and NOT NULL,
  so the schema round-trips — but **it cannot restore the tool definitions
  that were in it**. Nothing else recorded them: they arrived on a request,
  were persisted here, and the endpoints that served them are gone, so a
  rollback yields the empty array the column originally defaulted to. That is
  the same shape as `20260902120000_drop_onboarding_state_from_users`, whose
  `down/0` also restores a column but not its lost distinctions.

  Nothing reads the column at any version this can roll back to, so the data
  loss is of definitions that no deployed server can act on. Take a dump of
  the column first if a record is wanted; it is one query and the audit trail
  does not carry the payloads.
  """

  use Ecto.Migration

  def up do
    alter table(:conversations) do
      remove :caller_tools
    end
  end

  def down do
    alter table(:conversations) do
      add :caller_tools, {:array, :map}, null: false, default: []
    end
  end
end
