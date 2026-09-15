### Upgrade notes

- **The compatibility dialects are gone; native conversations are the only
  API** (ADR 0057, #2252). Five paths are retired: `POST /v1/chat/completions`,
  `GET /v1/models`, `GET /v1/models/{model}`, `POST /api/agui/{agent_id}` and
  `POST /api/mcp/caller/{conversation_id}`. Before you upgrade, check whether
  anything still calls one — a stock OpenAI client, an AG-UI front end, a
  gateway pointed at `/v1`, or a sandbox answering request-defined tools. Each
  now gets the ordinary unmatched-path answer, not a dialect error: `/v1` is
  404 for every request, and `/api/agui/…` is 404 for an authenticated JSON
  caller, 401 without a key and 406 for the `Accept: text/event-stream` an
  AG-UI client sends, so a caller that only checks for a 404 will read the
  other two as something else. Port it to conversations — `POST
  /api/conversations`, then `POST /api/conversations/{conversation_id}/prompts`,
  `GET /api/conversations/{conversation_id}/events` and
  `GET /api/conversations/{conversation_id}/stream` — or to an SDK over them;
  the four integration pages are migration pages at the same
  URLs and each says what has no replacement:
  [OpenAI-compatible](https://managoat.com/docs/integrations/openai-compatible),
  [OpenBot/AG-UI](https://managoat.com/docs/integrations/openbot),
  [LangChain](https://managoat.com/docs/integrations/langchain) and
  [AI gateways](https://managoat.com/docs/integrations/gateways). Native
  conversations, the SDKs over them, and OpenAI and Codex *inference*,
  credentials and runtimes are all unchanged.

- **Drop `openai_compat` from `FEATURE_FLAGS_ON`** (#2252). The flag no longer
  exists; the variable itself is unchanged and still documented. Remove that
  one entry and keep the rest — `connections` in particular still decides the
  Connections creation rollout wherever PostHog is configured — and unset the
  variable only if the list it leaves behind is empty.

- **A client that sends `caller_tools` on conversation create or attach must
  stop** (#2252). The field is gone with the bridge that read it, and the
  `conversation.caller_tool.started` / `.done` webhook events are no longer
  emitted. Nothing to do about stored webhook subscriptions: both names stay
  valid filters, and no subscription is rewritten, widened or dropped. Tools
  **configured on an agent** that call a client application are unaffected.
  The `conversations.caller_tools` column is kept in this release and dropped
  separately once the deployment floor advances (#2273), so this release
  carries no data migration and rolling back to v0.17.1 restores the retired
  surfaces intact.

- **Swift SDK callers: two source-breaking model changes** (#2269, #2277).
  `AuthMe.onboardingState` is gone — read `onboardingCompleted` instead — and
  `Catalog.sandboxAPIAccess` is now `[SandboxAPIAccess]?` rather than
  `[String]?`, so comparing an element to a bare `String` no longer compiles,
  although a string literal still does. Both decode unchanged from any server.
  TypeScript SDK 6.0.0 is the matching release there.
