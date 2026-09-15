### Fixed

- Swift SDK: generation now refuses a model that stops declaring a property
  the last release published, unless the removal is recorded as deliberate
  (#2303, closing #2296). The two existing compatibility rules compare
  *optionality*, so a property that vanished outright — a contract that drops
  it, a generator shape that quietly stops emitting it — passed both and was
  caught only by the handwritten `PublicSurfaceTests`, and only for the
  families those name. A property still counts as present when it comes from
  the type's field list, a computed property the generator adds, or a
  handwritten extension, so the rule tracks the SDK's public surface rather
  than one code path; a deliberate removal is recorded with the PR and
  changelog fragment that made it, and the first such entry is
  `AuthMe.onboardingState`, retired in #2269.
