### Fixed

- Interrupting a conversation whose server is dead and whose sandbox is dead
  or stranded (gone, never provisioned, or stuck `pending`/`starting` with
  no server ever turning up) now reconciles the orphaned turn instead of
  provisioning a fresh sandbox; the call answers `not_running` rather than
  spinning up a machine and then timing out to `provisioning` (#2175).
