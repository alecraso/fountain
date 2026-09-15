### Changed

- Swift SDK: `PageMeta` is generated from the contract's cursor envelope
  rather than handwritten (#2300). `hasMore`, `limit` and `nextCursor` keep
  their Optional types. `offset` is no longer on `PageMeta`: it was only ever
  sent by `GET /api/search`, which pages by offset, and now lives on the
  generated `SearchResponse.Meta`, whose members are non-Optional.
  `Page<T>` is now `Page<Items, Meta>`, so `audit.list` and
  `conversations.events` return `Page<[…], PageMeta>` and `search.search`
  returns `Page<[SearchHit], SearchResponse.Meta>`; code that spelled the old
  one-parameter type has to name the meta. `page.meta?.hasMore` and
  `page.meta?.nextCursor` read as before. `APIErrorBody` stays handwritten.
