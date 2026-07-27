const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bytes = @import("../util/bytes.zig");
const value = @import("value.zig");

pub const RecordType = enum(u8) {
    create_table = 1,
    insert = 2,
};

pub const CreateTableRecord = struct {
    name: []const u8,
    columns: []const value.Column,
};

pub const InsertRecord = struct {
    table: []const u8,
    values: []const value.Value,
};

/// Append-only WAL. Phase 0: one file `wal`, length-prefixed LE records.
pub const Wal = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    file: Io.File,
    /// Next write offset (end of file).
    offset: u64,
    sync_on_append: bool,

    pub const OpenError = Allocator.Error || Io.Dir.OpenError || Io.Dir.CreateDirPathOpenError || Io.File.OpenError || Io.File.StatError || Io.File.LengthError || error{
        InvalidWal,
        EndOfStream,
        ReadFailed,
        WriteFailed,
        NameTooLong,
    };

    pub fn open(gpa: Allocator, io: Io, data_dir: []const u8, sync_on_append: bool) OpenError!Wal {
        const dir = try Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        errdefer dir.close(io);

        const file = dir.createFile(io, "wal", .{
            .read = true,
            .truncate = false,
            .exclusive = false,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => try dir.openFile(io, "wal", .{ .mode = .read_write }),
            else => |e| return e,
        };
        errdefer file.close(io);

        const len = try file.length(io);
        return .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .file = file,
            .offset = len,
            .sync_on_append = sync_on_append,
        };
    }

    pub fn deinit(self: *Wal) void {
        self.file.close(self.io);
        self.dir.close(self.io);
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
            try list.append(self.gpa, if (col.primary_key) 1 else 0);
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

    fn appendPayload(self: *Wal, payload: []const u8) !void {
        var hdr: [4]u8 = undefined;
        bytes.writeU32LE(&hdr, @intCast(payload.len));
        try self.file.writePositionalAll(self.io, &hdr, self.offset);
        self.offset += 4;
        try self.file.writePositionalAll(self.io, payload, self.offset);
        self.offset += payload.len;
        if (self.sync_on_append) {
            try self.file.sync(self.io);
        }
    }
};

pub const RecordView = union(RecordType) {
    create_table: struct {
        name: []const u8,
        columns: []ParsedColumn,
    },
    insert: struct {
        table: []const u8,
        values: []value.Value,
    },

    pub const ParsedColumn = struct {
        name: []const u8,
        type_tag: value.TypeTag,
        primary_key: bool,
    };

    pub fn parseAlloc(gpa: Allocator, payload: []const u8) !struct { view: RecordView, owned: Owned } {
        var owned: Owned = .{ .gpa = gpa, .columns = .empty, .values = .empty };
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
                    const pk = payload[i] != 0;
                    i += 1;
                    try owned.columns.append(gpa, .{
                        .name = cname,
                        .type_tag = tt,
                        .primary_key = pk,
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
        }
    }

    pub const Owned = struct {
        gpa: Allocator,
        columns: std.ArrayList(ParsedColumn),
        values: std.ArrayList(value.Value),

        pub fn deinit(self: *Owned) void {
            for (self.values.items) |*v| v.deinit(self.gpa);
            self.columns.deinit(self.gpa);
            self.values.deinit(self.gpa);
        }
    };
};

/// Replay all complete records; truncate torn tail.
pub fn replayWal(self: *Wal, ctx: anytype, comptime apply: fn (@TypeOf(ctx), RecordView) anyerror!void) !void {
    var off: u64 = 0;
    while (off + 4 <= self.offset) {
        var hdr: [4]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &hdr, off);
        if (n < 4) break;
        const plen = bytes.readU32LE(&hdr);
        if (plen == 0) {
            try self.file.setLength(self.io, off);
            self.offset = off;
            return;
        }
        if (off + 4 + plen > self.offset) {
            try self.file.setLength(self.io, off);
            self.offset = off;
            return;
        }
        off += 4;
        const buf = try self.gpa.alloc(u8, plen);
        defer self.gpa.free(buf);
        const rn = try self.file.readPositionalAll(self.io, buf, off);
        if (rn < plen) return error.InvalidWal;
        off += plen;

        var parsed = try RecordView.parseAlloc(self.gpa, buf);
        defer parsed.owned.deinit();
        try apply(ctx, parsed.view);
    }
    if (off < self.offset) {
        try self.file.setLength(self.io, off);
        self.offset = off;
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
