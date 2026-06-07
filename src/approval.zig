//! Approval gate. High-risk plans require an approval record bound to the
//! plan's `plan_hash`, so an approved plan cannot be altered before apply.
const std = @import("std");
const Store = @import("store.zig").Store;

pub const status_approved = "approved";
pub const status_rejected = "rejected";

pub const Approval = struct {
    approval_id: []const u8,
    plan_id: []const u8,
    plan_hash: []const u8,
    resource_type: []const u8,
    resource_id: []const u8,
    risk_level: []const u8,
    status: []const u8,
    approver: []const u8,
    created_at: i64,
    note: ?[]const u8 = null,
};

pub fn save(store: Store, approval: Approval) !void {
    const name = try std.fmt.allocPrint(store.ctx.arena, "{s}.json", .{approval.approval_id});
    try store.writeJson(try store.path(&.{ "approvals", name }), approval);
}

pub fn load(store: Store, approval_id: []const u8) !?std.json.Parsed(Approval) {
    const name = try std.fmt.allocPrint(store.ctx.arena, "{s}.json", .{approval_id});
    const bytes = (try store.readAlloc(try store.path(&.{ "approvals", name }))) orelse return null;
    defer store.ctx.gpa.free(bytes);
    return try std.json.parseFromSlice(Approval, store.ctx.gpa, bytes, .{ .allocate = .alloc_always });
}
