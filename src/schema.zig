//! Static, agent-facing schema catalog. Describes — per resource type — what
//! `nbxg` is allowed to do and the shape of the `--set` input, independent of
//! any live NetBox instance. It is deterministic and works offline.
//!
//! The authoritative *types / choices / required* for each field come from the
//! live NetBox instance (via an `OPTIONS` request, see netbox.zig); this module
//! supplies the governance layer (which fields nbxg lets an agent touch, and at
//! what risk) plus human/agent-readable input guidance and examples. The two are
//! merged by `describe` so the reported schema stays in sync with real NetBox.
const std = @import("std");
const policy = @import("policy.zig");

/// Documentation for a single governed field: how to express it on `--set`.
pub const FieldDoc = struct {
    name: []const u8,
    /// JSON value kind expected by `--set` (after value parsing).
    json_type: []const u8,
    /// Example `--set` token for this field.
    example: []const u8,
    note: []const u8 = "",
};

/// Per-resource-type description: endpoint, the governed fields, and examples.
pub const ResourceDoc = struct {
    key: []const u8,
    netbox_endpoint: []const u8,
    display: []const u8,
    summary: []const u8,
    /// Low-risk governed field names (apply directly, no approval).
    low: []const []const u8,
    /// High-risk governed field names (require an approved plan).
    high: []const []const u8,
    examples: []const []const u8,
};

/// `--set` value guidance, shared across resource types (a field expresses the
/// same way regardless of which resource it lives on).
pub const field_docs = [_]FieldDoc{
    .{ .name = "description", .json_type = "string", .example = "description=\"edge router\"" },
    .{ .name = "comments", .json_type = "string", .example = "comments=\"maintenance window sat 02:00\"" },
    .{ .name = "tags", .json_type = "array", .example = "tags='[\"core\",\"prod\"]'", .note = "JSON array of tag slugs (or {name|slug} objects)" },
    .{ .name = "custom_fields", .json_type = "object", .example = "custom_fields='{\"owner\":\"netops\"}'", .note = "JSON object of custom-field name -> value" },
    .{ .name = "status", .json_type = "choice", .example = "status=active", .note = "Slug value; run describe with a token to list valid choices" },
    .{ .name = "role", .json_type = "reference", .example = "role=access", .note = "Slug or numeric id of a role" },
    .{ .name = "site", .json_type = "reference", .example = "site=1", .note = "Numeric id (or slug) of a site" },
    .{ .name = "rack", .json_type = "reference", .example = "rack=3", .note = "Numeric id of a rack" },
    .{ .name = "prefix", .json_type = "string", .example = "prefix=10.0.0.0/24", .note = "CIDR notation" },
    .{ .name = "address", .json_type = "string", .example = "address=192.0.2.10/24", .note = "IP with mask, CIDR notation" },
};

pub fn fieldDoc(name: []const u8) ?FieldDoc {
    for (field_docs) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

/// The supported resource types and the governed fields applicable to each.
/// Applicability mirrors the NetBox 4.x model; the live `OPTIONS` check flags
/// any field that is not actually present on the instance (drift).
pub const resources = [_]ResourceDoc{
    .{
        .key = "device",
        .netbox_endpoint = "dcim/devices",
        .display = "Device",
        .summary = "A physical or virtual device in DCIM.",
        .low = &.{ "description", "comments", "tags", "custom_fields" },
        .high = &.{ "status", "role", "site", "rack" },
        .examples = &.{
            "nbxg plan device <id> --set description=\"edge router\"",
            "nbxg plan device <id> --set status=offline   # high-risk -> approve then apply",
        },
    },
    .{
        .key = "interface",
        .netbox_endpoint = "dcim/interfaces",
        .display = "Interface",
        .summary = "A network interface attached to a device.",
        .low = &.{ "description", "tags", "custom_fields" },
        .high = &.{},
        .examples = &.{
            "nbxg plan interface <id> --set description=\"uplink to spine-1\"",
            "nbxg plan interface <id> --set tags='[\"uplink\"]'",
        },
    },
    .{
        .key = "ip-address",
        .netbox_endpoint = "ipam/ip-addresses",
        .display = "IP Address",
        .summary = "An individual IP address in IPAM.",
        .low = &.{ "description", "comments", "tags", "custom_fields" },
        .high = &.{ "status", "role", "address" },
        .examples = &.{
            "nbxg plan ip-address <id> --set description=\"reserved for spine-1\"",
            "nbxg plan ip-address <id> --set status=deprecated   # high-risk -> approve",
        },
    },
    .{
        .key = "prefix",
        .netbox_endpoint = "ipam/prefixes",
        .display = "Prefix",
        .summary = "An IPv4/IPv6 network prefix in IPAM.",
        .low = &.{ "description", "comments", "tags", "custom_fields" },
        .high = &.{ "status", "role", "prefix" },
        .examples = &.{
            "nbxg plan prefix <id> --set description=\"prod server subnet\"",
            "nbxg plan prefix <id> --set status=deprecated   # high-risk -> approve",
        },
    },
    .{
        .key = "vlan",
        .netbox_endpoint = "ipam/vlans",
        .display = "VLAN",
        .summary = "A virtual LAN in IPAM.",
        .low = &.{ "description", "comments", "tags", "custom_fields" },
        .high = &.{ "status", "role", "site" },
        .examples = &.{
            "nbxg plan vlan <id> --set description=\"dmz\"",
            "nbxg plan vlan <id> --set status=deprecated   # high-risk -> approve",
        },
    },
};

pub fn lookup(key: []const u8) ?ResourceDoc {
    for (resources) |r| if (std.mem.eql(u8, r.key, key)) return r;
    return null;
}

const testing = std.testing;

test "every resource type maps to a netbox endpoint" {
    const netbox = @import("netbox.zig");
    for (resources) |r| {
        try testing.expect(netbox.endpoint(r.key) != null);
        try testing.expectEqualStrings(netbox.endpoint(r.key).?, r.netbox_endpoint);
    }
}

test "governed fields agree with the policy engine" {
    for (resources) |r| {
        for (r.low) |f| {
            try testing.expectEqual(policy.FieldClass.allowed, policy.classifyField(f));
            try testing.expect(fieldDoc(f) != null);
        }
        for (r.high) |f| {
            try testing.expectEqual(policy.FieldClass.high_risk, policy.classifyField(f));
            try testing.expect(fieldDoc(f) != null);
        }
    }
}

test "lookup resolves known and rejects unknown" {
    try testing.expect(lookup("device") != null);
    try testing.expectEqualStrings("dcim/devices", lookup("device").?.netbox_endpoint);
    try testing.expect(lookup("nope") == null);
}
