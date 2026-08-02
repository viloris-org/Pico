const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const wal_mod = @import("wal.zig");
const vfs_mod = @import("vfs.zig");
const table_mod = @import("table.zig");
const mvcc_mod = @import("mvcc.zig");
const document_mod = @import("document.zig");
const graph_mod = @import("graph.zig");
const manifest_mod = @import("manifest.zig");
const checkpoint_mod = @import("checkpoint.zig");
const evidence_mod = @import("evidence.zig");
const vector_mod = @import("../vector.zig");
const lsm_store = @import("lsm/store.zig");
const commit_mod = @import("../commit/coordinator.zig");
const txn_mod = @import("../txn/transaction.zig");

pub const EngineError = table_mod.Error;
pub const Row = table_mod.Row;
pub const Table = table_mod.Table;
pub const Pred = table_mod.Pred;
pub const ColumnSpec = table_mod.ColumnSpec;
pub const VectorSearchError = error{VectorColumnRequired} || vector_mod.Error || Allocator.Error;

const Coordinator = commit_mod.Coordinator(*Engine, .{
    .walAppend = engineWalAppend,
    .rowVersion = engineRowVersion,
    .pkExists = enginePkExists,
    .pkOf = enginePkOf,
    .applyOp = engineApplyOp,
    .validateOp = engineValidateOp,
});

fn engineWalAppend(eng: *Engine) *wal_mod.Wal {
    return &eng.wal;
}

fn engineRowVersion(eng: *Engine, table_name: []const u8, pk: value.Value) ?u64 {
    const table = eng.tables.getPtr(table_name) orelse return null;
    return table.rowVersion(pk);
}

fn enginePkExists(eng: *Engine, table_name: []const u8, pk: value.Value) bool {
    const table = eng.tables.getPtr(table_name) orelse return false;
    return table.pkContains(pk);
}

fn enginePkOf(eng: *Engine, table_name: []const u8, values: []const value.Value) ?value.Value {
    const table = eng.tables.getPtr(table_name) orelse return null;
    const pki = table.pk_index orelse return null;
    if (pki >= values.len) return null;
    return values[pki];
}

fn engineApplyOp(eng: *Engine, op: *const wal_mod.TxnOp, commit_seq: u64) anyerror!void {
    if (eng.test_fail_next_apply) {
        eng.test_fail_next_apply = false;
        return error.PrimaryKeyNotFound;
    }
    return eng.applyTxnOp(op, commit_seq);
}

fn engineValidateOp(eng: *Engine, op: *const wal_mod.TxnOp, shadow: []const commit_mod.ShadowEntry) commit_mod.CoordError!void {
    return eng.validateCoordinatedOp(op, shadow);
}

/// Operator-configurable resource bounds for Observation Evidence (ADR-0019).
/// A rejected limit creates no visible evidence and no WAL record.
pub const EvidenceLimits = struct {
    /// Maximum attachments staged concurrently across all connections. A
    /// connection stages at most one attachment; this bounds the instance-wide
    /// total, not the per-Connection rule already enforced by the protocol.
    max_concurrent_staging: usize = 8,
    /// Maximum expected bytes staged concurrently across all connections.
    max_staged_bytes: u64 = 64 * 1024 * 1024,
    /// Maximum retained committed payload bytes across all evidence.
    max_retained_bytes: u64 = 512 * 1024 * 1024,
};

/// Why evidence was rejected. Metrics break rejections down by this reason.
pub const RejectReason = enum(u8) {
    payload_too_large,
    invalid_metadata,
    retained_quota,
    corrupt_payload,
    storage_failure,
};

/// Evidence operator metrics (ADR-0019 "Reads And Observability"). Counters
/// never expose payload bytes, origin secrets, or authorization tokens.
pub const EvidenceStats = struct {
    // Staged-upload accounting: uploads begun instance-wide, and how many
    // staging reservations were aborted or rejected by a quota.
    staged_uploads: u64 = 0,
    staged_upload_bytes: u64 = 0,
    aborted_uploads: u64 = 0,
    staging_rejections: u64 = 0,
    // Accepted (committed) evidence by modality; `committed_count` is the total.
    accepted_by_modality: [modalityCount]u64 = [_]u64{0} ** modalityCount,
    // Rejected evidence by reason; `rejected_evidence` is the total.
    rejected_evidence: u64 = 0,
    rejected_by_reason: [rejectReasonCount]u64 = [_]u64{0} ** rejectReasonCount,
    // Payload write and synchronization latency (total nanoseconds + count).
    payload_write_ns: u64 = 0,
    payload_write_count: u64 = 0,
    // Committed payloads and recovery orphan reclamation.
    committed_count: u64 = 0,
    committed_bytes: u64 = 0,
    recovery_orphans_found: u64 = 0,
    recovery_orphan_bytes: u64 = 0,
    // Missing, corrupt, or unsupported payload file failures at read time.
    payload_failures: u64 = 0,
};

const modalityCount = std.enums.values(evidence_mod.Modality).len;
const rejectReasonCount = std.enums.values(RejectReason).len;

/// Single-writer storage engine: in-memory tables (the LSM memtable half) +
/// WAL + the on-disk LSM store (roadmap Phase 5). Table rows live in
/// `table.zig`; `lsm/store.zig` materializes durable SSTable snapshots at
/// flush/checkpoint time, and this module owns durability ordering
/// (validate → WAL append → apply → publish).
pub const Engine = struct {
    gpa: Allocator,
    io: Io,
    wal: wal_mod.Wal,
    payloads: evidence_mod.Store,
    /// On-disk LSM version set (roadmap Phase 5): per-table SSTable levels and
    /// the durable manifest. The in-memory `Table`s are the memtable half;
    /// this store materializes durable snapshots at flush/checkpoint time.
    lsm: lsm_store.Store,
    /// Recovery watermark of the last LSM flush. WAL records with
    /// `commit_seq <= lsm_watermark` are already materialized in SSTables and
    /// are skipped during recovery replay; tables named by the LSM manifest
    /// are rebuilt from SSTables before the WAL tail is applied.
    lsm_watermark: u64 = 0,
    tables: std.StringHashMap(Table),
    /// Document collections (roadmap Phase 2). A name is exclusive between
    /// tables and document collections; recovery rebuilds both from the WAL.
    documents: std.StringHashMap(document_mod.Collection),
    /// Graph collections (roadmap Phase 2). A name is exclusive with tables
    /// and document collections.
    graphs: std.StringHashMap(graph_mod.Graph),
    observations: std.ArrayList(evidence_mod.Record),
    next_evidence_id: u64 = 1,
    evidence_stats: EvidenceStats = .{},
    /// Operator resource bounds for evidence staging and retention.
    evidence_limits: EvidenceLimits = .{},
    /// Instance-wide attachments currently in the begin..finish/abort staging
    /// window. Guarded by `writer_mutex` in a multi-threaded runtime; the
    /// current single-threaded server never overlaps these with a writer.
    staging_active: usize = 0,
    staging_active_bytes: u64 = 0,
    /// Highest commit sequence whose changes are visible to readers. Advanced by
    /// the commit coordinator only after WAL durability and in-memory
    /// publication succeed. Rebuilt from `txn_batch`/`set_commit_seq` records
    /// during recovery. Row versions become visible through this watermark.
    published_commit_seq: u64 = 0,
    /// Active snapshot watermarks (roadmap Phase 5 MVCC retention). Reads
    /// register their watermark before reading and deregister afterwards, so
    /// `oldest_active_snapshot_seq` protects retained versions from reclamation
    /// while any snapshot can still see them.
    snapshot_registry: mvcc_mod.SnapshotRegistry = undefined,
    /// Single-writer commit coordinator: assigns commit order, writes WAL
    /// records, validates conflicts, and publishes confirmed changes. All DML
    /// mutation enters through this boundary.
    coordinator: Coordinator,
    /// Serializes DDL, observe, and checkpoint (the non-coordinator writers)
    /// against each other. DML mutation is ordered by the commit coordinator's
    /// own mutex; in the current single-threaded server these never overlap.
    /// A future multi-threaded runtime must route DDL and catalog changes
    /// through the same single-writer queue as DML (see
    /// `docs/architecture/concurrency-control.md`).
    ///
    /// A checkpoint discards WAL frames on the strength of the table state it
    /// captured, so it must never observe a writer between its WAL append and
    /// its table apply: that state omits the appended record while the rewrite
    /// drops the frame carrying it, losing a commit.
    ///
    /// Scope note: this makes writers mutually exclusive and excludes
    /// checkpoint. Readers (`getTable`, `selectAll`, `matchIndices`) still run
    /// unsynchronized against writers — see the concurrency note in
    /// `docs/architecture/wal-and-recovery.md`.
    writer_mutex: Io.Mutex = .init,
    /// Statement-boundary serialization (roadmap Phase 6). A connection thread
    /// holds `engine_lock` for the whole execution of one request (compile +
    /// bind + execute and any mutation) and releases it before sending the
    /// fully-owned result over the wire, so concurrent connections never observe
    /// the engine mid-statement. The engine's `writer_mutex` and the commit
    /// coordinator's own mutex nest under it: the lock order is always
    /// `engine_lock -> (writer_mutex | coordinator.mutex)`, and no path acquires
    /// `engine_lock` while holding another engine lock, so there is no cycle.
    /// `coordinator.cancel` takes only the coordinator mutex and never touches
    /// this lock, so cancellation cannot deadlock against a running statement.
    engine_lock: Io.Mutex = .init,
    /// Test-only fault injection at the publication boundary: when true, the
    /// next coordinator apply fails (as `PrimaryKeyNotFound`) before touching
    /// the table. The WAL record is already durable at that point, so the test
    /// asserts that an in-memory publication failure never loses a durable
    /// commit and that restart converges to the WAL-confirmed prefix. Never set
    /// outside tests.
    test_fail_next_apply: bool = false,

    pub fn open(gpa: Allocator, io: Io, data_dir: []const u8, sync_wal: bool) !Engine {
        var wal = try wal_mod.Wal.open(gpa, io, data_dir, sync_wal);
        var transferred = false;
        errdefer if (!transferred) wal.deinit();
        var payloads = try evidence_mod.Store.open(io, data_dir, sync_wal);
        errdefer if (!transferred) payloads.deinit();
        var lsm = try lsm_store.Store.open(gpa, io, data_dir);
        errdefer if (!transferred) lsm.deinit();
        var eng: Engine = .{
            .gpa = gpa,
            .io = io,
            .wal = wal,
            .payloads = payloads,
            .lsm = lsm,
            .tables = std.StringHashMap(Table).init(gpa),
            .documents = std.StringHashMap(document_mod.Collection).init(gpa),
            .graphs = std.StringHashMap(graph_mod.Graph).init(gpa),
            .observations = .empty,
            .coordinator = Coordinator.init(gpa, io),
            .snapshot_registry = mvcc_mod.SnapshotRegistry.init(gpa),
        };
        transferred = true;
        errdefer eng.deinit();
        try eng.recover();
        // Recovery rebuilds the published watermark from the WAL; the
        // coordinator's sequence counters must start from the recovered state.
        eng.coordinator.restoreWatermark(eng.published_commit_seq);
        return eng;
    }

    pub fn deinit(self: *Engine) void {
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.gpa);
        }
        self.tables.deinit();
        var doc_it = self.documents.iterator();
        while (doc_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.documents.deinit();
        var graph_it = self.graphs.iterator();
        while (graph_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.graphs.deinit();
        for (self.observations.items) |*record| record.deinit(self.gpa);
        self.observations.deinit(self.gpa);
        self.payloads.deinit();
        self.lsm.deinit();
        self.coordinator.deinit();
        self.snapshot_registry.deinit();
        self.wal.deinit();
        self.* = undefined;
    }

    /// Acquire the instance-wide statement-execution lock (roadmap Phase 6).
    /// The net layer holds it around the whole execution of one request and
    /// releases it before sending the result over the wire.
    pub fn lock(self: *Engine, io: Io) Io.Cancelable!void {
        try self.engine_lock.lock(io);
    }

    /// Release the instance-wide statement-execution lock.
    pub fn unlock(self: *Engine, io: Io) void {
        self.engine_lock.unlock(io);
    }

    /// Acquire the instance-wide statement-execution lock without a
    /// cancellation point. Used by cleanup paths that must release accounting
    /// exactly once (a connection dropping mid-upload).
    pub fn lockUncancelable(self: *Engine, io: Io) void {
        self.engine_lock.lockUncancelable(io);
    }

    /// Try to acquire the statement-execution lock without blocking. Used by
    /// the runtime fault regressions to observe that a slow consumer does not
    /// hold the lock while its result is being sent; returns false when a
    /// statement is currently executing under the lock.
    pub fn tryLock(self: *Engine) bool {
        return self.engine_lock.tryLock();
    }

    fn recover(self: *Engine) !void {
        // Load the durable LSM version set first: its watermark defines which
        // WAL records are already materialized, and its tables are rebuilt
        // from SSTables before the WAL tail replays on top of them.
        try self.lsm.loadFromDisk(self.gpa);
        self.lsm_watermark = self.lsm.watermark;
        self.published_commit_seq = self.lsm_watermark;
        try self.loadLsmTables();
        try wal_mod.replayWal(&self.wal, self, applyRecord);
        // The manifest's serial counters are authoritative for flushed tables:
        // replayed inserts raise next_serial to max(pk)+1, which lags the
        // live counter whenever a row was deleted before the flush.
        try self.restoreLsmSerials();
        // Reclaim SSTable files no version set references (interrupted flushes
        // or compactions that crashed before their manifest edit).
        _ = try self.lsm.reclaimOrphans(self.gpa);
        var committed = std.AutoHashMap(u64, usize).init(self.gpa);
        defer committed.deinit();
        for (self.observations.items, 0..) |record, index| try committed.put(record.evidence_id, index);
        const reclaimed = try self.payloads.reclaimOrphans(&committed);
        self.evidence_stats.recovery_orphans_found = reclaimed.count;
        self.evidence_stats.recovery_orphan_bytes = reclaimed.bytes;
        try self.validateManifest();
    }

    /// Rebuild every LSM-managed table from its manifest schema and SSTables:
    /// the manifest's columns create the table, the merged SSTable entries
    /// restore its rows (skipping delete tombstones), and the manifest's serial
    /// counter restores its next identifier.
    fn loadLsmTables(self: *Engine) !void {
        var it = self.lsm.tables.iterator();
        while (it.next()) |entry| {
            const meta = entry.value_ptr;
            var specs: std.ArrayList(ColumnSpec) = .empty;
            defer specs.deinit(self.gpa);
            try specs.ensureTotalCapacity(self.gpa, meta.columns.len);
            for (meta.columns) |col| {
                specs.appendAssumeCapacity(.{
                    .name = col.name,
                    .type_tag = col.type_tag,
                    .primary_key = col.primary_key,
                    .not_null = col.not_null,
                    .unique = col.unique,
                    .serial = col.serial,
                    .default_expr = col.default_expr,
                });
            }
            var table = try Table.create(self.gpa, meta.name, specs.items);
            errdefer table.deinit(self.gpa);

            const entries = try self.lsm.loadTableEntries(self.gpa, meta.name);
            defer {
                for (entries) |*e| e.deinit(self.gpa);
                self.gpa.free(entries);
            }
            for (entries) |e| {
                if (e.is_delete) continue;
                const values = try lsm_store.decodeRowForEngine(self.gpa, e.value);
                defer {
                    for (values) |*v| v.deinit(self.gpa);
                    self.gpa.free(values);
                }
                try table.insert(self.gpa, values, @min(e.seq, self.lsm_watermark));
            }
            table.next_serial = meta.next_serial;
            try self.tables.put(table.name, table);
        }
    }

    /// Restore the manifest serial counters after WAL replay. The manifest's
    /// value is authoritative for identifiers retired before the flush, but
    /// replayed post-flush inserts raise the counter further; the live counter
    /// is the maximum of the two.
    fn restoreLsmSerials(self: *Engine) !void {
        var it = self.lsm.tables.iterator();
        while (it.next()) |entry| {
            if (self.tables.getPtr(entry.key_ptr.*)) |table| {
                table.next_serial = @max(table.next_serial, entry.value_ptr.next_serial);
            }
        }
    }

    /// Validate the durable checkpoint manifest against the catalog rebuilt
    /// from the WAL. A manifest published by an incompatible build, a torn
    /// checkpoint, or an inconsistent data directory fails startup rather than
    /// being silently accepted (roadmap Phase 4 format rejection).
    fn validateManifest(self: *Engine) !void {
        const manifest = try manifest_mod.read(self.gpa, &self.wal.vfs) orelse return;
        defer {
            for (manifest.objects) |*object| self.gpa.free(object.name);
            self.gpa.free(manifest.objects);
        }
        if (self.published_commit_seq < manifest.commit_seq) return error.CorruptManifest;
        for (manifest.objects) |*object| {
            const exists = switch (object.kind) {
                .table => self.tables.contains(object.name),
                .document => self.documents.contains(object.name),
                .graph => self.graphs.contains(object.name),
            };
            if (!exists) return error.CorruptManifest;
        }
    }

    fn applyRecord(self: *Engine, view: wal_mod.RecordView) !void {
        switch (view) {
            .txn_batch => |batch| {
                // A batch at or below the LSM watermark is already materialized
                // in SSTables; replaying it would duplicate its rows.
                if (batch.commit_seq != 0 and batch.commit_seq <= self.lsm_watermark) return;
                if (batch.commit_seq != 0 and batch.commit_seq > self.published_commit_seq) {
                    self.published_commit_seq = batch.commit_seq;
                }
                try wal_mod.forEachTxnBatchOp(self.gpa, batch.body, self.wal.file_version, self, applyRecord);
            },
            .set_commit_seq => |seq| {
                if (seq <= self.lsm_watermark) return;
                if (seq > self.published_commit_seq) self.published_commit_seq = seq;
            },
            else => try self.applyOne(view),
        }
    }

    fn applyOne(self: *Engine, view: wal_mod.RecordView) !void {
        switch (view) {
            .txn_batch, .set_commit_seq => return error.InvalidWal,
            .create_table => |ct| {
                // A table loaded from the LSM manifest already exists; this is
                // the crash-window leftover of a checkpoint that flushed but
                // did not finish its WAL rewrite.
                if (self.tables.contains(ct.name)) return;
                try self.registerTable(ct.name, ct.columns);
            },
            // Recovery stamps version intervals from the watermark rebuilt by
            // the enclosing `txn_batch`/`set_commit_seq` records: nested ops of
            // a batch carry its commit_seq, standalone records use the current
            // watermark as it advances during replay.
            .insert => |ins| {
                const table = self.tables.getPtr(ins.table) orelse return error.TableNotFound;
                try table.insert(self.gpa, ins.values, self.published_commit_seq);
            },
            .update => |upd| {
                const table = self.tables.getPtr(upd.table) orelse return error.TableNotFound;
                if (table.pk_index != null) {
                    try table.update(self.gpa, upd.pk, upd.values, self.published_commit_seq);
                } else {
                    const idx: usize = switch (upd.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    try table.updateAt(self.gpa, idx, upd.values, self.published_commit_seq);
                }
            },
            .delete => |del| {
                const table = self.tables.getPtr(del.table) orelse return error.TableNotFound;
                if (table.pk_index != null) {
                    try table.delete(self.gpa, del.pk, self.published_commit_seq);
                } else {
                    const idx: usize = switch (del.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    try table.deleteAt(self.gpa, idx, self.published_commit_seq);
                }
            },
            .add_column => |add| {
                const table = self.tables.getPtr(add.table) orelse return error.TableNotFound;
                // Idempotent replay: the column may already be present because
                // the LSM manifest captured a post-ALTER schema and the WAL
                // rewrite of the interrupted checkpoint was never published.
                if (table.columnIndex(add.column.name) != null) return;
                const col: value.Column = .{
                    .name = @constCast(add.column.name),
                    .type_tag = add.column.type_tag,
                    .primary_key = add.column.primary_key,
                    .not_null = add.column.not_null,
                    .unique = add.column.unique,
                    .serial = add.column.serial,
                    .default_expr = add.column.default_expr,
                };
                var existing = try existingColumnValue(self.gpa, col.default_expr);
                defer existing.deinit(self.gpa);
                try table.addColumn(self.gpa, col, existing);
            },
            .drop_column => |drop| {
                const table = self.tables.getPtr(drop.table) orelse return error.TableNotFound;
                // Idempotent replay, mirroring `add_column`.
                if (table.columnIndex(drop.column) == null) return;
                try table.dropColumn(self.gpa, drop.column);
            },
            // Checkpoint-only record. Replayed inserts raise `next_serial` to
            // `max(pk)+1`; this restores the counter the instance actually
            // reached, so identifiers retired by DELETE are not handed out again.
            .set_serial => |ss| {
                // LSM-managed tables restore their serial counter from the LSM
                // manifest (see `restoreLsmSerials`); a leftover pre-flush
                // record must not rewind it.
                if (self.lsm.hasTable(ss.table)) return;
                const table = self.tables.getPtr(ss.table) orelse return error.TableNotFound;
                table.next_serial = ss.next_serial;
            },
            .set_default => |set| {
                const table = self.tables.getPtr(set.table) orelse return error.TableNotFound;
                try table.setDefault(self.gpa, set.column, set.default_expr);
            },
            .set_not_null => |set| {
                const table = self.tables.getPtr(set.table) orelse return error.TableNotFound;
                try table.setNotNull(set.column, set.enabled);
            },
            .observe => |metadata| {
                if (metadata.evidence_id != self.next_evidence_id) return error.InvalidWal;
                try self.payloads.validateReference(self.gpa, metadata);
                const record = try evidence_mod.Record.clone(self.gpa, metadata);
                errdefer {
                    var owned = record;
                    owned.deinit(self.gpa);
                }
                try self.observations.append(self.gpa, record);
                self.next_evidence_id = metadata.evidence_id + 1;
                self.evidence_stats.committed_count += 1;
                self.evidence_stats.committed_bytes += metadata.payload_length;
            },
            .create_document => |create| {
                if (self.documents.contains(create.name) or self.tables.contains(create.name)) return error.TableExists;
                var collection = try document_mod.Collection.create(self.gpa, create.name);
                errdefer collection.deinit();
                try self.documents.put(collection.name, collection);
            },
            .insert_document => |ins| {
                const collection = self.documents.getPtr(ins.collection) orelse return error.TableNotFound;
                var fields: std.ArrayList(document_mod.Field) = .empty;
                defer {
                    for (fields.items) |*field| field.deinit(self.gpa);
                    fields.deinit(self.gpa);
                }
                try fields.ensureTotalCapacity(self.gpa, ins.fields.len);
                for (ins.fields) |*field| {
                    const path = try self.gpa.dupe(u8, field.path);
                    const item = try field.item.clone(self.gpa);
                    fields.appendAssumeCapacity(.{ .path = path, .item = item });
                }
                try collection.insert(ins.id, fields.items);
            },
            .create_graph => |create| {
                if (self.graphs.contains(create.name) or self.tables.contains(create.name) or self.documents.contains(create.name)) return error.TableExists;
                var graph = try graph_mod.Graph.create(self.gpa, create.name);
                errdefer graph.deinit();
                try self.graphs.put(graph.name, graph);
            },
            .add_node => |rec| {
                const graph = self.graphs.getPtr(rec.graph) orelse return error.TableNotFound;
                var fields: std.ArrayList(document_mod.Field) = .empty;
                defer {
                    for (fields.items) |*field| field.deinit(self.gpa);
                    fields.deinit(self.gpa);
                }
                try fields.ensureTotalCapacity(self.gpa, rec.fields.len);
                for (rec.fields) |*field| {
                    const path = try self.gpa.dupe(u8, field.path);
                    const item = try field.item.clone(self.gpa);
                    fields.appendAssumeCapacity(.{ .path = path, .item = item });
                }
                try graph.addNode(rec.id, fields.items);
            },
            .add_edge => |rec| {
                const graph = self.graphs.getPtr(rec.graph) orelse return error.TableNotFound;
                try graph.addEdge(rec.from, rec.label, rec.to);
            },
        }
    }

    /// Snapshot watermark for a new transaction.
    pub fn snapshotSeq(self: *Engine) u64 {
        return self.coordinator.snapshot();
    }

    /// Published commit watermark.
    pub fn publishedSeq(self: *Engine) u64 {
        return self.coordinator.publishedSeq();
    }

    // ── Snapshot registry and version reclamation (roadmap Phase 5) ──
    //
    // Reads register their watermark and deregister it when done, so
    // `oldestActiveSnapshotSeq` reflects every in-flight snapshot. Reclamation
    // consults it before freeing retained versions: only versions invisible to
    // every active snapshot (`deleted_seq < oldest_active_snapshot_seq`) are
    // reclaimed, and the newest live version is never reclaimed.

    /// Register `s` as an active snapshot watermark.
    pub fn registerSnapshot(self: *Engine, s: u64) (mvcc_mod.RegistryError || Allocator.Error)!void {
        try self.snapshot_registry.register(s);
    }

    /// Release one registration of snapshot watermark `s`.
    pub fn unregisterSnapshot(self: *Engine, s: u64) void {
        self.snapshot_registry.unregister(s);
    }

    /// The lowest active snapshot watermark, or `published_commit_seq + 1` when
    /// no snapshot is active.
    pub fn oldestActiveSnapshotSeq(self: *Engine) u64 {
        return self.snapshot_registry.oldestActive() orelse self.publishedSeq() + 1;
    }

    /// Reclaim retained versions invisible to every active snapshot across all
    /// tables. Returns the total number of versions reclaimed. A future
    /// compactor drives this; the live row set is never touched.
    pub fn reclaimRetainedVersions(self: *Engine) usize {
        const oldest = self.oldestActiveSnapshotSeq();
        var total: usize = 0;
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.reclaimRetained(self.gpa, oldest);
        }
        return total;
    }

    fn applyTxnOp(self: *Engine, op: *const wal_mod.TxnOp, commit_seq: u64) anyerror!void {
        switch (op.*) {
            .insert => |ins| {
                const table = self.tables.getPtr(ins.table) orelse return error.TableNotFound;
                try table.insert(self.gpa, ins.values, commit_seq);
            },
            .update => |upd| {
                const table = self.tables.getPtr(upd.table) orelse return error.TableNotFound;
                if (table.pk_index != null) {
                    try table.update(self.gpa, upd.pk, upd.values, commit_seq);
                } else {
                    const idx: usize = switch (upd.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    try table.updateAt(self.gpa, idx, upd.values, commit_seq);
                }
            },
            .delete => |del| {
                const table = self.tables.getPtr(del.table) orelse return error.TableNotFound;
                if (table.pk_index != null) {
                    try table.delete(self.gpa, del.pk, commit_seq);
                } else {
                    const idx: usize = switch (del.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    try table.deleteAt(self.gpa, idx, commit_seq);
                }
            },
        }
    }

    /// Coordinator-side validation of one op against published tables plus the
    /// round shadow (earlier accepted requests). Unique-column and primary-key
    /// checks must account for a transaction's own earlier inserts, which the
    /// shadow exposes.
    fn validateCoordinatedOp(self: *Engine, op: *const wal_mod.TxnOp, shadow: []const commit_mod.ShadowEntry) commit_mod.CoordError!void {
        switch (op.*) {
            .insert => |ins| {
                const table = self.tables.getPtr(ins.table) orelse return error.PrimaryKeyNotFound;
                table.validateInsert(ins.values) catch |err| return mapCoordError(err);
                // Reject a primary key that another request in the same round
                // already inserted. The engine resolves the pk from the values
                // using the table schema.
                if (table.pk_index) |pki| {
                    const pk = ins.values[pki];
                    if (findShadowRow(shadow, ins.table, pk) != null) return error.DuplicatePrimaryKey;
                }
                // Reject a secondary unique value that an earlier accepted
                // request in this round already inserted. The live table does
                // not yet contain that row, so this must be checked against the
                // shadow or the conflict would surface only at apply time, after
                // the WAL is durable, and break recovery on replay.
                const pk: value.Value = if (table.pk_index) |pki| ins.values[pki] else .null;
                if (shadowUniqueViolation(shadow, ins.table, pk, ins.values, table)) return error.UniqueViolation;
            },
            .update => |upd| {
                const table = self.tables.getPtr(upd.table) orelse return error.PrimaryKeyNotFound;
                // If the target was inserted earlier in this same write set, it
                // is not yet live; validate against the shadow row instead.
                if (findShadowRow(shadow, upd.table, upd.pk) != null) {
                    table.validateTypes(upd.values) catch |err| return mapCoordError(err);
                    return;
                }
                if (table.pk_index != null) {
                    table.validateUpdate(upd.pk, upd.values) catch |err| return mapCoordError(err);
                } else {
                    const idx: usize = switch (upd.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    if (idx >= table.rows.items.len) return error.PrimaryKeyNotFound;
                    table.validateUpdateAt(idx, upd.values) catch |err| return mapCoordError(err);
                }
                // Same-round secondary unique conflicts for updates: the live
                // table is validated above, but an earlier accepted request in
                // this round may hold the unique value without it being live.
                if (shadowUniqueViolation(shadow, upd.table, upd.pk, upd.values, table)) return error.UniqueViolation;
            },
            .delete => |del| {
                const table = self.tables.getPtr(del.table) orelse return error.PrimaryKeyNotFound;
                if (findShadowRow(shadow, del.table, del.pk) != null) return;
                if (table.pk_index != null) {
                    if (!table.pkContains(del.pk)) return error.PrimaryKeyNotFound;
                } else {
                    const idx: usize = switch (del.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    if (idx >= table.rows.items.len) return error.PrimaryKeyNotFound;
                }
            },
        }
    }

    fn registerTable(self: *Engine, name: []const u8, cols: []const wal_mod.RecordView.ParsedColumn) !void {
        if (self.tables.contains(name)) return error.TableExists;

        var specs: std.ArrayList(ColumnSpec) = .empty;
        defer specs.deinit(self.gpa);
        try specs.ensureTotalCapacity(self.gpa, cols.len);
        for (cols) |c| {
            specs.appendAssumeCapacity(.{
                .name = c.name,
                .type_tag = c.type_tag,
                .primary_key = c.primary_key,
                .not_null = c.not_null,
                .unique = c.unique,
                .serial = c.serial,
                .default_expr = c.default_expr,
            });
        }

        var table = try Table.create(self.gpa, name, specs.items);
        errdefer table.deinit(self.gpa);
        try self.tables.put(table.name, table);
    }

    pub fn createTable(self: *Engine, name: []const u8, columns: []const value.Column) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        return self.createTableLocked(name, columns);
    }

    fn createTableLocked(self: *Engine, name: []const u8, columns: []const value.Column) !void {
        if (self.tables.contains(name) or self.documents.contains(name)) return error.TableExists;

        var specs: std.ArrayList(ColumnSpec) = .empty;
        defer specs.deinit(self.gpa);
        try specs.ensureTotalCapacity(self.gpa, columns.len);
        for (columns) |c| {
            specs.appendAssumeCapacity(.{
                .name = c.name,
                .type_tag = c.type_tag,
                .primary_key = c.primary_key,
                .not_null = c.not_null,
                .unique = c.unique,
                .serial = c.serial,
                .default_expr = c.default_expr,
            });
        }
        // Schema check before WAL (Table.create would also check; fail closed early).
        try Table.validateSchema(specs.items);

        try self.wal.appendCreateTable(.{ .name = name, .columns = columns });

        var table = try Table.create(self.gpa, name, specs.items);
        errdefer table.deinit(self.gpa);
        try self.tables.put(table.name, table);
    }

    pub fn createTableIfNotExists(self: *Engine, name: []const u8, columns: []const value.Column) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        if (self.tables.contains(name)) return;
        try self.createTableLocked(name, columns);
    }

    // ── Document collections (roadmap Phase 2) ──

    /// Create an empty document collection. The name is exclusive with tables;
    /// the WAL record makes the collection durable before it is registered.
    pub fn createDocument(self: *Engine, name: []const u8) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        try self.createDocumentLocked(name);
    }

    fn createDocumentLocked(self: *Engine, name: []const u8) !void {
        if (self.documents.contains(name) or self.tables.contains(name)) return error.TableExists;

        try self.wal.appendCreateDocument(.{ .name = name });

        var collection = try document_mod.Collection.create(self.gpa, name);
        errdefer collection.deinit();
        try self.documents.put(collection.name, collection);
    }

    /// Insert a document into a collection, rejecting a duplicate id. The
    /// caller owns `fields`; the collection clones them. The document slice's
    /// ingest is self-contained: inserting into a nonexistent collection
    /// creates it (mirroring `observe`), and a table with the same name is
    /// rejected.
    pub fn insertDocument(self: *Engine, collection_name: []const u8, id: []const u8, fields: []const document_mod.Field) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);

        // Validate before touching state or the WAL so a rejected insert leaves
        // no record and creates no collection.
        if (id.len == 0) return error.MissingDocumentId;
        for (fields) |*field| if (field.path.len == 0) return error.EmptyFieldPath;

        if (self.documents.getPtr(collection_name) == null) {
            try self.createDocumentLocked(collection_name);
        }
        const collection = self.documents.getPtr(collection_name) orelse return error.TableNotFound;

        // Reject a duplicate id before touching the WAL so a rejected insert
        // leaves no record, mirroring the relation slice's pre-validation.
        if (collection.contains(id)) return error.DuplicateDocumentId;

        const records = try self.gpa.alloc(wal_mod.DocumentFieldRecord, fields.len);
        defer self.gpa.free(records);
        for (fields, 0..) |*field, index| {
            records[index] = .{ .path = field.path, .item = field.item };
        }
        try self.wal.appendInsertDocument(.{ .collection = collection_name, .id = id, .fields = records });

        try collection.insert(id, fields);
    }

    /// Look up a document collection, or null when no collection or table with
    /// that name exists. Used by the semantic binding to route Flow requests.
    pub fn getDocumentCollection(self: *Engine, name: []const u8) ?*document_mod.Collection {
        return self.documents.getPtr(name);
    }

    // ── Graph collections (roadmap Phase 2) ──

    /// Create an empty graph. The name is exclusive with tables and document
    /// collections.
    pub fn createGraph(self: *Engine, name: []const u8) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        try self.createGraphLocked(name);
    }

    fn createGraphLocked(self: *Engine, name: []const u8) !void {
        if (self.graphs.contains(name) or self.tables.contains(name) or self.documents.contains(name)) return error.TableExists;

        try self.wal.appendCreateGraph(.{ .name = name });

        var graph = try graph_mod.Graph.create(self.gpa, name);
        errdefer graph.deinit();
        try self.graphs.put(graph.name, graph);
    }

    /// Add a node, creating the graph on its first node (mirroring the document
    /// slice's self-contained ingest).
    pub fn addNode(self: *Engine, graph_name: []const u8, id: []const u8, fields: []const document_mod.Field) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        if (id.len == 0) return error.MissingDocumentId;
        for (fields) |*field| if (field.path.len == 0) return error.EmptyFieldPath;

        if (self.graphs.getPtr(graph_name) == null) {
            try self.createGraphLocked(graph_name);
        }
        const graph = self.graphs.getPtr(graph_name) orelse return error.TableNotFound;
        if (graph.containsNode(id)) return error.DuplicateDocumentId;

        const records = try self.gpa.alloc(wal_mod.DocumentFieldRecord, fields.len);
        defer self.gpa.free(records);
        for (fields, 0..) |*field, index| records[index] = .{ .path = field.path, .item = field.item };
        try self.wal.appendAddNode(.{ .graph = graph_name, .id = id, .fields = records });
        try graph.addNode(id, fields);
    }

    /// Add a directed labeled edge between two existing nodes.
    pub fn addEdge(self: *Engine, graph_name: []const u8, from: []const u8, label: []const u8, to: []const u8) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const graph = self.graphs.getPtr(graph_name) orelse return error.TableNotFound;
        if (!graph.containsNode(from) or !graph.containsNode(to)) return error.UnknownNode;
        try self.wal.appendAddEdge(.{ .graph = graph_name, .from = from, .label = label, .to = to });
        try graph.addEdge(from, label, to);
    }

    /// Look up a graph, or null when no graph with that name exists.
    pub fn getGraph(self: *Engine, name: []const u8) ?*graph_mod.Graph {
        return self.graphs.getPtr(name);
    }

    /// Rank non-null embeddings in one table column. The caller owns the query
    /// embedding and must free the returned candidate slice.
    pub fn searchVectors(
        self: *Engine,
        table_name: []const u8,
        column_name: []const u8,
        query: vector_mod.Embedding,
        metric: vector_mod.Metric,
        limit: usize,
    ) (VectorSearchError || table_mod.Error)![]vector_mod.Candidate {
        const table = self.getTable(table_name) orelse return error.TableNotFound;
        const column_index = table.columnIndex(column_name) orelse return error.ColumnNotFound;
        if (table.columns[column_index].type_tag != .vector) return error.VectorColumnRequired;

        var entries: std.ArrayList(vector_mod.Entry) = .empty;
        defer entries.deinit(self.gpa);
        try entries.ensureTotalCapacity(self.gpa, table.rows.items.len);
        for (table.rows.items, 0..) |row, row_index| switch (row.values[column_index]) {
            .null => {},
            .vector => |embedding| entries.appendAssumeCapacity(.{ .row_index = row_index, .embedding = embedding }),
            else => unreachable,
        };
        return vector_mod.topK(self.gpa, entries.items, query, metric, limit);
    }

    pub fn addColumn(self: *Engine, table_name: []const u8, column: value.Column, if_not_exists: bool) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (table.columnIndex(column.name) != null) {
            if (if_not_exists) return;
            return error.ColumnExists;
        }
        var existing = try existingColumnValue(self.gpa, column.default_expr);
        defer existing.deinit(self.gpa);
        if (column.not_null and existing == .null and table.rows.items.len != 0) return error.NotNullViolation;
        try self.wal.appendAddColumn(.{ .table = table_name, .column = column });
        try table.addColumn(self.gpa, column, existing);
    }

    pub fn dropColumn(self: *Engine, table_name: []const u8, name: []const u8, if_exists: bool) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (table.columnIndex(name) == null) {
            if (if_exists) return;
            return error.ColumnNotFound;
        }
        if (table.pk_index != null and table.pk_index.? == table.columnIndex(name).?) return error.CannotDropPrimaryKey;
        try self.wal.appendDropColumn(.{ .table = table_name, .column = name });
        try table.dropColumn(self.gpa, name);
    }

    pub fn setDefault(self: *Engine, table_name: []const u8, name: []const u8, default_expr: value.DefaultExpr) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        _ = table.columnIndex(name) orelse return error.ColumnNotFound;
        try self.wal.appendSetDefault(.{ .table = table_name, .column = name, .default_expr = default_expr });
        try table.setDefault(self.gpa, name, default_expr);
    }

    pub fn setNotNull(self: *Engine, table_name: []const u8, name: []const u8, enabled: bool) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        _ = table.columnIndex(name) orelse return error.ColumnNotFound;
        if (enabled) for (table.rows.items) |row| {
            const idx = table.columnIndex(name).?;
            if (row.values[idx] == .null) return error.NotNullViolation;
        };
        try self.wal.appendSetNotNull(.{ .table = table_name, .column = name, .enabled = enabled });
        try table.setNotNull(name, enabled);
    }

    /// Autocommit insert: one statement, one commit, routed through the
    /// single-writer coordinator.
    pub fn insert(self: *Engine, table_name: []const u8, values: []const value.Value) !void {
        var tx = txn_mod.Transaction.begin(self.gpa, self.coordinator.snapshot());
        defer tx.deinit();
        try self.stageInsert(&tx, table_name, values);
        try self.commitTransaction(&tx);
    }

    /// Autocommit update by primary key.
    pub fn update(self: *Engine, table_name: []const u8, pk: value.Value, values: []const value.Value) !void {
        var tx = txn_mod.Transaction.begin(self.gpa, self.coordinator.snapshot());
        defer tx.deinit();
        try self.stageUpdate(&tx, table_name, pk, values);
        try self.commitTransaction(&tx);
    }

    /// Autocommit delete by primary key.
    pub fn delete(self: *Engine, table_name: []const u8, pk: value.Value) !void {
        var tx = txn_mod.Transaction.begin(self.gpa, self.coordinator.snapshot());
        defer tx.deinit();
        try self.stageDelete(&tx, table_name, pk);
        try self.commitTransaction(&tx);
    }

    // ── Explicit transaction API ──

    /// Begin an explicit transaction at the current published watermark.
    pub fn beginTransaction(self: *Engine) txn_mod.Transaction {
        return txn_mod.Transaction.begin(self.gpa, self.coordinator.snapshot());
    }

    /// Stage an insert into `tx`, validating against the live table and the
    /// transaction's own earlier writes (read-your-writes).
    pub fn stageInsert(self: *Engine, tx: *txn_mod.Transaction, table_name: []const u8, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try table.validateInsert(values);
        // A transaction must not insert the same primary key twice. The live
        // table does not yet contain this row, so check the private write set.
        const pk: value.Value = if (table.pk_index) |pki| values[pki] else .null;
        if (pk != .null) {
            if (self.findStagedOp(tx, table_name, pk)) |staged| {
                if (staged.op == .insert) return error.DuplicatePrimaryKey;
            }
        }
        try tx.stageInsert(table_name, pk, values);
    }

    /// Find a staged write-set entry for `(table_name, pk)`.
    fn findStagedOp(self: *Engine, tx: *txn_mod.Transaction, table_name: []const u8, pk: value.Value) ?*txn_mod.WriteOp {
        _ = self;
        for (tx.write_set.items) |*op| {
            if (std.mem.eql(u8, op.table, table_name) and op.pk.eql(pk)) return op;
        }
        return null;
    }

    /// Stage an update into `tx`. Captures the observed row version so the
    /// coordinator can reject a lost update. When the target is already owned
    /// by this transaction's write set (a prior insert or update), no external
    /// version exists yet: `null` makes the coordinator validate against the
    /// private shadow, so update-after-insert and update-after-update succeed.
    pub fn stageUpdate(self: *Engine, tx: *txn_mod.Transaction, table_name: []const u8, pk: value.Value, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (self.findStagedOp(tx, table_name, pk)) |staged| {
            if (staged.op == .delete) return error.PrimaryKeyNotFound;
            try table.validateTypes(values);
            try tx.stageUpdate(table_name, pk, values, null);
            return;
        }
        const observed = table.rowVersion(pk) orelse return error.PrimaryKeyNotFound;
        try table.validateUpdate(pk, values);
        try tx.stageUpdate(table_name, pk, values, observed);
    }

    /// Stage a delete into `tx`. Captures the observed row version. A target
    /// owned by this transaction's write set is staged with `null` so the
    /// coordinator validates it against the private shadow rather than the
    /// published row version.
    pub fn stageDelete(self: *Engine, tx: *txn_mod.Transaction, table_name: []const u8, pk: value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (self.findStagedOp(tx, table_name, pk)) |staged| {
            if (staged.op == .delete) return error.PrimaryKeyNotFound;
            try tx.stageDelete(table_name, pk, null);
            return;
        }
        const observed = table.rowVersion(pk) orelse return error.PrimaryKeyNotFound;
        try tx.stageDelete(table_name, pk, observed);
    }

    /// Commit a staged transaction through the coordinator.
    pub fn commitTransaction(self: *Engine, tx: *txn_mod.Transaction) !void {
        if (!tx.isActive()) return error.InvalidState;
        const observed = try self.gpa.alloc(?u64, tx.write_set.items.len);
        for (tx.write_set.items, 0..) |op, i| observed[i] = op.observed_version;
        const ops = tx.toWalOps() catch {
            self.gpa.free(observed);
            return error.OutOfMemory;
        };

        var request = commit_mod.Request{
            .gpa = self.gpa,
            .ops = ops,
            .observed = observed,
            .read_seq = tx.snapshot_seq,
        };
        var transferred = false;
        defer if (!transferred) request.deinit();

        try self.coordinator.submit(self, &request);
        try self.coordinator.drain(self);
        transferred = true;
        const result = request.result;
        request.deinit();
        if (result) |err| {
            // A commit that reaches the coordinator and fails — conflict,
            // duplicate key, uniqueness, WAL append, or cancellation — leaves
            // the transaction `failed`, not `idle`: the write set is gone but
            // the connection must not silently continue as if it had committed.
            // A failed transaction rejects every operation except rollback.
            tx.state = .failed;
            return err;
        }
    }

    /// Rollback discards the transaction's private write set.
    pub fn rollbackTransaction(self: *Engine, tx: *txn_mod.Transaction) !void {
        _ = self;
        try tx.rollback();
    }

    /// Update by current row index; resolves to a primary key when present and
    /// routes through the commit coordinator so the watermark advances. Tables
    /// without a single-column primary key use a legacy index-addressed WAL
    /// path (unused by the current public API).
    pub fn updateAt(self: *Engine, table_name: []const u8, idx: usize, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (idx >= table.rows.items.len) return error.PrimaryKeyNotFound;
        if (table.pk_index) |pki| {
            const pk = table.rows.items[idx].values[pki];
            return self.update(table_name, pk, values);
        }
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        try table.validateUpdateAt(idx, values);
        try self.wal.appendUpdate(.{ .table = table_name, .pk = .{ .int = @intCast(idx) }, .values = values });
        // Legacy index-addressed path: no coordinator commit sequence, so the
        // version is stamped with the current published watermark, matching
        // what recovery would rebuild when it replays this plain record.
        try table.updateAt(self.gpa, idx, values, self.publishedSeq());
    }

    pub fn deleteAt(self: *Engine, table_name: []const u8, idx: usize) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (idx >= table.rows.items.len) return error.PrimaryKeyNotFound;
        if (table.pk_index) |pki| {
            const pk = table.rows.items[idx].values[pki];
            return self.delete(table_name, pk);
        }
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        try self.wal.appendDelete(.{ .table = table_name, .pk = .{ .int = @intCast(idx) } });
        try table.deleteAt(self.gpa, idx, self.publishedSeq());
    }

    /// Reserve one instance-wide staging slot and expected-byte budget for a
    /// bounded attachment. The connection holds the reservation until
    /// `finishStage` or `abortStage`. A rejected reservation creates no visible
    /// evidence and no WAL record.
    pub fn beginStage(self: *Engine, expected_length: u64) error{StagingQuotaExceeded}!void {
        if (self.staging_active >= self.evidence_limits.max_concurrent_staging) {
            self.evidence_stats.staging_rejections += 1;
            return error.StagingQuotaExceeded;
        }
        const total = std.math.add(u64, self.staging_active_bytes, expected_length) catch {
            self.evidence_stats.staging_rejections += 1;
            return error.StagingQuotaExceeded;
        };
        if (total > self.evidence_limits.max_staged_bytes) {
            self.evidence_stats.staging_rejections += 1;
            return error.StagingQuotaExceeded;
        }
        self.staging_active += 1;
        self.staging_active_bytes = total;
        self.evidence_stats.staged_uploads += 1;
        self.evidence_stats.staged_upload_bytes +|= expected_length;
    }

    /// Release a staging reservation after the upload completed. The attached
    /// evidence is committed later by `observe`.
    pub fn finishStage(self: *Engine, expected_length: u64) void {
        self.releaseStage(expected_length);
    }

    /// Release a staging reservation after the upload was aborted or dropped.
    pub fn abortStage(self: *Engine, expected_length: u64) void {
        self.releaseStage(expected_length);
        self.evidence_stats.aborted_uploads += 1;
    }

    fn releaseStage(self: *Engine, expected_length: u64) void {
        std.debug.assert(self.staging_active > 0);
        std.debug.assert(self.staging_active_bytes >= expected_length);
        self.staging_active -= 1;
        self.staging_active_bytes -= expected_length;
    }

    /// Publish immutable Observation Evidence through payload-file then WAL
    /// ordering. A failed WAL append leaves a reclaimable orphan file. Enforces
    /// the retained-byte quota and records acceptance/rejection metrics.
    pub fn observe(self: *Engine, object_id: []const u8, modality: evidence_mod.Modality, media_type: []const u8, observed_at: []const u8, origin: []const u8, owner: []const u8, payload: []const u8) !u64 {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        if (payload.len > evidence_mod.MAX_PAYLOAD_LENGTH) {
            recordRejection(self, .payload_too_large);
            return error.PayloadTooLarge;
        }
        if (self.evidence_stats.committed_bytes + payload.len > self.evidence_limits.max_retained_bytes) {
            recordRejection(self, .retained_quota);
            return error.RetainedQuotaExceeded;
        }
        const id = self.next_evidence_id;
        const payload_digest = evidence_mod.digest(payload);
        const metadata: evidence_mod.Metadata = .{
            .evidence_id = id,
            .object_id = object_id,
            .modality = modality,
            .media_type = media_type,
            .observed_at = observed_at,
            .origin = origin,
            .owner = owner,
            .payload_length = payload.len,
            .payload_digest = payload_digest,
        };
        evidence_mod.validateMetadata(metadata) catch |err| {
            recordRejection(self, if (err == error.PayloadTooLarge) .payload_too_large else .invalid_metadata);
            return err;
        };
        var record = try evidence_mod.Record.clone(self.gpa, metadata);
        errdefer record.deinit(self.gpa);
        try self.observations.ensureUnusedCapacity(self.gpa, 1);
        const timer_start = Io.Clock.Timestamp.now(self.io, .awake);
        const stored_digest = self.payloads.publish(id, payload) catch |err| {
            recordRejection(self, if (err == error.PayloadTooLarge) .payload_too_large else .storage_failure);
            return err;
        };
        const payload_latency = timer_start.untilNow(self.io);
        self.evidence_stats.payload_write_ns +|= @intCast(payload_latency.raw.nanoseconds);
        self.evidence_stats.payload_write_count += 1;
        if (!std.mem.eql(u8, &stored_digest, &payload_digest)) {
            recordRejection(self, .corrupt_payload);
            return error.CorruptPayload;
        }
        self.wal.appendObserve(metadata) catch |err| {
            recordRejection(self, .storage_failure);
            return err;
        };
        self.observations.appendAssumeCapacity(record);
        self.next_evidence_id = id + 1;
        self.evidence_stats.accepted_by_modality[modalityIndex(modality)] += 1;
        self.evidence_stats.committed_count += 1;
        self.evidence_stats.committed_bytes += payload.len;
        return id;
    }

    pub fn readEvidencePayload(self: *Engine, evidence_id: u64) ![]u8 {
        for (self.observations.items) |record| {
            if (record.evidence_id == evidence_id) {
                return self.payloads.read(self.gpa, evidence_id, record.payload_length, record.payload_digest) catch |err| {
                    self.evidence_stats.payload_failures += 1;
                    return err;
                };
            }
        }
        return error.EvidenceNotFound;
    }

    pub fn observationsView(self: *Engine) []const evidence_mod.Record {
        return self.observations.items;
    }

    pub fn evidenceStats(self: *const Engine) EvidenceStats {
        return self.evidence_stats;
    }

    pub const SelectResult = struct {
        columns: []const value.Column,
        rows: []const Row,
        owned_rows: ?[]Row,
        gpa: Allocator,

        pub fn deinit(self: *SelectResult) void {
            if (self.owned_rows) |rows| {
                for (rows) |*r| r.deinit(self.gpa);
                self.gpa.free(rows);
            }
        }
    };

    /// Read Committed scan at snapshot watermark `s`: every version visible at
    /// `s`, cloned into an owned result. Registers `s` with the snapshot
    /// registry for the duration of the read so reclamation cannot free a
    /// version the result still references (success, error, and limit paths all
    /// deregister through the defer).
    pub fn selectAll(self: *Engine, table_name: []const u8, snapshot_seq: u64) !SelectResult {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        self.snapshot_registry.register(snapshot_seq) catch return error.SnapshotLimitExceeded;
        defer self.snapshot_registry.unregister(snapshot_seq);
        const rows = try table.rowsVisibleAt(self.gpa, snapshot_seq);
        return .{ .columns = table.columns, .rows = rows, .owned_rows = rows, .gpa = self.gpa };
    }

    /// Read Committed point read at snapshot watermark `s`: the version of `pk`
    /// visible at `s`, or no row. Registers `s` around the read.
    pub fn selectByPk(self: *Engine, table_name: []const u8, pk: value.Value, snapshot_seq: u64) !SelectResult {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        self.snapshot_registry.register(snapshot_seq) catch return error.SnapshotLimitExceeded;
        defer self.snapshot_registry.unregister(snapshot_seq);
        if (try table.rowVisibleAt(self.gpa, pk, snapshot_seq)) |row| {
            var owned = row;
            errdefer owned.deinit(self.gpa);
            const one = try self.gpa.alloc(Row, 1);
            one[0] = owned;
            return .{ .columns = table.columns, .rows = one, .owned_rows = one, .gpa = self.gpa };
        }
        return emptyResult(self.gpa, table.columns);
    }

    /// Read Committed scan through `tx`'s private write set: committed rows the
    /// transaction has not touched are cloned unchanged, rows it staged as
    /// update or insert appear with the write-set values, and rows it staged as
    /// delete are invisible. Other connections' uncommitted writes never enter
    /// this result: the live tables hold only published commits, and the private
    /// write set is merged only for the owning transaction. This is the engine
    /// boundary that makes explicit-transaction reads read-your-writes while
    /// every other reader sees only committed state.
    pub fn selectAllTx(self: *Engine, tx: *txn_mod.Transaction, table_name: []const u8, snapshot_seq: u64) !SelectResult {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const gpa = self.gpa;
        self.snapshot_registry.register(snapshot_seq) catch return error.SnapshotLimitExceeded;
        defer self.snapshot_registry.unregister(snapshot_seq);

        // Committed rows visible at the snapshot watermark (live rows created at
        // or before it, plus retained versions visible at it), cloned by the
        // table.
        const committed = try table.rowsVisibleAt(gpa, snapshot_seq);
        defer {
            for (committed) |*row| row.deinit(gpa);
            gpa.free(committed);
        }

        var merged: std.ArrayList(Row) = .empty;
        errdefer {
            for (merged.items) |*row| row.deinit(gpa);
            merged.deinit(gpa);
        }

        // Merge the transaction's private write set over the committed snapshot
        // (read-your-writes): a staged insert/update substitutes its values and
        // a staged delete hides the row.
        const pk_index = table.pk_index;
        for (committed) |*row| {
            const staged = if (pk_index) |pki| tx.lastStaged(table_name, row.values[pki]) else null;
            if (staged) |op| switch (op.op) {
                .delete => continue,
                .insert, .update => {
                    try merged.ensureUnusedCapacity(gpa, 1);
                    merged.appendAssumeCapacity(try rowFromValues(gpa, op.values));
                    continue;
                },
            };
            try merged.ensureUnusedCapacity(gpa, 1);
            merged.appendAssumeCapacity(try row.clone(gpa));
        }

        // Private rows that do not exist in the committed snapshot append new
        // rows. Only the last write-set entry for a key is effective: an
        // earlier insert is superseded by its own later update/delete. The
        // visibility check is at the snapshot, not the live state, so a key a
        // peer inserted after `snapshot_seq` still reads as this transaction's
        // insert.
        if (pk_index) |_| {
            for (tx.write_set.items) |*op| {
                if (op.op == .delete or !std.mem.eql(u8, op.table, table_name)) continue;
                const effective = tx.lastStaged(table_name, op.pk) orelse continue;
                if (effective != op) continue;
                if (table.pkVisibleAt(op.pk, snapshot_seq)) continue;
                try merged.ensureUnusedCapacity(gpa, 1);
                merged.appendAssumeCapacity(try rowFromValues(gpa, op.values));
            }
        } else {
            // Heap table (no single-column primary key): staged updates and
            // deletes cannot be addressed, so committed rows are unchanged and
            // every staged insert appends a new row.
            for (tx.write_set.items) |op| {
                if (op.op == .insert and std.mem.eql(u8, op.table, table_name)) {
                    try merged.ensureUnusedCapacity(gpa, 1);
                    merged.appendAssumeCapacity(try rowFromValues(gpa, op.values));
                }
            }
        }

        const rows = try merged.toOwnedSlice(gpa);
        return .{ .columns = table.columns, .rows = rows, .owned_rows = rows, .gpa = gpa };
    }

    /// Read Committed point read through `tx`: a staged insert or update for
    /// `pk` returns the write-set values, a staged delete returns no row, and
    /// otherwise the committed row is returned. Tables without a single-column
    /// primary key fall back to the committed point read because their write
    /// set cannot address rows by key.
    pub fn selectByPkTx(self: *Engine, tx: *txn_mod.Transaction, table_name: []const u8, pk: value.Value, snapshot_seq: u64) !SelectResult {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (table.pk_index == null) return self.selectByPk(table_name, pk, snapshot_seq);
        if (tx.lastStaged(table_name, pk)) |op| {
            switch (op.op) {
                .delete => return emptyResult(self.gpa, table.columns),
                .insert, .update => {
                    const one = try self.gpa.alloc(Row, 1);
                    errdefer self.gpa.free(one);
                    one[0] = try rowFromValues(self.gpa, op.values);
                    return .{ .columns = table.columns, .rows = one, .owned_rows = one, .gpa = self.gpa };
                },
            }
        }
        return self.selectByPk(table_name, pk, snapshot_seq);
    }

    /// Collect row indices matching all predicates (AND). Caller owns the slice.
    pub fn matchIndices(self: *Engine, table: *Table, preds: []const Pred) ![]usize {
        return table.matchIndices(self.gpa, preds);
    }

    pub fn getTable(self: *Engine, name: []const u8) ?*Table {
        return self.tables.getPtr(name);
    }

    pub fn allocSerial(self: *Engine, table_name: []const u8) !i64 {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);

        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        return table.allocSerial();
    }

    /// Compact the WAL down to the records that reconstruct current committed
    /// state, bounding both WAL size and recovery time.
    ///
    /// Holds `writer_mutex` for the whole rewrite: the emitted snapshot must
    /// correspond to exactly the set of WAL frames being discarded. A mutation
    /// interleaved between reading a table and publishing the new WAL would have
    /// its frame discarded without appearing in the snapshot, losing a commit.
    pub fn checkpoint(self: *Engine) !checkpoint_mod.Stats {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);

        const watermark = self.publishedSeq();

        // PK-addressable tables are materialized into L0 SSTables; the LSM
        // manifest becomes the durable home of their schema, serial counter,
        // and rows. Heap tables (no single-column primary key) cannot be
        // addressed by key and stay in the rewritten WAL.
        var heap_refs: std.ArrayList(*const Table) = .empty;
        defer heap_refs.deinit(self.gpa);
        try heap_refs.ensureTotalCapacity(self.gpa, self.tables.count());
        var flushed_tables: usize = 0;
        var flushed_rows: usize = 0;
        var table_it = self.tables.iterator();
        while (table_it.next()) |entry| {
            const table = entry.value_ptr;
            if (table.pk_index) |pk_index| {
                const flush_stats = try self.lsm.flushTable(self.gpa, table.name, table.columns, pk_index, table.next_serial, table.rows.items, watermark);
                flushed_tables += 1;
                flushed_rows += @intCast(flush_stats.entries);
            } else {
                heap_refs.appendAssumeCapacity(table);
            }
        }
        // Publish the LSM version set before rewriting the WAL so a crash
        // between the two leaves SSTables that the (still complete) WAL tail
        // replays on top of without duplication.
        try self.lsm.publishManifest(self.gpa);

        var doc_refs: std.ArrayList(*const document_mod.Collection) = .empty;
        defer doc_refs.deinit(self.gpa);
        try doc_refs.ensureTotalCapacity(self.gpa, self.documents.count());
        var doc_it = self.documents.iterator();
        while (doc_it.next()) |entry| doc_refs.appendAssumeCapacity(entry.value_ptr);

        var graph_refs: std.ArrayList(*const graph_mod.Graph) = .empty;
        defer graph_refs.deinit(self.gpa);
        try graph_refs.ensureTotalCapacity(self.gpa, self.graphs.count());
        var graph_it = self.graphs.iterator();
        while (graph_it.next()) |entry| graph_refs.appendAssumeCapacity(entry.value_ptr);

        var stats = try checkpoint_mod.run(&self.wal, heap_refs.items, doc_refs.items, graph_refs.items, self.observations.items, watermark);
        // Reported counts cover the whole checkpoint: tables flushed to SSTables
        // plus heap tables rewritten into the WAL.
        stats.tables += flushed_tables;
        stats.rows += flushed_rows;

        // Publish the durable manifest boundary only after the WAL rewrite has
        // committed, so the manifest always describes state the rewritten WAL
        // reconstructs. The catalog objects are borrowed for the synchronous
        // encode inside publish.
        var objects: std.ArrayList(manifest_mod.CatalogObject) = .empty;
        defer objects.deinit(self.gpa);
        try objects.ensureTotalCapacity(self.gpa, self.tables.count() + self.documents.count() + self.graphs.count());
        var table_it2 = self.tables.iterator();
        while (table_it2.next()) |entry| objects.appendAssumeCapacity(.{ .kind = .table, .name = entry.key_ptr.* });
        var doc_it2 = self.documents.iterator();
        while (doc_it2.next()) |entry| objects.appendAssumeCapacity(.{ .kind = .document, .name = entry.key_ptr.* });
        var graph_it2 = self.graphs.iterator();
        while (graph_it2.next()) |entry| objects.appendAssumeCapacity(.{ .kind = .graph, .name = entry.key_ptr.* });
        const manifest = manifest_mod.Manifest{ .commit_seq = self.publishedSeq(), .objects = objects.items };
        try manifest_mod.publish(&self.wal.vfs, self.gpa, &manifest);
        return stats;
    }

    /// Flush one table into an L0 SSTable and publish the LSM manifest (the
    /// manual FLUSH analog). The WAL keeps its frames; recovery skips batches
    /// at or below the new watermark because their state is in the SSTable.
    pub fn flush(self: *Engine, table_name: []const u8) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const pk_index = table.pk_index orelse return error.PrimaryKeyNotFound;
        _ = try self.lsm.flushTable(self.gpa, table.name, table.columns, pk_index, table.next_serial, table.rows.items, self.publishedSeq());
        try self.lsm.publishManifest(self.gpa);
    }

    /// Compact one table's L0 files (with overlapping L1 files) into L1.
    pub fn compact(self: *Engine, table_name: []const u8) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        _ = try self.lsm.compactTable(self.gpa, table_name);
    }

    /// Instance-wide LSM observability counters.
    pub fn lsmStats(self: *const Engine) lsm_store.Stats {
        return self.lsm.stats;
    }
};

fn existingColumnValue(gpa: Allocator, default_expr: value.DefaultExpr) !value.Value {
    return switch (default_expr) {
        .none, .now => .null,
        .literal => |v| try v.clone(gpa),
    };
}

/// Build an owned `Row` by cloning `values`. Used by the transaction-aware read
/// path so a result never aliases the private write set or a live table row.
fn rowFromValues(gpa: Allocator, values: []const value.Value) !Row {
    const owned = try gpa.alloc(value.Value, values.len);
    errdefer gpa.free(owned);
    var cloned: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < cloned) : (index += 1) owned[index].deinit(gpa);
    }
    while (cloned < values.len) : (cloned += 1) owned[cloned] = try values[cloned].clone(gpa);
    return .{ .values = owned };
}

fn emptyResult(gpa: Allocator, columns: []const value.Column) !Engine.SelectResult {
    const empty = try gpa.alloc(Row, 0);
    return .{ .columns = columns, .rows = empty, .owned_rows = empty, .gpa = gpa };
}

fn recordRejection(self: *Engine, reason: RejectReason) void {
    self.evidence_stats.rejected_evidence += 1;
    self.evidence_stats.rejected_by_reason[@intFromEnum(reason)] += 1;
}

/// Dense 0-based index into `accepted_by_modality` for `modality`.
fn modalityIndex(modality: evidence_mod.Modality) usize {
    for (std.enums.values(evidence_mod.Modality), 0..) |modality_value, index| {
        if (modality_value == modality) return index;
    }
    unreachable;
}

fn findShadowRow(shadow: []const commit_mod.ShadowEntry, table: []const u8, pk: value.Value) ?*const commit_mod.ShadowEntry {
    for (shadow) |*entry| {
        if (std.mem.eql(u8, entry.table, table) and entry.pk.eql(pk)) return entry;
    }
    return null;
}

/// Reject a secondary unique-column value already held by an earlier accepted
/// request in the same round. `pk` is the target row's primary key (or null);
/// shadow entries for that same row are the transaction's own prior writes and
/// must not conflict with themselves.
fn shadowUniqueViolation(
    shadow: []const commit_mod.ShadowEntry,
    table_name: []const u8,
    pk: value.Value,
    values: []const value.Value,
    table: *const Table,
) bool {
    for (table.columns, 0..) |col, ci| {
        // A single-column primary key is checked through `by_pk_*`; rechecking
        // it here would make each insert O(round size).
        if (!col.unique or (table.pk_index != null and ci == table.pk_index.?)) continue;
        const v = values[ci];
        if (v == .null) continue;
        for (shadow) |*entry| {
            if (!entry.present or !std.mem.eql(u8, entry.table, table_name)) continue;
            if (pk != .null and entry.pk.eql(pk)) continue;
            if (ci >= entry.values.len) continue;
            if (value.Value.eql(entry.values[ci], v)) return true;
        }
    }
    return false;
}

fn mapCoordError(err: table_mod.Error) commit_mod.CoordError {
    return switch (err) {
        error.DuplicatePrimaryKey => error.DuplicatePrimaryKey,
        error.UniqueViolation => error.UniqueViolation,
        error.PrimaryKeyNotFound => error.PrimaryKeyNotFound,
        error.TableNotFound => error.PrimaryKeyNotFound,
        error.NotNullViolation => error.DuplicatePrimaryKey,
        error.TypeMismatch => error.DuplicatePrimaryKey,
        error.ColumnCountMismatch => error.DuplicatePrimaryKey,
        else => error.InvalidRequest,
    };
}

test "engine create insert select roundtrip with wal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = "zig-cache/runadb-test-engine";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();

        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
            .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text, .primary_key = false },
        };
        defer {
            for (&cols) |*c| c.deinit(gpa);
        }

        try eng.createTable("users", &cols);
        var name_val: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
        defer name_val.deinit(gpa);
        const vals = [_]value.Value{ .{ .int = 1 }, name_val };
        try eng.insert("users", &vals);

        var res = try eng.selectByPk("users", .{ .int = 1 }, eng.publishedSeq());
        defer res.deinit();
        try std.testing.expectEqual(@as(usize, 1), res.rows.len);
        try std.testing.expectEqualStrings("alice", res.rows[0].values[1].text);
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var res = try eng.selectAll("users", eng.publishedSeq());
        defer res.deinit();
        try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    }

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}

test "engine update delete with wal recovery" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-engine-ud";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();

        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
            .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text, .primary_key = false },
        };
        defer for (&cols) |*c| c.deinit(gpa);

        try eng.createTable("users", &cols);

        var a: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
        defer a.deinit(gpa);
        var b: value.Value = .{ .text = try gpa.dupe(u8, "bob") };
        defer b.deinit(gpa);
        var c: value.Value = .{ .text = try gpa.dupe(u8, "carol") };
        defer c.deinit(gpa);
        try eng.insert("users", &[_]value.Value{ .{ .int = 1 }, a });
        try eng.insert("users", &[_]value.Value{ .{ .int = 2 }, b });
        try eng.insert("users", &[_]value.Value{ .{ .int = 3 }, c });

        var bob2: value.Value = .{ .text = try gpa.dupe(u8, "bobby") };
        defer bob2.deinit(gpa);
        try eng.update("users", .{ .int = 2 }, &[_]value.Value{ .{ .int = 2 }, bob2 });
        try eng.delete("users", .{ .int = 1 });

        var res = try eng.selectByPk("users", .{ .int = 2 }, eng.publishedSeq());
        defer res.deinit();
        try std.testing.expectEqual(@as(usize, 1), res.rows.len);
        try std.testing.expectEqualStrings("bobby", res.rows[0].values[1].text);

        var all = try eng.selectAll("users", eng.publishedSeq());
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var all = try eng.selectAll("users", eng.publishedSeq());
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);

        var r2 = try eng.selectByPk("users", .{ .int = 2 }, eng.publishedSeq());
        defer r2.deinit();
        try std.testing.expectEqualStrings("bobby", r2.rows[0].values[1].text);

        var r1 = try eng.selectByPk("users", .{ .int = 1 }, eng.publishedSeq());
        defer r1.deinit();
        try std.testing.expectEqual(@as(usize, 0), r1.rows.len);
    }

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}

test "engine rejects invalid writes before they enter the wal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-engine-preflight";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();

        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
            .{ .name = try gpa.dupe(u8, "email"), .type_tag = .text, .unique = true },
        };
        defer for (&cols) |*col| col.deinit(gpa);

        try eng.createTable("users", &cols);
        try std.testing.expectError(error.TableExists, eng.createTable("users", &cols));
        var alice: value.Value = .{ .text = try gpa.dupe(u8, "alice@example.com") };
        defer alice.deinit(gpa);
        var bob: value.Value = .{ .text = try gpa.dupe(u8, "bob@example.com") };
        defer bob.deinit(gpa);
        try eng.insert("users", &.{ .{ .int = 1 }, alice });
        try eng.insert("users", &.{ .{ .int = 2 }, bob });
        try std.testing.expectError(
            error.DuplicatePrimaryKey,
            eng.insert("users", &.{ .{ .int = 1 }, bob }),
        );
        try std.testing.expectError(
            error.UniqueViolation,
            eng.update("users", .{ .int = 2 }, &.{ .{ .int = 2 }, alice }),
        );
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var rows = try eng.selectAll("users", eng.publishedSeq());
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
        try std.testing.expectEqualStrings("alice@example.com", rows.rows[0].values[1].text);
    }

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}

// Crash matrix slice: durable prefix of WAL frames survives; a torn final frame
// is dropped. Matches ARCHITECTURE.md recovery invariant for memtable+WAL phase.
test "checkpoint preserves rows, altered schema, and serial counter across restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-engine-ckpt";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var stats: checkpoint_mod.Stats = undefined;
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();

        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true, .serial = true },
            .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text },
        };
        defer for (&cols) |*c| c.deinit(gpa);
        try eng.createTable("users", &cols);

        var a: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
        defer a.deinit(gpa);
        try eng.insert("users", &.{ .{ .int = 1 }, a });
        try eng.insert("users", &.{ .{ .int = 2 }, a });
        try eng.insert("users", &.{ .{ .int = 9 }, a });
        // Delete the highest id so the live serial counter (10) is ahead of
        // max(pk) (2). Replaying inserts alone would rewind it.
        try eng.delete("users", .{ .int = 9 });

        // Schema history the checkpoint must collapse into one create_table.
        var extra: value.Column = .{ .name = try gpa.dupe(u8, "tier"), .type_tag = .int };
        defer extra.deinit(gpa);
        try eng.addColumn("users", extra, false);
        try eng.dropColumn("users", "name", false);

        stats = try eng.checkpoint();
        try std.testing.expectEqual(@as(usize, 1), stats.tables);
        try std.testing.expectEqual(@as(usize, 2), stats.rows);
        // The whole point: the rewritten WAL is smaller than the history it replaced.
        try std.testing.expect(stats.wal_bytes_after < stats.wal_bytes_before);
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();

        const table = eng.getTable("users").?;
        try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);
        // Post-ALTER schema, not the original.
        try std.testing.expectEqual(@as(usize, 2), table.columns.len);
        try std.testing.expectEqualStrings("id", table.columns[0].name);
        try std.testing.expectEqualStrings("tier", table.columns[1].name);
        // Serial did not rewind to max(pk)+1 == 3.
        try std.testing.expectEqual(@as(i64, 10), table.next_serial);
        // And a fresh allocation does not reuse a retired identifier.
        try std.testing.expectEqual(@as(i64, 10), try eng.allocSerial("users"));
    }
}

test "writes after a checkpoint survive restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-engine-ckpt-append";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();

        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        };
        defer for (&cols) |*c| c.deinit(gpa);
        try eng.createTable("t", &cols);
        try eng.insert("t", &.{.{ .int = 1 }});

        _ = try eng.checkpoint();

        // Appends must land at the rewritten file's offsets, not the old file's.
        try eng.insert("t", &.{.{ .int = 2 }});
        try eng.insert("t", &.{.{ .int = 3 }});
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var all = try eng.selectAll("t", eng.publishedSeq());
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 3), all.rows.len);
    }
}

// A checkpoint that fails before publication must leave the instance recoverable
// from the original WAL. Nothing is durably discarded until the atomic rename.
test "an aborted checkpoint leaves the original wal intact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-engine-ckpt-abort";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();

        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        };
        defer for (&cols) |*c| c.deinit(gpa);
        try eng.createTable("t", &cols);
        try eng.insert("t", &.{.{ .int = 1 }});
        try eng.insert("t", &.{.{ .int = 2 }});

        const before = eng.wal.offset;
        var rewrite = try eng.wal.beginRewrite();
        try rewrite.emitCreateTable(.{ .name = "t", .columns = eng.getTable("t").?.columns });
        rewrite.abort();
        // Live WAL untouched: same handle, same offset.
        try std.testing.expectEqual(before, eng.wal.offset);
        try eng.insert("t", &.{.{ .int = 3 }});
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var all = try eng.selectAll("t", eng.publishedSeq());
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 3), all.rows.len);
    }
}

test "engine recovers only the committed prefix after a torn wal tail" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-engine-torn";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var sealed_end: u64 = 0;
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();

        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
            .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text, .primary_key = false },
        };
        defer for (&cols) |*c| c.deinit(gpa);

        try eng.createTable("users", &cols);
        var a: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
        defer a.deinit(gpa);
        var b: value.Value = .{ .text = try gpa.dupe(u8, "bob") };
        defer b.deinit(gpa);
        var c: value.Value = .{ .text = try gpa.dupe(u8, "carol") };
        defer c.deinit(gpa);
        try eng.insert("users", &.{ .{ .int = 1 }, a });
        try eng.insert("users", &.{ .{ .int = 2 }, b });
        sealed_end = eng.wal.offset;
        try eng.insert("users", &.{ .{ .int = 3 }, c });

        const full = eng.wal.offset;
        const torn = sealed_end + (full - sealed_end) / 2;
        try eng.wal.file.truncate(torn);
        eng.wal.offset = torn;
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var all = try eng.selectAll("users", eng.publishedSeq());
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);
        try std.testing.expectEqual(sealed_end, eng.wal.offset);

        var ghost = try eng.selectByPk("users", .{ .int = 3 }, eng.publishedSeq());
        defer ghost.deinit();
        try std.testing.expectEqual(@as(usize, 0), ghost.rows.len);

        var d: value.Value = .{ .text = try gpa.dupe(u8, "dave") };
        defer d.deinit(gpa);
        try eng.insert("users", &.{ .{ .int = 4 }, d });
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var all = try eng.selectAll("users", eng.publishedSeq());
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 3), all.rows.len);
        var dave = try eng.selectByPk("users", .{ .int = 4 }, eng.publishedSeq());
        defer dave.deinit();
        try std.testing.expectEqualStrings("dave", dave.rows[0].values[1].text);
    }

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}

test "observation evidence survives checkpoint and restart with verified payload" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-evidence-recovery";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var evidence_id: u64 = 0;
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        evidence_id = try eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "png bytes");
        try std.testing.expectEqual(@as(usize, 1), eng.observationsView().len);
        _ = try eng.checkpoint();
    }
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        try std.testing.expectEqual(@as(usize, 1), eng.observationsView().len);
        const payload = try eng.readEvidencePayload(evidence_id);
        defer gpa.free(payload);
        try std.testing.expectEqualStrings("png bytes", payload);
    }
}

test "recovery rejects a corrupt committed evidence payload" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-evidence-corrupt";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        _ = try eng.observe("sensor_1", .sensor, "application/octet-stream", "2026-07-31T12:00:00+08:00", "test-sensor", "development", "sensor bytes");
    }
    {
        var root = try Io.Dir.cwd().openDir(io, dir_name, .{});
        defer root.close(io);
        var file = try root.openFile(io, "payloads/0000000000000001.rpe", .{ .mode = .read_write });
        defer file.close(io);
        var byte: [1]u8 = undefined;
        _ = try file.readPositionalAll(io, &byte, 20);
        byte[0] ^= 1;
        try file.writePositionalAll(io, &byte, 20);
        try file.sync(io);
    }
    try std.testing.expectError(error.CorruptPayload, Engine.open(gpa, io, dir_name, true));
}

// ── Evidence operator contract (roadmap Phase 2, ADR-0019) ──
// Metrics, instance-wide staging quotas, and staged-upload accounting.

test "instance-wide staging quota bounds concurrent attachments" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-evidence-staging-quota";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    eng.evidence_limits.max_concurrent_staging = 2;

    try eng.beginStage(10);
    try eng.beginStage(20);
    try std.testing.expectError(error.StagingQuotaExceeded, eng.beginStage(30));
    eng.finishStage(10); // a completed upload frees a slot
    try eng.beginStage(40);
    eng.abortStage(20); // an aborted upload frees a slot
    try eng.beginStage(50);

    const stats = eng.evidenceStats();
    try std.testing.expectEqual(@as(u64, 4), stats.staged_uploads);
    try std.testing.expectEqual(@as(u64, 1), stats.staging_rejections);
    try std.testing.expectEqual(@as(u64, 1), stats.aborted_uploads);
}

test "instance-wide staged byte budget is enforced" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-evidence-staged-bytes";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    eng.evidence_limits.max_staged_bytes = 100;

    try eng.beginStage(60);
    try std.testing.expectError(error.StagingQuotaExceeded, eng.beginStage(60));
    eng.abortStage(60);
    try eng.beginStage(60);

    const stats = eng.evidenceStats();
    try std.testing.expectEqual(@as(u64, 2), stats.staged_uploads);
    try std.testing.expectEqual(@as(u64, 1), stats.staging_rejections);
}

test "retained byte quota rejects evidence without creating it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-evidence-retained-quota";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    eng.evidence_limits.max_retained_bytes = 100;

    _ = try eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "aaaaaaaaaa");
    try std.testing.expectError(
        error.RetainedQuotaExceeded,
        eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "b" ** 95),
    );
    try std.testing.expectEqual(@as(usize, 1), eng.observationsView().len);

    const stats = eng.evidenceStats();
    try std.testing.expectEqual(@as(u64, 1), stats.committed_count);
    try std.testing.expectEqual(@as(u64, 1), stats.rejected_evidence);
    try std.testing.expectEqual(@as(u64, 1), stats.rejected_by_reason[@intFromEnum(RejectReason.retained_quota)]);
}

test "evidence metrics account a full upload lifecycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-evidence-metrics";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();

    try eng.beginStage(11);
    eng.finishStage(11);
    _ = try eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "image bytes");

    const stats = eng.evidenceStats();
    try std.testing.expectEqual(@as(u64, 1), stats.staged_uploads);
    try std.testing.expectEqual(@as(u64, 1), stats.committed_count);
    try std.testing.expectEqual(@as(u64, 1), stats.accepted_by_modality[modalityIndex(.image)]);
    try std.testing.expect(stats.payload_write_count >= 1);
}

test "oversized evidence payload rejection is counted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-evidence-oversize";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();

    const big = try gpa.alloc(u8, evidence_mod.MAX_PAYLOAD_LENGTH + 1);
    defer gpa.free(big);
    try std.testing.expectError(
        error.PayloadTooLarge,
        eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", big),
    );
    try std.testing.expectEqual(@as(usize, 0), eng.observationsView().len);

    const stats = eng.evidenceStats();
    try std.testing.expectEqual(@as(u64, 1), stats.rejected_evidence);
    try std.testing.expectEqual(@as(u64, 1), stats.rejected_by_reason[@intFromEnum(RejectReason.payload_too_large)]);
}

test "a corrupt payload read increments the failure counter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-evidence-read-failure";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try Engine.open(gpa, io, dir_name, true);
    defer eng.deinit();
    const id = try eng.observe("sensor_1", .sensor, "application/octet-stream", "2026-07-31T12:00:00+08:00", "test-sensor", "development", "sensor bytes");

    var root = try Io.Dir.cwd().openDir(io, dir_name, .{});
    defer root.close(io);
    var file = try root.openFile(io, "payloads/0000000000000001.rpe", .{ .mode = .read_write });
    defer file.close(io);
    var byte: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &byte, 20);
    byte[0] ^= 1;
    try file.writePositionalAll(io, &byte, 20);
    try file.sync(io);

    try std.testing.expectError(error.CorruptPayload, eng.readEvidencePayload(id));
    try std.testing.expectEqual(@as(u64, 1), eng.evidenceStats().payload_failures);
}

test "vector columns survive checkpoint and restart, and rank deterministically" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-vector-recovery";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var columns = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
            .{ .name = try gpa.dupe(u8, "embedding"), .type_tag = .vector, .not_null = true },
        };
        defer for (&columns) |*column| column.deinit(gpa);
        try eng.createTable("document", &columns);

        var first: value.Value = .{ .vector = try gpa.dupe(f32, &.{ 1, 0 }) };
        defer first.deinit(gpa);
        var second: value.Value = .{ .vector = try gpa.dupe(f32, &.{ 0, 1 }) };
        defer second.deinit(gpa);
        try eng.insert("document", &.{ .{ .int = 10 }, first });
        try eng.insert("document", &.{ .{ .int = 20 }, second });

        const ranked = try eng.searchVectors("document", "embedding", &.{ 0, 1 }, .cosine, 1);
        defer gpa.free(ranked);
        try std.testing.expectEqual(@as(usize, 1), ranked.len);
        try std.testing.expectEqual(@as(usize, 1), ranked[0].row_index);
        _ = try eng.checkpoint();
    }
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        const ranked = try eng.searchVectors("document", "embedding", &.{ 0, 1 }, .cosine, 2);
        defer gpa.free(ranked);
        try std.testing.expectEqual(@as(usize, 2), ranked.len);
        try std.testing.expectEqual(@as(usize, 1), ranked[0].row_index);
        try std.testing.expectEqual(@as(usize, 0), ranked[1].row_index);
    }
}

test "document collections survive restart and checkpoint" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-engine-documents";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        try eng.createDocument("books");

        var fields = [_]document_mod.Field{
            .{ .path = try gpa.dupe(u8, "title"), .item = .{ .text = try gpa.dupe(u8, "Dune") } },
            .{ .path = try gpa.dupe(u8, "author.name"), .item = .{ .text = try gpa.dupe(u8, "Herbert") } },
        };
        defer for (&fields) |*f| f.deinit(gpa);
        try eng.insertDocument("books", "1", &fields);
        // A duplicate id is rejected before any WAL record is written.
        try std.testing.expectError(error.DuplicateDocumentId, eng.insertDocument("books", "1", &fields));
        // A name cannot be both a table and a document collection.
        var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int }};
        defer cols[0].deinit(gpa);
        try std.testing.expectError(error.TableExists, eng.createTable("books", &cols));

        const stats = try eng.checkpoint();
        try std.testing.expectEqual(@as(usize, 1), stats.collections);
        try std.testing.expectEqual(@as(usize, 1), stats.documents);
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        const collection = eng.getDocumentCollection("books") orelse return error.NotFound;
        try std.testing.expectEqual(@as(usize, 1), collection.order.items.len);
        const doc = collection.order.items[0];
        try std.testing.expectEqualStrings("1", doc.id);
        try std.testing.expectEqualStrings("Dune", doc.pathValue("title").?.text);
        try std.testing.expectEqualStrings("Herbert", doc.pathValue("author.name").?.text);
    }
}

test "graph collections survive restart and checkpoint" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-engine-graphs";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        try eng.createGraph("social");
        var fields = [_]document_mod.Field{.{ .path = try gpa.dupe(u8, "name"), .item = .{ .text = try gpa.dupe(u8, "Ada") } }};
        defer fields[0].deinit(gpa);
        try eng.addNode("social", "1", &fields);
        try eng.addNode("social", "2", &fields);
        try eng.addEdge("social", "1", "mentors", "2");
        // An edge to an unknown node is rejected before any WAL record.
        try std.testing.expectError(error.UnknownNode, eng.addEdge("social", "1", "mentors", "99"));

        const stats = try eng.checkpoint();
        try std.testing.expectEqual(@as(usize, 1), stats.graphs);
        try std.testing.expectEqual(@as(usize, 2), stats.graph_nodes);
        try std.testing.expectEqual(@as(usize, 1), stats.graph_edges);
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        const graph = eng.getGraph("social") orelse return error.NotFound;
        try std.testing.expectEqual(@as(usize, 2), graph.nodes.order.items.len);
        try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
        try std.testing.expectEqualStrings("1", graph.edges.items[0].from);
        try std.testing.expectEqualStrings("mentors", graph.edges.items[0].label);
        try std.testing.expectEqualStrings("2", graph.edges.items[0].to);
    }
}

test "checkpoint publishes a durable manifest that restart validates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-engine-manifest";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
        defer cols[0].deinit(gpa);
        try eng.createTable("t", &cols);
        try eng.createDocument("docs");
        try eng.createGraph("g");
        _ = try eng.checkpoint();
    }

    // A clean restart rebuilds the catalog from the rewritten WAL and accepts
    // the manifest published by the checkpoint.
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        try std.testing.expect(eng.getTable("t") != null);
        try std.testing.expect(eng.getDocumentCollection("docs") != null);
        try std.testing.expect(eng.getGraph("g") != null);
    }

    // A manifest naming an object absent from the rebuilt catalog is an
    // inconsistent checkpoint: startup rejects it rather than proceeding.
    {
        var vfs = try vfs_mod.Vfs.open(io, dir_name);
        defer vfs.close();
        var objects = [_]manifest_mod.CatalogObject{.{ .kind = .table, .name = "ghost" }};
        const bad = manifest_mod.Manifest{ .commit_seq = 0, .objects = objects[0..] };
        try manifest_mod.publish(&vfs, gpa, &bad);
    }
    try std.testing.expectError(error.CorruptManifest, Engine.open(gpa, io, dir_name, true));

    // A manifest written by an incompatible (future) build is rejected.
    {
        var vfs = try vfs_mod.Vfs.open(io, dir_name);
        defer vfs.close();
        var objects = [_]manifest_mod.CatalogObject{.{ .kind = .table, .name = "t" }};
        const good = manifest_mod.Manifest{ .commit_seq = 1, .objects = objects[0..] };
        const bytes = try manifest_mod.encode(gpa, &good);
        defer gpa.free(bytes);
        var future = try gpa.dupe(u8, bytes);
        defer gpa.free(future);
        std.mem.writeInt(u32, future["RUNADB_MAN".len..][0..4], manifest_mod.FORMAT_VERSION + 1, .little);
        var atomic = try vfs.createAtomicFile("manifest");
        defer atomic.deinit();
        try atomic.writeAtAll(future, 0);
        try atomic.sync();
        try atomic.commit();
    }
    try std.testing.expectError(error.UnsupportedManifest, Engine.open(gpa, io, dir_name, true));

    // A corrupt complete manifest is rejected, leaving the data directory for
    // forensics rather than silently recovering around it.
    {
        var vfs = try vfs_mod.Vfs.open(io, dir_name);
        defer vfs.close();
        var atomic = try vfs.createAtomicFile("manifest");
        defer atomic.deinit();
        try atomic.writeAtAll("this is not a manifest", 0);
        try atomic.sync();
        try atomic.commit();
    }
    try std.testing.expectError(error.InvalidManifest, Engine.open(gpa, io, dir_name, true));
}

// ── LSM flush / compaction integration (roadmap Phase 5) ──

test "manual flush materializes rows and restart skips the wal tail without duplicates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-lsm-flush";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();

        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true, .serial = true },
            .{ .name = try gpa.dupe(u8, "v"), .type_tag = .int },
        };
        defer for (&cols) |*c| c.deinit(gpa);
        try eng.createTable("t", &cols);
        try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
        try eng.insert("t", &.{ .{ .int = 2 }, .{ .int = 20 } });

        // Flush publishes the LSM manifest but leaves the WAL untouched: this
        // is the crash window between manifest publication and the WAL
        // rewrite of a full checkpoint.
        try eng.flush("t");
        try std.testing.expect(eng.lsmStats().flushed_files == 1);
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var all = try eng.selectAll("t", eng.publishedSeq());
        defer all.deinit();
        // Exactly the two flushed rows: pre-flush batches were skipped.
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);
        try std.testing.expectEqual(@as(i64, 10), all.rows[0].values[1].int);
        try std.testing.expectEqual(@as(i64, 20), all.rows[1].values[1].int);

        // And a fresh serial is not reused after recovery.
        try std.testing.expectEqual(@as(i64, 3), try eng.allocSerial("t"));
    }
}

test "writes after a manual flush survive restart without duplication" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-lsm-flush-append";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
        defer cols[0].deinit(gpa);
        try eng.createTable("t", &cols);
        try eng.insert("t", &.{.{ .int = 1 }});
        try eng.insert("t", &.{.{ .int = 2 }});
        try eng.flush("t");
        // Post-flush commits ride in the WAL tail.
        try eng.insert("t", &.{.{ .int = 3 }});
        try eng.update("t", .{ .int = 2 }, &.{.{ .int = 2 }});
        try eng.delete("t", .{ .int = 1 });
    }
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var all = try eng.selectAll("t", eng.publishedSeq());
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);
        var by_pk = try eng.selectByPk("t", .{ .int = 2 }, eng.publishedSeq());
        defer by_pk.deinit();
        try std.testing.expectEqual(@as(usize, 1), by_pk.rows.len);
        var gone = try eng.selectByPk("t", .{ .int = 1 }, eng.publishedSeq());
        defer gone.deinit();
        try std.testing.expectEqual(@as(usize, 0), gone.rows.len);
    }
}

test "checkpoint after a flush reuses the lsm store and compaction reclaims space" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-lsm-compact";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
            .{ .name = try gpa.dupe(u8, "v"), .type_tag = .int },
        };
        defer for (&cols) |*c| c.deinit(gpa);
        try eng.createTable("t", &cols);
        try eng.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
        try eng.insert("t", &.{ .{ .int = 2 }, .{ .int = 20 } });
        try eng.flush("t");

        // A second flush at the next checkpoint captures updates; the older
        // SSTable still holds the superseded versions.
        try eng.update("t", .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 11 } });
        try eng.insert("t", &.{ .{ .int = 3 }, .{ .int = 30 } });
        _ = try eng.checkpoint();
        try std.testing.expect(eng.lsmStats().flushed_files == 2);

        // Compaction merges the two L0 files into one L1 file.
        try eng.compact("t");
        const stats = eng.lsmStats();
        try std.testing.expectEqual(@as(u64, 1), stats.compaction_runs);
        try std.testing.expectEqual(@as(u64, 2), stats.files_reclaimed);
        // One superseded version was dropped (row 1's pre-update value).
        try std.testing.expect(stats.compaction_dropped_entries >= 1);
    }
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var all = try eng.selectAll("t", eng.publishedSeq());
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 3), all.rows.len);
        var r1 = try eng.selectByPk("t", .{ .int = 1 }, eng.publishedSeq());
        defer r1.deinit();
        try std.testing.expectEqual(@as(i64, 11), r1.rows[0].values[1].int);
        var r3 = try eng.selectByPk("t", .{ .int = 3 }, eng.publishedSeq());
        defer r3.deinit();
        try std.testing.expectEqual(@as(i64, 30), r3.rows[0].values[1].int);
    }
}

test "lsm flush collapses alter history and retained versions like a checkpoint" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-lsm-alter";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
            .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text },
        };
        defer for (&cols) |*c| c.deinit(gpa);
        try eng.createTable("t", &cols);
        var a: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
        defer a.deinit(gpa);
        try eng.insert("t", &.{ .{ .int = 1 }, a });
        try eng.flush("t");

        var extra: value.Column = .{ .name = try gpa.dupe(u8, "tier"), .type_tag = .int };
        defer extra.deinit(gpa);
        try eng.addColumn("t", extra, false);
        try eng.dropColumn("t", "name", false);
        // The ALTER records stay in the WAL; recovery replays them over the
        // manifest's pre-ALTER schema.
        try eng.flush("t");
    }
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        const table = eng.getTable("t").?;
        try std.testing.expectEqual(@as(usize, 2), table.columns.len);
        try std.testing.expectEqualStrings("id", table.columns[0].name);
        try std.testing.expectEqualStrings("tier", table.columns[1].name);
        var all = try eng.selectAll("t", eng.publishedSeq());
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 1), all.rows.len);
    }
}

test "heap tables stay wal-backed while pk tables flush to sstables" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-lsm-heap";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
        defer cols[0].deinit(gpa);
        try eng.createTable("pk_t", &cols);
        try eng.insert("pk_t", &.{.{ .int = 1 }});

        var heap_cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "note"), .type_tag = .text }};
        defer heap_cols[0].deinit(gpa);
        try eng.createTable("heap_t", &heap_cols);
        var note: value.Value = .{ .text = try gpa.dupe(u8, "hello") };
        defer note.deinit(gpa);
        try eng.insert("heap_t", &.{note});

        _ = try eng.checkpoint();
        // Only the pk table materialized into the LSM.
        try std.testing.expectEqual(@as(usize, 1), eng.lsm.tableCount());
    }
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var pk_rows = try eng.selectAll("pk_t", eng.publishedSeq());
        defer pk_rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), pk_rows.rows.len);
        var heap_rows = try eng.selectAll("heap_t", eng.publishedSeq());
        defer heap_rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), heap_rows.rows.len);
        try std.testing.expectEqualStrings("hello", heap_rows.rows[0].values[0].text);
    }
}

test "text primary keys flush, compact, and recover" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-lsm-text-pk";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "key"), .type_tag = .text, .primary_key = true },
            .{ .name = try gpa.dupe(u8, "v"), .type_tag = .int },
        };
        defer for (&cols) |*c| c.deinit(gpa);
        try eng.createTable("t", &cols);
        var a: value.Value = .{ .text = try gpa.dupe(u8, "alpha") };
        defer a.deinit(gpa);
        var b: value.Value = .{ .text = try gpa.dupe(u8, "beta") };
        defer b.deinit(gpa);
        var c: value.Value = .{ .text = try gpa.dupe(u8, "gamma") };
        defer c.deinit(gpa);
        try eng.insert("t", &.{ a, .{ .int = 1 } });
        try eng.insert("t", &.{ b, .{ .int = 2 } });
        try eng.insert("t", &.{ c, .{ .int = 3 } });
        try eng.flush("t");

        try eng.update("t", b, &.{ b, .{ .int = 20 } });
        try eng.delete("t", c);
        _ = try eng.checkpoint();
        try eng.compact("t");
    }
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var all = try eng.selectAll("t", eng.publishedSeq());
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);
        var beta_pk: value.Value = .{ .text = try gpa.dupe(u8, "beta") };
        defer beta_pk.deinit(gpa);
        var beta = try eng.selectByPk("t", beta_pk, eng.publishedSeq());
        defer beta.deinit();
        try std.testing.expectEqual(@as(i64, 20), beta.rows[0].values[1].int);
        var gamma_pk: value.Value = .{ .text = try gpa.dupe(u8, "gamma") };
        defer gamma_pk.deinit(gpa);
        var gamma = try eng.selectByPk("t", gamma_pk, eng.publishedSeq());
        defer gamma.deinit();
        try std.testing.expectEqual(@as(usize, 0), gamma.rows.len);
    }
}

test "a corrupt sstable fails recovery rather than being ignored" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-lsm-corrupt-sst";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
        defer cols[0].deinit(gpa);
        try eng.createTable("t", &cols);
        try eng.insert("t", &.{.{ .int = 1 }});
        try eng.flush("t");
    }
    // Corrupt the first byte of the single SSTable.
    {
        var root = try Io.Dir.cwd().openDir(io, dir_name, .{});
        defer root.close(io);
        var lsm_dir = try root.openDir(io, "lsm", .{ .iterate = true });
        defer lsm_dir.close(io);
        var it = lsm_dir.iterate();
        var target: ?[]const u8 = null;
        while (try it.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, "sst_")) target = entry.name;
        }
        const name = target orelse return error.NotFound;
        var file = try lsm_dir.openFile(io, name, .{ .mode = .read_write });
        defer file.close(io);
        var byte: [1]u8 = undefined;
        _ = try file.readPositionalAll(io, &byte, 0);
        byte[0] ^= 0xFF;
        try file.writePositionalAll(io, &byte, 0);
        try file.sync(io);
    }
    try std.testing.expectError(error.CorruptSst, Engine.open(gpa, io, dir_name, true));
}

test "post-flush serial allocations survive recovery without reuse" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-lsm-serial";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true, .serial = true }};
        defer cols[0].deinit(gpa);
        try eng.createTable("t", &cols);
        try eng.insert("t", &.{.{ .int = 1 }});
        try eng.flush("t"); // manifest serial = 2

        // A post-flush insert raises the in-memory counter beyond the manifest.
        try eng.insert("t", &.{.{ .int = 100 }});
        try std.testing.expectEqual(@as(i64, 101), eng.allocSerial("t"));
    }
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        // The replayed post-flush insert (pk 100) raised the counter to 101;
        // a fresh allocation must continue from there, never falling back to
        // the manifest's stale value of 2 (which would reuse pk 2).
        try std.testing.expectEqual(@as(i64, 101), try eng.allocSerial("t"));
    }
}

test "checkpoint flushes an empty pk table into the manifest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-lsm-empty";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true, .serial = true }};
        defer cols[0].deinit(gpa);
        try eng.createTable("t", &cols);
        _ = try eng.checkpoint();
        try std.testing.expectEqual(@as(usize, 1), eng.lsm.tableCount());
    }
    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        const table = eng.getTable("t") orelse return error.NotFound;
        try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
        try std.testing.expectEqual(@as(i64, 1), try eng.allocSerial("t"));
    }
}
