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

/// Parse a single `--set` value into JSON (numbers, bools, arrays, objects when
/// it parses, otherwise a string). Exposed so the CLI can merge `--set` pairs
/// into the same object it builds from a `--data` JSON document.
pub fn scalarValue(arena: std.mem.Allocator, s: []const u8) std.json.Value {
    return parseScalar(arena, s);
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

/// Deep structural equality for two JSON values. Used to detect a no-op plan
/// (every requested value already equals the current NetBox value). Numbers
/// compare across integer/float representations; objects compare key sets and
/// member values irrespective of key order.
pub fn valueEqual(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => switch (b) {
            .null => true,
            else => false,
        },
        .bool => |av| switch (b) {
            .bool => |bv| av == bv,
            else => false,
        },
        .integer => |av| switch (b) {
            .integer => |bv| av == bv,
            .float => |bv| @as(f64, @floatFromInt(av)) == bv,
            else => false,
        },
        .float => |av| switch (b) {
            .float => |bv| av == bv,
            .integer => |bv| av == @as(f64, @floatFromInt(bv)),
            else => false,
        },
        .number_string => |av| switch (b) {
            .number_string => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .string => |av| switch (b) {
            .string => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .array => |av| switch (b) {
            .array => |bv| blk: {
                if (av.items.len != bv.items.len) break :blk false;
                for (av.items, bv.items) |x, y| {
                    if (!valueEqual(x, y)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |av| switch (b) {
            .object => |bv| blk: {
                if (av.count() != bv.count()) break :blk false;
                var it = av.iterator();
                while (it.next()) |entry| {
                    const other = bv.get(entry.key_ptr.*) orelse break :blk false;
                    if (!valueEqual(entry.value_ptr.*, other)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
    };
}

/// True when every field in `fields` has the same value in `requested` as in
/// `current` — i.e. the requested update is a complete no-op. Both arguments are
/// JSON objects keyed by field name; a missing key compares as null. An empty
/// field set is never a no-op. A representation mismatch (e.g. NetBox returns a
/// `{value,label}` object while the request is a scalar) compares as changed, so
/// this never produces a false "no change".
pub fn allUnchanged(
    requested: std.json.Value,
    current: std.json.Value,
    fields: []const []const u8,
) bool {
    if (fields.len == 0) return false;
    const req = switch (requested) {
        .object => |o| o,
        else => return false,
    };
    const cur = switch (current) {
        .object => |o| o,
        else => return false,
    };
    for (fields) |f| {
        const rv = req.get(f) orelse std.json.Value{ .null = {} };
        const cv = cur.get(f) orelse std.json.Value{ .null = {} };
        if (!valueEqual(rv, cv)) return false;
    }
    return true;
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

test "valueEqual + allUnchanged detect no-op updates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Requested values, parsed the same way NetBox returns scalar fields.
    const requested = try buildChanges(a, &.{
        .{ .key = "description", .value = "edge router" },
        .{ .key = "vid", .value = "100" },
    });
    const fields = try changeFields(a, requested);

    var cur: std.json.ObjectMap = .empty;
    try cur.put(a, "description", .{ .string = "edge router" });
    try cur.put(a, "vid", .{ .integer = 100 });
    try testing.expect(allUnchanged(requested, .{ .object = cur }, fields));

    // A single differing field defeats the no-op.
    var cur2: std.json.ObjectMap = .empty;
    try cur2.put(a, "description", .{ .string = "core router" });
    try cur2.put(a, "vid", .{ .integer = 100 });
    try testing.expect(!allUnchanged(requested, .{ .object = cur2 }, fields));

    // An empty field set is never a no-op.
    try testing.expect(!allUnchanged(requested, .{ .object = cur }, &.{}));

    // Representation mismatch (NetBox {value,label} object vs scalar request) is
    // treated as changed, never a false no-op.
    var status_obj: std.json.ObjectMap = .empty;
    try status_obj.put(a, "value", .{ .string = "active" });
    var cur3: std.json.ObjectMap = .empty;
    try cur3.put(a, "status", .{ .object = status_obj });
    const req_status = try buildChanges(a, &.{.{ .key = "status", .value = "active" }});
    const sf = try changeFields(a, req_status);
    try testing.expect(!allUnchanged(req_status, .{ .object = cur3 }, sf));
}
