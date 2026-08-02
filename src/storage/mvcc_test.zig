//! Engine-level MVCC version retention tests (roadmap Phase 5).
//!
//! Deterministic coverage of the snapshot/retention contract in
//! docs/architecture/concurrency-control.md §"WAL, Recovery, and Reclamation"
//! and §"Required Invariants": active snapshots block reclamation, a snapshot
//! read at a fixed watermark is stable across later commits, point and range
//! reads interpret the full update/delete/reinsert history, and the
//! transaction-aware read path keeps read-your-writes with the new
//! snapshot-aware signature.

const std = @import("std");
const Io = std.Io;
const engine_mod = @import("engine.zig");
const value = @import("value.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

fn openEngine(dir: []const u8) !engine_mod.Engine {
    return engine_mod.Engine.open(gpa, io, dir, false);
}

fn cleanDir(name: []const u8) void {
    Io.Dir.cwd().deleteTree(io, name) catch {};
}

/// Open a fresh engine, wiping any prior data at `dir`.
fn freshEngine(dir: []const u8) !engine_mod.Engine {
    cleanDir(dir);
    return engine_mod.Engine.open(gpa, io, dir, false);
}

fn makeTable(eng: *engine_mod.Engine, name: []const u8, pk_col: []const u8, extra: []const value.Column) !void {
    var columns: std.ArrayList(value.Column) = .empty;
    defer {
        for (columns.items) |*c| c.deinit(gpa);
        columns.deinit(gpa);
    }
    try columns.append(gpa, .{ .name = try gpa.dupe(u8, pk_col), .type_tag = .int, .primary_key = true });
    for (extra) |c| try columns.append(gpa, try c.clone(gpa));
    try eng.createTable(name, columns.items);
}

fn col(name: []const u8, tag: value.TypeTag) value.Column {
    return .{ .name = @constCast(name), .type_tag = tag };
}

test "an active old snapshot prevents reclamation until it is released" {
    const dir = "zig-cache/runadb-mvcc-reclaim";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        cleanDir(dir);
    }
    try makeTable(&eng, "t", "id", &.{col("v", .int)});

    try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
    const old_snapshot = eng.publishedSeq();
    // A second connection holds a snapshot at the pre-update watermark.
    try eng.registerSnapshot(old_snapshot);

    try eng.update("t", .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 11 } });
    const table = eng.getTable("t").?;
    try std.testing.expectEqual(@as(usize, 1), table.retained.items.len);

    // The active snapshot (1) still overlaps the retained interval [1,2), so
    // reclamation must not free it.
    try std.testing.expectEqual(@as(usize, 0), eng.reclaimRetainedVersions());
    try std.testing.expectEqual(@as(usize, 1), table.retained.items.len);
    try std.testing.expectEqual(@as(usize, 1), eng.snapshot_registry.count());

    // After the snapshot is released, reclamation proceeds...
    eng.unregisterSnapshot(old_snapshot);
    try std.testing.expectEqual(@as(usize, 1), eng.reclaimRetainedVersions());
    try std.testing.expectEqual(@as(usize, 0), table.retained.items.len);

    // ...and results for new snapshots are unchanged: the live row is current.
    var res = try eng.selectByPk("t", .{ .int = 1 }, eng.publishedSeq());
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqual(@as(i64, 11), res.rows[0].values[1].int);
}

test "a snapshot read at a fixed watermark is stable across later commits" {
    const dir = "zig-cache/runadb-mvcc-snapshot-stable";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        cleanDir(dir);
    }
    try makeTable(&eng, "t", "id", &.{col("v", .int)});
    try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
    try eng.insert("t", &.{ .{ .int = 2 }, .{ .int = 20 } });
    const snapshot = eng.publishedSeq();

    // Reads register and deregister their watermark around the scan: the
    // registry is empty both before and after the call, never leaking a slot.
    try std.testing.expectEqual(@as(usize, 0), eng.snapshot_registry.count());
    var first = try eng.selectAll("t", snapshot);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 0), eng.snapshot_registry.count());
    try std.testing.expectEqual(@as(usize, 2), first.rows.len);

    // Later commits land: row 2 is updated and row 3 is inserted.
    try eng.update("t", .{ .int = 2 }, &.{ .{ .int = 2 }, .{ .int = 99 } });
    try eng.insert("t", &.{ .{ .int = 3 }, .{ .int = 30 } });

    // The same snapshot still returns exactly the versions committed at or
    // before it (reads do not wait for writes).
    var again = try eng.selectAll("t", snapshot);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 2), again.rows.len);
    try std.testing.expectEqual(@as(i64, 10), again.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 20), again.rows[1].values[1].int);
}

test "snapshot point reads across update, delete, and reinsert history" {
    const dir = "zig-cache/runadb-mvcc-point-history";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        cleanDir(dir);
    }
    try makeTable(&eng, "t", "id", &.{col("v", .int)});
    try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
    try eng.update("t", .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 11 } });
    try eng.delete("t", .{ .int = 1 });
    try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 100 } });

    // At s=1 the original version is visible.
    var at_one = try eng.selectByPk("t", .{ .int = 1 }, 1);
    defer at_one.deinit();
    try std.testing.expectEqual(@as(usize, 1), at_one.rows.len);
    try std.testing.expectEqual(@as(i64, 10), at_one.rows[0].values[1].int);

    // At s=2 the updated version is visible.
    var at_two = try eng.selectByPk("t", .{ .int = 1 }, 2);
    defer at_two.deinit();
    try std.testing.expectEqual(@as(i64, 11), at_two.rows[0].values[1].int);

    // Deleted before s → absent at s=3.
    var at_three = try eng.selectByPk("t", .{ .int = 1 }, 3);
    defer at_three.deinit();
    try std.testing.expectEqual(@as(usize, 0), at_three.rows.len);

    // Reinserted after s → still absent at s=3 (the reinsert is at seq 4).
    var at_three_again = try eng.selectByPk("t", .{ .int = 1 }, 3);
    defer at_three_again.deinit();
    try std.testing.expectEqual(@as(usize, 0), at_three_again.rows.len);

    // At s=4 the reinserted version is visible again.
    var at_four = try eng.selectByPk("t", .{ .int = 1 }, 4);
    defer at_four.deinit();
    try std.testing.expectEqual(@as(i64, 100), at_four.rows[0].values[1].int);
}

test "snapshot range scans return only versions committed at or before the watermark" {
    const dir = "zig-cache/runadb-mvcc-range";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        cleanDir(dir);
    }
    try makeTable(&eng, "t", "id", &.{col("v", .int)});
    try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
    try eng.insert("t", &.{ .{ .int = 2 }, .{ .int = 20 } });
    const snapshot = eng.publishedSeq();
    // A later insert and a later update land after the watermark.
    try eng.insert("t", &.{ .{ .int = 3 }, .{ .int = 30 } });
    try eng.update("t", .{ .int = 2 }, &.{ .{ .int = 2 }, .{ .int = 99 } });

    var rows = try eng.selectAll("t", snapshot);
    defer rows.deinit();
    // Only the two versions committed at or before the watermark; row 2 keeps
    // its watermark-era value and row 3 is absent.
    try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
    try std.testing.expectEqual(@as(i64, 10), rows.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 20), rows.rows[1].values[1].int);
}

test "recovery rebuilds retained version history from the wal" {
    const dir = "zig-cache/runadb-mvcc-recovery";
    cleanDir(dir);
    {
        var eng = try openEngine(dir);
        defer eng.deinit();
        try makeTable(&eng, "t", "id", &.{col("v", .int)});
        try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
        try eng.update("t", .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 11 } });
        try eng.delete("t", .{ .int = 1 });
        try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 100 } });
    }
    {
        // Recovery replays the commit sequences, so old snapshots still see the
        // pre-update and pre-delete versions after restart.
        var eng = try openEngine(dir);
        defer eng.deinit();
        var at_one = try eng.selectByPk("t", .{ .int = 1 }, 1);
        defer at_one.deinit();
        try std.testing.expectEqual(@as(i64, 10), at_one.rows[0].values[1].int);
        var at_two = try eng.selectByPk("t", .{ .int = 1 }, 2);
        defer at_two.deinit();
        try std.testing.expectEqual(@as(i64, 11), at_two.rows[0].values[1].int);
        // Deleted at 3, reinserted at 4: absent at 3, present again at 4.
        var at_three = try eng.selectByPk("t", .{ .int = 1 }, 3);
        defer at_three.deinit();
        try std.testing.expectEqual(@as(usize, 0), at_three.rows.len);
        var at_four = try eng.selectByPk("t", .{ .int = 1 }, 4);
        defer at_four.deinit();
        try std.testing.expectEqual(@as(i64, 100), at_four.rows[0].values[1].int);
    }
    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "read-your-writes holds through the snapshot-aware transaction read path" {
    const dir = "zig-cache/runadb-mvcc-tx-read-your-writes";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        cleanDir(dir);
    }
    try makeTable(&eng, "t", "id", &.{col("v", .int)});
    try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
    try eng.insert("t", &.{ .{ .int = 3 }, .{ .int = 30 } });

    var tx = eng.beginTransaction();
    defer tx.deinit();
    try eng.stageInsert(&tx, "t", &.{ .{ .int = 2 }, .{ .int = 20 } });
    try eng.stageUpdate(&tx, "t", .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 11 } });
    try eng.stageDelete(&tx, "t", .{ .int = 3 });

    const snapshot_seq = eng.publishedSeq();

    // Point reads merge the private write set over the committed snapshot.
    var updated = try eng.selectByPkTx(&tx, "t", .{ .int = 1 }, snapshot_seq);
    defer updated.deinit();
    try std.testing.expectEqual(@as(usize, 1), updated.rows.len);
    try std.testing.expectEqual(@as(i64, 11), updated.rows[0].values[1].int);

    var inserted = try eng.selectByPkTx(&tx, "t", .{ .int = 2 }, snapshot_seq);
    defer inserted.deinit();
    try std.testing.expectEqual(@as(i64, 20), inserted.rows[0].values[1].int);

    var deleted = try eng.selectByPkTx(&tx, "t", .{ .int = 3 }, snapshot_seq);
    defer deleted.deinit();
    try std.testing.expectEqual(@as(usize, 0), deleted.rows.len);

    // The merged scan contains exactly the transaction's view: committed rows
    // in read order, staged delete removed, staged insert appended.
    var all = try eng.selectAllTx(&tx, "t", snapshot_seq);
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 2), all.rows.len);
    try std.testing.expectEqual(@as(i64, 11), all.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 20), all.rows[1].values[1].int);

    // Committing publishes exactly that state to fresh snapshots.
    try eng.commitTransaction(&tx);
    var committed = try eng.selectAll("t", eng.publishedSeq());
    defer committed.deinit();
    try std.testing.expectEqual(@as(usize, 2), committed.rows.len);
    try std.testing.expectEqual(@as(i64, 11), committed.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 20), committed.rows[1].values[1].int);
}
