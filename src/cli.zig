//! CLI command layer. Parses argv, enforces the guard workflow, and prints
//! exactly one JSON envelope per invocation. The agent only proposes intent;
//! every decision (policy, approval, backup, apply, restore) is made here.
const std = @import("std");
const ctxmod = @import("context.zig");
const Context = ctxmod.Context;
const Store = @import("store.zig").Store;
const ids = @import("ids.zig");
const policy = @import("policy.zig");
const schema = @import("schema.zig");
const plan = @import("plan.zig");
const approval = @import("approval.zig");
const backup = @import("backup.zig");
const audit = @import("audit.zig");
const netbox = @import("netbox.zig");
const doctor = @import("doctor.zig");
const config = @import("config.zig");

pub const version = "0.8.0";

// Exit codes: 0 ok, 2 client/policy/state error, 3 upstream/io/config error.
const exit_ok: u8 = 0;
const exit_client: u8 = 2;
const exit_upstream: u8 = 3;

// Placeholder resource id for a `create` plan: the object has no id until it is
// applied (POSTed). It is part of the plan_hash, so the same sentinel is used at
// plan time and at the apply-time integrity recheck. The real id is recorded in
// the backup and the apply output once NetBox assigns it.
const create_sentinel_id = "(new)";

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try applyOperatorConfig(ctx)) |code| return code;
    if (try resolveToken(ctx)) |code| return code;
    if (args.len < 2) {
        try printHelp(ctx);
        return exit_ok;
    }
    const cmd = args[1];
    const rest = args[2..];

    if (eq(cmd, "version") or eq(cmd, "--version") or eq(cmd, "-v")) {
        try cmdVersion(ctx);
        return exit_ok;
    } else if (eq(cmd, "help") or eq(cmd, "--help") or eq(cmd, "-h")) {
        try printHelp(ctx);
        return exit_ok;
    } else if (eq(cmd, "config")) {
        return cmdConfig(ctx, rest);
    } else if (eq(cmd, "doctor")) {
        return cmdDoctor(ctx, args[0], rest);
    } else if (eq(cmd, "get")) {
        return cmdGet(ctx, rest, "get");
    } else if (eq(cmd, "inspect")) {
        return cmdGet(ctx, rest, "inspect");
    } else if (eq(cmd, "describe")) {
        return cmdDescribe(ctx, rest);
    } else if (eq(cmd, "plan")) {
        return cmdPlan(ctx, rest);
    } else if (eq(cmd, "create")) {
        return cmdCreate(ctx, rest);
    } else if (eq(cmd, "approve")) {
        return cmdApprove(ctx, rest);
    } else if (eq(cmd, "approve-read")) {
        return cmdApproveRead(ctx, rest);
    } else if (eq(cmd, "reject")) {
        return cmdReject(ctx, rest);
    } else if (eq(cmd, "apply")) {
        return cmdApply(ctx, rest);
    } else if (eq(cmd, "restore")) {
        return cmdRestore(ctx, rest);
    } else if (eq(cmd, "audit")) {
        return cmdAudit(ctx, rest);
    } else if (eq(cmd, "list")) {
        return cmdList(ctx, rest);
    } else if (eq(cmd, "list-resources")) {
        return cmdListResources(ctx, rest, false);
    } else if (eq(cmd, "search")) {
        return cmdListResources(ctx, rest, true);
    } else if (eq(cmd, "resolve")) {
        return cmdResolve(ctx, rest);
    } else if (eq(cmd, "export")) {
        return cmdExport(ctx, rest);
    } else if (eq(cmd, "snapshot")) {
        return cmdSnapshot(ctx, rest);
    }

    try ctx.fail(cmd, .{
        .kind = .invalid_args,
        .message = "unknown command",
        .next_action = "run `nbxg help` to list supported commands",
    });
    return exit_client;
}

/// Load the optional operator config file and merge its governance extensions into
/// `ctx.env`, so the rest of the run reads them exactly like the NBX_GUARD_* env
/// vars. Resolution: `NBX_GUARD_CONFIG` (explicit; must exist) else
/// `$HOME/.nbx-guard/config.json` (missing = silent no-op, fully backward
/// compatible). Returns a non-null exit code only when an explicit/invalid config
/// must abort the run (the failure envelope is already emitted).
fn applyOperatorConfig(ctx: *Context) !?u8 {
    const explicit = blk: {
        const v = ctx.env.get("NBX_GUARD_CONFIG") orelse break :blk null;
        break :blk if (v.len == 0) null else v;
    };
    const path = explicit orelse home_path: {
        const home = ctx.env.get("HOME") orelse return null;
        if (home.len == 0) return null;
        break :home_path try std.fs.path.join(ctx.arena, &.{ home, ".nbx-guard", "config.json" });
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            if (explicit != null) {
                try ctx.fail("config", .{
                    .kind = .config_error,
                    .message = "NBX_GUARD_CONFIG points to a file that does not exist",
                    .next_action = "create the JSON file or unset NBX_GUARD_CONFIG",
                });
                return exit_upstream;
            }
            return null;
        },
        else => {
            try ctx.fail("config", .{
                .kind = .config_error,
                .message = "failed to read operator config file",
                .next_action = "check the path and permissions of ~/.nbx-guard/config.json (or NBX_GUARD_CONFIG)",
            });
            return exit_upstream;
        },
    };

    const ext = config.parseExtJson(ctx.arena, bytes) catch |err| {
        const Detail = struct { message: []const u8, next_action: []const u8 };
        const d: Detail = switch (err) {
            error.SecretInConfig => .{
                .message = "the operator config file must not contain the raw NetBox token",
                .next_action = "remove the \"netbox_token\"/\"token\" key; point at a keychain with \"token_cmd\", a file with \"token_file\", or set NETBOX_TOKEN in the environment",
            },
            error.InvalidConfig => .{
                .message = "invalid operator config JSON (~/.nbx-guard/config.json)",
                .next_action = "fix the JSON (object root). Connection keys: netbox_url, token_cmd, token_file, state_dir, branching, branch, http_timeout_ms. Governance keys: extra_resources, allowed_fields, high_risk_fields, read_sensitive_fields, creatable_resources, auto_approve. Never put the raw token here.",
            },
        };
        try ctx.fail("config", .{
            .kind = .config_error,
            .message = d.message,
            .next_action = d.next_action,
        });
        return exit_upstream;
    };
    ctx.config_path = path;
    if (ext.isEmpty()) return null;
    applyConnectionConfig(ctx, ext);
    ctx.env = try config.mergeEnv(ctx.arena, ctx.env, ext);
    return null;
}

/// Overlay connection/runtime settings from the operator config file onto
/// `ctx.config`, but only where the matching environment variable is unset — the
/// environment always wins. This is what lets an operator keep the whole setup in
/// one ~/.nbx-guard/config.json (URL, token source, state dir, branching, timeout)
/// instead of exporting a pile of env vars. Secrets never live here: the raw token
/// is refused at parse time, so `token_file`/`token_cmd` are only pointers.
fn applyConnectionConfig(ctx: *Context, ext: config.ParsedExt) void {
    if (ext.netbox_url) |v| {
        if (envUnset(ctx, "NETBOX_URL")) ctx.config.netbox_url = v;
    }
    if (ext.netbox_token_file) |v| {
        if (envUnset(ctx, "NETBOX_TOKEN_FILE")) ctx.config.netbox_token_file = v;
    }
    if (ext.netbox_token_cmd) |v| {
        if (envUnset(ctx, "NETBOX_TOKEN_CMD")) ctx.config.netbox_token_cmd = v;
    }
    if (ext.state_dir) |v| {
        if (envUnset(ctx, "NBX_GUARD_STATE_DIR")) ctx.config.state_dir = v;
    }
    if (ext.branch) |v| {
        if (envUnset(ctx, "NBX_GUARD_BRANCH")) ctx.config.branch = v;
    }
    if (ext.branching) |_| {
        if (envUnset(ctx, "NBX_GUARD_BRANCHING")) ctx.config.branching = true;
    }
    if (ext.http_timeout_ms) |v| {
        if (envUnset(ctx, "NBX_GUARD_HTTP_TIMEOUT_MS")) {
            ctx.config.http_timeout_ms = std.fmt.parseInt(u64, v, 10) catch ctx.config.http_timeout_ms;
        }
    }
}

/// True when an environment variable is absent or empty, i.e. the operator has not
/// set it and the config-file value should take effect.
fn envUnset(ctx: *Context, key: []const u8) bool {
    const v = ctx.env.get(key) orelse return true;
    return v.len == 0;
}

/// Resolve the effective NetBox token and record where it came from. Secrets stay
/// out of the environment when an operator prefers it: the token may be supplied
/// directly (`NETBOX_TOKEN`), read from a file (`NETBOX_TOKEN_FILE` — Docker/k8s
/// secrets, systemd credentials, a Vault-agent file), or produced by a command
/// (`NETBOX_TOKEN_CMD` — the direct hook into an OS keychain, e.g. macOS
/// `security find-generic-password -w`, Linux `secret-tool lookup` / `pass`).
/// Precedence: env var > command > file. On success `ctx.config.netbox_token`
/// holds the token and `ctx.token_source` names the source; a misconfigured
/// file/command aborts with a `config_error` envelope. No source configured is
/// not an error here — read-free commands still run, and commands needing a token
/// fail later with a precise needs-token message.
fn resolveToken(ctx: *Context) !?u8 {
    if (ctx.config.netbox_token != null) {
        ctx.token_source = "env";
        return null;
    }
    if (ctx.config.netbox_token_cmd) |cmd| {
        const tok = runTokenCmd(ctx, cmd) catch {
            try ctx.fail("config", .{
                .kind = .config_error,
                .message = "NETBOX_TOKEN_CMD failed to produce a token",
                .next_action = "the command in NETBOX_TOKEN_CMD must print the token to stdout and exit 0 (e.g. `security find-generic-password -s netbox -w`)",
            });
            return exit_upstream;
        };
        if (tok.len == 0) {
            try ctx.fail("config", .{
                .kind = .config_error,
                .message = "NETBOX_TOKEN_CMD produced an empty token",
                .next_action = "ensure the command prints the NetBox token to stdout",
            });
            return exit_upstream;
        }
        ctx.config.netbox_token = tok;
        ctx.token_source = "cmd";
        return null;
    }
    if (ctx.config.netbox_token_file) |file_path| {
        const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, file_path, ctx.gpa, .limited(64 * 1024)) catch {
            try ctx.fail("config", .{
                .kind = .config_error,
                .message = "NETBOX_TOKEN_FILE could not be read",
                .next_action = "check the path and permissions of the file named by NETBOX_TOKEN_FILE",
            });
            return exit_upstream;
        };
        defer ctx.gpa.free(raw);
        const tok = std.mem.trim(u8, raw, " \t\r\n");
        if (tok.len == 0) {
            try ctx.fail("config", .{
                .kind = .config_error,
                .message = "NETBOX_TOKEN_FILE is empty",
                .next_action = "put the NetBox token (and nothing else) in the file named by NETBOX_TOKEN_FILE",
            });
            return exit_upstream;
        }
        ctx.config.netbox_token = try ctx.arena.dupe(u8, tok);
        ctx.token_source = "file";
        return null;
    }
    ctx.token_source = "none";
    return null;
}

/// Run `cmd` through the platform shell and return its trimmed stdout (arena-
/// owned). Used only to fetch the NetBox token from a keychain/secret helper.
fn runTokenCmd(ctx: *Context, cmd: []const u8) ![]const u8 {
    const builtin = @import("builtin");
    const argv = if (builtin.os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/c", cmd }
    else
        [_][]const u8{ "/bin/sh", "-c", cmd };
    const res = try std.process.run(ctx.gpa, ctx.io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer ctx.gpa.free(res.stdout);
    defer ctx.gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) return error.TokenCmdFailed,
        else => return error.TokenCmdFailed,
    }
    const tok = std.mem.trim(u8, res.stdout, " \t\r\n");
    return ctx.arena.dupe(u8, tok);
}

// ---------------------------------------------------------------------------
// version / help
// ---------------------------------------------------------------------------

fn cmdVersion(ctx: *Context) !void {
    const Info = struct {
        name: []const u8 = "nbxg",
        version: []const u8 = version,
        description: []const u8 = "Agent-only NetBox safe-change gateway (Zig)",
        netbox_url: []const u8,
        branching: bool,
        branch: ?[]const u8 = null,
        state_dir: []const u8,
        token_configured: bool,
        token_source: []const u8,
        auto_approve: bool,
        config_file: ?[]const u8 = null,
        principle: []const u8 = "Agent proposes intent; the CLI decides what is allowed.",
    };
    try ctx.ok("version", Info{
        .netbox_url = ctx.config.netbox_url,
        .branching = ctx.config.branching,
        .branch = netbox.activeBranch(ctx.config),
        .state_dir = ctx.config.state_dir,
        .token_configured = ctx.config.netbox_token != null,
        .token_source = ctx.token_source,
        .auto_approve = policy.autoApproveEnabled(ctx.env),
        .config_file = ctx.config_path,
    });
}

/// One environment variable, described for a human: what value it takes and,
/// in plain words, what it does.
const EnvVar = struct {
    name: []const u8,
    default: []const u8,
    example: []const u8,
    purpose: []const u8,
};

/// The `env` section of `nbxg help`, grouped so the reader sees at a glance that
/// only two variables are actually required and the rest are optional knobs.
const EnvHelp = struct {
    note: []const u8 = "Most setups need only NETBOX_URL + NETBOX_TOKEN. You can put these (and any knob below) once in ~/.nbx-guard/config.json instead of exporting env vars — each shows its config.json key. The environment always wins over the file.",
    required: []const EnvVar = &.{
        .{ .name = "NETBOX_URL", .default = "http://localhost:8000", .example = "https://netbox.example.com", .purpose = "Address of your NetBox instance. config.json key: netbox_url." },
        .{ .name = "NETBOX_TOKEN", .default = "(unset)", .example = "<your-netbox-api-token>", .purpose = "NetBox API token. Required — without it nothing can read or write. Paste it as-is (v1 and v2 'nbt_…' tokens both work). To keep it out of the environment use NETBOX_TOKEN_FILE / NETBOX_TOKEN_CMD (config.json: token_file / token_cmd). The raw token must never go in config.json." },
    },
    optional: []const EnvVar = &.{
        .{ .name = "NETBOX_TOKEN_FILE", .default = "(unset)", .example = "/run/secrets/netbox_token", .purpose = "Read the token from this file instead of NETBOX_TOKEN. For Docker/Kubernetes secrets, systemd credentials, or a Vault-agent rendered file. config.json key: token_file." },
        .{ .name = "NETBOX_TOKEN_CMD", .default = "(unset)", .example = "security find-generic-password -s netbox -w", .purpose = "Run this command and use its stdout as the token. The hook into an OS keychain: macOS `security`, Linux `secret-tool`/`pass`. Precedence: NETBOX_TOKEN > NETBOX_TOKEN_CMD > NETBOX_TOKEN_FILE. config.json key: token_cmd." },
        .{ .name = "NBX_GUARD_STATE_DIR", .default = ".nbx-guard", .example = "/var/lib/nbx-guard", .purpose = "Folder for this tool's own data: change plans, approvals, backups, audit log. config.json key: state_dir." },
        .{ .name = "NBX_GUARD_HTTP_TIMEOUT_MS", .default = "15000", .example = "15000", .purpose = "Give up on a NetBox request after this many milliseconds so a command never hangs. 0 = wait forever. config.json key: http_timeout_ms." },
        .{ .name = "NBX_GUARD_BRANCHING", .default = "0", .example = "1", .purpose = "Set to 1 to work inside a NetBox Branching branch instead of the live data. config.json key: branching." },
        .{ .name = "NBX_GUARD_BRANCH", .default = "(unset)", .example = "abc12345", .purpose = "Which branch to use (its schema id). Needed when NBX_GUARD_BRANCHING=1. config.json key: branch." },
    },
    advanced_note: []const u8 = "Operator-only. These widen what the tool is allowed to touch (it denies every type and field by default) or relax the approval gate. An agent must not set them — set them once, more readably, in ~/.nbx-guard/config.json using the config.json key shown for each.",
    advanced: []const EnvVar = &.{
        .{ .name = "NBX_GUARD_CONFIG", .default = "~/.nbx-guard/config.json", .example = "/etc/nbx-guard/config.json", .purpose = "Read the operator config file from a custom path instead of the default location." },
        .{ .name = "NBX_GUARD_AUTO_APPROVE", .default = "0", .example = "1", .purpose = "Set to 1 to auto-approve change plans (high-risk update + create) while still recording a full audit trail. For your own branch/sandbox work — pair it with NBX_GUARD_BRANCHING. config.json key: auto_approve." },
        .{ .name = "NBX_GUARD_EXTRA_RESOURCES", .default = "(unset)", .example = "site=dcim/sites,tenant=tenancy/tenants", .purpose = "Allow more NetBox resource types. Format: type=app/endpoint, comma-separated. config.json key: extra_resources." },
        .{ .name = "NBX_GUARD_ALLOWED_FIELDS", .default = "(unset)", .example = "serial,asset_tag", .purpose = "Allow more fields to be written without approval (low risk). config.json key: allowed_fields." },
        .{ .name = "NBX_GUARD_HIGH_RISK_FIELDS", .default = "(unset)", .example = "tenant", .purpose = "Allow more fields to be written, but require an approval first. config.json key: high_risk_fields." },
        .{ .name = "NBX_GUARD_READ_SENSITIVE_FIELDS", .default = "(unset)", .example = "comments", .purpose = "Treat more fields as sensitive: hidden on read unless you run approve-read. config.json key: read_sensitive_fields." },
        .{ .name = "NBX_GUARD_CREATABLE_RESOURCES", .default = "(unset)", .example = "site,vlan or *", .purpose = "Allow `nbxg create` to make new objects of these types (default: none). Use * for any type. Every create still needs approval. config.json key: creatable_resources." },
    },
};

fn printHelp(ctx: *Context) !void {
    const ef = try policy.effectiveFields(ctx.arena, ctx.env);
    var types: std.ArrayList([]const u8) = .empty;
    try types.appendSlice(ctx.arena, &.{ "device", "interface", "ip-address", "prefix", "vlan", "contact" });
    for (try envExtraResources(ctx)) |ex| try types.append(ctx.arena, ex.key);

    const Help = struct {
        name: []const u8 = "nbxg",
        version: []const u8 = version,
        usage: []const u8 = "nbxg <command> [options]",
        commands: []const []const u8 = &.{
            "version                          Print version and active configuration",
            "help                             Show this help",
            "config show                      Explain in plain language what the current config lets the agent do",
            "config set <key=value> ...       Propose a governance/connection change (human-approved + audited)",
            "doctor [--skill <dir>]           Check installed binary vs SKILL.md/source for drift (offline)",
            "get <type> <id> [--fields basic|all] [--plan-read] [--plan <id>]",
            "                                 Read a NetBox resource (basic redacts sensitive fields; all needs read approval)",
            "inspect <type> <id> [--fields basic|all] [--plan-read] [--plan <id>]",
            "                                 Read a resource annotated with read + write field policy",
            "list-resources <type> [--limit N] [--offset N] [--all-fields]",
            "                                 Discover NetBox resources (brief identifying fields; low-risk read)",
            "search <type> [-q text] [--filter k=v] [--limit N] [--all-fields]",
            "                                 Search NetBox resources by fuzzy text / field filters (read-only)",
            "resolve <type> [--name v] [--slug v] [--address v] [--display v] [k=v ...]",
            "                                 Resolve human-readable identifiers to an object id (ambiguous => candidate list, never a silent pick)",
            "export <type> [--filter k=v] [-q text] [--fields basic|full] [--format json|jsonl] [--out path] [--limit N]",
            "                                 Read-only export of matching resources (full tier redacts read-sensitive values)",
            "snapshot <type> <id> [--fields basic|all] [--plan-read] [--plan <id>] [--out path]",
            "                                 Read-only snapshot of one resource; sensitive fields redacted unless disclosed via a read approval",
            "describe [<type>] [--source options|openapi] [--refresh] [--offline]",
            "                                 Self-describe a type: action, fields, I/O schema (live-synced to NetBox)",
            "plan <type> <id> --set k=v ...   Create a change plan (policy + risk checked)",
            "create <type> --set k=v ...      Plan creating a NEW object (opt-in type; always needs approval)",
            "approve --plan <id> [--note x]   Approve a high-risk plan (binds plan_hash)",
            "approve-read --plan <id> [--note x]  Approve a full read of a sensitive object (binds plan_hash)",
            "reject --plan <id> [--note x]    Reject a plan so it can never be applied",
            "apply --plan <id>                Backup then apply an approved/low-risk plan",
            "restore --backup <id>            Revert a resource from a backup snapshot",
            "audit [--plan <id>]              Show the audit log",
            "list <plans|approvals|backups>   List local state",
        },
        resource_types: []const []const u8,
        creatable_resources: []const []const u8,
        allowed_fields: []const []const u8,
        high_risk_fields: []const []const u8,
        read_sensitive_fields: []const []const u8,
        env: EnvHelp = .{},
        principle: []const u8 = "Agent proposes intent; the CLI decides what is allowed.",
    };
    try ctx.ok("help", Help{
        .resource_types = try types.toOwnedSlice(ctx.arena),
        .creatable_resources = try policy.effectiveCreatableResources(ctx.arena, ctx.env),
        .allowed_fields = ef.allowed,
        .high_risk_fields = ef.high_risk,
        .read_sensitive_fields = try policy.effectiveReadSensitiveFields(ctx.arena, ctx.env),
    });
}

// ---------------------------------------------------------------------------
// doctor (offline consistency check)
// ---------------------------------------------------------------------------

const DoctorSkill = struct {
    found: bool,
    source: ?[]const u8 = null,
    path: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    size: ?usize = null,
    resource_types: ?[]const []const u8 = null,
    low_risk_fields: ?[]const []const u8 = null,
    high_risk_fields: ?[]const []const u8 = null,
};

const DoctorFile = struct {
    found: bool,
    path: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    size: ?usize = null,
};

const DoctorCheck = struct {
    name: []const u8,
    ok: bool,
    detail: []const u8,
    binary_only: []const []const u8 = &.{},
    doc_only: []const []const u8 = &.{},
};

/// Best-effort read of a (possibly absolute) path relative to cwd. Any failure
/// — missing file, bad parent, permission — is treated as "absent" so doctor can
/// keep probing candidate locations without aborting.
fn readFileOpt(ctx: *Context, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(1 << 20)) catch null;
}

/// `nbxg doctor`: compare the installed binary's self-knowledge (version,
/// governed resource types, policy fields) against the installed `SKILL.md` and,
/// when run from a checkout, the repository `build.zig.zon` version. Fully
/// offline; needs no NetBox token. Exits 0 when consistent, 2 on drift.
fn cmdDoctor(ctx: *Context, argv0: []const u8, rest: []const [:0]const u8) !u8 {
    var explicit: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "--skill") or eq(a, "--skill-dir")) {
            if (i + 1 < rest.len) {
                i += 1;
                explicit = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--skill=")) {
            explicit = a["--skill=".len..];
        } else if (std.mem.startsWith(u8, a, "--skill-dir=")) {
            explicit = a["--skill-dir=".len..];
        }
    }

    // Binary self-knowledge (all compile-time constants).
    var rtypes: std.ArrayList([]const u8) = .empty;
    for (schema.resources) |r| try rtypes.append(ctx.arena, r.key);
    const bin_rtypes = rtypes.items;
    const bin_low: []const []const u8 = &policy.allowed_fields;
    const bin_high: []const []const u8 = &policy.high_risk_fields;

    // Locate the installed SKILL.md by probing candidate locations in priority
    // order: explicit flag, operator env, the binary's own directory (direct
    // absolute-path invocation), the default install dir, then the repo layout.
    const Candidate = struct { source: []const u8, path: []const u8 };
    var cands: std.ArrayList(Candidate) = .empty;
    if (explicit) |e| {
        const p = if (std.mem.endsWith(u8, e, "SKILL.md"))
            try ctx.arena.dupe(u8, e)
        else
            try std.fs.path.join(ctx.arena, &.{ e, "SKILL.md" });
        try cands.append(ctx.arena, .{ .source = "flag", .path = p });
    }
    if (ctx.env.get("NBX_GUARD_SKILL_DIR")) |d|
        try cands.append(ctx.arena, .{ .source = "env", .path = try std.fs.path.join(ctx.arena, &.{ d, "SKILL.md" }) });
    if (std.fs.path.dirname(argv0)) |d| if (d.len > 0)
        try cands.append(ctx.arena, .{ .source = "binary-dir", .path = try std.fs.path.join(ctx.arena, &.{ d, "SKILL.md" }) });
    if (ctx.env.get("HOME")) |h|
        try cands.append(ctx.arena, .{ .source = "home", .path = try std.fs.path.join(ctx.arena, &.{ h, ".agents/skills/nbx-guard/SKILL.md" }) });
    try cands.append(ctx.arena, .{ .source = "cwd", .path = "skills/nbx-guard/SKILL.md" });
    try cands.append(ctx.arena, .{ .source = "cwd", .path = "SKILL.md" });

    var skill: DoctorSkill = .{ .found = false };
    var readme: DoctorFile = .{ .found = false };
    var checks: std.ArrayList(DoctorCheck) = .empty;
    var issues: std.ArrayList([]const u8) = .empty;
    var drift = false;

    for (cands.items) |c| {
        const text = readFileOpt(ctx, c.path) orelse continue;
        skill = .{
            .found = true,
            .source = c.source,
            .path = c.path,
            .sha256 = try doctor.sha256Hex(ctx.arena, text),
            .size = text.len,
            .resource_types = try doctor.documentedTokens(ctx.arena, text, doctor.marker_resource_types),
            .low_risk_fields = try doctor.documentedTokens(ctx.arena, text, doctor.marker_low_fields),
            .high_risk_fields = try doctor.documentedTokens(ctx.arena, text, doctor.marker_high_fields),
        };
        // A README.md installed alongside the skill is checksummed (not parsed)
        // so operators can detect README drift across installs.
        if (std.fs.path.dirname(c.path)) |dir| {
            const rp = try std.fs.path.join(ctx.arena, &.{ dir, "README.md" });
            if (readFileOpt(ctx, rp)) |rtext|
                readme = .{ .found = true, .path = rp, .sha256 = try doctor.sha256Hex(ctx.arena, rtext), .size = rtext.len };
        }
        break;
    }

    if (skill.found) {
        try doctorCheck(ctx, &checks, &issues, &drift, "resource_types", "resource types", bin_rtypes, skill.resource_types);
        try doctorCheck(ctx, &checks, &issues, &drift, "low_risk_fields", "low-risk policy fields", bin_low, skill.low_risk_fields);
        try doctorCheck(ctx, &checks, &issues, &drift, "high_risk_fields", "high-risk policy fields", bin_high, skill.high_risk_fields);
    }

    // Repository/source version (only present when run from a checkout).
    var source_version: ?[]const u8 = null;
    var source_matches: ?bool = null;
    if (readFileOpt(ctx, "build.zig.zon")) |zon| {
        if (doctor.parseZonVersion(zon)) |sv| {
            source_version = sv;
            const matches = std.mem.eql(u8, sv, version);
            source_matches = matches;
            if (!matches) {
                drift = true;
                try issues.append(ctx.arena, try std.fmt.allocPrint(
                    ctx.arena,
                    "binary version {s} differs from repository source version {s}",
                    .{ version, sv },
                ));
            }
        }
    }

    const status: []const u8 = if (!skill.found)
        "skill_not_found"
    else if (drift)
        "drift"
    else
        "consistent";

    const next_action: []const u8 = if (!skill.found)
        "install the skill (run scripts/installer.sh) or pass `nbxg doctor --skill <dir>` to point at SKILL.md"
    else if (drift)
        "reinstall so the binary and SKILL.md match: re-run scripts/installer.sh (rebuild with `zig build` first if needed)"
    else
        "installed binary and skill documentation agree";

    if (!skill.found)
        try issues.append(ctx.arena, "could not locate an installed SKILL.md to verify against");

    try ctx.ok("doctor", .{
        .status = status,
        .consistent = skill.found and !drift,
        .binary = .{
            .name = "nbxg",
            .version = version,
            .path = argv0,
            .resource_types = bin_rtypes,
            .low_risk_fields = bin_low,
            .high_risk_fields = bin_high,
        },
        .source = .{
            .version = source_version,
            .matches_binary = source_matches,
        },
        .skill_doc = skill,
        .readme = readme,
        .checks = checks.items,
        .issues = issues.items,
        .next_action = next_action,
    });
    return if (drift) exit_client else exit_ok;
}

/// Append one doc-vs-binary comparison to `checks`, recording any mismatch in
/// `issues` and flipping `drift`. A `null` documented list means the marker was
/// absent from SKILL.md (a documentation-format problem), which also counts as
/// drift since the governed surface can no longer be verified.
fn doctorCheck(
    ctx: *Context,
    checks: *std.ArrayList(DoctorCheck),
    issues: *std.ArrayList([]const u8),
    drift: *bool,
    name: []const u8,
    label: []const u8,
    binary: []const []const u8,
    documented: ?[]const []const u8,
) !void {
    const docs = documented orelse {
        drift.* = true;
        try checks.append(ctx.arena, .{
            .name = name,
            .ok = false,
            .detail = try std.fmt.allocPrint(ctx.arena, "SKILL.md does not document the {s}", .{label}),
        });
        try issues.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "installed SKILL.md does not document the {s}", .{label}));
        return;
    };
    const d = try doctor.diff(ctx.arena, binary, docs);
    if (!d.consistent()) {
        drift.* = true;
        if (d.binary_only.len > 0)
            try issues.append(ctx.arena, try std.fmt.allocPrint(
                ctx.arena,
                "binary supports {s} not documented in SKILL.md: {s}",
                .{ label, try joinList(ctx.arena, d.binary_only) },
            ));
        if (d.doc_only.len > 0)
            try issues.append(ctx.arena, try std.fmt.allocPrint(
                ctx.arena,
                "SKILL.md documents {s} this binary does not support: {s}",
                .{ label, try joinList(ctx.arena, d.doc_only) },
            ));
    }
    try checks.append(ctx.arena, .{
        .name = name,
        .ok = d.consistent(),
        .detail = if (d.consistent())
            try std.fmt.allocPrint(ctx.arena, "{s} match", .{label})
        else
            try std.fmt.allocPrint(ctx.arena, "{s} differ", .{label}),
        .binary_only = d.binary_only,
        .doc_only = d.doc_only,
    });
}

fn joinList(arena: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (items, 0..) |it, idx| {
        if (idx > 0) try buf.appendSlice(arena, ", ");
        try buf.appendSlice(arena, it);
    }
    return buf.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// get / inspect (read-only)
// ---------------------------------------------------------------------------

fn cmdGet(ctx: *Context, rest: []const [:0]const u8, comptime command: []const u8) !u8 {
    var rtype: ?[]const u8 = null;
    var rid: ?[]const u8 = null;
    var profile: []const u8 = "basic";
    var plan_read = false;
    var read_plan_id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "--fields")) {
            if (i + 1 < rest.len) {
                i += 1;
                profile = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--fields=")) {
            profile = a["--fields=".len..];
        } else if (eq(a, "--all-fields")) {
            profile = "all";
        } else if (eq(a, "--redact")) {
            profile = "basic";
        } else if (eq(a, "--plan-read")) {
            plan_read = true;
        } else if (eq(a, "--plan")) {
            if (i + 1 < rest.len) {
                i += 1;
                read_plan_id = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--plan=")) {
            read_plan_id = a["--plan=".len..];
        } else if (!std.mem.startsWith(u8, a, "-")) {
            if (rtype == null) {
                rtype = a;
            } else if (rid == null) {
                rid = a;
            }
        }
    }

    const rt = rtype orelse {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "expected <type> <id>",
            .next_action = "example: nbxg " ++ command ++ " device 1 --fields basic",
        });
        return exit_client;
    };
    const id = rid orelse {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "expected <type> <id>",
            .next_action = "example: nbxg " ++ command ++ " device 1 --fields basic",
        });
        return exit_client;
    };

    // Read field-scope tier (default-deny on a typo so it can never widen the
    // read): "basic" redacts read-sensitive fields; "all" requests the full
    // object and is gated behind a read approval when sensitive fields are present.
    const basic = eq(profile, "basic") or eq(profile, "brief");
    const all = eq(profile, "all") or eq(profile, "full");
    if (!basic and !all) {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "fields tier must be 'basic' or 'all'",
            .next_action = "use --fields basic (minimal, redacted read) or --fields all (requires read approval)",
        });
        return exit_client;
    }

    if (netbox.endpointFor(ctx.env, rt) == null) return failUnknownType(ctx, command, rt);
    if (ctx.config.netbox_token == null) return failNoToken(ctx, command);

    var client = netbox.Client.init(ctx);
    defer client.deinit();

    const res = client.get(rt, id) catch |err| return failNetboxConn(ctx, command, err);
    defer ctx.gpa.free(res.body);

    if (!res.ok) return failNetboxStatus(ctx, command, res);

    const resource = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, res.body, .{}) catch
        std.json.Value{ .null = {} };

    const sensitive = try policy.sensitiveFieldsPresent(ctx.arena, ctx.env, resource);

    // basic tier: redact sensitive fields, no approval needed.
    if (basic) {
        const redacted = try policy.redactSensitive(ctx.arena, ctx.env, resource);
        return emitRead(ctx, command, rt, id, redacted, .{
            .field_profile = "basic",
            .risk_level = "low",
            .redacted_fields = sensitive,
            .note = "basic read: sensitive fields redacted. To reveal them, request `--fields all` (requires a read approval).",
        }, if (sensitive.len > 0)
            "sensitive fields were redacted; run with `--fields all --plan-read` then `approve-read` to disclose them"
        else
            "no read-sensitive fields on this object");
    }

    // all tier with no sensitive fields present: full object is low-risk.
    if (sensitive.len == 0) {
        return emitRead(ctx, command, rt, id, resource, .{
            .field_profile = "all",
            .risk_level = "low",
            .redacted_fields = &[_][]const u8{},
            .note = "full read: no read-sensitive fields present on this object.",
        }, "full object returned");
    }

    // all tier with sensitive fields present: gated behind a read approval.
    if (read_plan_id) |pid| return serveApprovedRead(ctx, command, rt, id, resource, sensitive, pid);
    if (plan_read) return createReadPlan(ctx, command, rt, id, resource, sensitive);

    try ctx.fail(command, .{
        .kind = .needs_approval,
        .message = "full read of read-sensitive fields requires an approved read plan",
        .risk_level = "high",
        .next_action = "run `nbxg " ++ command ++ " <type> <id> --fields all --plan-read`, get it approved with `nbxg approve-read --plan <plan_id>`, then re-run with `--plan <plan_id>`",
    });
    return exit_client;
}

/// Emit a successful read envelope. `inspect` additionally annotates the write
/// policy so the agent can see what it may later propose to change.
fn emitRead(
    ctx: *Context,
    comptime command: []const u8,
    rtype: []const u8,
    rid: []const u8,
    resource: std.json.Value,
    read_policy: anytype,
    next_action: []const u8,
) !u8 {
    if (eq(command, "inspect")) {
        const ef = try policy.effectiveFields(ctx.arena, ctx.env);
        try ctx.ok(command, .{
            .resource_type = rtype,
            .resource_id = rid,
            .resource = resource,
            .read_policy = read_policy,
            .policy = .{
                .allowed_fields = ef.allowed,
                .high_risk_fields = ef.high_risk,
                .note = "Other fields are denied by default. High-risk fields require approval.",
            },
            .next_action = next_action,
        });
    } else {
        try ctx.ok(command, .{
            .resource_type = rtype,
            .resource_id = rid,
            .resource = resource,
            .read_policy = read_policy,
            .next_action = next_action,
        });
    }
    return exit_ok;
}

/// Read-plan changes payload: the read tier the plan authorizes. Hashing this
/// (with the resource type/id and "read" action) binds an approval to a specific
/// full-object disclosure, exactly like a write plan binds to its changes.
fn readChanges(ctx: *Context) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(ctx.arena, "field_profile", .{ .string = "all" });
    return .{ .object = obj };
}

/// Create a pending-approval read plan for a full-object read whose object
/// contains read-sensitive fields. Returns a redacted preview so the agent can
/// see the basic view while approval is sought.
fn createReadPlan(
    ctx: *Context,
    comptime command: []const u8,
    rtype: []const u8,
    rid: []const u8,
    resource: std.json.Value,
    sensitive: []const []const u8,
) !u8 {
    const changes_value = try readChanges(ctx);

    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const now_ns = ctx.nowNanos();
    const p: plan.Plan = .{
        .plan_id = try ids.genId(ctx.arena, "rplan", now_ns),
        .request_id = try ids.genId(ctx.arena, "req", now_ns),
        .plan_hash = try plan.computeHash(ctx.arena, rtype, rid, "read", changes_value),
        .resource_type = rtype,
        .resource_id = rid,
        .action = "read",
        .changes = changes_value,
        .risk_level = "high",
        .requires_approval = true,
        .status = plan.status_pending_approval,
        .created_at = nsToSecs(now_ns),
        .netbox_url = ctx.config.netbox_url,
    };
    try plan.save(store, p);

    try audit.append(store, .{
        .ts = p.created_at,
        .request_id = p.request_id,
        .event = "read_plan_created",
        .plan_id = p.plan_id,
        .resource_type = rtype,
        .resource_id = rid,
        .risk_level = p.risk_level,
    });

    const preview = try policy.redactSensitive(ctx.arena, ctx.env, resource);
    try ctx.ok(command, .{
        .plan = p,
        .read_policy = .{
            .field_profile = "all",
            .risk_level = "high",
            .sensitive_fields = sensitive,
        },
        .preview = preview,
        .next_action = "human approval required: run `nbxg approve-read --plan <plan_id>`, then re-run `nbxg " ++ command ++ " <type> <id> --fields all --plan <plan_id>`",
    });
    return exit_ok;
}

/// Result of verifying a read plan authorizes disclosing a specific resource.
const ReadAuth = union(enum) {
    /// Verified and audited. Carries arena-owned ids for response annotation.
    ok: struct { plan_id: []const u8, approval_id: ?[]const u8 },
    /// A failure envelope was already emitted; carries its exit code.
    handled: u8,
};

/// Verify a read plan is an approved read for this exact resource, that its
/// stored form still hashes to its plan_hash, and that the bound approval covers
/// that hash (tamper-evident, mirroring `apply`). On success writes the
/// `read_served` audit record and returns `.ok`; on any failure emits the
/// envelope and returns `.handled`. Shared by `get`/`inspect` and `snapshot`.
fn authorizeApprovedRead(
    ctx: *Context,
    comptime command: []const u8,
    rtype: []const u8,
    rid: []const u8,
    plan_id: []const u8,
) !ReadAuth {
    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const loaded = (try plan.load(store, plan_id)) orelse
        return .{ .handled = try failPlanNotFound(ctx, command, plan_id) };
    defer loaded.deinit();
    const p = loaded.value;

    if (!eq(p.action, "read")) {
        try ctx.fail(command, .{
            .kind = .plan_state_error,
            .message = "--plan does not reference a read plan",
            .next_action = "create one with `nbxg " ++ command ++ " <type> <id> --fields all --plan-read`",
        });
        return .{ .handled = exit_client };
    }
    if (!eq(p.resource_type, rtype) or !eq(p.resource_id, rid)) {
        try ctx.fail(command, .{
            .kind = .plan_state_error,
            .message = "read plan was approved for a different resource",
            .next_action = "create a read plan for this exact <type> <id>",
        });
        return .{ .handled = exit_client };
    }
    if (eq(p.status, plan.status_rejected)) {
        try ctx.fail(command, .{
            .kind = .plan_state_error,
            .message = "read plan was rejected and cannot disclose data",
            .next_action = "create a new read plan",
        });
        return .{ .handled = exit_client };
    }
    if (!eq(p.status, plan.status_approved)) {
        try ctx.fail(command, .{
            .kind = .not_approved,
            .message = "read plan requires approval before sensitive fields can be disclosed",
            .risk_level = "high",
            .next_action = "run `nbxg approve-read --plan <plan_id>` first",
        });
        return .{ .handled = exit_client };
    }

    // Integrity: the stored read plan must still hash to its plan_hash, and the
    // bound approval must cover that exact hash.
    const recomputed = try plan.computeHash(ctx.arena, p.resource_type, p.resource_id, p.action, p.changes);
    if (!eq(recomputed, p.plan_hash)) {
        try ctx.fail(command, .{
            .kind = .plan_state_error,
            .message = "read plan integrity check failed: stored plan does not match its plan_hash",
            .next_action = "discard this tampered read plan and create a new one",
        });
        return .{ .handled = exit_client };
    }
    const bound = if (p.approval_id) |aid| (try approval.load(store, aid)) else null;
    defer {
        if (bound) |bp| bp.deinit();
    }
    const bound_ok = if (bound) |bp| eq(bp.value.plan_hash, p.plan_hash) else false;
    if (!bound_ok) {
        try ctx.fail(command, .{
            .kind = .plan_state_error,
            .message = "approval does not match this read plan (missing approval or plan_hash mismatch)",
            .next_action = "re-approve the read plan before disclosing data",
        });
        return .{ .handled = exit_client };
    }

    try audit.append(store, .{
        .ts = nsToSecs(ctx.nowNanos()),
        .request_id = try ids.genId(ctx.arena, "req", ctx.nowNanos()),
        .event = "read_served",
        .plan_id = p.plan_id,
        .approval_id = p.approval_id,
        .resource_type = rtype,
        .resource_id = rid,
        .risk_level = "high",
    });

    return .{ .ok = .{
        .plan_id = try ctx.arena.dupe(u8, p.plan_id),
        .approval_id = if (p.approval_id) |aid| try ctx.arena.dupe(u8, aid) else null,
    } };
}

/// Serve a full-object read under a previously approved read plan.
fn serveApprovedRead(
    ctx: *Context,
    comptime command: []const u8,
    rtype: []const u8,
    rid: []const u8,
    resource: std.json.Value,
    sensitive: []const []const u8,
    plan_id: []const u8,
) !u8 {
    switch (try authorizeApprovedRead(ctx, command, rtype, rid, plan_id)) {
        .handled => |code| return code,
        .ok => |info| return emitRead(ctx, command, rtype, rid, resource, .{
            .field_profile = "all",
            .risk_level = "high",
            .disclosed_fields = sensitive,
            .read_plan = info.plan_id,
            .approval_id = info.approval_id,
            .note = "full object disclosed under an approved read plan; this disclosure is recorded in the audit log.",
        }, "sensitive fields disclosed under approved read plan"),
    }
}

// ---------------------------------------------------------------------------
// describe (per-type self-description; static schema + live NetBox sync)
// ---------------------------------------------------------------------------

const DescribeField = struct {
    name: []const u8,
    class: []const u8,
    requires_approval: bool,
    json_type: []const u8,
    example: []const u8,
    note: []const u8,
    /// Live NetBox field metadata (type/choices/required/help_text), or null
    /// when no live sync was performed.
    netbox: ?std.json.Value = null,
    /// Whether this governed field exists on the live NetBox model.
    present_in_netbox: ?bool = null,
};

fn cmdDescribe(ctx: *Context, rest: []const [:0]const u8) !u8 {
    var rtype: ?[]const u8 = null;
    var offline = false;
    var refresh = false;
    var source: []const u8 = "options";
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "--offline")) {
            offline = true;
        } else if (eq(a, "--refresh")) {
            refresh = true;
        } else if (eq(a, "--source")) {
            if (i + 1 < rest.len) {
                i += 1;
                source = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--source=")) {
            source = a["--source=".len..];
        } else if (!std.mem.startsWith(u8, a, "-") and rtype == null) {
            rtype = a;
        }
    }

    if (!eq(source, "options") and !eq(source, "openapi")) {
        try ctx.fail("describe", .{
            .kind = .invalid_args,
            .message = "unknown --source",
            .next_action = "use --source options (default) or --source openapi",
        });
        return exit_client;
    }

    if (rtype == null) return describeCatalog(ctx);

    const key = rtype.?;
    const doc = schema.lookup(key) orelse (try syntheticDoc(ctx, key)) orelse return failUnknownType(ctx, "describe", key);

    var fields: std.ArrayList(DescribeField) = .empty;
    for (doc.low) |fname| {
        const fd = schema.fieldDoc(fname) orelse genericFieldDoc(ctx, fname);
        try fields.append(ctx.arena, .{
            .name = fname,
            .class = "allowed",
            .requires_approval = false,
            .json_type = fd.json_type,
            .example = fd.example,
            .note = fd.note,
        });
    }
    for (doc.high) |fname| {
        const fd = schema.fieldDoc(fname) orelse genericFieldDoc(ctx, fname);
        try fields.append(ctx.arena, .{
            .name = fname,
            .class = "high_risk",
            .requires_approval = true,
            .json_type = fd.json_type,
            .example = fd.example,
            .note = fd.note,
        });
    }
    // Operator env additions (NBX_GUARD_ALLOWED_FIELDS / *_HIGH_RISK_FIELDS) are
    // honored globally by the policy engine, so the self-description must surface
    // them too — otherwise the agent can't discover a field the operator enabled.
    // The live sync below annotates whether each is actually present on this type.
    for (try envFieldList(ctx, "NBX_GUARD_HIGH_RISK_FIELDS")) |fname| {
        if (describeHasField(fields.items, fname)) continue;
        if (policy.classifyFieldEnv(ctx.env, fname) != .high_risk) continue;
        const fd = schema.fieldDoc(fname) orelse genericFieldDoc(ctx, fname);
        try fields.append(ctx.arena, .{
            .name = fname,
            .class = "high_risk",
            .requires_approval = true,
            .json_type = fd.json_type,
            .example = fd.example,
            .note = fd.note,
        });
    }
    for (try envFieldList(ctx, "NBX_GUARD_ALLOWED_FIELDS")) |fname| {
        if (describeHasField(fields.items, fname)) continue;
        if (policy.classifyFieldEnv(ctx.env, fname) != .allowed) continue;
        const fd = schema.fieldDoc(fname) orelse genericFieldDoc(ctx, fname);
        try fields.append(ctx.arena, .{
            .name = fname,
            .class = "allowed",
            .requires_approval = false,
            .json_type = fd.json_type,
            .example = fd.example,
            .note = fd.note,
        });
    }

    var sync_status: []const u8 = "skipped";
    var sync_detail: []const u8 = "no NETBOX_TOKEN; static schema only";
    var source_desc: []const u8 = undefined;
    var component: ?[]const u8 = null;
    var cached: ?bool = null;
    var fetched_at: ?i64 = null;
    var writable: ?std.json.Value = null;
    var missing: std.ArrayList([]const u8) = .empty;

    if (offline) {
        source_desc = "none (offline)";
        sync_detail = "--offline given; static schema only";
    } else if (eq(source, "openapi")) {
        source_desc = "GET /api/schema/?format=json";
        const store = Store.init(ctx);
        switch (try loadOpenApi(ctx, store, refresh)) {
            .unavailable => |d| {
                sync_status = "unavailable";
                sync_detail = d;
            },
            .ok => |loaded| {
                cached = loaded.cached;
                fetched_at = loaded.fetched_at;
                if (openApiComponent(ctx.arena, loaded.value, doc.netbox_endpoint)) |cn| {
                    component = cn;
                    if (openApiProperties(loaded.value, cn)) |props| {
                        writable = props;
                        sync_status = "ok";
                        sync_detail = if (loaded.cached)
                            "merged NetBox OpenAPI PATCH schema (cached)"
                        else
                            "merged NetBox OpenAPI PATCH schema (fetched)";
                    } else {
                        sync_status = "unavailable";
                        sync_detail = "OpenAPI component exposed no properties";
                    }
                } else {
                    sync_status = "unavailable";
                    sync_detail = "no PATCH request schema for this endpoint in OpenAPI";
                }
            },
        }
    } else {
        source_desc = try std.fmt.allocPrint(ctx.arena, "OPTIONS /api/{s}/", .{doc.netbox_endpoint});
        if (ctx.config.netbox_token != null) {
            var client = netbox.Client.init(ctx);
            defer client.deinit();
            if (client.options(key)) |res| {
                defer ctx.gpa.free(res.body);
                if (res.ok) {
                    const meta = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, res.body, .{ .allocate = .alloc_always }) catch
                        std.json.Value{ .null = {} };
                    if (netboxWritableFields(meta)) |w| {
                        writable = w;
                        sync_status = "ok";
                        sync_detail = "merged live NetBox field metadata";
                    } else {
                        sync_status = "unavailable";
                        sync_detail = "NetBox OPTIONS exposed no writable field metadata (token may lack write permission)";
                    }
                } else {
                    sync_status = "unavailable";
                    sync_detail = try std.fmt.allocPrint(ctx.arena, "NetBox OPTIONS returned HTTP {d}", .{res.status});
                }
            } else |err| {
                sync_status = "unavailable";
                sync_detail = @errorName(err);
            }
        }
    }

    if (writable) |w| {
        for (fields.items) |*f| {
            if (objGet(w, f.name)) |fm| {
                f.netbox = fm;
                f.present_in_netbox = true;
            } else {
                f.present_in_netbox = false;
                try missing.append(ctx.arena, f.name);
            }
        }
    }

    const usage = try std.fmt.allocPrint(ctx.arena, "nbxg plan {s} <id> --set <field>=<value> ...", .{doc.key});
    try ctx.ok("describe", .{
        .resource_type = doc.key,
        .netbox_endpoint = doc.netbox_endpoint,
        .display = doc.display,
        .summary = doc.summary,
        .action = "update",
        .creatable = policy.creatableAllowed(ctx.env, doc.key),
        .create = .{
            .enabled = policy.creatableAllowed(ctx.env, doc.key),
            .command = "nbxg create <type> --set field=value ...  (then approve + apply)",
            .note = "create requires operator opt-in (creatable_resources / NBX_GUARD_CREATABLE_RESOURCES) and always needs approval; fields pass through to NetBox, so set the required identifying fields (e.g. name, slug).",
        },
        .denied_actions = &[_][]const u8{ "delete", "bulk_delete" },
        .default_policy = "deny: only the fields below are writable",
        .fields = fields.items,
        .input = .{
            .command = "plan",
            .usage = usage,
            .value_parsing = .{
                .string = "bare or quoted, e.g. description=\"edge router\"",
                .json_array = "valid JSON array, e.g. tags='[\"core\"]'",
                .json_object = "valid JSON object, e.g. custom_fields='{\"x\":1}'",
                .note = "a value that parses as a JSON array/object is sent as JSON; otherwise it is a string",
            },
        },
        .output = .{
            .envelope = "{ ok, command, data, error }",
            .plan_fields = &[_][]const u8{ "plan_id", "plan_hash", "resource_type", "resource_id", "action", "changes", "risk_level", "requires_approval", "status", "base_values" },
            .note = "plan emits data.plan + data.evaluation; apply emits data.backup_id + data.applied",
        },
        .examples = doc.examples,
        .discovery = .{
            .note = "plan / get / inspect operate on an object id; resolve a human-readable identifier to an id first",
            .resolve = "nbxg resolve <type> --name|--slug|--address <value>  (deterministic; several matches => candidate list, never a silent pick)",
            .search = "nbxg search <type> -q <text>  (fuzzy browse)",
            .list = "nbxg list-resources <type>  (brief listing)",
        },
        .read_policy = .{
            .tiers = &[_][]const u8{ "basic", "all" },
            .default = "basic",
            .sensitive_fields = try policy.effectiveReadSensitiveFields(ctx.arena, ctx.env),
            .note = "Reads are scoped: `--fields basic` (default) redacts read-sensitive fields; `--fields all` returns the full object and requires an approved read plan (`--plan-read` then `approve-read`) when sensitive fields are present.",
        },
        .netbox_sync = .{
            .source_kind = source,
            .status = sync_status,
            .source = source_desc,
            .detail = sync_detail,
            .component = component,
            .cached = cached,
            .fetched_at = fetched_at,
            .missing_in_netbox = missing.items,
        },
    });
    return exit_ok;
}

fn describeCatalog(ctx: *Context) !u8 {
    const Item = struct {
        resource_type: []const u8,
        netbox_endpoint: []const u8,
        display: []const u8,
        summary: []const u8,
        low_fields: []const []const u8,
        high_fields: []const []const u8,
    };
    var items: std.ArrayList(Item) = .empty;
    for (schema.resources) |r| {
        try items.append(ctx.arena, .{
            .resource_type = r.key,
            .netbox_endpoint = r.netbox_endpoint,
            .display = r.display,
            .summary = r.summary,
            .low_fields = r.low,
            .high_fields = r.high,
        });
    }
    // Operator-extended types (NBX_GUARD_EXTRA_RESOURCES) appear alongside the
    // built-ins so agents can discover the full governed surface.
    for (try envExtraResources(ctx)) |ex| {
        if (try syntheticDoc(ctx, ex.key)) |d| {
            try items.append(ctx.arena, .{
                .resource_type = d.key,
                .netbox_endpoint = d.netbox_endpoint,
                .display = d.display,
                .summary = d.summary,
                .low_fields = d.low,
                .high_fields = d.high,
            });
        }
    }
    try ctx.ok("describe", .{
        .principle = "Agent proposes intent; the CLI decides what is allowed.",
        .action = "update",
        .create_policy = .{
            .enabled_types = try policy.effectiveCreatableResources(ctx.arena, ctx.env),
            .note = "create is default-deny: only types listed in creatable_resources (or \"*\") may be created, and every create requires approval. `enabled_types` empty = no type may be created.",
        },
        .denied_actions = &[_][]const u8{ "delete", "bulk_delete" },
        .default_policy = "deny: only explicitly classified fields are writable",
        .read_policy = .{
            .tiers = &[_][]const u8{ "basic", "all" },
            .default = "basic",
            .sensitive_fields = try policy.effectiveReadSensitiveFields(ctx.arena, ctx.env),
            .note = "Read exposure tiers are classified separately from write risk: `--fields basic` (default) redacts read-sensitive fields; `--fields all` requires an approved read plan when sensitive fields are present.",
        },
        .resource_types = items.items,
        .next_action = "run `nbxg describe <type>` for a type's fields and its live NetBox schema",
    });
    return exit_ok;
}

/// Extract the writable-field metadata object from a NetBox `OPTIONS` response:
/// `actions.PUT` (update) is preferred, falling back to `actions.POST`.
fn netboxWritableFields(meta: std.json.Value) ?std.json.Value {
    const root = switch (meta) {
        .object => |o| o,
        else => return null,
    };
    const actions = root.get("actions") orelse return null;
    const actions_obj = switch (actions) {
        .object => |o| o,
        else => return null,
    };
    if (actions_obj.get("PUT")) |put| switch (put) {
        .object => return put,
        else => {},
    };
    if (actions_obj.get("POST")) |post| switch (post) {
        .object => return post,
        else => {},
    };
    return null;
}

/// Read a key from a JSON object value, or null if not an object / absent.
fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// How long a cached OpenAPI document is considered fresh (6 hours). The NetBox
/// schema changes rarely (model/plugin changes), so this avoids refetching the
/// multi-MB document on every `describe` while still picking up changes.
const openapi_cache_ttl_s: i64 = 6 * 3600;

/// Upper bound for the OpenAPI document we cache and read back. The base NetBox
/// schema is ~11 MB; this leaves generous headroom for plugin-heavy instances.
/// Read and write use the same bound so the cache can always be read back.
const openapi_max_bytes: usize = 64 * 1024 * 1024;

const LoadedSchema = union(enum) {
    ok: struct { value: std.json.Value, cached: bool, fetched_at: i64 },
    unavailable: []const u8,
};

/// Load the NetBox OpenAPI document, preferring a fresh on-disk cache under
/// `<state_dir>/cache/`. Fetches from NetBox (and rewrites the cache) when the
/// cache is missing, stale, unreadable, or `--refresh` was given. A read or
/// parse failure of the cache is treated as a miss (fall through to refetch),
/// never a hard error. Parsing uses the arena.
fn loadOpenApi(ctx: *Context, store: Store, refresh: bool) !LoadedSchema {
    const cache_rel = try store.path(&.{ "cache", "openapi-schema.json" });
    const meta_rel = try store.path(&.{ "cache", "openapi-schema.fetched_at" });

    if (!refresh) {
        if (store.readAlloc(meta_rel) catch null) |mb| {
            defer ctx.gpa.free(mb);
            const fetched = std.fmt.parseInt(i64, std.mem.trim(u8, mb, " \t\r\n"), 10) catch 0;
            const age = nsToSecs(ctx.nowNanos()) - fetched;
            if (fetched > 0 and age >= 0 and age < openapi_cache_ttl_s) {
                if (store.readAllocMax(cache_rel, openapi_max_bytes) catch null) |cb| {
                    defer ctx.gpa.free(cb);
                    if (std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, cb, .{ .allocate = .alloc_always })) |v| {
                        return .{ .ok = .{ .value = v, .cached = true, .fetched_at = fetched } };
                    } else |_| {}
                }
            }
        }
    }

    if (ctx.config.netbox_token == null)
        return .{ .unavailable = "no NETBOX_TOKEN and no fresh cache; cannot fetch OpenAPI schema" };

    var client = netbox.Client.init(ctx);
    defer client.deinit();
    const res = client.schema() catch |err| return .{ .unavailable = @errorName(err) };
    defer ctx.gpa.free(res.body);
    if (!res.ok)
        return .{ .unavailable = try std.fmt.allocPrint(ctx.arena, "NetBox /api/schema/ returned HTTP {d}", .{res.status}) };

    const now_s = nsToSecs(ctx.nowNanos());
    // Only persist a cache we can read back later (read and write share the cap).
    if (res.body.len <= openapi_max_bytes) {
        store.ensureSubdir(try store.path(&.{"cache"})) catch {};
        store.writeBytes(cache_rel, res.body) catch {};
        store.writeBytes(meta_rel, try std.fmt.allocPrint(ctx.arena, "{d}", .{now_s})) catch {};
    }

    const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, res.body, .{ .allocate = .alloc_always }) catch
        return .{ .unavailable = "failed to parse NetBox OpenAPI schema" };
    return .{ .ok = .{ .value = v, .cached = false, .fetched_at = now_s } };
}

/// Resolve the component-schema name for a type's PATCH request body, by walking
/// `paths./api/<ep>/{id}/.patch.requestBody.content.application/json.schema.$ref`.
/// Resolving dynamically avoids hardcoding NetBox's inconsistent component names
/// (e.g. `PatchedWritableDeviceWithConfigContextRequest`).
fn openApiComponent(arena: std.mem.Allocator, doc: std.json.Value, endpoint: []const u8) ?[]const u8 {
    const path_key = std.fmt.allocPrint(arena, "/api/{s}/{{id}}/", .{endpoint}) catch return null;
    const paths = objGet(doc, "paths") orelse return null;
    const path_item = objGet(paths, path_key) orelse return null;
    const patch = objGet(path_item, "patch") orelse return null;
    const body = objGet(patch, "requestBody") orelse return null;
    const content = objGet(body, "content") orelse return null;
    const appjson = objGet(content, "application/json") orelse return null;
    const sch = objGet(appjson, "schema") orelse return null;
    const ref = objGet(sch, "$ref") orelse return null;
    const ref_str = switch (ref) {
        .string => |s| s,
        else => return null,
    };
    const slash = std.mem.lastIndexOfScalar(u8, ref_str, '/') orelse return null;
    return ref_str[slash + 1 ..];
}

/// The `properties` object of a named component schema, or null.
fn openApiProperties(doc: std.json.Value, component: []const u8) ?std.json.Value {
    const components = objGet(doc, "components") orelse return null;
    const schemas = objGet(components, "schemas") orelse return null;
    const comp = objGet(schemas, component) orelse return null;
    return objGet(comp, "properties");
}

// ---------------------------------------------------------------------------
// config (capability introspection + human-approved governance changes)
// ---------------------------------------------------------------------------
//
// The guard is default-deny: out of the box the agent may only touch a small
// allow-list of types and fields. Ordinary operators often cannot hand-edit
// ~/.nbx-guard/config.json, so a tool that *only* refuses is a safe corpse. The
// answer is not to drop the gate but to make changing it transparent and
// governed: `config show` says, in plain words, exactly what the current config
// permits; `config set` lets the agent *propose* a change, which a human must
// approve (the same plan->approve->apply path as a data change) and which is
// fully audited. The agent never approves its own config change — even when
// NBX_GUARD_AUTO_APPROVE is on, a config change is never auto-approved.

const config_action = "config_set";
const config_resource_type = "operator_config";

const ConfigKeyKind = enum { boolean, integer, string, list, object_map, forbidden };

const ConfigKeySpec = struct {
    name: []const u8,
    kind: ConfigKeyKind,
    /// Risk surfaced to the human: "high" loosens governance, "medium" is a
    /// connection/runtime change. Every config change requires approval anyway.
    risk: []const u8,
    /// Plain-language consequence of setting this key, for the approval prompt.
    impact: []const u8,
};

const config_key_specs = [_]ConfigKeySpec{
    .{ .name = "auto_approve", .kind = .boolean, .risk = "high", .impact = "Turns OFF the manual approval gate: change plans (high-risk updates and creates) get auto-approved. Still audited. Only safe for your own branch/sandbox work — pair it with branching." },
    .{ .name = "creatable_resources", .kind = .list, .risk = "high", .impact = "Lets `nbxg create` make brand-new objects of these types (default: none). Use * for any type. Every create still needs approval." },
    .{ .name = "allowed_fields", .kind = .list, .risk = "high", .impact = "Lets the agent change these extra fields WITHOUT approval (treated low-risk). Built-in high-risk fields can never be downgraded." },
    .{ .name = "high_risk_fields", .kind = .list, .risk = "high", .impact = "Lets the agent change these extra fields, but each change needs an approval first." },
    .{ .name = "extra_resources", .kind = .object_map, .risk = "high", .impact = "Governs additional NetBox resource types (type:app/endpoint). The agent can then read and plan changes on them under the same policy." },
    .{ .name = "read_sensitive_fields", .kind = .list, .risk = "medium", .impact = "Marks more fields as sensitive: hidden on read unless a human runs approve-read. This only tightens exposure." },
    .{ .name = "netbox_url", .kind = .string, .risk = "medium", .impact = "Changes which NetBox instance every command talks to." },
    .{ .name = "token_file", .kind = .string, .risk = "medium", .impact = "Reads the NetBox token from this file (keychain/secret-manager friendly). The raw token is never stored in config." },
    .{ .name = "token_cmd", .kind = .string, .risk = "medium", .impact = "Runs this command and uses its stdout as the NetBox token (OS keychain hook). The raw token is never stored in config." },
    .{ .name = "state_dir", .kind = .string, .risk = "medium", .impact = "Moves where the guard keeps its own plans/approvals/backups/audit log." },
    .{ .name = "branch", .kind = .string, .risk = "medium", .impact = "Selects the NetBox Branching branch (schema id) to work in." },
    .{ .name = "branching", .kind = .boolean, .risk = "medium", .impact = "Works inside a NetBox Branching branch instead of live data (a safety net for changes)." },
    .{ .name = "http_timeout_ms", .kind = .integer, .risk = "medium", .impact = "How long to wait on a NetBox request before giving up (0 = wait forever)." },
    .{ .name = "netbox_token", .kind = .forbidden, .risk = "high", .impact = "The raw token must never be written to config." },
    .{ .name = "token", .kind = .forbidden, .risk = "high", .impact = "The raw token must never be written to config." },
};

fn configKeySpec(name: []const u8) ?ConfigKeySpec {
    for (config_key_specs) |k| if (eq(k.name, name)) return k;
    return null;
}

fn cmdConfig(ctx: *Context, rest: []const [:0]const u8) !u8 {
    if (rest.len == 0 or eq(rest[0], "show")) return cmdConfigShow(ctx);
    if (eq(rest[0], "set")) return cmdConfigSet(ctx, rest[1..]);
    try ctx.fail("config", .{
        .kind = .invalid_args,
        .message = "unknown config subcommand",
        .next_action = "use `nbxg config show` to see current capabilities, or `nbxg config set <key=value> ...` to propose a change",
    });
    return exit_client;
}

/// Resolve the operator config file this run reads/writes: the file actually
/// loaded (`ctx.config_path`), else an explicit `NBX_GUARD_CONFIG`, else the
/// default `$HOME/.nbx-guard/config.json`. Returns null only when no path can be
/// determined (no HOME and no override) so the caller emits a precise error.
fn operatorConfigTarget(ctx: *Context) !?[]const u8 {
    if (ctx.config_path) |p| return p;
    if (ctx.env.get("NBX_GUARD_CONFIG")) |v| {
        if (v.len != 0) return v;
    }
    const home = ctx.env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(ctx.arena, &.{ home, ".nbx-guard", "config.json" });
}

fn fileExists(ctx: *Context, path: []const u8) bool {
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

fn cmdConfigShow(ctx: *Context) !u8 {
    const ef = try policy.effectiveFields(ctx.arena, ctx.env);
    const creatable = try policy.effectiveCreatableResources(ctx.arena, ctx.env);
    const read_sensitive = try policy.effectiveReadSensitiveFields(ctx.arena, ctx.env);
    const auto = policy.autoApproveEnabled(ctx.env);

    var types: std.ArrayList([]const u8) = .empty;
    try types.appendSlice(ctx.arena, &.{ "device", "interface", "ip-address", "prefix", "vlan", "contact" });
    for (try envExtraResources(ctx)) |ex| try types.append(ctx.arena, ex.key);

    const target = try operatorConfigTarget(ctx);
    const cfg_exists = if (target) |t| fileExists(ctx, t) else false;

    var caps: std.ArrayList([]const u8) = .empty;
    try caps.append(ctx.arena, "Read any governed resource. Sensitive fields are hidden until a human runs `approve-read`.");
    try caps.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "Change these fields WITHOUT approval (low-risk): {s}.", .{try joinOrNone(ctx.arena, ef.allowed)}));
    try caps.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "Change these fields WITH one approval (high-risk): {s}.", .{try joinOrNone(ctx.arena, ef.high_risk)}));
    if (creatable.len == 0) {
        try caps.append(ctx.arena, "Create brand-new objects: disabled (no creatable types configured).");
    } else {
        try caps.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "Create brand-new objects of: {s} (every create still needs approval).", .{try joinOrNone(ctx.arena, creatable)}));
    }
    if (auto) {
        try caps.append(ctx.arena, "Auto-approve is ON: change plans are approved automatically (still backed up and audited). Best paired with branching. Config changes are NEVER auto-approved.");
    } else {
        try caps.append(ctx.arena, "Auto-approve is OFF: every high-risk change waits for `nbxg approve`.");
    }

    var to_change: std.ArrayList([]const u8) = .empty;
    try to_change.append(ctx.arena, "Auto-approve your own branch/sandbox work: nbxg config set auto_approve=true");
    try to_change.append(ctx.arena, "Let the agent change a new field without approval: nbxg config set allowed_fields=<field>");
    try to_change.append(ctx.arena, "Allow a new field but keep approval: nbxg config set high_risk_fields=<field>");
    try to_change.append(ctx.arena, "Allow creating a new object type: nbxg config set creatable_resources=<type>");
    try to_change.append(ctx.arena, "Govern a new resource type: nbxg config set extra_resources=<type>:<app/endpoint>");

    const Token = struct { configured: bool, source: []const u8 };
    const Connection = struct {
        netbox_url: []const u8,
        branching: bool,
        branch: ?[]const u8 = null,
        state_dir: []const u8,
        http_timeout_ms: u64,
    };
    const ConfigFile = struct { path: ?[]const u8, exists: bool };
    const Governance = struct {
        auto_approve: bool,
        governed_resource_types: []const []const u8,
        creatable_resources: []const []const u8,
        writable_without_approval: []const []const u8,
        writable_with_approval: []const []const u8,
        read_sensitive_fields: []const []const u8,
    };
    const Report = struct {
        summary: []const u8 = "This is exactly what the agent may do right now. To do more, the agent proposes a change with `nbxg config set`, a human approves it, and it is audited — refusing is never the only option.",
        token: Token,
        connection: Connection,
        config_file: ConfigFile,
        governance: Governance,
        capabilities: []const []const u8,
        to_change: []const []const u8,
        change_workflow: []const u8 = "nbxg config set <key=value>  ->  (human) nbxg approve --plan <id>  ->  nbxg apply --plan <id>",
        next_action: []const u8 = "decide what the agent needs; if the current config already allows it, just proceed — otherwise propose it with `nbxg config set` and ask a human to approve",
    };

    try ctx.ok("config", Report{
        .token = .{ .configured = ctx.config.netbox_token != null, .source = ctx.token_source },
        .connection = .{
            .netbox_url = ctx.config.netbox_url,
            .branching = ctx.config.branching,
            .branch = netbox.activeBranch(ctx.config),
            .state_dir = ctx.config.state_dir,
            .http_timeout_ms = ctx.config.http_timeout_ms,
        },
        .config_file = .{ .path = target, .exists = cfg_exists },
        .governance = .{
            .auto_approve = auto,
            .governed_resource_types = try types.toOwnedSlice(ctx.arena),
            .creatable_resources = creatable,
            .writable_without_approval = ef.allowed,
            .writable_with_approval = ef.high_risk,
            .read_sensitive_fields = read_sensitive,
        },
        .capabilities = try caps.toOwnedSlice(ctx.arena),
        .to_change = try to_change.toOwnedSlice(ctx.arena),
    });
    return exit_ok;
}

fn joinOrNone(arena: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    if (items.len == 0) return "(none)";
    return joinList(arena, items);
}

/// Turn a `config set` value string into the JSON value the config schema expects
/// for `spec.kind`. Lists/object-maps are comma-separated; an object-map entry is
/// `type:app/endpoint`. Returns InvalidConfigValue on a malformed value.
fn buildConfigValue(arena: std.mem.Allocator, spec: ConfigKeySpec, raw: []const u8) error{ OutOfMemory, InvalidConfigValue }!std.json.Value {
    const v = std.mem.trim(u8, raw, " \t");
    switch (spec.kind) {
        .forbidden => return error.InvalidConfigValue,
        .boolean => {
            if (eq(v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes") or std.ascii.eqlIgnoreCase(v, "on"))
                return .{ .bool = true };
            if (eq(v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "no") or std.ascii.eqlIgnoreCase(v, "off"))
                return .{ .bool = false };
            return error.InvalidConfigValue;
        },
        .integer => {
            const n = std.fmt.parseInt(i64, v, 10) catch return error.InvalidConfigValue;
            if (n < 0) return error.InvalidConfigValue;
            return .{ .integer = n };
        },
        .string => {
            if (v.len == 0) return error.InvalidConfigValue;
            return .{ .string = v };
        },
        .list => {
            var arr = std.json.Array.init(arena);
            var it = std.mem.tokenizeAny(u8, v, ", \t");
            while (it.next()) |tok| try arr.append(.{ .string = tok });
            return .{ .array = arr };
        },
        .object_map => {
            var obj: std.json.ObjectMap = .empty;
            var it = std.mem.tokenizeAny(u8, v, ", \t");
            while (it.next()) |entry| {
                const ci = std.mem.indexOfScalar(u8, entry, ':') orelse return error.InvalidConfigValue;
                const k = std.mem.trim(u8, entry[0..ci], " \t");
                const path = std.mem.trim(u8, entry[ci + 1 ..], " \t");
                if (k.len == 0 or path.len == 0) return error.InvalidConfigValue;
                try obj.put(arena, k, .{ .string = path });
            }
            if (obj.count() == 0) return error.InvalidConfigValue;
            return .{ .object = obj };
        },
    }
}

fn cmdConfigSet(ctx: *Context, rest: []const [:0]const u8) !u8 {
    const note = findFlag(rest, "--note");
    const pairs = try parseSet(ctx.arena, rest);
    if (pairs.len == 0) {
        try ctx.fail("config", .{
            .kind = .invalid_args,
            .message = "no settings given; use `nbxg config set <key=value> ...`",
            .next_action = "run `nbxg config show` to see the keys you can change (e.g. auto_approve=true, allowed_fields=serial, creatable_resources=site)",
        });
        return exit_client;
    }

    const target = (try operatorConfigTarget(ctx)) orelse {
        try ctx.fail("config", .{
            .kind = .config_error,
            .message = "cannot locate the operator config file (no HOME and no NBX_GUARD_CONFIG)",
            .next_action = "set NBX_GUARD_CONFIG to the path of the config file to manage",
        });
        return exit_upstream;
    };

    // Build the proposed change object (validated, typed) and a from/to summary.
    var changes_obj: std.json.ObjectMap = .empty;
    const ChangeDetail = struct {
        key: []const u8,
        from: std.json.Value,
        to: std.json.Value,
        risk: []const u8,
        impact: []const u8,
    };
    var details: std.ArrayList(ChangeDetail) = .empty;
    var max_risk: []const u8 = "medium";

    // Current file contents (for from-values + merge baseline).
    const current_bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, target, ctx.gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            try ctx.fail("config", .{
                .kind = .config_error,
                .message = "failed to read the existing operator config file",
                .next_action = "check the path and permissions of the config file",
            });
            return exit_upstream;
        },
    };
    defer if (current_bytes) |b| ctx.gpa.free(b);
    const current_root: ?std.json.Value = if (current_bytes) |b|
        (std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, b, .{}) catch {
            try ctx.fail("config", .{
                .kind = .config_error,
                .message = "the existing operator config file is not valid JSON",
                .next_action = "fix or remove the malformed ~/.nbx-guard/config.json before changing it",
            });
            return exit_upstream;
        })
    else
        null;
    const current_obj: ?std.json.ObjectMap = if (current_root) |r| switch (r) {
        .object => |o| o,
        else => {
            try ctx.fail("config", .{
                .kind = .config_error,
                .message = "the existing operator config file is not a JSON object",
                .next_action = "the config file root must be a JSON object ({ ... })",
            });
            return exit_upstream;
        },
    } else null;

    for (pairs) |kv| {
        const spec = configKeySpec(kv.key) orelse {
            try ctx.fail("config", .{
                .kind = .invalid_args,
                .message = "unknown config key",
                .next_action = "run `nbxg config show` for the list of changeable keys; the raw NetBox token is never stored in config (use token_file/token_cmd)",
            });
            return exit_client;
        };
        if (spec.kind == .forbidden) {
            try ctx.fail("config", .{
                .kind = .config_error,
                .message = "the raw NetBox token must never be written to config",
                .next_action = "use `nbxg config set token_cmd=...` (keychain) or `token_file=...`, or keep NETBOX_TOKEN in the environment",
            });
            return exit_client;
        }
        const value = buildConfigValue(ctx.arena, spec, kv.value) catch {
            try ctx.fail("config", .{
                .kind = .invalid_args,
                .message = "invalid value for config key",
                .next_action = "booleans: true/false; integers: a non-negative number; lists: comma-separated (a,b); extra_resources: type:app/endpoint,type2:app/endpoint",
            });
            return exit_client;
        };
        try changes_obj.put(ctx.arena, kv.key, value);
        const from = if (current_obj) |o| (o.get(kv.key) orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
        try details.append(ctx.arena, .{ .key = kv.key, .from = from, .to = value, .risk = spec.risk, .impact = spec.impact });
        if (eq(spec.risk, "high")) max_risk = "high";
    }
    const changes_value = std.json.Value{ .object = changes_obj };

    // Defense in depth: the merged file must stay valid and secret-free.
    var merged: std.json.ObjectMap = .empty;
    if (current_obj) |o| {
        var it = o.iterator();
        while (it.next()) |e| try merged.put(ctx.arena, e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = changes_obj.iterator();
        while (it.next()) |e| try merged.put(ctx.arena, e.key_ptr.*, e.value_ptr.*);
    }
    const merged_bytes = try std.json.Stringify.valueAlloc(ctx.arena, std.json.Value{ .object = merged }, .{ .whitespace = .indent_2 });
    _ = config.parseExtJson(ctx.arena, merged_bytes) catch {
        try ctx.fail("config", .{
            .kind = .config_error,
            .message = "the resulting config would be invalid",
            .next_action = "check the key/value types; run `nbxg config show` for guidance",
        });
        return exit_client;
    };

    const base_values = blk: {
        var bo: std.json.ObjectMap = .empty;
        for (details.items) |d| try bo.put(ctx.arena, d.key, d.from);
        break :blk std.json.Value{ .object = bo };
    };

    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const now_ns = ctx.nowNanos();
    const p: plan.Plan = .{
        .plan_id = try ids.genId(ctx.arena, "plan", now_ns),
        .request_id = try ids.genId(ctx.arena, "req", now_ns),
        .plan_hash = try plan.computeHash(ctx.arena, config_resource_type, target, config_action, changes_value),
        .resource_type = config_resource_type,
        .resource_id = target,
        .action = config_action,
        .changes = changes_value,
        .risk_level = max_risk,
        // A governance change ALWAYS needs a human. It is never auto-approved,
        // even with NBX_GUARD_AUTO_APPROVE on, so the agent cannot self-grant
        // power: maybeAutoApprove is deliberately not called here.
        .requires_approval = true,
        .status = plan.status_pending_approval,
        .created_at = nsToSecs(now_ns),
        .netbox_url = ctx.config.netbox_url,
        .base_values = base_values,
    };
    try plan.save(store, p);

    try audit.append(store, .{
        .ts = p.created_at,
        .request_id = p.request_id,
        .event = "plan_created",
        .plan_id = p.plan_id,
        .resource_type = p.resource_type,
        .resource_id = p.resource_id,
        .risk_level = p.risk_level,
        .detail = note orelse "config_set",
    });

    try ctx.ok("config", .{
        .plan = p,
        .config_file = .{ .path = target, .exists = current_bytes != null },
        .changes = details.items,
        .risk_level = max_risk,
        .note = "This is a PROPOSAL — nothing changed yet. A human must review and approve it; the agent must not approve its own config change. The change is auditable and reversible (a backup of the old config is kept on apply).",
        .next_action = "ask an operator to review, then run `nbxg approve --plan <plan_id>` (human), and finally `nbxg apply --plan <plan_id>` to write the new config",
    });
    return exit_ok;
}

/// Apply an approved `config_set` plan: merge the proposed keys into the operator
/// config file, after backing up the prior file under `<state_dir>/config-backups/`.
/// Reached only from `cmdApply` once the plan is approved and its hash verified.
/// The caller already holds the store lock.
fn applyConfigChange(ctx: *Context, store: Store, p: *plan.Plan) !u8 {
    const target = p.resource_id;

    const changes_obj = switch (p.changes) {
        .object => |o| o,
        else => {
            try ctx.fail("apply", .{
                .kind = .plan_state_error,
                .message = "config plan has no change set",
                .next_action = "discard this plan and create a new one with `nbxg config set`",
            });
            return exit_client;
        },
    };

    // Read the current file fresh at apply time (it may have changed since the
    // proposal). Merge proposed keys over it; re-validate; never write a secret.
    const current_bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, target, ctx.gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            try ctx.fail("apply", .{
                .kind = .config_error,
                .message = "failed to read the operator config file for update",
                .next_action = "check the path and permissions of the config file",
            });
            return exit_upstream;
        },
    };
    defer if (current_bytes) |b| ctx.gpa.free(b);

    var merged: std.json.ObjectMap = .empty;
    if (current_bytes) |b| {
        const root = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, b, .{}) catch {
            try ctx.fail("apply", .{
                .kind = .config_error,
                .message = "the operator config file is not valid JSON",
                .next_action = "fix or remove the malformed config file, then re-propose the change",
            });
            return exit_upstream;
        };
        switch (root) {
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |e| try merged.put(ctx.arena, e.key_ptr.*, e.value_ptr.*);
            },
            else => {
                try ctx.fail("apply", .{
                    .kind = .config_error,
                    .message = "the operator config file is not a JSON object",
                    .next_action = "the config file root must be a JSON object ({ ... })",
                });
                return exit_upstream;
            },
        }
    }
    {
        var it = changes_obj.iterator();
        while (it.next()) |e| {
            if (eq(e.key_ptr.*, "netbox_token") or eq(e.key_ptr.*, "token")) {
                try ctx.fail("apply", .{
                    .kind = .config_error,
                    .message = "refusing to write a raw token into config",
                    .next_action = "discard this plan; use token_file/token_cmd instead",
                });
                return exit_client;
            }
            try merged.put(ctx.arena, e.key_ptr.*, e.value_ptr.*);
        }
    }

    const merged_bytes = try std.json.Stringify.valueAlloc(ctx.arena, std.json.Value{ .object = merged }, .{ .whitespace = .indent_2 });
    _ = config.parseExtJson(ctx.arena, merged_bytes) catch {
        try ctx.fail("apply", .{
            .kind = .config_error,
            .message = "the resulting config would be invalid; nothing was written",
            .next_action = "discard this plan and re-propose with valid values",
        });
        return exit_client;
    };

    const now_ns = ctx.nowNanos();
    const request_id = try ids.genId(ctx.arena, "req", now_ns);

    // Back up the prior file so the change is reversible.
    try store.ensureSubdir(try store.path(&.{"config-backups"}));
    const backup_name = try std.fmt.allocPrint(ctx.arena, "{s}.json", .{p.plan_id});
    const backup_rel = try store.path(&.{ "config-backups", backup_name });
    const prior_bytes = current_bytes orelse "{}\n";
    try store.writeBytes(backup_rel, prior_bytes);

    // Ensure the target directory exists (first-ever config write), then write
    // the merged config atomically (temp + rename).
    if (std.fs.path.dirname(target)) |d| std.Io.Dir.cwd().createDirPath(ctx.io, d) catch {};
    store.writeBytes(target, merged_bytes) catch {
        try audit.append(store, .{
            .ts = nsToSecs(ctx.nowNanos()),
            .request_id = request_id,
            .event = "apply_failed",
            .plan_id = p.plan_id,
            .resource_type = p.resource_type,
            .resource_id = target,
            .risk_level = p.risk_level,
            .detail = "failed to write config file",
        });
        try ctx.fail("apply", .{
            .kind = .config_error,
            .message = "failed to write the operator config file",
            .next_action = "check the path and permissions; the prior config is backed up under <state_dir>/config-backups/",
        });
        return exit_upstream;
    };

    p.status = plan.status_applied;
    p.backup_id = backup_rel;
    try plan.save(store, p.*);

    var keys: std.ArrayList([]const u8) = .empty;
    {
        var it = changes_obj.iterator();
        while (it.next()) |e| try keys.append(ctx.arena, e.key_ptr.*);
    }
    const keys_joined = try joinList(ctx.arena, keys.items);

    try audit.append(store, .{
        .ts = nsToSecs(now_ns),
        .request_id = request_id,
        .event = "config_applied",
        .plan_id = p.plan_id,
        .approval_id = p.approval_id,
        .backup_id = backup_rel,
        .resource_type = p.resource_type,
        .resource_id = target,
        .risk_level = p.risk_level,
        .detail = keys_joined,
    });

    try ctx.ok("apply", .{
        .request_id = request_id,
        .plan_id = p.plan_id,
        .backup_id = backup_rel,
        .status = p.status,
        .action = config_action,
        .config_file = target,
        .applied = p.changes,
        .diff = .{ .before = p.base_values, .after = p.changes },
        .next_action = "the new configuration takes effect on the next `nbxg` run; to roll back, restore the backup file shown in backup_id over the config file",
    });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// plan
// ---------------------------------------------------------------------------

fn cmdPlan(ctx: *Context, rest: []const [:0]const u8) !u8 {
    if (rest.len < 2) {
        try ctx.fail("plan", .{
            .kind = .invalid_args,
            .message = "expected <type> <id> --set field=value ...",
            .next_action = "see `nbxg describe <type>` for fields; example: nbxg plan device 1 --set description=\"edge router\"",
        });
        return exit_client;
    }
    const rtype = rest[0];
    const rid = rest[1];
    if (netbox.endpointFor(ctx.env, rtype) == null) return failUnknownType(ctx, "plan", rtype);

    const changes = try parseSet(ctx.arena, rest[2..]);
    if (changes.len == 0) {
        try ctx.fail("plan", .{
            .kind = .invalid_args,
            .message = "no changes given; use --set field=value",
            .next_action = "add at least one --set field=value",
        });
        return exit_client;
    }

    const changes_value = try plan.buildChanges(ctx.arena, changes);
    const fields = try plan.changeFields(ctx.arena, changes_value);
    const eval = try policy.evaluateEnv(ctx.arena, ctx.env, fields);

    if (eval.decision == .deny) {
        try ctx.fail("plan", .{
            .kind = .policy_denied,
            .message = "one or more fields are not writable by policy (default-deny)",
            .risk_level = eval.risk_level,
            .next_action = "remove the denied field(s), or have an operator allow one: `nbxg config set allowed_fields=<field>` (no approval needed for it) or `high_risk_fields=<field>` (approval-gated). That proposal is itself human-approved and audited. See `nbxg config show`.",
        });
        return exit_client;
    }

    // Observe current state so the plan binds to a concrete baseline; apply uses
    // it to detect drift. The CLI holds NetBox creds, so this needs a token.
    if (ctx.config.netbox_token == null) return failNoToken(ctx, "plan");
    var client = netbox.Client.init(ctx);
    defer client.deinit();
    const base_res = client.get(rtype, rid) catch |err| return failNetboxConn(ctx, "plan", err);
    defer ctx.gpa.free(base_res.body);
    if (!base_res.ok) return failNetboxStatus(ctx, "plan", base_res);
    const base_snapshot = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, base_res.body, .{}) catch
        std.json.Value{ .null = {} };
    const base_values = try backup.priorValues(ctx.arena, base_snapshot, fields);

    // No-op guard: when every requested value already equals the current NetBox
    // value, a plan would encode an empty change. Refuse with `no_change` and
    // create nothing (no plan, approval, backup, or audit record) so agents don't
    // apply nothing. Partial changes (any field differs) proceed normally.
    if (plan.allUnchanged(changes_value, base_values, fields)) {
        try ctx.failData("plan", .{
            .kind = .no_change,
            .message = "requested values already match the current resource state; no change plan was created",
            .risk_level = "low",
            .next_action = "nothing to change — the resource already has these values; inspect with `nbxg get <type> <id>` or set different values",
        }, .{
            .status = "no_change",
            .resource_type = rtype,
            .resource_id = rid,
            .requested = changes_value,
            .current = base_values,
        });
        return exit_client;
    }

    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const now_ns = ctx.nowNanos();
    const p: plan.Plan = .{
        .plan_id = try ids.genId(ctx.arena, "plan", now_ns),
        .request_id = try ids.genId(ctx.arena, "req", now_ns),
        .plan_hash = try plan.computeHash(ctx.arena, rtype, rid, "update", changes_value),
        .resource_type = rtype,
        .resource_id = rid,
        .action = "update",
        .changes = changes_value,
        .risk_level = eval.risk_level,
        .requires_approval = eval.requires_approval,
        .status = if (eval.requires_approval) plan.status_pending_approval else plan.status_planned,
        .created_at = nsToSecs(now_ns),
        .netbox_url = ctx.config.netbox_url,
        .base_values = base_values,
    };
    try plan.save(store, p);

    try audit.append(store, .{
        .ts = p.created_at,
        .request_id = p.request_id,
        .event = "plan_created",
        .plan_id = p.plan_id,
        .resource_type = rtype,
        .resource_id = rid,
        .risk_level = p.risk_level,
    });

    var approved_plan = p;
    const auto_approved = try maybeAutoApprove(ctx, store, &approved_plan);

    const next_action = if (auto_approved)
        "auto-approved (recorded in the audit log): run `nbxg apply --plan <plan_id>`"
    else if (approved_plan.requires_approval)
        "high-risk: run `nbxg approve --plan <plan_id>`, then `apply`"
    else
        "low-risk: run `nbxg apply --plan <plan_id>`";

    try ctx.ok("plan", .{
        .plan = approved_plan,
        .evaluation = eval,
        .auto_approved = auto_approved,
        .next_action = next_action,
    });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// create (governed object creation: opt-in type + mandatory approval)
// ---------------------------------------------------------------------------

fn cmdCreate(ctx: *Context, rest: []const [:0]const u8) !u8 {
    if (rest.len < 1) {
        try ctx.fail("create", .{
            .kind = .invalid_args,
            .message = "expected <type> --set field=value ...",
            .next_action = "example: nbxg create site --set name=POP3 --set slug=pop3   (see `nbxg describe <type>` for fields)",
        });
        return exit_client;
    }
    const rtype = rest[0];
    if (netbox.endpointFor(ctx.env, rtype) == null) return failUnknownType(ctx, "create", rtype);

    // Type-level opt-in (default-deny): an operator must list the type in
    // `creatable_resources` (config.json) / NBX_GUARD_CREATABLE_RESOURCES. Unlike
    // update, create does not apply per-field policy — a new object needs its
    // identifying/required fields (name, slug, …) that are not in allowed_fields.
    // The governance for create is the type opt-in plus the mandatory approval,
    // backup-as-delete rollback, and audit trail below.
    if (!policy.creatableAllowed(ctx.env, rtype)) {
        try ctx.fail("create", .{
            .kind = .policy_denied,
            .message = "creating this resource type is not permitted (default-deny)",
            .next_action = "have an operator allow it: `nbxg config set creatable_resources=<type>` (use * for any type). That proposal is human-approved and audited; then every create still needs its own approval. See `nbxg config show`.",
        });
        return exit_client;
    }

    const changes = try parseSet(ctx.arena, rest[1..]);
    if (changes.len == 0) {
        try ctx.fail("create", .{
            .kind = .invalid_args,
            .message = "no fields given; use --set field=value",
            .next_action = "add at least one --set field=value (NetBox enforces which fields are required)",
        });
        return exit_client;
    }
    const changes_value = try plan.buildChanges(ctx.arena, changes);

    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const now_ns = ctx.nowNanos();
    const p: plan.Plan = .{
        .plan_id = try ids.genId(ctx.arena, "plan", now_ns),
        .request_id = try ids.genId(ctx.arena, "req", now_ns),
        .plan_hash = try plan.computeHash(ctx.arena, rtype, create_sentinel_id, "create", changes_value),
        .resource_type = rtype,
        .resource_id = create_sentinel_id,
        .action = "create",
        .changes = changes_value,
        // Creating a new object is always treated as high-risk: it must be
        // approved by a human before the POST. base_values stays null (nothing
        // existed beforehand, so there is no drift baseline).
        .risk_level = "high",
        .requires_approval = true,
        .status = plan.status_pending_approval,
        .created_at = nsToSecs(now_ns),
        .netbox_url = ctx.config.netbox_url,
        .base_values = .{ .null = {} },
    };
    try plan.save(store, p);

    try audit.append(store, .{
        .ts = p.created_at,
        .request_id = p.request_id,
        .event = "plan_created",
        .plan_id = p.plan_id,
        .resource_type = rtype,
        .resource_id = create_sentinel_id,
        .risk_level = p.risk_level,
        .detail = "create",
    });

    var approved_plan = p;
    const auto_approved = try maybeAutoApprove(ctx, store, &approved_plan);

    try ctx.ok("create", .{
        .plan = approved_plan,
        .auto_approved = auto_approved,
        .note = if (auto_approved)
            "create was auto-approved (NBX_GUARD_AUTO_APPROVE); it is still backed up and audited, and its rollback is a delete via restore"
        else
            "create is approval-gated: review every field, then approve and apply",
        .next_action = if (auto_approved)
            "run `nbxg apply --plan <plan_id>`"
        else
            "run `nbxg approve --plan <plan_id>`, then `nbxg apply --plan <plan_id>`",
    });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// approve
// ---------------------------------------------------------------------------

/// If the operator enabled auto-approval (NBX_GUARD_AUTO_APPROVE / config
/// `auto_approve`), satisfy the change-approval gate for `p` in place: record a
/// real approval bound to the plan_hash (approver "auto"), flip the plan to
/// approved, and append an `auto_approved` audit event. Every other control —
/// plan-hash integrity, drift detection, pre-change backup, and the audit trail —
/// is untouched, so `apply` behaves exactly as if a human had approved. Returns
/// false (no-op) when the plan needs no approval or auto-approval is off. The
/// caller must already hold the store lock.
fn maybeAutoApprove(ctx: *Context, store: Store, p: *plan.Plan) !bool {
    if (!p.requires_approval) return false;
    if (!policy.autoApproveEnabled(ctx.env)) return false;

    const now_ns = ctx.nowNanos();
    const a: approval.Approval = .{
        .approval_id = try ids.genId(ctx.arena, "appr", now_ns),
        .plan_id = p.plan_id,
        .plan_hash = p.plan_hash,
        .resource_type = p.resource_type,
        .resource_id = p.resource_id,
        .risk_level = p.risk_level,
        .status = approval.status_approved,
        .approver = "auto",
        .created_at = nsToSecs(now_ns),
        .note = "auto-approved by NBX_GUARD_AUTO_APPROVE",
    };
    try approval.save(store, a);

    p.status = plan.status_approved;
    p.approval_id = a.approval_id;
    try plan.save(store, p.*);

    try audit.append(store, .{
        .ts = a.created_at,
        .request_id = try ids.genId(ctx.arena, "req", now_ns),
        .event = "auto_approved",
        .plan_id = p.plan_id,
        .approval_id = a.approval_id,
        .resource_type = p.resource_type,
        .resource_id = p.resource_id,
        .risk_level = p.risk_level,
    });
    return true;
}

fn cmdApprove(ctx: *Context, rest: []const [:0]const u8) !u8 {
    const plan_id = findFlag(rest, "--plan") orelse return failMissingFlag(ctx, "approve", "--plan");
    const note = findFlag(rest, "--note");

    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const loaded = (try plan.load(store, plan_id)) orelse return failPlanNotFound(ctx, "approve", plan_id);
    defer loaded.deinit();
    var p = loaded.value;

    if (eq(p.action, "read")) {
        try ctx.fail("approve", .{
            .kind = .plan_state_error,
            .message = "this is a read plan; use approve-read to approve a full read",
            .risk_level = p.risk_level,
            .next_action = "run `nbxg approve-read --plan <plan_id>`",
        });
        return exit_client;
    }

    if (!eq(p.status, plan.status_pending_approval)) {
        try ctx.fail("approve", .{
            .kind = .plan_state_error,
            .message = "plan is not awaiting approval",
            .risk_level = p.risk_level,
            .next_action = "only plans in 'pending_approval' can be approved",
        });
        return exit_client;
    }

    const now_ns = ctx.nowNanos();
    const a: approval.Approval = .{
        .approval_id = try ids.genId(ctx.arena, "appr", now_ns),
        .plan_id = p.plan_id,
        .plan_hash = p.plan_hash,
        .resource_type = p.resource_type,
        .resource_id = p.resource_id,
        .risk_level = p.risk_level,
        .status = approval.status_approved,
        .approver = ctx.env.get("USER") orelse "cli",
        .created_at = nsToSecs(now_ns),
        .note = note,
    };
    try approval.save(store, a);

    p.status = plan.status_approved;
    p.approval_id = a.approval_id;
    try plan.save(store, p);

    try audit.append(store, .{
        .ts = a.created_at,
        .request_id = try ids.genId(ctx.arena, "req", now_ns),
        .event = "approved",
        .plan_id = p.plan_id,
        .approval_id = a.approval_id,
        .resource_type = p.resource_type,
        .resource_id = p.resource_id,
        .risk_level = p.risk_level,
    });

    try ctx.ok("approve", .{
        .approval = a,
        .plan_status = p.status,
        .next_action = "run `nbxg apply --plan <plan_id>`",
    });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// approve-read (human-in-the-loop gate for a full, sensitive read)
// ---------------------------------------------------------------------------

fn cmdApproveRead(ctx: *Context, rest: []const [:0]const u8) !u8 {
    const plan_id = findFlag(rest, "--plan") orelse return failMissingFlag(ctx, "approve-read", "--plan");
    const note = findFlag(rest, "--note");

    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const loaded = (try plan.load(store, plan_id)) orelse return failPlanNotFound(ctx, "approve-read", plan_id);
    defer loaded.deinit();
    var p = loaded.value;

    if (!eq(p.action, "read")) {
        try ctx.fail("approve-read", .{
            .kind = .plan_state_error,
            .message = "this is not a read plan; use approve for write plans",
            .risk_level = p.risk_level,
            .next_action = "run `nbxg approve --plan <plan_id>` for a write plan",
        });
        return exit_client;
    }
    if (!eq(p.status, plan.status_pending_approval)) {
        try ctx.fail("approve-read", .{
            .kind = .plan_state_error,
            .message = "read plan is not awaiting approval",
            .risk_level = p.risk_level,
            .next_action = "only read plans in 'pending_approval' can be approved",
        });
        return exit_client;
    }

    const now_ns = ctx.nowNanos();
    const a: approval.Approval = .{
        .approval_id = try ids.genId(ctx.arena, "appr", now_ns),
        .plan_id = p.plan_id,
        .plan_hash = p.plan_hash,
        .resource_type = p.resource_type,
        .resource_id = p.resource_id,
        .risk_level = p.risk_level,
        .status = approval.status_approved,
        .approver = ctx.env.get("USER") orelse "cli",
        .created_at = nsToSecs(now_ns),
        .note = note,
    };
    try approval.save(store, a);

    p.status = plan.status_approved;
    p.approval_id = a.approval_id;
    try plan.save(store, p);

    try audit.append(store, .{
        .ts = a.created_at,
        .request_id = try ids.genId(ctx.arena, "req", now_ns),
        .event = "read_approved",
        .plan_id = p.plan_id,
        .approval_id = a.approval_id,
        .resource_type = p.resource_type,
        .resource_id = p.resource_id,
        .risk_level = p.risk_level,
    });

    try ctx.ok("approve-read", .{
        .approval = a,
        .plan_status = p.status,
        .next_action = "run `nbxg get <type> <id> --fields all --plan <plan_id>` (or `inspect`) to disclose the full object",
    });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// reject
// ---------------------------------------------------------------------------

fn cmdReject(ctx: *Context, rest: []const [:0]const u8) !u8 {
    const plan_id = findFlag(rest, "--plan") orelse return failMissingFlag(ctx, "reject", "--plan");
    const note = findFlag(rest, "--note");

    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const loaded = (try plan.load(store, plan_id)) orelse return failPlanNotFound(ctx, "reject", plan_id);
    defer loaded.deinit();
    var p = loaded.value;

    if (eq(p.status, plan.status_applied)) {
        try ctx.fail("reject", .{
            .kind = .plan_state_error,
            .message = "an applied plan cannot be rejected",
            .next_action = "create a new plan for further changes",
        });
        return exit_client;
    }
    if (eq(p.status, plan.status_rejected)) {
        try ctx.fail("reject", .{
            .kind = .plan_state_error,
            .message = "plan is already rejected",
            .next_action = "create a new plan",
        });
        return exit_client;
    }

    p.status = plan.status_rejected;
    try plan.save(store, p);

    const now_ns = ctx.nowNanos();
    try audit.append(store, .{
        .ts = nsToSecs(now_ns),
        .request_id = try ids.genId(ctx.arena, "req", now_ns),
        .event = "rejected",
        .plan_id = p.plan_id,
        .approval_id = p.approval_id,
        .resource_type = p.resource_type,
        .resource_id = p.resource_id,
        .risk_level = p.risk_level,
        .detail = note,
    });

    try ctx.ok("reject", .{
        .plan_id = p.plan_id,
        .status = p.status,
        .next_action = "this plan is rejected and can never be applied",
    });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// apply
// ---------------------------------------------------------------------------

fn cmdApply(ctx: *Context, rest: []const [:0]const u8) !u8 {
    const plan_id = findFlag(rest, "--plan") orelse return failMissingFlag(ctx, "apply", "--plan");

    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const loaded = (try plan.load(store, plan_id)) orelse return failPlanNotFound(ctx, "apply", plan_id);
    defer loaded.deinit();
    var p = loaded.value;

    if (eq(p.action, "read")) {
        try ctx.fail("apply", .{
            .kind = .plan_state_error,
            .message = "read plans are not applied; they authorize a full read",
            .next_action = "run `nbxg get <type> <id> --fields all --plan <plan_id>` instead",
        });
        return exit_client;
    }

    if (eq(p.status, plan.status_applied)) {
        try ctx.fail("apply", .{
            .kind = .plan_state_error,
            .message = "plan has already been applied",
            .next_action = "create a new plan for further changes",
        });
        return exit_client;
    }
    if (eq(p.status, plan.status_rejected)) {
        try ctx.fail("apply", .{
            .kind = .plan_state_error,
            .message = "plan was rejected and cannot be applied",
            .next_action = "create a new plan",
        });
        return exit_client;
    }
    if (p.requires_approval and !eq(p.status, plan.status_approved)) {
        try ctx.fail("apply", .{
            .kind = .not_approved,
            .message = "high-risk plan requires approval before apply",
            .risk_level = p.risk_level,
            .next_action = "run `nbxg approve --plan " ++ "" ++ "<plan_id>` first",
        });
        return exit_client;
    }

    // Integrity: the stored plan must still hash to its recorded plan_hash, and a
    // high-risk plan's approval must bind that exact hash. This makes the
    // approve->apply window tamper-evident instead of merely status-checked.
    const recomputed = try plan.computeHash(ctx.arena, p.resource_type, p.resource_id, p.action, p.changes);
    if (!eq(recomputed, p.plan_hash)) {
        try ctx.fail("apply", .{
            .kind = .plan_state_error,
            .message = "plan integrity check failed: stored plan does not match its plan_hash",
            .risk_level = p.risk_level,
            .next_action = "discard this tampered plan and create a new one",
        });
        return exit_client;
    }
    if (p.requires_approval) {
        const bound = if (p.approval_id) |aid| (try approval.load(store, aid)) else null;
        defer {
            if (bound) |bp| bp.deinit();
        }
        const bound_ok = if (bound) |bp| eq(bp.value.plan_hash, p.plan_hash) else false;
        if (!bound_ok) {
            try ctx.fail("apply", .{
                .kind = .plan_state_error,
                .message = "approval does not match this plan (missing approval or plan_hash mismatch)",
                .risk_level = p.risk_level,
                .next_action = "re-approve the plan before applying",
            });
            return exit_client;
        }
    }

    // A governance change writes a local file, not NetBox: it needs no token and
    // no NetBox round-trip. Route it once approved + integrity-verified.
    if (eq(p.action, config_action)) return applyConfigChange(ctx, store, &p);

    // Re-validate the stored plan (defense in depth). `create` is gated by type
    // opt-in (no per-field policy — a new object needs identifying fields that are
    // not in the writable allow-list); `update` re-checks field policy.
    const is_create = eq(p.action, "create");
    const fields = try plan.changeFields(ctx.arena, p.changes);
    if (is_create) {
        if (!policy.creatableAllowed(ctx.env, p.resource_type)) {
            try ctx.fail("apply", .{
                .kind = .policy_denied,
                .message = "creating this resource type is no longer permitted (default-deny)",
                .next_action = "discard this plan, or re-enable the type in creatable_resources",
            });
            return exit_client;
        }
    } else {
        const eval = try policy.evaluateEnv(ctx.arena, ctx.env, fields);
        if (eval.decision == .deny) {
            try ctx.fail("apply", .{
                .kind = .policy_denied,
                .message = "stored plan violates policy and will not be applied",
                .next_action = "discard this plan",
            });
            return exit_client;
        }
    }

    // NetBox-backed plans need a token; config plans returned earlier do not.
    if (ctx.config.netbox_token == null) return failNoToken(ctx, "apply");

    var client = netbox.Client.init(ctx);
    defer client.deinit();

    const now_ns = ctx.nowNanos();
    const request_id = try ids.genId(ctx.arena, "req", now_ns);

    // create: POST a new object. There is no prior state to snapshot or drift to
    // check; the "backup" records the created id so a restore can DELETE it.
    if (is_create) {
        const body = try std.json.Stringify.valueAlloc(ctx.gpa, p.changes, .{});
        defer ctx.gpa.free(body);
        const post_res = client.create(p.resource_type, body) catch |err| {
            try audit.append(store, .{
                .ts = nsToSecs(ctx.nowNanos()),
                .request_id = request_id,
                .event = "apply_failed",
                .plan_id = p.plan_id,
                .resource_type = p.resource_type,
                .resource_id = p.resource_id,
                .risk_level = p.risk_level,
                .detail = @errorName(err),
            });
            return failNetboxConn(ctx, "apply", err);
        };
        defer ctx.gpa.free(post_res.body);
        if (!post_res.ok) {
            try audit.append(store, .{
                .ts = nsToSecs(ctx.nowNanos()),
                .request_id = request_id,
                .event = "apply_failed",
                .plan_id = p.plan_id,
                .resource_type = p.resource_type,
                .resource_id = p.resource_id,
                .risk_level = p.risk_level,
                .detail = "netbox rejected the create",
            });
            return failNetboxStatus(ctx, "apply", post_res);
        }

        const created = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, post_res.body, .{}) catch
            std.json.Value{ .null = {} };
        const created_id = createdObjectId(ctx.arena, created) orelse create_sentinel_id;

        const b: backup.Backup = .{
            .backup_id = try ids.genId(ctx.arena, "bkp", now_ns),
            .plan_id = p.plan_id,
            .resource_type = p.resource_type,
            .resource_id = created_id,
            .snapshot = created,
            .prior_values = .{ .null = {} },
            .created_at = nsToSecs(now_ns),
            .netbox_url = ctx.config.netbox_url,
            .action = "create",
        };
        try backup.save(store, b);

        // Keep the plan's resource_id as the sentinel so it still hashes to its
        // plan_hash; the real id lives in the backup, audit, and this output.
        p.status = plan.status_applied;
        p.backup_id = b.backup_id;
        try plan.save(store, p);

        try audit.append(store, .{
            .ts = nsToSecs(ctx.nowNanos()),
            .request_id = request_id,
            .event = "applied",
            .plan_id = p.plan_id,
            .approval_id = p.approval_id,
            .backup_id = b.backup_id,
            .resource_type = p.resource_type,
            .resource_id = created_id,
            .risk_level = p.risk_level,
            .detail = "create",
        });

        try ctx.ok("apply", .{
            .request_id = request_id,
            .plan_id = p.plan_id,
            .backup_id = b.backup_id,
            .status = p.status,
            .action = "create",
            .resource_id = created_id,
            .resource = created,
            .next_action = "verify in NetBox; to roll back (delete the created object) run `nbxg restore --backup <backup_id>`",
        });
        return exit_ok;
    }

    // 1. snapshot current state for backup + conflict detection
    const get_res = client.get(p.resource_type, p.resource_id) catch |err| return failNetboxConn(ctx, "apply", err);
    defer ctx.gpa.free(get_res.body);
    if (!get_res.ok) return failNetboxStatus(ctx, "apply", get_res);

    const snapshot = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, get_res.body, .{}) catch
        std.json.Value{ .null = {} };
    const prior = try backup.priorValues(ctx.arena, snapshot, fields);

    // Drift: the changed fields must match the baseline captured at plan time.
    if (!isNull(p.base_values) and !jsonEqual(ctx.arena, prior, p.base_values)) {
        try ctx.fail("apply", .{
            .kind = .conflict,
            .message = "resource changed since the plan was created (drift detected)",
            .risk_level = p.risk_level,
            .next_action = "re-create the plan against the current state",
        });
        return exit_client;
    }

    const b: backup.Backup = .{
        .backup_id = try ids.genId(ctx.arena, "bkp", now_ns),
        .plan_id = p.plan_id,
        .resource_type = p.resource_type,
        .resource_id = p.resource_id,
        .snapshot = snapshot,
        .prior_values = prior,
        .created_at = nsToSecs(now_ns),
        .netbox_url = ctx.config.netbox_url,
    };
    try backup.save(store, b);

    // 2. apply the change
    const body = try std.json.Stringify.valueAlloc(ctx.gpa, p.changes, .{});
    defer ctx.gpa.free(body);
    const patch_res = client.patch(p.resource_type, p.resource_id, body) catch |err| {
        try audit.append(store, .{
            .ts = nsToSecs(ctx.nowNanos()),
            .request_id = request_id,
            .event = "apply_failed",
            .plan_id = p.plan_id,
            .backup_id = b.backup_id,
            .resource_type = p.resource_type,
            .resource_id = p.resource_id,
            .risk_level = p.risk_level,
            .detail = @errorName(err),
        });
        return failNetboxConn(ctx, "apply", err);
    };
    defer ctx.gpa.free(patch_res.body);

    if (!patch_res.ok) {
        try audit.append(store, .{
            .ts = nsToSecs(ctx.nowNanos()),
            .request_id = request_id,
            .event = "apply_failed",
            .plan_id = p.plan_id,
            .backup_id = b.backup_id,
            .resource_type = p.resource_type,
            .resource_id = p.resource_id,
            .risk_level = p.risk_level,
            .detail = "netbox rejected the change",
        });
        return failNetboxStatus(ctx, "apply", patch_res);
    }

    const applied = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, patch_res.body, .{}) catch
        std.json.Value{ .null = {} };

    // 3. record success
    p.status = plan.status_applied;
    p.backup_id = b.backup_id;
    try plan.save(store, p);

    try audit.append(store, .{
        .ts = nsToSecs(ctx.nowNanos()),
        .request_id = request_id,
        .event = "applied",
        .plan_id = p.plan_id,
        .approval_id = p.approval_id,
        .backup_id = b.backup_id,
        .resource_type = p.resource_type,
        .resource_id = p.resource_id,
        .risk_level = p.risk_level,
    });

    try ctx.ok("apply", .{
        .request_id = request_id,
        .plan_id = p.plan_id,
        .backup_id = b.backup_id,
        .status = p.status,
        .diff = .{ .before = prior, .after = p.changes },
        .resource = applied,
        .next_action = "verify in NetBox; to revert run `nbxg restore --backup <backup_id>`",
    });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// restore
// ---------------------------------------------------------------------------

fn cmdRestore(ctx: *Context, rest: []const [:0]const u8) !u8 {
    const backup_id = findFlag(rest, "--backup") orelse return failMissingFlag(ctx, "restore", "--backup");
    if (ctx.config.netbox_token == null) return failNoToken(ctx, "restore");

    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const loaded = (try backup.load(store, backup_id)) orelse {
        try ctx.fail("restore", .{
            .kind = .backup_not_found,
            .message = "no such backup",
            .next_action = "run `nbxg list backups`",
        });
        return exit_client;
    };
    defer loaded.deinit();
    const b = loaded.value;

    var client = netbox.Client.init(ctx);
    defer client.deinit();

    // Roll back a create by DELETING the object it produced (it did not exist
    // before, so its rollback is removal). Update backups restore via PATCH.
    if (eq(b.action, "create")) {
        const del_res = client.delete(b.resource_type, b.resource_id) catch |err| return failNetboxConn(ctx, "restore", err);
        defer ctx.gpa.free(del_res.body);
        // 404 means the object is already gone — treat the rollback as satisfied.
        if (!del_res.ok and del_res.status != 404) return failNetboxStatus(ctx, "restore", del_res);

        const now_ns = ctx.nowNanos();
        const request_id = try ids.genId(ctx.arena, "req", now_ns);
        try audit.append(store, .{
            .ts = nsToSecs(now_ns),
            .request_id = request_id,
            .event = "restored",
            .plan_id = b.plan_id,
            .backup_id = b.backup_id,
            .resource_type = b.resource_type,
            .resource_id = b.resource_id,
            .detail = "delete (rollback of create)",
        });

        try ctx.ok("restore", .{
            .request_id = request_id,
            .backup_id = b.backup_id,
            .action = "delete",
            .resource_type = b.resource_type,
            .resource_id = b.resource_id,
            .deleted = true,
            .next_action = "verify in NetBox: the created object has been removed",
        });
        return exit_ok;
    }

    const write_values = try backup.toWriteForm(ctx.arena, b.prior_values);
    const body = try std.json.Stringify.valueAlloc(ctx.gpa, write_values, .{});
    defer ctx.gpa.free(body);

    const res = client.patch(b.resource_type, b.resource_id, body) catch |err| return failNetboxConn(ctx, "restore", err);
    defer ctx.gpa.free(res.body);
    if (!res.ok) return failNetboxStatus(ctx, "restore", res);

    const now_ns = ctx.nowNanos();
    const request_id = try ids.genId(ctx.arena, "req", now_ns);
    try audit.append(store, .{
        .ts = nsToSecs(now_ns),
        .request_id = request_id,
        .event = "restored",
        .plan_id = b.plan_id,
        .backup_id = b.backup_id,
        .resource_type = b.resource_type,
        .resource_id = b.resource_id,
    });

    const restored = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, res.body, .{}) catch
        std.json.Value{ .null = {} };

    try ctx.ok("restore", .{
        .request_id = request_id,
        .backup_id = b.backup_id,
        .restored_values = write_values,
        .resource = restored,
        .next_action = "verify in NetBox",
    });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// audit
// ---------------------------------------------------------------------------

fn cmdAudit(ctx: *Context, rest: []const [:0]const u8) !u8 {
    const plan_filter = findFlag(rest, "--plan");
    const store = Store.init(ctx);
    try store.ensureDirs();

    const all = try audit.readAll(store, ctx.arena);
    var list: std.ArrayList(audit.Entry) = .empty;
    for (all) |e| {
        if (plan_filter) |pf| {
            const pid = e.plan_id orelse continue;
            if (!eq(pid, pf)) continue;
        }
        try list.append(ctx.arena, e);
    }

    try ctx.ok("audit", .{ .count = list.items.len, .entries = list.items });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

fn cmdList(ctx: *Context, rest: []const [:0]const u8) !u8 {
    if (rest.len < 1) {
        try ctx.fail("list", .{
            .kind = .invalid_args,
            .message = "expected one of: plans | approvals | backups",
            .next_action = "example: nbxg list plans",
        });
        return exit_client;
    }
    const kind = rest[0];
    if (!eq(kind, "plans") and !eq(kind, "approvals") and !eq(kind, "backups")) {
        try ctx.fail("list", .{
            .kind = .invalid_args,
            .message = "kind must be plans, approvals, or backups",
            .next_action = "example: nbxg list plans",
        });
        return exit_client;
    }

    const store = Store.init(ctx);
    try store.ensureDirs();

    var items: std.ArrayList(std.json.Value) = .empty;
    const dir_rel = try store.path(&.{kind});
    var d = std.Io.Dir.cwd().openDir(ctx.io, dir_rel, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.ok("list", .{ .kind = kind, .count = @as(usize, 0), .items = items.items });
            return exit_ok;
        },
        else => return err,
    };
    defer d.close(ctx.io);

    var it = d.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const rel = try store.path(&.{ kind, entry.name });
        const bytes = (try store.readAlloc(rel)) orelse continue;
        defer ctx.gpa.free(bytes);
        const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, bytes, .{}) catch continue;
        try items.append(ctx.arena, v);
    }

    try ctx.ok("list", .{ .kind = kind, .count = items.items.len, .items = items.items });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// list-resources / search (read-only NetBox discovery)
// ---------------------------------------------------------------------------

/// Discover NetBox resources before id-based operations. Default output is the
/// NetBox `brief` representation (id/display/url + a couple of identifying
/// fields) so the read surface stays minimal and low-risk; `--all-fields`
/// returns full objects. `search` additionally accepts `-q/--name <text>`
/// (NetBox fuzzy search) and repeatable `--filter key=value`.
fn cmdListResources(ctx: *Context, rest: []const [:0]const u8, is_search: bool) !u8 {
    const command = if (is_search) "search" else "list-resources";

    var rtype: ?[]const u8 = null;
    var limit: u32 = 50;
    var offset: u32 = 0;
    var all_fields = false;
    var query_text: ?[]const u8 = null;
    var filters: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "--all-fields")) {
            all_fields = true;
        } else if (eq(a, "--limit")) {
            if (i + 1 < rest.len) {
                i += 1;
                limit = parseU32(rest[i]) orelse return failIntFlag(ctx, command, "--limit");
            }
        } else if (std.mem.startsWith(u8, a, "--limit=")) {
            limit = parseU32(a["--limit=".len..]) orelse return failIntFlag(ctx, command, "--limit");
        } else if (eq(a, "--offset")) {
            if (i + 1 < rest.len) {
                i += 1;
                offset = parseU32(rest[i]) orelse return failIntFlag(ctx, command, "--offset");
            }
        } else if (std.mem.startsWith(u8, a, "--offset=")) {
            offset = parseU32(a["--offset=".len..]) orelse return failIntFlag(ctx, command, "--offset");
        } else if (is_search and (eq(a, "-q") or eq(a, "--query") or eq(a, "--name"))) {
            if (i + 1 < rest.len) {
                i += 1;
                query_text = rest[i];
            }
        } else if (is_search and std.mem.startsWith(u8, a, "--query=")) {
            query_text = a["--query=".len..];
        } else if (is_search and std.mem.startsWith(u8, a, "--name=")) {
            query_text = a["--name=".len..];
        } else if (is_search and eq(a, "--filter")) {
            if (i + 1 < rest.len) {
                i += 1;
                try filters.append(ctx.arena, rest[i]);
            }
        } else if (is_search and std.mem.startsWith(u8, a, "--filter=")) {
            try filters.append(ctx.arena, a["--filter=".len..]);
        } else if (!std.mem.startsWith(u8, a, "-") and rtype == null) {
            rtype = a;
        }
    }

    const rt = rtype orelse {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "expected <type>",
            .next_action = if (is_search) "example: nbxg search device -q edge" else "example: nbxg list-resources device --limit 50",
        });
        return exit_client;
    };

    const ep = netbox.endpointFor(ctx.env, rt) orelse return failUnknownType(ctx, command, rt);
    if (ctx.config.netbox_token == null) return failNoToken(ctx, command);

    if (limit == 0) limit = 50;
    if (limit > 1000) limit = 1000;

    var qs: std.ArrayList(u8) = .empty;
    try appendU32Param(ctx.arena, &qs, "limit", limit);
    try appendU32Param(ctx.arena, &qs, "offset", offset);
    if (!all_fields) try appendParam(ctx.arena, &qs, "brief", "true");
    if (query_text) |q| try appendParam(ctx.arena, &qs, "q", q);
    for (filters.items) |f| {
        const eqi = std.mem.indexOfScalar(u8, f, '=') orelse continue;
        try appendParam(ctx.arena, &qs, f[0..eqi], f[eqi + 1 ..]);
    }

    var client = netbox.Client.init(ctx);
    defer client.deinit();
    const res = client.list(rt, qs.items) catch |err| return failNetboxConn(ctx, command, err);
    defer ctx.gpa.free(res.body);
    if (!res.ok) return failNetboxStatus(ctx, command, res);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, res.body, .{}) catch
        std.json.Value{ .null = {} };
    var total: i64 = 0;
    var results: []const std.json.Value = &.{};
    switch (parsed) {
        .object => |o| {
            if (o.get("count")) |c| switch (c) {
                .integer => |n| total = n,
                else => {},
            };
            if (o.get("results")) |r| switch (r) {
                .array => |arr| results = arr.items,
                else => {},
            };
        },
        else => {},
    }

    const returned: i64 = @intCast(results.len);
    const has_more = (@as(i64, @intCast(offset)) + returned) < total;

    try ctx.ok(command, .{
        .resource_type = rt,
        .netbox_endpoint = ep,
        .query = .{
            .text = query_text,
            .filters = filters.items,
            .limit = limit,
            .offset = offset,
            .brief = !all_fields,
        },
        .count = total,
        .returned = returned,
        .has_more = has_more,
        .results = results,
        .note = if (all_fields)
            "full-attribute listing (wider read surface); omit --all-fields for a minimal, low-risk view"
        else
            "brief listing: identifying fields only (id/display/url). Use --all-fields for full attributes, or get/inspect <type> <id> for one object.",
        .next_action = if (has_more)
            "more results exist; re-run with a larger --offset to page through them"
        else
            "use get / inspect / plan <type> <id> on a chosen id",
    });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// resolve (human-readable identifier -> object id, with ambiguity handling)
// ---------------------------------------------------------------------------

/// Map a human-readable identifier (name / slug / address / display / any
/// NetBox field) to the object id that follow-up commands (get/inspect/plan)
/// require. This is a deterministic, identity-only read: it requests NetBox's
/// `brief` representation (id/url/display + identifying fields, never the
/// sensitive read-policy fields), so it needs no read approval.
///
/// Outcomes are made unambiguous on purpose:
///   - exactly one match  -> ok, `resolved` carries the id.
///   - several matches     -> NOT ok (kind=ambiguous) WITH a `candidates`
///                            list. The non-ok status stops naive `&&` chains;
///                            the caller must pick an id, the CLI never does.
///   - no match            -> NOT ok (kind=not_found).
fn cmdResolve(ctx: *Context, rest: []const [:0]const u8) !u8 {
    const command = "resolve";

    var rtype: ?[]const u8 = null;
    // Selectors are NetBox exact-match filters ("field=value"); kept both as a
    // display list and folded into the query string below.
    var selectors: std.ArrayList([]const u8) = .empty;

    const Named = struct { flag: []const u8, field: []const u8 };
    const named = [_]Named{
        .{ .flag = "--name", .field = "name" },
        .{ .flag = "--slug", .field = "slug" },
        .{ .flag = "--address", .field = "address" },
        .{ .flag = "--display", .field = "display" },
    };

    var i: usize = 0;
    arg: while (i < rest.len) : (i += 1) {
        const a = rest[i];
        // Convenience flags for the common identity fields.
        for (named) |n| {
            if (eq(a, n.flag)) {
                if (i + 1 < rest.len) {
                    i += 1;
                    try selectors.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}={s}", .{ n.field, rest[i] }));
                }
                continue :arg;
            }
            if (std.mem.startsWith(u8, a, n.flag) and a.len > n.flag.len and a[n.flag.len] == '=') {
                try selectors.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}={s}", .{ n.field, a[n.flag.len + 1 ..] }));
                continue :arg;
            }
        }
        if (eq(a, "--field") or eq(a, "--filter")) {
            if (i + 1 < rest.len) {
                i += 1;
                if (std.mem.indexOfScalar(u8, rest[i], '=') == null) return failResolveSelector(ctx, rest[i]);
                try selectors.append(ctx.arena, rest[i]);
            }
            continue :arg;
        }
        if (std.mem.startsWith(u8, a, "--filter=")) {
            const kv = a["--filter=".len..];
            if (std.mem.indexOfScalar(u8, kv, '=') == null) return failResolveSelector(ctx, kv);
            try selectors.append(ctx.arena, kv);
            continue :arg;
        }
        // Generic positional `key=value` selector (covers resource-specific
        // identity fields like serial / asset_tag / mac_address / vid / rd).
        if (!std.mem.startsWith(u8, a, "-") and std.mem.indexOfScalar(u8, a, '=') != null) {
            try selectors.append(ctx.arena, a);
            continue :arg;
        }
        if (!std.mem.startsWith(u8, a, "-") and rtype == null) {
            rtype = a;
            continue :arg;
        }
        // Anything else (an unknown flag, or a bare positional that is neither
        // the type nor a key=value) is rejected rather than silently ignored.
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = try std.fmt.allocPrint(ctx.arena, "unrecognized argument: {s}", .{a}),
            .next_action = "use a selector flag (--name/--slug/--address/--display) or a key=value pair",
        });
        return exit_client;
    }

    const rt = rtype orelse {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "expected <type>",
            .next_action = "example: nbxg resolve device --name edge-router",
        });
        return exit_client;
    };

    if (selectors.items.len == 0) {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "expected at least one selector",
            .next_action = "example: nbxg resolve site --slug tokyo  (or device serial=ABC123)",
        });
        return exit_client;
    }

    const ep = netbox.endpointFor(ctx.env, rt) orelse return failUnknownType(ctx, command, rt);
    if (ctx.config.netbox_token == null) return failNoToken(ctx, command);

    // Identity lookup: a brief listing capped low enough to surface ambiguity
    // but never to become a bulk read. `count` (below) still reflects the true
    // total match count regardless of this cap.
    const cap: u32 = 50;
    var qs: std.ArrayList(u8) = .empty;
    try appendU32Param(ctx.arena, &qs, "limit", cap);
    try appendParam(ctx.arena, &qs, "brief", "true");
    for (selectors.items) |s| {
        const eqi = std.mem.indexOfScalar(u8, s, '=') orelse continue;
        try appendParam(ctx.arena, &qs, s[0..eqi], s[eqi + 1 ..]);
    }

    var client = netbox.Client.init(ctx);
    defer client.deinit();
    const res = client.list(rt, qs.items) catch |err| return failNetboxConn(ctx, command, err);
    defer ctx.gpa.free(res.body);
    if (!res.ok) return failNetboxStatus(ctx, command, res);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, res.body, .{}) catch
        std.json.Value{ .null = {} };
    var total: i64 = 0;
    var results: []const std.json.Value = &.{};
    switch (parsed) {
        .object => |o| {
            if (o.get("count")) |c| switch (c) {
                .integer => |n| total = n,
                else => {},
            };
            if (o.get("results")) |r| switch (r) {
                .array => |arr| results = arr.items,
                else => {},
            };
        },
        else => {},
    }

    const query = .{
        .resource_type = rt,
        .netbox_endpoint = ep,
        .selectors = selectors.items,
    };

    // No match: a clean, deterministic "nothing to operate on".
    if (total == 0 or results.len == 0) {
        // When branch routing is off, an empty read may simply mean the object
        // lives in a NetBox branch (the query hit `main`). Point the agent at
        // the branch env vars so it can widen the lookup deliberately.
        const next_action = if (ctx.config.branching)
            "broaden with `nbxg search <type> -q <text>`, or re-check the value"
        else
            "broaden with `nbxg search <type> -q <text>`, or re-check the value; if the object may live in a NetBox branch, set NBX_GUARD_BRANCHING=1 and NBX_GUARD_BRANCH=<schema_id> and retry";
        try ctx.fail(command, .{
            .kind = .not_found,
            .message = try std.fmt.allocPrint(ctx.arena, "no {s} matches the given selector(s)", .{rt}),
            .next_action = next_action,
        });
        return exit_client;
    }

    // Several matches: hand back the candidate list and refuse to choose.
    if (total > 1) {
        try ctx.failData(command, .{
            .kind = .ambiguous,
            .message = try std.fmt.allocPrint(ctx.arena, "{d} {s} objects match the given selector(s)", .{ total, rt }),
            .next_action = "choose one id from candidates and pass it explicitly; the CLI will not pick for you",
        }, .{
            .resource_type = rt,
            .netbox_endpoint = ep,
            .query = query,
            .status = "ambiguous",
            .match_count = total,
            .returned = @as(i64, @intCast(results.len)),
            .truncated = total > @as(i64, @intCast(results.len)),
            .candidates = results,
        });
        return exit_client;
    }

    // Exactly one match: resolve it.
    const obj = results[0];
    var id_val: ?i64 = null;
    var display_val: ?[]const u8 = null;
    var url_val: ?[]const u8 = null;
    switch (obj) {
        .object => |o| {
            if (o.get("id")) |v| switch (v) {
                .integer => |n| id_val = n,
                else => {},
            };
            if (o.get("display")) |v| switch (v) {
                .string => |s| display_val = s,
                else => {},
            };
            if (o.get("url")) |v| switch (v) {
                .string => |s| url_val = s,
                else => {},
            };
        },
        else => {},
    }

    try ctx.ok(command, .{
        .resource_type = rt,
        .netbox_endpoint = ep,
        .query = query,
        .status = "resolved",
        .match_count = total,
        .resolved = .{
            .id = id_val,
            .display = display_val,
            .url = url_val,
        },
        .candidate = obj,
        .next_action = "use the id with get / inspect / plan <type> <id>",
    });
    return exit_ok;
}

fn failResolveSelector(ctx: *Context, got: []const u8) !u8 {
    try ctx.fail("resolve", .{
        .kind = .invalid_args,
        .message = try std.fmt.allocPrint(ctx.arena, "selector must be key=value, got: {s}", .{got}),
        .next_action = "example: nbxg resolve device --filter serial=ABC123",
    });
    return exit_client;
}

/// Provenance metadata embedded in every export/snapshot artifact so it stays
/// useful for later review, offline approval, and post-change comparison. The
/// NetBox instance is identified by a short URL hash plus a host label rather
/// than the full URL (which can carry credentials/ports), and the token is
/// never recorded.
const ExportMeta = struct {
    tool: []const u8 = "nbxg",
    nbxg_version: []const u8 = version,
    /// "export" (collection) or "snapshot" (single object).
    kind: []const u8,
    resource_type: []const u8,
    netbox_endpoint: []const u8,
    /// Single-object id (snapshot only).
    resource_id: ?[]const u8 = null,
    /// Read-surface tier: "basic" (minimal/brief) or "full".
    field_profile: []const u8,
    /// Read-sensitive fields whose values were redacted in this artifact (empty
    /// when nothing was redacted, e.g. a snapshot disclosed under a read plan).
    redacted_fields: []const []const u8 = &.{},
    /// Output encoding for the `--out` file (export only).
    format: ?[]const u8 = null,
    /// NetBox fuzzy `q` text, when given (export only).
    query: ?[]const u8 = null,
    /// Raw `key=value` filters passed through to NetBox (export only).
    filters: []const []const u8 = &.{},
    /// Caller-requested record cap, or null when exporting all matches.
    limit: ?u32 = null,
    offset: u32 = 0,
    /// Number of objects captured.
    count: ?usize = null,
    /// Wall-clock seconds when the artifact was produced.
    generated_at: i64,
    /// First 16 hex chars of SHA-256(NETBOX_URL): a stable instance fingerprint.
    netbox_url_hash: []const u8,
    /// Human-readable host[:port] label for the NetBox instance.
    netbox_instance: []const u8,
    /// Active NetBox Branching schema id, when branch routing is enabled.
    branch: ?[]const u8 = null,
};

/// Derive a human-readable `host[:port]` label from a NetBox base URL.
fn instanceLabel(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfScalar(u8, s, '/')) |j| s = s[0..j];
    return s;
}

/// First 16 hex chars of SHA-256(url): a short, stable instance fingerprint
/// that identifies which NetBox an artifact came from without leaking the URL.
fn urlHash16(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const full = try ids.sha256Hex(arena, url);
    return full[0..16];
}

/// Write `data` to an arbitrary `--out` path, creating parent directories as
/// needed. Unlike `Store`, exports may target any path the operator chooses.
fn writeOutFile(ctx: *Context, out_path: []const u8, data: []const u8) !void {
    const io = ctx.io;
    const d = std.Io.Dir.cwd();
    if (std.fs.path.dirname(out_path)) |parent| {
        if (parent.len > 0) try d.createDirPath(io, parent);
    }
    var file = try d.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

/// Encode an export as JSONL: a leading `{"_meta": ...}` provenance line so the
/// artifact is self-describing, then one minified object per line.
fn renderJsonl(ctx: *Context, meta: ExportMeta, records: []const std.json.Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(ctx.gpa);
    const meta_line = try std.json.Stringify.valueAlloc(ctx.gpa, .{ ._meta = meta }, .{});
    defer ctx.gpa.free(meta_line);
    try buf.appendSlice(ctx.gpa, meta_line);
    try buf.append(ctx.gpa, '\n');
    for (records) |rec| {
        const line = try std.json.Stringify.valueAlloc(ctx.gpa, rec, .{});
        defer ctx.gpa.free(line);
        try buf.appendSlice(ctx.gpa, line);
        try buf.append(ctx.gpa, '\n');
    }
    return buf.toOwnedSlice(ctx.gpa);
}

/// `export <type>`: read-only, filtered, auto-paginated capture of every
/// matching NetBox object, with provenance metadata for later review. The read
/// surface is tiered via `--fields basic|full` (basic uses NetBox `brief`).
fn cmdExport(ctx: *Context, rest: []const [:0]const u8) !u8 {
    const command = "export";

    var rtype: ?[]const u8 = null;
    var filters: std.ArrayList([]const u8) = .empty;
    var query_text: ?[]const u8 = null;
    var field_profile: []const u8 = "basic";
    var format: []const u8 = "json";
    var out_path: ?[]const u8 = null;
    var limit: ?u32 = null;
    var offset: u32 = 0;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "--filter")) {
            if (i + 1 < rest.len) {
                i += 1;
                try filters.append(ctx.arena, rest[i]);
            }
        } else if (std.mem.startsWith(u8, a, "--filter=")) {
            try filters.append(ctx.arena, a["--filter=".len..]);
        } else if (eq(a, "-q") or eq(a, "--query") or eq(a, "--name")) {
            if (i + 1 < rest.len) {
                i += 1;
                query_text = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--query=")) {
            query_text = a["--query=".len..];
        } else if (std.mem.startsWith(u8, a, "--name=")) {
            query_text = a["--name=".len..];
        } else if (eq(a, "--fields")) {
            if (i + 1 < rest.len) {
                i += 1;
                field_profile = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--fields=")) {
            field_profile = a["--fields=".len..];
        } else if (eq(a, "--all-fields")) {
            field_profile = "full";
        } else if (eq(a, "--format")) {
            if (i + 1 < rest.len) {
                i += 1;
                format = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--format=")) {
            format = a["--format=".len..];
        } else if (eq(a, "--out")) {
            if (i + 1 < rest.len) {
                i += 1;
                out_path = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            out_path = a["--out=".len..];
        } else if (eq(a, "--limit")) {
            if (i + 1 < rest.len) {
                i += 1;
                limit = parseU32(rest[i]) orelse return failIntFlag(ctx, command, "--limit");
            }
        } else if (std.mem.startsWith(u8, a, "--limit=")) {
            limit = parseU32(a["--limit=".len..]) orelse return failIntFlag(ctx, command, "--limit");
        } else if (eq(a, "--offset")) {
            if (i + 1 < rest.len) {
                i += 1;
                offset = parseU32(rest[i]) orelse return failIntFlag(ctx, command, "--offset");
            }
        } else if (std.mem.startsWith(u8, a, "--offset=")) {
            offset = parseU32(a["--offset=".len..]) orelse return failIntFlag(ctx, command, "--offset");
        } else if (!std.mem.startsWith(u8, a, "-") and rtype == null) {
            rtype = a;
        }
    }

    const rt = rtype orelse {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "expected <type>",
            .next_action = "example: nbxg export device --filter site=tokyo --format json",
        });
        return exit_client;
    };

    // Read-surface tier: basic == NetBox brief (minimal, low-risk); full == all
    // attributes. Default-deny on anything else so a typo can't widen the read.
    const basic = eq(field_profile, "basic") or eq(field_profile, "brief");
    const full = eq(field_profile, "full") or eq(field_profile, "all");
    if (!basic and !full) {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "fields profile must be 'basic' or 'full'",
            .next_action = "use --fields basic (minimal read surface) or --fields full",
        });
        return exit_client;
    }
    field_profile = if (basic) "basic" else "full";

    const fmt_jsonl = eq(format, "jsonl");
    if (!eq(format, "json") and !fmt_jsonl) {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "format must be 'json' or 'jsonl'",
            .next_action = "use --format json or --format jsonl",
        });
        return exit_client;
    }

    const ep = netbox.endpointFor(ctx.env, rt) orelse return failUnknownType(ctx, command, rt);
    if (ctx.config.netbox_token == null) return failNoToken(ctx, command);

    // Auto-paginate the collection so the export captures every matching object,
    // not just one page. Bounded by --limit, or a hard cap when exporting all.
    const page_size: u32 = 1000;
    const hard_cap: usize = 100_000;
    const max_records: usize = if (limit) |l| l else hard_cap;

    var client = netbox.Client.init(ctx);
    defer client.deinit();

    var records: std.ArrayList(std.json.Value) = .empty;
    var total: i64 = 0;
    var cur_offset: u32 = offset;

    while (records.items.len < max_records) {
        const remaining = max_records - records.items.len;
        var this_limit: u32 = page_size;
        if (remaining < page_size) this_limit = @intCast(remaining);
        if (this_limit == 0) break;

        var qs: std.ArrayList(u8) = .empty;
        try appendU32Param(ctx.arena, &qs, "limit", this_limit);
        try appendU32Param(ctx.arena, &qs, "offset", cur_offset);
        if (basic) try appendParam(ctx.arena, &qs, "brief", "true");
        if (query_text) |q| try appendParam(ctx.arena, &qs, "q", q);
        for (filters.items) |f| {
            const eqi = std.mem.indexOfScalar(u8, f, '=') orelse continue;
            try appendParam(ctx.arena, &qs, f[0..eqi], f[eqi + 1 ..]);
        }

        const res = client.list(rt, qs.items) catch |err| return failNetboxConn(ctx, command, err);
        defer ctx.gpa.free(res.body);
        if (!res.ok) return failNetboxStatus(ctx, command, res);

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, res.body, .{}) catch
            std.json.Value{ .null = {} };
        var page: []const std.json.Value = &.{};
        switch (parsed) {
            .object => |o| {
                if (o.get("count")) |c| switch (c) {
                    .integer => |n| total = n,
                    else => {},
                };
                if (o.get("results")) |r| switch (r) {
                    .array => |arr| page = arr.items,
                    else => {},
                };
            },
            else => {},
        }
        if (page.len == 0) break;
        for (page) |rec| {
            if (records.items.len >= max_records) break;
            try records.append(ctx.arena, rec);
        }
        cur_offset += @intCast(page.len);
        if (@as(i64, @intCast(cur_offset)) >= total) break;
    }

    // Bulk export never discloses raw read-sensitive values: a collection has no
    // per-object read-approval binding. In the `full` tier we redact every
    // record's sensitive fields (the `basic` tier uses NetBox `brief`, which
    // already omits them). To read raw sensitive values, use single-object
    // `get`/`snapshot` with an approved read plan.
    var out_records: []const std.json.Value = records.items;
    var redacted_fields: []const []const u8 = &.{};
    if (full) {
        var redacted: std.ArrayList(std.json.Value) = .empty;
        var seen: std.ArrayList([]const u8) = .empty;
        for (records.items) |rec| {
            for (try policy.sensitiveFieldsPresent(ctx.arena, ctx.env, rec)) |name| {
                var found = false;
                for (seen.items) |x| {
                    if (eq(x, name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) try seen.append(ctx.arena, name);
            }
            try redacted.append(ctx.arena, try policy.redactSensitive(ctx.arena, ctx.env, rec));
        }
        out_records = redacted.items;
        redacted_fields = seen.items;
    }

    const meta = ExportMeta{
        .kind = "export",
        .resource_type = rt,
        .netbox_endpoint = ep,
        .field_profile = field_profile,
        .redacted_fields = redacted_fields,
        .format = format,
        .query = query_text,
        .filters = filters.items,
        .limit = limit,
        .offset = offset,
        .count = records.items.len,
        .generated_at = nsToSecs(ctx.nowNanos()),
        .netbox_url_hash = try urlHash16(ctx.arena, ctx.config.netbox_url),
        .netbox_instance = instanceLabel(ctx.config.netbox_url),
        .branch = netbox.activeBranch(ctx.config),
    };

    if (out_path) |op| {
        const bytes = if (fmt_jsonl)
            try renderJsonl(ctx, meta, out_records)
        else
            try std.json.Stringify.valueAlloc(ctx.gpa, .{ .metadata = meta, .records = out_records }, .{ .whitespace = .indent_2 });
        defer ctx.gpa.free(bytes);
        writeOutFile(ctx, op, bytes) catch |err| return failOutWrite(ctx, command, op, err);
        try ctx.ok(command, .{
            .metadata = meta,
            .out = op,
            .bytes = bytes.len,
            .note = if (basic)
                "basic field profile: minimal, low-risk read surface. Use --fields full for complete attributes."
            else
                "full field profile: complete attributes; read-sensitive field values are redacted (bulk export never discloses raw sensitive values — use `nbxg get`/`snapshot` with a read approval).",
            .next_action = "review or archive the export; re-run later and diff to detect drift",
        });
    } else {
        try ctx.ok(command, .{
            .metadata = meta,
            .records = out_records,
            .note = if (basic)
                "no --out given: records embedded in this response. Pass --out <path> with --format json|jsonl to persist."
            else
                "no --out given: records embedded (read-sensitive values redacted in the full tier). Pass --out <path> with --format json|jsonl to persist.",
            .next_action = "pass --out <path> to persist this export for offline review",
        });
    }
    return exit_ok;
}

/// `snapshot <type> <id>`: read-only point-in-time capture of one object with
/// provenance metadata, for pre-change review and post-change comparison. The
/// read surface is gated exactly like `get`: `--fields basic` (default) redacts
/// read-sensitive fields; `--fields all` requires an approved read plan
/// (`--plan-read` then `approve-read` then `--plan <id>`) to disclose them.
fn cmdSnapshot(ctx: *Context, rest: []const [:0]const u8) !u8 {
    const command = "snapshot";

    var rtype: ?[]const u8 = null;
    var rid: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var profile: []const u8 = "basic";
    var plan_read = false;
    var read_plan_id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "--out")) {
            if (i + 1 < rest.len) {
                i += 1;
                out_path = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            out_path = a["--out=".len..];
        } else if (eq(a, "--fields")) {
            if (i + 1 < rest.len) {
                i += 1;
                profile = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--fields=")) {
            profile = a["--fields=".len..];
        } else if (eq(a, "--all-fields")) {
            profile = "all";
        } else if (eq(a, "--redact")) {
            profile = "basic";
        } else if (eq(a, "--plan-read")) {
            plan_read = true;
        } else if (eq(a, "--plan")) {
            if (i + 1 < rest.len) {
                i += 1;
                read_plan_id = rest[i];
            }
        } else if (std.mem.startsWith(u8, a, "--plan=")) {
            read_plan_id = a["--plan=".len..];
        } else if (!std.mem.startsWith(u8, a, "-")) {
            if (rtype == null) {
                rtype = a;
            } else if (rid == null) {
                rid = a;
            }
        }
    }

    const rt = rtype orelse return failSnapshotUsage(ctx);
    const id = rid orelse return failSnapshotUsage(ctx);

    // Read field-scope tier (default-deny on a typo so it can never widen the
    // read): "basic" redacts read-sensitive fields; "all" requests the full
    // object and is gated behind a read approval when sensitive fields are present.
    const basic = eq(profile, "basic") or eq(profile, "brief");
    const all = eq(profile, "all") or eq(profile, "full");
    if (!basic and !all) {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "fields tier must be 'basic' or 'all'",
            .next_action = "use --fields basic (minimal, redacted read) or --fields all (requires read approval for sensitive fields)",
        });
        return exit_client;
    }

    const ep = netbox.endpointFor(ctx.env, rt) orelse return failUnknownType(ctx, command, rt);
    if (ctx.config.netbox_token == null) return failNoToken(ctx, command);

    var client = netbox.Client.init(ctx);
    defer client.deinit();
    const res = client.get(rt, id) catch |err| return failNetboxConn(ctx, command, err);
    defer ctx.gpa.free(res.body);
    if (!res.ok) return failNetboxStatus(ctx, command, res);

    const resource = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, res.body, .{}) catch
        std.json.Value{ .null = {} };

    const sensitive = try policy.sensitiveFieldsPresent(ctx.arena, ctx.env, resource);

    // Same read-sensitive gate as `get --fields all`: basic redacts; full
    // requires an approved read plan when sensitive fields are present. The read
    // tier uses get's vocabulary ("basic"/"all") for cross-command consistency.
    var emit_resource = resource;
    var emit_profile: []const u8 = "all";
    var redacted_fields: []const []const u8 = &.{};
    var disclosed_fields: []const []const u8 = &.{};
    var used_plan: ?[]const u8 = null;
    var used_approval: ?[]const u8 = null;

    if (basic) {
        emit_resource = try policy.redactSensitive(ctx.arena, ctx.env, resource);
        emit_profile = "basic";
        redacted_fields = sensitive;
    } else if (sensitive.len == 0) {
        emit_profile = "all";
    } else if (read_plan_id) |pid| {
        switch (try authorizeApprovedRead(ctx, command, rt, id, pid)) {
            .handled => |code| return code,
            .ok => |info| {
                emit_profile = "all";
                disclosed_fields = sensitive;
                used_plan = info.plan_id;
                used_approval = info.approval_id;
            },
        }
    } else if (plan_read) {
        return createReadPlan(ctx, command, rt, id, resource, sensitive);
    } else {
        try ctx.fail(command, .{
            .kind = .needs_approval,
            .message = "full snapshot of read-sensitive fields requires an approved read plan",
            .risk_level = "high",
            .next_action = "run `nbxg snapshot <type> <id> --fields all --plan-read`, approve with `nbxg approve-read --plan <plan_id>`, then re-run with `--plan <plan_id>`",
        });
        return exit_client;
    }

    const read_policy = .{
        .field_profile = emit_profile,
        .redacted_fields = redacted_fields,
        .disclosed_fields = disclosed_fields,
        .read_plan = used_plan,
        .approval_id = used_approval,
    };

    const meta = ExportMeta{
        .kind = "snapshot",
        .resource_type = rt,
        .netbox_endpoint = ep,
        .resource_id = id,
        .field_profile = emit_profile,
        .redacted_fields = redacted_fields,
        .count = 1,
        .generated_at = nsToSecs(ctx.nowNanos()),
        .netbox_url_hash = try urlHash16(ctx.arena, ctx.config.netbox_url),
        .netbox_instance = instanceLabel(ctx.config.netbox_url),
        .branch = netbox.activeBranch(ctx.config),
    };

    const note: []const u8 = if (basic)
        "basic snapshot: read-sensitive fields redacted. Use --fields all with a read approval to disclose them."
    else if (disclosed_fields.len > 0)
        "full snapshot disclosed under an approved read plan; this disclosure is recorded in the audit log."
    else
        "full snapshot: no read-sensitive fields present on this object.";

    if (out_path) |op| {
        const bytes = try std.json.Stringify.valueAlloc(ctx.gpa, .{ .metadata = meta, .resource = emit_resource }, .{ .whitespace = .indent_2 });
        defer ctx.gpa.free(bytes);
        writeOutFile(ctx, op, bytes) catch |err| return failOutWrite(ctx, command, op, err);
        try ctx.ok(command, .{
            .metadata = meta,
            .read_policy = read_policy,
            .out = op,
            .bytes = bytes.len,
            .note = note,
            .next_action = "review or archive the snapshot; re-run later and diff to detect change",
        });
    } else {
        try ctx.ok(command, .{
            .metadata = meta,
            .read_policy = read_policy,
            .resource = emit_resource,
            .note = note,
            .next_action = "pass --out <path> to persist this snapshot for offline review",
        });
    }
    return exit_ok;
}

fn failSnapshotUsage(ctx: *Context) !u8 {
    try ctx.fail("snapshot", .{
        .kind = .invalid_args,
        .message = "expected <type> <id>",
        .next_action = "example: nbxg snapshot device 123 --out snapshots/device-123.json",
    });
    return exit_client;
}

fn failOutWrite(ctx: *Context, command: []const u8, path: []const u8, err: anyerror) !u8 {
    const msg = std.fmt.allocPrint(ctx.arena, "could not write {s}: {s}", .{ path, @errorName(err) }) catch
        "could not write output file";
    try ctx.fail(command, .{
        .kind = .io_error,
        .message = msg,
        .next_action = "check the --out path is writable and its parent directory is accessible",
    });
    return exit_upstream;
}

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn failIntFlag(ctx: *Context, command: []const u8, flag: []const u8) !u8 {
    const msg = std.fmt.allocPrint(ctx.arena, "{s} expects a non-negative integer", .{flag}) catch
        "flag expects a non-negative integer";
    try ctx.fail(command, .{
        .kind = .invalid_args,
        .message = msg,
        .next_action = "example: nbxg list-resources device --limit 50 --offset 0",
    });
    return exit_client;
}

/// Append `key=value` (both percent-encoded) to a query string, inserting `&`.
fn appendParam(arena: std.mem.Allocator, qs: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    if (qs.items.len > 0) try qs.append(arena, '&');
    try pctEncode(arena, qs, key);
    try qs.append(arena, '=');
    try pctEncode(arena, qs, value);
}

fn appendU32Param(arena: std.mem.Allocator, qs: *std.ArrayList(u8), key: []const u8, value: u32) !void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    try appendParam(arena, qs, key, s);
}

fn pctEncode(arena: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (raw) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try out.append(arena, c);
        } else {
            try out.append(arena, '%');
            try out.append(arena, hex[c >> 4]);
            try out.append(arena, hex[c & 0x0F]);
        }
    }
}

const ExtraResource = struct { key: []const u8, endpoint: []const u8 };

/// Operator-added resource types parsed from `NBX_GUARD_EXTRA_RESOURCES`
/// (skipping any that shadow a built-in type).
fn envExtraResources(ctx: *Context) ![]ExtraResource {
    var list: std.ArrayList(ExtraResource) = .empty;
    const spec = ctx.env.get("NBX_GUARD_EXTRA_RESOURCES") orelse return list.items;
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |pair_raw| {
        const pair = std.mem.trim(u8, pair_raw, " \t");
        const eqi = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = std.mem.trim(u8, pair[0..eqi], " \t");
        const epath = std.mem.trim(u8, pair[eqi + 1 ..], " \t/");
        if (key.len == 0 or epath.len == 0) continue;
        if (netbox.endpoint(key) != null) continue;
        try list.append(ctx.arena, .{ .key = key, .endpoint = epath });
    }
    return list.toOwnedSlice(ctx.arena);
}

/// Parse a comma/space separated env field list into a slice.
fn envFieldList(ctx: *Context, var_name: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const spec = ctx.env.get(var_name) orelse return list.items;
    var it = std.mem.tokenizeAny(u8, spec, ", \t");
    while (it.next()) |tok| try list.append(ctx.arena, tok);
    return list.toOwnedSlice(ctx.arena);
}

/// Build a minimal ResourceDoc for an operator-extended type so `describe` can
/// self-document it. Governed fields = universal low-risk defaults + operator
/// env field lists; the real schema is filled in by the live NetBox sync.
fn syntheticDoc(ctx: *Context, key: []const u8) !?schema.ResourceDoc {
    const ep = netbox.extraEndpoint(ctx.env, key) orelse return null;
    const base_low = [_][]const u8{ "description", "comments", "tags", "custom_fields" };
    const env_low = try envFieldList(ctx, "NBX_GUARD_ALLOWED_FIELDS");
    const env_high = try envFieldList(ctx, "NBX_GUARD_HIGH_RISK_FIELDS");
    var low: std.ArrayList([]const u8) = .empty;
    try low.appendSlice(ctx.arena, &base_low);
    for (env_low) |f| {
        if (inList(&base_low, f)) continue;
        try low.append(ctx.arena, f);
    }
    return schema.ResourceDoc{
        .key = key,
        .netbox_endpoint = ep,
        .display = key,
        .summary = "Operator-extended resource type (NBX_GUARD_EXTRA_RESOURCES); governed by global field policy.",
        .low = try low.toOwnedSlice(ctx.arena),
        .high = env_high,
        .examples = &.{},
    };
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (eq(x, name)) return true;
    return false;
}

fn describeHasField(list: []const DescribeField, name: []const u8) bool {
    for (list) |f| if (eq(f.name, name)) return true;
    return false;
}

/// Fallback field doc for operator-extended fields that have no built-in entry.
fn genericFieldDoc(ctx: *Context, name: []const u8) schema.FieldDoc {
    const ex = std.fmt.allocPrint(ctx.arena, "{s}=<value>", .{name}) catch name;
    return .{
        .name = name,
        .json_type = "string",
        .example = ex,
        .note = "operator-extended; consult the live NetBox schema below for the real type",
    };
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn parseSet(arena: std.mem.Allocator, args: []const [:0]const u8) ![]plan.Change {
    var list: std.ArrayList(plan.Change) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        var pair: ?[]const u8 = null;
        if (eq(a, "--set")) {
            if (i + 1 >= args.len) break;
            i += 1;
            pair = args[i];
        } else if (std.mem.startsWith(u8, a, "--set=")) {
            pair = a["--set=".len..];
        } else if (std.mem.indexOfScalar(u8, a, '=') != null and !std.mem.startsWith(u8, a, "--")) {
            pair = a;
        }
        if (pair) |kv| {
            const eqi = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            try list.append(arena, .{ .key = kv[0..eqi], .value = kv[eqi + 1 ..] });
        }
    }
    return list.toOwnedSlice(arena);
}

fn findFlag(args: []const [:0]const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], name)) {
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }
        const prefix_len = name.len + 1;
        if (args[i].len > prefix_len and std.mem.startsWith(u8, args[i], name) and args[i][name.len] == '=') {
            return args[i][prefix_len..];
        }
    }
    return null;
}

fn nsToSecs(ns: i128) i64 {
    return @intCast(@divTrunc(ns, std.time.ns_per_s));
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isNull(v: std.json.Value) bool {
    return switch (v) {
        .null => true,
        else => false,
    };
}

/// Extract a created object's `id` as a string (NetBox returns it as an integer
/// on POST). Returns null when the body is not an object or has no usable id.
fn createdObjectId(arena: std.mem.Allocator, created: std.json.Value) ?[]const u8 {
    const obj = switch (created) {
        .object => |o| o,
        else => return null,
    };
    const idv = obj.get("id") orelse return null;
    return switch (idv) {
        .integer => |n| std.fmt.allocPrint(arena, "{d}", .{n}) catch null,
        .string => |s| s,
        else => null,
    };
}

/// Structural equality of two JSON values via canonical serialization. Both
/// sides are built field-by-field in the same field order, so a byte compare of
/// the serialized form is sufficient here.
fn jsonEqual(arena: std.mem.Allocator, a: std.json.Value, b: std.json.Value) bool {
    const sa = std.json.Stringify.valueAlloc(arena, a, .{}) catch return false;
    const sb = std.json.Stringify.valueAlloc(arena, b, .{}) catch return false;
    return std.mem.eql(u8, sa, sb);
}

// shared failure responses -------------------------------------------------

fn failUnknownType(ctx: *Context, command: []const u8, rtype: []const u8) !u8 {
    _ = rtype;
    try ctx.fail(command, .{
        .kind = .invalid_args,
        .message = "unknown resource type",
        .next_action = "run `nbxg describe` to list types (device, interface, ip-address, prefix, vlan, contact); to govern another type have an operator run `nbxg config set extra_resources=<type>:<app/endpoint>` (human-approved, audited)",
    });
    return exit_client;
}

fn failNoToken(ctx: *Context, command: []const u8) !u8 {
    try ctx.fail(command, .{
        .kind = .config_error,
        .message = "NETBOX_TOKEN is not set",
        .next_action = "export NETBOX_TOKEN before running this command",
    });
    return exit_upstream;
}

fn failMissingFlag(ctx: *Context, command: []const u8, flag: []const u8) !u8 {
    _ = flag;
    try ctx.fail(command, .{
        .kind = .invalid_args,
        .message = "missing required flag",
        .next_action = "run `nbxg help`",
    });
    return exit_client;
}

fn failPlanNotFound(ctx: *Context, command: []const u8, plan_id: []const u8) !u8 {
    _ = plan_id;
    try ctx.fail(command, .{
        .kind = .plan_not_found,
        .message = "no such plan",
        .next_action = "run `nbxg list plans`",
    });
    return exit_client;
}

fn failNetboxConn(ctx: *Context, command: []const u8, err: anyerror) !u8 {
    try ctx.fail(command, .{
        .kind = .netbox_error,
        .message = @errorName(err),
        .next_action = "check NETBOX_URL/NETBOX_TOKEN and connectivity",
    });
    return exit_upstream;
}

fn failNetboxStatus(ctx: *Context, command: []const u8, res: netbox.Result) !u8 {
    // Surface NetBox's own error `detail` when present so the agent sees *why*
    // (e.g. "Invalid v2 token") instead of a bare status code.
    const detail = netboxDetail(ctx.arena, res.body);
    const msg = if (detail) |d|
        try std.fmt.allocPrint(ctx.arena, "netbox returned HTTP {d}: {s}", .{ res.status, d })
    else
        try std.fmt.allocPrint(ctx.arena, "netbox returned HTTP {d}", .{res.status});

    // NetBox collapses every authentication AND authorization failure into HTTP
    // 403 (its TokenAuthentication never sets a WWW-Authenticate header, so DRF
    // does not emit 401). Only the response body's `detail` disambiguates: an
    // invalid/expired/disabled token reads like "Invalid v2 token" / "Token
    // expired", while a valid token whose user lacks model rights reads "You do
    // not have permission ...". Steer the agent at the credential/permissions
    // rather than the resource.
    if (res.status == 401 or res.status == 403) {
        try ctx.fail(command, .{
            .kind = .netbox_error,
            .message = msg,
            .next_action = "authentication or permission failure: verify NETBOX_TOKEN is the full v2 credential (nbt_<key>.<secret>; the secret is shown only once at creation) and that its NetBox user has the required view/change permission — read message for the NetBox detail",
        });
        return exit_upstream;
    }

    try ctx.fail(command, .{
        .kind = if (res.status == 409) .conflict else .netbox_error,
        .message = msg,
        .next_action = "inspect the resource and adjust the plan",
    });
    return exit_upstream;
}

/// Best-effort extraction of NetBox/DRF's top-level error `detail` string from a
/// JSON error body. NetBox returns `{"detail": "..."}` for authentication and
/// permission failures; field-validation errors are field-keyed (no `detail`),
/// so those safely yield null and the caller falls back to the bare status. Only
/// the `detail` string is read — never arbitrary field values — so no resource
/// data is surfaced.
fn netboxDetail(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    if (body.len == 0) return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const d = obj.get("detail") orelse return null;
    return switch (d) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "instanceLabel extracts host[:port] from a NetBox URL" {
    try std.testing.expectEqualStrings("netbox.example.com", instanceLabel("https://netbox.example.com"));
    try std.testing.expectEqualStrings("127.0.0.1:8000", instanceLabel("http://127.0.0.1:8000"));
    try std.testing.expectEqualStrings("netbox.local:8080", instanceLabel("https://netbox.local:8080/api"));
    // no scheme: still trims any path
    try std.testing.expectEqualStrings("host", instanceLabel("host/x"));
}

test "urlHash16 is a stable 16-hex instance fingerprint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h1 = try urlHash16(a, "https://netbox.example.com");
    try std.testing.expectEqual(@as(usize, 16), h1.len);
    const h2 = try urlHash16(a, "https://netbox.example.com");
    try std.testing.expectEqualStrings(h1, h2);
    // matches the first 16 hex chars of the full SHA-256 of the same URL
    const full = try ids.sha256Hex(a, "https://netbox.example.com");
    try std.testing.expectEqualStrings(full[0..16], h1);
}

test "netboxDetail extracts DRF detail and ignores everything else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The disambiguating case: NetBox 403s carry the reason only in `detail`.
    try std.testing.expectEqualStrings("Invalid v2 token", netboxDetail(a, "{\"detail\":\"Invalid v2 token\"}").?);
    try std.testing.expectEqualStrings(
        "You do not have permission to perform this action.",
        netboxDetail(a, "{\"detail\":\"You do not have permission to perform this action.\"}").?,
    );
    // No `detail` (field-keyed validation error) -> null, so no resource data leaks.
    try std.testing.expect(netboxDetail(a, "{\"serial\":[\"This field may not be blank.\"]}") == null);
    // Defensive: empty body, non-JSON, non-object, empty/non-string detail -> null.
    try std.testing.expect(netboxDetail(a, "") == null);
    try std.testing.expect(netboxDetail(a, "not json") == null);
    try std.testing.expect(netboxDetail(a, "[1,2,3]") == null);
    try std.testing.expect(netboxDetail(a, "{\"detail\":\"\"}") == null);
    try std.testing.expect(netboxDetail(a, "{\"detail\":42}") == null);
}

test "buildConfigValue types values per key kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // boolean
    const bspec = configKeySpec("auto_approve").?;
    try std.testing.expect((try buildConfigValue(a, bspec, "true")).bool);
    try std.testing.expect(!(try buildConfigValue(a, bspec, "off")).bool);
    try std.testing.expectError(error.InvalidConfigValue, buildConfigValue(a, bspec, "maybe"));

    // integer (non-negative)
    const ispec = configKeySpec("http_timeout_ms").?;
    try std.testing.expectEqual(@as(i64, 2500), (try buildConfigValue(a, ispec, "2500")).integer);
    try std.testing.expectError(error.InvalidConfigValue, buildConfigValue(a, ispec, "-1"));

    // list
    const lspec = configKeySpec("creatable_resources").?;
    const lv = try buildConfigValue(a, lspec, "site, vlan");
    try std.testing.expectEqual(@as(usize, 2), lv.array.items.len);
    try std.testing.expectEqualStrings("site", lv.array.items[0].string);

    // object_map (type:endpoint)
    const ospec = configKeySpec("extra_resources").?;
    const ov = try buildConfigValue(a, ospec, "site:dcim/sites,tenant:tenancy/tenants");
    try std.testing.expectEqualStrings("dcim/sites", ov.object.get("site").?.string);
    try std.testing.expectError(error.InvalidConfigValue, buildConfigValue(a, ospec, "noseparator"));

    // forbidden keys never build a value
    try std.testing.expectError(error.InvalidConfigValue, buildConfigValue(a, configKeySpec("netbox_token").?, "x"));

    // unknown key has no spec
    try std.testing.expect(configKeySpec("definitely_not_a_key") == null);
}
