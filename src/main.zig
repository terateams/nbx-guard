//! nbx-guard entry point. The agent only ever proposes intent here; the CLI
//! decides what is actually allowed to happen.
const std = @import("std");
const guard = @import("nbx_guard");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_fw: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_fw.interface;

    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var ctx: guard.context.Context = .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .env = init.environ_map,
        .config = guard.config.Config.fromEnv(init.environ_map),
        .out = out,
    };

    const code = guard.cli.run(&ctx, args) catch |err| {
        out.print(
            "{{\"ok\":false,\"command\":\"\",\"data\":null,\"error\":{{\"kind\":\"io_error\",\"message\":\"{s}\",\"risk_level\":\"low\",\"next_action\":\"retry or inspect environment\"}}}}\n",
            .{@errorName(err)},
        ) catch {};
        out.flush() catch {};
        std.process.exit(1);
    };
    std.process.exit(code);
}
