# GitHub labels

Use label families to answer distinct questions. The label definitions are in
`.github/labels.json`. Keep names, colors and descriptions aligned with that file.
Colors identify a family; priority alone expresses urgency.

| Family | Meaning | Color |
| --- | --- | --- |
| `P0` / `P1` / `P2` / `P3` | Urgency and impact | Red / orange / yellow / pale yellow |
| `area:*` | Owning product or engineering area | Blue `1D76DB` |
| `lang:*` | Language or ecosystem | Pale blue `C5DEF5` |
| `type:*` | Nature of the work | Teal `007F8B` |
| `campaign:*`, `stack:*` | Program or PR-stack membership | Purple `8250DF` |
| `needs:*`, `release:*` | Required action or an explicit automation control | Amber `D4A72C` |
| `status:*`, `scope:*`, `resolution:*` | Deferral, scope or disposition | Gray `BDBDBD` |
| `good first issue` | Contributor-friendly entry point | Green `0E8A16` |

## Usage

- Choose a primary area and work type. Add secondary areas only when they help ownership.
- Priority is independent of size: `scope:large` does not imply P0 or P1.
- `needs:upstream` means a dependency change or release is required.
  `needs:external` means operator or vendor action such as credentials or verification.
  Use both only when both blockers remain.
- `status:deferred` requires a recorded decision and a condition for revisiting it.
  It is not a synonym for low priority or waiting for an upstream release.
- Trackers use `type:tracker`; executable children carry their own priority and work state.
- Campaign names use `campaign:<topic>-YYYY-MM`; PR stacks use `stack:<issue-number>`.
  `stack:root` and `stack:short` describe a PR's role or the stack's current extent.
- Keep `good first issue` in GitHub's conventional spelling.
- Project fields remain the source for execution scheduling. Do not infer a commitment from a label.

## Automation references

When changing label names, update Dependabot, issue templates, Review Loop and
release guards together. The SDK and changelog guards accept their prior labels
during migration so existing events and PRs retain the same behavior. Remove those
aliases only after the old references and active PR heads have been reconciled.

## Keeping definitions aligned

The Repository labels workflow runs from main when the manifest or synchronizer
changes. It can also be dispatched on main. It reconciles colors, descriptions
and names, preserving each renamed label's ID and existing issue/PR assignments.
It never deletes an unlisted label. A conflicting old/new pair stops before any
mutation so a maintainer can reconcile assignments without losing history.

Preview against GitHub with:

```bash
python3 scripts/sync-labels.py --repo managoat/fountain
```

The manifest's `previous_name` entries record the approved one-time migration.
Keep them while any supported PR or automation can still use the old names.
After a rename, check private Project filters manually: the repository workflow
cannot verify private Project views or saved searches.
