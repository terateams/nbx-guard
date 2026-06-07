# Command Reference

Every command prints exactly **one** JSON envelope (see [Response Format](./responses.md))
and sets an exit code. Commands that read or write NetBox require `NETBOX_TOKEN`.

```text
nbx-guard version                          Print version and active configuration
nbx-guard help                             Show help
nbx-guard get <type> <id>                  Read a resource (read-only)
nbx-guard inspect <type> <id>              Read a resource annotated with field policy
nbx-guard plan <type> <id> --set k=v ...   Create a change plan (policy + risk checked)
nbx-guard approve --plan <id> [--note x]   Approve a high-risk plan (binds plan_hash)
nbx-guard apply --plan <id>                Backup, then apply an approved/low-risk plan
nbx-guard restore --backup <id>            Revert a resource from a backup snapshot
nbx-guard audit [--plan <id>]              Show the audit log
nbx-guard list <plans|approvals|backups>   List local state
```

## `version`

Prints the version and active configuration (`netbox_url`, `branching`, `state_dir`,
`token_configured`). No network access. Also available as `--version` / `-v`.

## `help`

Prints usage, the command list, supported resource types, the allowed/high-risk field
lists, and the recognized environment variables. Also available as `--help` / `-h`.
Running with no arguments prints help.

## `get <type> <id>`

Reads a resource from NetBox and returns it verbatim under `data.resource`. Read-only.
Requires a token.

## `inspect <type> <id>`

Like `get`, but annotates the response with the field policy (`allowed_fields`,
`high_risk_fields`) so an agent can see which fields it may propose. Requires a token.

## `plan <type> <id> --set field=value ...`

Creates a change plan. Steps:

1. Validates the resource type.
2. Parses `--set` pairs into a changes object.
3. Runs the policy engine; a denied field aborts with `policy_denied`.
4. Stores the plan and appends a `plan_created` audit entry.

The response includes the full `plan`, the policy `evaluation`, and a `next_action`
telling you whether to `approve` (high-risk) or `apply` (low-risk) next.

### `--set` value parsing

Values are parsed as JSON when possible, otherwise treated as strings:

```sh
nbx-guard plan device 1 --set description="edge router"   # string
nbx-guard plan device 1 --set status=active               # string "active"
nbx-guard plan device 1 --set tags='["core"]'             # JSON array
nbx-guard plan vlan 10 --set custom_fields='{"x":1}'      # JSON object
```

`--set k=v`, `--set=k=v`, and a bare `k=v` are all accepted.

## `approve --plan <id> [--note <text>]`

Approves a plan that is in `pending_approval`. Creates an approval record bound to the
plan's `plan_hash`, moves the plan to `approved`, and appends an `approved` audit entry.
The approver is taken from `$USER` (or `cli`). Approving a plan that is not awaiting
approval fails with `plan_state_error`.

## `apply --plan <id>`

Applies a plan. Requires a token. Steps:

1. Refuses if the plan is already `applied` (`plan_state_error`).
2. Refuses a high-risk plan that is not `approved` (`not_approved`).
3. Re-validates policy on the stored changes.
4. Fetches the current resource and writes a **backup** (snapshot + prior values).
5. `PATCH`es NetBox with the changes.
6. On success: marks the plan `applied`, links the `backup_id`, appends an `applied`
   audit entry, and returns a `diff` (`before` / `after`) plus the updated `resource`.

If NetBox rejects the change or the connection fails, an `apply_failed` audit entry is
written and the command reports a `netbox_error`.

## `restore --backup <id>`

Reverts a resource by `PATCH`ing the **prior values** captured in the backup. Requires a
token. Appends a `restored` audit entry and returns the restored resource. A missing
backup id fails with `backup_not_found`.

## `audit [--plan <id>]`

Prints the audit log, optionally filtered to a single `--plan <id>`. Returns a `count`
and the matching `entries`.

## `list <plans|approvals|backups>`

Lists the stored JSON records of the given kind. Returns `kind`, `count`, and the raw
`items`. An empty/absent directory yields `count: 0`.
