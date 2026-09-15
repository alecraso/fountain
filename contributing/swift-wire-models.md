# Swift wire-model generation inventory

Tracked by [#2251](https://github.com/managoat/fountain/issues/2251).
The generator reads the committed contract and does not require Elixir to run.

| Family | Disposition |
|---|---|
| Conversation, Turn, ImageInput, ConversationCreateRequest and referenced permission/model-selection objects | Generated in the foundation |
| Usage / UsageAccounting | Generated. Usage is the source-compatible union of TurnUsage and UsageTotal; either schema can add fields, and incompatible shared definitions fail generation |
| Sandbox, SandboxDetail, Sandbox.Checkpoint, Sandbox.RunnerRef, SandboxDetail.SandboxConversation, Runner | Generated from the contract; the shared inline definitions must match |
| ConversationTreeNode | Generated; no handwritten field/CodingKey declarations remain |
| Agent, Skill, AgentVersion, AgentInput | Generated; preserve names, initializer order, numeric policy values, explicit nullable inputs and the create/update convenience |
| Environment, EnvironmentInput, Vault, VaultInput, Secret | Generated; preserve JSONValue conveniences. Secret unions the environment/vault schemas and rejects conflicting shared definitions |
| Connection, ConnectionProvider, Teammate and nested types, TeamSchedule/Input | Generated; retain unknown enum handling and derived teammate identity |
| APIKey, CreatedAPIKey, AuditEvent, SearchHit, Catalog/nested types, ApplyResult/nested types, AdminUser, AdminSandbox, AdminEvent | Generated from endpoint payload shapes, including shapes nested inside envelopes |
| AuthMe | Remaining migration [#2269](https://github.com/managoat/fountain/issues/2269): decide compatibility for `onboardingState`, absent from the current wire contract |
| AdminUserPage | Remaining migration #2269: retain page/hasMore behavior while deriving its data/meta envelope |
| ConversationBindingUpdate / ConversationReapplyRequest | Remaining migration #2269: retain three-state bindings while deriving underlying wire fields |
| LogEvent, Block, PermissionOption, PermissionRequest | Remaining migration #2269: inventory raw/normalized differences and preserve custom decoding and stream/permission behavior |
| JSONValue, ConversationInputField and WireValue / enum wrappers | Intentionally handwritten value/behavior types; their raw-string decoding preserves unknown server values |
| Swift Fountain map product | Uses JSON objects rather than duplicated typed wire properties; remains supported |
| PageMeta (`Client/APIClient.swift`), APIErrorBody (`Errors/FountainError.swift`), TeamResource request bodies | Contract-shaped but handwritten outside `Models/`; unmigrated and outside #2269's four seams |

## Compatibility rules

Existing nested public names and initializer order remain intact. A model that
already shipped by hand must not become harder to decode, so `OPTIONAL_COMPAT`
keeps two kinds of property optional even where the current server requires
them: properties that were historically optional, and properties this SDK
exposes for the first time on a type that already shipped. The second kind is
why a response from an older server still decodes rather than failing whole.
The table is finite and auditable: it grew from 9 entries over 5 owner types
(sandbox and runner models) to 55 over 21 as the resource families landed.
Wholly new types take contract requiredness directly.
`test_optional_compat_pins_reach_a_live_property` fails when a pin stops
naming a live property, and `ResourceWireTests` decodes payloads that omit the
pinned keys.

The 19 `TYPE_OVERRIDES` entries retain existing `JSONValue` APIs for
deliberately dynamic payloads: metadata, packages, networking config,
repositories, MCP servers, agent-version config and apply errors. Neither
table is a registry to extend for ordinary API additions. Aliased Skill
definitions must agree, and Secret reads both environment and vault schemas.
Conflicting shared definitions fail generation.

Agent inputs expose numeric policy values through `permissionPolicyValues`
while retaining the string-only initializer/property. Nullable generated inputs
use `setNull` for explicit JSON null; assigning nil restores omission. Endpoint
create/update validation remains server-owned.

Keep endpoint and behavioral contract assertions. Generation replaces field
registrations, not evidence that resource methods call the correct routes or
that the stream follower handles errors and permissions.

Checks: `python3 scripts/sdk-contract/generate-swift.py --check`,
`python3 -m unittest discover -s scripts/ci -p test_swift_generation.py`, and
`swift test -Xswiftc -warnings-as-errors`. Synthetic additions to every generated
family verify propagation without adding fake production API fields.
