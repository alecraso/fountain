# OpenAI-compatible API (retired)

Fountain used to answer `POST /v1/chat/completions`, `GET /v1/models` and
`GET /v1/models/{model}`, so that any client or gateway with a base-URL field
could point at `https://your-fountain/v1` and treat a Fountain agent as a
model. **Those endpoints are gone.** They were removed in the release that
carries [ADR 0057](https://github.com/managoat/fountain/blob/main/decisions/0057-retire-public-compatibility-protocols.md),
having been alpha and off by default behind a feature flag for their whole
life.

This page stays because the URL is in other people's notes and bookmarks. It
is not a page about a feature you can turn on.

## What a call gets now

`/v1` matches no route, so every request answers `404` with the ordinary body:

```json
{"errors": {"detail": "Not Found"}}
```

That is the same for `GET` and `POST`, with or without an API key, and
whether the client asks for JSON or `text/event-stream`. There is no legacy
envelope, no `openai_compat_not_enabled` code, and no redirect.

## Continuing a thread you already have

**Do this before creating anything.** A conversation your old integration
opened is still there, with its sandbox and everything the agent worked out in
it. Creating a new one instead gets you a fresh sandbox and loses that.

The thread key you were sending — `X-Fountain-Thread`, else `user`, else
`safety_identifier` — was stored as the conversation's `channel_id`, prefixed
`openai:`. So find it, then prompt the id you get back:

```bash
# 1. Find the conversation your thread key is bound to.
curl -H "Authorization: Bearer ftn_..." \
  "https://your-fountain/api/conversations?channel_id=openai:<your-thread-key>"

# 2. Prompt it by id. Same sandbox, same history.
curl -X POST -H "Authorization: Bearer ftn_..." -H "Content-Type: application/json" \
  -d '{"prompt":"..."}' \
  "https://your-fountain/api/conversations/<id>/prompts"
```

Two things to get right:

- **Do not replay your transcript.** The sandbox is the memory. Send only the
  new message; replaying the history feeds the agent its own words back.
- If you resume by `channel_id` rather than by id, **send the same
  `agent_id`, `environment_id` and `vault_id`** the conversation was created
  with. An incomplete identity resolves to a different machine, which is the
  same lost-sandbox outcome by another route.

Existing `openai:` bindings are left intact by the retirement — nothing was
renamed or migrated.

## What to use instead

The native conversation API. It is not a drop-in for a chat-completions
client — that is the point of the shape that went away — so this is a
rewrite, not a base-URL change:

| You had | You want |
|---|---|
| `POST /v1/chat/completions` with `messages` | [`POST /api/conversations`](../api.md), then prompt the conversation |
| `stream: true` and SSE chunks | [`GET /api/conversations/:id/stream`](../api.md) |
| A thread key in a header | A conversation id, which Fountain returns when you create one |
| `model: "<agent>"` | `agent_id` on the conversation |
| `GET /v1/models` | [`GET /api/agents`](../api.md) |

The [TypeScript](../sdk.md), [Python](../python-sdk.md),
[Elixir](../elixir-sdk.md) and [Swift](../swift-sdk.md) SDKs wrap all of it, and
[Plug into Fountain](clients.md) is the shortest route in.

## What is not affected

**OpenAI and Codex as inference.** Fountain still runs agents on OpenAI
models, still stores OpenAI credentials, and still supports the Codex
runtime. Those share the vendor's name with the retired gateway and nothing
else — no provider-side `/v1` path was touched.

**Tools your agent calls on your application.** Configure them on the agent
as MCP servers, with `${VAR}` references resolved from the environment and
the vault. That path is unchanged and is not the retired request-defined
tool bridge. Read [Plug into Fountain](clients.md).

## What has no replacement

Pointing a stock OpenAI client or an AI gateway at Fountain with **no code**.
That was the whole value of the dialect, and retiring it removes it; nothing
in the native API gives it back. If that is what you needed, the honest
answer is that Fountain no longer offers it.
