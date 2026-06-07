//! Execution context shared by every command, plus the agent-facing JSON
//! response envelope and structured error model.
const std = @import("std");
const Config = @import("config.zig").Config;

/// Stable, machine-readable error categories returned to the agent.
pub const ErrKind = enum {
    invalid_args,
    config_error,
    policy_denied,
    invalid_field,
    needs_approval,
    not_approved,
    plan_not_found,
    approval_not_found,
    backup_not_found,
    plan_state_error,
    netbox_error,
    conflict,
    io_error,
    not_implemented,
};

/// Structured failure payload. `next_action` tells the agent what to do next.
pub const GuardError = struct {
    kind: ErrKind,
    message: []const u8,
    risk_level: []const u8 = "low",
    next_action: []const u8,
};

pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    config: Config,
    out: *std.Io.Writer,

    /// Current wall-clock time in nanoseconds.
    pub fn nowNanos(self: *const Context) i128 {
        return std.Io.Timestamp.now(self.io, .real).nanoseconds;
    }

    pub fn flush(self: *const Context) !void {
        try self.out.flush();
    }

    /// Emit a success envelope: `{ ok:true, command, data, error:null }`.
    pub fn ok(self: *const Context, command: []const u8, data: anytype) !void {
        var s: std.json.Stringify = .{ .writer = self.out, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("command");
        try s.write(command);
        try s.objectField("data");
        try s.write(data);
        try s.objectField("error");
        try s.write(null);
        try s.endObject();
        try self.out.writeByte('\n');
        try self.flush();
    }

    /// Emit a failure envelope: `{ ok:false, command, data:null, error }`.
    pub fn fail(self: *const Context, command: []const u8, err: GuardError) !void {
        var s: std.json.Stringify = .{ .writer = self.out, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("ok");
        try s.write(false);
        try s.objectField("command");
        try s.write(command);
        try s.objectField("data");
        try s.write(null);
        try s.objectField("error");
        try s.write(err);
        try s.endObject();
        try self.out.writeByte('\n');
        try self.flush();
    }
};
