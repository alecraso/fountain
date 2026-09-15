# CLAUDE.md — Contributor Guide

Read by Claude Code and other coding agents at session start, and by people.
It holds the rules that are easy to get wrong, the commands, and links to the
one place each longer procedure lives. Keep it short; the detail belongs in
the files it points at.

| For | Read |
|---|---|
| Workstation setup, toolchain pins | [SETUP.md](SETUP.md) |
| Licensing, DCO, the local gate, flakes, API changes, PRs | [CONTRIBUTING.md](CONTRIBUTING.md) |
| CI jobs, the merge queue mechanics, coverage, partitions | [scripts/ci/README.md](scripts/ci/README.md) |
| Writing and checking manual pages | [contributing/docs.md](contributing/docs.md) |
| Component libraries (extraction is paused) | [contributing/component-libraries.md](contributing/component-libraries.md) |
| Why things are the way they are | [decisions/index.md](decisions/index.md) |
| Reference templates and GitHub labels | [standards/](standards/) |
| Configuration reference | [docs/configuration.md](docs/configuration.md), `.env.example` |

## Product and goal

What Fountain is, in one paragraph, is the top of [README.md](README.md).
The standing goal since the May-2026 launch is **100 weekly active users by
month 6** (November 2026). Org/team features stay out of scope until that
traction shows; onboarding is the open product decision on the way there
(#1039). This is the only place the goal is written down.

## Working with Review Loop

On a Review Loop PR, read the
[repository skill](.agents/skills/review-loop/SKILL.md) for bot commits, CI
repairs, human decisions and bounded retries. Report outcomes briefly.
`.github/review-loop.yml` and its referenced files remain the policy
authority. The skill is copied unchanged from
[Review Loop Action `9278790`](https://github.com/managoat/review-loop-action/blob/92787907f1b236d471555e3d231443582e46ce12/skills/review-loop/SKILL.md);
review upstream changes before replacing it.

## Commands

```bash
mise install                        # Erlang/OTP 28 + Elixir 1.19.2, from .tool-versions
mix deps.get && mix setup           # dev DB: create + migrate
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
mix test                            # core, ee/test and every sibling app
mix precommit                       # full local gate for code, CI policy and mixed changes
mix precommit --list                # its stages; `mix precommit credo test` runs a subset
gh pr merge <N> --squash --auto     # queue a reviewed PR; never --admin
```

Run every mix command through the pinned toolchain (activate mise, or
`mise exec -- mix ...`). `mix precommit` refuses a different Elixir.

## Repo layout

```
apps/fountain/             the server (AGPL-3.0): lib/fountain/ contexts, lib/fountain_web/ Phoenix
  test/support/            DataCase, ConnCase, factory.ex
apps/fountain_buzz/        the five first-party extensions (ADR 0043, 0054): AGPL OTP apps
apps/fountain_support/     that depend on :fountain, are named in `config :fountain,
apps/fountain_google/      :extensions` and are reached only through the `Fountain.Extension`
apps/fountain_microsoft/   callbacks. Core names no module of any (extension_guard_test.exs)
apps/fountain_slack/       and builds no connection provider of its own. Their suites run
                           from their own directories; `BUNDLE_EXTENSIONS=false` builds the
                           core distribution. A new callback on the behaviour needs an ADR.
ee/                        credits, Stripe and the credit emails, compiled into :fountain
                           (Elastic 2.0; ADR 0010, 0027). Account email + Mailer are core.
cli/, apps/fountain_buzz/cli   two Go modules (Apache-2.0); test each from its own directory
sdk/                       four clients against one OpenAPI contract (CONTRIBUTING.md)
config/                    config.exs, dev.exs, test.exs, prod.exs, runtime.exs
decisions/                 ADRs, an OKF bundle; start at decisions/index.md
docs/                      the public manual, served at /docs and nowhere else
standards/, contributing/  unpublished contributor material
scripts/                   the gates and the CI helpers (scripts/ci/README.md)
```

The nine `managoat_*` libraries (substitution, mcp_auth, oauth, acp, sandbox,
docs, broker, runner, runtimes) are hex packages pinned in
`apps/fountain/mix.exs`, not directories here. What each owns is tabled in
[contributing/component-libraries.md](contributing/component-libraries.md).

## The four primitives

| Primitive | Purpose |
|---|---|
| **Environment** | Baseline set of encrypted env vars + runtime config (packages, repos, scripts) attached to an agent. A conversation may name a different one at launch (`environment_id`, scoped by `agent.allowed_environment_ids`) |
| **Vault** | Free-floating bag of env-var overrides. Vault values **win on key collision** when merged with an environment at sandbox spawn |
| **Agent** | A named, re-runnable agent config: model, runtime, skills, MCP servers, optional environment |
| **Conversation** | A single run of an agent inside a sandbox. Has turns, log events, and a status lifecycle |

## Rules

### Tenant isolation

Every user-facing query is scoped by `user_id`: `Agents.get_agent(id, user_id)`,
`Agents.list_agents(user_id, filters)`. Functions that bypass scoping carry the
`_unsafe_` prefix, on *every* unscoped function, so a call site never has to
be researched. **Never call one as the first fetch in a user-facing request.**
Legitimate callers: an admin surface behind `require_admin`, a system sweep
(the rehydrator, `SandboxReaper`), a GenServer that already established
ownership, or a user-facing call site directly after a tenant-scoped parent
fetch, adjacent and in the same function, with a comment naming the fetch:

```elixir
# ownership established by the scoped get_vault above
vault = Vaults.get_vault(vault_id, user.id)
secrets = Vaults._unsafe_list_secrets(vault)
```

A credo check (`credo/checks/unsafe_call_ownership.ex`) enforces the shape.

### Secrets

Environment and vault values are envelope-encrypted with a per-tenant DEK
derived from `MASTER_SECRETS_KEY`:

```elixir
{:ok, dek} = Fountain.Crypto.load_tenant_key(user_id)
Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => "plaintext"}, dek)  # string keys
%{"TOKEN" => "plaintext"} = Environments.decrypted_env(env, dek)                    # a plain map
```

`Managoat.Substitution.apply(value, vars)` resolves `${VAR}` (and `$$` to `$`)
recursively through maps and lists, returning `{:ok, result}` or
`{:error, {:missing_vars, sorted_list}}` with **every** missing var.

### Audit

**Mutations audit in the context, not the caller** (ADR 0013). The context
records its own event; the caller supplies attribution only:

```elixir
def create_agent(attrs, opts \\ []) do
  %Agent{} |> Agent.changeset(attrs) |> Repo.insert() |> audited("agent.created", opts)
end
Agents.create_agent(attrs, Audited.attribution(conn))   # or (socket); actor: "system:<worker>" from a worker
```

- **Never audit inside a transaction.** `record/1` is best-effort by
  rescuing, and a rescue does not survive an aborted transaction.
- **Never record values.** Update events name changed fields
  (`Audit.changed_fields/1`); secret and credential events record keys, sizes
  and providers.
- **Only record what happened.** A rejected changeset or a no-op sync
  records nothing.

The actor vocabulary is closed (`self`, `ui`, `api`, `sprite`, `admin`,
`admin:<operator_id>`, `system:<worker>`); a bare `"system"` is a defect, so
the unauthenticated routes pass an explicit actor. `audit_guardrail_test.exs`
fails on a new context mutation until it audits or is excluded with a reason.
`Audit.record!/1` is test-only.

### Credits (ADR 0030, 0031)

There are no plans, tiers or subscriptions. `CREDITS_ENABLED` off means
nothing is priced, granted, gated or shown.

- **The gate is the balance.** `Billing.check_spend/1` (`Credits.gate/1`) is
  `:ok` with billing off, for a comped account, or a positive
  `credit_balance_cents`; else `{:error, :insufficient_credits}` (402). Every
  door that spends calls it, including the reservation lock in
  `Quotas.with_sandbox_reservation/3`. In-flight turns finish and may go
  negative. There is no router-level billing gate and no `check_active/1`.
- **The opening credit lands at email verification**, idempotent per
  account. In tests `insert_verified_user/1` holds $5 and may spend; drain it
  with a `burn_turn` debit to test refusal.
- **Concurrency is funded by the balance under a fleet ceiling.**
  `Quotas.sandbox_limit/1` clamps balance ÷ `SANDBOX_RESERVE_CENTS` between
  the floor and ceiling; `SANDBOX_FLEET_CEILING` is global and `:fleet_full`
  is 503, not 402. Anything that displays a cap uses `Quotas.sandbox_limit_for/1`.
- **A turn hour is not a sandbox hour.** Turns burn `turn_seconds` on
  platform-paid providers only; `busy_seconds` is the union of intervals and
  relates to a provider bill. Several conversations share one sandbox, so the
  two differ and must not be swapped.
- **The ledger** (`credit_ledger`, cached on `users.credit_balance_cents`) is
  idempotent per row and never summed on a gate; debits consume lots in order.

### Surfaces

The browser UI is an **operator console** (dashboard, agents, environments,
vaults, audit, keys, account, admin). Watching a conversation and messaging a
team are separate apps on `/api` ([managoat/demos](https://github.com/managoat/demos));
`Fountain.Apps` is the only place that knows where they live, and retired
`/conversations*`, `/team*` and `/onboarding*` URLs 404. **A
conversation-facing feature goes in the app; marketing copy goes in
[managoat/site](https://github.com/managoat/site)** (ADR 0034). The boundary is
`docs/concepts/surfaces.md`.

### Web plumbing

- `FountainWeb.Live.Hooks` `on_mount` guards: `require_authenticated_user`
  and `require_pending_verification` use `redirect` (`{:redirect, _}` in
  tests); `require_admin` sends a non-admin on with `push_navigate`
  (`{:live_redirect, _}`).
- `FountainWeb.Plugs.RateLimit` is ETS-backed per node and runs twice on
  `:api`, by IP before auth and by API key after. `config/test.exs` keys it
  per test process (`rate_limit_test_isolation`).
- `UeberAuthController` skips `plug Ueberauth` under `ueberauth_test_mode` so
  tests can set `conn.assigns` by hand.

### Tests

- `use Fountain.DataCase, async: true` for anything touching the database;
  `use ExUnit.Case, async: true` otherwise. StreamData and Mimic are
  installed; prefer real changesets over mocks.
- Factories are in `test/support/factory.ex`, imported by `DataCase`:
  `insert_verified_user()`, `insert_agent(user_id: ...)`, `insert_env`,
  `insert_vault`. `*_attrs/1` helpers return **string-keyed** maps.
- `mix test` at the umbrella root runs everything. From `apps/fountain`, which
  is what CI's partitions do, an ee file is `mix test ../../ee/test/...`;
  root-relative `ee/...` paths silently match nothing. An extension's suite
  runs from its own directory or the root, never from `apps/fountain`.
- A test that fails and then passes with no code change is investigated, not
  re-run: CONTRIBUTING.md, *If a test went red and then green*.

### Things not to do

- Don't call `_unsafe_*` without established ownership (above).
- Don't lower the test pool size below 20, and don't remove
  `ueberauth_test_mode` or `rate_limit_test_isolation` from `config/test.exs`.
- Don't add `async: false` unless the test genuinely needs global state.
- Don't start fire-and-forget work with `Task.async`: it links, nothing
  awaits it, and a transient failure takes the caller down (#1040). Use
  `Task.Supervisor.start_child(Fountain.TaskSupervisor, fun)`; `DataCase`
  waits for those before stopping the sandbox owner.
- Don't push to `main`, don't merge with `--admin`, and don't wait
  synchronously on a queued PR.
- Don't describe unbuilt behaviour as built in an ADR or a docstring. Say
  `**Status:** Proposed` or "not yet built", and remove the caveat in the PR
  that builds it.
- Check that an issue or PR reference supports the statement it accompanies.

## How a change lands

Every change is a PR with an approving review, queued with
`gh pr merge <N> --squash --auto`. GitHub builds the merge result before
letting it in, so nothing needs rebasing to be mergeable, a queued PR can
still be ejected by a real failure, and a queued PR builds as soon as the
queue is free, batched with whatever else queued while it waited. An
unreviewed PR never enters the queue and `--auto` looks stuck; check
`gh pr view <N> --json reviewDecision` first.
Stacked PRs land one stage at a time from the tip. A PR that changes
something a user or operator can observe adds a fragment under
`changelog.d/` (its README has the format); `CHANGELOG.md` itself is written
by the release. The mechanics and the CI job list are in
[scripts/ci/README.md](scripts/ci/README.md); the decision is ADR 0050.

## Docs and decisions

- For documentation-only changes, use the focused checks in
  [contributing/docs.md](contributing/docs.md); contributor-only Markdown
  needs no Elixir suite.
- `docs/` is published at `/docs` only. A page not in `docs/nav.yml` fails the
  suite, as does a dead internal link or anchor. The structural rules and
  writing guidance are in [contributing/docs.md](contributing/docs.md).
- Architecturally significant choices are ADRs in `decisions/`, an OKF
  bundle: copy `decisions/0001-template.md`, then run
  `scripts/decisions-index.sh` and `okf validate decisions` in the same PR.
  `okf backlinks decisions <id>` lists what depends on one before amending it.
