# Local State

nbx-guard keeps all of its state in a single directory (default `.nbx-guard/`, override
with `NBX_GUARD_STATE_DIR`). Everything is plain JSON / JSONL so it is easy to inspect,
back up, and audit.

```text
.nbx-guard/
├── plans/<plan_id>.json
├── approvals/<approval_id>.json
├── backups/<backup_id>.json
└── audit.jsonl
```

## Identifiers

IDs are prefixed and time-ordered so they sort chronologically and are easy to recognise
in logs:

| Prefix | Example | Created by |
| --- | --- | --- |
| `plan_` | `plan_1730000000_a1b2c3` | `plan` |
| `req_` | `req_1730000000_d4e5f6` | every mutating command |
| `appr_` | `appr_1730000000_7890ab` | `approve` |
| `bkp_` | `bkp_1730000000_cdef01` | `apply` |

The form is `<prefix>_<unix_seconds>_<6 hex random>`.

## Plans

Each plan file stores the intent and verdict: `plan_id`, `request_id`, `plan_hash`,
`resource_type`, `resource_id`, `action`, `changes`, `risk_level`, `requires_approval`,
`status`, optional `approval_id` / `backup_id`, `created_at`, and `netbox_url`.

## Approvals

An approval binds to a plan's `plan_hash`: `approval_id`, `plan_id`, `plan_hash`,
`resource_type`, `resource_id`, `risk_level`, `status`, `approver`, `created_at`, and an
optional `note`. Because it carries the hash, an approval cannot be transplanted onto a
different (mutated) plan.

## Backups

A backup captures what is needed to revert: `backup_id`, `plan_id`, `resource_type`,
`resource_id`, the full `snapshot` taken just before applying, the `prior_values` of the
changed fields, `created_at`, and `netbox_url`. `restore` replays `prior_values`.

## Audit log

`audit.jsonl` is **append-only**; one JSON object per line. Events include
`plan_created`, `approved`, `applied`, `apply_failed`, and `restored`. Each entry carries
a timestamp and the relevant `request_id`, `plan_id`, `approval_id`, and `backup_id`, so
any change can be traced from intent to outcome (and to its reversal).

## Operational notes

- Treat the state directory as the **source of truth** for what was changed and by whom;
  store it somewhere durable and access-controlled in production.
- The directory contains no secrets — the NetBox token is never persisted here.
- The repository's `.gitignore` excludes `.nbx-guard/` so local runs are not committed.
