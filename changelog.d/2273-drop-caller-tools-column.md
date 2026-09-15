### Upgrade notes

- **Upgrade from v0.18.0 or later, not from v0.17.x** (#2273). This release
  drops the `conversations.caller_tools` column, and v0.18.0 is the release
  that made the server stop reading it. A single-node deployment coming
  straight from v0.17.x is fine — both migrations run before it serves — but a
  **rolling** multi-node deployment that skips v0.18.0 leaves v0.17.x nodes,
  whose schema still declares the field, running against a table without it,
  and those nodes raise on every conversation read. Take v0.18.0 first, let it
  finish rolling, then take this one.

- **The drop destroys the retired tool definitions, and a rollback does not
  bring them back** (#2273). The column held the tool schemas a
  chat-completions or AG-UI client defined on its request (#1202). The
  migration's `down/0` restores the column with its original type, default and
  `NOT NULL`, so the schema round-trips and a rollback is safe — but every row
  comes back with the empty array the column originally defaulted to. Nothing
  else recorded those definitions: they arrived on a request, were persisted
  only here, and the endpoints that served them were retired in v0.18.0. No
  version you can roll back to reads the column, so what is lost is
  definitions no deployed server can act on. If you want a record anyway, take
  it before upgrading — it is one query:

      COPY (SELECT id, caller_tools FROM conversations
            WHERE caller_tools <> '{}') TO STDOUT WITH CSV HEADER;

  Conversations, sandboxes, channel bindings, agent MCP configuration,
  callback-key fields, turns and historical log and webhook records are
  untouched; only that one column goes.

### Removed

- The `conversations.caller_tools` column, the last of the retired tool
  bridge (ADR 0057, #2252, closing #2273). The field left
  `Fountain.Conversations.Conversation` in v0.18.0, which is what made the
  server a non-reader; the column stayed for that one release so a rolling
  deployment could reach a non-reader everywhere before the drop. Nothing
  reads or writes it at any supported version. `conversation.caller_tool.started`
  and `.done` remain valid webhook filters, as they have been since v0.18.0,
  and stored subscriptions are still left exactly as their owners wrote them.
