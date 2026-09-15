### Changed

- Swift SDK: `TeamResource`'s `add`, `rename` and `message` request bodies are
  generated from the contract rather than handwritten (#2300, part of
  #2251/#2269's follow-up in #2300). The public methods keep their existing
  signatures and wire behaviour, including `rename` always sending an
  explicit JSON `null` for a `nil` name rather than omitting the key.
  `PageMeta` and `APIErrorBody` are unchanged and stay handwritten,
  each its own follow-up.
