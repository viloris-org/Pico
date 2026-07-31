const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const wal_mod = @import("wal.zig");
const table_mod = @import("table.zig");
const checkpoint_mod = @import("checkpoint.zig");
const evidence_mod = @import("evidence.zig");
const vector_mod = @import("../vector.zig");

pub const EngineError = table_mod.Error;
pub const Row = table_mod.Row;
pub const Table = table_mod.Table;
pub const Pred = table_mod.Pred;
pub const ColumnSpec = table_mod.ColumnSpec;
pub const VectorSearchError = error{VectorColumnRequired} || vector_mod.Error || Allocator.Error;

pub const EvidenceStats = struct {
    committed_count: u64 = 0,
    committed_bytes: u64 = 0,
    recovery_orphans_found: u64 = 0,
    recovery_orphan_bytes: u64 = 0,
};

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
    /// Serializes the mutating sequence (validate → WAL append → apply) against
    /// itself and against a checkpoint.
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
        };
        transferred = true;
        errdefer eng.deinit();
        try eng.recover();
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
                try wal_mod.forEachTxnBatchOp(self.gpa, batch.body, self, applyRecord);
            },
            else => try self.applyOne(view),
        }
    }

    fn applyOne(self: *Engine, view: wal_mod.RecordView) !void {
        switch (view) {
            .txn_batch => return error.InvalidWal,
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

    /// Publish an explicit-transaction write set: one WAL frame, then apply all ops.
    /// Ops were validated incrementally while staging against base + earlier write-set
    /// entries; apply order must match staging order so later ops see earlier ones.
    pub fn commitTxnOps(self: *Engine, ops: []const wal_mod.TxnOp) !void {
        if (ops.len == 0) return;
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);

        try self.wal.appendTxnBatch(ops);
        for (ops) |op| {
            try self.applyTxnOp(op);
        }
    }

    fn applyTxnOp(self: *Engine, op: wal_mod.TxnOp) !void {
        switch (op) {
            .insert => |ins| {
                const table = self.tables.getPtr(ins.table) orelse return error.TableNotFound;
                try table.insert(self.gpa, ins.values);
            },
            .update => |upd| {
                const table = self.tables.getPtr(upd.table) orelse return error.TableNotFound;
                try table.update(self.gpa, upd.pk, upd.values);
            },
            .delete => |del| {
                const table = self.tables.getPtr(del.table) orelse return error.TableNotFound;
                try table.delete(self.gpa, del.pk);
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

    pub fn insert(self: *Engine, table_name: []const u8, values: []const value.Value) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try table.validateInsert(values);
        try self.wal.appendInsert(.{ .table = table_name, .values = values });
        try table.insert(self.gpa, values);
    }

    pub fn update(self: *Engine, table_name: []const u8, pk: value.Value, values: []const value.Value) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try table.validateUpdate(pk, values);
        try self.wal.appendUpdate(.{ .table = table_name, .pk = pk, .values = values });
        try table.update(self.gpa, pk, values);
    }

    /// Update by current row index; WAL records full row with PK when present, else uses int index as pseudo-pk for replay.
    pub fn updateAt(self: *Engine, table_name: []const u8, idx: usize, values: []const value.Value) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (idx >= table.rows.items.len) return error.PrimaryKeyNotFound;
        if (table.pk_index) |pki| {
            const pk = table.rows.items[idx].values[pki];
            try table.validateUpdate(pk, values);
            try self.wal.appendUpdate(.{ .table = table_name, .pk = pk, .values = values });
            try table.update(self.gpa, pk, values);
        } else {
            try table.validateUpdateAt(idx, values);
            try self.wal.appendUpdate(.{ .table = table_name, .pk = .{ .int = @intCast(idx) }, .values = values });
            try table.updateAt(self.gpa, idx, values);
        }
    }

    pub fn delete(self: *Engine, table_name: []const u8, pk: value.Value) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (!table.pkContains(pk)) return error.PrimaryKeyNotFound;

        try self.wal.appendDelete(.{ .table = table_name, .pk = pk });
        try table.delete(self.gpa, pk);
    }

    pub fn deleteAt(self: *Engine, table_name: []const u8, idx: usize) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (idx >= table.rows.items.len) return error.PrimaryKeyNotFound;
        if (table.pk_index) |pki| {
            const pk = table.rows.items[idx].values[pki];
            try self.wal.appendDelete(.{ .table = table_name, .pk = pk });
            try table.delete(self.gpa, pk);
        } else {
            try self.wal.appendDelete(.{ .table = table_name, .pk = .{ .int = @intCast(idx) } });
            try table.deleteAt(self.gpa, idx);
        }
    }

    /// Publish immutable Observation Evidence through payload-file then WAL
    /// ordering. A failed WAL append leaves a reclaimable orphan file.
    pub fn observe(self: *Engine, object_id: []const u8, modality: evidence_mod.Modality, media_type: []const u8, observed_at: []const u8, origin: []const u8, owner: []const u8, payload: []const u8) !u64 {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        if (payload.len > evidence_mod.MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;
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
        try evidence_mod.validateMetadata(metadata);
        var record = try evidence_mod.Record.clone(self.gpa, metadata);
        errdefer record.deinit(self.gpa);
        try self.observations.ensureUnusedCapacity(self.gpa, 1);
        const stored_digest = try self.payloads.publish(id, payload);
        if (!std.mem.eql(u8, &stored_digest, &payload_digest)) return error.CorruptPayload;
        try self.wal.appendObserve(metadata);
        self.observations.appendAssumeCapacity(record);
        self.next_evidence_id = id + 1;
        self.evidence_stats.committed_count += 1;
        self.evidence_stats.committed_bytes += payload.len;
        return id;
    }

    pub fn readEvidencePayload(self: *Engine, evidence_id: u64) ![]u8 {
        for (self.observations.items) |record| {
            if (record.evidence_id == evidence_id) {
                return self.payloads.read(self.gpa, evidence_id, record.payload_length, record.payload_digest);
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

        return checkpoint_mod.run(&self.wal, refs.items, self.observations.items);
    }
};

fn existingColumnValue(gpa: Allocator, default_expr: value.DefaultExpr) !value.Value {
    return switch (default_expr) {
        .none, .now => .null,
        .literal => |v| try v.clone(gpa),
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
