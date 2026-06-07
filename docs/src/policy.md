# Policy

The policy engine is **default-deny**: a field may be written only if it is explicitly
classified. This is the heart of nbx-guard — even a fully-trusted agent cannot change a
field the policy does not know about.

## Field classes

| Class | Fields | Behavior |
| --- | --- | --- |
| Allowed (low-risk) | `description`, `comments`, `tags`, `custom_fields` | Applied directly. |
| High-risk | `status`, `role`, `site`, `rack`, `prefix`, `address` | Require approval. |
| Everything else | — | **Denied.** |

## How a plan is evaluated

When you create a plan, every field in `--set` is classified:

1. If **any** field is denied → the whole plan is rejected with
   `error.kind = "policy_denied"`. Nothing is stored.
2. Otherwise, if **any** field is high-risk → the plan's risk level is `high` and it
   enters `pending_approval`.
3. Otherwise → the plan's risk level is `low` and it is `planned`, ready to apply.

The decision is re-evaluated again at `apply` time against the *stored* changes
(defense in depth), so a plan that somehow no longer satisfies policy will not be
applied.

## Actions

Only the **`update`** action is permitted. `create`, `delete`, and `bulk_delete` are
refused by the policy engine, and the [NetBox client](./architecture.md) only exposes
`GET` and `PATCH` — there is no code path that can issue a `DELETE` or call an arbitrary
endpoint.

## Supported resource types

| Type | NetBox endpoint |
| --- | --- |
| `device` | `dcim/devices` |
| `interface` | `dcim/interfaces` |
| `ip-address` | `ipam/ip-addresses` |
| `prefix` | `ipam/prefixes` |
| `vlan` | `ipam/vlans` |

A resource type outside this set is rejected before any network call is made.

## Inspecting policy at runtime

- `nbx-guard help` lists the allowed and high-risk fields and the supported resource
  types.
- `nbx-guard inspect <type> <id>` returns the live resource annotated with the policy so
  an agent can see, per resource, which fields it is allowed to propose.
