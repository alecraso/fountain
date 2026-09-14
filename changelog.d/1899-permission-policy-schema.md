### Changed

- The OpenAPI document declares the permission policy once, as the
  `PermissionPolicy` component, instead of repeating it inline on `Agent`,
  `AgentRequest`, `AgentUpdate`, `Conversation` and `ConversationCreateRequest`
  (#1899). The wire shape is unchanged: the five properties are now a `$ref` to
  that component, keep their own descriptions, and still accept the `null` a
  policy-less agent or conversation carries. A generated client gains a named
  type where it had an anonymous object with the same body. TypeScript SDK
  4.1.0 follows.

### Fixed

- `POST /api/agents` and `PUT /api/agents/{id}` accept `"permission_policy":
  null` and store an empty policy, which is what the OpenAPI document has
  promised since the field existed. A null used to pass the schema and the
  changeset and come back as a 500 from the database's not-null constraint
  (#1899).
- `scripts/sdk-contract/build.sh` refuses a document where a property says
  `nullable: true` and a standards validator would still reject `null` (#1899).
  In OpenAPI 3.0 `nullable` relaxes the type of the node it sits on, so a
  property that borrows its shape from `allOf`/`oneOf` needs the composition to
  admit null too. Nothing in the server's own casting can see the difference.
  Two properties already in that state, `Conversation.sandbox` and `Turn.usage`,
  are recorded in the guard's ratchet and tracked in
  https://github.com/managoat/fountain/issues/2189.
