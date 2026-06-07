//! Append-only audit log (JSONL). Every meaningful event is traceable back to
//! its plan_id / approval_id / backup_id / request_id.
const std = @import("std");
const Store = @import("store.zig").Store;

pub const file = "audit.jsonl";

pub const Entry = struct {
    ts: i64,
    request_id: []const u8,
    event: []const u8,
    plan_id: ?[]const u8 = null,
    approval_id: ?[]const u8 = null,
    backup_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    risk_level: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub fn append(store: Store, entry: Entry) !void {
    try store.appendJsonl(try store.path(&.{file}), entry);
}

/// Parse the whole audit log into entries. Caller owns the returned `Parsed`
/// values via the arena they were allocated from. Returns entries in order.
pub fn readAll(store: Store, arena: std.mem.Allocator) ![]Entry {
    const bytes = (try store.readAlloc(try store.path(&.{file}))) orelse return &.{};
    defer store.ctx.gpa.free(bytes);

    var list: std.ArrayList(Entry) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(Entry, arena, trimmed, .{ .allocate = .alloc_always }) catch continue;
        try list.append(arena, parsed);
    }
    return list.toOwnedSlice(arena);
}
