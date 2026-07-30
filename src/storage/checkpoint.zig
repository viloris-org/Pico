//! Checkpoint: bound WAL size and recovery time.
//!
//! A checkpoint rewrites the WAL into the shortest record sequence that
//! reconstructs current committed state, then publishes it atomically over the
//! live WAL. Recovery cost becomes proportional to live data rather than to
//! total write history, and the WAL stops growing without bound.
//!
//! In the current memtable + WAL phase there are no SSTables to materialize
//! into, so advancing persistent progress *is* the WAL rewrite. When LSM
//! storage lands, this module becomes flush + manifest publication + WAL
//! truncation; the externally visible contract (bounded WAL, bounded recovery)
//! does not change.
//!
//! A checkpoint is an internal mechanism for reclaiming WAL space. It is not a
//! user backup and not a point-in-time recovery interface.
const std = @import("std");
const Allocator = std.mem.Allocator;
const wal_mod = @import("wal.zig");
const table_mod = @import("table.zig");
const value_mod = @import("value.zig");

pub const Stats = struct {
    tables: usize,
    rows: usize,
    /// Live WAL size replaced by this checkpoint, sampled under the WAL append
    /// lock when the rewrite began.
    wal_bytes_before: u64,
    wal_bytes_after: u64,
};

/// Rewrite `wal` so it describes exactly `tables` and nothing else.
///
/// The caller must guarantee that no other writer can mutate `tables` for the
/// duration of this call. The rewritten WAL becomes the only record of
/// committed state, so a torn read of a table here would durably lose a commit
/// rather than merely return a bad row.
pub fn run(wal: *wal_mod.Wal, tables: []const *const table_mod.Table) !Stats {
    var rewrite = try wal.beginRewrite();

    var rows: usize = 0;
    {
        // `commit` is self-cleaning, so this errdefer must not cover it.
        errdefer rewrite.abort();

        for (tables) |table| {
            // One create_table carrying the *current* column set. This is what
            // collapses ALTER TABLE history: the replayed schema is the final
            // one, so no add_column/drop_column/set_default records survive.
            try rewrite.emitCreateTable(.{ .name = table.name, .columns = table.columns });

            for (table.rows.items) |row| {
                try rewrite.emitInsert(.{ .table = table.name, .values = row.values });
            }
            rows += table.rows.items.len;

            // Must follow the inserts: replaying them raises the counter to
            // max(pk)+1, which is behind the live counter whenever a row has
            // been deleted. Emitting the live value last prevents a later
            // INSERT from reusing a retired identifier.
            try rewrite.emitSetSerial(.{ .table = table.name, .next_serial = table.next_serial });
        }
    }

    const before = rewrite.replaced_bytes;
    const after = rewrite.offset;
    try rewrite.commit();

    return .{
        .tables = tables.len,
        .rows = rows,
        .wal_bytes_before = before,
        .wal_bytes_after = after,
    };
}

const Io = std.Io;

/// Replay sink that records the record sequence a checkpoint emitted, so tests
/// can assert the emitted order rather than only the recovered end state.
const RecordLog = struct {
    gpa: Allocator,
    entries: std.ArrayList([]u8) = .empty,

    fn deinit(self: *RecordLog) void {
        for (self.entries.items) |e| self.gpa.free(e);
        self.entries.deinit(self.gpa);
    }

    fn apply(self: *RecordLog, view: wal_mod.RecordView) !void {
        const text = switch (view) {
            .create_table => |ct| try std.fmt.allocPrint(self.gpa, "create_table {s}/{d}", .{ ct.name, ct.columns.len }),
            .insert => |ins| try std.fmt.allocPrint(self.gpa, "insert {s}", .{ins.table}),
            .set_serial => |ss| try std.fmt.allocPrint(self.gpa, "set_serial {s}={d}", .{ ss.table, ss.next_serial }),
            else => try std.fmt.allocPrint(self.gpa, "other", .{}),
        };
        errdefer self.gpa.free(text);
        try self.entries.append(self.gpa, text);
    }
};

fn makeTable(gpa: Allocator, name: []const u8) !table_mod.Table {
    return table_mod.Table.create(gpa, name, &.{
        .{ .name = "id", .type_tag = .int, .primary_key = true, .serial = true },
        .{ .name = "note", .type_tag = .text },
    });
}

test "checkpoint emits current schema and rows, with set_serial after the inserts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-ckpt-order";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var stats: Stats = undefined;
    {
        var wal = try wal_mod.Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();

        var table = try makeTable(gpa, "t");
        defer table.deinit(gpa);

        var note: value_mod.Value = .{ .text = try gpa.dupe(u8, "hello") };
        defer note.deinit(gpa);
        try table.insert(gpa, &.{ .{ .int = 1 }, note });
        try table.insert(gpa, &.{ .{ .int = 7 }, note });
        // Delete the high row so next_serial (8) outlives max(pk) (1).
        try table.delete(gpa, .{ .int = 7 });
        try std.testing.expectEqual(@as(i64, 8), table.next_serial);

        stats = try run(&wal, &.{&table});
    }

    try std.testing.expectEqual(@as(usize, 1), stats.tables);
    try std.testing.expectEqual(@as(usize, 1), stats.rows);

    {
        var wal = try wal_mod.Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var log: RecordLog = .{ .gpa = gpa };
        defer log.deinit();
        try wal_mod.replayWal(&wal, &log, RecordLog.apply);

        try std.testing.expectEqual(@as(usize, 3), log.entries.items.len);
        try std.testing.expectEqualStrings("create_table t/2", log.entries.items[0]);
        try std.testing.expectEqualStrings("insert t", log.entries.items[1]);
        // set_serial last, and carrying the live counter rather than max(pk)+1.
        try std.testing.expectEqualStrings("set_serial t=8", log.entries.items[2]);
    }
}

test "checkpoint of an empty instance still yields a replayable wal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-ckpt-empty";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var wal = try wal_mod.Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        const stats = try run(&wal, &.{});
        try std.testing.expectEqual(@as(usize, 0), stats.tables);
        try std.testing.expectEqual(@as(usize, 0), stats.rows);
    }

    {
        var wal = try wal_mod.Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var log: RecordLog = .{ .gpa = gpa };
        defer log.deinit();
        try wal_mod.replayWal(&wal, &log, RecordLog.apply);
        try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);
        // A fresh append onto the rewritten file must still land correctly.
        try wal.appendInsert(.{ .table = "t", .values = &.{.{ .int = 1 }} });
    }
}
