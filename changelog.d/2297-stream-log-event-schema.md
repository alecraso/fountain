### Added

- API: the SSE frame each stream sends is now a described `StreamLogEvent`
  schema instead of a bare string (#2297) — `GET /api/conversations/:id/stream`,
  `GET /api/events` and `GET /api/team/stream` all declare it on their
  `text/event-stream` response. The frame's actual fields are unchanged;
  a generated client can now decode it with a typed model instead of the
  operation's prose description alone.
