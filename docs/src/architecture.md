# Architecture

nbx-guard is a small, layered Zig program. The agent only reaches the **command layer**;
every guarantee is enforced below it, and only one component may talk to NetBox.

```text
        argv
          │
   ┌──────▼───────┐
   │   cli.zig    │  parse, orchestrate workflow, print one JSON envelope
   └──┬───┬───┬───┘
      │   │   │
 policy  plan/approval/backup/audit        netbox.zig ── GET / PATCH only ──> NetBox
 (deny)  (state via store.zig + ids.zig)
```

## Source layout

| File | Responsibility |
| --- | --- |
| `src/main.zig` | Entry point; builds `Context`, dispatches, sets the exit code. |
| `src/cli.zig` | Command layer / workflow orchestration. |
| `src/context.zig` | Shared context + JSON response envelope + error model. |
| `src/config.zig` | Environment-driven configuration. |
| `src/policy.zig` | Default-deny field policy engine. |
| `src/plan.zig` | Plan model, change parsing, deterministic `plan_hash`. |
| `src/approval.zig` | Approval records bound to `plan_hash`. |
| `src/backup.zig` | Pre-apply snapshots and prior-value capture. |
| `src/audit.zig` | Append-only JSONL audit log. |
| `src/netbox.zig` | NetBox REST client (GET / PATCH only). |
| `src/store.zig` | Local JSON/JSONL state storage. |
| `src/ids.zig` | ID generation and SHA-256 hashing. |
| `src/root.zig` | Library re-exports and unit-test aggregator. |

## Design choices that enforce the guarantees

- **One write verb.** `netbox.zig` exposes only `get` (GET) and `patch` (PATCH). There is
  no function that performs DELETE or calls an arbitrary path, so "no raw / no delete" is
  a structural property, not a runtime check.
- **Policy is consulted twice.** At `plan` time and again at `apply` time against the
  *stored* changes, so a plan cannot drift out of policy between proposal and application.
- **Approval binds to `plan_hash`.** Because the hash covers the canonical
  `{resource_type, resource_id, action, changes}`, an approved plan cannot be edited and
  re-applied without invalidating the binding.
- **Backup precedes the write.** `apply` always snapshots before it PATCHes, so every
  applied change is reversible via `restore`.
- **Single output contract.** `context.zig` is the only place that prints; every command
  emits exactly one `{ ok, command, data, error }` envelope.

## Technology

- Language: **Zig 0.16**
- HTTP: `std.http.Client`
- JSON: `std.json`
- Hashing: `std.crypto.hash.sha2.Sha256`
- State: local JSON files + a JSONL audit log

## Build & CI

`zig build` produces `zig-out/bin/nbx-guard`; `zig build test` runs the unit tests
aggregated in `root.zig`. The repository ships three GitHub Actions workflows:

- **CI** — builds and tests on Linux and macOS and checks `zig fmt` on every push/PR.
- **Release** — on a `v*` tag, cross-compiles `ReleaseSafe` binaries for Linux, macOS,
  and Windows (x86_64 + aarch64), packages them with checksums, and publishes a release.
- **Docs** — builds this mdBook site and deploys it to GitHub Pages.

## NetBox Branching

`NBX_GUARD_BRANCHING` / `NBX_GUARD_BRANCH` reserve support for routing writes through the
NetBox Branching plugin. In this MVP the default apply mechanism is a direct PATCH.
