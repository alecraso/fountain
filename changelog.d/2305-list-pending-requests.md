### Fixed

- `GET /api/conversations` and `POST /api/conversations` now carry
  `pending_requests` on every conversation, as an empty array unless
  `GET /api/conversations/{id}` reports a real one waiting (#2305).
