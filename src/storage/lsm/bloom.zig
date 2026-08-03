//! Full-key Bloom filter for SSTables (roadmap Phase 5).
//!
//! An SST's Bloom filter answers "might this user key be present in this
//! file?" with no false negatives and a bounded false positive rate. Point
//! lookups consult it before probing a file, so a definitive "absent" answer
//! skips the file's index and data-block reads; `sstable.zig` persists the
//! filter between the index block and the footer, and `store.zig` counts the
//! files skipped this way.
//!
//! The filter is built over the *user* keys of the entries a file contains
//! (not the internal keys with their MVCC sequence suffixes), because point
//! lookups probe by user key and within one SSTable every user key appears at
//! most once. It uses two independent 64-bit Wyhash values per key and double
//! hashing, so k hash positions come from one pair of hashes.
//!
//! The bit budget defaults to 10 bits per key, giving an expected false
//! positive rate around 1% for the optimal number of hash functions. The
//! wire bytes are versioned by the SSTable format version; a malformed or
//! inconsistent filter fails the file's CRC or decode validation rather than
//! being ignored.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bit budget per inserted key. 10 bits/key with the optimal k yields a false
/// positive rate around 1% (the classic LevelDB/RocksDB default).
pub const default_bits_per_key: usize = 10;

/// Upper bound on the number of hash functions; bounds both computation and
/// the k field validated by decode.
pub const max_hash_count: u32 = 30;

pub const Error = error{
    /// Filter bytes too short to carry the header.
    InvalidBloom,
    /// Filter bytes inconsistent: wrong length, illegal k, or a bit count
    /// that is not a multiple of 64.
    CorruptBloom,
} || Allocator.Error;

/// Two independent 64-bit hashes of one user key, used for double hashing.
pub const Hash = struct {
    h1: u64,
    h2: u64,
};

const seed_1: u64 = 0x9E37_79B9_7F4A_7C15;
const seed_2: u64 = 0xC2B2_AE3D_27D4_EB4F;

/// Hash a user key into two independent 64-bit values (Wyhash, two seeds).
pub fn hashKey(key: []const u8) Hash {
    return .{
        .h1 = std.hash.Wyhash.hash(seed_1, key),
        .h2 = std.hash.Wyhash.hash(seed_2, key),
    };
}

/// Number of hash functions for `n` keys over `m_bits` bits:
/// round((m/n) * ln 2), clamped to [1, max_hash_count].
fn optimalHashCount(n: usize, m_bits: u64) u32 {
    if (n == 0) return 0;
    // ln 2 ≈ 0.693; compute round((m * 693) / (n * 1000)) in u64.
    const ratio_num = m_bits * 693;
    const ratio_den = @as(u64, @intCast(n)) * 1000;
    const k = (ratio_num + ratio_den / 2) / ratio_den;
    return @intCast(@max(@as(u64, 1), @min(k, max_hash_count)));
}

/// An m-bit array with k hash functions. Owns its bit words.
pub const Filter = struct {
    bits: []u64,
    /// Total number of bits; always a multiple of 64. Zero means "no filter",
    /// where `mayContain` always returns true so callers keep probing.
    num_bits: u64,
    k: u32,

    pub fn deinit(self: *Filter, gpa: Allocator) void {
        gpa.free(self.bits);
        self.* = undefined;
    }

    /// Build a filter from the hashes of every key in a file. `hashes` may be
    /// empty, producing a no-op filter.
    pub fn build(gpa: Allocator, hashes: []const Hash, bits_per_key: usize) Error!Filter {
        const n = hashes.len;
        if (n == 0) return .{ .bits = try gpa.alloc(u64, 0), .num_bits = 0, .k = 0 };
        var m_bits = @as(u64, @intCast(n)) * bits_per_key;
        // Round up to a whole word so the bit array is word-aligned; at least
        // one word so a single key still gets a usable array.
        m_bits = @max(64, (m_bits + 63) & ~@as(u64, 63));
        const bits = try gpa.alloc(u64, @intCast(m_bits / 64));
        @memset(bits, 0);
        errdefer gpa.free(bits);
        var filter = Filter{ .bits = bits, .num_bits = m_bits, .k = optimalHashCount(n, m_bits) };
        for (hashes) |h| {
            var i: u32 = 0;
            while (i < filter.k) : (i += 1) {
                const bit = filter.hashIndex(h, i);
                filter.bits[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
            }
        }
        return filter;
    }

    /// True when `key` may be in the file; false only when it is definitely
    /// absent. A no-op filter (num_bits == 0) always returns true.
    pub fn mayContain(self: *const Filter, key: []const u8) bool {
        if (self.num_bits == 0) return true;
        const h = hashKey(key);
        var i: u32 = 0;
        while (i < self.k) : (i += 1) {
            const bit = self.hashIndex(h, i);
            if ((self.bits[bit / 64] & (@as(u64, 1) << @intCast(bit % 64))) == 0) return false;
        }
        return true;
    }

    /// Double hashing: the i-th position is (h1 + i*h2) mod m.
    fn hashIndex(self: *const Filter, h: Hash, i: u32) u64 {
        const g = h.h1 +% @as(u64, i) *% h.h2;
        return g % self.num_bits;
    }

    /// Wire bytes: [num_bits:u64][k:u32][bit words little-endian]. The caller
    /// owns the result.
    pub fn encode(self: *const Filter, gpa: Allocator) Error![]u8 {
        const header_len: usize = 12;
        const out = try gpa.alloc(u8, header_len + self.bits.len * 8);
        std.mem.writeInt(u64, out[0..8], self.num_bits, .little);
        std.mem.writeInt(u32, out[8..12], self.k, .little);
        for (self.bits, 0..) |word, i| {
            std.mem.writeInt(u64, out[header_len + i * 8 ..][0..8], word, .little);
        }
        return out;
    }

    /// Decode filter bytes produced by `encode`. The caller owns the result.
    pub fn decode(gpa: Allocator, bytes: []const u8) Error!Filter {
        const header_len: usize = 12;
        if (bytes.len < header_len) return error.InvalidBloom;
        const num_bits = std.mem.readInt(u64, bytes[0..8], .little);
        const k = std.mem.readInt(u32, bytes[8..12], .little);
        if (num_bits == 0) {
            if (k != 0 or bytes.len != header_len) return error.CorruptBloom;
            return .{ .bits = try gpa.alloc(u64, 0), .num_bits = 0, .k = 0 };
        }
        if (num_bits % 64 != 0) return error.CorruptBloom;
        if (k == 0 or k > max_hash_count) return error.CorruptBloom;
        const word_count = num_bits / 64;
        if (bytes.len != header_len + word_count * 8) return error.CorruptBloom;
        const bits = try gpa.alloc(u64, @intCast(word_count));
        errdefer gpa.free(bits);
        for (bits, 0..) |*word, i| {
            word.* = std.mem.readInt(u64, bytes[header_len + i * 8 ..][0..8], .little);
        }
        return .{ .bits = bits, .num_bits = num_bits, .k = k };
    }
};

// ── Tests ──

test "filter contains every inserted key and bounds false positives" {
    const gpa = std.testing.allocator;
    var hashes: std.ArrayList(Hash) = .empty;
    defer hashes.deinit(gpa);
    var keys: [200][]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        key.* = try std.fmt.allocPrint(gpa, "key-{d:0>4}", .{i});
        try hashes.append(gpa, hashKey(key.*));
    }
    defer for (keys) |k| gpa.free(k);

    var filter = try Filter.build(gpa, hashes.items, default_bits_per_key);
    defer filter.deinit(gpa);
    try std.testing.expect(filter.num_bits >= 200 * default_bits_per_key);
    for (keys) |key| try std.testing.expect(filter.mayContain(key));

    // Absent keys are rejected except for a small deterministic false positive
    // rate; 10 bits/key keeps it well under 5% across 1000 probes.
    var false_positives: usize = 0;
    for (0..1000) |i| {
        const probe = try std.fmt.allocPrint(gpa, "absent-{d:0>5}", .{i});
        defer gpa.free(probe);
        if (filter.mayContain(probe)) false_positives += 1;
    }
    try std.testing.expect(false_positives < 50);
}

test "empty filter is a no-op that always probes" {
    const gpa = std.testing.allocator;
    var filter = try Filter.build(gpa, &.{}, default_bits_per_key);
    defer filter.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 0), filter.num_bits);
    try std.testing.expect(filter.mayContain("anything"));
}

test "filter encode/decode round trips" {
    const gpa = std.testing.allocator;
    var hashes: std.ArrayList(Hash) = .empty;
    defer hashes.deinit(gpa);
    var keys: [64][]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        key.* = try std.fmt.allocPrint(gpa, "k-{d:0>3}", .{i});
        try hashes.append(gpa, hashKey(key.*));
    }
    defer for (keys) |k| gpa.free(k);
    var filter = try Filter.build(gpa, hashes.items, default_bits_per_key);
    defer filter.deinit(gpa);

    const encoded = try filter.encode(gpa);
    defer gpa.free(encoded);
    var decoded = try Filter.decode(gpa, encoded);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(filter.num_bits, decoded.num_bits);
    try std.testing.expectEqual(filter.k, decoded.k);
    for (keys) |key| try std.testing.expect(decoded.mayContain(key));
    try std.testing.expect(!decoded.mayContain("definitely-absent"));
}

test "filter decode rejects malformed bytes" {
    const gpa = std.testing.allocator;
    var hashes: std.ArrayList(Hash) = .empty;
    defer hashes.deinit(gpa);
    try hashes.append(gpa, hashKey("one"));

    var filter = try Filter.build(gpa, hashes.items, default_bits_per_key);
    defer filter.deinit(gpa);
    const encoded = try filter.encode(gpa);
    defer gpa.free(encoded);

    try std.testing.expectError(error.InvalidBloom, Filter.decode(gpa, encoded[0..10]));
    try std.testing.expectError(error.InvalidBloom, Filter.decode(gpa, &.{}));

    // Bit count not a multiple of 64.
    var bad_bits = try gpa.dupe(u8, encoded);
    defer gpa.free(bad_bits);
    std.mem.writeInt(u64, bad_bits[0..8], filter.num_bits + 1, .little);
    try std.testing.expectError(error.CorruptBloom, Filter.decode(gpa, bad_bits));

    // k out of range.
    var bad_k = try gpa.dupe(u8, encoded);
    defer gpa.free(bad_k);
    std.mem.writeInt(u32, bad_k[8..12], 0, .little);
    try std.testing.expectError(error.CorruptBloom, Filter.decode(gpa, bad_k));
    std.mem.writeInt(u32, bad_k[8..12], max_hash_count + 1, .little);
    try std.testing.expectError(error.CorruptBloom, Filter.decode(gpa, bad_k));

    // Truncated bit array.
    try std.testing.expectError(error.CorruptBloom, Filter.decode(gpa, encoded[0 .. encoded.len - 1]));
}
