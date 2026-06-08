//! Runtime configuration, loaded from environment variables.
const std = @import("std");

const Environ = std.process.Environ;

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
    /// Per-request NetBox timeout in milliseconds (bounds the connect phase so a
    /// down/unreachable NetBox fails fast instead of hanging). 0 disables it.
    http_timeout_ms: u64 = 15000,

    /// Build config from the process environment. Returned slices borrow the
    /// environment map and remain valid for the lifetime of the process.
    pub fn fromEnv(env: *const std.process.Environ.Map) Config {
        return .{
            .netbox_url = stripTrailingSlash(env.get("NETBOX_URL") orelse "http://localhost:8000"),
            .netbox_token = env.get("NETBOX_TOKEN"),
            .state_dir = env.get("NBX_GUARD_STATE_DIR") orelse ".nbx-guard",
            .branching = parseBool(env.get("NBX_GUARD_BRANCHING")),
            .branch = env.get("NBX_GUARD_BRANCH"),
            .http_timeout_ms = parseU64(env.get("NBX_GUARD_HTTP_TIMEOUT_MS")) orelse 15000,
        };
    }
};

// -- operator config file (~/.nbx-guard/config.json) --------------------------
//
// A friendly alternative to the NBX_GUARD_EXTRA_RESOURCES / NBX_GUARD_ALLOWED_FIELDS
// / NBX_GUARD_HIGH_RISK_FIELDS environment variables: an operator can keep the same
// governance extensions in a JSON file instead of exporting three env vars.
//
//     {
//       "extra_resources":      { "site": "dcim/sites", "tenant": "tenancy/tenants" },
//       "allowed_fields":       ["serial", "asset_tag"],
//       "high_risk_fields":     ["tenant"],
//       "read_sensitive_fields": ["serial"],
//       "creatable_resources":  ["site", "vlan"]
//     }
//
// The file only *extends* governance (add types / writable fields / read-gated
// fields / creatable types); it never holds secrets — NETBOX_URL / NETBOX_TOKEN stay in the
// environment. Values from the file and the environment are unioned (env entries
// kept first so the env wins on any extra_resources key conflict). Built-in
// classification always wins over both.

/// Governance keys the config file can populate, in env-string syntax, so they can
/// be unioned into the process environment and read by the existing env-driven
/// readers (netbox.extraEndpoint / policy.classifyFieldEnv) unchanged.
pub const ParsedExt = struct {
    /// `type=path,type2=path2` for NBX_GUARD_EXTRA_RESOURCES (null = key absent).
    extra_resources: ?[]const u8 = null,
    /// comma-joined tokens for NBX_GUARD_ALLOWED_FIELDS (null = key absent).
    allowed_fields: ?[]const u8 = null,
    /// comma-joined tokens for NBX_GUARD_HIGH_RISK_FIELDS (null = key absent).
    high_risk_fields: ?[]const u8 = null,
    /// comma-joined tokens for NBX_GUARD_READ_SENSITIVE_FIELDS (null = key absent).
    read_sensitive_fields: ?[]const u8 = null,
    /// comma-joined type names for NBX_GUARD_CREATABLE_RESOURCES (null = key absent).
    /// Each names a resource type the operator permits `create` on (default-deny);
    /// `*` permits any registered type. Every create still requires approval.
    creatable_resources: ?[]const u8 = null,

    pub fn isEmpty(self: ParsedExt) bool {
        return self.extra_resources == null and self.allowed_fields == null and
            self.high_risk_fields == null and self.read_sensitive_fields == null and
            self.creatable_resources == null;
    }
};

pub const env_extra_resources = "NBX_GUARD_EXTRA_RESOURCES";
pub const env_allowed_fields = "NBX_GUARD_ALLOWED_FIELDS";
pub const env_high_risk_fields = "NBX_GUARD_HIGH_RISK_FIELDS";
pub const env_read_sensitive_fields = "NBX_GUARD_READ_SENSITIVE_FIELDS";
pub const env_creatable_resources = "NBX_GUARD_CREATABLE_RESOURCES";

/// Parse the operator config JSON into env-string fragments. Pure (no IO) so it is
/// unit-testable. Unknown top-level keys are ignored; a wrong shape (non-object
/// root, non-string resource path, non-string field entry, etc.) yields
/// `error.InvalidConfig` so the caller can surface a `config_error`.
pub fn parseExtJson(arena: std.mem.Allocator, bytes: []const u8) error{InvalidConfig}!ParsedExt {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return error.InvalidConfig;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };
    var out: ParsedExt = .{};
    if (obj.get("extra_resources")) |v| {
        const s = try joinResources(arena, v);
        if (s.len > 0) out.extra_resources = s;
    }
    if (obj.get("allowed_fields")) |v| {
        const s = try joinStringArray(arena, v);
        if (s.len > 0) out.allowed_fields = s;
    }
    if (obj.get("high_risk_fields")) |v| {
        const s = try joinStringArray(arena, v);
        if (s.len > 0) out.high_risk_fields = s;
    }
    if (obj.get("read_sensitive_fields")) |v| {
        const s = try joinStringArray(arena, v);
        if (s.len > 0) out.read_sensitive_fields = s;
    }
    if (obj.get("creatable_resources")) |v| {
        const s = try joinStringArray(arena, v);
        if (s.len > 0) out.creatable_resources = s;
    }
    return out;
}

// Join an `extra_resources` object into `type=path,...`. An empty object is a
// no-op (returns ""); a wrong shape or an empty key/path is a typo and errors.
fn joinResources(arena: std.mem.Allocator, v: std.json.Value) error{InvalidConfig}![]const u8 {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };
    var buf: std.ArrayList(u8) = .empty;
    var it = obj.iterator();
    var first = true;
    while (it.next()) |e| {
        const path = switch (e.value_ptr.*) {
            .string => |s| s,
            else => return error.InvalidConfig,
        };
        const key = std.mem.trim(u8, e.key_ptr.*, " \t");
        const ep = std.mem.trim(u8, path, " \t/");
        if (key.len == 0 or ep.len == 0) return error.InvalidConfig;
        if (!first) buf.append(arena, ',') catch return error.InvalidConfig;
        first = false;
        buf.appendSlice(arena, key) catch return error.InvalidConfig;
        buf.append(arena, '=') catch return error.InvalidConfig;
        buf.appendSlice(arena, ep) catch return error.InvalidConfig;
    }
    return buf.items;
}

// Join a string array into `a,b,c`. An empty array is a no-op (returns ""); a
// non-array, a non-string element, or an empty-string element errors as a typo.
fn joinStringArray(arena: std.mem.Allocator, v: std.json.Value) error{InvalidConfig}![]const u8 {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.InvalidConfig,
    };
    var buf: std.ArrayList(u8) = .empty;
    var first = true;
    for (arr.items) |item| {
        const tok = switch (item) {
            .string => |s| std.mem.trim(u8, s, " \t"),
            else => return error.InvalidConfig,
        };
        if (tok.len == 0) return error.InvalidConfig;
        if (!first) buf.append(arena, ',') catch return error.InvalidConfig;
        first = false;
        buf.appendSlice(arena, tok) catch return error.InvalidConfig;
    }
    return buf.items;
}

/// Clone `base` (the process environment) and overlay the four governance keys
/// with `union(env, file)` so the file extends — never replaces — the env. The
/// returned map is allocated with `arena` (lives for the whole run). Env values
/// are kept first so the env wins on any `extra_resources` key conflict.
pub fn mergeEnv(arena: std.mem.Allocator, base: *const Environ.Map, ext: ParsedExt) !*Environ.Map {
    const m = try arena.create(Environ.Map);
    m.* = try base.clone(arena);
    try overlayUnion(arena, m, env_extra_resources, ext.extra_resources);
    try overlayUnion(arena, m, env_allowed_fields, ext.allowed_fields);
    try overlayUnion(arena, m, env_high_risk_fields, ext.high_risk_fields);
    try overlayUnion(arena, m, env_read_sensitive_fields, ext.read_sensitive_fields);
    try overlayUnion(arena, m, env_creatable_resources, ext.creatable_resources);
    return m;
}

fn overlayUnion(arena: std.mem.Allocator, m: *Environ.Map, key: []const u8, file_val: ?[]const u8) !void {
    const fv = file_val orelse return;
    if (fv.len == 0) return;
    if (m.get(key)) |env_val| {
        if (env_val.len == 0) {
            try m.put(key, fv);
            return;
        }
        const joined = try std.fmt.allocPrint(arena, "{s},{s}", .{ env_val, fv });
        try m.put(key, joined);
    } else {
        try m.put(key, fv);
    }
}

fn parseU64(v: ?[]const u8) ?u64 {
    const s = v orelse return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

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

test "parseU64" {
    try std.testing.expectEqual(@as(?u64, 15000), parseU64("15000"));
    try std.testing.expectEqual(@as(?u64, 0), parseU64("0"));
    try std.testing.expectEqual(@as(?u64, null), parseU64(null));
    try std.testing.expectEqual(@as(?u64, null), parseU64("oops"));
}

test "parseExtJson extracts governance keys in env syntax" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json =
        \\{
        \\  "extra_resources": { "site": "dcim/sites", "tenant": "/tenancy/tenants/" },
        \\  "allowed_fields": ["serial", "asset_tag"],
        \\  "high_risk_fields": ["tenant"],
        \\  "read_sensitive_fields": ["serial", "asset_tag"],
        \\  "creatable_resources": ["site", "vlan"],
        \\  "unknown_key": 123
        \\}
    ;
    const ext = try parseExtJson(a, json);
    try std.testing.expectEqualStrings("site=dcim/sites,tenant=tenancy/tenants", ext.extra_resources.?);
    try std.testing.expectEqualStrings("serial,asset_tag", ext.allowed_fields.?);
    try std.testing.expectEqualStrings("tenant", ext.high_risk_fields.?);
    try std.testing.expectEqualStrings("serial,asset_tag", ext.read_sensitive_fields.?);
    try std.testing.expectEqualStrings("site,vlan", ext.creatable_resources.?);
}

test "parseExtJson tolerates missing keys and empty object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ext = try parseExtJson(a, "{}");
    try std.testing.expect(ext.isEmpty());
    const ext2 = try parseExtJson(a, "{ \"allowed_fields\": [\"serial\"] }");
    try std.testing.expect(ext2.extra_resources == null);
    try std.testing.expectEqualStrings("serial", ext2.allowed_fields.?);
}

test "parseExtJson rejects malformed shapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "not json"));
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "[1,2,3]"));
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"allowed_fields\": \"serial\" }"));
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"allowed_fields\": [1] }"));
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"allowed_fields\": [\"\"] }"));
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"extra_resources\": { \"site\": 5 } }"));
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"extra_resources\": { \"site\": \"\" } }"));
}

test "parseExtJson treats empty collections as no-op" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ext = try parseExtJson(a, "{ \"allowed_fields\": [], \"extra_resources\": {}, \"high_risk_fields\": [], \"read_sensitive_fields\": [], \"creatable_resources\": [] }");
    try std.testing.expect(ext.isEmpty());
}

test "mergeEnv unions file values with env, env first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var base = Environ.Map.init(a);
    try base.put("NBX_GUARD_ALLOWED_FIELDS", "dns_name");
    try base.put("NBX_GUARD_EXTRA_RESOURCES", "site=dcim/sites");

    const ext: ParsedExt = .{
        .extra_resources = "tenant=tenancy/tenants",
        .allowed_fields = "serial",
        .high_risk_fields = "primary_ip4",
        .read_sensitive_fields = "serial",
        .creatable_resources = "site",
    };
    const merged = try mergeEnv(a, &base, ext);

    // env value kept first, file appended.
    try std.testing.expectEqualStrings("dns_name,serial", merged.get("NBX_GUARD_ALLOWED_FIELDS").?);
    try std.testing.expectEqualStrings("site=dcim/sites,tenant=tenancy/tenants", merged.get("NBX_GUARD_EXTRA_RESOURCES").?);
    // key absent in env -> file value used directly.
    try std.testing.expectEqualStrings("primary_ip4", merged.get("NBX_GUARD_HIGH_RISK_FIELDS").?);
    try std.testing.expectEqualStrings("serial", merged.get("NBX_GUARD_READ_SENSITIVE_FIELDS").?);
    try std.testing.expectEqualStrings("site", merged.get("NBX_GUARD_CREATABLE_RESOURCES").?);
    // base is untouched.
    try std.testing.expectEqualStrings("dns_name", base.get("NBX_GUARD_ALLOWED_FIELDS").?);
}
