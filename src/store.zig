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

    /// Create an arbitrary subdirectory tree under the state dir (e.g. `cache/`),
    /// including any missing parents. Used for non-critical caches.
    pub fn ensureSubdir(self: Store, rel: []const u8) !void {
        try self.dir().createDirPath(self.ctx.io, rel);
    }

    /// Advisory lock guarding all state mutations. Held for the duration of a
    /// mutating command so concurrent invocations serialize instead of racing
    /// (which could lose audit entries or double-apply). Released on `release`,
    /// and automatically by the OS if the process dies.
    pub const Lock = struct {
        file: std.Io.File,
        io: std.Io,
        pub fn release(self: Lock) void {
            self.file.close(self.io);
        }
    };

    /// Acquire the exclusive state lock, creating `<state_dir>/.lock` if needed.
    /// Blocks until the lock is available. Call `ensureDirs` first.
    pub fn acquireLock(self: Store) !Lock {
        const p = try self.path(&.{".lock"});
        const file = try self.dir().createFile(self.ctx.io, p, .{ .truncate = false, .lock = .exclusive });
        return .{ .file = file, .io = self.ctx.io };
    }

    /// Read an entire file, or `null` if it does not exist. Caller owns memory.
    /// Caps at 16 MB; use `readAllocMax` for larger payloads (e.g. schema cache).
    pub fn readAlloc(self: Store, rel: []const u8) !?[]u8 {
        return self.readAllocMax(rel, 16 * 1024 * 1024);
    }

    /// Like `readAlloc` but with a caller-specified maximum size. Returns
    /// `error.StreamTooLong` if the file exceeds `max_bytes`.
    pub fn readAllocMax(self: Store, rel: []const u8, max_bytes: usize) !?[]u8 {
        return self.dir().readFileAlloc(self.ctx.io, rel, self.ctx.gpa, .limited(max_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    /// Write `data` to `rel` atomically: stream into a temp file, then rename it
    /// over the target. A crash mid-write therefore never leaves a torn file
    /// (a truncated backup would mean an unrecoverable rollback), and readers
    /// always observe either the old or the new file, never a partial one.
    pub fn writeBytes(self: Store, rel: []const u8, data: []const u8) !void {
        const io = self.ctx.io;
        const d = self.dir();
        const tmp = try std.fmt.allocPrint(self.ctx.arena, "{s}.tmp.{d}", .{ rel, self.ctx.nowNanos() });
        errdefer d.deleteFile(io, tmp) catch {};
        {
            var file = try d.createFile(io, tmp, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, data);
        }
        try d.rename(tmp, d, rel, io);
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
