### Changed

- The OpenAPI document declares the permission policy once, as the
  `PermissionPolicy` component, instead of repeating it inline on `Agent`,
  `AgentRequest`, `AgentUpdate`, `Conversation` and `ConversationCreateRequest`
  (#1899). The wire shape is unchanged; the five properties are now a `$ref` to
  that component and keep their own descriptions. A generated client gains a
  named type where it had an anonymous object with the same body. TypeScript
  SDK 4.1.0 follows.
