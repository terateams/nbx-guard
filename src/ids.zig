//! ID and hash generation utilities.
const std = @import("std");

/// Lowercase hex SHA-256 of `data`. Caller owns returned memory.
pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

/// Generate a unique, sortable id of the form `<prefix>_<seconds>_<rand6hex>`.
/// `now_ns` should be a real-clock timestamp in nanoseconds.
pub fn genId(allocator: std.mem.Allocator, prefix: []const u8, now_ns: i128) ![]u8 {
    const secs: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));
    var seed: u64 = @bitCast(@as(i64, @truncate(now_ns)));
    seed ^= @as(u64, @intCast(secs)) *% 0x9E3779B97F4A7C15;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random().int(u24);
    const rhex = std.fmt.bytesToHex(std.mem.toBytes(rnd)[0..3].*, .lower);
    return std.fmt.allocPrint(allocator, "{s}_{d}_{s}", .{ prefix, secs, &rhex });
}

test "sha256Hex is stable and 64 chars" {
    const a = std.testing.allocator;
    const h1 = try sha256Hex(a, "hello");
    defer a.free(h1);
    const h2 = try sha256Hex(a, "hello");
    defer a.free(h2);
    try std.testing.expectEqual(@as(usize, 64), h1.len);
    try std.testing.expectEqualStrings(h1, h2);
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        h1,
    );
}

test "genId has prefix" {
    const a = std.testing.allocator;
    const id = try genId(a, "plan", 1_700_000_000_000_000_000);
    defer a.free(id);
    try std.testing.expect(std.mem.startsWith(u8, id, "plan_"));
}
