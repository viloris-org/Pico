const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const wal_mod = @import("wal.zig");
const table_mod = @import("table.zig");

pub const EngineError = table_mod.Error;
pub const Row = table_mod.Row;
pub const Table = table_mod.Table;
pub const Pred = table_mod.Pred;
pub const ColumnSpec = table_mod.ColumnSpec;

/// Single-writer storage engine: in-memory tables + WAL.
/// Phase 0 has no SSTables yet. Table storage lives in `table.zig`;
/// this module owns durability ordering (validate → WAL append → apply).
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
            .set_default => |set| {
                const table = self.tables.getPtr(set.table) orelse return error.TableNotFound;
                try table.setDefault(self.gpa, set.column, set.default_expr);
            },
            .set_not_null => |set| {
                const table = self.tables.getPtr(set.table) orelse return error.TableNotFound;
                try table.setNotNull(set.column, set.enabled);
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
        if (self.tables.contains(name)) return;
        try self.createTable(name, columns);
    }

    pub fn addColumn(self: *Engine, table_name: []const u8, column: value.Column, if_not_exists: bool) !void {
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
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        _ = table.columnIndex(name) orelse return error.ColumnNotFound;
        try self.wal.appendSetDefault(.{ .table = table_name, .column = name, .default_expr = default_expr });
        try table.setDefault(self.gpa, name, default_expr);
    }

    pub fn setNotNull(self: *Engine, table_name: []const u8, name: []const u8, enabled: bool) !void {
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
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try table.validateInsert(values);
        try self.wal.appendInsert(.{ .table = table_name, .values = values });
        try table.insert(self.gpa, values);
    }

    pub fn update(self: *Engine, table_name: []const u8, pk: value.Value, values: []const value.Value) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        try table.validateUpdate(pk, values);
        try self.wal.appendUpdate(.{ .table = table_name, .pk = pk, .values = values });
        try table.update(self.gpa, pk, values);
    }

    /// Update by current row index; WAL records full row with PK when present, else uses int index as pseudo-pk for replay.
    pub fn updateAt(self: *Engine, table_name: []const u8, idx: usize, values: []const value.Value) !void {
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
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        if (!table.pkContains(pk)) return error.PrimaryKeyNotFound;

        try self.wal.appendDelete(.{ .table = table_name, .pk = pk });
        try table.delete(self.gpa, pk);
    }

    pub fn deleteAt(self: *Engine, table_name: []const u8, idx: usize) !void {
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
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        return table.allocSerial();
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
