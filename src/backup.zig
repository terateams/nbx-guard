//! Pre-apply backups. Before any change is applied a snapshot of the resource
//! is captured, along with the prior values of exactly the fields being changed,
//! so the change can be reverted deterministically.
const std = @import("std");
const Store = @import("store.zig").Store;

pub const Backup = struct {
    backup_id: []const u8,
    plan_id: ?[]const u8 = null,
    resource_type: []const u8,
    resource_id: []const u8,
    /// Full resource representation at backup time (for inspection/audit).
    snapshot: std.json.Value,
    /// Object mapping each changed field to its value before the change.
    prior_values: std.json.Value,
    created_at: i64,
    netbox_url: []const u8,
};

pub fn save(store: Store, backup: Backup) !void {
    const name = try std.fmt.allocPrint(store.ctx.arena, "{s}.json", .{backup.backup_id});
    try store.writeJson(try store.path(&.{ "backups", name }), backup);
}

pub fn load(store: Store, backup_id: []const u8) !?std.json.Parsed(Backup) {
    const name = try std.fmt.allocPrint(store.ctx.arena, "{s}.json", .{backup_id});
    const bytes = (try store.readAlloc(try store.path(&.{ "backups", name }))) orelse return null;
    defer store.ctx.gpa.free(bytes);
    return try std.json.parseFromSlice(Backup, store.ctx.gpa, bytes, .{ .allocate = .alloc_always });
}

/// Extract `{ field: snapshot[field] }` for each changed field. Missing fields
/// are recorded as JSON null so a restore explicitly clears them.
pub fn priorValues(
    arena: std.mem.Allocator,
    snapshot: std.json.Value,
    fields: []const []const u8,
) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    const src = switch (snapshot) {
        .object => |o| o,
        else => null,
    };
    for (fields) |f| {
        const v = if (src) |o| (o.get(f) orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
        try obj.put(arena, f, v);
    }
    return .{ .object = obj };
}

/// Convert stored read-form values into NetBox write-form. NetBox returns rich
/// representations on GET (choice fields as `{value,label}`, related objects as
/// `{id,url,...}`) but only accepts the slug/id on write, so restoring a
/// captured value verbatim would be rejected for exactly the high-risk fields
/// rollback matters most for. Choice objects collapse to their `value`, related
/// objects to their `id`, arrays (e.g. tags) map element-wise to ids, and plain
/// objects (e.g. `custom_fields`) and scalars pass through unchanged.
pub fn toWriteForm(arena: std.mem.Allocator, values: std.json.Value) !std.json.Value {
    const src = switch (values) {
        .object => |o| o,
        else => return values,
    };
    var obj: std.json.ObjectMap = .empty;
    var it = src.iterator();
    while (it.next()) |entry| {
        try obj.put(arena, entry.key_ptr.*, try toWriteScalar(arena, entry.value_ptr.*));
    }
    return .{ .object = obj };
}

fn toWriteScalar(arena: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .object => |o| blk: {
            if (o.get("value")) |val| break :blk val;
            if (o.get("id")) |idv| break :blk idv;
            break :blk v;
        },
        .array => |arr| blk: {
            var out = std.json.Array.init(arena);
            for (arr.items) |item| try out.append(try toWriteScalar(arena, item));
            break :blk .{ .array = out };
        },
        else => v,
    };
}

test "toWriteForm collapses choice and related representations" {
    const a = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"status":{"value":"active","label":"Active"},"site":{"id":7,"name":"hq"},"description":"x","custom_fields":{"k":1},"tags":[{"id":3,"name":"t"}]}
    , .{});
    const out = try toWriteForm(arena, input);
    const s = try std.json.Stringify.valueAlloc(arena, out, .{});
    defer arena.free(s);

    try std.testing.expect(std.mem.indexOf(u8, s, "\"status\":\"active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"site\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"description\":\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"custom_fields\":{\"k\":1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"tags\":[3]") != null);
}
