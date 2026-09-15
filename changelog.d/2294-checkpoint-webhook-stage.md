### Added

- `conversation.checkpoint.done` and `conversation.checkpoint.failed` are
  now in the webhook catalogue, subscribable by name and documented (#2294).
  An endpoint already subscribed to `*` was receiving both; this only makes
  them nameable.
