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

/// NetBox v2 API tokens (NetBox 4.5+) are presented as `nbt_<key>.<secret>`
/// and authenticate with the `Bearer` scheme; legacy v1 tokens (the 40-char
/// value) use `Token`. NetBox infers the version from the `nbt_` prefix, so we
/// select the matching scheme from the token itself — the agent just supplies
/// whatever `NETBOX_TOKEN` NetBox handed it, regardless of version.
pub fn authHeader(arena: std.mem.Allocator, token: []const u8) ![]const u8 {
    const scheme = if (std.mem.startsWith(u8, token, "nbt_")) "Bearer" else "Token";
    return std.fmt.allocPrint(arena, "{s} {s}", .{ scheme, token });
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

    /// `OPTIONS` the collection endpoint to retrieve DRF field metadata
    /// (types, choices, required, help_text) for the live NetBox instance.
    /// Used by `describe` to keep the reported schema in sync with NetBox.
    pub fn options(self: *Client, resource_type: []const u8) !Result {
        return self.request(.OPTIONS, resource_type, null, null);
    }

    /// Fetch the instance's OpenAPI 3.0 description (`/api/schema/?format=json`).
    /// This is the canonical, complete API contract drf-spectacular generates;
    /// `describe --source openapi` uses it (cached) as an alternative to OPTIONS.
    /// Note: the document is large (multiple MB), hence the caller caches it.
    pub fn schema(self: *Client) !Result {
        const url = try std.fmt.allocPrint(self.ctx.arena, "{s}/api/schema/?format=json", .{self.ctx.config.netbox_url});
        return self.send(.GET, url, null, false);
    }

    fn request(
        self: *Client,
        method: std.http.Method,
        resource_type: []const u8,
        id: ?[]const u8,
        payload: ?[]const u8,
    ) !Result {
        const ep = endpoint(resource_type) orelse return Error.UnknownResourceType;
        const arena = self.ctx.arena;

        const url = if (id) |rid|
            try std.fmt.allocPrint(arena, "{s}/api/{s}/{s}/", .{ self.ctx.config.netbox_url, ep, rid })
        else
            try std.fmt.allocPrint(arena, "{s}/api/{s}/", .{ self.ctx.config.netbox_url, ep });

        return self.send(method, url, payload, true);
    }

    fn send(
        self: *Client,
        method: std.http.Method,
        url: []const u8,
        payload: ?[]const u8,
        want_branch: bool,
    ) !Result {
        const token = self.ctx.config.netbox_token orelse return Error.MissingToken;
        const arena = self.ctx.arena;
        const auth = try authHeader(arena, token);

        var extra: std.ArrayList(std.http.Header) = .empty;
        try extra.append(arena, .{ .name = "Accept", .value = "application/json" });
        if (want_branch) {
            if (activeBranch(self.ctx.config)) |schema_id| {
                try extra.append(arena, .{ .name = "X-NetBox-Branch", .value = schema_id });
            }
        }

        // Establish the connection with a bounded timeout so an unreachable
        // NetBox fails fast instead of hanging the CLI indefinitely. We drive
        // the request/response explicitly (rather than `fetch`) only so the
        // timed connection can be injected.
        const uri = try std.Uri.parse(url);
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        const port: u16 = uri.port orelse if (protocol == .tls) 443 else 80;

        const connection = try self.http.connectTcpOptions(.{
            .host = host,
            .port = port,
            .protocol = protocol,
            .timeout = timeoutFor(self.ctx.config),
        });

        var req = try self.http.request(method, uri, .{
            .connection = connection,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .{ .override = auth },
                .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = extra.items,
        });
        defer req.deinit();

        if (payload) |body_bytes| {
            req.transfer_encoding = .{ .content_length = body_bytes.len };
            var body = try req.sendBodyUnflushed(&.{});
            try body.writer.writeAll(body_bytes);
            try body.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var response = try req.receiveHead(&.{});

        var resp: std.Io.Writer.Allocating = .init(self.ctx.gpa);
        defer resp.deinit();
        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        _ = reader.streamRemaining(&resp.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };

        const code: u16 = @intFromEnum(response.head.status);
        return .{
            .status = code,
            .body = try self.ctx.gpa.dupe(u8, resp.written()),
            .ok = code >= 200 and code < 300,
        };
    }
};

/// Build the per-request connect timeout from config. `0` means no timeout.
fn timeoutFor(config: Config) std.Io.Timeout {
    if (config.http_timeout_ms == 0) return .none;
    return .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(config.http_timeout_ms)),
        .clock = .awake,
    } };
}

test "endpoint mapping" {
    try std.testing.expectEqualStrings("dcim/devices", endpoint("device").?);
    try std.testing.expectEqualStrings("ipam/ip-addresses", endpoint("ip-address").?);
    try std.testing.expect(endpoint("nope") == null);
}

test "authHeader selects scheme by token version" {
    const a = std.testing.allocator;
    const v1 = try authHeader(a, "0123456789abcdef0123456789abcdef01234567");
    defer a.free(v1);
    try std.testing.expectEqualStrings("Token 0123456789abcdef0123456789abcdef01234567", v1);
    const v2 = try authHeader(a, "nbt_abcdefghijkl.secretsecretsecret");
    defer a.free(v2);
    try std.testing.expectEqualStrings("Bearer nbt_abcdefghijkl.secretsecretsecret", v2);
}

test "activeBranch routing" {
    try std.testing.expect(activeBranch(.{}) == null); // disabled by default
    try std.testing.expect(activeBranch(.{ .branching = true }) == null); // enabled but no schema id
    try std.testing.expect(activeBranch(.{ .branching = false, .branch = "td5smq0f" }) == null); // schema id but disabled
    try std.testing.expect(activeBranch(.{ .branching = true, .branch = "" }) == null); // empty schema id
    try std.testing.expectEqualStrings("td5smq0f", activeBranch(.{ .branching = true, .branch = "td5smq0f" }).?);
}
