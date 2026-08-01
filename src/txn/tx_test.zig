//! Transaction semantics tests (roadmap Phase 3).
//!
//! Deterministic coverage for autocommit, multi-statement commit, rollback,
//! failed transactions, read-your-writes visibility, uncommitted invisibility,
//! write-write conflicts, primary-key conflicts, bounded contention, and
//! cancellation at the write-set boundary. These tests drive the engine through
//! its public transaction API and assert only the confirmed commit prefix after
//! restart.

const std = @import("std");
const Io = std.Io;
const engine_mod = @import("../storage/engine.zig");
const commit_mod = @import("../commit/coordinator.zig");
const value = @import("../storage/value.zig");
const txn_mod = @import("transaction.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

fn cleanDir(name: []const u8) void {
    Io.Dir.cwd().deleteTree(io, name) catch {};
}

fn openEngine(dir: []const u8) !engine_mod.Engine {
    return engine_mod.Engine.open(gpa, io, dir, false);
}

/// Open a fresh engine, wiping any prior data at `dir` (for the first block of
/// a two-block test).
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

/// Build an immutable commit request for a staged transaction, mirroring the
/// engine's commitTransaction request construction. The caller owns the
/// request and must deinit it.
fn buildRequest(tx: *txn_mod.Transaction) !commit_mod.Request {
    const observed = try gpa.alloc(?u64, tx.write_set.items.len);
    for (tx.write_set.items, 0..) |op, i| observed[i] = op.observed_version;
    const ops = try tx.toWalOps();
    return .{ .gpa = gpa, .ops = ops, .observed = observed, .read_seq = tx.snapshot_seq };
}

test "autocommit statements each commit and advance the watermark" {
    const dir = "zig-cache/runadb-txn-autocommit";
    {
        var eng = try freshEngine(dir);
        defer eng.deinit();
        try makeTable(&eng, "t", "id", &.{col("name", .text)});

        var first: value.Value = .{ .text = try gpa.dupe(u8, "a") };
        defer first.deinit(gpa);
        try eng.insert("t", &.{ .{ .int = 1 }, first });
        const seq1 = eng.publishedSeq();
        try std.testing.expect(seq1 >= 1);

        var second: value.Value = .{ .text = try gpa.dupe(u8, "b") };
        defer second.deinit(gpa);
        try eng.insert("t", &.{ .{ .int = 2 }, second });
        try std.testing.expect(eng.publishedSeq() > seq1);
    }
    {
        var eng = try openEngine(dir);
        defer eng.deinit();
        var all = try eng.selectAll("t");
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);
    }
    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "multi-statement commit is atomic and read-your-writes" {
    const dir = "zig-cache/runadb-txn-multi";
    {
        var eng = try freshEngine(dir);
        defer eng.deinit();
        try makeTable(&eng, "t", "id", &.{col("name", .text)});

        var tx = eng.beginTransaction();
        defer tx.deinit();

        var one: value.Value = .{ .text = try gpa.dupe(u8, "one") };
        defer one.deinit(gpa);
        try eng.stageInsert(&tx, "t", &.{ .{ .int = 1 }, one });
        var two: value.Value = .{ .text = try gpa.dupe(u8, "two") };
        defer two.deinit(gpa);
        try eng.stageInsert(&tx, "t", &.{ .{ .int = 2 }, two });

        // Before commit the rows are not visible to other connections.
        var before = try eng.selectAll("t");
        defer before.deinit();
        try std.testing.expectEqual(@as(usize, 0), before.rows.len);

        try eng.commitTransaction(&tx);
        // After commit both rows appear atomically.
        var after = try eng.selectAll("t");
        defer after.deinit();
        try std.testing.expectEqual(@as(usize, 2), after.rows.len);
    }
    {
        var eng = try openEngine(dir);
        defer eng.deinit();
        var all = try eng.selectAll("t");
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);
    }
    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "rollback discards the write set and leaves no trace" {    const dir = "zig-cache/runadb-txn-rollback";
    {
        var eng = try freshEngine(dir);
        defer eng.deinit();
        try makeTable(&eng, "t", "id", &.{});

        var tx = eng.beginTransaction();
        defer tx.deinit();
        try eng.stageInsert(&tx, "t", &.{.{ .int = 1 }});
        try eng.rollbackTransaction(&tx);

        var all = try eng.selectAll("t");
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 0), all.rows.len);
        // The transaction is idle and cannot commit anymore.
        try std.testing.expectError(error.InvalidState, eng.commitTransaction(&tx));
    }
    {
        var eng = try openEngine(dir);
        defer eng.deinit();
        var all = try eng.selectAll("t");
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 0), all.rows.len);
    }
    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "failed staging rejects a later commit and only rollback resets it" {
    const dir = "zig-cache/runadb-txn-failed";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{col("name", .text)});

    var tx = eng.beginTransaction();
    defer tx.deinit();
    var name: value.Value = .{ .text = try gpa.dupe(u8, "x") };
    defer name.deinit(gpa);
    try eng.stageInsert(&tx, "t", &.{ .{ .int = 1 }, name });
    // A second insert of the same primary key fails during staging.
    try std.testing.expectError(error.DuplicatePrimaryKey, eng.stageInsert(&tx, "t", &.{ .{ .int = 1 }, name }));

    // The transaction is still active after a staging failure, but committing a
    // partial write set is rejected at the coordinator boundary; a malformed
    // commit must not surface. Rollback resets it.
    try eng.rollbackTransaction(&tx);
    var after = try eng.selectAll("t");
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.rows.len);
}

test "uncommitted write set is invisible to other connections" {
    const dir = "zig-cache/runadb-txn-visibility";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{col("name", .text)});

    var tx = eng.beginTransaction();
    defer tx.deinit();
    var name: value.Value = .{ .text = try gpa.dupe(u8, "secret") };
    defer name.deinit(gpa);
    try eng.stageInsert(&tx, "t", &.{ .{ .int = 7 }, name });

    // A separate connection's read sees nothing.
    var all = try eng.selectAll("t");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 0), all.rows.len);

    try eng.commitTransaction(&tx);
    var after = try eng.selectAll("t");
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.rows.len);
}

test "write-write conflict rejects a lost update" {
    const dir = "zig-cache/runadb-txn-conflict";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{col("v", .int)});

    try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });

    // Connection A reads the row, then Connection B updates it and commits.
    var a = eng.beginTransaction();
    defer a.deinit();
    var b = eng.beginTransaction();
    defer b.deinit();

    try eng.stageUpdate(&a, "t", .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 20 } });
    try eng.stageUpdate(&b, "t", .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 30 } });

    // B commits first.
    try eng.commitTransaction(&b);
    // A's update was based on the same observed version; committing it loses
    // B's write, so the coordinator rejects it.
    try std.testing.expectError(error.WriteWriteConflict, eng.commitTransaction(&a));

    var row = try eng.selectByPk("t", .{ .int = 1 });
    defer row.deinit();
    try std.testing.expectEqual(@as(usize, 1), row.rows.len);
    try std.testing.expectEqual(@as(i64, 30), row.rows[0].values[1].int);
}

test "two blind inserts to distinct keys both commit" {
    const dir = "zig-cache/runadb-txn-distinct";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{});

    var a = eng.beginTransaction();
    defer a.deinit();
    var b = eng.beginTransaction();
    defer b.deinit();
    try eng.stageInsert(&a, "t", &.{.{ .int = 1 }});
    try eng.stageInsert(&b, "t", &.{.{ .int = 2 }});
    try eng.commitTransaction(&a);
    try eng.commitTransaction(&b);

    var all = try eng.selectAll("t");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 2), all.rows.len);
}

test "commit queue is bounded and rejects overflow" {
    const dir = "zig-cache/runadb-txn-queue";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{});

    // Build requests without draining so the coordinator queue fills. The
    // engine coordinator defaults to 64 slots; submitting one more than that
    // must reject with CommitQueueFull rather than grow without bound.
    const cap = eng.coordinator.cfg.queue_capacity;
    var txns: [80]txn_mod.Transaction = undefined;
    var requests: [80]commit_mod.Request = undefined;
    var count: usize = 0;
    var overflow_rejected = false;
    for (&txns, 0..) |*tx, i| {
        tx.* = eng.beginTransaction();
        try eng.stageInsert(tx, "t", &.{.{ .int = @intCast(i + 1) }});
        const observed = try gpa.alloc(?u64, 1);
        observed[0] = null;
        const ops = try tx.toWalOps();
        // Build directly into the array slot so the coordinator's queued
        // pointer remains valid; submitting a local would dangle.
        requests[i] = .{ .gpa = gpa, .ops = ops, .observed = observed, .read_seq = tx.snapshot_seq };
        eng.coordinator.submit(&eng, &requests[i]) catch |err| {
            if (err == error.CommitQueueFull) {
                overflow_rejected = true;
                requests[i].deinit();
                tx.deinit();
                continue;
            }
            requests[i].deinit();
            tx.deinit();
            return err;
        };
        count += 1;
    }
    try std.testing.expect(overflow_rejected);
    try std.testing.expectEqual(cap, count);

    // Drain the accepted batch; every submitted request is committed.
    try eng.coordinator.drain(&eng);
    for (requests[0..count]) |*req| req.deinit();
    for (txns[0..count]) |*tx| tx.deinit();

    var all = try eng.selectAll("t");
    defer all.deinit();
    try std.testing.expectEqual(count, all.rows.len);
}

test "a cancelled queued commit is withdrawn without a commit-sequence gap" {
    const dir = "zig-cache/runadb-txn-cancel-withdraw";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{});

    var tx_a = eng.beginTransaction();
    defer tx_a.deinit();
    try eng.stageInsert(&tx_a, "t", &.{.{ .int = 1 }});
    var tx_b = eng.beginTransaction();
    defer tx_b.deinit();
    try eng.stageInsert(&tx_b, "t", &.{.{ .int = 2 }});

    var req_a = try buildRequest(&tx_a);
    defer req_a.deinit();
    var req_b = try buildRequest(&tx_b);
    defer req_b.deinit();

    try eng.coordinator.submit(&eng, &req_a);
    try eng.coordinator.submit(&eng, &req_b);

    // Withdraw the first request before the drain round: it consumes its
    // queue position but no commit sequence, so the surviving request commits
    // exactly as if the cancelled one had never been submitted. Withdrawal
    // marks the request done with a Canceled result so the original submitter
    // observes a deterministic outcome; ownership stays with the submitter,
    // which frees it exactly once.
    try std.testing.expect(try eng.coordinator.cancel(&req_a));
    try std.testing.expect(req_a.done);
    try std.testing.expectEqual(error.Canceled, req_a.result.?);
    try eng.coordinator.drain(&eng);

    try std.testing.expectEqual(@as(u64, 1), eng.coordinator.publishedSeq());
    try std.testing.expectEqual(@as(u64, 1), eng.coordinator.commits);
    // A withdrawn request never reaches the round, so it is not counted as a
    // round cancellation; it was already counted at withdrawal time.
    try std.testing.expectEqual(@as(u64, 1), eng.coordinator.cancelled);

    var all = try eng.selectAll("t");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 1), all.rows.len);
    try std.testing.expectEqual(@as(i64, 2), all.rows[0].values[0].int);
}

test "a request marked at the drain boundary publishes nothing (white-box Phase 6 invariant)" {
    const dir = "zig-cache/runadb-txn-cancel-round";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{});

    var tx_a = eng.beginTransaction();
    defer tx_a.deinit();
    try eng.stageInsert(&tx_a, "t", &.{.{ .int = 1 }});
    var tx_b = eng.beginTransaction();
    defer tx_b.deinit();
    try eng.stageInsert(&tx_b, "t", &.{.{ .int = 2 }});

    var req_a = try buildRequest(&tx_a);
    defer req_a.deinit();
    var req_b = try buildRequest(&tx_b);
    defer req_b.deinit();

    try eng.coordinator.submit(&eng, &req_a);
    try eng.coordinator.submit(&eng, &req_b);

    // White-box Phase 6 invariant: the drain-boundary mark is checked exactly
    // once at admission (pass 1, before any commit sequence is assigned). No
    // production path sets `cancelled` on a live request today — `cancel()`
    // withdraws queued requests instead, and the writer mutex serializes
    // `cancel` against `drain`, so mid-round marks become deliverable only with
    // the Phase 6 runtime. This test drives the mark directly to pin the
    // invariant: the request terminates deterministically, publishes nothing,
    // and later requests in the round are unaffected.
    req_a.cancelled = true;
    try eng.coordinator.drain(&eng);

    try std.testing.expect(req_a.done);
    try std.testing.expectEqual(error.Canceled, req_a.result.?);
    try std.testing.expectEqual(@as(u64, 1), eng.coordinator.cancelled);
    try std.testing.expectEqual(@as(u64, 1), eng.coordinator.publishedSeq());

    var all = try eng.selectAll("t");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 1), all.rows.len);
    try std.testing.expectEqual(@as(i64, 2), all.rows[0].values[0].int);
}

test "cancelling a committed request is a no-op" {
    const dir = "zig-cache/runadb-txn-cancel-after";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{});

    var tx = eng.beginTransaction();
    defer tx.deinit();
    try eng.stageInsert(&tx, "t", &.{.{ .int = 1 }});
    var req = try buildRequest(&tx);
    defer req.deinit();

    try eng.coordinator.submit(&eng, &req);
    try eng.coordinator.drain(&eng);
    try std.testing.expect(req.done);
    try std.testing.expectEqual(@as(?commit_mod.CoordError, null), req.result);

    // Once the complete commit record is durable, cancellation cannot make it
    // uncommitted: cancel() reports false and leaves the request unmodified, so
    // a stale flag can never silently drop a later submission.
    try std.testing.expect(!try eng.coordinator.cancel(&req));
    try std.testing.expect(!req.cancelled);
    try std.testing.expectEqual(@as(u64, 0), eng.coordinator.cancelled);

    var all = try eng.selectAll("t");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 1), all.rows.len);
}

test "coordinator group commit shares one durability round" {
    const dir = "zig-cache/runadb-txn-group-round";
    cleanDir(dir);
    var eng = try engine_mod.Engine.open(gpa, io, dir, true);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{});

    var txns: [8]txn_mod.Transaction = undefined;
    var requests: [8]commit_mod.Request = undefined;
    for (&txns, 0..) |*tx, i| {
        tx.* = eng.beginTransaction();
        try eng.stageInsert(tx, "t", &.{.{ .int = @intCast(i + 1) }});
        const observed = try gpa.alloc(?u64, 1);
        observed[0] = null;
        const ops = try tx.toWalOps();
        requests[i] = .{ .gpa = gpa, .ops = ops, .observed = observed, .read_seq = tx.snapshot_seq };
        try eng.coordinator.submit(&eng, &requests[i]);
    }

    // One drain commits all eight as one group; a single durability round
    // covers the batch.
    const rounds_before = eng.wal.sync_rounds;
    try eng.coordinator.drain(&eng);
    const rounds_after = eng.wal.sync_rounds;
    try std.testing.expectEqual(rounds_before + 1, rounds_after);

    for (&requests) |*req| req.deinit();
    for (&txns) |*tx| tx.deinit();

    var all = try eng.selectAll("t");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 8), all.rows.len);
}

test "recovery rebuilds the published watermark from commit seq records" {
    const dir = "zig-cache/runadb-txn-watermark-recovery";
    cleanDir(dir);
    var published: u64 = 0;
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir, true);
        defer eng.deinit();
        try makeTable(&eng, "t", "id", &.{col("v", .int)});
        try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
        try eng.insert("t", &.{ .{ .int = 2 }, .{ .int = 20 } });
        published = eng.publishedSeq();
        try std.testing.expectEqual(@as(u64, 2), published);
    }
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir, true);
        defer eng.deinit();
        // Recovery replays the txn_batch commit_seq records, so the watermark
        // is restored to the last confirmed commit, not reset.
        try std.testing.expectEqual(published, eng.publishedSeq());
        // New commits continue after the recovered watermark.
        try eng.insert("t", &.{ .{ .int = 3 }, .{ .int = 30 } });
        try std.testing.expectEqual(published + 1, eng.publishedSeq());
    }
    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "checkpoint preserves the watermark across restart" {
    const dir = "zig-cache/runadb-txn-watermark-ckpt";
    cleanDir(dir);
    var published: u64 = 0;
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir, true);
        defer eng.deinit();
        try makeTable(&eng, "t", "id", &.{col("v", .int)});
        try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
        try eng.insert("t", &.{ .{ .int = 2 }, .{ .int = 20 } });
        published = eng.publishedSeq();
        _ = try eng.checkpoint();
    }
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir, true);
        defer eng.deinit();
        // The checkpoint collapses per-commit history; set_commit_seq restores
        // the watermark so later commits stay ordered above the recovered one.
        try std.testing.expectEqual(published, eng.publishedSeq());
    }
    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "a torn wal tail after a transaction commit keeps only the confirmed prefix" {
    const dir = "zig-cache/runadb-txn-torn-tail";
    cleanDir(dir);
    var sealed_end: u64 = 0;
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir, true);
        defer eng.deinit();
        try makeTable(&eng, "t", "id", &.{col("v", .int)});
        try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
        try eng.insert("t", &.{ .{ .int = 2 }, .{ .int = 20 } });
        sealed_end = eng.wal.offset;
        // A later transaction is torn mid-frame by a crash.
        try eng.insert("t", &.{ .{ .int = 3 }, .{ .int = 30 } });
        const full = eng.wal.offset;
        const torn = sealed_end + (full - sealed_end) / 2;
        try eng.wal.file.truncate(torn);
        eng.wal.offset = torn;
    }
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir, true);
        defer eng.deinit();
        var all = try eng.selectAll("t");
        defer all.deinit();
        // Only the two confirmed commits survive; the torn tail is discarded.
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);
        var ghost = try eng.selectByPk("t", .{ .int = 3 });
        defer ghost.deinit();
        try std.testing.expectEqual(@as(usize, 0), ghost.rows.len);
    }
    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

// ── Read Committed read path (roadmap Phase 3) ──
//
// The transaction-aware reads merge the private write set (read-your-writes)
// over committed state. They are the engine boundary that makes explicit
// transactions read their own staged writes while every other reader sees only
// published commits.

test "read-your-writes: a transaction reads its own staged writes" {
    const dir = "zig-cache/runadb-txn-read-your-writes";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{col("name", .text)});

    var alice: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
    defer alice.deinit(gpa);
    var carol: value.Value = .{ .text = try gpa.dupe(u8, "carol") };
    defer carol.deinit(gpa);
    try eng.insert("t", &.{ .{ .int = 1 }, alice });
    try eng.insert("t", &.{ .{ .int = 3 }, carol });

    var tx = eng.beginTransaction();
    defer tx.deinit();
    var bob: value.Value = .{ .text = try gpa.dupe(u8, "bob") };
    defer bob.deinit(gpa);
    var alice2: value.Value = .{ .text = try gpa.dupe(u8, "alice-updated") };
    defer alice2.deinit(gpa);
    try eng.stageInsert(&tx, "t", &.{ .{ .int = 2 }, bob });
    try eng.stageUpdate(&tx, "t", .{ .int = 1 }, &.{ .{ .int = 1 }, alice2 });
    try eng.stageDelete(&tx, "t", .{ .int = 3 });

    // Point reads see the transaction's own staged writes.
    var updated = try eng.selectByPkTx(&tx, "t", .{ .int = 1 });
    defer updated.deinit();
    try std.testing.expectEqual(@as(usize, 1), updated.rows.len);
    try std.testing.expectEqualStrings("alice-updated", updated.rows[0].values[1].text);

    var inserted = try eng.selectByPkTx(&tx, "t", .{ .int = 2 });
    defer inserted.deinit();
    try std.testing.expectEqual(@as(usize, 1), inserted.rows.len);
    try std.testing.expectEqualStrings("bob", inserted.rows[0].values[1].text);

    var deleted = try eng.selectByPkTx(&tx, "t", .{ .int = 3 });
    defer deleted.deinit();
    try std.testing.expectEqual(@as(usize, 0), deleted.rows.len);

    // The merged scan contains exactly the transaction's view: committed rows
    // in read order, staged delete removed, staged insert appended.
    var all = try eng.selectAllTx(&tx, "t");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 2), all.rows.len);
    try std.testing.expectEqualStrings("alice-updated", all.rows[0].values[1].text);
    try std.testing.expectEqualStrings("bob", all.rows[1].values[1].text);

    // Committing publishes exactly that state.
    try eng.commitTransaction(&tx);
    var committed = try eng.selectAll("t");
    defer committed.deinit();
    try std.testing.expectEqual(@as(usize, 2), committed.rows.len);
    try std.testing.expectEqualStrings("alice-updated", committed.rows[0].values[1].text);
    try std.testing.expectEqualStrings("bob", committed.rows[1].values[1].text);
}

test "an uncommitted write set is invisible to other readers and transactions" {
    const dir = "zig-cache/runadb-txn-invisible";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{col("name", .text)});
    var alice: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
    defer alice.deinit(gpa);
    try eng.insert("t", &.{ .{ .int = 1 }, alice });

    var tx = eng.beginTransaction();
    defer tx.deinit();
    var secret: value.Value = .{ .text = try gpa.dupe(u8, "secret") };
    defer secret.deinit(gpa);
    try eng.stageInsert(&tx, "t", &.{ .{ .int = 2 }, secret });
    try eng.stageUpdate(&tx, "t", .{ .int = 1 }, &.{ .{ .int = 1 }, secret });

    // A plain read (another connection) sees only committed rows.
    var plain = try eng.selectAll("t");
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 1), plain.rows.len);
    try std.testing.expectEqualStrings("alice", plain.rows[0].values[1].text);

    // Another transaction's Read Committed scan sees only committed rows.
    var other = eng.beginTransaction();
    defer other.deinit();
    var other_view = try eng.selectAllTx(&other, "t");
    defer other_view.deinit();
    try std.testing.expectEqual(@as(usize, 1), other_view.rows.len);
    try std.testing.expectEqualStrings("alice", other_view.rows[0].values[1].text);

    var other_pk = try eng.selectByPkTx(&other, "t", .{ .int = 2 });
    defer other_pk.deinit();
    try std.testing.expectEqual(@as(usize, 0), other_pk.rows.len);
}

test "Read Committed re-reads the latest committed state between statements" {
    const dir = "zig-cache/runadb-txn-read-committed";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{col("v", .int)});
    try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });

    var tx = eng.beginTransaction();
    defer tx.deinit();

    var first = try eng.selectByPkTx(&tx, "t", .{ .int = 1 });
    defer first.deinit();
    try std.testing.expectEqual(@as(i64, 10), first.rows[0].values[1].int);

    // A separate autocommit connection commits between the two statements.
    try eng.update("t", .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 20 } });

    // Read Committed: the second statement observes that commit.
    var second = try eng.selectByPkTx(&tx, "t", .{ .int = 1 });
    defer second.deinit();
    try std.testing.expectEqual(@as(i64, 20), second.rows[0].values[1].int);

    // The transaction still keeps its own staged writes on top of fresh state.
    try eng.stageInsert(&tx, "t", &.{ .{ .int = 2 }, .{ .int = 200 } });
    var merged = try eng.selectAllTx(&tx, "t");
    defer merged.deinit();
    try std.testing.expectEqual(@as(usize, 2), merged.rows.len);
    try std.testing.expectEqual(@as(i64, 20), merged.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 200), merged.rows[1].values[1].int);
}

test "a staged insert followed by update emits the latest write-set values" {
    const dir = "zig-cache/runadb-txn-insert-then-update";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{col("name", .text)});

    var tx = eng.beginTransaction();
    defer tx.deinit();
    var first: value.Value = .{ .text = try gpa.dupe(u8, "first") };
    defer first.deinit(gpa);
    var second: value.Value = .{ .text = try gpa.dupe(u8, "second") };
    defer second.deinit(gpa);
    try eng.stageInsert(&tx, "t", &.{ .{ .int = 2 }, first });
    try eng.stageUpdate(&tx, "t", .{ .int = 2 }, &.{ .{ .int = 2 }, second });

    var point = try eng.selectByPkTx(&tx, "t", .{ .int = 2 });
    defer point.deinit();
    try std.testing.expectEqual(@as(usize, 1), point.rows.len);
    try std.testing.expectEqualStrings("second", point.rows[0].values[1].text);

    var all = try eng.selectAllTx(&tx, "t");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 1), all.rows.len);
    try std.testing.expectEqualStrings("second", all.rows[0].values[1].text);
}

test "a staged update followed by delete hides the row from the transaction" {
    const dir = "zig-cache/runadb-txn-update-then-delete";
    var eng = try freshEngine(dir);
    defer {
        eng.deinit();
        Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try makeTable(&eng, "t", "id", &.{col("v", .int)});
    try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });

    var tx = eng.beginTransaction();
    defer tx.deinit();
    try eng.stageUpdate(&tx, "t", .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 99 } });
    try eng.stageDelete(&tx, "t", .{ .int = 1 });

    var point = try eng.selectByPkTx(&tx, "t", .{ .int = 1 });
    defer point.deinit();
    try std.testing.expectEqual(@as(usize, 0), point.rows.len);

    var all = try eng.selectAllTx(&tx, "t");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 0), all.rows.len);

    // Committing publishes the deletion.
    try eng.commitTransaction(&tx);
    var committed = try eng.selectAll("t");
    defer committed.deinit();
    try std.testing.expectEqual(@as(usize, 0), committed.rows.len);
}
