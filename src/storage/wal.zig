const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bytes = @import("../util/bytes.zig");
const value = @import("value.zig");
const vfs_mod = @import("vfs.zig");

pub const RecordType = enum(u8) {
    create_table = 1,
    insert = 2,
    update = 3,
    delete = 4,
};

/// WAL files are self-identifying so a changed frame layout never reinterprets old bytes.
///
/// Frame layout (little-endian):
///   [payload_len: u32][crc32: u32][payload: payload_len bytes]
/// where crc32 covers `payload_len` (as raw LE bytes) concatenated with `payload`.
/// Covering the length prevents a flipped length field from being accepted as a
/// different complete frame; only an incomplete tail may be truncated.
const file_magic = "PICO_WAL";
const format_version: u32 = 1;
const file_header_len = file_magic.len + @sizeOf(u32);
const frame_header_len = @sizeOf(u32) + @sizeOf(u32);
const frame_payload_len_max = 8 * 1024 * 1024;

pub const CreateTableRecord = struct {
    name: []const u8,
    columns: []const value.Column,
};

pub const InsertRecord = struct {
    table: []const u8,
    values: []const value.Value,
};

/// Full-row replacement addressed by primary key value.
pub const UpdateRecord = struct {
    table: []const u8,
    pk: value.Value,
    values: []const value.Value,
};

pub const DeleteRecord = struct {
    table: []const u8,
    pk: value.Value,
};

/// Append-only WAL with a versioned file header and checksummed LE frames.
pub const Wal = struct {
    gpa: Allocator,
    io: Io,
    vfs: vfs_mod.Vfs,
    file: vfs_mod.File,
    /// Next write offset (end of file).
    offset: u64,
    sync_on_append: bool,

    pub const OpenError = Allocator.Error || Io.Dir.OpenError || Io.Dir.CreateDirPathOpenError || Io.File.OpenError || Io.File.StatError || Io.File.LengthError || error{
        InvalidWal,
        InvalidStoragePath,
        InstanceInUse,
        UnsupportedWalFormat,
        CorruptWal,
        InputOutput,
        LockViolation,
        BrokenPipe,
        NotOpenForWriting,
        NotOpenForReading,
        Unseekable,
        EndOfStream,
        ReadFailed,
        WriteFailed,
        NameTooLong,
    };

    pub fn open(gpa: Allocator, io: Io, data_dir: []const u8, sync_on_append: bool) OpenError!Wal {
        var vfs = try vfs_mod.Vfs.open(io, data_dir);
        errdefer vfs.close();

        var file = try vfs.openFile("wal", .{ .create = true });
        errdefer file.close();

        var len = try file.size();
        if (len == 0) {
            var header: [file_header_len]u8 = undefined;
            @memcpy(header[0..file_magic.len], file_magic);
            bytes.writeU32LE(header[file_magic.len..][0..4], format_version);
            try file.writeAtAll(&header, 0);
            if (sync_on_append) try file.sync();
            len = file_header_len;
        } else {
            try validateFileHeader(&file, len);
        }
        return .{
            .gpa = gpa,
            .io = io,
            .vfs = vfs,
            .file = file,
            .offset = len,
            .sync_on_append = sync_on_append,
        };
    }

    pub fn deinit(self: *Wal) void {
        self.file.close();
        self.vfs.close();
        self.* = undefined;
    }

    pub fn appendCreateTable(self: *Wal, rec: CreateTableRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, @intFromEnum(RecordType.create_table));
        try writeStr(&list, self.gpa, rec.name);
        try writeU16(&list, self.gpa, @intCast(rec.columns.len));
        for (rec.columns) |col| {
            try writeStr(&list, self.gpa, col.name);
            try list.append(self.gpa, @intFromEnum(col.type_tag));
            // flags: bit0 pk, bit1 not_null, bit2 unique, bit3 serial
            var flags: u8 = 0;
            if (col.primary_key) flags |= 1;
            if (col.not_null) flags |= 2;
            if (col.unique) flags |= 4;
            if (col.serial) flags |= 8;
            try list.append(self.gpa, flags);
            // default: 0 none, 1 now, 2 literal
            switch (col.default_expr) {
                .none => try list.append(self.gpa, 0),
                .now => try list.append(self.gpa, 1),
                .literal => |v| {
                    try list.append(self.gpa, 2);
                    try writeValue(&list, self.gpa, v);
                },
            }
        }
        try self.appendPayload(list.items);
    }

    pub fn appendInsert(self: *Wal, rec: InsertRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, @intFromEnum(RecordType.insert));
        try writeStr(&list, self.gpa, rec.table);
        try writeU16(&list, self.gpa, @intCast(rec.values.len));
        for (rec.values) |v| {
            try writeValue(&list, self.gpa, v);
        }
        try self.appendPayload(list.items);
    }

    pub fn appendUpdate(self: *Wal, rec: UpdateRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, @intFromEnum(RecordType.update));
        try writeStr(&list, self.gpa, rec.table);
        try writeValue(&list, self.gpa, rec.pk);
        try writeU16(&list, self.gpa, @intCast(rec.values.len));
        for (rec.values) |v| {
            try writeValue(&list, self.gpa, v);
        }
        try self.appendPayload(list.items);
    }

    pub fn appendDelete(self: *Wal, rec: DeleteRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, @intFromEnum(RecordType.delete));
        try writeStr(&list, self.gpa, rec.table);
        try writeValue(&list, self.gpa, rec.pk);
        try self.appendPayload(list.items);
    }

    fn appendPayload(self: *Wal, payload: []const u8) !void {
        if (payload.len == 0 or payload.len > frame_payload_len_max) return error.InvalidWal;

        // One positional write for the whole frame so a crash yields either a
        // complete frame or a single torn tail — never a header without body
        // from two separate writes.
        const frame_len = frame_header_len + payload.len;
        const frame = try self.gpa.alloc(u8, frame_len);
        defer self.gpa.free(frame);

        const payload_len: u32 = @intCast(payload.len);
        bytes.writeU32LE(frame[0..4], payload_len);
        bytes.writeU32LE(frame[4..8], frameChecksum(payload_len, payload));
        @memcpy(frame[frame_header_len..], payload);

        try self.file.writeAtAll(frame, self.offset);
        self.offset += frame_len;
        if (self.sync_on_append) {
            try self.file.sync();
        }
    }

    /// Persist a recovered logical EOF. Required after torn-tail truncation so a
    /// later append cannot leave garbage past the new end if size metadata was
    /// not durable.
    fn persistEnd(self: *Wal) !void {
        try self.file.sync();
    }
};

fn frameChecksum(payload_len: u32, payload: []const u8) u32 {
    var len_bytes: [4]u8 = undefined;
    bytes.writeU32LE(&len_bytes, payload_len);
    var c = std.hash.Crc32.init();
    c.update(&len_bytes);
    c.update(payload);
    return c.final();
}

fn validateFileHeader(file: *vfs_mod.File, len: u64) !void {
    if (len < file_header_len) return error.InvalidWal;

    var header: [file_header_len]u8 = undefined;
    const read_len = try file.readAt(&header, 0);
    if (read_len < file_header_len) return error.InvalidWal;
    if (!std.mem.eql(u8, header[0..file_magic.len], file_magic)) return error.UnsupportedWalFormat;
    if (bytes.readU32LE(header[file_magic.len..][0..4]) != format_version) {
        return error.UnsupportedWalFormat;
    }
}

pub const RecordView = union(RecordType) {
    create_table: struct {
        name: []const u8,
        columns: []ParsedColumn,
    },
    insert: struct {
        table: []const u8,
        values: []value.Value,
    },
    update: struct {
        table: []const u8,
        pk: value.Value,
        values: []value.Value,
    },
    delete: struct {
        table: []const u8,
        pk: value.Value,
    },

    pub const ParsedColumn = struct {
        name: []const u8,
        type_tag: value.TypeTag,
        primary_key: bool,
        not_null: bool = false,
        unique: bool = false,
        serial: bool = false,
        default_expr: value.DefaultExpr = .none,
    };

    pub fn parseAlloc(gpa: Allocator, payload: []const u8) !struct { view: RecordView, owned: Owned } {
        var owned: Owned = .{ .gpa = gpa, .columns = .empty, .values = .empty, .pk = .null };
        errdefer owned.deinit();

        if (payload.len < 1) return error.InvalidWal;
        const tag = std.enums.fromInt(RecordType, payload[0]) orelse return error.InvalidWal;
        var i: usize = 1;
        switch (tag) {
            .create_table => {
                const name = try readStr(payload, &i);
                const ncol = try readU16(payload, &i);
                try owned.columns.ensureTotalCapacity(gpa, ncol);
                var c: u16 = 0;
                while (c < ncol) : (c += 1) {
                    const cname = try readStr(payload, &i);
                    if (i >= payload.len) return error.InvalidWal;
                    const tt = std.enums.fromInt(value.TypeTag, payload[i]) orelse return error.InvalidWal;
                    i += 1;
                    if (i >= payload.len) return error.InvalidWal;
                    const flags = payload[i];
                    i += 1;
                    if (i >= payload.len) return error.InvalidWal;
                    const def_tag = payload[i];
                    i += 1;
                    var def: value.DefaultExpr = .none;
                    switch (def_tag) {
                        0 => {},
                        1 => def = .now,
                        2 => {
                            const lit = try readValue(gpa, payload, &i);
                            def = .{ .literal = lit };
                        },
                        else => return error.InvalidWal,
                    }
                    try owned.columns.append(gpa, .{
                        .name = cname,
                        .type_tag = tt,
                        .primary_key = flags & 1 != 0,
                        .not_null = flags & 2 != 0,
                        .unique = flags & 4 != 0,
                        .serial = flags & 8 != 0,
                        .default_expr = def,
                    });
                }
                return .{
                    .view = .{ .create_table = .{
                        .name = name,
                        .columns = owned.columns.items,
                    } },
                    .owned = owned,
                };
            },
            .insert => {
                const table = try readStr(payload, &i);
                const nval = try readU16(payload, &i);
                try owned.values.ensureTotalCapacity(gpa, nval);
                var v: u16 = 0;
                while (v < nval) : (v += 1) {
                    const val = try readValue(gpa, payload, &i);
                    try owned.values.append(gpa, val);
                }
                return .{
                    .view = .{ .insert = .{
                        .table = table,
                        .values = owned.values.items,
                    } },
                    .owned = owned,
                };
            },
            .update => {
                const table = try readStr(payload, &i);
                owned.pk = try readValue(gpa, payload, &i);
                const nval = try readU16(payload, &i);
                try owned.values.ensureTotalCapacity(gpa, nval);
                var v: u16 = 0;
                while (v < nval) : (v += 1) {
                    const val = try readValue(gpa, payload, &i);
                    try owned.values.append(gpa, val);
                }
                return .{
                    .view = .{ .update = .{
                        .table = table,
                        .pk = owned.pk,
                        .values = owned.values.items,
                    } },
                    .owned = owned,
                };
            },
            .delete => {
                const table = try readStr(payload, &i);
                owned.pk = try readValue(gpa, payload, &i);
                return .{
                    .view = .{ .delete = .{
                        .table = table,
                        .pk = owned.pk,
                    } },
                    .owned = owned,
                };
            },
        }
    }

    pub const Owned = struct {
        gpa: Allocator,
        columns: std.ArrayList(ParsedColumn),
        values: std.ArrayList(value.Value),
        pk: value.Value,

        pub fn deinit(self: *Owned) void {
            for (self.values.items) |*v| v.deinit(self.gpa);
            for (self.columns.items) |*c| c.default_expr.deinit(self.gpa);
            self.columns.deinit(self.gpa);
            self.values.deinit(self.gpa);
            self.pk.deinit(self.gpa);
        }
    };
};

/// Replay complete, checksummed frames; truncate only a torn tail.
///
/// Invariants (see docs/ARCHITECTURE.md):
/// - Only complete, supported, checksum-valid frames are applied.
/// - An incomplete final frame (short header, or declared body past EOF) is
///   truncated and the new EOF is synced — never guessed or repaired mid-file.
/// - A complete frame with a bad checksum, zero/oversized length, or undecodable
///   payload fails recovery; the file is left untouched for forensics.
pub fn replayWal(self: *Wal, ctx: anytype, comptime apply: fn (@TypeOf(ctx), RecordView) anyerror!void) !void {
    try validateFileHeader(&self.file, self.offset);
    var off: u64 = file_header_len;
    var truncated = false;
    while (off < self.offset) {
        if (self.offset - off < frame_header_len) {
            try self.file.truncate(off);
            self.offset = off;
            truncated = true;
            break;
        }

        var header: [frame_header_len]u8 = undefined;
        const header_len = try self.file.readAt(&header, off);
        if (header_len < frame_header_len) return error.InvalidWal;
        const payload_len = bytes.readU32LE(header[0..4]);
        const payload_crc = bytes.readU32LE(header[4..8]);
        // Zero or absurd lengths on a fully present header are corruption, not a
        // torn tail: a real append never writes a zero-length payload.
        if (payload_len == 0 or payload_len > frame_payload_len_max) return error.CorruptWal;
        const frame_len: u64 = frame_header_len + payload_len;
        if (frame_len > self.offset - off) {
            try self.file.truncate(off);
            self.offset = off;
            truncated = true;
            break;
        }

        const buf = try self.gpa.alloc(u8, payload_len);
        defer self.gpa.free(buf);
        const payload_off = off + frame_header_len;
        const payload_read_len = try self.file.readAt(buf, payload_off);
        if (payload_read_len < payload_len) return error.InvalidWal;
        if (frameChecksum(payload_len, buf) != payload_crc) return error.CorruptWal;

        var parsed = try RecordView.parseAlloc(self.gpa, buf);
        defer parsed.owned.deinit();
        try apply(ctx, parsed.view);
        off += frame_len;
    }
    if (truncated) {
        try self.persistEnd();
    }
}

fn writeU16(list: *std.ArrayList(u8), gpa: Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    bytes.writeU16LE(&b, v);
    try list.appendSlice(gpa, &b);
}

fn writeStr(list: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    if (s.len > std.math.maxInt(u16)) return error.NameTooLong;
    try writeU16(list, gpa, @intCast(s.len));
    try list.appendSlice(gpa, s);
}

fn writeValue(list: *std.ArrayList(u8), gpa: Allocator, v: value.Value) !void {
    switch (v) {
        .null => try list.append(gpa, 0),
        .int => |i| {
            try list.append(gpa, 1);
            var b: [8]u8 = undefined;
            bytes.writeI64LE(&b, i);
            try list.appendSlice(gpa, &b);
        },
        .text => |t| {
            try list.append(gpa, 2);
            try writeStr(list, gpa, t);
        },
        .bool => |b| {
            try list.append(gpa, 3);
            try list.append(gpa, if (b) 1 else 0);
        },
    }
}

fn readU16(payload: []const u8, i: *usize) !u16 {
    if (i.* + 2 > payload.len) return error.InvalidWal;
    const v = bytes.readU16LE(payload[i.*..][0..2]);
    i.* += 2;
    return v;
}

fn readStr(payload: []const u8, i: *usize) ![]const u8 {
    const len = try readU16(payload, i);
    if (i.* + len > payload.len) return error.InvalidWal;
    const s = payload[i.* .. i.* + len];
    i.* += len;
    return s;
}

fn readValue(gpa: Allocator, payload: []const u8, i: *usize) !value.Value {
    if (i.* >= payload.len) return error.InvalidWal;
    const tag = payload[i.*];
    i.* += 1;
    switch (tag) {
        0 => return .null,
        1 => {
            if (i.* + 8 > payload.len) return error.InvalidWal;
            const v = bytes.readI64LE(payload[i.*..][0..8]);
            i.* += 8;
            return .{ .int = v };
        },
        2 => {
            const s = try readStr(payload, i);
            return .{ .text = try gpa.dupe(u8, s) };
        },
        3 => {
            if (i.* >= payload.len) return error.InvalidWal;
            const b = payload[i.*] != 0;
            i.* += 1;
            return .{ .bool = b };
        },
        else => return error.InvalidWal,
    }
}

const TestSink = struct {
    inserts: u32 = 0,

    fn apply(self: *TestSink, view: RecordView) !void {
        switch (view) {
            .insert => self.inserts += 1,
            else => {},
        }
    }
};

fn noopApply(_: void, _: RecordView) !void {}

fn openCleanDir(comptime name: []const u8) ![]const u8 {
    const io = std.testing.io;
    Io.Dir.cwd().deleteTree(io, name) catch {};
    return name;
}

fn removeDir(name: []const u8) void {
    Io.Dir.cwd().deleteTree(std.testing.io, name) catch {};
}

test "wal rejects a complete frame with a bad checksum" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/pico-test-wal-checksum");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 1 }} });

        var corrupt: [1]u8 = .{0};
        try wal.file.writeAtAll(&corrupt, file_header_len + frame_header_len);
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try std.testing.expectError(error.CorruptWal, replayWal(&wal, {}, noopApply));
    }
}

test "wal truncates a torn tail and keeps the committed prefix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/pico-test-wal-torn");
    defer removeDir(dir_name);

    var prefix_end: u64 = 0;
    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 1 }} });
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 2 }} });
        prefix_end = wal.offset;
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 3 }} });

        // Simulate crash after a partial frame write: keep only half of the last frame.
        const torn_len = prefix_end + (wal.offset - prefix_end) / 2;
        try std.testing.expect(torn_len > prefix_end);
        try std.testing.expect(torn_len < wal.offset);
        try wal.file.truncate(torn_len);
        wal.offset = torn_len;
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: TestSink = .{};
        try replayWal(&wal, &sink, TestSink.apply);
        try std.testing.expectEqual(@as(u32, 2), sink.inserts);
        try std.testing.expectEqual(prefix_end, wal.offset);
        try std.testing.expectEqual(prefix_end, try wal.file.size());
    }

    // After sealing the torn tail, new appends must recover cleanly with no garbage tail.
    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: TestSink = .{};
        try replayWal(&wal, &sink, TestSink.apply);
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 4 }} });
    }
    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: TestSink = .{};
        try replayWal(&wal, &sink, TestSink.apply);
        try std.testing.expectEqual(@as(u32, 3), sink.inserts);
    }
}

test "wal truncates a partial frame header at EOF" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/pico-test-wal-partial-header");
    defer removeDir(dir_name);

    var prefix_end: u64 = 0;
    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 1 }} });
        prefix_end = wal.offset;
        var junk: [3]u8 = .{ 0x01, 0x02, 0x03 };
        try wal.file.writeAtAll(&junk, wal.offset);
        wal.offset += junk.len;
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: TestSink = .{};
        try replayWal(&wal, &sink, TestSink.apply);
        try std.testing.expectEqual(@as(u32, 1), sink.inserts);
        try std.testing.expectEqual(prefix_end, wal.offset);
    }
}

test "wal rejects a flipped length on an otherwise complete frame" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/pico-test-wal-bad-len");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 1 }} });
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 2 }} });

        // Flip the low bit of the first frame's payload_len. The frame remains
        // fully inside the file, so this must be CorruptWal — not a torn tail.
        var len_byte: [1]u8 = undefined;
        _ = try wal.file.readAt(&len_byte, file_header_len);
        len_byte[0] ^= 1;
        try wal.file.writeAtAll(&len_byte, file_header_len);
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try std.testing.expectError(error.CorruptWal, replayWal(&wal, {}, noopApply));
        // Forensics: refuse without truncating away evidence past the bad frame.
        try std.testing.expect((try wal.file.size()) > file_header_len);
    }
}

test "wal rejects unknown magic and format version" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/pico-test-wal-format");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var bad_magic: [4]u8 = "XXXX".*;
        try wal.file.writeAtAll(&bad_magic, 0);
    }
    try std.testing.expectError(error.UnsupportedWalFormat, Wal.open(gpa, io, dir_name, false));

    removeDir(dir_name);
    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var ver: [4]u8 = undefined;
        bytes.writeU32LE(&ver, format_version + 1);
        try wal.file.writeAtAll(&ver, file_magic.len);
    }
    try std.testing.expectError(error.UnsupportedWalFormat, Wal.open(gpa, io, dir_name, false));
}
