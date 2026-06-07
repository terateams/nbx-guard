# Configuration

All configuration is read from the **process environment** (see `.env.example` in the
repository). Nothing is written to NetBox without a token.

| Variable | Default | Purpose |
| --- | --- | --- |
| `NETBOX_URL` | `http://localhost:8000` | NetBox base URL. A trailing slash is stripped. |
| `NETBOX_TOKEN` | _(unset)_ | API token; **required** for `get` / `inspect` / `apply` / `restore`. |
| `NBX_GUARD_STATE_DIR` | `.nbx-guard` | Local state directory (plans, approvals, backups, audit log). |
| `NBX_GUARD_BRANCHING` | `0` | Route reads/writes through a NetBox Branching branch. |
| `NBX_GUARD_BRANCH` | _(unset)_ | Active branch schema id, sent as the `X-NetBox-Branch` header. |

## Boolean parsing

`NBX_GUARD_BRANCHING` is treated as **true** for `1`, `true`, `yes`, or `on`
(case-insensitive). Anything else — including unset — is **false**.

## Example `.env`

```sh
export NETBOX_URL=https://netbox.example.com
export NETBOX_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export NBX_GUARD_STATE_DIR=.nbx-guard
export NBX_GUARD_BRANCHING=0
```

## Where state lives

By default nbx-guard writes its plans, approvals, backups, and audit log under
`.nbx-guard/` in the current working directory. Point `NBX_GUARD_STATE_DIR` at a
durable, access-controlled location if you want the audit trail to persist across runs
or be shared by a team. See [Local State](./state.md) for the on-disk layout.

## Token handling

The token is read from the environment and sent as a `Token <token>` Authorization
header to NetBox. It is **never** written to the local state directory and never printed
in command output — `version` only reports `token_configured: true|false`.

## NetBox Branching

When `NBX_GUARD_BRANCHING` is enabled **and** `NBX_GUARD_BRANCH` holds a branch's schema
id, nbx-guard adds the `X-NetBox-Branch: <schema_id>` header to every NetBox request.
Reads, backups, and the apply PATCH are then scoped to that branch instead of `main`, so
an agent's guarded changes accumulate in an isolated branch for later review.

- The schema id is the eight-character identifier shown in a branch's REST API
  representation or detail view — **without** the `branch_` prefix.
- If branching is off, or the schema id is empty, no header is sent and writes go to
  `main` directly.
- `version` echoes the resolved active branch so you can confirm routing is on.

Creating a branch and running its `sync` / `merge` / `revert` lifecycle is done through
NetBox's own Branching API; those approver-level actions are deliberately not exposed by
the gateway. See [Architecture](./architecture.md#netbox-branching).
