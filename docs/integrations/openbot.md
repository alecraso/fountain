# OpenBot / AG-UI (retired)

Fountain used to answer `POST /api/agui/:agent_id` with
[AG-UI](https://github.com/ag-ui-protocol/ag-ui)'s `RunAgentInput` and SSE
event stream, so a Fountain agent could be registered as a Bot in
[OpenBot](https://copilotkit.ai/openbot) or any other AG-UI host with no
plugin and no code. **That endpoint is gone**, removed in the release that
carries [ADR 0057](https://github.com/managoat/fountain/blob/main/decisions/0057-retire-public-compatibility-protocols.md).

This page stays because the URL is in other people's notes. It is not a page
about a feature you can turn on.

## What a call gets now

`/api/agui/:agent_id` matches no route and falls through to the ordinary
unmatched-path handling for `/api`, which means the answer depends on the
request rather than on anything AG-UI:

| Request | Answer |
|---|---|
| Authenticated, `Accept: application/json` | `404` `{"error": "Not found", "reason": "not_found"}` |
| No API key | `401` — authentication runs before dispatch |
| `Accept: text/event-stream` | `406` — content negotiation refuses it first |

The `406` is worth knowing about, because `text/event-stream` is exactly what
an AG-UI client sends: such a client sees a content-negotiation failure
rather than a clean "gone". Every one of these is what an `/api` path that
never existed returns. No `RUN_ERROR` event and no AG-UI envelope survives.

## Continuing a thread you already have

**Do this before creating anything.** A conversation OpenBot (or any AG-UI
host) opened is still there, with its sandbox and its history. Creating a new
one instead gets you a fresh sandbox and loses that.

Each host `threadId` was stored as the conversation's `channel_id`, prefixed
`agui:`. Find it, then prompt the id:

```bash
# 1. Find the conversation the thread is bound to.
curl -H "Authorization: Bearer ftn_..." \
  "https://your-fountain/api/conversations?channel_id=agui:<threadId>"

# 2. Prompt it by id. Same sandbox, same history.
curl -X POST -H "Authorization: Bearer ftn_..." -H "Content-Type: application/json" \
  -d '{"prompt":"..."}' \
  "https://your-fountain/api/conversations/<id>/prompts"
```

Two things to get right:

- **Do not replay the host transcript.** An AG-UI host replays the whole
  message list on each run because it expects a stateless endpoint. Fountain
  never worked that way — the sandbox is the memory — and replaying it now
  feeds the agent its own words back.
- If you resume by `channel_id` rather than by id, **send the same
  `agent_id`, `environment_id` and `vault_id`** the conversation was created
  with. An incomplete identity resolves to a different machine.

Existing `agui:` bindings are left intact by the retirement — nothing was
renamed or migrated.

## What to use instead

The native conversation API: create a conversation, prompt it, and follow
[`GET /api/conversations/:id/stream`](../api.md). Fountain's own event stream
carries the same turn — text, thinking, tool activity, lifecycle — in
Fountain's shape rather than AG-UI's, so a host that speaks AG-UI needs a
translation layer of its own that Fountain no longer provides.

Read [Plug into Fountain](clients.md) for the routes in, and the
[TypeScript](../sdk.md), [Python](../python-sdk.md), [Elixir](../elixir-sdk.md)
or [Swift](../swift-sdk.md) SDK for a client that already follows the stream.

## What has no replacement

Registering a Fountain agent with an AG-UI host by pasting a URL. Fountain no
longer speaks the protocol, and the native stream is not AG-UI. A host that
needs AG-UI has to adapt Fountain's events itself.
