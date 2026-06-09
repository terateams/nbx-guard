//! Runtime configuration, loaded from environment variables.
const std = @import("std");

const Environ = std.process.Environ;

pub const Config = struct {
    /// NetBox base URL, e.g. `https://netbox.example.com`.
    netbox_url: []const u8 = "http://localhost:8000",
    /// NetBox API token. Writes are impossible without it. May be supplied
    /// directly (`NETBOX_TOKEN`), or resolved at runtime from a file
    /// (`NETBOX_TOKEN_FILE`) or a command (`NETBOX_TOKEN_CMD`); after
    /// resolution this holds the effective token regardless of its source.
    netbox_token: ?[]const u8 = null,
    /// Path of a file whose contents are the NetBox token (trailing whitespace
    /// trimmed). Keychain/secret-manager friendly: Docker/k8s secrets, systemd
    /// credentials, a Vault-agent rendered file, etc. Lower precedence than
    /// `NETBOX_TOKEN`.
    netbox_token_file: ?[]const u8 = null,
    /// Shell command whose stdout is the NetBox token (trailing whitespace
    /// trimmed). The direct hook into an OS keychain — e.g. macOS
    /// `security find-generic-password -w`, Linux `secret-tool lookup ...`, or
    /// `pass show netbox/token`. Lower precedence than `NETBOX_TOKEN`, higher
    /// than `NETBOX_TOKEN_FILE`.
    netbox_token_cmd: ?[]const u8 = null,
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
            .netbox_token = nonEmpty(env.get("NETBOX_TOKEN")),
            .netbox_token_file = nonEmpty(env.get("NETBOX_TOKEN_FILE")),
            .netbox_token_cmd = nonEmpty(env.get("NETBOX_TOKEN_CMD")),
            .state_dir = env.get("NBX_GUARD_STATE_DIR") orelse ".nbx-guard",
            .branching = parseBool(env.get("NBX_GUARD_BRANCHING")),
            .branch = env.get("NBX_GUARD_BRANCH"),
            .http_timeout_ms = parseU64(env.get("NBX_GUARD_HTTP_TIMEOUT_MS")) orelse 15000,
        };
    }
};

// -- operator config file (~/.nbx-guard/config.json) --------------------------
//
// The one-file alternative to exporting a pile of NBX_GUARD_* / NETBOX_* env vars:
// an operator keeps the whole setup in a single JSON file. It holds two kinds of
// keys — connection/runtime settings and governance extensions:
//
//     {
//       "netbox_url":           "https://netbox.example.com",
//       "token_cmd":            "security find-generic-password -s netbox -w",
//       "auto_approve":         false,
//       "state_dir":            ".nbx-guard",
//       "branching":            false,
//       "extra_resources":      { "site": "dcim/sites", "tenant": "tenancy/tenants" },
//       "allowed_fields":       ["serial", "asset_tag"],
//       "high_risk_fields":     ["tenant"],
//       "read_sensitive_fields": ["serial"],
//       "creatable_resources":  ["site", "vlan"]
//     }
//
// Precedence is always "environment wins": any value set in the env overrides the
// file, so the file is a convenient default, not a lock. Governance keys *extend*
// (union, env first); connection keys are scalars (env replaces file). The one
// thing the file must never hold is the raw secret: a `netbox_token` key is
// refused (error.SecretInConfig). Point at a keychain with `token_cmd`, a file
// with `token_file`, or keep NETBOX_TOKEN in the environment. Built-in field
// classification always wins over both env and file.

/// Keys the config file can populate, in env-string syntax, so the connection keys
/// overlay `Config` and the governance keys union into the process environment for
/// the existing env-driven readers (netbox.extraEndpoint / policy.classifyFieldEnv)
/// unchanged. Connection scalars carry the file value verbatim ("1"/null for flags,
/// a decimal string for the timeout); the caller applies env-wins precedence.
pub const ParsedExt = struct {
    // -- connection / runtime (overlay Config when the matching env var is unset) --
    /// NetBox base URL for `netbox_url` (trailing slash stripped; null = key absent).
    netbox_url: ?[]const u8 = null,
    /// File path for `token_file` (null = key absent). A pointer, not a secret.
    netbox_token_file: ?[]const u8 = null,
    /// Keychain command for `token_cmd` (null = key absent). A pointer, not a secret.
    netbox_token_cmd: ?[]const u8 = null,
    /// State directory for `state_dir` (null = key absent).
    state_dir: ?[]const u8 = null,
    /// Branch schema id for `branch` (null = key absent).
    branch: ?[]const u8 = null,
    /// "1" for `branching: true` (null = key absent or false).
    branching: ?[]const u8 = null,
    /// Decimal milliseconds for `http_timeout_ms` (null = key absent).
    http_timeout_ms: ?[]const u8 = null,

    // -- governance (union into the NBX_GUARD_* environment) --
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
    /// "1" to populate NBX_GUARD_AUTO_APPROVE (null = key absent). Auto-approves
    /// the change-approval gate (high-risk update + create) while keeping the
    /// full audit trail. Operator-only; meant for branch/sandbox work.
    auto_approve: ?[]const u8 = null,

    pub fn isEmpty(self: ParsedExt) bool {
        return self.netbox_url == null and self.netbox_token_file == null and
            self.netbox_token_cmd == null and self.state_dir == null and
            self.branch == null and self.branching == null and
            self.http_timeout_ms == null and self.extra_resources == null and
            self.allowed_fields == null and self.high_risk_fields == null and
            self.read_sensitive_fields == null and self.creatable_resources == null and
            self.auto_approve == null;
    }
};

pub const env_extra_resources = "NBX_GUARD_EXTRA_RESOURCES";
pub const env_allowed_fields = "NBX_GUARD_ALLOWED_FIELDS";
pub const env_high_risk_fields = "NBX_GUARD_HIGH_RISK_FIELDS";
pub const env_read_sensitive_fields = "NBX_GUARD_READ_SENSITIVE_FIELDS";
pub const env_creatable_resources = "NBX_GUARD_CREATABLE_RESOURCES";
pub const env_auto_approve = "NBX_GUARD_AUTO_APPROVE";

/// Parse the operator config JSON into env-string fragments. Pure (no IO) so it is
/// unit-testable. Unknown top-level keys are ignored; a wrong shape (non-object
/// root, non-string resource path, non-string field entry, etc.) yields
/// `error.InvalidConfig`, and a raw secret (`netbox_token`) yields
/// `error.SecretInConfig`, so the caller can surface a precise `config_error`.
pub fn parseExtJson(arena: std.mem.Allocator, bytes: []const u8) error{ InvalidConfig, SecretInConfig }!ParsedExt {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return error.InvalidConfig;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };
    // The raw token must never live in the file — point at a keychain/file instead.
    if (obj.get("netbox_token") != null or obj.get("token") != null) return error.SecretInConfig;
    var out: ParsedExt = .{};
    if (try jsonString(obj.get("netbox_url"))) |s| out.netbox_url = stripTrailingSlash(s);
    if (try jsonString(obj.get("token_file"))) |s| out.netbox_token_file = s;
    if (try jsonString(obj.get("token_cmd"))) |s| out.netbox_token_cmd = s;
    if (try jsonString(obj.get("state_dir"))) |s| out.state_dir = s;
    if (try jsonString(obj.get("branch"))) |s| out.branch = s;
    if (obj.get("branching")) |v| {
        out.branching = switch (v) {
            .bool => |b| if (b) "1" else null,
            else => return error.InvalidConfig,
        };
    }
    if (obj.get("http_timeout_ms")) |v| {
        out.http_timeout_ms = switch (v) {
            .integer => |n| if (n >= 0) std.fmt.allocPrint(arena, "{d}", .{n}) catch return error.InvalidConfig else return error.InvalidConfig,
            else => return error.InvalidConfig,
        };
    }
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
    if (obj.get("auto_approve")) |v| {
        out.auto_approve = switch (v) {
            .bool => |b| if (b) "1" else null,
            else => return error.InvalidConfig,
        };
    }
    return out;
}

// A scalar string config value: trimmed; an empty string is treated as absent
// (null) so a placeholder like "token_cmd": "" is a harmless no-op. A non-string
// is a typo and errors.
fn jsonString(maybe: ?std.json.Value) error{InvalidConfig}!?[]const u8 {
    const v = maybe orelse return null;
    return switch (v) {
        .string => |s| blk: {
            const t = std.mem.trim(u8, s, " \t");
            break :blk if (t.len == 0) null else t;
        },
        else => error.InvalidConfig,
    };
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
    try overlayFlag(m, env_auto_approve, ext.auto_approve);
    return m;
}

// Overlay a boolean enable-flag: the env wins if present (any value), otherwise
// the file value is used. Unlike `overlayUnion` it never comma-joins — a flag is
// matched whole by `parseBool`, so "1,1" would silently disable it.
fn overlayFlag(m: *Environ.Map, key: []const u8, file_val: ?[]const u8) !void {
    const fv = file_val orelse return;
    if (fv.len == 0) return;
    if (m.get(key) != null) return;
    try m.put(key, fv);
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

/// Treat an empty environment value the same as unset, so `export NETBOX_TOKEN=`
/// (or an empty token file/cmd var) does not masquerade as a configured value.
fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
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
        \\  "auto_approve": true,
        \\  "unknown_key": 123
        \\}
    ;
    const ext = try parseExtJson(a, json);
    try std.testing.expectEqualStrings("site=dcim/sites,tenant=tenancy/tenants", ext.extra_resources.?);
    try std.testing.expectEqualStrings("serial,asset_tag", ext.allowed_fields.?);
    try std.testing.expectEqualStrings("tenant", ext.high_risk_fields.?);
    try std.testing.expectEqualStrings("serial,asset_tag", ext.read_sensitive_fields.?);
    try std.testing.expectEqualStrings("site,vlan", ext.creatable_resources.?);
    try std.testing.expectEqualStrings("1", ext.auto_approve.?);
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
        .auto_approve = "1",
    };
    const merged = try mergeEnv(a, &base, ext);

    // env value kept first, file appended.
    try std.testing.expectEqualStrings("dns_name,serial", merged.get("NBX_GUARD_ALLOWED_FIELDS").?);
    try std.testing.expectEqualStrings("site=dcim/sites,tenant=tenancy/tenants", merged.get("NBX_GUARD_EXTRA_RESOURCES").?);
    // key absent in env -> file value used directly.
    try std.testing.expectEqualStrings("primary_ip4", merged.get("NBX_GUARD_HIGH_RISK_FIELDS").?);
    try std.testing.expectEqualStrings("serial", merged.get("NBX_GUARD_READ_SENSITIVE_FIELDS").?);
    try std.testing.expectEqualStrings("site", merged.get("NBX_GUARD_CREATABLE_RESOURCES").?);
    // boolean flag: not comma-joined, set whole from the file.
    try std.testing.expectEqualStrings("1", merged.get("NBX_GUARD_AUTO_APPROVE").?);
    // base is untouched.
    try std.testing.expectEqualStrings("dns_name", base.get("NBX_GUARD_ALLOWED_FIELDS").?);
}

test "mergeEnv keeps env auto_approve over the file (flag, no join)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var base = Environ.Map.init(a);
    try base.put(env_auto_approve, "0"); // operator explicitly disabled it in env
    const merged = try mergeEnv(a, &base, .{ .auto_approve = "1" });
    // env wins whole; never becomes "0,1" (which parseBool would read as false anyway).
    try std.testing.expectEqualStrings("0", merged.get(env_auto_approve).?);
}

test "parseExtJson auto_approve must be boolean" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect((try parseExtJson(a, "{ \"auto_approve\": false }")).auto_approve == null);
    try std.testing.expectEqualStrings("1", (try parseExtJson(a, "{ \"auto_approve\": true }")).auto_approve.?);
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"auto_approve\": \"yes\" }"));
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"auto_approve\": 1 }"));
}

test "parseExtJson parses connection keys (one-file setup)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json =
        \\{
        \\  "netbox_url": "https://nb.example.com/",
        \\  "token_cmd": "security find-generic-password -s netbox -w",
        \\  "token_file": "/run/secrets/netbox_token",
        \\  "state_dir": "/var/lib/nbx-guard",
        \\  "branching": true,
        \\  "branch": "abc12345",
        \\  "http_timeout_ms": 20000
        \\}
    ;
    const ext = try parseExtJson(a, json);
    try std.testing.expectEqualStrings("https://nb.example.com", ext.netbox_url.?); // trailing slash stripped
    try std.testing.expectEqualStrings("security find-generic-password -s netbox -w", ext.netbox_token_cmd.?);
    try std.testing.expectEqualStrings("/run/secrets/netbox_token", ext.netbox_token_file.?);
    try std.testing.expectEqualStrings("/var/lib/nbx-guard", ext.state_dir.?);
    try std.testing.expectEqualStrings("1", ext.branching.?);
    try std.testing.expectEqualStrings("abc12345", ext.branch.?);
    try std.testing.expectEqualStrings("20000", ext.http_timeout_ms.?);
}

test "parseExtJson treats empty/false connection values as absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ext = try parseExtJson(a, "{ \"netbox_url\": \"\", \"token_cmd\": \"   \", \"branching\": false }");
    try std.testing.expect(ext.isEmpty());
}

test "parseExtJson refuses a raw secret in the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.SecretInConfig, parseExtJson(a, "{ \"netbox_token\": \"nbt_x.y\" }"));
    try std.testing.expectError(error.SecretInConfig, parseExtJson(a, "{ \"token\": \"nbt_x.y\" }"));
}

test "parseExtJson rejects malformed connection shapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"netbox_url\": 5 }"));
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"branching\": \"yes\" }"));
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"http_timeout_ms\": \"20000\" }"));
    try std.testing.expectError(error.InvalidConfig, parseExtJson(a, "{ \"http_timeout_ms\": -1 }"));
}

test "nonEmpty treats empty string as unset" {
    try std.testing.expect(nonEmpty(null) == null);
    try std.testing.expect(nonEmpty("") == null);
    try std.testing.expectEqualStrings("tok", nonEmpty("tok").?);
}
