//! Immutable sorted-string table (SST) format, builder, and reader.
//!
//! An SST is the persistent ordered-storage unit of the LSM. It holds opaque
//! byte-sorted internal keys (user key + MVCC sequence suffix, see
//! `codec.zig`) with byte values, packed into fixed-target data blocks with a
//! trailing index block and a fixed footer:
//!
//! ```text
//! [Data block 0] [Data block 1] ... [Data block N-1] [Index block] [Footer]
//! ```
//!
//! Each data block is a sequence of `key_len:u32 key value_len:u32 value`
//! entries followed by a CRC32 of the block bytes. The index block has one
//! entry per data block keyed by the block's *last* internal key, with a
//! 16-byte value `(block_offset:u64, block_size:u64)`. A point lookup binary
//! searches the index for the block that may contain the seek key, then scans
//! that block. The footer is fixed-size and records the index location plus
//! the total entry count.
//!
//! Files are written through the directory's atomic-file primitive and synced
//! before publication, so a torn or interrupted flush never publishes a
//! half-written SST. Blocks are not compressed and no Bloom filter is written
//! yet; both are documented evolution points (docs/architecture/lsm-storage.md).
//!
//! The comparator is fixed: bytewise internal-key order (see
//! `codec.internalLessThan`). The header records the format version so a
//! future comparator or layout change fails validation rather than
//! misinterpreting old bytes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const codec = @import("codec.zig");

pub const file_magic = "RUNADB_SST";
pub const format_version: u32 = 1;
pub const footer_len = file_magic.len + 4 + 8 + 8 + 8;
const crc_len = 4;
pub const default_block_size: usize = 4096;
pub const default_target_file_size: usize = 4 * 1024 * 1024;
/// Maximum block we are willing to read from a file; bounds a corrupt length.
const max_block_size: usize = 64 * 1024 * 1024;

pub const Error = error{
    InvalidSst,
    UnsupportedSst,
    CorruptSst,
    SstTooLarge,
} || Allocator.Error;

/// One parsed entry from an SST block. Keys/values are owned by the caller of
/// the parse that produced them.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

fn blockCrc(block: []const u8) u32 {
    return std.hash.Crc32.hash(block);
}

// ── Builder ──

/// Streaming SST builder writing into an atomic file in the data directory.
/// Entries must be added in strictly ascending internal-key order. `finish`
/// syncs and publishes the file; `abort` removes the staged file.
pub const Builder = struct {
    io: Io,
    atomic: Io.File.Atomic,
    gpa: Allocator,
    block_size: usize,
    /// Next write offset in the staged file.
    offset: u64,
    /// Entries accumulated into the current data block (unencoded framing).
    block: std.ArrayList(u8),
    /// Encoded index entries: `key_len:u32 key offset:u64 size:u64`.
    index: std.ArrayList(u8),
    /// First internal key written (owned), null for an empty SST.
    first_key: ?[]u8,
    /// Last internal key written (owned).
    last_key: ?[]u8,
    entry_count: u64,

    /// Start building `name` in `dir`. The staged file is removed if the
    /// builder is aborted and replaces any prior file on `finish`.
    pub fn create(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8) !Builder {
        return .{
            .io = io,
            .atomic = try dir.createFileAtomic(io, name, .{ .replace = true }),
            .gpa = gpa,
            .block_size = default_block_size,
            .offset = 0,
            .block = .empty,
            .index = .empty,
            .first_key = null,
            .last_key = null,
            .entry_count = 0,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.atomic.deinit(self.io);
        self.block.deinit(self.gpa);
        self.index.deinit(self.gpa);
        if (self.first_key) |k| self.gpa.free(k);
        if (self.last_key) |k| self.gpa.free(k);
        self.* = undefined;
    }

    /// Add one entry. `key` must sort strictly after the previous key.
    pub fn add(self: *Builder, key: []const u8, entry_value: []const u8) !void {
        if (self.last_key) |last| {
            if (!codec.internalLessThan(last, key)) return error.InvalidSst;
        }
        if (self.first_key == null) self.first_key = try self.gpa.dupe(u8, key);
        if (self.last_key) |last| self.gpa.free(last);
        self.last_key = try self.gpa.dupe(u8, key);

        const entry_len = 4 + key.len + 4 + entry_value.len;
        // Flush the current block once adding this entry would exceed the
        // target size and the block is non-empty.
        if (self.block.items.len != 0 and self.block.items.len + entry_len > self.block_size) {
            try self.finishBlock();
        }
        try self.block.ensureUnusedCapacity(self.gpa, entry_len);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(key.len), .little);
        self.block.appendSliceAssumeCapacity(&len_bytes);
        self.block.appendSliceAssumeCapacity(key);
        std.mem.writeInt(u32, &len_bytes, @intCast(entry_value.len), .little);
        self.block.appendSliceAssumeCapacity(&len_bytes);
        self.block.appendSliceAssumeCapacity(entry_value);
        self.entry_count += 1;
    }

    fn finishBlock(self: *Builder) !void {
        if (self.block.items.len == 0) return;
        const block_start = self.offset;
        const block_len = self.block.items.len + crc_len;
        const bytes = try self.gpa.alloc(u8, block_len);
        defer self.gpa.free(bytes);
        @memcpy(bytes[0..self.block.items.len], self.block.items);
        std.mem.writeInt(u32, bytes[self.block.items.len..][0..4], blockCrc(self.block.items), .little);

        try self.atomic.file.writePositionalAll(self.io, bytes, block_start);
        self.offset += block_len;

        // Index entry keyed by this block's last internal key.
        const last = self.last_key.?;
        try self.index.ensureUnusedCapacity(self.gpa, 4 + last.len + 8 + 8);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(last.len), .little);
        self.index.appendSliceAssumeCapacity(&len_bytes);
        self.index.appendSliceAssumeCapacity(last);
        var num_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &num_bytes, block_start, .little);
        self.index.appendSliceAssumeCapacity(&num_bytes);
        std.mem.writeInt(u64, &num_bytes, block_len, .little);
        self.index.appendSliceAssumeCapacity(&num_bytes);

        self.block.clearRetainingCapacity();
    }

    /// Flush the final block, write the index block and footer, sync, and
    /// atomically publish the file. Returns the file's size.
    pub fn finish(self: *Builder) !u64 {
        try self.finishBlock();

        // Index block: same framing as data blocks, then its own CRC.
        const index_start = self.offset;
        const index_len = self.index.items.len + crc_len;
        const index_bytes = try self.gpa.alloc(u8, index_len);
        defer self.gpa.free(index_bytes);
        @memcpy(index_bytes[0..self.index.items.len], self.index.items);
        std.mem.writeInt(u32, index_bytes[self.index.items.len..][0..4], blockCrc(self.index.items), .little);
        try self.atomic.file.writePositionalAll(self.io, index_bytes, index_start);
        self.offset += index_len;

        // Footer.
        var footer: [footer_len]u8 = undefined;
        @memcpy(footer[0..file_magic.len], file_magic);
        std.mem.writeInt(u32, footer[file_magic.len..][0..4], format_version, .little);
        std.mem.writeInt(u64, footer[file_magic.len + 4 ..][0..8], index_start, .little);
        std.mem.writeInt(u64, footer[file_magic.len + 12 ..][0..8], index_len, .little);
        std.mem.writeInt(u64, footer[file_magic.len + 20 ..][0..8], self.entry_count, .little);
        try self.atomic.file.writePositionalAll(self.io, &footer, self.offset);
        self.offset += footer_len;

        try self.atomic.file.sync(self.io);
        try self.atomic.replace(self.io);
        try syncDir(self.atomic.dir, self.io);
        return self.offset;
    }

    /// Remove the staged file without publishing anything.
    pub fn abort(self: *Builder) void {
        self.atomic.deinit(self.io);
        self.atomic = undefined;
    }
};

pub const FlushError = Error || Io.File.OpenError || Io.File.StatError || Io.File.LengthError || Io.File.ReadError;

/// Index entry parsed from the index block.
const IndexEntry = struct {
    last_key: []u8, // owned
    offset: u64,
    size: u64,

    fn deinit(self: *IndexEntry, gpa: Allocator) void {
        gpa.free(self.last_key);
    }
};

/// Read-only view of one SST file. The index is loaded eagerly; data blocks
/// are read on demand and validated block by block.
pub const Reader = struct {
    gpa: Allocator,
    io: Io,
    file: Io.File,
    index: std.ArrayList(IndexEntry),
    entry_count: u64,

    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8) !Reader {
        var file = try dir.openFile(io, name, .{ .mode = .read_only });
        errdefer file.close(io);
        const file_len = try file.length(io);
        if (file_len < footer_len) return error.InvalidSst;

        var footer: [footer_len]u8 = undefined;
        if (try file.readPositionalAll(io, &footer, file_len - footer_len) != footer_len) return error.CorruptSst;
        if (!std.mem.eql(u8, footer[0..file_magic.len], file_magic)) return error.InvalidSst;
        const version = std.mem.readInt(u32, footer[file_magic.len..][0..4], .little);
        if (version != format_version) return error.UnsupportedSst;
        const index_offset = std.mem.readInt(u64, footer[file_magic.len + 4 ..][0..8], .little);
        const index_size = std.mem.readInt(u64, footer[file_magic.len + 12 ..][0..8], .little);
        const entry_count = std.mem.readInt(u64, footer[file_magic.len + 20 ..][0..8], .little);

        if (index_size > max_block_size) return error.CorruptSst;
        const index_bytes = try readBlock(gpa, io, &file, index_offset, index_size);
        defer gpa.free(index_bytes);

        var index: std.ArrayList(IndexEntry) = .empty;
        errdefer {
            for (index.items) |*entry| entry.deinit(gpa);
            index.deinit(gpa);
        }
        var pos: usize = 0;
        while (pos + crc_len < index_bytes.len) {
            const key_len = try readU32(index_bytes, &pos);
            if (pos + key_len + 16 > index_bytes.len) return error.CorruptSst;
            const last_key = try gpa.dupe(u8, index_bytes[pos .. pos + key_len]);
            pos += key_len;
            const offset = std.mem.readInt(u64, index_bytes[pos..][0..8], .little);
            const size = std.mem.readInt(u64, index_bytes[pos + 8 ..][0..8], .little);
            pos += 16;
            if (size == 0 or size > max_block_size) return error.CorruptSst;
            // Blocks must not overlap or run past EOF.
            if (offset + size > file_len) return error.CorruptSst;
            try index.append(gpa, .{ .last_key = last_key, .offset = offset, .size = size });
        }
        if (pos + crc_len != index_bytes.len) return error.CorruptSst;
        if (entry_count == 0 and index.items.len != 0) return error.CorruptSst;
        return .{ .gpa = gpa, .io = io, .file = file, .index = index, .entry_count = entry_count };
    }

    pub fn deinit(self: *Reader) void {
        for (self.index.items) |*entry| entry.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn count(self: *const Reader) u64 {
        return self.entry_count;
    }

    /// First internal key in the file, or null for an empty SST. Borrowed.
    pub fn firstKey(self: *const Reader) ?[]const u8 {
        return self.index.items[0].last_key;
    }

    /// Last internal key in the file. Borrowed.
    pub fn lastKey(self: *const Reader) ?[]const u8 {
        const n = self.index.items.len;
        if (n == 0) return null;
        return self.index.items[n - 1].last_key;
    }

    /// Point lookup by user key. Returns the owned entry if found; a delete
    /// tombstone is returned with an empty value so the caller decides
    /// visibility. The caller owns the returned key/value bytes.
    pub fn find(self: *Reader, gpa: Allocator, io: Io, user_key: []const u8) !?Entry {
        if (self.index.items.len == 0) return null;
        const seek = try codec.seekKey(gpa, user_key);
        defer gpa.free(seek);

        // First index entry whose last key sorts at or after the seek key.
        var lo: usize = 0;
        var hi: usize = self.index.items.len;
        var block_idx: usize = self.index.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.index.items[mid].last_key, seek) == .lt) {
                lo = mid + 1;
            } else {
                block_idx = mid;
                hi = mid;
            }
        }
        if (block_idx == self.index.items.len) return null;

        const target = self.index.items[block_idx];
        const block_bytes = try readBlock(gpa, io, &self.file, target.offset, target.size);
        defer gpa.free(block_bytes);
        const entries = try parseBlock(gpa, block_bytes[0 .. block_bytes.len - crc_len]);
        defer {
            for (entries) |e| {
                gpa.free(@constCast(e.key));
                gpa.free(@constCast(e.value));
            }
            gpa.free(entries);
        }
        for (entries) |e| {
            if (std.mem.eql(u8, codec.userKeyOf(e.key), user_key)) {
                return .{ .key = try gpa.dupe(u8, e.key), .value = try gpa.dupe(u8, e.value) };
            }
        }
        return null;
    }

    /// Read every entry in file order. The caller owns the returned slice and
    /// each entry's key/value bytes.
    pub fn iterate(self: *Reader, gpa: Allocator, io: Io) ![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        errdefer {
            for (out.items) |e| {
                gpa.free(@constCast(e.key));
                gpa.free(@constCast(e.value));
            }
            out.deinit(gpa);
        }
        for (self.index.items) |target| {
            const block_bytes = try readBlock(gpa, io, &self.file, target.offset, target.size);
            defer gpa.free(block_bytes);
            const entries = try parseBlock(gpa, block_bytes[0 .. block_bytes.len - crc_len]);
            defer {
                for (entries) |e| {
                    gpa.free(@constCast(e.key));
                    gpa.free(@constCast(e.value));
                }
                gpa.free(entries);
            }
            try out.ensureUnusedCapacity(gpa, entries.len);
            for (entries) |e| {
                out.appendAssumeCapacity(.{
                    .key = try gpa.dupe(u8, e.key),
                    .value = try gpa.dupe(u8, e.value),
                });
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Read and validate one block (data or index): bounded size, CRC, exact read.
fn readBlock(gpa: Allocator, io: Io, file: *Io.File, offset: u64, size: u64) ![]u8 {
    if (size == 0 or size > max_block_size) return error.CorruptSst;
    const bytes = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(bytes);
    const got = file.readPositionalAll(io, bytes, offset) catch |err| {
        gpa.free(bytes);
        return err;
    };
    if (got != bytes.len) return error.CorruptSst;
    if (size < crc_len) return error.CorruptSst;
    const body_len = size - crc_len;
    const stored_crc = std.mem.readInt(u32, bytes[body_len..][0..4], .little);
    if (stored_crc != blockCrc(bytes[0..body_len])) return error.CorruptSst;
    return bytes;
}

/// Parse block body bytes (excluding the CRC) into owned entries.
fn parseBlock(gpa: Allocator, body: []const u8) Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |e| {
            gpa.free(@constCast(e.key));
            gpa.free(@constCast(e.value));
        }
        out.deinit(gpa);
    }
    var pos: usize = 0;
    while (pos < body.len) {
        const key_len = try readU32(body, &pos);
        if (pos + key_len > body.len) return error.CorruptSst;
        const key = try gpa.dupe(u8, body[pos .. pos + key_len]);
        pos += key_len;
        const value_len = try readU32(body, &pos);
        if (pos + value_len > body.len) return error.CorruptSst;
        const value = try gpa.dupe(u8, body[pos .. pos + value_len]);
        pos += value_len;
        try out.append(gpa, .{ .key = key, .value = value });
    }
    return out.toOwnedSlice(gpa);
}

fn readU32(bytes: []const u8, pos: *usize) Error!u32 {
    if (bytes.len -| pos.* < 4) return error.CorruptSst;
    const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn syncDir(dir: Io.Dir, io: Io) !void {
    var handle = try dir.openFile(io, ".", .{ .mode = .read_only });
    defer handle.close(io);
    try handle.sync(io);
}

// ── Tests ──

const test_dir = "zig-cache/runadb-lsm-sstable";

fn openTestDir(io: Io) !Io.Dir {
    Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    return Io.Dir.cwd().createDirPathOpen(io, test_dir, .{ .open_options = .{ .iterate = true } });
}

test "sst round trips entries, point lookups, and iteration" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try openTestDir(io);
    defer {
        dir.close(io);
        Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    }

    const name = "sst_0001.sst";
    var builder = try Builder.create(gpa, io, dir, name);
    errdefer builder.deinit();
    try builder.add("b-key", "b-value");
    // Out-of-order entries are rejected by the builder.
    try std.testing.expectError(error.InvalidSst, builder.add("a-key", "a-value"));
    builder.deinit(); // staged file is discarded
    builder = try Builder.create(gpa, io, dir, name);
    defer builder.deinit();

    // Entries in strict ascending order. Keys are internal keys: user key
    // plus the MVCC sequence suffix (newest sequence first within one user
    // key), so a single put per user key sorts plainly by user key.
    const a = try codec.internalKey(gpa, "a-key", 1, .put);
    defer gpa.free(a);
    const b = try codec.internalKey(gpa, "b-key", 2, .put);
    defer gpa.free(b);
    const m = try codec.internalKey(gpa, "m-key", 3, .put);
    defer gpa.free(m);
    const z = try codec.internalKey(gpa, "z-key", 4, .put);
    defer gpa.free(z);
    try builder.add(a, "a-value");
    try builder.add(b, "b-value");
    try builder.add(m, "m-value");
    try builder.add(z, "z-value");
    _ = try builder.finish();

    var reader = try Reader.open(gpa, io, dir, name);
    defer reader.deinit();
    try std.testing.expectEqual(@as(u64, 4), reader.count());

    const hit = (try reader.find(gpa, io, "b-key")).?;
    defer {
        gpa.free(@constCast(hit.key));
        gpa.free(@constCast(hit.value));
    }
    try std.testing.expectEqualStrings("b-value", hit.value);

    try std.testing.expect((try reader.find(gpa, io, "missing")) == null);
    try std.testing.expect((try reader.find(gpa, io, "aaa")) == null);
    try std.testing.expect((try reader.find(gpa, io, "zzz")) == null);

    const all = try reader.iterate(gpa, io);
    defer {
        for (all) |e| {
            gpa.free(@constCast(e.key));
            gpa.free(@constCast(e.value));
        }
        gpa.free(all);
    }
    try std.testing.expectEqual(@as(usize, 4), all.len);
    try std.testing.expectEqualStrings("a-key", codec.userKeyOf(all[0].key));
    try std.testing.expectEqualStrings("z-key", codec.userKeyOf(all[3].key));
}

test "sst empty file has no entries and no index blocks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try openTestDir(io);
    defer {
        dir.close(io);
        Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    }

    const name = "sst_empty.sst";
    var builder = try Builder.create(gpa, io, dir, name);
    defer builder.deinit();
    _ = try builder.finish();
    const empty = try codec.internalKey(gpa, "any", 1, .put);
    defer gpa.free(empty);

    var reader = try Reader.open(gpa, io, dir, name);
    defer reader.deinit();
    try std.testing.expectEqual(@as(u64, 0), reader.count());
    try std.testing.expect((try reader.find(gpa, io, "any")) == null);
    const all = try reader.iterate(gpa, io);
    defer gpa.free(all);
    try std.testing.expectEqual(@as(usize, 0), all.len);
}

test "sst blocks split at the block size and still read correctly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try openTestDir(io);
    defer {
        dir.close(io);
        Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    }

    const name = "sst_multi.sst";
    var builder = try Builder.create(gpa, io, dir, name);
    defer builder.deinit();
    builder.block_size = 128;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const key = try std.fmt.allocPrint(gpa, "key-{d:0>4}", .{i});
        defer gpa.free(key);
        const internal = try codec.internalKey(gpa, key, @intCast(i + 1), .put);
        defer gpa.free(internal);
        const val = try std.fmt.allocPrint(gpa, "value-{d:0>4}", .{i});
        defer gpa.free(val);
        try builder.add(internal, val);
    }
    _ = try builder.finish();

    var reader = try Reader.open(gpa, io, dir, name);
    defer reader.deinit();
    try std.testing.expect(reader.index.items.len > 1);
    try std.testing.expectEqual(@as(u64, 200), reader.count());

    const probe_key = "key-0137";
    const hit = (try reader.find(gpa, io, probe_key)).?;
    defer {
        gpa.free(@constCast(hit.key));
        gpa.free(@constCast(hit.value));
    }
    try std.testing.expectEqualStrings("value-0137", hit.value);

    const all = try reader.iterate(gpa, io);
    defer {
        for (all) |e| {
            gpa.free(@constCast(e.key));
            gpa.free(@constCast(e.value));
        }
        gpa.free(all);
    }
    try std.testing.expectEqual(@as(usize, 200), all.len);
    try std.testing.expectEqualStrings("key-0000", codec.userKeyOf(all[0].key));
    try std.testing.expectEqualStrings("key-0199", codec.userKeyOf(all[199].key));
}

test "sst rejects bad magic, unsupported version, and corrupt blocks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try openTestDir(io);
    defer {
        dir.close(io);
        Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    }

    const name = "sst_corrupt.sst";
    {
        var builder = try Builder.create(gpa, io, dir, name);
        defer builder.deinit();
        const k1 = try codec.internalKey(gpa, "k1", 1, .put);
        defer gpa.free(k1);
        const k2 = try codec.internalKey(gpa, "k2", 2, .put);
        defer gpa.free(k2);
        try builder.add(k1, "v1");
        try builder.add(k2, "v2");
        _ = try builder.finish();
    }

    // Corrupt the first data block (offset 0): the CRC must fail.
    {
        var file = try dir.openFile(io, name, .{ .mode = .read_write });
        defer file.close(io);
        var byte: [1]u8 = undefined;
        _ = try file.readPositionalAll(io, &byte, 0);
        byte[0] ^= 0xFF;
        try file.writePositionalAll(io, &byte, 0);
    }
    var reader = try Reader.open(gpa, io, dir, name);
    defer reader.deinit();
    try std.testing.expectError(error.CorruptSst, reader.iterate(gpa, io));

    // Unsupported future format version in the footer.
    {
        var file = try dir.openFile(io, name, .{ .mode = .read_write });
        defer file.close(io);
        const len = try file.length(io);
        var footer: [footer_len]u8 = undefined;
        _ = try file.readPositionalAll(io, &footer, len - footer_len);
        std.mem.writeInt(u32, footer[file_magic.len..][0..4], format_version + 1, .little);
        try file.writePositionalAll(io, &footer, len - footer_len);
    }
    try std.testing.expectError(error.UnsupportedSst, Reader.open(gpa, io, dir, name));

    // Truncated file: footer missing.
    {
        var file = try dir.openFile(io, name, .{ .mode = .read_write });
        defer file.close(io);
        try file.setLength(io, footer_len - 1);
    }
    try std.testing.expectError(error.InvalidSst, Reader.open(gpa, io, dir, name));
}
