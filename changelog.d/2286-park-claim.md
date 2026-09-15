### Changed

- A prompt that arrives while the sandbox reaper is parking a conversation's
  sandbox is now refused with 503 `sandbox_parking` and a `Retry-After`
  header, instead of racing the park (#2286).

### Fixed

- A wake could previously land on a sandbox the reaper was still suspending,
  leaving the database saying `ready` over a machine the provider had
  already paused (#2286).
