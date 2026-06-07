# Workflows

Set your connection once:

```sh
export NETBOX_URL=https://netbox.example.com
export NETBOX_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## Low-risk change

A change that touches only allowed fields (`description`, `comments`, `tags`,
`custom_fields`) needs no approval.

```sh
nbx-guard plan device 1 --set description="edge router"
# -> { plan_id, plan_hash, risk_level: "low", status: "planned",
#      next_action: "low-risk: run `nbx-guard apply --plan <plan_id>`" }

nbx-guard apply --plan plan_...      # snapshots a backup, PATCHes, writes audit
nbx-guard restore --backup bkp_...   # revert if needed
```

## High-risk change (requires approval)

A change that touches any high-risk field (`status`, `role`, `site`, `rack`, `prefix`,
`address`) must be approved first.

```sh
nbx-guard plan device 1 --set status=active
# -> status: "pending_approval", next_action: "...approve... then apply"

nbx-guard apply --plan plan_...
# refused: error.kind = "not_approved"

nbx-guard approve --plan plan_... --note "approved by netops"
nbx-guard apply --plan plan_...      # now allowed
```

## Denied change

A change to a field outside the policy is rejected at plan time — nothing is stored:

```sh
nbx-guard plan device 1 --set name="core-1"
# -> error.kind = "policy_denied" (name is not a writable field)
```

## Inspecting before proposing

An agent can look at a resource together with the policy to decide what it may safely
propose:

```sh
nbx-guard inspect device 1
# data.resource = live resource; data.policy = allowed/high-risk fields
```

## Auditing and listing

```sh
nbx-guard audit                 # full audit trail
nbx-guard audit --plan plan_... # only events for one plan
nbx-guard list plans            # stored plans
nbx-guard list approvals        # stored approvals
nbx-guard list backups          # stored backups
```

## Recommended agent loop

1. `inspect` the resource to learn which fields are writable.
2. `plan` the intended change.
3. Read `next_action` from the envelope:
   - `low` risk → `apply`.
   - `high` risk → ask a human to `approve`, then `apply`.
4. Keep the returned `backup_id` so the change can be `restore`d.
5. Use `audit` / `request_id` to confirm and trace the outcome.
