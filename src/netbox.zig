//! NetBox REST client. The only component allowed to talk to NetBox. Exposes
//! just the verbs the gateway needs: GET (read) and PATCH (guarded write).
//! Raw/arbitrary API access and DELETE are intentionally not provided.
const std = @import("std");
const Context = @import("context.zig").Context;
const Config = @import("config.zig").Config;

pub const Error = error{ UnknownResourceType, MissingToken, UnsupportedContentEncoding };

pub const Result = struct {
    status: u16,
    /// Response body, owned by the caller (allocated with ctx.gpa).
    body: []u8,
    ok: bool,
};

/// Map a built-in resource type to its NetBox API path.
pub fn endpoint(resource_type: []const u8) ?[]const u8 {
    const map = .{
        .{ "device", "dcim/devices" },
        .{ "interface", "dcim/interfaces" },
        .{ "ip-address", "ipam/ip-addresses" },
        .{ "prefix", "ipam/prefixes" },
        .{ "vlan", "ipam/vlans" },
        .{ "contact", "tenancy/contacts" },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, resource_type, m[0])) return m[1];
    }
    return null;
}

/// Resolve a resource type to its NetBox API path, consulting the built-in map
/// first and then operator-supplied extensions in `NBX_GUARD_EXTRA_RESOURCES`.
/// This is the operator escape hatch for the hard-coded type allow-list: a human
/// (never the agent) widens coverage by exporting the env var; every workflow
/// control (plan/approval/backup/drift/audit/restore) still applies.
pub fn endpointFor(env: *const std.process.Environ.Map, resource_type: []const u8) ?[]const u8 {
    if (endpoint(resource_type)) |e| return e;
    return extraEndpoint(env, resource_type);
}

/// Parse `NBX_GUARD_EXTRA_RESOURCES` (`type=path,type2=path2`) for an operator-
/// added type. The returned slice borrows the env string, which lives for the
/// whole process, so no allocation is needed.
pub fn extraEndpoint(env: *const std.process.Environ.Map, resource_type: []const u8) ?[]const u8 {
    const spec = env.get("NBX_GUARD_EXTRA_RESOURCES") orelse return null;
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |pair_raw| {
        const pair = std.mem.trim(u8, pair_raw, " \t");
        const eqi = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = std.mem.trim(u8, pair[0..eqi], " \t");
        const ep = std.mem.trim(u8, pair[eqi + 1 ..], " \t/");
        if (key.len == 0 or ep.len == 0) continue;
        if (std.mem.eql(u8, key, resource_type)) return ep;
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

    /// `GET` the collection endpoint with an already-encoded query string (no
    /// leading `?`). Used by `list-resources`/`search` for read-only discovery.
    pub fn list(self: *Client, resource_type: []const u8, query: []const u8) !Result {
        const ep = endpointFor(self.ctx.env, resource_type) orelse return Error.UnknownResourceType;
        const arena = self.ctx.arena;
        const url = if (query.len > 0)
            try std.fmt.allocPrint(arena, "{s}/api/{s}/?{s}", .{ self.ctx.config.netbox_url, ep, query })
        else
            try std.fmt.allocPrint(arena, "{s}/api/{s}/", .{ self.ctx.config.netbox_url, ep });
        return self.send(.GET, url, null, true);
    }

    pub fn patch(self: *Client, resource_type: []const u8, id: []const u8, body: []const u8) !Result {
        return self.request(.PATCH, resource_type, id, body);
    }

    /// `POST` a new object to the collection endpoint. Used by `apply` for
    /// `create` plans; NetBox returns the created object (including its new id).
    pub fn create(self: *Client, resource_type: []const u8, body: []const u8) !Result {
        return self.request(.POST, resource_type, null, body);
    }

    /// `DELETE` an object by id. Used by `restore` to roll back a create
    /// (the rollback of a creation is deletion). NetBox returns 204 No Content.
    pub fn delete(self: *Client, resource_type: []const u8, id: []const u8) !Result {
        return self.request(.DELETE, resource_type, id, null);
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
        const ep = endpointFor(self.ctx.env, resource_type) orelse return Error.UnknownResourceType;
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

        // `std.http.Client` initializes its TLS trust store (the system CA
        // bundle and the clock used to check certificate expiry) lazily the
        // first time it runs `request()`. Because we connect ourselves via
        // `connectTcpOptions` (to inject the connect timeout) that lazy init
        // never runs, so the TLS handshake would dereference a null
        // `client.now` and panic. Prime the trust store here so an
        // unreachable, misconfigured, or TLS-failing NetBox surfaces as a
        // normal error envelope instead of crashing the CLI.
        if (protocol == .tls) try primeTlsTrust(&self.http, self.ctx.io);

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
        // std.http advertises `Accept-Encoding: gzip, deflate`, so NetBox (or a
        // reverse proxy / CDN in front of it) may return a compressed body.
        // Decode it per the negotiated Content-Encoding before parsing JSON.
        var transfer_buffer: [4096]u8 = undefined;
        const transfer = response.reader(&transfer_buffer);
        streamDecoded(arena, transfer, response.head.content_encoding, &resp.writer) catch |err| switch (err) {
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

/// Stream an HTTP response body into `out`, decoding the negotiated
/// `Content-Encoding`. `transfer` yields transfer-decoded (de-chunked) bytes
/// that may still be compressed: std.http advertises
/// `Accept-Encoding: gzip, deflate`, so the server may gzip- or deflate-encode
/// the body. `scratch` provides the decompression window (freed on return).
fn streamDecoded(
    scratch: std.mem.Allocator,
    transfer: *std.Io.Reader,
    content_encoding: std.http.ContentEncoding,
    out: *std.Io.Writer,
) !void {
    var window: []u8 = &.{};
    defer if (window.len != 0) scratch.free(window);
    switch (content_encoding) {
        .identity => {},
        .gzip, .deflate => window = try scratch.alloc(u8, std.compress.flate.max_window_len),
        .zstd => window = try scratch.alloc(u8, std.compress.zstd.default_window_len),
        .compress => return Error.UnsupportedContentEncoding,
    }
    var decompress: std.http.Decompress = undefined;
    const reader = std.http.Decompress.init(&decompress, transfer, window, content_encoding);
    _ = try reader.streamRemaining(out);
}

/// Prime `std.http.Client`'s TLS trust store so a TLS handshake driven through
/// `connectTcpOptions` does not dereference a null `now`. `request()` normally
/// does this lazily, but we bypass it to inject a connect timeout. Mirrors the
/// std lazy-init: scan the system CA bundle and record the validation clock.
fn primeTlsTrust(http: *std.http.Client, io: std.Io) !void {
    if (!std.http.Client.disable_tls) {
        if (http.now != null) return;
        const now = std.Io.Clock.real.now(io);
        try http.ca_bundle.rescan(http.allocator, io, now);
        http.now = now;
    }
}

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
    try std.testing.expectEqualStrings("tenancy/contacts", endpoint("contact").?);
    try std.testing.expect(endpoint("nope") == null);
}

test "endpointFor resolves operator extras (NBX_GUARD_EXTRA_RESOURCES)" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("NBX_GUARD_EXTRA_RESOURCES", "site=dcim/sites, tenant=tenancy/tenants ");
    // built-ins keep resolving
    try std.testing.expectEqualStrings("dcim/devices", endpointFor(&env, "device").?);
    // operator-added types resolve (whitespace + trailing slash tolerated)
    try std.testing.expectEqualStrings("dcim/sites", endpointFor(&env, "site").?);
    try std.testing.expectEqualStrings("tenancy/tenants", endpointFor(&env, "tenant").?);
    // anything not built-in or listed stays unknown (default-deny on types)
    try std.testing.expect(endpointFor(&env, "nope") == null);
}

test "endpointFor without extras is built-ins only" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try std.testing.expect(endpointFor(&env, "site") == null);
    try std.testing.expectEqualStrings("ipam/vlans", endpointFor(&env, "vlan").?);
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

test "primeTlsTrust initializes the TLS validation clock" {
    // Regression: HTTPS requests connect via `connectTcpOptions`, bypassing the
    // lazy trust-store init in `std.http.Client.request()`. Without priming,
    // the TLS handshake dereferences a null `now` and panics instead of
    // returning an error envelope. After priming, `now` must be set so the
    // handshake can proceed (and any failure surfaces as a normal error).
    if (std.http.Client.disable_tls) return error.SkipZigTest;
    var http: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer http.deinit();
    try std.testing.expect(http.now == null);
    try primeTlsTrust(&http, std.testing.io);
    try std.testing.expect(http.now != null);
    // Idempotent: a second call leaves the already-initialized clock in place.
    try primeTlsTrust(&http, std.testing.io);
    try std.testing.expect(http.now != null);
}

test "streamDecoded decodes gzip and deflate response bodies" {
    // Fixtures are the gzip and zlib(deflate) encodings of `want`; identity is
    // passed through unchanged.
    const gpa = std.testing.allocator;
    const want = "{\"count\":1,\"results\":[{\"id\":7,\"name\":\"edge-1\"}]}";
    const gzip_body = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xab, 0x56, 0x4a, 0xce,
        0x2f, 0xcd, 0x2b, 0x51, 0xb2, 0x32, 0xd4, 0x51, 0x2a, 0x4a, 0x2d, 0x2e, 0xcd, 0x29,
        0x29, 0x56, 0xb2, 0x8a, 0xae, 0x56, 0xca, 0x4c, 0x51, 0xb2, 0x32, 0xd7, 0x51, 0xca,
        0x4b, 0xcc, 0x4d, 0x55, 0xb2, 0x52, 0x4a, 0x4d, 0x49, 0x4f, 0xd5, 0x35, 0x54, 0xaa,
        0x8d, 0xad, 0x05, 0x00, 0x99, 0x57, 0x19, 0x6a, 0x30, 0x00, 0x00, 0x00,
    };
    const deflate_body = [_]u8{
        0x78, 0x9c, 0xab, 0x56, 0x4a, 0xce, 0x2f, 0xcd, 0x2b, 0x51, 0xb2, 0x32, 0xd4, 0x51,
        0x2a, 0x4a, 0x2d, 0x2e, 0xcd, 0x29, 0x29, 0x56, 0xb2, 0x8a, 0xae, 0x56, 0xca, 0x4c,
        0x51, 0xb2, 0x32, 0xd7, 0x51, 0xca, 0x4b, 0xcc, 0x4d, 0x55, 0xb2, 0x52, 0x4a, 0x4d,
        0x49, 0x4f, 0xd5, 0x35, 0x54, 0xaa, 0x8d, 0xad, 0x05, 0x00, 0x7d, 0x05, 0x0f, 0x41,
    };

    const cases = [_]struct { ce: std.http.ContentEncoding, body: []const u8 }{
        .{ .ce = .gzip, .body = &gzip_body },
        .{ .ce = .deflate, .body = &deflate_body },
        .{ .ce = .identity, .body = want },
    };
    for (cases) |c| {
        var transfer: std.Io.Reader = .fixed(c.body);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try streamDecoded(gpa, &transfer, c.ce, &out.writer);
        try std.testing.expectEqualStrings(want, out.written());
    }
}
