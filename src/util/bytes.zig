const std = @import("std");

/// Read a big-endian u32 from a 4-byte slice.
pub fn readU32BE(buf: *const [4]u8) u32 {
    return std.mem.readInt(u32, buf, .big);
}

/// Write a big-endian u32 into a 4-byte slice.
pub fn writeU32BE(buf: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, buf, value, .big);
}

/// Read a big-endian i32.
pub fn readI32BE(buf: *const [4]u8) i32 {
    return std.mem.readInt(i32, buf, .big);
}

pub fn writeI32BE(buf: *[4]u8, value: i32) void {
    std.mem.writeInt(i32, buf, value, .big);
}

pub fn readU16BE(buf: *const [2]u8) u16 {
    return std.mem.readInt(u16, buf, .big);
}

pub fn writeU16BE(buf: *[2]u8, value: u16) void {
    std.mem.writeInt(u16, buf, value, .big);
}

/// Little-endian helpers for on-disk WAL.
pub fn readU32LE(buf: *const [4]u8) u32 {
    return std.mem.readInt(u32, buf, .little);
}

pub fn writeU32LE(buf: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, buf, value, .little);
}

pub fn readU16LE(buf: *const [2]u8) u16 {
    return std.mem.readInt(u16, buf, .little);
}

pub fn writeU16LE(buf: *[2]u8, value: u16) void {
    std.mem.writeInt(u16, buf, value, .little);
}

pub fn readI64LE(buf: *const [8]u8) i64 {
    return std.mem.readInt(i64, buf, .little);
}

pub fn writeI64LE(buf: *[8]u8, value: i64) void {
    std.mem.writeInt(i64, buf, value, .little);
}

test "endian roundtrip" {
    var b4: [4]u8 = undefined;
    writeU32BE(&b4, 0x01020304);
    try std.testing.expectEqual(@as(u32, 0x01020304), readU32BE(&b4));
    writeU32LE(&b4, 0x01020304);
    try std.testing.expectEqual(@as(u32, 0x01020304), readU32LE(&b4));
}
