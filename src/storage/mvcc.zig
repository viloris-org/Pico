//! MVCC visibility and snapshot registry (roadmap Phase 5).
//!
//! This module is the target owner of the version-retention foundation that the
//! LSM storage builds on (docs/architecture/concurrency-control.md §"Versions
//! and Visibility" and §"WAL, Recovery, and Reclamation"). It owns two pure,
//! deterministic pieces: the visibility predicate that decides whether a
//! version interval `[created_seq, deleted_seq)` is visible at a snapshot
//! watermark, and the bounded registry of active snapshot watermarks that the
//! engine consults before reclaiming retained versions.
//!
//! Version retention and reclamation over live rows live in `table.zig`; the
//! engine wires this registry to those tables. The runtime is single-threaded
//! today, so the registry is a deliberately simple fixed-capacity list.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Visibility predicate for a version interval `[created_seq, deleted_seq)`
/// against snapshot watermark `s`:
///
///   visible(v, s) = v.created_seq <= s
///                and (v.deleted_seq is absent or s < v.deleted_seq)
///
/// A version created after `s` is invisible; a version deleted at or before `s`
/// is no longer visible at `s`. A `null` deletion marks a never-deleted
/// version (the newest live row).
pub fn visible(created_seq: u64, deleted_seq: ?u64, s: u64) bool {
    if (created_seq > s) return false;
    if (deleted_seq) |deleted| {
        if (s >= deleted) return false;
    }
    return true;
}

/// Error returned when the snapshot registry is at capacity.
pub const RegistryError = error{
    SnapshotLimitExceeded,
};

/// Bounded registry of active snapshot watermarks.
///
/// The runtime maintains `oldest_active_snapshot_seq`, or
/// `published_commit_seq + 1` when no snapshot is active. Version reclamation
/// may free only versions with `deleted_seq < oldest_active_snapshot_seq`, so
/// an active snapshot's view is preserved until the snapshot is released.
/// Registration and deregistration must occur on every statement path; leaked
/// snapshots surface as reclamation stalls, never as guessed-away versions.
///
/// Duplicate watermarks are meaningful: two snapshots at the same watermark are
/// each registered, and `unregister` releases exactly one of them.
pub const SnapshotRegistry = struct {
    gpa: Allocator,
    capacity: usize = 4096,
    watermarks: std.ArrayList(u64) = .empty,

    pub fn init(gpa: Allocator) SnapshotRegistry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *SnapshotRegistry) void {
        self.watermarks.deinit(self.gpa);
        self.* = undefined;
    }

    /// Register `s` as an active snapshot watermark. Fails explicitly beyond
    /// `capacity` rather than growing without bound.
    pub fn register(self: *SnapshotRegistry, s: u64) (RegistryError || Allocator.Error)!void {
        if (self.watermarks.items.len >= self.capacity) return error.SnapshotLimitExceeded;
        try self.watermarks.append(self.gpa, s);
    }

    /// Release one registration of watermark `s`. A no-op when `s` is not
    /// registered; a duplicate of the current minimum keeps it active.
    pub fn unregister(self: *SnapshotRegistry, s: u64) void {
        for (self.watermarks.items, 0..) |item, i| {
            if (item == s) {
                _ = self.watermarks.orderedRemove(i);
                return;
            }
        }
    }

    /// The lowest active snapshot watermark, or null when none is active.
    pub fn oldestActive(self: *const SnapshotRegistry) ?u64 {
        var oldest: ?u64 = null;
        for (self.watermarks.items) |s| {
            if (oldest) |current| {
                if (s < current) oldest = s;
            } else oldest = s;
        }
        return oldest;
    }

    /// Number of currently registered snapshot watermarks.
    pub fn count(self: *const SnapshotRegistry) usize {
        return self.watermarks.items.len;
    }
};

test "visible predicate respects creation and deletion boundaries" {
    // Never deleted: visible from its creation watermark onward.
    try std.testing.expect(visible(0, null, 0));
    try std.testing.expect(visible(5, null, 5));
    try std.testing.expect(visible(5, null, 100));
    // Created after the watermark: invisible even when never deleted.
    try std.testing.expect(!visible(6, null, 5));
    try std.testing.expect(!visible(5, null, 4));
    // Deleted interval [created, deleted): visible only while s < deleted.
    try std.testing.expect(visible(1, 4, 1));
    try std.testing.expect(visible(1, 4, 2));
    try std.testing.expect(visible(1, 4, 3));
    // Deleted at or before the watermark: invisible.
    try std.testing.expect(!visible(1, 4, 4));
    try std.testing.expect(!visible(1, 4, 5));
    // Created and deleted before the watermark: invisible.
    try std.testing.expect(!visible(2, 3, 3));
    try std.testing.expect(!visible(2, 3, 10));
}

test "snapshot registry tracks the oldest active watermark" {
    const gpa = std.testing.allocator;
    var reg = SnapshotRegistry.init(gpa);
    defer reg.deinit();

    try std.testing.expectEqual(@as(usize, 0), reg.count());
    try std.testing.expect(reg.oldestActive() == null);

    try reg.register(7);
    try reg.register(3);
    try reg.register(9);
    try std.testing.expectEqual(@as(usize, 3), reg.count());
    try std.testing.expectEqual(@as(?u64, 3), reg.oldestActive());

    reg.unregister(3);
    try std.testing.expectEqual(@as(?u64, 7), reg.oldestActive());

    // A duplicate watermark: releasing one keeps the other active.
    try reg.register(7);
    reg.unregister(7);
    try std.testing.expectEqual(@as(?u64, 7), reg.oldestActive());
    reg.unregister(7);
    try std.testing.expectEqual(@as(?u64, 9), reg.oldestActive());

    // Unregistering an absent watermark is a no-op.
    reg.unregister(123);
    try std.testing.expectEqual(@as(?u64, 9), reg.oldestActive());
    try std.testing.expectEqual(@as(usize, 1), reg.count());
}

test "snapshot registry rejects registration beyond capacity" {
    const gpa = std.testing.allocator;
    var reg = SnapshotRegistry.init(gpa);
    defer reg.deinit();
    reg.capacity = 2;

    try reg.register(1);
    try reg.register(2);
    try std.testing.expectError(error.SnapshotLimitExceeded, reg.register(3));
    // The registry is unchanged by the rejected registration.
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    try std.testing.expectEqual(@as(?u64, 1), reg.oldestActive());
}
