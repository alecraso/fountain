### Fixed

- Interrupting a conversation whose server is dead and whose sandbox can no
  longer be reused now reconciles the orphaned turn instead of provisioning
  a fresh sandbox; the call answers `not_running` rather than spinning up a
  machine and then timing out to `provisioning` (#2175).
