### Removed

- The runnable examples for the retired compatibility dialects:
  `examples/openai-chat`, `examples/litellm-gateway` and
  `examples/deepagents-contractor`. All three called endpoints that no longer
  exist, and none has a native port: the first two existed to show that a
  stock OpenAI client or gateway needed no code, and the third wrapped the
  dialect as a LangChain `ChatOpenAI` model. `docs/integrations/langchain.md`
  says plainly which capability ended rather than implying a migration
  (ADR 0057, #2252).

### Changed

- The integration pages for the OpenAI-compatible API, OpenBot/AG-UI,
  LangChain and AI gateways are now migration pages at the same URLs: each
  says what a call gets today, what to use instead, and what has no
  replacement. ADR 0035 is superseded by ADR 0057, and ADR 0057 records the
  correction that the retirement answer is a plain 404 only on `/v1` — the
  `/api` paths keep the 401 and 406 that authentication and content
  negotiation produce before dispatch (#2252).
