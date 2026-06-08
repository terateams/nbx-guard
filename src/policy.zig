//! Policy engine. Default-deny: a field may only be written if it is explicitly
//! classified. Low-risk fields apply directly; high-risk fields require approval;
//! everything else is denied. Delete/bulk-delete are never allowed.
const std = @import("std");

pub const FieldClass = enum { allowed, high_risk, denied };
pub const Decision = enum { allow, allow_with_approval, deny };

const EnvMap = std.process.Environ.Map;

/// Low-risk, agent-writable fields (no approval required).
pub const allowed_fields = [_][]const u8{ "description", "comments", "tags", "custom_fields", "title", "phone", "email", "link" };

/// High-risk fields: writable only through an approved plan.
pub const high_risk_fields = [_][]const u8{ "status", "role", "site", "rack", "prefix", "address", "groups" };

/// Only `update` is permitted. `create`/`delete`/`bulk_delete` are refused.
pub fn actionAllowed(action: []const u8) bool {
    return std.mem.eql(u8, action, "update");
}

pub fn classifyField(name: []const u8) FieldClass {
    for (high_risk_fields) |f| if (std.mem.eql(u8, name, f)) return .high_risk;
    for (allowed_fields) |f| if (std.mem.eql(u8, name, f)) return .allowed;
    return .denied;
}

/// Like `classifyField`, but the operator may widen the (still default-deny)
/// allow-list via `NBX_GUARD_ALLOWED_FIELDS` / `NBX_GUARD_HIGH_RISK_FIELDS`
/// (comma/space separated). Built-in classification always wins, so a built-in
/// high-risk field can never be downgraded to low-risk by the environment, and
/// an env high-risk entry beats an env allowed entry (fail safe).
pub fn classifyFieldEnv(env: *const EnvMap, name: []const u8) FieldClass {
    const builtin = classifyField(name);
    if (builtin != .denied) return builtin;
    if (envListHas(env, "NBX_GUARD_HIGH_RISK_FIELDS", name)) return .high_risk;
    if (envListHas(env, "NBX_GUARD_ALLOWED_FIELDS", name)) return .allowed;
    return .denied;
}

/// True when `name` appears in the comma/space/tab separated env list `var_name`.
pub fn envListHas(env: *const EnvMap, var_name: []const u8, name: []const u8) bool {
    const spec = env.get(var_name) orelse return false;
    var it = std.mem.tokenizeAny(u8, spec, ", \t");
    while (it.next()) |tok| if (std.mem.eql(u8, tok, name)) return true;
    return false;
}

pub const FieldVerdict = struct {
    field: []const u8,
    class: FieldClass,
};

pub const Evaluation = struct {
    decision: Decision,
    risk_level: []const u8,
    requires_approval: bool,
    verdicts: []const FieldVerdict,
    denied_fields: []const []const u8,
    high_risk_used: []const []const u8,

    pub fn allowed(self: Evaluation) bool {
        return self.decision != .deny;
    }
};

/// Evaluate a set of field names against the built-in policy. Allocations use
/// `arena`. Operator env extensions are ignored (use `evaluateEnv`).
pub fn evaluate(arena: std.mem.Allocator, fields: []const []const u8) !Evaluation {
    return evaluateWith(arena, null, fields);
}

/// Like `evaluate`, but honors operator-supplied field extensions in
/// `NBX_GUARD_ALLOWED_FIELDS` / `NBX_GUARD_HIGH_RISK_FIELDS`.
pub fn evaluateEnv(arena: std.mem.Allocator, env: *const EnvMap, fields: []const []const u8) !Evaluation {
    return evaluateWith(arena, env, fields);
}

fn evaluateWith(arena: std.mem.Allocator, env: ?*const EnvMap, fields: []const []const u8) !Evaluation {
    var verdicts = try arena.alloc(FieldVerdict, fields.len);
    var denied: std.ArrayList([]const u8) = .empty;
    var high: std.ArrayList([]const u8) = .empty;

    for (fields, 0..) |f, i| {
        const class = if (env) |e| classifyFieldEnv(e, f) else classifyField(f);
        verdicts[i] = .{ .field = f, .class = class };
        switch (class) {
            .denied => try denied.append(arena, f),
            .high_risk => try high.append(arena, f),
            .allowed => {},
        }
    }

    const decision: Decision = if (denied.items.len > 0)
        .deny
    else if (high.items.len > 0)
        .allow_with_approval
    else
        .allow;

    return .{
        .decision = decision,
        .risk_level = if (high.items.len > 0) "high" else "low",
        .requires_approval = decision == .allow_with_approval,
        .verdicts = verdicts,
        .denied_fields = try denied.toOwnedSlice(arena),
        .high_risk_used = try high.toOwnedSlice(arena),
    };
}

const testing = std.testing;

test "default deny blocks unknown field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const e = try evaluate(arena.allocator(), &.{ "description", "name" });
    try testing.expectEqual(Decision.deny, e.decision);
    try testing.expectEqual(@as(usize, 1), e.denied_fields.len);
    try testing.expectEqualStrings("name", e.denied_fields[0]);
}

test "high-risk field requires approval" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const e = try evaluate(arena.allocator(), &.{ "description", "status" });
    try testing.expectEqual(Decision.allow_with_approval, e.decision);
    try testing.expect(e.requires_approval);
    try testing.expectEqualStrings("high", e.risk_level);
}

test "low-risk only is auto-allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const e = try evaluate(arena.allocator(), &.{ "description", "comments", "tags" });
    try testing.expectEqual(Decision.allow, e.decision);
    try testing.expect(!e.requires_approval);
    try testing.expectEqualStrings("low", e.risk_level);
}

test "delete action refused" {
    try testing.expect(!actionAllowed("delete"));
    try testing.expect(!actionAllowed("bulk_delete"));
    try testing.expect(actionAllowed("update"));
}

test "operator env extends the allow-list without weakening defaults" {
    const a = testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("NBX_GUARD_ALLOWED_FIELDS", "asset_tag, serial");
    try env.put("NBX_GUARD_HIGH_RISK_FIELDS", "primary_ip4");

    // env-added low-risk field -> allowed, no approval
    try testing.expectEqual(FieldClass.allowed, classifyFieldEnv(&env, "asset_tag"));
    // env-added high-risk field -> requires approval
    try testing.expectEqual(FieldClass.high_risk, classifyFieldEnv(&env, "primary_ip4"));
    // unlisted field is still denied (default-deny holds)
    try testing.expectEqual(FieldClass.denied, classifyFieldEnv(&env, "name"));
    // a built-in high-risk field cannot be downgraded by env
    try env.put("NBX_GUARD_ALLOWED_FIELDS", "asset_tag, serial, status");
    try testing.expectEqual(FieldClass.high_risk, classifyFieldEnv(&env, "status"));

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const e = try evaluateEnv(arena.allocator(), &env, &.{ "description", "asset_tag", "primary_ip4" });
    try testing.expectEqual(Decision.allow_with_approval, e.decision);
    try testing.expect(e.requires_approval);

    const denied_eval = try evaluateEnv(arena.allocator(), &env, &.{"name"});
    try testing.expectEqual(Decision.deny, denied_eval.decision);
}
