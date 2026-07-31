//! Immutable Observation Evidence metadata and payload-file ownership.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const MAX_PAYLOAD_LENGTH: usize = 8 * 1024 * 1024;
pub const DIGEST_LENGTH: usize = 32;

const file_magic = "RUNA_EVID";
const format_version: u16 = 1;
const digest_algorithm_blake3_256: u8 = 1;
const header_len = file_magic.len + 2 + 8 + 8 + 1 + DIGEST_LENGTH;
const trailer_len = 4;

pub const Modality = enum(u8) {
    text = 1,
    image = 2,
    audio = 3,
    video = 4,
    sensor = 5,
    other = 6,
};

pub const Metadata = struct {
    evidence_id: u64,
    object_id: []const u8,
    modality: Modality,
    media_type: []const u8,
    observed_at: []const u8,
    origin: []const u8,
    owner: []const u8,
    payload_length: u64,
    payload_digest: [DIGEST_LENGTH]u8,
};

pub const Record = struct {
    evidence_id: u64,
    object_id: []u8,
    modality: Modality,
    media_type: []u8,
    observed_at: []u8,
    origin: []u8,
    owner: []u8,
    payload_length: u64,
    payload_digest: [DIGEST_LENGTH]u8,

    pub fn clone(gpa: Allocator, source: Metadata) !Record {
        const object_id = try gpa.dupe(u8, source.object_id);
        errdefer gpa.free(object_id);
        const media_type = try gpa.dupe(u8, source.media_type);
        errdefer gpa.free(media_type);
        const observed_at = try gpa.dupe(u8, source.observed_at);
        errdefer gpa.free(observed_at);
        const origin = try gpa.dupe(u8, source.origin);
        errdefer gpa.free(origin);
        const owner = try gpa.dupe(u8, source.owner);
        return .{
            .evidence_id = source.evidence_id,
            .object_id = object_id,
            .modality = source.modality,
            .media_type = media_type,
            .observed_at = observed_at,
            .origin = origin,
            .owner = owner,
            .payload_length = source.payload_length,
            .payload_digest = source.payload_digest,
        };
    }

    pub fn metadata(self: *const Record) Metadata {
        return .{
            .evidence_id = self.evidence_id,
            .object_id = self.object_id,
            .modality = self.modality,
            .media_type = self.media_type,
            .observed_at = self.observed_at,
            .origin = self.origin,
            .owner = self.owner,
            .payload_length = self.payload_length,
            .payload_digest = self.payload_digest,
        };
    }

    pub fn deinit(self: *Record, gpa: Allocator) void {
        gpa.free(self.object_id);
        gpa.free(self.media_type);
        gpa.free(self.observed_at);
        gpa.free(self.origin);
        gpa.free(self.owner);
        self.* = undefined;
    }
};

pub fn validateMetadata(metadata: Metadata) !void {
    if (metadata.evidence_id == 0) return error.InvalidEvidence;
    if (metadata.object_id.len == 0 or metadata.object_id.len > 1024) return error.InvalidEvidence;
    if (!validMediaType(metadata.media_type)) return error.InvalidMediaType;
    if (metadata.observed_at.len > 128 or !hasExplicitUtcOffset(metadata.observed_at)) return error.InvalidObservationTime;
    if (metadata.origin.len == 0 or metadata.origin.len > 4096) return error.InvalidEvidence;
    if (metadata.owner.len == 0 or metadata.owner.len > 1024) return error.InvalidEvidence;
    if (metadata.payload_length > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;
}

fn validMediaType(media_type: []const u8) bool {
    if (media_type.len < 3 or media_type.len > 255) return false;
    const slash = std.mem.indexOfScalar(u8, media_type, '/') orelse return false;
    if (slash == 0 or slash + 1 == media_type.len) return false;
    for (media_type) |byte| {
        if (std.ascii.isUpper(byte)) return false;
        if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!#$&^_.+-/", byte) != null)) return false;
    }
    return true;
}

fn hasExplicitUtcOffset(value: []const u8) bool {
    if (value.len < 2) return false;
    if (value[value.len - 1] == 'Z') return true;
    const time_separator = std.mem.indexOfScalar(u8, value, 'T') orelse return false;
    for (value[time_separator + 1 ..]) |byte| {
        if (byte == '+' or byte == '-') return true;
    }
    return false;
}

pub fn digest(payload: []const u8) [DIGEST_LENGTH]u8 {
    var result: [DIGEST_LENGTH]u8 = undefined;
    std.crypto.hash.Blake3.hash(payload, &result, .{});
    return result;
}

pub const Store = struct {
    io: Io,
    dir: Io.Dir,
    sync_files: bool,

    pub fn open(io: Io, data_dir: []const u8, sync_files: bool) !Store {
        var root = try Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer root.close(io);
        const dir = try root.createDirPathOpen(io, "payloads", .{ .open_options = .{ .iterate = true } });
        return .{ .io = io, .dir = dir, .sync_files = sync_files };
    }

    pub fn deinit(self: *Store) void {
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn publish(self: *Store, evidence_id: u64, payload: []const u8) ![DIGEST_LENGTH]u8 {
        if (payload.len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;
        const payload_digest = digest(payload);
        const name = fileName(evidence_id);
        const exists = blk: {
            self.dir.access(self.io, &name, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        if (exists) return error.EvidenceExists;

        const total_len = std.math.add(usize, header_len + trailer_len, payload.len) catch return error.PayloadTooLarge;
        const encoded = try std.heap.page_allocator.alloc(u8, total_len);
        defer std.heap.page_allocator.free(encoded);
        encodeFile(encoded, evidence_id, payload, payload_digest);

        var atomic = try self.dir.createFileAtomic(self.io, &name, .{ .replace = false });
        defer atomic.deinit(self.io);
        try atomic.file.writePositionalAll(self.io, encoded, 0);
        if (self.sync_files) try atomic.file.sync(self.io);
        try atomic.link(self.io);
        if (self.sync_files) try syncDir(self.dir, self.io);
        return payload_digest;
    }

    pub fn read(self: *Store, gpa: Allocator, evidence_id: u64, expected_length: u64, expected_digest: [DIGEST_LENGTH]u8) ![]u8 {
        const name = fileName(evidence_id);
        var file = try self.dir.openFile(self.io, &name, .{ .mode = .read_only });
        defer file.close(self.io);
        const length = try file.length(self.io);
        if (length > header_len + MAX_PAYLOAD_LENGTH + trailer_len) return error.CorruptPayload;
        const encoded = try gpa.alloc(u8, @intCast(length));
        errdefer gpa.free(encoded);
        const got = try file.readPositionalAll(self.io, encoded, 0);
        if (got != encoded.len) return error.CorruptPayload;
        const payload = try validateFile(encoded, evidence_id, expected_length, expected_digest);
        const result = try gpa.dupe(u8, payload);
        gpa.free(encoded);
        return result;
    }

    pub fn validateReference(self: *Store, gpa: Allocator, metadata: Metadata) !void {
        const payload = try self.read(gpa, metadata.evidence_id, metadata.payload_length, metadata.payload_digest);
        gpa.free(payload);
    }

    pub const ReclaimStats = struct { count: u64 = 0, bytes: u64 = 0 };

    pub fn reclaimOrphans(self: *Store, committed: *const std.AutoHashMap(u64, usize)) !ReclaimStats {
        var result: ReclaimStats = .{};
        var iterator = self.dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const id = parseFileName(entry.name) orelse continue;
            if (committed.contains(id)) continue;
            const stat = try self.dir.statFile(self.io, entry.name, .{});
            try self.dir.deleteFile(self.io, entry.name);
            result.count += 1;
            result.bytes += stat.size;
        }
        if (result.count != 0 and self.sync_files) try syncDir(self.dir, self.io);
        return result;
    }
};

fn fileName(evidence_id: u64) [20]u8 {
    var name: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&name, "{x:0>16}.rpe", .{evidence_id}) catch unreachable;
    return name;
}

fn parseFileName(name: []const u8) ?u64 {
    if (name.len != 20 or !std.mem.eql(u8, name[16..], ".rpe")) return null;
    return std.fmt.parseInt(u64, name[0..16], 16) catch null;
}

fn encodeFile(out: []u8, evidence_id: u64, payload: []const u8, payload_digest: [DIGEST_LENGTH]u8) void {
    var pos: usize = 0;
    @memcpy(out[pos..][0..file_magic.len], file_magic);
    pos += file_magic.len;
    std.mem.writeInt(u16, out[pos..][0..2], format_version, .little);
    pos += 2;
    std.mem.writeInt(u64, out[pos..][0..8], evidence_id, .little);
    pos += 8;
    std.mem.writeInt(u64, out[pos..][0..8], payload.len, .little);
    pos += 8;
    out[pos] = digest_algorithm_blake3_256;
    pos += 1;
    @memcpy(out[pos..][0..DIGEST_LENGTH], &payload_digest);
    pos += DIGEST_LENGTH;
    @memcpy(out[pos..][0..payload.len], payload);
    pos += payload.len;
    std.mem.writeInt(u32, out[pos..][0..4], std.hash.Crc32.hash(out[0..pos]), .little);
}

fn validateFile(encoded: []const u8, evidence_id: u64, expected_length: u64, expected_digest: [DIGEST_LENGTH]u8) ![]const u8 {
    if (encoded.len < header_len + trailer_len) return error.CorruptPayload;
    if (!std.mem.eql(u8, encoded[0..file_magic.len], file_magic)) return error.UnsupportedPayloadFormat;
    var pos: usize = file_magic.len;
    if (std.mem.readInt(u16, encoded[pos..][0..2], .little) != format_version) return error.UnsupportedPayloadFormat;
    pos += 2;
    if (std.mem.readInt(u64, encoded[pos..][0..8], .little) != evidence_id) return error.CorruptPayload;
    pos += 8;
    const length = std.mem.readInt(u64, encoded[pos..][0..8], .little);
    pos += 8;
    if (length != expected_length or length > MAX_PAYLOAD_LENGTH) return error.CorruptPayload;
    if (encoded[pos] != digest_algorithm_blake3_256) return error.UnsupportedPayloadFormat;
    pos += 1;
    if (!std.mem.eql(u8, encoded[pos..][0..DIGEST_LENGTH], &expected_digest)) return error.CorruptPayload;
    pos += DIGEST_LENGTH;
    const payload_len: usize = @intCast(length);
    if (encoded.len != header_len + payload_len + trailer_len) return error.CorruptPayload;
    const payload = encoded[pos .. pos + payload_len];
    pos += payload_len;
    if (!std.mem.eql(u8, &digest(payload), &expected_digest)) return error.CorruptPayload;
    const stored_crc = std.mem.readInt(u32, encoded[pos..][0..4], .little);
    if (stored_crc != std.hash.Crc32.hash(encoded[0..pos])) return error.CorruptPayload;
    return payload;
}

fn syncDir(dir: Io.Dir, io: Io) !void {
    var handle = try dir.openFile(io, ".", .{ .mode = .read_only });
    defer handle.close(io);
    try handle.sync(io);
}

test "payload file round trips and rejects a mismatched digest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const path = "zig-cache/runadb-evidence-store";
    Io.Dir.cwd().deleteTree(io, path) catch {};
    defer Io.Dir.cwd().deleteTree(io, path) catch {};
    var store = try Store.open(io, path, false);
    defer store.deinit();
    const expected = try store.publish(1, "image bytes");
    const payload = try store.read(gpa, 1, 11, expected);
    defer gpa.free(payload);
    try std.testing.expectEqualStrings("image bytes", payload);
    var wrong = expected;
    wrong[0] ^= 1;
    try std.testing.expectError(error.CorruptPayload, store.read(gpa, 1, 11, wrong));
}

test "orphan cleanup preserves committed payloads" {
    const io = std.testing.io;
    const path = "zig-cache/runadb-evidence-orphans";
    Io.Dir.cwd().deleteTree(io, path) catch {};
    defer Io.Dir.cwd().deleteTree(io, path) catch {};
    var store = try Store.open(io, path, false);
    defer store.deinit();
    _ = try store.publish(1, "kept");
    _ = try store.publish(2, "orphan");
    var committed = std.AutoHashMap(u64, usize).init(std.testing.allocator);
    defer committed.deinit();
    try committed.put(1, 0);
    const stats = try store.reclaimOrphans(&committed);
    try std.testing.expectEqual(@as(u64, 1), stats.count);
    try std.testing.expectError(error.FileNotFound, store.read(std.testing.allocator, 2, 6, digest("orphan")));
}
