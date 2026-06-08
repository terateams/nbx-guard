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

pub const version = "0.1.1";

// Exit codes: 0 ok, 2 client/policy/state error, 3 upstream/io/config error.
const exit_ok: u8 = 0;
const exit_client: u8 = 2;
const exit_upstream: u8 = 3;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
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
    } else if (eq(cmd, "get")) {
        return cmdGet(ctx, rest, "get");
    } else if (eq(cmd, "inspect")) {
        return cmdGet(ctx, rest, "inspect");
    } else if (eq(cmd, "describe")) {
        return cmdDescribe(ctx, rest);
    } else if (eq(cmd, "plan")) {
        return cmdPlan(ctx, rest);
    } else if (eq(cmd, "approve")) {
        return cmdApprove(ctx, rest);
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
    }

    try ctx.fail(cmd, .{
        .kind = .invalid_args,
        .message = "unknown command",
        .next_action = "run `nbxg help` to list supported commands",
    });
    return exit_client;
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
        principle: []const u8 = "Agent proposes intent; the CLI decides what is allowed.",
    };
    try ctx.ok("version", Info{
        .netbox_url = ctx.config.netbox_url,
        .branching = ctx.config.branching,
        .branch = netbox.activeBranch(ctx.config),
        .state_dir = ctx.config.state_dir,
        .token_configured = ctx.config.netbox_token != null,
    });
}

fn printHelp(ctx: *Context) !void {
    const Help = struct {
        name: []const u8 = "nbxg",
        version: []const u8 = version,
        usage: []const u8 = "nbxg <command> [options]",
        commands: []const []const u8 = &.{
            "version                          Print version and active configuration",
            "help                             Show this help",
            "get <type> <id>                  Read a NetBox resource (read-only)",
            "inspect <type> <id>              Read a resource annotated with field policy",
            "describe [<type>] [--source options|openapi] [--refresh] [--offline]",
            "                                 Self-describe a type: action, fields, I/O schema (live-synced to NetBox)",
            "plan <type> <id> --set k=v ...   Create a change plan (policy + risk checked)",
            "approve --plan <id> [--note x]   Approve a high-risk plan (binds plan_hash)",
            "reject --plan <id> [--note x]    Reject a plan so it can never be applied",
            "apply --plan <id>                Backup then apply an approved/low-risk plan",
            "restore --backup <id>            Revert a resource from a backup snapshot",
            "audit [--plan <id>]              Show the audit log",
            "list <plans|approvals|backups>   List local state",
        },
        resource_types: []const []const u8 = &.{ "device", "interface", "ip-address", "prefix", "vlan" },
        allowed_fields: []const []const u8 = &policy.allowed_fields,
        high_risk_fields: []const []const u8 = &policy.high_risk_fields,
        env: []const []const u8 = &.{
            "NETBOX_URL            NetBox base URL (default http://localhost:8000)",
            "NETBOX_TOKEN          NetBox API token (required for plan/get/inspect/apply/restore)",
            "NBX_GUARD_STATE_DIR   Local state directory (default .nbx-guard)",
            "NBX_GUARD_HTTP_TIMEOUT_MS  NetBox connect timeout in ms (default 15000, 0=off)",
            "NBX_GUARD_BRANCHING   Use NetBox Branching (1/true)",
        },
        principle: []const u8 = "Agent proposes intent; the CLI decides what is allowed.",
    };
    try ctx.ok("help", Help{});
}

// ---------------------------------------------------------------------------
// get / inspect (read-only)
// ---------------------------------------------------------------------------

fn cmdGet(ctx: *Context, rest: []const [:0]const u8, comptime command: []const u8) !u8 {
    if (rest.len < 2) {
        try ctx.fail(command, .{
            .kind = .invalid_args,
            .message = "expected <type> <id>",
            .next_action = "example: nbxg " ++ command ++ " device 1",
        });
        return exit_client;
    }
    const rtype = rest[0];
    const rid = rest[1];

    if (netbox.endpoint(rtype) == null) return failUnknownType(ctx, command, rtype);
    if (ctx.config.netbox_token == null) return failNoToken(ctx, command);

    var client = netbox.Client.init(ctx);
    defer client.deinit();

    const res = client.get(rtype, rid) catch |err| return failNetboxConn(ctx, command, err);
    defer ctx.gpa.free(res.body);

    if (!res.ok) return failNetboxStatus(ctx, command, res);

    const resource = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, res.body, .{}) catch
        std.json.Value{ .null = {} };

    if (eq(command, "inspect")) {
        try ctx.ok(command, .{
            .resource_type = rtype,
            .resource_id = rid,
            .resource = resource,
            .policy = .{
                .allowed_fields = &policy.allowed_fields,
                .high_risk_fields = &policy.high_risk_fields,
                .note = "Other fields are denied by default. High-risk fields require approval.",
            },
        });
    } else {
        try ctx.ok(command, .{ .resource_type = rtype, .resource_id = rid, .resource = resource });
    }
    return exit_ok;
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
    const doc = schema.lookup(key) orelse return failUnknownType(ctx, "describe", key);

    var fields: std.ArrayList(DescribeField) = .empty;
    for (doc.low) |fname| {
        const fd = schema.fieldDoc(fname) orelse continue;
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
        const fd = schema.fieldDoc(fname) orelse continue;
        try fields.append(ctx.arena, .{
            .name = fname,
            .class = "high_risk",
            .requires_approval = true,
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
        .denied_actions = &[_][]const u8{ "create", "delete", "bulk_delete" },
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
    try ctx.ok("describe", .{
        .principle = "Agent proposes intent; the CLI decides what is allowed.",
        .action = "update",
        .denied_actions = &[_][]const u8{ "create", "delete", "bulk_delete" },
        .default_policy = "deny: only explicitly classified fields are writable",
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
    if (netbox.endpoint(rtype) == null) return failUnknownType(ctx, "plan", rtype);

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
    const eval = try policy.evaluate(ctx.arena, fields);

    if (eval.decision == .deny) {
        try ctx.fail("plan", .{
            .kind = .policy_denied,
            .message = "one or more fields are not writable by policy (default-deny)",
            .risk_level = eval.risk_level,
            .next_action = "remove denied fields; only allowed/high-risk fields may be changed",
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

    const next_action = if (p.requires_approval)
        "high-risk: run `nbxg approve --plan <plan_id>`, then `apply`"
    else
        "low-risk: run `nbxg apply --plan <plan_id>`";

    try ctx.ok("plan", .{
        .plan = p,
        .evaluation = eval,
        .next_action = next_action,
    });
    return exit_ok;
}

// ---------------------------------------------------------------------------
// approve
// ---------------------------------------------------------------------------

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
    if (ctx.config.netbox_token == null) return failNoToken(ctx, "apply");

    const store = Store.init(ctx);
    try store.ensureDirs();
    const lock = try store.acquireLock();
    defer lock.release();

    const loaded = (try plan.load(store, plan_id)) orelse return failPlanNotFound(ctx, "apply", plan_id);
    defer loaded.deinit();
    var p = loaded.value;

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

    // Re-validate policy on the stored changes (defense in depth).
    const fields = try plan.changeFields(ctx.arena, p.changes);
    const eval = try policy.evaluate(ctx.arena, fields);
    if (eval.decision == .deny) {
        try ctx.fail("apply", .{
            .kind = .policy_denied,
            .message = "stored plan violates policy and will not be applied",
            .next_action = "discard this plan",
        });
        return exit_client;
    }

    var client = netbox.Client.init(ctx);
    defer client.deinit();

    const now_ns = ctx.nowNanos();
    const request_id = try ids.genId(ctx.arena, "req", now_ns);

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
        .next_action = "run `nbxg describe` to list types; one of: device, interface, ip-address, prefix, vlan",
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
    const msg = try std.fmt.allocPrint(ctx.arena, "netbox returned HTTP {d}", .{res.status});
    try ctx.fail(command, .{
        .kind = if (res.status == 409) .conflict else .netbox_error,
        .message = msg,
        .next_action = "inspect the resource and adjust the plan",
    });
    return exit_upstream;
}
