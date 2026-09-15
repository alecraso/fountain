# Swift wire-model generation inventory

Tracked by [#2251](https://github.com/managoat/fountain/issues/2251).
The generator reads the committed contract and does not require Elixir to run.

| Family | Disposition |
|---|---|
| Conversation, Turn, ImageInput, ConversationCreateRequest and referenced permission/model-selection objects | Generated in the foundation |
| Usage / UsageAccounting | Generated. Usage is the source-compatible union of TurnUsage and UsageTotal; either schema can add fields, and incompatible shared definitions fail generation |
| Sandbox, SandboxDetail, Sandbox.Checkpoint, Sandbox.RunnerRef, SandboxDetail.SandboxConversation, Runner | Generated from the contract; the shared inline definitions must match |
| ConversationTreeNode | Generated; no handwritten field/CodingKey declarations remain |
| Agent, Skill, AgentVersion, AgentInput | Next resource batch: preserve names, initializer order, nullable policy values and the create/update convenience |
| Environment, EnvironmentInput, Vault, VaultInput, Secret | Next resource batch: preserve JSONValue conveniences and the shared environment/vault secret shape |
| Connection, ConnectionProvider, Teammate and nested types, TeamSchedule/Input | Next resource batch: retain unknown enum handling and derived teammate identity |
| APIKey, CreatedAPIKey, AuditEvent, SearchHit, Catalog/nested types, ApplyResult/nested types, AdminUser, AdminSandbox, AdminEvent | Next resource batch: generate endpoint payload shapes, including shapes nested inside envelopes |
| AuthMe | Requires a compatibility decision for `onboardingState`, which is absent from the current wire contract |
| AdminUserPage | Keep the page/hasMore convenience; its envelope decoding can consume generated wire data |
| ConversationBindingUpdate / ConversationReapplyRequest | Keep the public three-state binding behavior; the underlying wire body can use generated fields |
| LogEvent, Block, PermissionOption, PermissionRequest | Keep stream normalization and behavior separate from generation; inventory the raw/normalized contract differences before replacing these models |
| JSONValue, ConversationInputField and WireValue / enum wrappers | Intentionally handwritten value/behavior types; their raw-string decoding preserves unknown server values |
| Swift Fountain map product | Uses JSON objects rather than duplicated typed wire properties; remains supported |

## Compatibility rules

Existing nested public names remain intact. The generator retains seven existing
optional-property APIs in `OPTIONAL_COMPAT`: Sandbox and SandboxDetail spriteName
and status, SandboxDetail conversations, Sandbox.RunnerRef online, and Runner
createdAt. Their historically permissive decoding remains supported. This is a
finite compatibility exception, not a list of fields to extend for new API work.
New fields use contract requiredness/nullability directly.

Keep endpoint and behavioral contract assertions. Generation replaces field
registrations, not evidence that resource methods call the correct routes or
that the stream follower handles errors and permissions.

Checks: `python3 scripts/sdk-contract/generate-swift.py --check`,
`python3 -m unittest discover -s scripts/ci -p test_swift_generation.py`, and
`swift test -Xswiftc -warnings-as-errors`. Synthetic additions to every generated
family verify propagation without adding fake production API fields.
