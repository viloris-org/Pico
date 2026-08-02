//! Persistent LSM version-set manifest (roadmap Phase 5).
//!
//! The LSM manifest records the durable version set of every table that has
//! been flushed: the published watermark, the instance-wide next file number,
//! and per-table schema, serial counter, and SSTable file metadata (level,
//! size, and internal-key range). It is the persistent companion to the WAL:
//! recovery loads flushed tables from this manifest and their SSTables, then
//! replays only the WAL tail past the watermark.
//!
//! Unlike the checkpoint manifest (`storage/manifest.zig`), which validates a
//! checkpoint boundary over catalog objects, this manifest owns table storage
//! metadata. Both are written atomically through the VFS and use
//! self-identifying, versioned formats; unknown or corrupt complete manifests
//! fail recovery rather than being silently ignored.
//!
//! Each flush or compaction rewrites the manifest atomically (the VFS atomic
//! publication primitive). SSTable files are immutable, so a single snapshot
//! record is sufficient; append-style version_edit manifests are a documented
//! evolution option (docs/architecture/lsm-storage.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("../value.zig");

pub const file_magic = "RUNADB_LMV";
pub const format_version: u32 = 1;
const file_header_len = file_magic.len + 4;
const max_tables = 1_000_000;
const max_files = 10_000_000;

pub const Error = error{
    InvalidLsmManifest,
    UnsupportedLsmManifest,
    CorruptLsmManifest,
    NameTooLong,
} || Allocator.Error;

/// One SSTable file in a table's version set.
pub const FileMeta = struct {
    number: u64,
    level: u8,
    size: u64,
    first_key: []const u8,
    last_key: []const u8,
};

/// One flushed table's metadata. All slices are borrowed during encode and
/// owned by the decode caller afterwards.
pub const TableMeta = struct {
    name: []const u8,
    next_serial: i64,
    columns: []const value.Column,
    files: []const FileMeta,
};

/// The full durable version set snapshot.
pub const Snapshot = struct {
    watermark: u64,
    next_file_number: u64,
    tables: []const TableMeta,
};

/// Serialize a snapshot (LE) for publication. The caller owns the bytes.
pub fn encode(gpa: Allocator, snapshot: *const Snapshot) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, file_magic);
    try writeU32(&out, gpa, format_version);
    try writeU64(&out, gpa, snapshot.watermark);
    try writeU64(&out, gpa, snapshot.next_file_number);
    if (snapshot.tables.len > max_tables) return error.InvalidLsmManifest;
    try writeU32(&out, gpa, @intCast(snapshot.tables.len));
    for (snapshot.tables) |table| {
        if (table.name.len > std.math.maxInt(u16)) return error.NameTooLong;
        try writeU16(&out, gpa, @intCast(table.name.len));
        try out.appendSlice(gpa, table.name);
        try writeI64(&out, gpa, table.next_serial);
        if (table.columns.len > std.math.maxInt(u16)) return error.InvalidLsmManifest;
        try writeU16(&out, gpa, @intCast(table.columns.len));
        for (table.columns) |col| try encodeColumn(&out, gpa, col);
        if (table.files.len > max_files) return error.InvalidLsmManifest;
        try writeU64(&out, gpa, @intCast(table.files.len));
        for (table.files) |file| {
            try writeU64(&out, gpa, file.number);
            try out.append(gpa, file.level);
            try writeU64(&out, gpa, file.size);
            if (file.first_key.len > std.math.maxInt(u32) or file.last_key.len > std.math.maxInt(u32)) {
                return error.InvalidLsmManifest;
            }
            try writeU32(&out, gpa, @intCast(file.first_key.len));
            try out.appendSlice(gpa, file.first_key);
            try writeU32(&out, gpa, @intCast(file.last_key.len));
            try out.appendSlice(gpa, file.last_key);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Parse and validate a snapshot. The returned tables, columns, and file keys
/// are owned by the caller; free with `deinitSnapshot`.
pub fn decode(gpa: Allocator, bytes: []const u8) Error!Snapshot {
    var pos: usize = 0;
    if (bytes.len < file_header_len) return error.InvalidLsmManifest;
    if (!std.mem.eql(u8, bytes[0..file_magic.len], file_magic)) return error.InvalidLsmManifest;
    pos = file_magic.len;
    const version = try readU32(bytes, &pos);
    if (version != format_version) return error.UnsupportedLsmManifest;
    const watermark = try readU64(bytes, &pos);
    const next_file_number = try readU64(bytes, &pos);
    const n_tables = try readU32(bytes, &pos);
    if (n_tables > max_tables) return error.InvalidLsmManifest;

    var tables = try gpa.alloc(TableMeta, n_tables);
    errdefer gpa.free(tables);
    var table_count: usize = 0;
    errdefer for (tables[0..table_count]) |*t| deinitTableMeta(gpa, t);

    for (0..n_tables) |i| {
        const name_len = try readU16(bytes, &pos);
        if (bytes.len -| pos < name_len) return error.InvalidLsmManifest;
        const name = try gpa.dupe(u8, bytes[pos .. pos + name_len]);
        pos += name_len;
        const next_serial = try readI64(bytes, &pos);
        const n_columns = try readU16(bytes, &pos);
        const columns = try gpa.alloc(value.Column, n_columns);
        var column_count: usize = 0;
        errdefer {
            for (columns[0..column_count]) |*c| c.deinit(gpa);
            gpa.free(columns);
        }
        for (0..n_columns) |_| {
            columns[column_count] = try decodeColumn(gpa, bytes, &pos);
            column_count += 1;
        }
        const n_files = try readU64(bytes, &pos);
        if (n_files > max_files) return error.InvalidLsmManifest;
        const files = try gpa.alloc(FileMeta, @intCast(n_files));
        var file_count: usize = 0;
        errdefer {
            for (files[0..file_count]) |*f| {
                gpa.free(@constCast(f.first_key));
                gpa.free(@constCast(f.last_key));
            }
            gpa.free(files);
        }
        for (0..n_files) |_| {
            const number = try readU64(bytes, &pos);
            if (pos >= bytes.len) return error.InvalidLsmManifest;
            const level = bytes[pos];
            pos += 1;
            const size = try readU64(bytes, &pos);
            const first_len = try readU32(bytes, &pos);
            if (bytes.len -| pos < first_len) return error.InvalidLsmManifest;
            const first_key = try gpa.dupe(u8, bytes[pos .. pos + first_len]);
            pos += first_len;
            const last_len = try readU32(bytes, &pos);
            if (bytes.len -| pos < last_len) return error.InvalidLsmManifest;
            const last_key = try gpa.dupe(u8, bytes[pos .. pos + last_len]);
            pos += last_len;
            files[file_count] = .{ .number = number, .level = level, .size = size, .first_key = first_key, .last_key = last_key };
            file_count += 1;
        }
        tables[i] = .{ .name = name, .next_serial = next_serial, .columns = columns, .files = files };
        table_count += 1;
    }
    if (pos != bytes.len) return error.InvalidLsmManifest;
    return .{ .watermark = watermark, .next_file_number = next_file_number, .tables = tables };
}

/// Free a snapshot produced by `decode`.
pub fn deinitSnapshot(gpa: Allocator, snapshot: *Snapshot) void {
    for (@constCast(snapshot.tables)) |*table| deinitTableMeta(gpa, table);
    gpa.free(snapshot.tables);
    snapshot.* = undefined;
}

fn deinitTableMeta(gpa: Allocator, table: *TableMeta) void {
    gpa.free(@constCast(table.name));
    for (@constCast(table.columns)) |*c| c.deinit(gpa);
    gpa.free(@constCast(table.columns));
    for (table.files) |*f| {
        gpa.free(@constCast(f.first_key));
        gpa.free(@constCast(f.last_key));
    }
    gpa.free(@constCast(table.files));
}

/// Column encoding mirrors the WAL's `writeColumn` layout so both paths agree
/// on flags and default-expression encoding by construction.
fn encodeColumn(out: *std.ArrayList(u8), gpa: Allocator, col: value.Column) Error!void {
    if (col.name.len > std.math.maxInt(u16)) return error.NameTooLong;
    try writeU16(out, gpa, @intCast(col.name.len));
    try out.appendSlice(gpa, col.name);
    try out.append(gpa, @intFromEnum(col.type_tag));
    var flags: u8 = 0;
    if (col.primary_key) flags |= 1;
    if (col.not_null) flags |= 2;
    if (col.unique) flags |= 4;
    if (col.serial) flags |= 8;
    try out.append(gpa, flags);
    switch (col.default_expr) {
        .none => try out.append(gpa, 0),
        .now => try out.append(gpa, 1),
        .literal => |v| {
            try out.append(gpa, 2);
            try encodeValue(out, gpa, v);
        },
    }
}

fn decodeColumn(gpa: Allocator, bytes: []const u8, pos: *usize) Error!value.Column {
    const name_len = try readU16(bytes, pos);
    if (bytes.len -| pos.* < name_len) return error.InvalidLsmManifest;
    const name = try gpa.dupe(u8, bytes[pos.* .. pos.* + name_len]);
    pos.* += name_len;
    if (pos.* >= bytes.len) return error.InvalidLsmManifest;
    const type_tag = std.enums.fromInt(value.TypeTag, bytes[pos.*]) orelse return error.InvalidLsmManifest;
    pos.* += 1;
    if (pos.* >= bytes.len) return error.InvalidLsmManifest;
    const flags = bytes[pos.*];
    pos.* += 1;
    if (pos.* >= bytes.len) return error.InvalidLsmManifest;
    const def_tag = bytes[pos.*];
    pos.* += 1;
    var default_expr: value.DefaultExpr = .none;
    switch (def_tag) {
        0 => {},
        1 => default_expr = .now,
        2 => default_expr = .{ .literal = try decodeValue(gpa, bytes, pos) },
        else => return error.InvalidLsmManifest,
    }
    return .{
        .name = name,
        .type_tag = type_tag,
        .primary_key = flags & 1 != 0,
        .not_null = flags & 2 != 0,
        .unique = flags & 4 != 0,
        .serial = flags & 8 != 0,
        .default_expr = default_expr,
    };
}

fn encodeValue(out: *std.ArrayList(u8), gpa: Allocator, v: value.Value) Error!void {
    switch (v) {
        .null => try out.append(gpa, 0),
        .int => |i| {
            try out.append(gpa, 1);
            try writeI64(out, gpa, i);
        },
        .text => |t| {
            try out.append(gpa, 2);
            if (t.len > std.math.maxInt(u16)) return error.NameTooLong;
            try writeU16(out, gpa, @intCast(t.len));
            try out.appendSlice(gpa, t);
        },
        .bool => |b| {
            try out.append(gpa, 3);
            try out.append(gpa, if (b) 1 else 0);
        },
        .vector => |items| {
            if (items.len > std.math.maxInt(u16)) return error.NameTooLong;
            try out.append(gpa, 4);
            try writeU16(out, gpa, @intCast(items.len));
            for (items) |item| {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @bitCast(item), .little);
                try out.appendSlice(gpa, &b);
            }
        },
    }
}

fn decodeValue(gpa: Allocator, bytes: []const u8, pos: *usize) Error!value.Value {
    if (pos.* >= bytes.len) return error.InvalidLsmManifest;
    const tag = bytes[pos.*];
    pos.* += 1;
    return switch (tag) {
        0 => .null,
        1 => .{ .int = try readI64(bytes, pos) },
        2 => blk: {
            const len = try readU16(bytes, pos);
            if (bytes.len -| pos.* < len) return error.InvalidLsmManifest;
            const t = try gpa.dupe(u8, bytes[pos.* .. pos.* + len]);
            pos.* += len;
            break :blk .{ .text = t };
        },
        3 => blk: {
            if (pos.* >= bytes.len) return error.InvalidLsmManifest;
            const b = bytes[pos.*] != 0;
            pos.* += 1;
            break :blk .{ .bool = b };
        },
        4 => blk: {
            const len = try readU16(bytes, pos);
            if (len == 0 or bytes.len -| pos.* < @as(usize, len) * 4) return error.InvalidLsmManifest;
            const items = try gpa.alloc(f32, len);
            errdefer gpa.free(items);
            for (items) |*item| {
                item.* = @bitCast(std.mem.readInt(u32, bytes[pos.*..][0..4], .little));
                pos.* += 4;
            }
            break :blk .{ .vector = items };
        },
        else => error.InvalidLsmManifest,
    };
}

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

fn writeI64(list: *std.ArrayList(u8), gpa: Allocator, v: i64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(i64, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn readU16(bytes: []const u8, pos: *usize) Error!u16 {
    if (bytes.len -| pos.* < 2) return error.InvalidLsmManifest;
    const v = std.mem.readInt(u16, bytes[pos.*..][0..2], .little);
    pos.* += 2;
    return v;
}

fn readU32(bytes: []const u8, pos: *usize) Error!u32 {
    if (bytes.len -| pos.* < 4) return error.InvalidLsmManifest;
    const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn readU64(bytes: []const u8, pos: *usize) Error!u64 {
    if (bytes.len -| pos.* < 8) return error.InvalidLsmManifest;
    const v = std.mem.readInt(u64, bytes[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

fn readI64(bytes: []const u8, pos: *usize) Error!i64 {
    if (bytes.len -| pos.* < 8) return error.InvalidLsmManifest;
    const v = std.mem.readInt(i64, bytes[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

test "lsm manifest round trips a version set" {
    const gpa = std.testing.allocator;
    var columns = [_]value.Column{
        .{ .name = @constCast("id"), .type_tag = .int, .primary_key = true, .serial = true },
        .{ .name = @constCast("name"), .type_tag = .text },
    };
    var files = [_]FileMeta{
        .{ .number = 7, .level = 0, .size = 4096, .first_key = "k1", .last_key = "k9" },
        .{ .number = 8, .level = 1, .size = 8192, .first_key = "a0", .last_key = "k0" },
    };
    var tables = [_]TableMeta{.{
        .name = "users",
        .next_serial = 42,
        .columns = columns[0..],
        .files = files[0..],
    }};
    const snapshot = Snapshot{ .watermark = 99, .next_file_number = 10, .tables = tables[0..] };

    const bytes = try encode(gpa, &snapshot);
    defer gpa.free(bytes);
    var decoded = try decode(gpa, bytes);
    defer deinitSnapshot(gpa, &decoded);

    try std.testing.expectEqual(@as(u64, 99), decoded.watermark);
    try std.testing.expectEqual(@as(u64, 10), decoded.next_file_number);
    try std.testing.expectEqual(@as(usize, 1), decoded.tables.len);
    try std.testing.expectEqualStrings("users", decoded.tables[0].name);
    try std.testing.expectEqual(@as(i64, 42), decoded.tables[0].next_serial);
    try std.testing.expectEqual(@as(usize, 2), decoded.tables[0].columns.len);
    try std.testing.expectEqualStrings("id", decoded.tables[0].columns[0].name);
    try std.testing.expectEqual(@as(usize, 2), decoded.tables[0].files.len);
    try std.testing.expectEqual(@as(u8, 1), decoded.tables[0].files[1].level);
    try std.testing.expectEqualStrings("a0", decoded.tables[0].files[1].first_key);
}

test "lsm manifest decode rejects bad magic, version, and truncation" {
    const gpa = std.testing.allocator;
    const snapshot = Snapshot{ .watermark = 1, .next_file_number = 2, .tables = &.{} };
    const bytes = try encode(gpa, &snapshot);
    defer gpa.free(bytes);

    var bad_magic = try gpa.dupe(u8, bytes);
    defer gpa.free(bad_magic);
    @memset(bad_magic[0..4], 'X');
    try std.testing.expectError(error.InvalidLsmManifest, decode(gpa, bad_magic));

    var future = try gpa.dupe(u8, bytes);
    defer gpa.free(future);
    std.mem.writeInt(u32, future[file_magic.len..][0..4], format_version + 1, .little);
    try std.testing.expectError(error.UnsupportedLsmManifest, decode(gpa, future));

    try std.testing.expectError(error.InvalidLsmManifest, decode(gpa, bytes[0 .. bytes.len - 1]));
}
