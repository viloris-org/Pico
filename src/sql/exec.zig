const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("../storage/engine.zig");
const value = @import("../storage/value.zig");
const parse = @import("parse.zig");
const token = @import("token.zig");

pub const ExecError = parse.ParseError || error{
    ColumnNotFound,
    NotImplemented,
    TableExists,
    TableNotFound,
    ColumnCountMismatch,
    DuplicatePrimaryKey,
    MissingPrimaryKey,
    PrimaryKeyNotFound,
    PrimaryKeyImmutable,
    TypeMismatch,
};

pub const QueryResult = union(enum) {
    empty: []const u8, // command tag e.g. "CREATE TABLE"
    rows: Rows,

    pub const Rows = struct {
        /// Column names for RowDescription
        col_names: [][]const u8,
        /// Each row is a list of optional text cells (null = SQL NULL)
        cells: [][]?[]const u8,
        gpa: Allocator,
        /// Backing storage for text cells
        arena_data: std.ArrayList([]u8),

        pub fn deinit(self: *Rows) void {
            for (self.cells) |row| {
                self.gpa.free(row);
            }
            self.gpa.free(self.cells);
            self.gpa.free(self.col_names);
            for (self.arena_data.items) |s| self.gpa.free(s);
            self.arena_data.deinit(self.gpa);
        }
    };

    pub fn deinit(self: *QueryResult) void {
        switch (self.*) {
            .empty => {},
            .rows => |*r| r.deinit(),
        }
    }
};

pub fn execute(gpa: Allocator, eng: *engine_mod.Engine, sql: []const u8) !QueryResult {
    var parser = try parse.Parser.init(gpa, sql);
    var stmt = try parser.parseStatement();
    defer parse.freeStmt(gpa, &stmt);

    // Allow trailing empty / multiple only first for Phase 0
    return switch (stmt) {
        .empty => .{ .empty = "EMPTY" },
        .create_table => |ct| {
            try eng.createTable(ct.name, ct.columns);
            return .{ .empty = "CREATE TABLE" };
        },
        .insert => |ins| {
            try execInsert(gpa, eng, ins);
            return .{ .empty = "INSERT 0 1" };
        },
        .select => |sel| {
            return .{ .rows = try execSelect(gpa, eng, sel) };
        },
        .update => |upd| {
            try execUpdate(gpa, eng, upd);
            return .{ .empty = "UPDATE 1" };
        },
        .delete => |del| {
            try execDelete(eng, del);
            return .{ .empty = "DELETE 1" };
        },
    };
}

fn execInsert(gpa: Allocator, eng: *engine_mod.Engine, ins: parse.Insert) !void {
    const table = eng.getTable(ins.table) orelse return error.TableNotFound;

    if (ins.columns) |colnames| {
        // Map provided columns into table order
        const ordered = try gpa.alloc(value.Value, table.columns.len);
        defer {
            // insert() clones; free temps that weren't moved... we pass to insert which clones all
            for (ordered) |*v| v.deinit(gpa);
            gpa.free(ordered);
        }
        for (ordered) |*v| v.* = .null;

        if (colnames.len != ins.values.len) return error.ColumnCountMismatch;
        for (colnames, ins.values) |cname, val| {
            const idx = findColumn(table, cname) orelse return error.ColumnNotFound;
            // move value
            ordered[idx].deinit(gpa);
            ordered[idx] = try val.clone(gpa);
        }
        try eng.insert(ins.table, ordered);
    } else {
        try eng.insert(ins.table, ins.values);
    }
}

fn findColumn(table: *engine_mod.Table, name: []const u8) ?usize {
    for (table.columns, 0..) |c, i| {
        if (token.eqlIgnoreCase(c.name, name)) return i;
    }
    return null;
}

fn requirePkWhere(table: *engine_mod.Table, where_col: []const u8) !void {
    const widx = findColumn(table, where_col) orelse return error.ColumnNotFound;
    if (widx != table.pk_index) return error.NotImplemented;
}

fn execUpdate(gpa: Allocator, eng: *engine_mod.Engine, upd: parse.Update) !void {
    const table = eng.getTable(upd.table) orelse return error.TableNotFound;
    try requirePkWhere(table, upd.where_col);

    // Start from current row, apply SET clauses, then full-row update.
    const idx = table.by_pk.get(upd.where_pk) orelse return error.PrimaryKeyNotFound;
    const current = table.rows.items[idx];

    const ordered = try gpa.alloc(value.Value, table.columns.len);
    defer {
        for (ordered) |*v| v.deinit(gpa);
        gpa.free(ordered);
    }
    for (current.values, 0..) |v, i| {
        ordered[i] = try v.clone(gpa);
    }

    for (upd.sets) |set| {
        const cidx = findColumn(table, set.column) orelse return error.ColumnNotFound;
        if (cidx == table.pk_index) {
            // Allow `SET id = <same pk>` only.
            const new_pk = switch (set.value) {
                .int => |n| n,
                else => return error.PrimaryKeyImmutable,
            };
            if (new_pk != upd.where_pk) return error.PrimaryKeyImmutable;
            continue;
        }
        ordered[cidx].deinit(gpa);
        ordered[cidx] = try set.value.clone(gpa);
    }

    try eng.update(upd.table, upd.where_pk, ordered);
}

fn execDelete(eng: *engine_mod.Engine, del: parse.Delete) !void {
    const table = eng.getTable(del.table) orelse return error.TableNotFound;
    try requirePkWhere(table, del.where_col);
    try eng.delete(del.table, del.where_pk);
}

fn valueToText(gpa: Allocator, arena_data: *std.ArrayList([]u8), v: value.Value) !?[]const u8 {
    switch (v) {
        .null => return null,
        .text => |t| {
            // Always copy: source rows may be freed when SelectResult is dropped.
            const s = try gpa.dupe(u8, t);
            try arena_data.append(gpa, s);
            return s;
        },
        .bool => |b| return if (b) "t" else "f",
        .int => |n| {
            const s = try std.fmt.allocPrint(gpa, "{d}", .{n});
            try arena_data.append(gpa, s);
            return s;
        },
    }
}

fn execSelect(gpa: Allocator, eng: *engine_mod.Engine, sel: parse.Select) !QueryResult.Rows {
    const table = eng.getTable(sel.table) orelse return error.TableNotFound;

    // Resolve projection indices
    var proj: std.ArrayList(usize) = .empty;
    defer proj.deinit(gpa);
    if (sel.columns) |names| {
        for (names) |n| {
            const idx = findColumn(table, n) orelse return error.ColumnNotFound;
            try proj.append(gpa, idx);
        }
    } else {
        for (table.columns, 0..) |_, i| try proj.append(gpa, i);
    }

    if (sel.where_col) |wc| {
        const widx = findColumn(table, wc) orelse return error.ColumnNotFound;
        if (widx != table.pk_index) return error.NotImplemented; // only PK equality in Phase 0
    }

    var result_src = if (sel.where_pk) |pk|
        try eng.selectByPk(sel.table, pk)
    else
        try eng.selectAll(sel.table);
    defer result_src.deinit();

    const col_names = try gpa.alloc([]const u8, proj.items.len);
    errdefer gpa.free(col_names);
    for (proj.items, 0..) |pi, i| {
        col_names[i] = table.columns[pi].name;
    }

    var arena_data: std.ArrayList([]u8) = .empty;
    errdefer {
        for (arena_data.items) |s| gpa.free(s);
        arena_data.deinit(gpa);
    }

    var cells: std.ArrayList([]?[]const u8) = .empty;
    errdefer {
        for (cells.items) |row| gpa.free(row);
        cells.deinit(gpa);
    }

    for (result_src.rows) |row| {
        const line = try gpa.alloc(?[]const u8, proj.items.len);
        errdefer gpa.free(line);
        for (proj.items, 0..) |pi, i| {
            line[i] = try valueToText(gpa, &arena_data, row.values[pi]);
        }
        try cells.append(gpa, line);
    }

    return .{
        .col_names = col_names,
        .cells = try cells.toOwnedSlice(gpa),
        .gpa = gpa,
        .arena_data = arena_data,
    };
}

test "exec create insert select" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();

    var r1 = try execute(gpa, &eng, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
    defer r1.deinit();
    try std.testing.expect(r1 == .empty);

    var r2 = try execute(gpa, &eng, "INSERT INTO t (id, name) VALUES (1, 'bob')");
    defer r2.deinit();

    var r3 = try execute(gpa, &eng, "SELECT name FROM t WHERE id = 1");
    defer r3.deinit();
    try std.testing.expect(r3 == .rows);
    try std.testing.expectEqual(@as(usize, 1), r3.rows.cells.len);
    try std.testing.expectEqualStrings("bob", r3.rows.cells[0][0].?);

    var r4 = try execute(gpa, &eng, "UPDATE t SET name = 'bobby' WHERE id = 1");
    defer r4.deinit();
    try std.testing.expect(r4 == .empty);

    var r5 = try execute(gpa, &eng, "SELECT name FROM t WHERE id = 1");
    defer r5.deinit();
    try std.testing.expectEqualStrings("bobby", r5.rows.cells[0][0].?);

    var r6 = try execute(gpa, &eng, "DELETE FROM t WHERE id = 1");
    defer r6.deinit();

    var r7 = try execute(gpa, &eng, "SELECT name FROM t WHERE id = 1");
    defer r7.deinit();
    try std.testing.expectEqual(@as(usize, 0), r7.rows.cells.len);

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}

const Io = std.Io;
