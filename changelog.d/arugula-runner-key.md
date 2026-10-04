### Added

- **A runner key connects one named runner and nothing else** (arugula fork).
  `POST /api/runners/keys` with `{"name"}` mints a key, shown once, that
  authenticates only at `GET /api/runners/ws` and only for that name. Any other
  route answers 403 `insufficient_scope` and another name answers 403
  `runner_name_mismatch`. Minting needs a full-scope key. Revoking the key also
  closes the runner's open connection. `GET /api/auth/api-keys` lists
  `runner_name`.
