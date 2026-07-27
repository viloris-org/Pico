const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const wal_mod = @import("wal.zig");

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
    pk_index: usize,
    /// Primary key (int) -> row index in `rows`. Phase 0: INT PK only.
    by_pk: std.AutoHashMap(i64, usize),
    rows: std.ArrayList(Row),

    pub fn deinit(self: *Table, gpa: Allocator) void {
        gpa.free(self.name);
        for (self.columns) |*c| c.deinit(gpa);
        gpa.free(self.columns);
        for (self.rows.items) |*r| r.deinit(gpa);
        self.rows.deinit(gpa);
        self.by_pk.deinit();
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
                try self.updateMem(upd.table, upd.pk, upd.values);
            },
            .delete => |del| {
                try self.deleteMem(del.table, del.pk);
            },
        }
    }

    fn createTableMem(self: *Engine, name: []const u8, cols: []const wal_mod.RecordView.ParsedColumn) !void {
        if (self.tables.contains(name)) return error.TableExists;
        if (cols.len == 0) return error.MissingPrimaryKey;

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
            };
            allocated = i + 1;
            if (c.primary_key) {
                if (pk_index != null) return error.MissingPrimaryKey; // multiple PKs not supported
                if (c.type_tag != .int) return error.TypeMismatch;
                pk_index = i;
            }
        }
        const pk = pk_index orelse return error.MissingPrimaryKey;

        const tname = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(tname);

        var table: Table = .{
            .name = tname,
            .columns = columns,
            .pk_index = pk,
            .by_pk = std.AutoHashMap(i64, usize).init(self.gpa),
            .rows = .empty,
        };
        errdefer table.deinit(self.gpa);

        try self.tables.put(tname, table);
    }

    fn insertMem(self: *Engine, table_name: []const u8, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (values.len != table.columns.len) return error.ColumnCountMismatch;

        // Type check
        for (values, table.columns) |v, col| {
            switch (v) {
                .null => {},
                .int => if (col.type_tag != .int) return error.TypeMismatch,
                .text => if (col.type_tag != .text) return error.TypeMismatch,
                .bool => if (col.type_tag != .bool) return error.TypeMismatch,
            }
        }

        const pk_val = values[table.pk_index];
        const pk = switch (pk_val) {
            .int => |i| i,
            else => return error.MissingPrimaryKey,
        };
        if (table.by_pk.contains(pk)) return error.DuplicatePrimaryKey;

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
        try table.by_pk.put(pk, idx);
    }

    fn checkTypes(table: *const Table, values: []const value.Value) !void {
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

    fn updateMem(self: *Engine, table_name: []const u8, pk: i64, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try checkTypes(table, values);

        // Primary key value in the row must match the addressed pk (immutable PK).
        const row_pk = switch (values[table.pk_index]) {
            .int => |i| i,
            else => return error.MissingPrimaryKey,
        };
        if (row_pk != pk) return error.PrimaryKeyImmutable;

        const idx = table.by_pk.get(pk) orelse return error.PrimaryKeyNotFound;

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
    }

    fn deleteMem(self: *Engine, table_name: []const u8, pk: i64) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const idx = table.by_pk.get(pk) orelse return error.PrimaryKeyNotFound;

        _ = table.by_pk.remove(pk);

        const last = table.rows.items.len - 1;
        var removed = table.rows.items[idx];
        if (idx != last) {
            const moved = table.rows.items[last];
            table.rows.items[idx] = moved;
            // Fix PK index for the swapped-in row.
            const moved_pk = switch (moved.values[table.pk_index]) {
                .int => |i| i,
                else => return error.MissingPrimaryKey,
            };
            try table.by_pk.put(moved_pk, idx);
        }
        _ = table.rows.pop();
        removed.deinit(self.gpa);
    }

    pub fn createTable(self: *Engine, name: []const u8, columns: []const value.Column) !void {
        // Convert to ParsedColumn view for mem path + WAL
        var parsed: std.ArrayList(wal_mod.RecordView.ParsedColumn) = .empty;
        defer parsed.deinit(self.gpa);
        for (columns) |c| {
            try parsed.append(self.gpa, .{
                .name = c.name,
                .type_tag = c.type_tag,
                .primary_key = c.primary_key,
            });
        }
        // Persist first, then mem (crash between is ok — replay creates table)
        try self.wal.appendCreateTable(.{ .name = name, .columns = columns });
        try self.createTableMem(name, parsed.items);
    }

    pub fn insert(self: *Engine, table_name: []const u8, values: []const value.Value) !void {
        try self.wal.appendInsert(.{ .table = table_name, .values = values });
        try self.insertMem(table_name, values);
    }

    /// Replace a full row addressed by primary key. `values` must include the PK column
    /// with the same key (PK changes are not supported).
    pub fn update(self: *Engine, table_name: []const u8, pk: i64, values: []const value.Value) !void {
        // Validate before durable write so recovery never sees a doomed record.
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try checkTypes(table, values);
        const row_pk = switch (values[table.pk_index]) {
            .int => |i| i,
            else => return error.MissingPrimaryKey,
        };
        if (row_pk != pk) return error.PrimaryKeyImmutable;
        if (!table.by_pk.contains(pk)) return error.PrimaryKeyNotFound;

        try self.wal.appendUpdate(.{ .table = table_name, .pk = pk, .values = values });
        try self.updateMem(table_name, pk, values);
    }

    pub fn delete(self: *Engine, table_name: []const u8, pk: i64) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (!table.by_pk.contains(pk)) return error.PrimaryKeyNotFound;

        try self.wal.appendDelete(.{ .table = table_name, .pk = pk });
        try self.deleteMem(table_name, pk);
    }

    pub const SelectResult = struct {
        columns: []const value.Column,
        /// Borrowed row pointers into table storage — valid until next mutate.
        rows: []const Row,
        /// If non-null, caller owns and must free this slice (filtered copy of pointers... actually we use owned list of indices).
        owned_rows: ?[]Row,
        gpa: Allocator,

        pub fn deinit(self: *SelectResult) void {
            if (self.owned_rows) |rows| {
                // These are clones
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

    pub fn selectByPk(self: *Engine, table_name: []const u8, pk: i64) !SelectResult {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (table.by_pk.get(pk)) |idx| {
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

    pub fn getTable(self: *Engine, name: []const u8) ?*Table {
        return self.tables.getPtr(name);
    }
};

test "engine create insert select roundtrip with wal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = "zig-cache/pico-test-engine";
    // Clean slate
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();

        var cols = [_]value.Column{
            .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
            .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text, .primary_key = false },
        };
        // createTable clones via WAL path — but columns are borrowed for WAL write then createTableMem clones.
        // Our createTable uses columns for WAL (names as slices) and createTableMem clones.
        // After createTable, original cols names are still ours.
        defer {
            for (&cols) |*c| c.deinit(gpa);
        }

        try eng.createTable("users", &cols);
        var name_val: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
        defer name_val.deinit(gpa);
        const vals = [_]value.Value{ .{ .int = 1 }, name_val };
        try eng.insert("users", &vals);

        var res = try eng.selectByPk("users", 1);
        defer res.deinit();
        try std.testing.expectEqual(@as(usize, 1), res.rows.len);
        try std.testing.expectEqualStrings("alice", res.rows[0].values[1].text);
    }

    // Reopen — recovery
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
        try eng.update("users", 2, &[_]value.Value{ .{ .int = 2 }, bob2 });
        try eng.delete("users", 1);

        var res = try eng.selectByPk("users", 2);
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

        var r2 = try eng.selectByPk("users", 2);
        defer r2.deinit();
        try std.testing.expectEqualStrings("bobby", r2.rows[0].values[1].text);

        var r1 = try eng.selectByPk("users", 1);
        defer r1.deinit();
        try std.testing.expectEqual(@as(usize, 0), r1.rows.len);
    }

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}
