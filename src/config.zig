//! Runtime configuration, loaded from environment variables.
const std = @import("std");

pub const Config = struct {
    /// NetBox base URL, e.g. `https://netbox.example.com`.
    netbox_url: []const u8 = "http://localhost:8000",
    /// NetBox API token. Writes are impossible without it.
    netbox_token: ?[]const u8 = null,
    /// Directory (relative to cwd or absolute) holding local guard state.
    state_dir: []const u8 = ".nbx-guard",
    /// Use the NetBox Branching plugin (branch/diff/merge) instead of direct PATCH.
    branching: bool = false,
    /// Active branch schema id when `branching` is enabled.
    branch: ?[]const u8 = null,

    /// Build config from the process environment. Returned slices borrow the
    /// environment map and remain valid for the lifetime of the process.
    pub fn fromEnv(env: *const std.process.Environ.Map) Config {
        return .{
            .netbox_url = stripTrailingSlash(env.get("NETBOX_URL") orelse "http://localhost:8000"),
            .netbox_token = env.get("NETBOX_TOKEN"),
            .state_dir = env.get("NBX_GUARD_STATE_DIR") orelse ".nbx-guard",
            .branching = parseBool(env.get("NBX_GUARD_BRANCHING")),
            .branch = env.get("NBX_GUARD_BRANCH"),
        };
    }
};

fn parseBool(v: ?[]const u8) bool {
    const s = v orelse return false;
    return std.mem.eql(u8, s, "1") or
        std.ascii.eqlIgnoreCase(s, "true") or
        std.ascii.eqlIgnoreCase(s, "yes") or
        std.ascii.eqlIgnoreCase(s, "on");
}

fn stripTrailingSlash(s: []const u8) []const u8 {
    if (s.len > 1 and s[s.len - 1] == '/') return s[0 .. s.len - 1];
    return s;
}

test "parseBool" {
    try std.testing.expect(parseBool("1"));
    try std.testing.expect(parseBool("true"));
    try std.testing.expect(parseBool("YES"));
    try std.testing.expect(!parseBool("0"));
    try std.testing.expect(!parseBool(null));
}

test "stripTrailingSlash" {
    try std.testing.expectEqualStrings("http://x", stripTrailingSlash("http://x/"));
    try std.testing.expectEqualStrings("http://x", stripTrailingSlash("http://x"));
}
