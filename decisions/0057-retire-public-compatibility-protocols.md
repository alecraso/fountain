---
type: ADR
title: "Retire the OpenAI-compatible and AG-UI public protocols"
description: "Propose removing the compatibility endpoints and request-tool bridge while preserving native conversations and agent-configured application tools. Implementation is not yet built."
tags: [api, architecture, integrations]
status: draft
adr: "0057"
adr_status: "Proposed"
date: 2026-09-15
---

# 0057 — Retire the OpenAI-compatible and AG-UI public protocols

**Status:** Proposed. This PR records the inventory and cutover proposal.
No endpoint, application callback, source implementation or database column is
removed here. [#2252](https://github.com/managoat/fountain/issues/2252) owns the
implementation and release. ADR 0035 remains the description of shipped behavior
until the implementation PR explicitly supersedes it.

## Context

[ADR 0035](0035-openai-compatible-endpoint.md) added an OpenAI-compatible public
API alongside AG-UI. Both translate an external transcript into a stateful
Fountain conversation and translate native events back into another protocol.
Their request-defined tools also require a bridge through conversation storage,
MCP injection, parked calls, timers and follow-up tool-result messages.

The maintainer requested retirement under #2252. On 2026-09-15, they reported no
known consumers requiring a transition period and no users explicitly relying
on request-defined tools. They also identified active use of tools configured
on agents that call back into client applications. Those tools are supported
behavior to preserve. This report is maintainer evidence, not a measured census
of hosted traffic or self-hosted databases.

The source and consumer inventory in `contributing/protocol-retirement.md`
records the exact snapshots, removable code, shared behavior and migration gaps.
[ADR 0056](0056-conversation-request-inputs.md) supplies native request APIs; it
does not make an OpenAI or AG-UI host work by changing its base URL alone.

## Decision

Propose retiring these five method/path combinations in the next explicitly
announced breaking server release:

- `POST /v1/chat/completions`
- `GET /v1/models`
- `GET /v1/models/:model`
- `POST /api/agui/:agent_id`
- `POST /api/mcp/caller/:conversation_id`

Remove their route declarations and exclusive controllers, translations and
request-tool bridge. Requests then receive the ordinary unmatched-route HTTP
404; preserve no dialect-specific response envelope, redirect or dormant
feature-flag implementation. Record the actual release tag when scheduled;
this ADR does not assign one or claim retirement shipped in v0.17.1.

Preserve agent-configured MCP servers and application tool callbacks, including
credential substitution, connection-backed tools, callback-key scope/rotation,
extension and team tools, native SSE, permissions, and runtime tool execution.
OpenAI/Codex inference adapters, credentials and model support remain supported.
The implementation must prove these boundaries with regression coverage.

Native clients resolve an agent explicitly and use conversation creation,
prompt submission, event streams and permission responses. Existing conversations
and `openai:`/`agui:` channel bindings remain readable and usable through native
APIs; do not rename channels or create replacement sandboxes merely to migrate a
client. Request-defined tool callbacks have no drop-in native replacement. Put
application tools in the agent's tool/MCP configuration, or build a client-side
integration over native APIs; do not reintroduce a second protocol server in a
new directory as part of this retirement.

Remove all reads and writes of `conversations.caller_tools` in the implementation
release, leaving the physical column temporarily intact. A later forward
migration, [#2273](https://github.com/managoat/fountain/issues/2273), drops it only
after every old server/job is gone and the rollback floor is documented. Never
rewrite its applied migration. Preserve callback-key fields, native permission
records, conversations, sandboxes and historical events/audit/webhook deliveries.

Coordinate public migration pages, examples and release notes with
[managoat/site#3](https://github.com/managoat/site/issues/3). Update the AG-UI
outreach section of [#1196](https://github.com/managoat/fountain/issues/1196) to
point to retirement; its ACP, Buzz and native/MCP work remains independent.

## Consequences

- Four exclusive production files contain 2,295 lines at the audited commit.
  Additional bridge-only state and lifecycle paths can disappear. These are
  removal candidates, not a claim of a measured final net reduction.
- Native launch, streaming, permission and MCP code still needs independent
  tests. Shared `Pending` permission logic, `FeatureFlags`, API authentication
  and rate limits remain; their protocol-specific branches can go.
- Generic OpenAI/AG-UI hosts lose a zero-adapter integration. Native SDK wrappers
  can replace delegation calls, but they are not `ChatOpenAI`, `HttpAgent` or
  request-tool-loop substitutes. Documentation must say which capability ended.
- Generated API types lose the retired operations/schemas. Review package export
  impact and follow each SDK's version policy; native SDK behavior alone does
  not imply that removing a public generated type is source-compatible.
- The code release is reversible while the old column remains. The later column
  drop destroys obsolete tool definitions and needs its own backup/rollback
  accounting. Re-adding an empty column does not restore those definitions.

## Alternatives considered

- **Leave the endpoints disabled behind flags** — keeps the duplicate code,
  tests and bridge state; AG-UI is not gated by `openai_compat` today.
- **Keep a generic request-tool callback bridge** — no reported direct consumer
  justifies preserving this subsystem. Agent-configured application tools already
  serve the actively used pattern and retain their existing behavior.
- **Remove all callback/MCP plumbing** — breaks current application integrations,
  team/extension tools and credential scoping; those are shared native behavior.
- **Drop the column in the first release** — an older Ecto reader can still select
  it during a rolling deployment. Two phases make that deployment boundary explicit.
