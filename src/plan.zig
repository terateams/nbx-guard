//! Change plans. A plan captures the agent's *intent* (resource, action, field
//! changes) plus the policy verdict and a stable `plan_hash`. Nothing is ever
//! applied without first creating one.
const std = @import("std");
const Store = @import("store.zig").Store;
const ids = @import("ids.zig");

pub const status_planned = "planned";
pub const status_pending_approval = "pending_approval";
pub const status_approved = "approved";
pub const status_applied = "applied";
pub const status_rejected = "rejected";

pub const Change = struct { key: []const u8, value: []const u8 };

pub const Plan = struct {
    plan_id: []const u8,
    request_id: []const u8,
    plan_hash: []const u8,
    resource_type: []const u8,
    resource_id: []const u8,
    action: []const u8,
    changes: std.json.Value,
    risk_level: []const u8,
    requires_approval: bool,
    status: []const u8,
    approval_id: ?[]const u8 = null,
    backup_id: ?[]const u8 = null,
    created_at: i64,
    netbox_url: []const u8,
    /// Values of the changed fields as observed at plan time. Used at apply to
    /// detect drift. Defaults to null for plans created before this was added.
    base_values: std.json.Value = .{ .null = {} },
};

/// Convert `key=value` pairs into a JSON object. Each value is parsed as JSON
/// when possible (numbers, bools, arrays, objects), otherwise kept as a string.
pub fn buildChanges(arena: std.mem.Allocator, changes: []const Change) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (changes) |c| {
        try obj.put(arena, c.key, parseScalar(arena, c.value));
    }
    return .{ .object = obj };
}

fn parseScalar(arena: std.mem.Allocator, s: []const u8) std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, s, .{}) catch
        std.json.Value{ .string = s };
}

/// Field names present in a changes object, in insertion order.
pub fn changeFields(arena: std.mem.Allocator, changes: std.json.Value) ![]const []const u8 {
    const obj = switch (changes) {
        .object => |o| o,
        else => return &.{},
    };
    var list = try arena.alloc([]const u8, obj.count());
    var it = obj.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) list[i] = entry.key_ptr.*;
    return list;
}

/// Deterministic hash over the meaningful, security-relevant parts of a plan.
/// Approvals bind to this hash so an approved plan cannot be mutated.
pub fn computeHash(
    arena: std.mem.Allocator,
    resource_type: []const u8,
    resource_id: []const u8,
    action: []const u8,
    changes: std.json.Value,
) ![]u8 {
    const Canon = struct {
        resource_type: []const u8,
        resource_id: []const u8,
        action: []const u8,
        changes: std.json.Value,
    };
    const bytes = try std.json.Stringify.valueAlloc(arena, Canon{
        .resource_type = resource_type,
        .resource_id = resource_id,
        .action = action,
        .changes = changes,
    }, .{});
    return ids.sha256Hex(arena, bytes);
}

pub fn relPath(arena: std.mem.Allocator, plan_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "plans/{s}.json", .{plan_id});
}

pub fn save(store: Store, plan: Plan) !void {
    const rel = try store.path(&.{ "plans", try basename(store.ctx.arena, plan.plan_id) });
    try store.writeJson(rel, plan);
}

/// Load a plan by id. Caller must `deinit()` the returned `Parsed`.
pub fn load(store: Store, plan_id: []const u8) !?std.json.Parsed(Plan) {
    const rel = try store.path(&.{ "plans", try basename(store.ctx.arena, plan_id) });
    const bytes = (try store.readAlloc(rel)) orelse return null;
    defer store.ctx.gpa.free(bytes);
    return try std.json.parseFromSlice(Plan, store.ctx.gpa, bytes, .{ .allocate = .alloc_always });
}

fn basename(arena: std.mem.Allocator, plan_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}.json", .{plan_id});
}

const testing = std.testing;

test "buildChanges parses types and computeHash is stable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ch = try buildChanges(a, &.{
        .{ .key = "description", .value = "edge router" },
        .{ .key = "status", .value = "active" },
    });
    const fields = try changeFields(a, ch);
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("description", fields[0]);

    const h1 = try computeHash(a, "device", "1", "update", ch);
    const h2 = try computeHash(a, "device", "1", "update", ch);
    try testing.expectEqualStrings(h1, h2);
    try testing.expectEqual(@as(usize, 64), h1.len);

    // Any change to the intent must change the hash (basis of tamper detection).
    const ch2 = try buildChanges(a, &.{.{ .key = "description", .value = "edge router 2" }});
    const h3 = try computeHash(a, "device", "1", "update", ch2);
    try testing.expect(!std.mem.eql(u8, h1, h3));
    const h4 = try computeHash(a, "device", "2", "update", ch);
    try testing.expect(!std.mem.eql(u8, h1, h4));
}
