//! LSM key and value encoding.
//!
//! The SSTable layer stores opaque byte-sorted entries; this module owns the
//! mapping between table rows and those bytes. It encodes primary keys as
//! order-preserving user keys (so a bytewise comparison orders rows the same
//! way `value.Value.order` does), packs an MVCC sequence number and value type
//! into an internal-key suffix (newest sequence first), and encodes row values
//! into self-contained byte strings.
//!
//! Only single-column integer/text primary keys are addressable by the LSM
//! (the same set `table.zig` can index); heap tables stay in memory and in the
//! WAL. Primary keys of other type tags are rejected by schema validation, so
//! the codec never sees them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("../value.zig");

/// Value type recorded in the internal-key suffix. A tombstone marks a key
/// that was live in an earlier SSTable but is deleted in the current flush;
/// compaction resolves tombstones by dropping the key entirely.
pub const ValueType = enum(u8) {
    put = 0,
    delete = 1,
};

/// Number of suffix bytes in an internal key: one u64 encoding
/// `(seq << 8) | value_type`, bitwise-complemented and big-endian so that
/// within one user key, a higher sequence sorts first (newest version first).
pub const suffix_len = 8;

/// Encode an integer primary key as an order-preserving 8-byte user key.
/// Flipping the sign bit maps signed order onto unsigned byte order, so
/// `std.mem.order` on the result matches `value.Value.order` for ints.
pub fn encodeIntKey(i: i64) [8]u8 {
    const raw: u64 = @bitCast(i);
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, raw ^ 0x8000_0000_0000_0000, .big);
    return out;
}

/// Decode an integer user key produced by `encodeIntKey`.
pub fn decodeIntKey(bytes: [8]u8) i64 {
    const raw = std.mem.readInt(u64, &bytes, .big);
    return @bitCast(raw ^ 0x8000_0000_0000_0000);
}

/// Encode the sequence/value-type suffix for an internal key.
fn encodeSuffix(seq: u64, value_type: ValueType) [8]u8 {
    const seq_and_type = (seq << 8) | @as(u64, @intFromEnum(value_type));
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, ~seq_and_type, .big);
    return out;
}

/// The seek suffix: the largest possible suffix, so a seek key sorts after
/// every internal key of the same user key and before any larger user key.
fn seekSuffix() [8]u8 {
    return [_]u8{0} ** 8;
}

/// Parse a suffix into its sequence and value type.
pub fn parseSuffix(bytes: [8]u8) struct { seq: u64, value_type: ValueType } {
    const seq_and_type = ~std.mem.readInt(u64, &bytes, .big);
    return .{
        .seq = seq_and_type >> 8,
        .value_type = @enumFromInt(seq_and_type & 1),
    };
}

/// Build an internal key: `user_key` followed by the sequence suffix.
/// The caller owns the result.
pub fn internalKey(gpa: Allocator, user_key: []const u8, seq: u64, value_type: ValueType) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, user_key.len + suffix_len);
    @memcpy(out[0..user_key.len], user_key);
    @memcpy(out[user_key.len..], &encodeSuffix(seq, value_type));
    return out;
}

/// Build the seek key for a user key: sorts before every internal key with the
/// same user key (it carries the minimum possible suffix). Used by point
/// lookups to locate the block that may contain the key. The caller owns the
/// result.
pub fn seekKey(gpa: Allocator, user_key: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, user_key.len + suffix_len);
    @memcpy(out[0..user_key.len], user_key);
    @memcpy(out[user_key.len..], &seekSuffix());
    return out;
}

/// The user-key portion of an internal key (all but the suffix).
pub fn userKeyOf(internal: []const u8) []const u8 {
    std.debug.assert(internal.len >= suffix_len);
    return internal[0 .. internal.len - suffix_len];
}

/// Whether internal key `a` sorts before `b` (bytewise, so user key ascending
/// then sequence descending).
pub fn internalLessThan(a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── Row value encoding ──

const tag_null: u8 = 0;
const tag_int: u8 = 1;
const tag_text: u8 = 2;
const tag_bool: u8 = 3;
const tag_vector: u8 = 4;

fn writeU16(list: *std.ArrayList(u8), gpa: Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn writeU32(list: *std.ArrayList(u8), gpa: Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn writeU64(list: *std.ArrayList(u8), gpa: Allocator, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn readU16(bytes: []const u8, pos: *usize) error{InvalidLsmValue}!u16 {
    if (bytes.len -| pos.* < 2) return error.InvalidLsmValue;
    const v = std.mem.readInt(u16, bytes[pos.*..][0..2], .little);
    pos.* += 2;
    return v;
}

fn readU32(bytes: []const u8, pos: *usize) error{InvalidLsmValue}!u32 {
    if (bytes.len -| pos.* < 4) return error.InvalidLsmValue;
    const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

/// Encode a row's values into a self-contained byte string: a u16 column
/// count followed by one typed value per column. The caller owns the result.
pub fn encodeRow(gpa: Allocator, values: []const value.Value) (Allocator.Error || error{ NameTooLong, InvalidLsmValue })![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (values.len > std.math.maxInt(u16)) return error.NameTooLong;
    try writeU16(&out, gpa, @intCast(values.len));
    for (values) |v| {
        switch (v) {
            .null => try out.append(gpa, tag_null),
            .int => |i| {
                try out.append(gpa, tag_int);
                var b: [8]u8 = undefined;
                std.mem.writeInt(i64, &b, i, .little);
                try out.appendSlice(gpa, &b);
            },
            .text => |t| {
                try out.append(gpa, tag_text);
                if (t.len > std.math.maxInt(u16)) return error.NameTooLong;
                try writeU16(&out, gpa, @intCast(t.len));
                try out.appendSlice(gpa, t);
            },
            .bool => |b| {
                try out.append(gpa, tag_bool);
                try out.append(gpa, if (b) 1 else 0);
            },
            .vector => |items| {
                value.validateVector(items) catch return error.InvalidLsmValue;
                if (items.len > std.math.maxInt(u16)) return error.NameTooLong;
                try out.append(gpa, tag_vector);
                try writeU16(&out, gpa, @intCast(items.len));
                for (items) |item| {
                    var b: [4]u8 = undefined;
                    std.mem.writeInt(u32, &b, @bitCast(item), .little);
                    try out.appendSlice(gpa, &b);
                }
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Decode a row encoding produced by `encodeRow`. The caller owns the values.
pub fn decodeRow(gpa: Allocator, bytes: []const u8) error{ InvalidLsmValue, NameTooLong, OutOfMemory }![]value.Value {
    var pos: usize = 0;
    const count = try readU16(bytes, &pos);
    const values = try gpa.alloc(value.Value, count);
    errdefer gpa.free(values);
    var decoded: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < decoded) : (i += 1) values[i].deinit(gpa);
    }
    while (decoded < count) : (decoded += 1) {
        if (pos >= bytes.len) return error.InvalidLsmValue;
        const tag = bytes[pos];
        pos += 1;
        values[decoded] = switch (tag) {
            tag_null => .null,
            tag_int => blk: {
                if (bytes.len -| pos < 8) return error.InvalidLsmValue;
                const i = std.mem.readInt(i64, bytes[pos..][0..8], .little);
                pos += 8;
                break :blk .{ .int = i };
            },
            tag_text => blk: {
                const len = try readU16(bytes, &pos);
                if (bytes.len -| pos < len) return error.InvalidLsmValue;
                const t = try gpa.dupe(u8, bytes[pos .. pos + len]);
                pos += len;
                break :blk .{ .text = t };
            },
            tag_bool => blk: {
                if (pos >= bytes.len) return error.InvalidLsmValue;
                const b = bytes[pos] != 0;
                pos += 1;
                break :blk .{ .bool = b };
            },
            tag_vector => blk: {
                const len = try readU16(bytes, &pos);
                if (len == 0 or bytes.len -| pos < @as(usize, len) * 4) return error.InvalidLsmValue;
                const items = try gpa.alloc(f32, len);
                errdefer gpa.free(items);
                for (items) |*item| {
                    item.* = @bitCast(std.mem.readInt(u32, bytes[pos..][0..4], .little));
                    pos += 4;
                }
                value.validateVector(items) catch return error.InvalidLsmValue;
                break :blk .{ .vector = items };
            },
            else => return error.InvalidLsmValue,
        };
    }
    if (pos != bytes.len) return error.InvalidLsmValue;
    return values;
}

test "int user keys order like their values" {
    const gpa = std.testing.allocator;
    const keys = [_]i64{ std.math.minInt(i64), -1000, -1, 0, 1, 42, std.math.maxInt(i64) };
    var encoded: [keys.len][8]u8 = undefined;
    for (keys, 0..) |k, i| encoded[i] = encodeIntKey(k);

    var i: usize = 0;
    while (i + 1 < keys.len) : (i += 1) {
        try std.testing.expect(std.mem.order(u8, &encoded[i], &encoded[i + 1]) == .lt);
        try std.testing.expectEqual(keys[i], decodeIntKey(encoded[i]));
    }
    try std.testing.expectEqual(keys[keys.len - 1], decodeIntKey(encoded[keys.len - 1]));
    _ = gpa;
}

test "internal keys sort newest sequence first within a user key" {
    const gpa = std.testing.allocator;
    const a1 = try internalKey(gpa, "alice", 1, .put);
    defer gpa.free(a1);
    const a5 = try internalKey(gpa, "alice", 5, .put);
    defer gpa.free(a5);
    const a3d = try internalKey(gpa, "alice", 3, .delete);
    defer gpa.free(a3d);
    const bob = try internalKey(gpa, "bob", 2, .put);
    defer gpa.free(bob);

    // Newest sequence first within one user key; user keys in byte order.
    try std.testing.expect(internalLessThan(a5, a3d));
    try std.testing.expect(internalLessThan(a3d, a1));
    try std.testing.expect(internalLessThan(a1, bob));

    // Suffix round trip.
    const parsed = parseSuffix(a5[a5.len - 8 ..][0..8].*);
    try std.testing.expectEqual(@as(u64, 5), parsed.seq);
    try std.testing.expectEqual(ValueType.put, parsed.value_type);
    const parsed_delete = parseSuffix(a3d[a3d.len - 8 ..][0..8].*);
    try std.testing.expectEqual(ValueType.delete, parsed_delete.value_type);

    // A seek key sorts before every internal key of its user key and before
    // the next user key.
    const seek = try seekKey(gpa, "alice");
    defer gpa.free(seek);
    try std.testing.expect(internalLessThan(seek, a1));
    try std.testing.expect(internalLessThan(seek, a5));
    try std.testing.expect(internalLessThan(a1, bob));
    try std.testing.expectEqualStrings("alice", userKeyOf(a5));
}

test "row encoding round trips every value type" {
    const gpa = std.testing.allocator;
    var vals = [_]value.Value{
        .null,
        .{ .int = -42 },
        .{ .text = try gpa.dupe(u8, "hello lsm") },
        .{ .bool = true },
        .{ .vector = try gpa.dupe(f32, &.{ 0.5, -1.25, 3 }) },
    };
    defer for (&vals) |*v| v.deinit(gpa);

    const encoded = try encodeRow(gpa, &vals);
    defer gpa.free(encoded);
    const decoded = try decodeRow(gpa, encoded);
    defer {
        for (decoded) |*v| v.deinit(gpa);
        gpa.free(decoded);
    }
    try std.testing.expectEqual(@as(usize, 5), decoded.len);
    for (vals, decoded) |expected, actual| {
        try std.testing.expect(expected.eql(actual));
    }
}

test "row decoding rejects truncated and trailing bytes" {
    const gpa = std.testing.allocator;
    var vals = [_]value.Value{ .{ .int = 7 }, .null };
    const encoded = try encodeRow(gpa, &vals);
    defer gpa.free(encoded);

    try std.testing.expectError(error.InvalidLsmValue, decodeRow(gpa, encoded[0 .. encoded.len - 1]));
    var padded = try gpa.dupe(u8, encoded);
    defer gpa.free(padded);
    padded = try gpa.realloc(padded, padded.len + 1);
    padded[padded.len - 1] = 0;
    try std.testing.expectError(error.InvalidLsmValue, decodeRow(gpa, padded));
}
