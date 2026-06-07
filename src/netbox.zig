//! NetBox REST client. The only component allowed to talk to NetBox. Exposes
//! just the verbs the gateway needs: GET (read) and PATCH (guarded write).
//! Raw/arbitrary API access and DELETE are intentionally not provided.
const std = @import("std");
const Context = @import("context.zig").Context;
const Config = @import("config.zig").Config;

pub const Error = error{ UnknownResourceType, MissingToken };

pub const Result = struct {
    status: u16,
    /// Response body, owned by the caller (allocated with ctx.gpa).
    body: []u8,
    ok: bool,
};

/// Map an MVP resource type to its NetBox API path.
pub fn endpoint(resource_type: []const u8) ?[]const u8 {
    const map = .{
        .{ "device", "dcim/devices" },
        .{ "interface", "dcim/interfaces" },
        .{ "ip-address", "ipam/ip-addresses" },
        .{ "prefix", "ipam/prefixes" },
        .{ "vlan", "ipam/vlans" },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, resource_type, m[0])) return m[1];
    }
    return null;
}

/// The active branch schema id, or null when branch routing is disabled.
/// When set, object requests carry the `X-NetBox-Branch` header so guarded
/// changes are scoped to a NetBox Branching branch instead of main. The value
/// is the branch's schema id (without the `branch_` prefix).
pub fn activeBranch(config: Config) ?[]const u8 {
    if (!config.branching) return null;
    const b = config.branch orelse return null;
    if (b.len == 0) return null;
    return b;
}

pub const Client = struct {
    ctx: *const Context,
    http: std.http.Client,

    pub fn init(ctx: *const Context) Client {
        return .{ .ctx = ctx, .http = .{ .allocator = ctx.gpa, .io = ctx.io } };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    pub fn get(self: *Client, resource_type: []const u8, id: []const u8) !Result {
        return self.request(.GET, resource_type, id, null);
    }

    pub fn patch(self: *Client, resource_type: []const u8, id: []const u8, body: []const u8) !Result {
        return self.request(.PATCH, resource_type, id, body);
    }

    fn request(
        self: *Client,
        method: std.http.Method,
        resource_type: []const u8,
        id: []const u8,
        payload: ?[]const u8,
    ) !Result {
        const ep = endpoint(resource_type) orelse return Error.UnknownResourceType;
        const token = self.ctx.config.netbox_token orelse return Error.MissingToken;
        const arena = self.ctx.arena;

        const url = try std.fmt.allocPrint(arena, "{s}/api/{s}/{s}/", .{ self.ctx.config.netbox_url, ep, id });
        const auth = try std.fmt.allocPrint(arena, "Token {s}", .{token});

        var resp: std.Io.Writer.Allocating = .init(self.ctx.gpa);
        defer resp.deinit();

        var extra: std.ArrayList(std.http.Header) = .empty;
        try extra.append(arena, .{ .name = "Accept", .value = "application/json" });
        if (activeBranch(self.ctx.config)) |schema_id| {
            try extra.append(arena, .{ .name = "X-NetBox-Branch", .value = schema_id });
        }

        const fr = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .headers = .{
                .authorization = .{ .override = auth },
                .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = extra.items,
            .response_writer = &resp.writer,
        });

        const code: u16 = @intFromEnum(fr.status);
        return .{
            .status = code,
            .body = try self.ctx.gpa.dupe(u8, resp.written()),
            .ok = code >= 200 and code < 300,
        };
    }
};

test "endpoint mapping" {
    try std.testing.expectEqualStrings("dcim/devices", endpoint("device").?);
    try std.testing.expectEqualStrings("ipam/ip-addresses", endpoint("ip-address").?);
    try std.testing.expect(endpoint("nope") == null);
}

test "activeBranch routing" {
    try std.testing.expect(activeBranch(.{}) == null); // disabled by default
    try std.testing.expect(activeBranch(.{ .branching = true }) == null); // enabled but no schema id
    try std.testing.expect(activeBranch(.{ .branching = false, .branch = "td5smq0f" }) == null); // schema id but disabled
    try std.testing.expect(activeBranch(.{ .branching = true, .branch = "" }) == null); // empty schema id
    try std.testing.expectEqualStrings("td5smq0f", activeBranch(.{ .branching = true, .branch = "td5smq0f" }).?);
}
