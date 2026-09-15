### Removed

- **Breaking.** The request-defined tool bridge is retired with the dialects
  that fed it (ADR 0057, #2252): `POST /api/mcp/caller/{conversation_id}`,
  the `caller_tools` field on conversation create and attach, the parked-call
  state a turn carried, and the `conversation.caller_tool.started` /
  `conversation.caller_tool.done` webhook events. Tools **configured on an
  agent** that call a client application are unaffected — their MCP
  configuration, `${VAR}` substitution, connection-backed servers and
  callback-key scoping all work exactly as before, and a regression suite now
  pins that. `conversation.caller_tool.started` and `.done` stay **valid
  webhook filters** although nothing emits them any more: every endpoint
  update re-validates the whole `event_types` array, so retiring the
  vocabulary outright would refuse to save an endpoint that still named one
  the next time its owner changed the URL. Stored subscriptions are left
  exactly as their owners wrote them — nothing is rewritten, widened or
  dropped on their behalf — which also keeps this release rollback-safe. The
  `conversations.caller_tools` column is kept for now and dropped separately
  (#2273) (#2252).
