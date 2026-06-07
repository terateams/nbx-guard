# Configuration

All configuration is read from the **process environment** (see `.env.example` in the
repository). Nothing is written to NetBox without a token.

| Variable | Default | Purpose |
| --- | --- | --- |
| `NETBOX_URL` | `http://localhost:8000` | NetBox base URL. A trailing slash is stripped. |
| `NETBOX_TOKEN` | _(unset)_ | API token; **required** for `get` / `inspect` / `apply` / `restore`. |
| `NBX_GUARD_STATE_DIR` | `.nbx-guard` | Local state directory (plans, approvals, backups, audit log). |
| `NBX_GUARD_BRANCHING` | `0` | Route writes through the NetBox Branching plugin. |
| `NBX_GUARD_BRANCH` | _(unset)_ | Active branch schema id when branching is enabled. |

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
