//! Per-connection transaction state and private write set.
//!
//! Owns the idle/active/failed state machine from concurrency-control.md.
//! Uncommitted DML stays here until COMMIT publishes via Engine.commitTxnOps
//! (single WAL txn_batch frame). sql/ may stage ops; it must not write WAL.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("../storage/engine.zig");
const value = @import("../storage/value.zig");
const wal_mod = @import("../storage/wal.zig");
const table_mod = @import("../storage/table.zig");

pub const State = enum {
    idle,
    active,
    failed,
};

pub const TxnError = error{
    InFailedTransaction,
    NoActiveTransaction,
    /// Explicit transactions currently require a single-column primary key.
    TxnRequiresPrimaryKey,
} || table_mod.Error || Allocator.Error;

/// Owned DML entry in the private write set.
pub const WriteOp = union(enum) {
    insert: struct {
        table: []u8,
        values: []value.Value,
    },
    update: struct {
        table: []u8,
        pk: value.Value,
        values: []value.Value,
    },
    delete: struct {
        table: []u8,
        pk: value.Value,
    },

    pub fn deinit(self: *WriteOp, gpa: Allocator) void {
        switch (self.*) {
            .insert => |*ins| {
                gpa.free(ins.table);
                for (ins.values) |*v| v.deinit(gpa);
                gpa.free(ins.values);
            },
            .update => |*upd| {
                gpa.free(upd.table);
                upd.pk.deinit(gpa);
                for (upd.values) |*v| v.deinit(gpa);
                gpa.free(upd.values);
            },
            .delete => |*del| {
                gpa.free(del.table);
                del.pk.deinit(gpa);
            },
        }
        self.* = .{ .delete = .{ .table = &[_]u8{}, .pk = .null } };
    }

    fn toWalOp(self: WriteOp) wal_mod.TxnOp {
        return switch (self) {
            .insert => |ins| .{ .insert = .{ .table = ins.table, .values = ins.values } },
            .update => |upd| .{ .update = .{ .table = upd.table, .pk = upd.pk, .values = upd.values } },
            .delete => |del| .{ .delete = .{ .table = del.table, .pk = del.pk } },
        };
    }
};

/// Connection-scoped transaction session.
pub const Session = struct {
    gpa: Allocator,
    state: State = .idle,
    ops: std.ArrayList(WriteOp) = .empty,

    pub fn init(gpa: Allocator) Session {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Session) void {
        self.clearOps();
        self.ops.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn readyStatus(self: *const Session) u8 {
        return switch (self.state) {
            .idle => 'I',
            .active => 'T',
            .failed => 'E',
        };
    }

    pub fn begin(self: *Session) TxnError!void {
        switch (self.state) {
            .failed => return error.InFailedTransaction,
            .idle => self.state = .active,
            // Nested BEGIN is a no-op (PostgreSQL warns; we stay active).
            .active => {},
        }
    }

    pub fn commit(self: *Session, eng: *engine_mod.Engine) !void {
        switch (self.state) {
            .failed => return error.InFailedTransaction,
            .idle => {}, // no-op success, mirrors PG warning path
            .active => {
                if (self.ops.items.len > 0) {
                    const wal_ops = try self.gpa.alloc(wal_mod.TxnOp, self.ops.items.len);
                    defer self.gpa.free(wal_ops);
                    for (self.ops.items, 0..) |op, i| {
                        wal_ops[i] = op.toWalOp();
                    }
                    try eng.commitTxnOps(wal_ops);
                }
                self.clearOps();
                self.state = .idle;
            },
        }
    }

    pub fn rollback(self: *Session) void {
        self.clearOps();
        self.state = .idle;
    }

    /// Mark the transaction failed after a statement error. No-op when idle
    /// (autocommit failures do not leave a failed transaction).
    pub fn fail(self: *Session) void {
        if (self.state == .active) {
            self.state = .failed;
        }
    }

    pub fn ensureExecutable(self: *const Session) TxnError!void {
        if (self.state == .failed) return error.InFailedTransaction;
    }

    pub fn inTxn(self: *const Session) bool {
        return self.state == .active or self.state == .failed;
    }

    fn clearOps(self: *Session) void {
        for (self.ops.items) |*op| op.deinit(self.gpa);
        self.ops.clearRetainingCapacity();
    }

    pub fn stageInsert(self: *Session, eng: *engine_mod.Engine, table_name: []const u8, values: []const value.Value) TxnError!void {
        try self.ensureExecutable();
        if (self.state != .active) return error.NoActiveTransaction;

        const table = eng.getTable(table_name) orelse return error.TableNotFound;
        try self.validateInsertAgainstWriteSet(table, values);

        const owned_table = try self.gpa.dupe(u8, table_name);
        errdefer self.gpa.free(owned_table);
        const owned_vals = try cloneValues(self.gpa, values);
        errdefer freeValues(self.gpa, owned_vals);

        try self.ops.append(self.gpa, .{ .insert = .{
            .table = owned_table,
            .values = owned_vals,
        } });
    }

    pub fn stageUpdate(self: *Session, eng: *engine_mod.Engine, table_name: []const u8, pk: value.Value, values: []const value.Value) TxnError!void {
        try self.ensureExecutable();
        if (self.state != .active) return error.NoActiveTransaction;

        const table = eng.getTable(table_name) orelse return error.TableNotFound;
        const pki = table.pk_index orelse return error.TxnRequiresPrimaryKey;
        if (!value.Value.eql(values[pki], pk)) return error.PrimaryKeyImmutable;
        if (self.visibleRow(table, table_name, pk) == null) return error.PrimaryKeyNotFound;
        try self.validateUniqueAgainstWriteSet(table, table_name, values, pk);

        const owned_table = try self.gpa.dupe(u8, table_name);
        errdefer self.gpa.free(owned_table);
        const owned_pk = try pk.clone(self.gpa);
        errdefer {
            var p = owned_pk;
            p.deinit(self.gpa);
        }
        const owned_vals = try cloneValues(self.gpa, values);
        errdefer freeValues(self.gpa, owned_vals);

        try self.ops.append(self.gpa, .{ .update = .{
            .table = owned_table,
            .pk = owned_pk,
            .values = owned_vals,
        } });
    }

    pub fn stageDelete(self: *Session, eng: *engine_mod.Engine, table_name: []const u8, pk: value.Value) TxnError!void {
        try self.ensureExecutable();
        if (self.state != .active) return error.NoActiveTransaction;

        const table = eng.getTable(table_name) orelse return error.TableNotFound;
        if (table.pk_index == null) return error.TxnRequiresPrimaryKey;
        if (self.visibleRow(table, table_name, pk) == null) return error.PrimaryKeyNotFound;

        const owned_table = try self.gpa.dupe(u8, table_name);
        errdefer self.gpa.free(owned_table);
        const owned_pk = try pk.clone(self.gpa);
        errdefer {
            var p = owned_pk;
            p.deinit(self.gpa);
        }

        try self.ops.append(self.gpa, .{ .delete = .{
            .table = owned_table,
            .pk = owned_pk,
        } });
    }

    /// Current visible values for `pk` under base table + this session's write set.
    /// Returned slice is borrowed from table storage or a write-set op; do not free.
    pub fn visibleRow(self: *const Session, table: *const table_mod.Table, table_name: []const u8, pk: value.Value) ?[]const value.Value {
        var current: ?[]const value.Value = null;
        if (table.pkLookup(pk)) |idx| {
            current = table.rows.items[idx].values;
        }
        for (self.ops.items) |op| {
            switch (op) {
                .insert => |ins| {
                    if (!std.ascii.eqlIgnoreCase(ins.table, table_name)) continue;
                    const pki = table.pk_index orelse continue;
                    if (value.Value.eql(ins.values[pki], pk)) current = ins.values;
                },
                .update => |upd| {
                    if (!std.ascii.eqlIgnoreCase(upd.table, table_name)) continue;
                    if (value.Value.eql(upd.pk, pk)) current = upd.values;
                },
                .delete => |del| {
                    if (!std.ascii.eqlIgnoreCase(del.table, table_name)) continue;
                    if (value.Value.eql(del.pk, pk)) current = null;
                },
            }
        }
        return current;
    }

    /// Collect owned visible rows for `table_name` (base ∪ write set). Caller frees via `freeVisibleRows`.
    pub fn collectVisibleRows(self: *const Session, gpa: Allocator, table: *const table_mod.Table, table_name: []const u8) Allocator.Error![]table_mod.Row {
        const pki = table.pk_index;

        // pk-keyed materialization when a primary key exists.
        if (pki != null) {
            var list: std.ArrayList(table_mod.Row) = .empty;
            errdefer freeVisibleRows(gpa, list.items);

            // Start from base rows.
            for (table.rows.items) |row| {
                try list.append(gpa, try row.clone(gpa));
            }

            for (self.ops.items) |op| {
                switch (op) {
                    .insert => |ins| {
                        if (!std.ascii.eqlIgnoreCase(ins.table, table_name)) continue;
                        try list.append(gpa, .{ .values = try cloneValues(gpa, ins.values) });
                    },
                    .update => |upd| {
                        if (!std.ascii.eqlIgnoreCase(upd.table, table_name)) continue;
                        const idx = findRowByPk(list.items, pki.?, upd.pk) orelse continue;
                        var old = list.items[idx];
                        old.deinit(gpa);
                        list.items[idx] = .{ .values = try cloneValues(gpa, upd.values) };
                    },
                    .delete => |del| {
                        if (!std.ascii.eqlIgnoreCase(del.table, table_name)) continue;
                        const idx = findRowByPk(list.items, pki.?, del.pk) orelse continue;
                        var old = list.items[idx];
                        old.deinit(gpa);
                        _ = list.swapRemove(idx);
                    },
                }
            }
            return try list.toOwnedSlice(gpa);
        }

        // No PK: write set cannot address rows; only base is visible.
        var list: std.ArrayList(table_mod.Row) = .empty;
        errdefer freeVisibleRows(gpa, list.items);
        for (table.rows.items) |row| {
            try list.append(gpa, try row.clone(gpa));
        }
        return try list.toOwnedSlice(gpa);
    }

    pub fn freeVisibleRows(gpa: Allocator, rows: []table_mod.Row) void {
        for (rows) |*r| r.deinit(gpa);
        gpa.free(rows);
    }

    fn findRowByPk(rows: []const table_mod.Row, pki: usize, pk: value.Value) ?usize {
        for (rows, 0..) |row, i| {
            if (value.Value.eql(row.values[pki], pk)) return i;
        }
        return null;
    }

    fn validateInsertAgainstWriteSet(self: *const Session, table: *const table_mod.Table, values: []const value.Value) TxnError!void {
        if (values.len != table.columns.len) return error.ColumnCountMismatch;
        try checkTypes(table, values);
        for (table.columns, 0..) |col, ci| {
            if (col.not_null and values[ci] == .null and !col.serial) return error.NotNullViolation;
        }

        if (table.pk_index) |pki| {
            const pk = values[pki];
            switch (pk) {
                .int, .text => {},
                else => return error.MissingPrimaryKey,
            }
            if (self.visibleRow(table, table.name, pk) != null) return error.DuplicatePrimaryKey;
        }
        try self.validateUniqueAgainstWriteSet(table, table.name, values, null);
    }

    fn validateUniqueAgainstWriteSet(
        self: *const Session,
        table: *const table_mod.Table,
        table_name: []const u8,
        values: []const value.Value,
        skip_pk: ?value.Value,
    ) TxnError!void {
        const pki = table.pk_index;
        var has_non_pk_unique = false;
        for (table.columns, 0..) |col, ci| {
            if (col.unique and (pki == null or ci != pki.?)) {
                has_non_pk_unique = true;
                break;
            }
        }
        // Primary-key conflicts are checked by visibleRow before this method.
        // Avoid materializing the full transaction view when no separate UNIQUE
        // constraint needs it.
        if (!has_non_pk_unique) return;

        if (pki == null) {
            for (table.columns, 0..) |col, ci| {
                if (!col.unique) continue;
                const v = values[ci];
                if (v == .null) continue;
                for (table.rows.items) |row| {
                    if (value.Value.eql(row.values[ci], v)) return error.UniqueViolation;
                }
                for (self.ops.items) |op| switch (op) {
                    .insert => |ins| {
                        if (std.ascii.eqlIgnoreCase(ins.table, table_name) and value.Value.eql(ins.values[ci], v)) return error.UniqueViolation;
                    },
                    else => {},
                };
            }
            return;
        }
        const rows = try self.collectVisibleRows(self.gpa, table, table_name);
        defer freeVisibleRows(self.gpa, rows);

        for (table.columns, 0..) |col, ci| {
            if (!col.unique or ci == pki.?) continue;
            const v = values[ci];
            if (v == .null) continue;
            for (rows) |row| {
                if (skip_pk) |spk| {
                    if (value.Value.eql(row.values[pki.?], spk)) continue;
                }
                if (value.Value.eql(row.values[ci], v)) return error.UniqueViolation;
            }
        }
    }

    fn checkTypes(table: *const table_mod.Table, values: []const value.Value) TxnError!void {
        if (values.len != table.columns.len) return error.ColumnCountMismatch;
        for (values, table.columns) |v, col| {
            switch (v) {
                .null => {},
                .int => if (col.type_tag != .int) return error.TypeMismatch,
                .text => if (col.type_tag != .text) return error.TypeMismatch,
                .bool => if (col.type_tag != .bool) return error.TypeMismatch,
            }
        }
    }
};

fn cloneValues(gpa: Allocator, values: []const value.Value) Allocator.Error![]value.Value {
    const out = try gpa.alloc(value.Value, values.len);
    errdefer gpa.free(out);
    var n: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < n) : (j += 1) out[j].deinit(gpa);
    }
    while (n < values.len) : (n += 1) {
        out[n] = try values[n].clone(gpa);
    }
    return out;
}

fn freeValues(gpa: Allocator, values: []value.Value) void {
    for (values) |*v| v.deinit(gpa);
    gpa.free(values);
}

test "session begin commit rollback state machine" {
    const gpa = std.testing.allocator;
    var session = Session.init(gpa);
    defer session.deinit();

    try std.testing.expect(session.state == .idle);
    try session.begin();
    try std.testing.expect(session.state == .active);
    try session.begin(); // nested no-op
    try std.testing.expect(session.state == .active);
    session.rollback();
    try std.testing.expect(session.state == .idle);

    try session.begin();
    session.fail();
    try std.testing.expect(session.state == .failed);
    try std.testing.expectError(error.InFailedTransaction, session.begin());
    session.rollback();
    try std.testing.expect(session.state == .idle);
}

test "session write set insert is private until commit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-txn-private";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();

    var cols = [_]value.Column{
        .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text },
    };
    defer for (&cols) |*c| c.deinit(gpa);
    try eng.createTable("t", &cols);

    var session = Session.init(gpa);
    defer session.deinit();
    try session.begin();

    var name: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
    defer name.deinit(gpa);
    try session.stageInsert(&eng, "t", &.{ .{ .int = 1 }, name });

    // Published table still empty.
    try std.testing.expectEqual(@as(usize, 0), eng.getTable("t").?.rows.items.len);
    // Session sees the row.
    const vis = session.visibleRow(eng.getTable("t").?, "t", .{ .int = 1 }).?;
    try std.testing.expectEqualStrings("alice", vis[1].text);

    try session.commit(&eng);
    try std.testing.expectEqual(@as(usize, 1), eng.getTable("t").?.rows.items.len);
    try std.testing.expect(session.state == .idle);
}

test "session rollback discards write set" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-txn-rollback";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();

    var cols = [_]value.Column{
        .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text },
    };
    defer for (&cols) |*c| c.deinit(gpa);
    try eng.createTable("t", &cols);

    var session = Session.init(gpa);
    defer session.deinit();
    try session.begin();
    var name: value.Value = .{ .text = try gpa.dupe(u8, "bob") };
    defer name.deinit(gpa);
    try session.stageInsert(&eng, "t", &.{ .{ .int = 1 }, name });
    session.rollback();

    try std.testing.expectEqual(@as(usize, 0), eng.getTable("t").?.rows.items.len);
    try std.testing.expect(session.visibleRow(eng.getTable("t").?, "t", .{ .int = 1 }) == null);
}

const Io = std.Io;
