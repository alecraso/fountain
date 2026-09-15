### Changed

- A prompt that arrives while the sandbox reaper is parking a conversation's
  sandbox is now refused with 503 `sandbox_parking` and a `Retry-After`
  header, instead of racing the park (#2286). None of the client SDKs map
  this code to their retryable "not ready" error yet — see #2291 — so it
  currently surfaces as each SDK's generic API error.

### Fixed

- A wake could previously land on a sandbox the reaper was still suspending,
  leaving the database saying `ready` over a machine the provider had
  already paused (#2286).
- A crash or a lost race left a sandbox parked at the provider while its
  row still said `ready` with no way back; the next wake now reconciles
  against the provider's own state instead of trusting the row (#2286).
- A scheduled team prompt that fired while its sandbox was mid-park was
  silently dropped instead of retried, the same way a busy or provisioning
  teammate already retries (#2286).
