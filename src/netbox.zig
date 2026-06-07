//! NetBox REST client. The only component allowed to talk to NetBox. Exposes
//! just the verbs the gateway needs: GET (read) and PATCH (guarded write).
//! Raw/arbitrary API access and DELETE are intentionally not provided.
const std = @import("std");
const Context = @import("context.zig").Context;

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

        const fr = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .headers = .{
                .authorization = .{ .override = auth },
                .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
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
