//! KV collections (roadmap Phase 2).
//!
//! A KV collection maps a text key to a scalar value. `put` is an upsert: it
//! inserts a new entry or replaces the value of an existing key, so a key
//! always carries the most recently committed value. Entries preserve
//! insertion order for deterministic reads, and a replaced entry keeps its
//! position.
//!
//! This is the read-only KV slice: it defines key/value identity, upsert
//! ingestion, and projection/filter reads (through Runa Flow), and it does not
//! imply delete, TTLs, range scans beyond the Flow `where`/`limit` stages, or
//! mutation beyond `put`. Values are scalar-only (null/int/text/bool) in this
//! slice; a vector value is rejected rather than silently stored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");

pub const Error = error{
    /// A KV key must be non-empty text.
    MissingKey,
} || Allocator.Error;

/// One key/value entry. `key` and `item` are owned.
pub const Entry = struct {
    key: []u8,
    item: value.Value,

    pub fn deinit(self: *Entry, gpa: Allocator) void {
        gpa.free(self.key);
        self.item.deinit(gpa);
        self.* = undefined;
    }
};

/// A named KV collection. `by_key` provides identity lookup and upsert
/// rejection of duplicate keys; `order` preserves insertion order so reads
/// are deterministic (the same guarantee the document and relation slices
/// give).
pub const KvMap = struct {
    gpa: Allocator,
    name: []u8,
    by_key: std.StringHashMap(*Entry) = undefined,
    order: std.ArrayList(*Entry) = .empty,

    pub fn create(gpa: Allocator, name: []const u8) Allocator.Error!KvMap {
        return .{
            .gpa = gpa,
            .name = try gpa.dupe(u8, name),
            .by_key = std.StringHashMap(*Entry).init(gpa),
        };
    }

    pub fn deinit(self: *KvMap) void {
        var it = self.by_key.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.gpa);
            self.gpa.destroy(entry.value_ptr.*);
        }
        self.by_key.deinit();
        self.order.deinit(self.gpa);
        self.gpa.free(self.name);
        self.* = undefined;
    }

    /// Upsert one key/value pair, cloning `item`. A new key appends its entry
    /// to read order; an existing key keeps its position and its value is
    /// replaced. A failed upsert (allocation error, empty key) leaves both
    /// maps unchanged.
    pub fn put(self: *KvMap, key: []const u8, item: value.Value) Error!void {
        if (key.len == 0) return error.MissingKey;
        if (self.by_key.getPtr(key)) |existing| {
            const replacement = item.clone(self.gpa) catch |err| return err;
            existing.*.item.deinit(self.gpa);
            existing.*.item = replacement;
            return;
        }

        const owned = try self.gpa.create(Entry);
        owned.* = .{ .key = try self.gpa.dupe(u8, key), .item = .null };
        errdefer {
            owned.deinit(self.gpa);
            self.gpa.destroy(owned);
        }
        owned.item = item.clone(self.gpa) catch |err| return err;
        try self.by_key.put(owned.key, owned);
        try self.order.append(self.gpa, owned);
    }

    pub fn contains(self: *const KvMap, key: []const u8) bool {
        return self.by_key.contains(key);
    }

    /// Entry for an exact key, or null when the key is absent.
    pub fn get(self: *const KvMap, key: []const u8) ?*Entry {
        return self.by_key.get(key);
    }
};

test "kv map upserts keys and keeps insertion order stable" {
    const gpa = std.testing.allocator;
    var map = try KvMap.create(gpa, "cache");
    defer map.deinit();

    try map.put("a", .{ .int = 1 });
    var x_text: value.Value = .{ .text = try gpa.dupe(u8, "x") };
    defer x_text.deinit(gpa);
    try map.put("b", x_text);
    try map.put("c", .{ .bool = true });

    try std.testing.expectEqual(@as(usize, 3), map.order.items.len);
    try std.testing.expectEqualStrings("a", map.order.items[0].key);
    try std.testing.expectEqualStrings("b", map.order.items[1].key);
    try std.testing.expectEqualStrings("c", map.order.items[2].key);
    try std.testing.expectEqualStrings("x", map.get("b").?.item.text);

    // Upsert replaces the value in place and keeps the original position.
    try map.put("b", .{ .int = 42 });
    try std.testing.expectEqual(@as(usize, 3), map.order.items.len);
    try std.testing.expectEqualStrings("b", map.order.items[1].key);
    try std.testing.expectEqual(@as(i64, 42), map.get("b").?.item.int);

    // A new key appends; failed upserts leave both maps unchanged.
    try map.put("d", .{ .int = 4 });
    try std.testing.expectEqual(@as(usize, 4), map.order.items.len);
    try std.testing.expectError(error.MissingKey, map.put("", .{ .int = 5 }));
    try std.testing.expectEqual(@as(usize, 4), map.order.items.len);
    try std.testing.expect(!map.contains(""));
}

test "kv map clones values so callers may reuse or free their own" {
    const gpa = std.testing.allocator;
    var map = try KvMap.create(gpa, "cache");
    defer map.deinit();

    var caller_text: value.Value = .{ .text = try gpa.dupe(u8, "owned-by-caller") };
    try map.put("k", caller_text);
    const caller_ptr = caller_text.text.ptr;
    // Freeing the caller's value must not touch the map's clone.
    caller_text.deinit(gpa);

    try std.testing.expectEqualStrings("owned-by-caller", map.get("k").?.item.text);
    // The stored text does not alias the caller's (now freed) buffer.
    try std.testing.expect(map.get("k").?.item.text.ptr != caller_ptr);
}
