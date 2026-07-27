const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const wal_mod = @import("wal.zig");
const token = @import("../sql/token.zig");

pub const EngineError = error{
    TableExists,
    TableNotFound,
    ColumnCountMismatch,
    DuplicatePrimaryKey,
    MissingPrimaryKey,
    PrimaryKeyNotFound,
    PrimaryKeyImmutable,
    TypeMismatch,
    InvalidIdentifier,
    NotNullViolation,
    UniqueViolation,
};

pub const Row = struct {
    values: []value.Value,

    pub fn deinit(self: *Row, gpa: Allocator) void {
        for (self.values) |*v| v.deinit(gpa);
        gpa.free(self.values);
    }

    pub fn clone(self: Row, gpa: Allocator) Allocator.Error!Row {
        const vals = try gpa.alloc(value.Value, self.values.len);
        errdefer gpa.free(vals);
        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) vals[j].deinit(gpa);
        }
        while (i < self.values.len) : (i += 1) {
            vals[i] = try self.values[i].clone(gpa);
        }
        return .{ .values = vals };
    }
};

pub const Table = struct {
    name: []u8,
    columns: []value.Column,
    /// null = heap table without single-column PK (e.g. composite PRIMARY KEY).
    pk_index: ?usize,
    /// INT primary key → row index.
    by_pk_int: std.AutoHashMap(i64, usize),
    /// TEXT primary key → row index (keys owned by row storage).
    by_pk_text: std.StringHashMap(usize),
    rows: std.ArrayList(Row),
    /// Next value for SERIAL/BIGSERIAL columns.
    next_serial: i64,

    pub fn deinit(self: *Table, gpa: Allocator) void {
        gpa.free(self.name);
        for (self.columns) |*c| c.deinit(gpa);
        gpa.free(self.columns);
        for (self.rows.items) |*r| r.deinit(gpa);
        self.rows.deinit(gpa);
        self.by_pk_int.deinit();
        self.by_pk_text.deinit();
    }

    pub fn pkIsText(self: *const Table) bool {
        const pki = self.pk_index orelse return false;
        return self.columns[pki].type_tag == .text;
    }
};

/// Single-writer storage engine: memtable + WAL. Phase 0 has no SSTables yet.
pub const Engine = struct {
    gpa: Allocator,
    io: Io,
    wal: wal_mod.Wal,
    tables: std.StringHashMap(Table),

    pub fn open(gpa: Allocator, io: Io, data_dir: []const u8, sync_wal: bool) !Engine {
        var eng: Engine = .{
            .gpa = gpa,
            .io = io,
            .wal = try wal_mod.Wal.open(gpa, io, data_dir, sync_wal),
            .tables = std.StringHashMap(Table).init(gpa),
        };
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
        self.wal.deinit();
        self.* = undefined;
    }

    fn recover(self: *Engine) !void {
        try wal_mod.replayWal(&self.wal, self, applyRecord);
    }

    fn applyRecord(self: *Engine, view: wal_mod.RecordView) !void {
        switch (view) {
            .create_table => |ct| {
                try self.createTableMem(ct.name, ct.columns);
            },
            .insert => |ins| {
                try self.insertMem(ins.table, ins.values);
            },
            .update => |upd| {
                const table = self.tables.getPtr(upd.table) orelse return error.TableNotFound;
                if (table.pk_index != null) {
                    try self.updateMem(upd.table, upd.pk, upd.values);
                } else {
                    const idx: usize = switch (upd.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    try self.updateMemAt(upd.table, idx, upd.values);
                }
            },
            .delete => |del| {
                const table = self.tables.getPtr(del.table) orelse return error.TableNotFound;
                if (table.pk_index != null) {
                    try self.deleteMem(del.table, del.pk);
                } else {
                    const idx: usize = switch (del.pk) {
                        .int => |i| @intCast(i),
                        else => return error.PrimaryKeyNotFound,
                    };
                    try self.deleteMemAt(del.table, idx);
                }
            },
        }
    }

    fn createTableMem(self: *Engine, name: []const u8, cols: []const wal_mod.RecordView.ParsedColumn) !void {
        try self.validateCreateTable(name, cols);

        var pk_index: ?usize = null;
        const columns = try self.gpa.alloc(value.Column, cols.len);
        errdefer self.gpa.free(columns);
        var allocated: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < allocated) : (j += 1) columns[j].deinit(self.gpa);
        }
        for (cols, 0..) |c, i| {
            columns[i] = .{
                .name = try self.gpa.dupe(u8, c.name),
                .type_tag = c.type_tag,
                .primary_key = c.primary_key,
                .not_null = c.not_null,
                .unique = c.unique,
                .serial = c.serial,
                .default_expr = try c.default_expr.clone(self.gpa),
            };
            allocated = i + 1;
            if (c.primary_key) {
                if (pk_index != null) return error.MissingPrimaryKey; // multiple column-level PKs not supported
                if (c.type_tag != .int and c.type_tag != .text) return error.TypeMismatch;
                pk_index = i;
            }
        }

        const tname = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(tname);

        var table: Table = .{
            .name = tname,
            .columns = columns,
            .pk_index = pk_index,
            .by_pk_int = std.AutoHashMap(i64, usize).init(self.gpa),
            .by_pk_text = std.StringHashMap(usize).init(self.gpa),
            .rows = .empty,
            .next_serial = 1,
        };
        errdefer table.deinit(self.gpa);

        try self.tables.put(tname, table);
    }

    fn validateCreateTable(
        self: *const Engine,
        name: []const u8,
        cols: []const wal_mod.RecordView.ParsedColumn,
    ) !void {
        if (self.tables.contains(name)) return error.TableExists;
        if (cols.len == 0) return error.MissingPrimaryKey;

        var primary_key_count: usize = 0;
        for (cols) |col| {
            if (!col.primary_key) continue;
            primary_key_count += 1;
            if (col.type_tag != .int and col.type_tag != .text) return error.TypeMismatch;
        }
        if (primary_key_count > 1) return error.MissingPrimaryKey;
    }

    fn checkTypes(table: *const Table, values: []const value.Value) !void {
        if (values.len != table.columns.len) return error.ColumnCountMismatch;
        for (values, table.columns) |v, col| {
            switch (v) {
                .null => {
                    if (col.not_null and !col.serial) return error.NotNullViolation;
                },
                .int => if (col.type_tag != .int) return error.TypeMismatch,
                .text => if (col.type_tag != .text) return error.TypeMismatch,
                .bool => if (col.type_tag != .bool) return error.TypeMismatch,
            }
        }
    }

    fn pkLookup(table: *const Table, pk: value.Value) ?usize {
        return switch (pk) {
            .int => |i| table.by_pk_int.get(i),
            .text => |t| table.by_pk_text.get(t),
            else => null,
        };
    }

    fn pkContains(table: *const Table, pk: value.Value) bool {
        return pkLookup(table, pk) != null;
    }

    fn pkPut(table: *Table, pk: value.Value, idx: usize) !void {
        switch (pk) {
            .int => |i| try table.by_pk_int.put(i, idx),
            .text => |t| try table.by_pk_text.put(t, idx),
            else => return error.MissingPrimaryKey,
        }
    }

    fn pkRemove(table: *Table, pk: value.Value) void {
        switch (pk) {
            .int => |i| _ = table.by_pk_int.remove(i),
            .text => |t| _ = table.by_pk_text.remove(t),
            else => {},
        }
    }

    fn checkUnique(table: *const Table, values: []const value.Value, skip_idx: ?usize) !void {
        for (table.columns, 0..) |col, ci| {
            if (!col.unique and !col.primary_key) continue;
            const v = values[ci];
            if (v == .null) continue;
            for (table.rows.items, 0..) |row, ri| {
                if (skip_idx) |s| if (s == ri) continue;
                if (value.Value.eql(row.values[ci], v)) return error.UniqueViolation;
            }
        }
    }

    fn validateInsert(table: *const Table, values: []const value.Value) !void {
        try checkTypes(table, values);
        if (table.pk_index) |pk_index| {
            const pk = values[pk_index];
            switch (pk) {
                .int, .text => {},
                else => return error.MissingPrimaryKey,
            }
            if (pkContains(table, pk)) return error.DuplicatePrimaryKey;
        }
        try checkUnique(table, values, null);
    }

    fn validateUpdate(table: *const Table, pk: value.Value, values: []const value.Value) !void {
        try checkTypes(table, values);
        const pk_index = table.pk_index orelse return error.MissingPrimaryKey;
        if (!value.Value.eql(values[pk_index], pk)) return error.PrimaryKeyImmutable;
        const idx = pkLookup(table, pk) orelse return error.PrimaryKeyNotFound;
        try checkUnique(table, values, idx);
    }

    fn insertMem(self: *Engine, table_name: []const u8, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try validateInsert(table, values);

        const owned_vals = try self.gpa.alloc(value.Value, values.len);
        errdefer self.gpa.free(owned_vals);
        var n: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < n) : (j += 1) owned_vals[j].deinit(self.gpa);
        }
        while (n < values.len) : (n += 1) {
            owned_vals[n] = try values[n].clone(self.gpa);
        }

        const idx = table.rows.items.len;
        try table.rows.append(self.gpa, .{ .values = owned_vals });
        errdefer {
            var row = table.rows.pop().?;
            row.deinit(self.gpa);
        }
        if (table.pk_index) |pki| {
            const stored_pk = table.rows.items[idx].values[pki];
            try pkPut(table, stored_pk, idx);
            if (stored_pk == .int) {
                if (stored_pk.int >= table.next_serial) table.next_serial = stored_pk.int + 1;
            }
        }
        for (table.columns, 0..) |col, ci| {
            if (col.serial and values[ci] == .int) {
                if (values[ci].int >= table.next_serial) table.next_serial = values[ci].int + 1;
            }
        }
    }

    fn updateMem(self: *Engine, table_name: []const u8, pk: value.Value, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try validateUpdate(table, pk, values);
        const pki = table.pk_index.?;
        const idx = pkLookup(table, pk).?;

        const owned_vals = try self.gpa.alloc(value.Value, values.len);
        errdefer self.gpa.free(owned_vals);
        var n: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < n) : (j += 1) owned_vals[j].deinit(self.gpa);
        }
        while (n < values.len) : (n += 1) {
            owned_vals[n] = try values[n].clone(self.gpa);
        }

        pkRemove(table, pk);

        var old = table.rows.items[idx];
        old.deinit(self.gpa);
        table.rows.items[idx] = .{ .values = owned_vals };
        try pkPut(table, table.rows.items[idx].values[pki], idx);
    }

    /// Replace row at stable index (for tables without single-column PK, or by-index updates).
    fn updateMemAt(self: *Engine, table_name: []const u8, idx: usize, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (idx >= table.rows.items.len) return error.PrimaryKeyNotFound;
        try checkTypes(table, values);
        try checkUnique(table, values, idx);

        if (table.pk_index) |pki| {
            const old_pk = table.rows.items[idx].values[pki];
            const new_pk = values[pki];
            if (!value.Value.eql(old_pk, new_pk)) return error.PrimaryKeyImmutable;
            pkRemove(table, old_pk);
        }

        const owned_vals = try self.gpa.alloc(value.Value, values.len);
        errdefer self.gpa.free(owned_vals);
        var n: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < n) : (j += 1) owned_vals[j].deinit(self.gpa);
        }
        while (n < values.len) : (n += 1) {
            owned_vals[n] = try values[n].clone(self.gpa);
        }

        var old = table.rows.items[idx];
        old.deinit(self.gpa);
        table.rows.items[idx] = .{ .values = owned_vals };
        if (table.pk_index) |pki| {
            try pkPut(table, table.rows.items[idx].values[pki], idx);
        }
    }

    fn deleteMem(self: *Engine, table_name: []const u8, pk: value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const idx = pkLookup(table, pk) orelse return error.PrimaryKeyNotFound;
        try self.deleteMemAt(table_name, idx);
    }

    fn deleteMemAt(self: *Engine, table_name: []const u8, idx: usize) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (idx >= table.rows.items.len) return error.PrimaryKeyNotFound;

        if (table.pk_index) |pki| {
            pkRemove(table, table.rows.items[idx].values[pki]);
        }

        const last = table.rows.items.len - 1;
        var removed = table.rows.items[idx];
        if (idx != last) {
            const moved = table.rows.items[last];
            table.rows.items[idx] = moved;
            if (table.pk_index) |pki| {
                try pkPut(table, moved.values[pki], idx);
            }
        }
        _ = table.rows.pop();
        removed.deinit(self.gpa);
    }

    pub fn createTable(self: *Engine, name: []const u8, columns: []const value.Column) !void {
        var parsed: std.ArrayList(wal_mod.RecordView.ParsedColumn) = .empty;
        defer {
            for (parsed.items) |*c| c.default_expr.deinit(self.gpa);
            parsed.deinit(self.gpa);
        }
        for (columns) |c| {
            try parsed.append(self.gpa, .{
                .name = c.name,
                .type_tag = c.type_tag,
                .primary_key = c.primary_key,
                .not_null = c.not_null,
                .unique = c.unique,
                .serial = c.serial,
                .default_expr = try c.default_expr.clone(self.gpa),
            });
        }
        try self.validateCreateTable(name, parsed.items);
        try self.wal.appendCreateTable(.{ .name = name, .columns = columns });
        try self.createTableMem(name, parsed.items);
    }

    pub fn createTableIfNotExists(self: *Engine, name: []const u8, columns: []const value.Column) !void {
        if (self.tables.contains(name)) return;
        try self.createTable(name, columns);
    }

    pub fn insert(self: *Engine, table_name: []const u8, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try validateInsert(table, values);
        try self.wal.appendInsert(.{ .table = table_name, .values = values });
        try self.insertMem(table_name, values);
    }

    pub fn update(self: *Engine, table_name: []const u8, pk: value.Value, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try validateUpdate(table, pk, values);

        try self.wal.appendUpdate(.{ .table = table_name, .pk = pk, .values = values });
        try self.updateMem(table_name, pk, values);
    }

    /// Update by current row index; WAL records full row with PK when present, else uses int index as pseudo-pk for replay.
    pub fn updateAt(self: *Engine, table_name: []const u8, idx: usize, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (idx >= table.rows.items.len) return error.PrimaryKeyNotFound;
        try checkTypes(table, values);
        if (table.pk_index) |pki| {
            const pk = table.rows.items[idx].values[pki];
            try validateUpdate(table, pk, values);
            try self.wal.appendUpdate(.{ .table = table_name, .pk = pk, .values = values });
            try self.updateMem(table_name, pk, values);
        } else {
            try checkUnique(table, values, idx);
            // No single-column PK: persist with synthetic int key = row index at write time.
            // Recovery applies as insert-like replace via updateMemAt path encoded as update with int pk=idx.
            try self.wal.appendUpdate(.{ .table = table_name, .pk = .{ .int = @intCast(idx) }, .values = values });
            try self.updateMemAt(table_name, idx, values);
        }
    }

    pub fn delete(self: *Engine, table_name: []const u8, pk: value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (!pkContains(table, pk)) return error.PrimaryKeyNotFound;

        try self.wal.appendDelete(.{ .table = table_name, .pk = pk });
        try self.deleteMem(table_name, pk);
    }

    pub fn deleteAt(self: *Engine, table_name: []const u8, idx: usize) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (idx >= table.rows.items.len) return error.PrimaryKeyNotFound;
        if (table.pk_index) |pki| {
            const pk = table.rows.items[idx].values[pki];
            try self.wal.appendDelete(.{ .table = table_name, .pk = pk });
            try self.deleteMem(table_name, pk);
        } else {
            try self.wal.appendDelete(.{ .table = table_name, .pk = .{ .int = @intCast(idx) } });
            try self.deleteMemAt(table_name, idx);
        }
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
        if (pkLookup(table, pk)) |idx| {
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
        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(self.gpa);

        // Fast path: single PK equality
        if (preds.len == 1 and preds[0] == .eq) {
            if (table.pk_index) |pki| {
                const p = preds[0].eq;
                if (p.col_index == pki and p.value == .int and !table.pkIsText()) {
                    if (table.by_pk_int.get(p.value.int)) |idx| {
                        try out.append(self.gpa, idx);
                    }
                    return try out.toOwnedSlice(self.gpa);
                }
                if (p.col_index == pki and p.value == .text and table.pkIsText()) {
                    if (table.by_pk_text.get(p.value.text)) |idx| {
                        try out.append(self.gpa, idx);
                    }
                    return try out.toOwnedSlice(self.gpa);
                }
            }
        }

        for (table.rows.items, 0..) |row, idx| {
            if (rowMatches(row, preds)) {
                try out.append(self.gpa, idx);
            }
        }
        return try out.toOwnedSlice(self.gpa);
    }

    pub fn getTable(self: *Engine, name: []const u8) ?*Table {
        return self.tables.getPtr(name);
    }

    pub fn allocSerial(self: *Engine, table_name: []const u8) !i64 {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const id = table.next_serial;
        table.next_serial += 1;
        return id;
    }
};

/// Execution-layer predicate bound to column indices.
pub const Pred = union(enum) {
    eq: struct {
        col_index: usize,
        value: value.Value, // borrowed during match
    },
    is_null: struct {
        col_index: usize,
        negated: bool,
    },
};

fn rowMatches(row: Row, preds: []const Pred) bool {
    for (preds) |p| {
        switch (p) {
            .eq => |e| {
                if (!value.Value.eql(row.values[e.col_index], e.value)) return false;
            },
            .is_null => |n| {
                const is_null = row.values[n.col_index] == .null;
                if (n.negated) {
                    if (is_null) return false;
                } else {
                    if (!is_null) return false;
                }
            },
        }
    }
    return true;
}

test "engine create insert select roundtrip with wal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = "zig-cache/pico-test-engine";
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
    const dir_name = "zig-cache/pico-test-engine-ud";
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
    const dir_name = "zig-cache/pico-test-engine-preflight";
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
test "engine recovers only the committed prefix after a torn wal tail" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-engine-torn";
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

// silence unused import if token only needed for eql in future
comptime {
    _ = token;
}
