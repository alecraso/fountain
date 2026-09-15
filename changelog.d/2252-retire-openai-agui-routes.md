### Removed

- **Breaking.** The OpenAI-compatible gateway (`POST /v1/chat/completions`,
  `GET /v1/models`, `GET /v1/models/{model}`) and the AG-UI run endpoint
  (`POST /api/agui/{agent_id}`) are retired (ADR 0057, #2252). A client that
  still calls one gets the ordinary unmatched-path answer rather than a
  dialect error: `/v1` is 404 for every request, and `/api/agui/…` is 404 for
  an authenticated JSON caller, 401 without a key, and 406 for the
  `Accept: text/event-stream` an AG-UI client sends. Their four operations and
  five schemas leave the OpenAPI contract. Native conversations — creation,
  prompts, `/events`, `/stream`, permissions and the SDKs over them — are
  unchanged, as are OpenAI and Codex inference, credentials and runtimes,
  which share nothing with the retired dialects but the vendor's name. A
  conversation that still carries request-defined tools from the old bridge no
  longer offers them to its agent, because the controllers that could have
  answered such a call are what this change removes (#2252).
