# Response Format

Every command prints exactly **one** JSON envelope to stdout and nothing else, so an
agent can parse the result deterministically.

## Envelope

```json
{
  "ok": true,
  "command": "plan",
  "data": { "...": "command-specific payload" },
  "error": null
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `ok` | bool | `true` on success, `false` on failure. |
| `command` | string | The command that produced this envelope. |
| `data` | object \| null | Command-specific payload on success; `null` on failure. |
| `error` | object \| null | Structured error on failure; `null` on success. |

## Error object

```json
{
  "ok": false,
  "command": "apply",
  "data": null,
  "error": {
    "kind": "not_approved",
    "message": "high-risk plan requires approval before apply",
    "risk_level": "high",
    "next_action": "run `nbx-guard approve --plan <plan_id>` first"
  }
}
```

| Field | Meaning |
| --- | --- |
| `kind` | Stable, machine-readable error category (see below). |
| `message` | Human-readable explanation. |
| `risk_level` | `low` or `high`. |
| `next_action` | What the agent (or a human) should do next. |

## Error kinds

`error.kind` is always one of:

| Kind | Typical cause |
| --- | --- |
| `invalid_args` | Unknown command or missing/invalid arguments. |
| `config_error` | Configuration problem (e.g. missing token where required). |
| `policy_denied` | A requested field is not writable (default-deny). |
| `invalid_field` | A field value is not acceptable. |
| `needs_approval` | The plan is high-risk and not yet approved. |
| `not_approved` | `apply` attempted on an unapproved high-risk plan. |
| `plan_not_found` | No plan with the given id. |
| `approval_not_found` | No approval with the given id. |
| `backup_not_found` | No backup with the given id. |
| `plan_state_error` | Plan is in the wrong state for the operation. |
| `netbox_error` | NetBox returned an error or was unreachable. |
| `conflict` | The resource changed underneath the plan. |
| `io_error` | Local state read/write failed. |
| `not_implemented` | Feature not available in this build. |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `2` | Client / policy / state error (your input or local state). |
| `3` | Upstream / configuration / IO error (NetBox, env, disk). |

This lets a caller branch on the exit code first, then read `error.kind` for detail.
