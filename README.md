# nbx-guard

**Agent-only NetBox safe-change gateway, implemented in Zig.**

> 设计原则 / Design principle: **Agent 只提意图，CLI 决定能不能做。**
> The agent only proposes *intent*; the CLI decides what is actually allowed to happen.

nbx-guard sits between an LLM/agent and NetBox. The agent can never call the NetBox
API directly — it can only ask nbx-guard to *plan* a change. The CLI then enforces
policy, risk-based approval, pre-apply backup, audit logging, and restore. Even if the
agent claims it has full permissions, the approval rules are enforced here.

```
Agent / LLM ──> nbx-guard CLI (Zig) ──> NetBox REST API
                      │                  NetBox Branching
                      └─> local state: plans / backups / approvals / audit
                                         ▲
                                 human approver
```

## Core guarantees

- **Default-deny** — a field is writable only if policy explicitly classifies it.
- **Plan first** — no write happens without a stored `plan`; `apply` only accepts a `plan_id`.
- **Approval gate** — high-risk fields require an approval bound to the plan's `plan_hash`.
- **Backup before apply** — every apply snapshots the resource and the prior field values.
- **Audit everything** — append-only JSONL trace, every event links to `plan_id` / `approval_id` / `backup_id` / `request_id`.
- **Restorable** — any applied change can be reverted from its backup.
- **No raw / delete** — only `update` is permitted; `delete` / `bulk_delete` / raw API access are not exposed.
- **Agent-friendly JSON** — every command prints one envelope with `ok`, `data`, and an `error` carrying `kind`, `risk_level`, and `next_action`.

## Build & test

Requires **Zig 0.16.0**.

```sh
zig build           # produces ./zig-out/bin/nbx-guard
zig build test      # run unit tests
zig build run -- version
```

## Configuration

Set via environment (see `.env.example`):

| Variable | Default | Purpose |
| --- | --- | --- |
| `NETBOX_URL` | `http://localhost:8000` | NetBox base URL |
| `NETBOX_TOKEN` | _(unset)_ | API token; required for `get`/`inspect`/`apply`/`restore` |
| `NBX_GUARD_STATE_DIR` | `.nbx-guard` | Local state directory |
| `NBX_GUARD_BRANCHING` | `0` | Route reads/writes through a NetBox Branching branch |
| `NBX_GUARD_BRANCH` | _(unset)_ | Active branch schema id (sent as `X-NetBox-Branch`) |

When `NBX_GUARD_BRANCHING` is enabled **and** `NBX_GUARD_BRANCH` holds a branch's
schema id, every NetBox request carries the `X-NetBox-Branch: <schema_id>` header, so
guarded changes land in that branch instead of `main`. Create the branch and later
`sync`/`merge`/`revert` it via NetBox's own Branching API — those approver-level
lifecycle actions are intentionally outside the agent gateway.

## Policy (MVP)

| Class | Fields | Behavior |
| --- | --- | --- |
| Allowed (low-risk) | `description`, `comments`, `tags`, `custom_fields` | applied directly |
| High-risk | `status`, `role`, `site`, `rack`, `prefix`, `address` | require approval |
| Everything else | — | **denied** |

Supported resource types: `device`, `interface`, `ip-address`, `prefix`, `vlan`.

## Commands

```
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

`--set` values are parsed as JSON when possible (numbers, booleans, arrays, objects),
otherwise treated as strings — e.g. `--set description="edge router"`, `--set tags='["core"]'`.

## Workflow

### Low-risk change

```sh
export NETBOX_URL=http://netbox.local NETBOX_TOKEN=xxxx

nbx-guard plan device 1 --set description="edge router"
# -> { plan_id, plan_hash, risk_level: "low", status: "planned", next_action: "apply" }

nbx-guard apply --plan plan_...      # snapshots, PATCHes, writes audit + backup
nbx-guard restore --backup bkp_...   # revert if needed
```

### High-risk change (requires approval)

```sh
nbx-guard plan device 1 --set status=active
# -> status: "pending_approval", next_action: "approve"

nbx-guard apply --plan plan_...      # refused: error.kind = "not_approved"

nbx-guard approve --plan plan_... --note "approved by netops"
nbx-guard apply --plan plan_...      # now allowed
```

## Response envelope

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

`error.kind` is one of: `invalid_args`, `config_error`, `policy_denied`, `invalid_field`,
`needs_approval`, `not_approved`, `plan_not_found`, `approval_not_found`, `backup_not_found`,
`plan_state_error`, `netbox_error`, `conflict`, `io_error`, `not_implemented`.

Exit codes: `0` success, `2` client/policy/state error, `3` upstream/config/IO error.

## Local state layout

```
.nbx-guard/
├── plans/<plan_id>.json
├── approvals/<approval_id>.json
├── backups/<backup_id>.json
└── audit.jsonl
```

## Source layout

| File | Responsibility |
| --- | --- |
| `src/main.zig` | Entry point; builds `Context`, dispatches, sets exit code |
| `src/cli.zig` | Command layer / workflow orchestration |
| `src/context.zig` | Shared context + JSON response envelope + error model |
| `src/config.zig` | Environment-driven configuration |
| `src/policy.zig` | Default-deny field policy engine |
| `src/plan.zig` | Plan model, change parsing, deterministic `plan_hash` |
| `src/approval.zig` | Approval records bound to `plan_hash` |
| `src/backup.zig` | Pre-apply snapshots and prior-value capture |
| `src/audit.zig` | Append-only JSONL audit log |
| `src/netbox.zig` | NetBox REST client (GET / PATCH only) |
| `src/store.zig` | Local JSON/JSONL state storage |
| `src/ids.zig` | ID generation and SHA-256 hashing |

## Technology

- Language: **Zig 0.16**
- HTTP: `std.http.Client`
- JSON: `std.json`
- State: local JSON files + JSONL audit log

## Status

MVP. With NetBox Branching enabled, guarded changes are routed into a branch via the
`X-NetBox-Branch` header; branch lifecycle (`sync` / `merge` / `revert`) is handled
through NetBox's own Branching API. Without branching, the default apply mechanism is a
direct PATCH against `main`.
