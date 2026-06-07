# Introduction

**nbx-guard** is an agent-only [NetBox](https://netbox.dev/) safe-change gateway,
implemented in [Zig](https://ziglang.org/).

> **Design principle:** the agent only proposes *intent*; the CLI decides what is
> actually allowed to happen.

nbx-guard sits between an LLM/agent and NetBox. The agent can never call the NetBox
API directly — it can only ask nbx-guard to *plan* a change. The CLI then enforces
policy, risk-based approval, pre-apply backup, audit logging, and restore. Even if the
agent claims it has full permissions, the approval rules are enforced here.

```text
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
- **Audit everything** — append-only JSONL trace; every event links to
  `plan_id` / `approval_id` / `backup_id` / `request_id`.
- **Restorable** — any applied change can be reverted from its backup.
- **No raw / delete** — only `update` is permitted; `delete` / `bulk_delete` / raw
  API access are not exposed.
- **Agent-friendly JSON** — every command prints one envelope with `ok`, `data`, and an
  `error` carrying `kind`, `risk_level`, and `next_action`.

## Who is this for?

- **Platform / NetOps teams** who want to let an agent propose NetBox changes without
  granting it unmediated write access.
- **Agent authors** who need a deterministic, machine-readable contract (one JSON
  envelope per command) for proposing and applying changes.

## Status

MVP. NetBox Branching (`diff` / `sync` / `merge`) is configurable but the direct-PATCH
path is the default apply mechanism in this version.

Continue with [Getting Started](./getting-started.md).
