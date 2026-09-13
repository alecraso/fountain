# Run a release task

This guide shows you how to run an operator action that touches data. Each one
of them uses the same pattern.

## The pattern

Compose:

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.verify_email("you@example.com")'
```

Kubernetes:

```bash
kubectl exec -n fountain deploy/fountain -- \
  sh -c "PHX_SERVER=false bin/fountain_server eval 'Fountain.Release.verify_email(\"you@example.com\")'"
```

`eval` starts the database connection and nothing else. It never starts the
app. So a task cannot compete with the live server for ports, for background
jobs, or for conversation processes.

`PHX_SERVER=false` says that out loud in a container that sets it `true`.
Include it, and the pattern is always safe to paste.

## The tasks

| Task | What it does |
|---|---|
| `Fountain.Release.verify_email("a@b.c")` | Marks an account's email verified, and sends nothing. It is the escape hatch for a mail provider that broke. Since ADR 0011, `EMAIL_DELIVERY=none` self-verifies at registration. |
| `Fountain.Release.promote_admin("a@b.c")` | Grants the admin role. The admin audit trail records it under a system actor. It is the manual alternative to `FIRST_USER_ADMIN=true` (ADR 0011). |
| `Fountain.Release.rebuild_credit_lots()` | Replays every credit ledger and rewrites the lots. Safe to rerun. |
| `Fountain.Release.inventory_sandbox_metadata()` | Prints retained sandbox IDs and counts of absent build and skill metadata. Read-only. Disk manifests remain unverified. |
| `Fountain.Release.backfill_turn_replies()` | Fills the reply column on each turn that closed before the column existed. Safe to rerun. |
| `Fountain.Release.migrate()` | Runs the migrations that are due, by hand. It is what `bin/migrate` runs. They already run at each boot, unless `MIGRATE_ON_BOOT=false`. In that case this, in a Job before the rollout, is how they run at all. That switch never skips it. |
| `Fountain.Release.rollback(Fountain.Repo, version)` | Rolls migrations back to a version. It is a last resort. Read [Upgrade an instance](upgrade.md) first. |

## Inventory older sandbox metadata

Run this read-only task before a rollout that changes old sandbox metadata.

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.inventory_sandbox_metadata()'
```

The JSON report includes every sandbox row whose status is not `terminated`.
It lists sandbox and owner IDs, status, provider, mode and metadata presence.
Counts include active, suspended, failed and unfinished builds. A `pending` or
`starting` build can lack metadata because provision has not finished.

`build_fingerprint_recorded` and `applied_skills_recorded` report database
presence only. The task reads no skill content or provider metadata. It makes
no provider request, wakes no sandbox and changes no row. Repeated calls
return the same report while the database remains unchanged.

`disk_skill_manifests` is always `unverified`. A non-null `applied_skills` value
does not prove that a manifest still exists on disk. This report cannot certify
that all live or dormant disks have completed a migration.

A sandbox with no recorded build fingerprint refuses a configuration reapply
with `409 rebuild_required` and `field: "environment"`. The message explains
that the original build inputs are unknown. The current Environment may have
changed since provision, so do not populate a fingerprint from that row.
Retries leave the selection, configuration revision and disk unchanged.

Ordinary wake still reconciles skills through the current manifest path.
It records the applied selection only after reconciliation succeeds. This
preserves the recovery for named skills, unnamed GitHub skills and older
source locks. Reconciliation never supplies an absent build fingerprint.

To apply a different configuration, start a new conversation on a fresh
sandbox, without an explicit old `sandbox_id`. A persistent agent home can
reuse its old disk; choose a new agent or explicitly rebuild that home.
To rebuild this conversation's machine, first copy any work you need from its
disk. Then request `DELETE /api/sandboxes/:id`. That action destroys the old
disk; the next prompt provisions a fresh one and records its build inputs.
The conversation and transcript survive.

These rules apply to hosted and self-hosted instances. They also apply to
disks that remain dormant through an upgrade. Issue #2102 stays open for disk inventory
and migration evidence before removal of the legacy skill-manifest recovery.

## Warnings

Use `rollback/2` to reverse one migration that you understand. Do not attempt
to reverse a whole release's migrations on production data.


## Related

- [Upgrade an instance](upgrade.md).
- [Start billing](billing.md). <!-- vale disable-line STE.IngForms -->
- [Nobody can log in](../../troubleshooting/nobody-can-log-in.md), which is
  where `verify_email/1` matters.
