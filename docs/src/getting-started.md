# Getting Started

## Requirements

- **Zig 0.16.0** (to build from source)
- A reachable **NetBox** instance and an API token (for any command that touches NetBox)

## Build & test

```sh
zig build           # produces ./zig-out/bin/nbx-guard
zig build test      # run unit tests
zig build run -- version
```

The release binaries published on the
[Releases page](https://github.com/terateams/nbx-guard/releases) are statically
cross-compiled for Linux, macOS, and Windows (x86_64 and aarch64); download the archive
for your platform and put `nbx-guard` on your `PATH`.

## First run

`version` and `help` need no NetBox connection:

```sh
nbx-guard version
nbx-guard help
```

`version` echoes the active configuration so you can confirm the CLI sees your
environment:

```json
{
  "ok": true,
  "command": "version",
  "data": {
    "name": "nbx-guard",
    "version": "0.1.0",
    "description": "Agent-only NetBox safe-change gateway (Zig)",
    "netbox_url": "http://localhost:8000",
    "branching": false,
    "state_dir": ".nbx-guard",
    "token_configured": false,
    "principle": "Agent proposes intent; the CLI decides what is allowed."
  },
  "error": null
}
```

## Connect to NetBox

Set the URL and token, then read a resource:

```sh
export NETBOX_URL=https://netbox.example.com
export NETBOX_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

nbx-guard get device 1
```

See [Configuration](./configuration.md) for all variables.

## A first safe change

```sh
# 1. Propose intent (policy + risk checked, nothing written yet)
nbx-guard plan device 1 --set description="edge router"

# 2. Apply it (snapshots a backup, then PATCHes NetBox)
nbx-guard apply --plan plan_...

# 3. Revert if needed
nbx-guard restore --backup bkp_...
```

Low-risk fields apply without approval; high-risk fields must be approved first. See
[Workflows](./workflows.md) for the full low-risk and high-risk paths.
