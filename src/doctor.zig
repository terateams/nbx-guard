//! Consistency diagnostics. Pure, offline helpers that let `nbxg doctor` compare
//! what the *installed binary* knows (its version, governed resource types and
//! policy fields, all compile-time constants) against what the *installed*
//! `SKILL.md` and repository source document. The CLI layer (cli.zig) supplies
//! the binary's self-knowledge and the on-disk document text; everything here is
//! deterministic and side-effect free so it can be unit tested in isolation.
const std = @import("std");
const ids = @import("ids.zig");

/// Markers that uniquely identify the lines in `SKILL.md` listing, respectively,
/// the supported resource types, the low-risk fields, and the high-risk fields.
/// Each documented list is rendered as backtick-quoted tokens after a colon.
pub const marker_resource_types = "**支持的资源类型**";
pub const marker_low_fields = "**低风险（";
pub const marker_high_fields = "**高风险（";

fn contains(set: []const []const u8, x: []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

/// Return the text following the first ASCII/CJK colon in `seg`, or all of `seg`
/// when it has no colon. Used to skip a documented list's label (which may itself
/// contain backtick-quoted words such as `approve`).
fn afterColon(seg: []const u8) []const u8 {
    if (std.mem.indexOf(u8, seg, "：")) |ci| return seg[ci + "：".len ..];
    if (std.mem.indexOfScalar(u8, seg, ':')) |ci| return seg[ci + 1 ..];
    return seg;
}

/// Extract the backtick-quoted tokens documented on the first line of `text`
/// containing `marker`, considering only the part of the line after its colon.
/// Tokens are de-duplicated preserving order. Returns `null` when no line
/// contains `marker` (e.g. the document uses different phrasing). Borrowed
/// slices point into `text`, which must outlive the result.
pub fn documentedTokens(arena: std.mem.Allocator, text: []const u8, marker: []const u8) !?[]const []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const seg = while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, marker)) |mi| break afterColon(line[mi + marker.len ..]);
    } else return null;

    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, seg, i, '`')) |open| {
        const after = open + 1;
        const close = std.mem.indexOfScalarPos(u8, seg, after, '`') orelse break;
        const tok = seg[after..close];
        if (tok.len > 0 and !contains(out.items, tok)) try out.append(arena, tok);
        i = close + 1;
    }
    return try out.toOwnedSlice(arena);
}

/// The result of comparing a binary-known set against a documented set.
pub const SetDiff = struct {
    /// Entries the binary supports but the document omits.
    binary_only: []const []const u8,
    /// Entries the document lists but the binary does not support.
    doc_only: []const []const u8,

    pub fn consistent(self: SetDiff) bool {
        return self.binary_only.len == 0 and self.doc_only.len == 0;
    }
};

/// Compute the symmetric difference between the binary's set and the documented
/// set. Order follows the input slices; both result slices live in `arena`.
pub fn diff(arena: std.mem.Allocator, binary: []const []const u8, docs: []const []const u8) !SetDiff {
    var binary_only: std.ArrayList([]const u8) = .empty;
    var doc_only: std.ArrayList([]const u8) = .empty;
    for (binary) |b| if (!contains(docs, b)) try binary_only.append(arena, b);
    for (docs) |d| if (!contains(binary, d)) try doc_only.append(arena, d);
    return .{
        .binary_only = try binary_only.toOwnedSlice(arena),
        .doc_only = try doc_only.toOwnedSlice(arena),
    };
}

/// Lowercase hex-encoded SHA-256 of `data`, allocated in `arena`. Lets `doctor`
/// fingerprint the installed `SKILL.md`/`README.md` so drift is detectable even
/// when the documents carry no explicit version string.
pub fn sha256Hex(arena: std.mem.Allocator, data: []const u8) ![]u8 {
    return ids.sha256Hex(arena, data);
}

/// Parse the `.version = "x.y.z"` field out of a `build.zig.zon` document, so
/// `doctor` can report the repository/source version when run from a checkout.
/// Returns a slice borrowed from `text`, or `null` when not found.
pub fn parseZonVersion(text: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, text, ".version") orelse return null;
    const open = std.mem.indexOfScalarPos(u8, text, ki, '"') orelse return null;
    const start = open + 1;
    const close = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    return text[start..close];
}

const testing = std.testing;

test "documentedTokens parses the resource-type list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text =
        \\intro line
        \\**支持的资源类型**：`device`、`interface`、`ip-address`、`prefix`、`vlan`、`contact`。
        \\trailing line
    ;
    const got = (try documentedTokens(arena.allocator(), text, marker_resource_types)).?;
    const want = [_][]const u8{ "device", "interface", "ip-address", "prefix", "vlan", "contact" };
    try testing.expectEqual(want.len, got.len);
    for (want, 0..) |w, idx| try testing.expectEqualStrings(w, got[idx]);
}

test "documentedTokens skips a label that itself contains backticks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The high-risk label embeds `approve`; it must NOT leak into the field set.
    const text = "- **高风险（必须经 `approve` 才能 apply）**：`status`、`role`、`groups`。";
    const got = (try documentedTokens(arena.allocator(), text, marker_high_fields)).?;
    const want = [_][]const u8{ "status", "role", "groups" };
    try testing.expectEqual(want.len, got.len);
    for (want, 0..) |w, idx| try testing.expectEqualStrings(w, got[idx]);
}

test "documentedTokens returns null when the marker is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try documentedTokens(arena.allocator(), "nothing here", marker_low_fields)) == null);
}

test "diff reports both directions of drift" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const binary = [_][]const u8{ "device", "interface", "contact" };
    const docs = [_][]const u8{ "device", "interface", "vlan" };
    const d = try diff(arena.allocator(), &binary, &docs);
    try testing.expect(!d.consistent());
    try testing.expectEqual(@as(usize, 1), d.binary_only.len);
    try testing.expectEqualStrings("contact", d.binary_only[0]);
    try testing.expectEqual(@as(usize, 1), d.doc_only.len);
    try testing.expectEqualStrings("vlan", d.doc_only[0]);
}

test "diff is consistent for equal sets regardless of order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const binary = [_][]const u8{ "a", "b", "c" };
    const docs = [_][]const u8{ "c", "a", "b" };
    const d = try diff(arena.allocator(), &binary, &docs);
    try testing.expect(d.consistent());
}

test "sha256Hex is 64 lowercase hex chars and stable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const h = try sha256Hex(arena.allocator(), "nbx-guard");
    try testing.expectEqual(@as(usize, 64), h.len);
    const h2 = try sha256Hex(arena.allocator(), "nbx-guard");
    try testing.expectEqualStrings(h, h2);
}

test "parseZonVersion extracts the version field" {
    const zon =
        \\.{
        \\    .name = .nbx_guard,
        \\    .version = "0.4.0",
        \\}
    ;
    try testing.expectEqualStrings("0.4.0", parseZonVersion(zon).?);
    try testing.expect(parseZonVersion(".{ .name = .x }") == null);
}
