//! Durable checkpoint manifest (roadmap Phase 4).
//!
//! A checkpoint publishes a versioned manifest atomically over the live WAL
//! rewrite. The manifest records the commit watermark and the catalog objects
//! the checkpoint covered, so recovery can (a) reject a manifest written by an
//! incompatible build and (b) detect a torn or inconsistent checkpoint: every
//! object the manifest names must exist in the catalog rebuilt from the WAL,
//! and the recovered commit watermark must be at or past the manifest's.
//!
//! This is the durable manifest boundary that Phase 5's LSM storage builds on;
//! before SSTables exist, advancing persistent progress is the WAL rewrite, and
//! the manifest is its versioned publication record. A manifest is an internal
//! recovery mechanism, not a backup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vfs_mod = @import("vfs.zig");

pub const Error = error{
    InvalidManifest,
    UnsupportedManifest,
    CorruptManifest,
    ManifestMismatch,
} || Allocator.Error;

/// Self-identifying magic so a changed layout never reinterprets old bytes.
pub const file_magic = "RUNADB_MAN";
pub const FORMAT_VERSION: u32 = 1;
pub const FORMAT_VERSION_MIN: u32 = 1;
const file_header_len = file_magic.len + @sizeOf(u32);

/// The catalog object kinds a checkpoint can cover.
pub const ObjectKind = enum(u8) {
    table = 1,
    document = 2,
    graph = 3,
    kv = 4,
};

/// One catalog object named by a checkpoint.
pub const CatalogObject = struct {
    kind: ObjectKind,
    name: []const u8,
};

/// The durable record of one checkpoint.
pub const Manifest = struct {
    /// Published commit watermark at checkpoint time. Recovery requires the
    /// rebuilt watermark to be at or past this value.
    commit_seq: u64,
    /// Catalog objects the checkpoint covered, in deterministic order.
    objects: []CatalogObject,
};

/// Serialize a manifest (LE) for publication. The caller owns the bytes.
pub fn encode(gpa: Allocator, manifest: *const Manifest) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try output.appendSlice(gpa, file_magic);
    try writeU32(&output, gpa, FORMAT_VERSION);
    try writeU64(&output, gpa, manifest.commit_seq);
    if (manifest.objects.len > std.math.maxInt(u32)) return error.InvalidManifest;
    try writeU32(&output, gpa, @intCast(manifest.objects.len));
    for (manifest.objects) |object| {
        try output.append(gpa, @intFromEnum(object.kind));
        if (object.name.len > std.math.maxInt(u32)) return error.InvalidManifest;
        try writeU32(&output, gpa, @intCast(object.name.len));
        try output.appendSlice(gpa, object.name);
    }
    return output.toOwnedSlice(gpa);
}

/// Parse and validate a manifest. `objects` and `names` are owned by the caller.
pub fn decode(gpa: Allocator, bytes: []const u8) Error!Manifest {
    var pos: usize = 0;
    if (bytes.len < file_header_len) return error.InvalidManifest;
    if (!std.mem.eql(u8, bytes[0..file_magic.len], file_magic)) return error.InvalidManifest;
    pos = file_magic.len;
    const version = try readU32(bytes, &pos);
    if (version < FORMAT_VERSION_MIN or version > FORMAT_VERSION) return error.UnsupportedManifest;
    const commit_seq = try readU64(bytes, &pos);
    const n_objects = try readU32(bytes, &pos);
    if (n_objects > 1_000_000) return error.InvalidManifest;
    const objects = try gpa.alloc(CatalogObject, n_objects);
    errdefer gpa.free(objects);
    var copied: usize = 0;
    errdefer for (objects[0..copied]) |*object| gpa.free(object.name);
    for (0..n_objects) |i| {
        if (pos >= bytes.len) return error.InvalidManifest;
        const kind = std.enums.fromInt(ObjectKind, bytes[pos]) orelse return error.InvalidManifest;
        pos += 1;
        const name_len = try readU32(bytes, &pos);
        if (name_len > 1024 * 1024) return error.InvalidManifest;
        if (bytes.len -| pos < name_len) return error.InvalidManifest;
        const name = try gpa.dupe(u8, bytes[pos .. pos + name_len]);
        pos += name_len;
        objects[i] = .{ .kind = kind, .name = name };
        copied += 1;
    }
    if (pos != bytes.len) return error.InvalidManifest;
    return .{ .commit_seq = commit_seq, .objects = objects };
}

/// Publish a manifest atomically into the data directory. The caller holds the
/// writer lock, so no checkpoint or DDL can race the publication.
pub fn publish(vfs: *vfs_mod.Vfs, gpa: Allocator, manifest: *const Manifest) !void {
    const bytes = try encode(gpa, manifest);
    defer gpa.free(bytes);
    var atomic = try vfs.createAtomicFile("manifest");
    defer atomic.deinit();
    try atomic.writeAtAll(bytes, 0);
    try atomic.sync();
    try atomic.commit();
}

/// Read and validate the persisted manifest, or null when no checkpoint has
/// published one yet.
pub fn read(gpa: Allocator, vfs: *vfs_mod.Vfs) !?Manifest {
    if (!try vfs.exists("manifest")) return null;
    var file = try vfs.openFile("manifest", .{ .read = true, .write = false });
    defer file.close();
    const len = try file.size();
    if (len == 0 or len > 64 * 1024 * 1024) return error.CorruptManifest;
    const bytes = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(bytes);
    const read_len = try file.readAt(bytes, 0);
    if (read_len != len) return error.CorruptManifest;
    const parsed = try decode(gpa, bytes);
    return parsed;
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

fn readU32(bytes: []const u8, pos: *usize) Error!u32 {
    if (bytes.len -| pos.* < 4) return error.InvalidManifest;
    const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn readU64(bytes: []const u8, pos: *usize) Error!u64 {
    if (bytes.len -| pos.* < 8) return error.InvalidManifest;
    const v = std.mem.readInt(u64, bytes[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

test "manifest round trips exactly" {
    const gpa = std.testing.allocator;
    var objects = [_]CatalogObject{
        .{ .kind = .table, .name = "customer" },
        .{ .kind = .document, .name = "books" },
        .{ .kind = .graph, .name = "social" },
        .{ .kind = .kv, .name = "cache" },
    };
    const manifest = Manifest{ .commit_seq = 42, .objects = objects[0..] };
    const bytes = try encode(gpa, &manifest);
    defer gpa.free(bytes);
    const decoded = try decode(gpa, bytes);
    defer {
        for (decoded.objects) |*object| gpa.free(object.name);
        gpa.free(decoded.objects);
    }
    try std.testing.expectEqual(@as(u64, 42), decoded.commit_seq);
    try std.testing.expectEqual(@as(usize, 4), decoded.objects.len);
    try std.testing.expectEqual(ObjectKind.document, decoded.objects[1].kind);
    try std.testing.expectEqualStrings("books", decoded.objects[1].name);
    try std.testing.expectEqual(ObjectKind.kv, decoded.objects[3].kind);
    try std.testing.expectEqualStrings("cache", decoded.objects[3].name);
}

test "manifest decode rejects bad magic, version, and trailing bytes" {
    const gpa = std.testing.allocator;
    var objects = [_]CatalogObject{.{ .kind = .table, .name = "t" }};
    const manifest = Manifest{ .commit_seq = 1, .objects = objects[0..] };
    const bytes = try encode(gpa, &manifest);
    defer gpa.free(bytes);

    // Bad magic.
    var bad_magic = try gpa.dupe(u8, bytes);
    defer gpa.free(bad_magic);
    @memset(bad_magic[0..4], 'X');
    try std.testing.expectError(error.InvalidManifest, decode(gpa, bad_magic));

    // Unsupported future version.
    var future = try gpa.dupe(u8, bytes);
    defer gpa.free(future);
    std.mem.writeInt(u32, future[file_magic.len..][0..4], FORMAT_VERSION + 1, .little);
    try std.testing.expectError(error.UnsupportedManifest, decode(gpa, future));

    // Truncated body.
    try std.testing.expectError(error.InvalidManifest, decode(gpa, bytes[0 .. bytes.len - 1]));
}
