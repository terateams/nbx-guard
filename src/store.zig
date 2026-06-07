//! Local state storage: plans / backups / approvals / audit live as JSON and
//! JSONL files under the configured state directory.
const std = @import("std");
const Context = @import("context.zig").Context;

pub const Store = struct {
    ctx: *const Context,

    pub fn init(ctx: *const Context) Store {
        return .{ .ctx = ctx };
    }

    fn dir(_: Store) std.Io.Dir {
        return std.Io.Dir.cwd();
    }

    /// Join state_dir with the given path segments using the arena allocator.
    pub fn path(self: Store, segments: []const []const u8) ![]u8 {
        const a = self.ctx.arena;
        var parts = try a.alloc([]const u8, segments.len + 1);
        parts[0] = self.ctx.config.state_dir;
        for (segments, 0..) |s, i| parts[i + 1] = s;
        return std.fs.path.join(a, parts);
    }

    /// Create the state directory tree (`plans/`, `backups/`, `approvals/`).
    pub fn ensureDirs(self: Store) !void {
        const io = self.ctx.io;
        const d = self.dir();
        try d.createDirPath(io, self.ctx.config.state_dir);
        inline for (.{ "plans", "backups", "approvals" }) |sub| {
            try d.createDirPath(io, try self.path(&.{sub}));
        }
    }

    pub fn exists(self: Store, rel: []const u8) bool {
        self.dir().access(self.ctx.io, rel, .{}) catch return false;
        return true;
    }

    /// Read an entire file, or `null` if it does not exist. Caller owns memory.
    pub fn readAlloc(self: Store, rel: []const u8) !?[]u8 {
        return self.dir().readFileAlloc(self.ctx.io, rel, self.ctx.gpa, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    pub fn writeBytes(self: Store, rel: []const u8, data: []const u8) !void {
        try self.dir().writeFile(self.ctx.io, .{ .sub_path = rel, .data = data });
    }

    /// Serialize `value` as pretty JSON and write it to `rel` (truncating).
    pub fn writeJson(self: Store, rel: []const u8, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.ctx.gpa, value, .{ .whitespace = .indent_2 });
        defer self.ctx.gpa.free(bytes);
        try self.writeBytes(rel, bytes);
    }

    /// Append one minified JSON line to `rel`, creating it if needed.
    pub fn appendJsonl(self: Store, rel: []const u8, value: anytype) !void {
        const line = try std.json.Stringify.valueAlloc(self.ctx.gpa, value, .{});
        defer self.ctx.gpa.free(line);

        const existing = try self.readAlloc(rel);
        defer if (existing) |e| self.ctx.gpa.free(e);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.ctx.gpa);
        if (existing) |e| try buf.appendSlice(self.ctx.gpa, e);
        try buf.appendSlice(self.ctx.gpa, line);
        try buf.append(self.ctx.gpa, '\n');
        try self.writeBytes(rel, buf.items);
    }
};
