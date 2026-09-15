### Added

- API: the SSE frame each stream sends is now a described `StreamLogEvent`
  schema instead of a bare string (#2297) — `GET /api/conversations/:id/stream`,
  `GET /api/events/stream` and `GET /api/team/stream` all declare it on their
  `text/event-stream` response. The frame's actual fields are unchanged;
  a generated client can now decode it with a typed model instead of the
  operation's prose description alone. The one synthetic frame this stream
  sends — the "server exited, reconnect to resume" stage event on
  `GET /api/conversations/:id/stream` — now carries `stream: ""` instead of
  `null`, matching the schema and every persisted event; a client switching
  on `stage`/`state` is unaffected. `GET /api/events/stream` and
  `GET /api/team/stream` also send `conversations`/`team`/`schedule`
  change-signal frames on the same connection, now described as a second
  schema, `StreamSignal`, in a `oneOf` with `StreamLogEvent`.
