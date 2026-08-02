//! LSM store: version set, flush, compaction, and read paths.
//!
//! The store owns the on-disk half of the LSM (roadmap Phase 5): immutable
//! SSTables organized into levels, the version-set manifest that names them,
//! flush (memtable -> L0), compaction (L0 + overlapping L1 -> L1), point and
//! range read paths, and delayed file reclamation. The in-memory `Table` in
//! `table.zig` is the memtable half: the engine routes writes to it and the
//! store only ever materializes durable snapshots of it.
//!
//! ## Levels and invariants
//!
//! - L0 files are produced by flushes. Their key ranges may overlap; a newer
//!   L0 file is authoritative for any key it contains.
//! - L1 files are produced by compaction. Within L1, files are non-overlapping
//!   and sorted by first key; together a level's files cover the key space.
//! - A flush writes every live row plus a delete tombstone for every key that
//!   was live in an earlier SSTable but is no longer live, so deleted keys can
//!   never resurrect from old files.
//! - Compaction merges the table's L0 files with the overlapping L1 files and
//!   keeps, per user key, the entry with the highest sequence; a tombstone that
//!   is the newest entry for its key is dropped entirely (the key is gone).
//!
//! ## Durability and reclamation
//!
//! SSTables are written through the directory's atomic-file primitive and
//! synced before publication, so an interrupted flush never publishes a torn
//! file. The version-set manifest is rewritten atomically on every flush and
//! compaction. Input files of a compaction are deleted only after the new
//! manifest is durable; a crash in between leaves unreferenced files that
//! recovery reclaims as orphans.
//!
//! ## Ownership
//!
//! The store borrows no engine state: it owns its data-directory handle and
//! per-table metadata, and the engine passes rows in at flush time. Flush and
//! compaction are synchronous and must run under the engine's writer lock so
//! the materialized snapshot matches the WAL rewrite; background scheduling is
//! a later runtime slice (docs/architecture/io-scheduling.md).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const value = @import("../value.zig");
const table_mod = @import("../table.zig");
const codec = @import("codec.zig");
const sstable = @import("sstable.zig");
const lsm_manifest = @import("manifest.zig");

/// L0 (flush output, overlap allowed) and L1 (compacted, non-overlapping).
pub const max_levels = 2;
const level0: u8 = 0;
const level1: u8 = 1;
const file_prefix = "sst_";
const file_suffix = ".sst";

/// Instance-wide LSM observability (roadmap Phase 5 "Observability is a day-one
/// design constraint"). Counters never expose row contents.
pub const Stats = struct {
    // Flush
    flushed_files: u64 = 0,
    flushed_bytes: u64 = 0,
    flushed_entries: u64 = 0,
    tombstones_written: u64 = 0,
    // Compaction
    compaction_runs: u64 = 0,
    compaction_input_files: u64 = 0,
    compaction_input_bytes: u64 = 0,
    compaction_output_files: u64 = 0,
    compaction_output_bytes: u64 = 0,
    compaction_entries_in: u64 = 0,
    compaction_entries_out: u64 = 0,
    compaction_dropped_entries: u64 = 0,
    compaction_ns: u64 = 0,
    // Recovery
    recovery_files_loaded: u64 = 0,
    recovery_bytes_loaded: u64 = 0,
    recovery_orphan_files: u64 = 0,
    recovery_orphan_bytes: u64 = 0,
    // Reclamation
    files_reclaimed: u64 = 0,
};

pub const Error = error{
    TableNotFound,
    InvalidPrimaryKey,
    CorruptSst,
    CorruptLsmManifest,
} || Allocator.Error || Io.File.OpenError || Io.File.LengthError || Io.File.ReadError || Io.File.DeleteError;

/// One SSTable in a table's version set. Owns its internal-key range bytes.
pub const FileMeta = struct {
    number: u64,
    size: u64,
    first_key: []u8,
    last_key: []u8,

    fn clone(gpa: Allocator, source: FileMeta) Allocator.Error!FileMeta {
        return .{
            .number = source.number,
            .size = source.size,
            .first_key = try gpa.dupe(u8, source.first_key),
            .last_key = try gpa.dupe(u8, source.last_key),
        };
    }

    fn deinit(self: *FileMeta, gpa: Allocator) void {
        gpa.free(self.first_key);
        gpa.free(self.last_key);
        self.* = undefined;
    }
};

/// Per-table version-set metadata. Owns its name, columns, and file metadata.
pub const TableMeta = struct {
    name: []u8,
    next_serial: i64,
    columns: []value.Column,
    levels: [max_levels]std.ArrayList(FileMeta),

    fn clone(gpa: Allocator, source: *const TableMeta) Allocator.Error!TableMeta {
        var levels: [max_levels]std.ArrayList(FileMeta) = undefined;
        for (&levels, 0..) |*list, i| {
            list.* = .empty;
            errdefer {
                for (levels[0 .. i + 1]) |*seen| {
                    for (seen.items) |*f| f.deinit(gpa);
                    seen.deinit(gpa);
                }
            }
            try list.ensureTotalCapacity(gpa, source.levels[i].items.len);
            for (source.levels[i].items) |f| list.appendAssumeCapacity(try FileMeta.clone(gpa, f));
        }
        return .{
            .name = try gpa.dupe(u8, source.name),
            .next_serial = source.next_serial,
            .columns = try cloneColumns(gpa, source.columns),
            .levels = levels,
        };
    }

    fn deinit(self: *TableMeta, gpa: Allocator) void {
        gpa.free(self.name);
        for (self.columns) |*c| c.deinit(gpa);
        gpa.free(self.columns);
        for (&self.levels) |*list| {
            for (list.items) |*f| f.deinit(gpa);
            list.deinit(gpa);
        }
        self.* = undefined;
    }
};

fn cloneColumns(gpa: Allocator, columns: []const value.Column) Allocator.Error![]value.Column {
    const out = try gpa.alloc(value.Column, columns.len);
    errdefer gpa.free(out);
    var cloned: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < cloned) : (i += 1) out[i].deinit(gpa);
    }
    for (columns, 0..) |c, i| {
        out[i] = try c.clone(gpa);
        cloned = i + 1;
    }
    return out;
}

/// One merged entry across a table's files: an owned internal key and value,
/// with the sequence/type decoded so callers can filter tombstones.
pub const Entry = struct {
    key: []u8,
    value: []u8,
    seq: u64,
    is_delete: bool,

    pub fn deinit(self: *Entry, gpa: Allocator) void {
        gpa.free(self.key);
        gpa.free(self.value);
        self.* = undefined;
    }
};

pub const FlushStats = struct {
    files: u64 = 0,
    entries: u64 = 0,
    tombstones: u64 = 0,
    bytes: u64 = 0,
};

pub const CompactStats = struct {
    ran: bool = false,
    input_files: usize = 0,
    input_bytes: u64 = 0,
    output_files: usize = 0,
    output_bytes: u64 = 0,
    entries_in: u64 = 0,
    entries_out: u64 = 0,
    dropped_entries: u64 = 0,
    compaction_ns: u64 = 0,
};

pub const ReclaimStats = struct {
    count: u64 = 0,
    bytes: u64 = 0,
};

pub const Store = struct {
    gpa: Allocator,
    io: Io,
    /// Handle to the `lsm` subdirectory of the data directory; owns no other
    /// storage state. SSTables and the version manifest live here.
    dir: Io.Dir,
    /// Published watermark of the last flush. Recovery skips WAL records with
    /// `commit_seq <= watermark` because their state is already in SSTables.
    watermark: u64 = 0,
    next_file_number: u64 = 1,
    tables: std.StringHashMap(TableMeta),
    stats: Stats = .{},

    pub fn open(gpa: Allocator, io: Io, data_dir: []const u8) !Store {
        var root = try Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer root.close(io);
        const dir = try root.createDirPathOpen(io, "lsm", .{ .open_options = .{ .iterate = true } });
        return .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .tables = std.StringHashMap(TableMeta).init(gpa),
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.tables.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.gpa);
        self.tables.deinit();
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn hasTable(self: *const Store, name: []const u8) bool {
        return self.tables.contains(name);
    }

    pub fn tableCount(self: *const Store) usize {
        return self.tables.count();
    }

    // ── Version-set manifest ──

    /// Load the durable version set, or no-op when none exists yet. Validates
    /// the file layout and that every named SSTable exists; a missing or
    /// corrupt manifest fails recovery rather than being silently ignored.
    pub fn loadFromDisk(self: *Store, gpa: Allocator) !void {
        const exists = self.dir.access(self.io, "manifest", .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        _ = exists;
        var file = try self.dir.openFile(self.io, "manifest", .{ .mode = .read_only });
        defer file.close(self.io);
        const len = try file.length(self.io);
        if (len == 0 or len > 64 * 1024 * 1024) return error.CorruptLsmManifest;
        const bytes = try gpa.alloc(u8, @intCast(len));
        defer gpa.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.CorruptLsmManifest;

        var snap = try lsm_manifest.decode(gpa, bytes);
        defer lsm_manifest.deinitSnapshot(gpa, &snap);

        self.watermark = snap.watermark;
        self.next_file_number = @max(self.next_file_number, snap.next_file_number);
        for (snap.tables) |st| {
            if (self.tables.contains(st.name)) return error.CorruptLsmManifest;
            var meta = try tableMetaFromSnapshot(gpa, &st);
            errdefer meta.deinit(gpa);
            // Every named SSTable must exist on disk; a manifest pointing at a
            // missing file is an inconsistent data directory.
            for (&meta.levels) |*list| {
                for (list.items) |f| {
                    if (!try fileExists(self.dir, self.io, &fileName(f.number))) return error.CorruptLsmManifest;
                }
            }
            try self.tables.put(meta.name, meta);
            for (&meta.levels) |*list| {
                for (list.items) |f| {
                    self.stats.recovery_files_loaded += 1;
                    self.stats.recovery_bytes_loaded += f.size;
                }
            }
        }
    }

    /// Atomically publish the current version set. The caller holds the
    /// engine's writer lock so no flush or compaction races the rewrite.
    pub fn publishManifest(self: *Store, gpa: Allocator) !void {
        const snap = try self.snapshot(gpa);
        defer snap.deinit(gpa);
        const bytes = try lsm_manifest.encode(gpa, &snap.value);
        defer gpa.free(bytes);
        var atomic = try self.dir.createFileAtomic(self.io, "manifest", .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writePositionalAll(self.io, bytes, 0);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        try syncDir(self.dir, self.io);
    }

    /// Build a borrowed snapshot of the current version set.
    fn snapshot(self: *Store, gpa: Allocator) !struct {
        value: lsm_manifest.Snapshot,
        tables: []lsm_manifest.TableMeta,
        files: [][]lsm_manifest.FileMeta,

        fn deinit(s: @This(), alloc: Allocator) void {
            for (s.files) |files| alloc.free(files);
            alloc.free(s.files);
            alloc.free(s.tables);
        }
    } {
        const names = try self.sortedTableNames(gpa);
        defer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }
        const tables = try gpa.alloc(lsm_manifest.TableMeta, names.len);
        errdefer gpa.free(tables);
        const files = try gpa.alloc([]lsm_manifest.FileMeta, names.len);
        errdefer gpa.free(files);
        for (names, 0..) |name, i| {
            const meta = self.tables.getPtr(name).?;
            var flat: std.ArrayList(lsm_manifest.FileMeta) = .empty;
            defer flat.deinit(gpa);
            try flat.ensureTotalCapacity(gpa, meta.levels[0].items.len + meta.levels[1].items.len);
            for (&meta.levels) |*list| {
                for (list.items) |f| {
                    flat.appendAssumeCapacity(.{
                        .number = f.number,
                        .level = if (&list.* == &meta.levels[0]) level0 else level1,
                        .size = f.size,
                        .first_key = f.first_key,
                        .last_key = f.last_key,
                    });
                }
            }
            const owned_files = try gpa.dupe(lsm_manifest.FileMeta, flat.items);
            files[i] = owned_files;
            tables[i] = .{
                .name = meta.name,
                .next_serial = meta.next_serial,
                .columns = meta.columns,
                .files = owned_files,
            };
        }
        return .{
            .value = .{ .watermark = self.watermark, .next_file_number = self.next_file_number, .tables = tables },
            .tables = tables,
            .files = files,
        };
    }

    /// Deterministic table names for manifest encoding.
    fn sortedTableNames(self: *const Store, gpa: Allocator) Allocator.Error![][]u8 {
        const names = try gpa.alloc([]u8, self.tables.count());
        errdefer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }
        var it = self.tables.keyIterator();
        var i: usize = 0;
        while (it.next()) |key| {
            names[i] = try gpa.dupe(u8, key.*);
            i += 1;
        }
        std.mem.sort([]u8, names, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        return names;
    }

    // ── Flush: memtable -> L0 ──

    /// Materialize the live rows of one table into a new L0 SSTable, writing a
    /// delete tombstone for every key that was live in an earlier SSTable but
    /// is no longer live. Updates the in-memory version set; the caller
    /// publishes the manifest once all tables are flushed. Rows must be
    /// pre-sorted deterministically by primary key (they are: rows iterate in
    /// insertion order, so this routine sorts).
    pub fn flushTable(
        self: *Store,
        gpa: Allocator,
        table_name: []const u8,
        columns: []const value.Column,
        pk_index: usize,
        next_serial: i64,
        rows: []const table_mod.Row,
        watermark: u64,
    ) !FlushStats {
        self.watermark = @max(self.watermark, watermark);
        // This flush's file number doubles as the internal sequence for every
        // entry it writes: it is strictly larger than any earlier flush's
        // number, so a flush always supersedes older files for the same key.
        const flush_number = self.next_file_number;
        self.next_file_number += 1;
        var stats: FlushStats = .{};

        // Live entries: one put per row, keyed by the primary key and the
        // version's creation sequence.
        var entries: std.ArrayList(Entry) = .empty;
        defer {
            for (entries.items) |*e| e.deinit(gpa);
            entries.deinit(gpa);
        }
        try entries.ensureTotalCapacity(gpa, rows.len);
        var live_keys = std.StringHashMap(void).init(gpa);
        defer {
            var it = live_keys.keyIterator();
            while (it.next()) |k| gpa.free(k.*);
            live_keys.deinit();
        }
        for (rows) |row| {
            const pk = row.values[pk_index];
            const user_key = try userKeyOfPk(gpa, pk);
            defer gpa.free(user_key);
            // Every put of one flush shares `flush_number` as its internal
            // sequence: the sequence only orders flushes against each other,
            // and a flush must supersede older files for the same key even
            // when in-place ALTER rewrote the row without creating a version.
            const internal = try codec.internalKey(gpa, user_key, flush_number, .put);
            errdefer gpa.free(internal);
            const encoded = try codec.encodeRow(gpa, row.values);
            errdefer gpa.free(encoded);
            entries.appendAssumeCapacity(.{ .key = internal, .value = encoded, .seq = flush_number, .is_delete = false });
            try live_keys.put(try gpa.dupe(u8, user_key), {});
        }

        // Keys present in earlier SSTables but absent from the live set are
        // deleted: write a tombstone so they cannot resurrect from old files.
        var old_keys = std.StringHashMap(void).init(gpa);
        defer {
            var it = old_keys.keyIterator();
            while (it.next()) |k| gpa.free(k.*);
            old_keys.deinit();
        }
        try self.collectTableKeys(gpa, table_name, &old_keys);
        if (old_keys.count() != 0) {
            var tombstone_keys: std.ArrayList([]u8) = .empty;
            defer {
                for (tombstone_keys.items) |k| gpa.free(k);
                tombstone_keys.deinit(gpa);
            }
            var it = old_keys.keyIterator();
            while (it.next()) |k| {
                if (!live_keys.contains(k.*)) try tombstone_keys.append(gpa, try gpa.dupe(u8, k.*));
            }
            try entries.ensureUnusedCapacity(gpa, tombstone_keys.items.len);
            for (tombstone_keys.items) |user_key| {
                const internal = try codec.internalKey(gpa, user_key, flush_number, .delete);
                errdefer gpa.free(internal);
                entries.appendAssumeCapacity(.{ .key = internal, .value = try gpa.alloc(u8, 0), .seq = flush_number, .is_delete = true });
                stats.tombstones += 1;
            }
        }

        // Upsert table metadata (schema + serial) even for empty tables so the
        // manifest is the single durable home of a PK table's catalog state.
        // This runs before `addFile` so a first flush has a target level list.
        if (self.tables.getPtr(table_name)) |existing| {
            existing.next_serial = next_serial;
            const new_columns = try cloneColumns(gpa, columns);
            for (existing.columns) |*c| c.deinit(gpa);
            gpa.free(existing.columns);
            existing.columns = new_columns;
        } else {
            var meta = try emptyTableMeta(gpa, table_name, columns, next_serial);
            errdefer meta.deinit(gpa);
            try self.tables.put(meta.name, meta);
        }

        if (entries.items.len != 0) {
            std.mem.sort(Entry, entries.items, {}, struct {
                fn lessThan(_: void, a: Entry, b: Entry) bool {
                    return codec.internalLessThan(a.key, b.key);
                }
            }.lessThan);
            const meta = try self.writeSst(gpa, flush_number, entries.items);
            errdefer {
                gpa.free(meta.first_key);
                gpa.free(meta.last_key);
            }
            try self.addFile(table_name, level0, meta);
            stats.files = 1;
            stats.bytes = meta.size;
            stats.entries = entries.items.len;
            self.stats.flushed_files += 1;
            self.stats.flushed_bytes += meta.size;
            self.stats.flushed_entries += entries.items.len;
            self.stats.tombstones_written += stats.tombstones;
        }
        return stats;
    }

    fn writeSst(self: *Store, gpa: Allocator, number: u64, entries: []const Entry) !FileMeta {
        const name = fileName(number);
        var builder = try sstable.Builder.create(gpa, self.io, self.dir, &name);
        errdefer builder.deinit();
        for (entries) |e| try builder.add(e.key, e.value);
        const size = try builder.finish();
        // `finish` publishes the file; release the builder's owned buffers.
        builder.deinit();
        return .{
            .number = number,
            .size = size,
            .first_key = try gpa.dupe(u8, entries[0].key),
            .last_key = try gpa.dupe(u8, entries[entries.len - 1].key),
        };
    }

    /// Collect the union of user keys across a table's existing files.
    fn collectTableKeys(self: *Store, gpa: Allocator, table_name: []const u8, out: *std.StringHashMap(void)) !void {
        const meta = self.tables.get(table_name) orelse return;
        var reader_buf: std.ArrayList(sstable.Reader) = .empty;
        defer {
            for (reader_buf.items) |*r| r.deinit();
            reader_buf.deinit(gpa);
        }
        for (&meta.levels) |*list| {
            for (list.items) |f| {
                const reader = try sstable.Reader.open(gpa, self.io, self.dir, &fileName(f.number));
                try reader_buf.append(gpa, reader);
            }
        }
        for (reader_buf.items) |*reader| {
            const all = try reader.iterate(gpa, self.io);
            defer {
                for (all) |e| {
                    gpa.free(@constCast(e.key));
                    gpa.free(@constCast(e.value));
                }
                gpa.free(all);
            }
            for (all) |e| {
                const user_key = codec.userKeyOf(e.key);
                if (!out.contains(user_key)) {
                    const owned = try gpa.dupe(u8, user_key);
                    try out.put(owned, {});
                }
            }
        }
    }

    fn addFile(self: *Store, table_name: []const u8, level: u8, meta: FileMeta) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const list = &table.levels[level];
        try list.append(self.gpa, meta);
        if (level == level1) {
            std.mem.sort(FileMeta, list.items, {}, struct {
                fn lessThan(_: void, a: FileMeta, b: FileMeta) bool {
                    return codec.internalLessThan(a.first_key, b.first_key);
                }
            }.lessThan);
        }
    }

    // ── Compaction: L0 + overlapping L1 -> L1 ──

    /// Merge every L0 file of `table_name` with the overlapping L1 files into
    /// new L1 files. Per user key the highest-sequence entry wins; a tombstone
    /// that is the newest entry is dropped, reclaiming the key's space. The
    /// manifest is published before input files are deleted.
    pub fn compactTable(self: *Store, gpa: Allocator, table_name: []const u8) !CompactStats {
        var result: CompactStats = .{};
        const timer_start = Io.Clock.Timestamp.now(self.io, .awake);
        defer result.compaction_ns = @intCast(timer_start.untilNow(self.io).raw.nanoseconds);

        const meta = self.tables.get(table_name) orelse return error.TableNotFound;
        if (meta.levels[level0].items.len == 0) return result;

        // Inputs: all L0 files plus L1 files whose ranges intersect the L0
        // union range.
        var inputs: std.ArrayList(FileMeta) = .empty;
        defer inputs.deinit(gpa);
        var input_numbers: std.ArrayList(u64) = .empty;
        defer input_numbers.deinit(gpa);
        var l0_first: []const u8 = undefined;
        var l0_last: []const u8 = undefined;
        for (meta.levels[level0].items, 0..) |f, i| {
            try inputs.append(gpa, f);
            try input_numbers.append(gpa, f.number);
            if (i == 0) {
                l0_first = f.first_key;
                l0_last = f.last_key;
            } else {
                if (codec.internalLessThan(f.first_key, l0_first)) l0_first = f.first_key;
                if (codec.internalLessThan(l0_last, f.last_key)) l0_last = f.last_key;
            }
        }
        for (meta.levels[level1].items) |f| {
            const overlaps = !codec.internalLessThan(f.last_key, l0_first) and
                !codec.internalLessThan(l0_last, f.first_key);
            if (overlaps) {
                try inputs.append(gpa, f);
                try input_numbers.append(gpa, f.number);
            }
        }

        // Merge every input entry, sorted by internal key; the first entry per
        // user key has the highest sequence and wins.
        var merged: std.ArrayList(Entry) = .empty;
        defer {
            for (merged.items) |*e| e.deinit(gpa);
            merged.deinit(gpa);
        }
        for (inputs.items) |f| {
            result.input_files += 1;
            result.input_bytes += f.size;
            var reader = try sstable.Reader.open(gpa, self.io, self.dir, &fileName(f.number));
            defer reader.deinit();
            const all = try reader.iterate(gpa, self.io);
            defer {
                for (all) |e| {
                    gpa.free(@constCast(e.key));
                    gpa.free(@constCast(e.value));
                }
                gpa.free(all);
            }
            try merged.ensureUnusedCapacity(gpa, all.len);
            for (all) |e| {
                const parsed = codec.parseSuffix(e.key[e.key.len - codec.suffix_len ..][0..8].*);
                merged.appendAssumeCapacity(.{
                    .key = try gpa.dupe(u8, e.key),
                    .value = try gpa.dupe(u8, e.value),
                    .seq = parsed.seq,
                    .is_delete = parsed.value_type == .delete,
                });
            }
        }
        result.entries_in = merged.items.len;
        std.mem.sort(Entry, merged.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return codec.internalLessThan(a.key, b.key);
            }
        }.lessThan);

        // Deduplicate per user key (newest first) and drop tombstone-resolved
        // keys. Output entries are the surviving puts.
        var outputs: std.ArrayList(Entry) = .empty;
        defer {
            for (outputs.items) |*e| e.deinit(gpa);
            outputs.deinit(gpa);
        }
        try outputs.ensureTotalCapacity(gpa, merged.items.len);
        var i: usize = 0;
        while (i < merged.items.len) {
            const user_key = codec.userKeyOf(merged.items[i].key);
            var j = i + 1;
            while (j < merged.items.len and std.mem.eql(u8, user_key, codec.userKeyOf(merged.items[j].key))) : (j += 1) {}
            const winner = merged.items[i];
            if (!winner.is_delete) {
                outputs.appendAssumeCapacity(.{
                    .key = try gpa.dupe(u8, winner.key),
                    .value = try gpa.dupe(u8, winner.value),
                    .seq = winner.seq,
                    .is_delete = false,
                });
            }
            result.dropped_entries += j - i - 1;
            if (winner.is_delete) result.dropped_entries += 1;
            i = j;
        }
        result.entries_out = outputs.items.len;
        var new_files: std.ArrayList(FileMeta) = .empty;
        defer {
            for (new_files.items) |*f| f.deinit(gpa);
            new_files.deinit(gpa);
        }
        if (outputs.items.len == 0) {
            // Every key resolved to a tombstone: nothing to write, the table's
            // storage is empty. Still publish the manifest and reclaim inputs.
            result.ran = true;
            try self.installCompactedFiles(gpa, table_name, input_numbers.items, &new_files);
            return result;
        }

        // Pack outputs into target-size L1 files.
        // Runs borrow output entries (their keys/values stay owned by
        // `outputs`); only the run lists themselves are owned here.
        var runs: std.ArrayList(std.ArrayList(Entry)) = .empty;
        defer {
            for (runs.items) |*run| run.deinit(gpa);
            runs.deinit(gpa);
        }
        var current: std.ArrayList(Entry) = .empty;
        var current_bytes: usize = 0;
        for (outputs.items) |e| {
            const entry_bytes = e.key.len + e.value.len + 8;
            if (current.items.len != 0 and current_bytes + entry_bytes > sstable.default_target_file_size) {
                try runs.append(gpa, current);
                current = .empty;
                current_bytes = 0;
            }
            try current.append(gpa, e);
            current_bytes += entry_bytes;
        }
        if (current.items.len != 0) try runs.append(gpa, current);

        for (runs.items) |run| {
            const number = self.next_file_number;
            self.next_file_number += 1;
            const meta_out = try self.writeSst(gpa, number, run.items);
            // On append success the list owns the keys; on failure free them.
            new_files.append(gpa, meta_out) catch |err| {
                gpa.free(meta_out.first_key);
                gpa.free(meta_out.last_key);
                return err;
            };
        }

        result.ran = true;
        result.output_files = new_files.items.len;
        try self.installCompactedFiles(gpa, table_name, input_numbers.items, &new_files);
        for (new_files.items) |f| result.output_bytes += f.size;
        self.stats.compaction_runs += 1;
        self.stats.compaction_input_files += result.input_files;
        self.stats.compaction_input_bytes += result.input_bytes;
        self.stats.compaction_output_files += result.output_files;
        self.stats.compaction_output_bytes += result.output_bytes;
        self.stats.compaction_entries_in += result.entries_in;
        self.stats.compaction_entries_out += result.entries_out;
        self.stats.compaction_dropped_entries += result.dropped_entries;
        return result;
    }

    /// Replace the input files with the output files in the version set,
    /// publish the manifest, then delete the input files from disk. Input
    /// files are identified by number so no pointer into the replaced metadata
    /// outlives it.
    fn installCompactedFiles(self: *Store, gpa: Allocator, table_name: []const u8, input_numbers: []const u64, outputs: *std.ArrayList(FileMeta)) !void {
        var old_meta = self.tables.fetchRemove(table_name) orelse return error.TableNotFound;
        errdefer old_meta.value.deinit(gpa);

        var new_meta = try TableMeta.clone(gpa, &old_meta.value);
        errdefer new_meta.deinit(gpa);

        // L0 is fully consumed by the compaction.
        for (new_meta.levels[level0].items) |*f| f.deinit(gpa);
        new_meta.levels[level0].deinit(gpa);
        new_meta.levels[level0] = .empty;

        // L1 keeps only the files whose ranges did not overlap the L0 range.
        // In-place compaction: input files are freed, survivors move down.
        var dst: usize = 0;
        for (new_meta.levels[level1].items) |f| {
            if (isInputFile(input_numbers, f.number)) {
                var removed = f;
                removed.deinit(gpa);
            } else {
                new_meta.levels[level1].items[dst] = f;
                dst += 1;
            }
        }
        new_meta.levels[level1].shrinkRetainingCapacity(dst);

        for (outputs.items) |f| {
            try new_meta.levels[level1].append(gpa, f);
        }
        // Output ownership moved into `new_meta`; keep the caller's cleanup
        // from freeing keys the version set now references.
        outputs.items.len = 0;
        std.mem.sort(FileMeta, new_meta.levels[level1].items, {}, struct {
            fn lessThan(_: void, a: FileMeta, b: FileMeta) bool {
                return codec.internalLessThan(a.first_key, b.first_key);
            }
        }.lessThan);

        try self.tables.put(new_meta.name, new_meta);
        // Publish before deleting: a crash after the publish leaves the input
        // files as reclaimable orphans; a crash before leaves everything intact.
        self.publishManifest(gpa) catch |err| {
            _ = self.tables.fetchRemove(table_name);
            try self.tables.put(old_meta.key, old_meta.value);
            return err;
        };
        // Delete input files while their metadata is still owned by
        // `old_meta`; `inputs` may otherwise dangle after the deinit.
        for (input_numbers) |number| {
            self.dir.deleteFile(self.io, &fileName(number)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            self.stats.files_reclaimed += 1;
        }
        old_meta.value.deinit(gpa);
        try syncDir(self.dir, self.io);
    }

    fn isInputFile(input_numbers: []const u64, number: u64) bool {
        for (input_numbers) |n| {
            if (n == number) return true;
        }
        return false;
    }

    // ── Read paths ──

    /// Point lookup by user key across a table's files: L0 newest-first, then
    /// the L1 file whose range contains the key (binary search). The first hit
    /// wins; a delete tombstone is returned as `is_delete` so the caller
    /// treats the key as absent. The caller owns the returned entry.
    pub fn pointLookup(self: *Store, gpa: Allocator, table_name: []const u8, user_key: []const u8) !?Entry {
        const meta = self.tables.get(table_name) orelse return error.TableNotFound;
        const seek = try codec.seekKey(gpa, user_key);
        defer gpa.free(seek);

        // L0: ranges overlap; the newest file is authoritative.
        var i: usize = meta.levels[level0].items.len;
        while (i > 0) {
            i -= 1;
            const f = meta.levels[level0].items[i];
            if (try self.findInFile(gpa, f.number, user_key)) |entry| return entry;
        }
        // L1: non-overlapping, binary search by last key.
        const l1 = meta.levels[level1].items;
        var lo: usize = 0;
        var hi: usize = l1.len;
        var hit: ?usize = null;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, l1[mid].last_key, seek) == .lt) {
                lo = mid + 1;
            } else {
                hit = mid;
                hi = mid;
            }
        }
        if (hit) |idx| {
            const f = l1[idx];
            if (codec.internalLessThan(f.first_key, seek) or std.mem.eql(u8, f.first_key, seek)) {
                if (try self.findInFile(gpa, f.number, user_key)) |entry| return entry;
            }
        }
        return null;
    }

    fn findInFile(self: *Store, gpa: Allocator, number: u64, user_key: []const u8) !?Entry {
        var reader = try sstable.Reader.open(gpa, self.io, self.dir, &fileName(number));
        defer reader.deinit();
        if (try reader.find(gpa, self.io, user_key)) |hit| {
            defer {
                gpa.free(@constCast(hit.key));
                gpa.free(@constCast(hit.value));
            }
            const parsed = codec.parseSuffix(hit.key[hit.key.len - codec.suffix_len ..][0..8].*);
            return .{
                .key = try gpa.dupe(u8, hit.key),
                .value = try gpa.dupe(u8, hit.value),
                .seq = parsed.seq,
                .is_delete = parsed.value_type == .delete,
            };
        }
        return null;
    }

    /// The full merged view of a table across every level: entries sorted by
    /// internal key with one entry per user key (the newest). Used by recovery
    /// to rebuild the in-memory table and by tests. The caller owns the result.
    pub fn loadTableEntries(self: *Store, gpa: Allocator, table_name: []const u8) ![]Entry {
        const meta = self.tables.get(table_name) orelse return error.TableNotFound;
        var merged: std.ArrayList(Entry) = .empty;
        defer {
            for (merged.items) |*e| e.deinit(gpa);
            merged.deinit(gpa);
        }
        for (&meta.levels) |*list| {
            for (list.items) |f| {
                var reader = try sstable.Reader.open(gpa, self.io, self.dir, &fileName(f.number));
                defer reader.deinit();
                const all = try reader.iterate(gpa, self.io);
                defer {
                    for (all) |e| {
                        gpa.free(@constCast(e.key));
                        gpa.free(@constCast(e.value));
                    }
                    gpa.free(all);
                }
                try merged.ensureUnusedCapacity(gpa, all.len);
                for (all) |e| {
                    const parsed = codec.parseSuffix(e.key[e.key.len - codec.suffix_len ..][0..8].*);
                    merged.appendAssumeCapacity(.{
                        .key = try gpa.dupe(u8, e.key),
                        .value = try gpa.dupe(u8, e.value),
                        .seq = parsed.seq,
                        .is_delete = parsed.value_type == .delete,
                    });
                }
            }
        }
        if (merged.items.len == 0) return gpa.alloc(Entry, 0);
        std.mem.sort(Entry, merged.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return codec.internalLessThan(a.key, b.key);
            }
        }.lessThan);
        var out: std.ArrayList(Entry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(gpa);
            out.deinit(gpa);
        }
        var i: usize = 0;
        while (i < merged.items.len) {
            const user_key = codec.userKeyOf(merged.items[i].key);
            var j = i + 1;
            while (j < merged.items.len and std.mem.eql(u8, user_key, codec.userKeyOf(merged.items[j].key))) : (j += 1) {}
            const winner = merged.items[i];
            try out.append(gpa, .{
                .key = try gpa.dupe(u8, winner.key),
                .value = try gpa.dupe(u8, winner.value),
                .seq = winner.seq,
                .is_delete = winner.is_delete,
            });
            i = j;
        }
        return out.toOwnedSlice(gpa);
    }

    // ── Reclamation ──

    /// Delete every `sst_*.sst` file on disk that no version set references
    /// (interrupted flushes, failed compactions, or abandoned files). Mirrors
    /// the evidence payload store's orphan reclamation.
    pub fn reclaimOrphans(self: *Store, gpa: Allocator) !ReclaimStats {
        var result: ReclaimStats = .{};
        var referenced = std.AutoHashMap(u64, void).init(gpa);
        defer referenced.deinit();
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            for (&entry.value_ptr.levels) |*list| {
                for (list.items) |f| try referenced.put(f.number, {});
            }
        }
        var dir_it = self.dir.iterate();
        while (try dir_it.next(self.io)) |dir_entry| {
            if (dir_entry.kind != .file) continue;
            const number = parseFileName(dir_entry.name) orelse continue;
            if (referenced.contains(number)) continue;
            const stat = try self.dir.statFile(self.io, dir_entry.name, .{});
            try self.dir.deleteFile(self.io, dir_entry.name);
            result.count += 1;
            result.bytes += stat.size;
            self.stats.recovery_orphan_files += 1;
            self.stats.recovery_orphan_bytes += stat.size;
        }
        if (result.count != 0) try syncDir(self.dir, self.io);
        return result;
    }
};

// ── Helpers ──

fn userKeyOfPk(gpa: Allocator, pk: value.Value) ![]u8 {
    return switch (pk) {
        .int => |i| gpa.dupe(u8, &codec.encodeIntKey(i)),
        .text => |t| gpa.dupe(u8, t),
        else => error.InvalidPrimaryKey,
    };
}

/// Decode row value bytes produced by `codec.encodeRow`. Thin wrapper so the
/// engine's recovery path imports one LSM entry point.
pub fn decodeRowForEngine(gpa: Allocator, bytes: []const u8) ![]value.Value {
    return codec.decodeRow(gpa, bytes);
}

fn fileName(number: u64) [18]u8 {
    var name: [18]u8 = undefined;
    _ = std.fmt.bufPrint(&name, "sst_{d:0>10}{s}", .{ number, file_suffix }) catch unreachable;
    return name;
}

fn parseFileName(name: []const u8) ?u64 {
    const prefix = file_prefix.len;
    if (name.len <= prefix + file_suffix.len) return null;
    if (!std.mem.eql(u8, name[0..prefix], file_prefix)) return null;
    const suffix_start = name.len - file_suffix.len;
    if (!std.mem.eql(u8, name[suffix_start..], file_suffix)) return null;
    return std.fmt.parseInt(u64, name[prefix..suffix_start], 10) catch null;
}

fn fileExists(dir: Io.Dir, io: Io, name: []const u8) !bool {
    dir.access(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn emptyTableMeta(gpa: Allocator, name: []const u8, columns: []const value.Column, next_serial: i64) Allocator.Error!TableMeta {
    var levels: [max_levels]std.ArrayList(FileMeta) = undefined;
    for (&levels) |*list| list.* = .empty;
    return .{
        .name = try gpa.dupe(u8, name),
        .next_serial = next_serial,
        .columns = try cloneColumns(gpa, columns),
        .levels = levels,
    };
}

fn tableMetaFromSnapshot(gpa: Allocator, source: *const lsm_manifest.TableMeta) !TableMeta {
    var levels: [max_levels]std.ArrayList(FileMeta) = undefined;
    for (&levels) |*list| list.* = .empty;
    for (source.files) |f| {
        if (f.level >= max_levels) return error.CorruptLsmManifest;
        try levels[f.level].append(gpa, .{
            .number = f.number,
            .size = f.size,
            .first_key = try gpa.dupe(u8, f.first_key),
            .last_key = try gpa.dupe(u8, f.last_key),
        });
    }
    // Sorted, non-overlapping files are an L1+ invariant; L0 ranges may
    // overlap by design (flushes append newer state for existing keys).
    for (1..max_levels) |level| {
        const current = levels[level].items;
        var i: usize = 0;
        while (i + 1 < current.len) : (i += 1) {
            if (!codec.internalLessThan(current[i].last_key, current[i + 1].first_key)) return error.CorruptLsmManifest;
        }
    }
    return .{
        .name = try gpa.dupe(u8, source.name),
        .next_serial = source.next_serial,
        .columns = try cloneColumns(gpa, source.columns),
        .levels = levels,
    };
}

fn syncDir(dir: Io.Dir, io: Io) !void {
    var handle = try dir.openFile(io, ".", .{ .mode = .read_only });
    defer handle.close(io);
    try handle.sync(io);
}

// ── Tests ──

const test_dir = "zig-cache/runadb-lsm-store";
const test_dir_flush = test_dir ++ "-flush";
const test_dir_tomb = test_dir ++ "-tomb";
const test_dir_compact = test_dir ++ "-compact";
const test_dir_drop = test_dir ++ "-drop";
const test_dir_orphan = test_dir ++ "-orphan";

/// Build one owned row: [pk int, value int] with the given created seq.
fn makeRow(gpa: Allocator, pk: i64, v: i64, seq: u64) !table_mod.Row {
    const values = try gpa.alloc(value.Value, 2);
    values[0] = .{ .int = pk };
    values[1] = .{ .int = v };
    return .{ .values = values, .version = seq, .created_seq = seq };
}

fn freeRows(gpa: Allocator, rows: []table_mod.Row) void {
    // Rows live in caller-owned arrays; only the value slices are heap-owned.
    for (rows) |*row| {
        gpa.free(row.values);
    }
}

fn openStore(gpa: Allocator, io: Io, dir: []const u8) !Store {
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    return Store.open(gpa, io, dir);
}

const test_columns = [_]value.Column{
    .{ .name = @constCast("id"), .type_tag = .int, .primary_key = true, .serial = true },
    .{ .name = @constCast("v"), .type_tag = .int },
};

test "flush publishes a loadable version set with the table schema" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var store = try openStore(gpa, io, test_dir_flush);
    defer {
        store.deinit();
        Io.Dir.cwd().deleteTree(io, test_dir_flush) catch {};
    }

    var rows = [_]table_mod.Row{
        try makeRow(gpa, 3, 30, 3),
        try makeRow(gpa, 1, 10, 1),
        try makeRow(gpa, 2, 20, 2),
    };
    defer freeRows(gpa, &rows);

    const stats = try store.flushTable(gpa, "t", &test_columns, 0, 7, &rows, 3);
    try std.testing.expectEqual(@as(u64, 1), stats.files);
    try std.testing.expectEqual(@as(u64, 3), stats.entries);
    try store.publishManifest(gpa);
    try std.testing.expectEqual(@as(u64, 3), store.watermark);
    try std.testing.expectEqual(@as(u64, 2), store.next_file_number);

    // Reload from disk into a fresh store: same watermark, schema, and rows.
    var reloaded = try Store.open(gpa, io, test_dir_flush);
    defer reloaded.deinit();
    try reloaded.loadFromDisk(gpa);
    try std.testing.expectEqual(@as(u64, 3), reloaded.watermark);
    try std.testing.expectEqual(@as(u64, 2), reloaded.next_file_number);
    try std.testing.expect(reloaded.hasTable("t"));

    const entries = try reloaded.loadTableEntries(gpa, "t");
    defer {
        for (entries) |*e| e.deinit(gpa);
        gpa.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    // Merged entries sort by primary key (int user keys), newest seq first.
    try std.testing.expectEqualStrings("id", reloaded.tables.get("t").?.columns[0].name);
    try std.testing.expectEqual(@as(i64, 7), reloaded.tables.get("t").?.next_serial);

    // Point lookups by user key.
    const key2 = codec.encodeIntKey(2);
    var hit = (try reloaded.pointLookup(gpa, "t", &key2)).?;
    defer hit.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 1), hit.seq);
    try std.testing.expect(!hit.is_delete);
}

test "flush writes tombstones so deleted keys cannot resurrect" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var store = try openStore(gpa, io, test_dir_tomb);
    defer {
        store.deinit();
        Io.Dir.cwd().deleteTree(io, test_dir_tomb) catch {};
    }

    var first = [_]table_mod.Row{
        try makeRow(gpa, 1, 10, 1),
        try makeRow(gpa, 2, 20, 2),
    };
    defer freeRows(gpa, &first);
    _ = try store.flushTable(gpa, "t", &test_columns, 0, 3, &first, 2);
    try store.publishManifest(gpa);

    // Row 1 is deleted at watermark 5; row 2 is updated.
    var second = [_]table_mod.Row{try makeRow(gpa, 2, 21, 4)};
    defer freeRows(gpa, &second);
    const stats = try store.flushTable(gpa, "t", &test_columns, 0, 3, &second, 5);
    try std.testing.expectEqual(@as(u64, 1), stats.tombstones);
    try store.publishManifest(gpa);

    const entries = try store.loadTableEntries(gpa, "t");
    defer {
        for (entries) |*e| e.deinit(gpa);
        gpa.free(entries);
    }
    // Merged view: key 1 is a delete tombstone (its old put is shadowed),
    // key 2 carries its newest put.
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(i64, 1), codec.decodeIntKey(entries[0].key[0..8].*));
    try std.testing.expect(entries[0].is_delete);
    try std.testing.expectEqual(@as(i64, 2), codec.decodeIntKey(entries[1].key[0..8].*));
    try std.testing.expectEqual(@as(u64, 2), entries[1].seq);
    try std.testing.expect(!entries[1].is_delete);

    const key1 = codec.encodeIntKey(1);
    const gone = try store.pointLookup(gpa, "t", &key1);
    defer {
        if (gone) |g| {
            var owned = g;
            owned.deinit(gpa);
        }
    }
    try std.testing.expect(gone != null);
    try std.testing.expect(gone.?.is_delete);
}

test "compaction merges levels, drops superseded versions, and reclaims files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var store = try openStore(gpa, io, test_dir_compact);
    defer {
        store.deinit();
        Io.Dir.cwd().deleteTree(io, test_dir_compact) catch {};
    }

    // Flush 1: rows 1=v10, 2=v20 at watermark 2.
    var first = [_]table_mod.Row{
        try makeRow(gpa, 1, 10, 1),
        try makeRow(gpa, 2, 20, 2),
    };
    defer freeRows(gpa, &first);
    _ = try store.flushTable(gpa, "t", &test_columns, 0, 3, &first, 2);
    try store.publishManifest(gpa);
    const first_file = store.tables.get("t").?.levels[0].items[0].number;

    // Flush 2: row 1 updated to v11, row 2 updated to v21, row 3 inserted,
    // at watermark 6. Every row stays live, so no tombstone is written.
    var second = [_]table_mod.Row{
        try makeRow(gpa, 1, 11, 4),
        try makeRow(gpa, 2, 21, 5),
        try makeRow(gpa, 3, 30, 6),
    };
    defer freeRows(gpa, &second);
    const second_stats = try store.flushTable(gpa, "t", &test_columns, 0, 4, &second, 6);
    try std.testing.expectEqual(@as(u64, 0), second_stats.tombstones);
    try store.publishManifest(gpa);
    try std.testing.expectEqual(@as(usize, 2), store.tables.get("t").?.levels[0].items.len);

    // Compact: L0 files merge into L1; row 1 keeps only its newest version.
    const result = try store.compactTable(gpa, "t");
    try std.testing.expect(result.ran);
    try std.testing.expectEqual(@as(usize, 2), result.input_files);
    try std.testing.expectEqual(@as(usize, 1), result.output_files);
    // Flush 1 wrote 2 puts; flush 2 wrote 3 puts.
    try std.testing.expectEqual(@as(u64, 5), result.entries_in);
    // Keys 1 and 2 keep only their newest puts; key 3 stays as inserted.
    try std.testing.expectEqual(@as(u64, 3), result.entries_out);
    try std.testing.expectEqual(@as(u64, 2), result.dropped_entries);
    try std.testing.expectEqual(@as(usize, 0), store.tables.get("t").?.levels[0].items.len);
    try std.testing.expectEqual(@as(usize, 1), store.tables.get("t").?.levels[1].items.len);

    // Input files were reclaimed from disk.
    try std.testing.expect(!(try fileExists(store.dir, io, &fileName(first_file))));

    const entries = try store.loadTableEntries(gpa, "t");
    defer {
        for (entries) |*e| e.deinit(gpa);
        gpa.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    // Rows are [pk, v]; decode and check the second column.
    const decoded = try codec.decodeRow(gpa, entries[0].value);
    defer {
        for (decoded) |*dv| dv.deinit(gpa);
        gpa.free(decoded);
    }
    try std.testing.expectEqual(@as(i64, 11), decoded[1].int);

    // A second compaction with an empty L0 is a no-op.
    const noop = try store.compactTable(gpa, "t");
    try std.testing.expect(!noop.ran);
}

test "compaction drops tombstone-resolved keys entirely" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var store = try openStore(gpa, io, test_dir_tomb);
    defer {
        store.deinit();
        Io.Dir.cwd().deleteTree(io, test_dir_tomb) catch {};
    }

    var first = [_]table_mod.Row{
        try makeRow(gpa, 1, 10, 1),
        try makeRow(gpa, 2, 20, 2),
    };
    defer freeRows(gpa, &first);
    _ = try store.flushTable(gpa, "t", &test_columns, 0, 3, &first, 2);
    try store.publishManifest(gpa);

    // Both rows deleted.
    const empty = [_]table_mod.Row{};
    _ = try store.flushTable(gpa, "t", &test_columns, 0, 3, &empty, 4);
    try store.publishManifest(gpa);

    const result = try store.compactTable(gpa, "t");
    try std.testing.expect(result.ran);
    try std.testing.expectEqual(@as(u64, 0), result.entries_out);
    // The compacted table has no files at all.
    const meta = store.tables.get("t").?;
    try std.testing.expectEqual(@as(usize, 0), meta.levels[0].items.len);
    try std.testing.expectEqual(@as(usize, 0), meta.levels[1].items.len);
    const entries = try store.loadTableEntries(gpa, "t");
    defer gpa.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "recovery reclaims orphan sst files and rejects a corrupt manifest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var store = try openStore(gpa, io, test_dir_orphan);
    defer {
        store.deinit();
        Io.Dir.cwd().deleteTree(io, test_dir_orphan) catch {};
    }

    var rows = [_]table_mod.Row{try makeRow(gpa, 1, 10, 1)};
    defer freeRows(gpa, &rows);
    _ = try store.flushTable(gpa, "t", &test_columns, 0, 2, &rows, 1);
    try store.publishManifest(gpa);

    // An unreferenced SSTable (interrupted flush): build one, never register.
    {
        const orphan_name = fileName(99);
        var builder = try sstable.Builder.create(gpa, io, store.dir, &orphan_name);
        defer builder.deinit();
        const k = try codec.internalKey(gpa, "orphan", 1, .put);
        defer gpa.free(k);
        try builder.add(k, "x");
        _ = try builder.finish();
    }

    const reclaimed = try store.reclaimOrphans(gpa);
    try std.testing.expectEqual(@as(u64, 1), reclaimed.count);
    try std.testing.expect(!(try fileExists(store.dir, io, &fileName(99))));

    // Corrupting the manifest makes the next load fail rather than ignore it.
    {
        var file = try store.dir.openFile(io, "manifest", .{ .mode = .read_write });
        defer file.close(io);
        var byte: [1]u8 = undefined;
        _ = try file.readPositionalAll(io, &byte, 0);
        byte[0] ^= 0xFF;
        try file.writePositionalAll(io, &byte, 0);
    }
    var broken = try Store.open(gpa, io, test_dir_orphan);
    defer broken.deinit();
    try std.testing.expectError(error.InvalidLsmManifest, broken.loadFromDisk(gpa));
}
