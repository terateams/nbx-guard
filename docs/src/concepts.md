# Core Concepts

nbx-guard models a single, auditable lifecycle for every change. The agent only ever
produces the *first* step (intent); the CLI owns everything after that.

```text
plan ──> (approve) ──> apply ──> (restore)
  │           │           │           │
 policy    binds       backup +     reverts
 + risk   plan_hash     PATCH      from backup
```

## Plan

A **plan** captures the agent's intent: a resource (`type` + `id`), the action
(always `update` in the MVP), and a set of field `changes`. Creating a plan runs the
[policy](./policy.md) engine and assigns a risk level. Nothing is written to NetBox at
this stage.

Each plan has a status:

| Status | Meaning |
| --- | --- |
| `planned` | Low-risk plan, ready to `apply`. |
| `pending_approval` | High-risk plan, needs `approve` before it can be applied. |
| `approved` | A high-risk plan that has been approved. |
| `applied` | The change has been pushed to NetBox. |
| `rejected` | Reserved for a rejected plan. |

## `plan_hash`

Every plan has a deterministic **`plan_hash`** — a SHA-256 over the canonical
`{resource_type, resource_id, action, changes}`. It is the plan's tamper-evident
identity: an approval binds to this hash, so an approved plan cannot be silently
mutated and then applied.

## Risk level

The policy engine classifies the fields being changed:

- **low** — only allowed (low-risk) fields are touched → can be applied directly.
- **high** — at least one high-risk field is touched → requires approval.

If any field is outside the policy, the plan is **denied** outright. See
[Policy](./policy.md).

## Approval

An **approval** is a record bound to a plan's `plan_hash`. It records who approved it
(`USER`, or `cli` if unset), an optional note, and a timestamp. Only plans in
`pending_approval` can be approved.

## Backup

Before any `apply`, nbx-guard fetches the current resource and stores a **backup**
containing the full snapshot plus the *prior values* of exactly the fields being
changed. This is what `restore` uses to revert.

## Audit

Every meaningful event — `plan_created`, `approved`, `applied`, `apply_failed`,
`restored` — is appended to an append-only JSONL **audit** log. Each entry links the
relevant `request_id`, `plan_id`, `approval_id`, and `backup_id` so any change can be
traced end to end.

## Request id

Each command invocation that mutates state generates a `request_id`. It appears in the
response envelope and in the audit log, giving you a correlation handle across the plan,
approval, apply, and restore events.
