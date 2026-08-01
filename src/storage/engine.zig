const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const wal_mod = @import("wal.zig");
const table_mod = @import("table.zig");
const checkpoint_mod = @import("checkpoint.zig");
const evidence_mod = @import("evidence.zig");
const vector_mod = @import("../vector.zig");
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

fn engineApplyOp(eng: *Engine, op: *const wal_mod.TxnOp) anyerror!void {
    return eng.applyTxnOp(op);
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

/// Single-writer storage engine: in-memory tables + WAL.
/// Phase 0 has no SSTables yet. Table storage lives in `table.zig`;
/// this module owns durability ordering (validate → WAL append → apply).
pub const Engine = struct {
    gpa: Allocator,
    io: Io,
    wal: wal_mod.Wal,
    payloads: evidence_mod.Store,
    tables: std.StringHashMap(Table),
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

    pub fn open(gpa: Allocator, io: Io, data_dir: []const u8, sync_wal: bool) !Engine {
        var wal = try wal_mod.Wal.open(gpa, io, data_dir, sync_wal);
        var transferred = false;
        errdefer if (!transferred) wal.deinit();
        var payloads = try evidence_mod.Store.open(io, data_dir, sync_wal);
        errdefer if (!transferred) payloads.deinit();
        var eng: Engine = .{
            .gpa = gpa,
            .io = io,
            .wal = wal,
            .payloads = payloads,
            .tables = std.StringHashMap(Table).init(gpa),
            .observations = .empty,
            .coordinator = Coordinator.init(gpa, io),
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
        for (self.observations.items) |*record| record.deinit(self.gpa);
        self.observations.deinit(self.gpa);
        self.payloads.deinit();
        self.coordinator.deinit();
        self.wal.deinit();
        self.* = undefined;
    }

    fn recover(self: *Engine) !void {
        try wal_mod.replayWal(&self.wal, self, applyRecord);
        var committed = std.AutoHashMap(u64, usize).init(self.gpa);
        defer committed.deinit();
        for (self.observations.items, 0..) |record, index| try committed.put(record.evidence_id, index);
        const reclaimed = try self.payloads.reclaimOrphans(&committed);
        self.evidence_stats.recovery_orphans_found = reclaimed.count;
        self.evidence_stats.recovery_orphan_bytes = reclaimed.bytes;
    }

    fn applyRecord(self: *Engine, view: wal_mod.RecordView) !void {
        switch (view) {
            .txn_batch => |batch| {
                if (batch.commit_seq != 0 and batch.commit_seq > self.published_commit_seq) {
                    self.published_commit_seq = batch.commit_seq;
                }
                try wal_mod.forEachTxnBatchOp(self.gpa, batch.body, self.wal.file_version, self, applyRecord);
            },
            .set_commit_seq => |seq| {
                if (seq > self.published_commit_seq) self.published_commit_seq = seq;
            },
            else => try self.applyOne(view),
        }
    }

    fn applyOne(self: *Engine, view: wal_mod.RecordView) !void {
        switch (view) {
            .txn_batch, .set_commit_seq => return error.InvalidWal,
            .create_table => |ct| {
                try self.registerTable(ct.name, ct.columns);
            },
            .insert => |ins| {
                const table = self.tables.getPtr(ins.table) orelse return error.TableNotFound;
                try table.insert(self.gpa, ins.values);
            },
            .update => |upd| {
                const table = self.tables.getPtr(upd.table) orelse return error.TableNotFound;
                if (table.pk_index != null) {
                    try table.update(self.gpa, upd.pk, upd.values);
                } else {
                    const idx: usize = switch (upd.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    try table.updateAt(self.gpa, idx, upd.values);
                }
            },
            .delete => |del| {
                const table = self.tables.getPtr(del.table) orelse return error.TableNotFound;
                if (table.pk_index != null) {
                    try table.delete(self.gpa, del.pk);
                } else {
                    const idx: usize = switch (del.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    try table.deleteAt(self.gpa, idx);
                }
            },
            .add_column => |add| {
                const table = self.tables.getPtr(add.table) orelse return error.TableNotFound;
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
                try table.dropColumn(self.gpa, drop.column);
            },
            // Checkpoint-only record. Replayed inserts raise `next_serial` to
            // `max(pk)+1`; this restores the counter the instance actually
            // reached, so identifiers retired by DELETE are not handed out again.
            .set_serial => |ss| {
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

    fn applyTxnOp(self: *Engine, op: *const wal_mod.TxnOp) anyerror!void {
        switch (op.*) {
            .insert => |ins| {
                const table = self.tables.getPtr(ins.table) orelse return error.TableNotFound;
                try table.insert(self.gpa, ins.values);
            },
            .update => |upd| {
                const table = self.tables.getPtr(upd.table) orelse return error.TableNotFound;
                if (table.pk_index != null) {
                    try table.update(self.gpa, upd.pk, upd.values);
                } else {
                    const idx: usize = switch (upd.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    try table.updateAt(self.gpa, idx, upd.values);
                }
            },
            .delete => |del| {
                const table = self.tables.getPtr(del.table) orelse return error.TableNotFound;
                if (table.pk_index != null) {
                    try table.delete(self.gpa, del.pk);
                } else {
                    const idx: usize = switch (del.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    try table.deleteAt(self.gpa, idx);
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
        if (self.tables.contains(name)) return error.TableExists;

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
        if (result) |err| return err;
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
        try table.updateAt(self.gpa, idx, values);
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
        try table.deleteAt(self.gpa, idx);
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

    pub fn selectAll(self: *Engine, table_name: []const u8) !SelectResult {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        return .{
            .columns = table.columns,
            .rows = table.rows.items,
            .owned_rows = null,
            .gpa = self.gpa,
        };
    }

    pub fn selectByPk(self: *Engine, table_name: []const u8, pk: value.Value) !SelectResult {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (table.pkLookup(pk)) |idx| {
            const one = try self.gpa.alloc(Row, 1);
            errdefer self.gpa.free(one);
            one[0] = try table.rows.items[idx].clone(self.gpa);
            return .{
                .columns = table.columns,
                .rows = one,
                .owned_rows = one,
                .gpa = self.gpa,
            };
        }
        const empty = try self.gpa.alloc(Row, 0);
        return .{
            .columns = table.columns,
            .rows = empty,
            .owned_rows = empty,
            .gpa = self.gpa,
        };
    }

    /// Read Committed scan through `tx`'s private write set: committed rows the
    /// transaction has not touched are cloned unchanged, rows it staged as
    /// update or insert appear with the write-set values, and rows it staged as
    /// delete are invisible. Other connections' uncommitted writes never enter
    /// this result: the live tables hold only published commits, and the private
    /// write set is merged only for the owning transaction. This is the engine
    /// boundary that makes explicit-transaction reads read-your-writes while
    /// every other reader sees only committed state.
    pub fn selectAllTx(self: *Engine, tx: *txn_mod.Transaction, table_name: []const u8) !SelectResult {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const gpa = self.gpa;

        var merged: std.ArrayList(Row) = .empty;
        errdefer {
            for (merged.items) |*row| row.deinit(gpa);
            merged.deinit(gpa);
        }

        const pk_index = table.pk_index;
        for (table.rows.items) |row| {
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

        // Private rows that do not exist in committed state append new rows.
        // Only the last write-set entry for a key is effective: an earlier
        // insert is superseded by its own later update/delete.
        if (pk_index) |_| {
            for (tx.write_set.items) |*op| {
                if (op.op == .delete or !std.mem.eql(u8, op.table, table_name)) continue;
                const effective = tx.lastStaged(table_name, op.pk) orelse continue;
                if (effective != op) continue;
                if (table.pkContains(op.pk)) continue;
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
    pub fn selectByPkTx(self: *Engine, tx: *txn_mod.Transaction, table_name: []const u8, pk: value.Value) !SelectResult {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (table.pk_index == null) return self.selectByPk(table_name, pk);
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
        return self.selectByPk(table_name, pk);
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

        var refs: std.ArrayList(*const Table) = .empty;
        defer refs.deinit(self.gpa);
        try refs.ensureTotalCapacity(self.gpa, self.tables.count());
        var it = self.tables.iterator();
        while (it.next()) |entry| refs.appendAssumeCapacity(entry.value_ptr);

        return checkpoint_mod.run(&self.wal, refs.items, self.observations.items, self.publishedSeq());
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

        var res = try eng.selectByPk("users", .{ .int = 1 });
        defer res.deinit();
        try std.testing.expectEqual(@as(usize, 1), res.rows.len);
        try std.testing.expectEqualStrings("alice", res.rows[0].values[1].text);
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var res = try eng.selectAll("users");
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

        var res = try eng.selectByPk("users", .{ .int = 2 });
        defer res.deinit();
        try std.testing.expectEqual(@as(usize, 1), res.rows.len);
        try std.testing.expectEqualStrings("bobby", res.rows[0].values[1].text);

        var all = try eng.selectAll("users");
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var all = try eng.selectAll("users");
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);

        var r2 = try eng.selectByPk("users", .{ .int = 2 });
        defer r2.deinit();
        try std.testing.expectEqualStrings("bobby", r2.rows[0].values[1].text);

        var r1 = try eng.selectByPk("users", .{ .int = 1 });
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
        var rows = try eng.selectAll("users");
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
        var all = try eng.selectAll("t");
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
        var all = try eng.selectAll("t");
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
        var all = try eng.selectAll("users");
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 2), all.rows.len);
        try std.testing.expectEqual(sealed_end, eng.wal.offset);

        var ghost = try eng.selectByPk("users", .{ .int = 3 });
        defer ghost.deinit();
        try std.testing.expectEqual(@as(usize, 0), ghost.rows.len);

        var d: value.Value = .{ .text = try gpa.dupe(u8, "dave") };
        defer d.deinit(gpa);
        try eng.insert("users", &.{ .{ .int = 4 }, d });
    }

    {
        var eng = try Engine.open(gpa, io, dir_name, true);
        defer eng.deinit();
        var all = try eng.selectAll("users");
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 3), all.rows.len);
        var dave = try eng.selectByPk("users", .{ .int = 4 });
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
