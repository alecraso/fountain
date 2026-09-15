### Removed

- The `openai_compat` feature flag, which gated the retired OpenAI-compatible
  API (ADR 0057, #2252). `FEATURE_FLAGS_ON` itself is unchanged and still
  documented. A deployment that listed `openai_compat` there removes that one
  entry and keeps the rest: `connections` in particular still decides the
  Connections creation rollout wherever PostHog is configured, so unset the
  variable only if the list it leaves behind is empty. Without PostHog,
  `connections` reads on by itself and no shipped feature needs a key here
  (#2252).
