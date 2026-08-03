//! LSM benchmark baselines (roadmap Phase 5 exit criteria).
//!
//! Measures the durable LSM slice through the engine and storage entry points:
//! synchronized autocommit inserts with a per-batch flush, the L0+L1
//! compaction, on-disk point lookups after compaction (present keys probe the
//! L1 file; absent keys are rejected by the full-key Bloom filter before any
//! index read), and restart recovery over the same data directory. Every
//! number is a single-run observation on the current host; record workload,
//! optimization level, machine context, and durability level with any
//! comparison (see docs/benchmarks/).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const runadb = @import("runadb");

const n_per_flush: usize = 10_000;
const flush_count: usize = 4;
const point_probes: usize = 200_000;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const dir = "zig-cache/runadb-lsm-bench";

    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    std.debug.print("RunaDB LSM baseline — optimize {s}, durability WAL sync on, single run\n", .{@tagName(builtin.mode)});

    // 1. Write path: synchronized autocommit inserts, flushed per batch.
    {
        var eng = try runadb.engine.Engine.open(gpa, io, dir, true);
        defer eng.deinit();
        const id_name = try gpa.dupe(u8, "id");
        defer gpa.free(id_name);
        const val_name = try gpa.dupe(u8, "v");
        defer gpa.free(val_name);
        try eng.createTable("t", &.{
            .{ .name = id_name, .type_tag = .int, .primary_key = true },
            .{ .name = val_name, .type_tag = .int },
        });

        var seq: i64 = 0;
        const t0 = Io.Clock.Timestamp.now(io, .awake);
        var flush_ns_total: u64 = 0;
        var f: usize = 0;
        while (f < flush_count) : (f += 1) {
            var i: usize = 0;
            while (i < n_per_flush) : (i += 1) {
                try eng.insert("t", &.{ .{ .int = seq }, .{ .int = seq * 2 } });
                seq += 1;
            }
            const tf = Io.Clock.Timestamp.now(io, .awake);
            try eng.flush("t");
            flush_ns_total += elapsed(tf, io);
        }
        const write_ns = elapsed(t0, io);
        const total_rows: usize = flush_count * n_per_flush;
        std.debug.print("write+flush: {d:.0} inserts/s ({d} ns/insert), flush avg {d} ms per {d} rows\n", .{
            @as(f64, @floatFromInt(total_rows)) * 1e9 / @as(f64, @floatFromInt(write_ns)),
            write_ns / total_rows,
            flush_ns_total / flush_count / 1_000_000,
            n_per_flush,
        });
    }

    // 2. On-disk point lookups across the four L0 files: present keys hit the
    // newest file (every materialized key lives there as a put or tombstone);
    // absent keys are rejected by each file's full-key Bloom filter before any
    // index read, so each absent probe skips all four files.
    {
        var eng = try runadb.engine.Engine.open(gpa, io, dir, true);
        defer eng.deinit();
        const total_rows: usize = flush_count * n_per_flush;
        const codec = runadb.lsm.codec;

        var t = Io.Clock.Timestamp.now(io, .awake);
        var probes: usize = 0;
        var hits: usize = 0;
        while (probes < point_probes) : (probes += 1) {
            const k = codec.encodeIntKey(@intCast(probes % total_rows));
            var entry = (try eng.lsm.pointLookup(gpa, "t", &k)).?;
            entry.deinit(gpa);
            hits += 1;
        }
        var ns = elapsed(t, io);
        std.debug.print("point lookup L0 present: {d:.0} lookups/s ({d} ns/lookup), {d} hits\n", .{
            @as(f64, @floatFromInt(point_probes)) * 1e9 / @as(f64, @floatFromInt(ns)),
            ns / point_probes,
            hits,
        });

        t = Io.Clock.Timestamp.now(io, .awake);
        probes = 0;
        var misses: usize = 0;
        while (probes < point_probes) : (probes += 1) {
            const k = codec.encodeIntKey(@intCast(total_rows + probes));
            if (try eng.lsm.pointLookup(gpa, "t", &k)) |entry| {
                var owned = entry;
                owned.deinit(gpa);
            } else {
                misses += 1;
            }
        }
        ns = elapsed(t, io);
        std.debug.print("point lookup L0 absent:  {d:.0} lookups/s ({d} ns/lookup), {d} misses (filter rejects before any data-block read)\n", .{
            @as(f64, @floatFromInt(point_probes)) * 1e9 / @as(f64, @floatFromInt(ns)),
            ns / point_probes,
            misses,
        });
    }

    // 3. Compaction of the four L0 files into one non-overlapping L1 file.
    {
        var eng = try runadb.engine.Engine.open(gpa, io, dir, true);
        defer eng.deinit();

        const t1 = Io.Clock.Timestamp.now(io, .awake);
        try eng.compact("t");
        const compact_ns = elapsed(t1, io);
        const stats = eng.lsmStats();
        std.debug.print("compact: {d} input files ({d} entries, {d} B) -> {d} output files ({d} entries, {d} B), {d} dropped, {d} ms\n", .{
            stats.compaction_input_files, stats.compaction_entries_in, stats.compaction_input_bytes,
            stats.compaction_output_files, stats.compaction_entries_out, stats.compaction_output_bytes,
            stats.compaction_dropped_entries, compact_ns / 1_000_000,
        });
        std.debug.print("  compaction throughput: {d:.0} entries/s\n", .{
            @as(f64, @floatFromInt(stats.compaction_entries_in)) * 1e9 / @as(f64, @floatFromInt(compact_ns)),
        });

        // 4. Point lookups against the single L1 file: the canonical on-disk
        // OLTP read, exercising the filter-inside-find path for present keys.
        const total_rows: usize = flush_count * n_per_flush;
        const codec = runadb.lsm.codec;
        const tp = Io.Clock.Timestamp.now(io, .awake);
        var probes: usize = 0;
        var hits: usize = 0;
        while (probes < point_probes) : (probes += 1) {
            const k = codec.encodeIntKey(@intCast(probes % total_rows));
            var entry = (try eng.lsm.pointLookup(gpa, "t", &k)).?;
            entry.deinit(gpa);
            hits += 1;
        }
        const lookup_ns = elapsed(tp, io);
        std.debug.print("point lookup L1 present: {d:.0} lookups/s ({d} ns/lookup), {d} hits\n", .{
            @as(f64, @floatFromInt(point_probes)) * 1e9 / @as(f64, @floatFromInt(lookup_ns)),
            lookup_ns / point_probes,
            hits,
        });
    }

    // 5. Restart recovery: load manifest and SSTables, replay the (already
    // materialized) WAL tail, validate the checkpoint manifest.
    {
        const tr = Io.Clock.Timestamp.now(io, .awake);
        var eng2 = try runadb.engine.Engine.open(gpa, io, dir, true);
        defer eng2.deinit();
        const recover_ns = elapsed(tr, io);
        const tbl = eng2.getTable("t") orelse return error.TableMissing;
        std.debug.print("recovery: {d} ms, table rows {d}, sst files loaded {d}\n", .{
            recover_ns / 1_000_000,
            tbl.rows.items.len,
            eng2.lsmStats().recovery_files_loaded,
        });
    }
}

fn elapsed(start: Io.Clock.Timestamp, io: Io) u64 {
    return @intCast(@max(@as(i96, 1), start.untilNow(io).raw.nanoseconds));
}
