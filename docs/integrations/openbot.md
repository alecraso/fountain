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

**Do this before creating anything.** A conversation OpenBot (or any AG-UI host)
opened is still there, with its sandbox and everything the agent worked out in
it. Creating a new one instead gets you a fresh sandbox and loses that.

Each host `threadId` was stored as the conversation's `channel_id`, prefixed
`agui:`. Find it, **check it is the one you mean**, then prompt it by id.

```bash
# 1. Find candidates. Filter by the agent too: a thread key is only unique
#    within the agent it was used against, and `--data-urlencode` keeps a key
#    containing /, ?, & or a space from breaking the query.
curl -G -H "Authorization: Bearer ftn_..." \
  --data-urlencode "channel_id=agui:<threadId>" \
  --data-urlencode "agent_id=<agent-uuid>" \
  --data-urlencode "status=idle,running,pending" \
  "https://your-fountain/api/conversations"
```

**This is a list, not an answer.** It is ordered by `updated_at`, and without
the `status` filter it also returns `failed` and `terminated` conversations,
which cannot take a prompt.

```bash
# 2. For each candidate, fetch it by id. Only the show route loads the
#    sandbox — the list above renders `sandbox: null` for every row, so it
#    cannot tell you whether the machine is still there.
curl -H "Authorization: Bearer ftn_..." \
  "https://your-fountain/api/conversations/<id>"
```

The show route reads what Fountain last recorded. It does not contact the
sandbox provider, so `data.sandbox` says what the machine was, not whether it
is still there. Rule a candidate out when either of these holds:

- `data.sandbox` is null, or its `status` is `terminated` or `failed`. The
  machine is gone, and a prompt provisions a fresh one.
- `data.agent_id`, `data.environment_id` or `data.vault_id` is not the
  identity the work was done under. That is a different configuration, not
  your thread.

If several candidates come back, the thread key was reused across
configurations — pick by that identity, not by recency, and expect some of them
to have terminal sandboxes. If none survives, there is nothing to continue and
a fresh conversation is the right answer.

What the row cannot rule out is a `ready` or `suspended` sandbox the provider
has since lost. Fountain checks that when you prompt: the prompt probes the
provider first, and if the machine is gone it provisions a fresh one rather
than failing. The conversation keeps its id, title and transcript. The disk
and the runtime session on it go with the machine, so the agent starts that
turn with no memory of the work. How much you can know beforehand depends on
`data.sandbox.status`:

- `ready`: one read-only call proves the machine answers.
  `GET /api/sandboxes/<sandbox_id>/git-status`, with `data.sandbox_id`, runs
  on the machine without changing it. `200` means it is there.
  `503 sandbox_unreachable` means it did not answer, and a prompt now either
  reprovisions or fails retryably. `/files` and `/diff` on the same prefix
  serve as well; the [API reference](../api.md) lists them.
- `suspended`: no read-only check exists. A parked machine is not woken for a
  read (`409 sandbox_not_ready`), and the wake a prompt performs is the probe.

So the prompt below continues the thread on a best-effort basis. Afterwards,
two things say whether it kept the machine: `data.sandbox_id` on the show
route is unchanged, and the event feed, `GET /api/conversations/<id>/events`,
has no `session` stage event whose `data.reason` is `fresh_sandbox`. If either
says the machine was replaced, treat the thread as new from that turn on.

```bash
# 3. Prompt it by id. Same conversation, and the same machine while the
#    provider still has it — see above for how to tell.
curl -X POST -H "Authorization: Bearer ftn_..." -H "Content-Type: application/json" \
  -d '{"prompt":"..."}' \
  "https://your-fountain/api/conversations/<id>/prompts"
```

**Do not replay the host transcript.** An AG-UI host replays the whole message
list on each run because it expects a stateless endpoint. Fountain never worked
that way — the sandbox is the memory — and replaying it now feeds the agent its
own words back.

If you resume by `channel_id` instead of prompting an id, send the same
`agent_id`, `environment_id` and `vault_id` — an incomplete identity resolves
to a different machine, which is the same lost-sandbox outcome by another
route.

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
