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
