### Added

- **A conversation can be placed on a chosen runner** (arugula fork). `POST
  /api/conversations` takes an optional `runner_id` for an agent on the runner
  provider. It is refused with 404 `runner_not_found` for a runner that is not
  the caller's, 409 `no_runner_online` for one that is offline, and 422
  `runner_id_not_applicable` or `runner_id_with_sandbox` otherwise. Without it
  the most recently connected runner is still used.
