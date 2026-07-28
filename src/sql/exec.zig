const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("../storage/engine.zig");
const value = @import("../storage/value.zig");
const parse = @import("parse.zig");
const token = @import("token.zig");
const session_mod = @import("../txn/session.zig");

pub const Session = session_mod.Session;

pub const ExecError = parse.ParseError || session_mod.TxnError || error{
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
    NotNullViolation,
    UniqueViolation,
    ColumnExists,
    CannotDropPrimaryKey,
    /// Catalog DDL inside an explicit transaction is not in this slice.
    DdlInTransaction,
};

pub const QueryResult = union(enum) {
    empty: []const u8, // command tag e.g. "CREATE TABLE"
    rows: Rows,

    pub const Rows = struct {
        col_names: [][]const u8,
        cells: [][]?[]const u8,
        gpa: Allocator,
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

/// Execute a single SQL statement (or the first if multiple). Prefer `executeScript` for multi-stmt.
pub fn execute(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, sql: []const u8) !QueryResult {
    var results = try executeScript(gpa, eng, session, sql);
    defer {
        // free all but last if we transfer last
        if (results.len > 1) {
            for (results[0 .. results.len - 1]) |*r| r.deinit();
        }
        gpa.free(results);
    }
    if (results.len == 0) return .{ .empty = "EMPTY" };
    const last = results[results.len - 1];
    // prevent defer from freeing last
    results[results.len - 1] = .{ .empty = "EMPTY" };
    return last;
}

/// Execute all statements in a script; returns one result per non-empty statement.
pub fn executeScript(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, sql: []const u8) ![]QueryResult {
    var parser = try parse.Parser.init(gpa, sql);
    defer parser.deinit();

    var out: std.ArrayList(QueryResult) = .empty;
    errdefer {
        for (out.items) |*r| r.deinit();
        out.deinit(gpa);
    }

    while (true) {
        var stmt = try parser.parseStatement();
        defer parse.freeStmt(gpa, &stmt);
        if (stmt == .empty) break;
        try out.append(gpa, try execStmt(gpa, eng, session, stmt));
    }

    if (out.items.len == 0) {
        try out.append(gpa, .{ .empty = "EMPTY" });
    }
    return try out.toOwnedSlice(gpa);
}

fn execStmt(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, stmt: parse.Stmt) !QueryResult {
    // ROLLBACK is the only statement allowed in a failed transaction.
    if (stmt == .rollback_tx) {
        session.rollback();
        return .{ .empty = "ROLLBACK" };
    }

    return execStmtBody(gpa, eng, session, stmt) catch |err| {
        // Statement errors abort an explicit transaction; autocommit stays idle.
        session.fail();
        return err;
    };
}

fn execStmtBody(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, stmt: parse.Stmt) !QueryResult {
    switch (stmt) {
        .empty => return .{ .empty = "EMPTY" },
        .begin_tx => {
            try session.begin();
            return .{ .empty = "BEGIN" };
        },
        .commit_tx => {
            try session.commit(eng);
            return .{ .empty = "COMMIT" };
        },
        .rollback_tx => {
            session.rollback();
            return .{ .empty = "ROLLBACK" };
        },
        .create_index => return error.NotImplemented,
        else => {},
    }

    try session.ensureExecutable();

    // Catalog DDL is autocommit-only in this slice (no DDL write-set yet).
    if (session.state == .active) {
        switch (stmt) {
            .create_table, .alter_table, .create_index => return error.DdlInTransaction,
            else => {},
        }
    }

    return switch (stmt) {
        .empty, .begin_tx, .commit_tx, .rollback_tx, .create_index => unreachable,
        .create_table => |ct| {
            if (ct.if_not_exists) {
                try eng.createTableIfNotExists(ct.name, ct.columns);
            } else {
                try eng.createTable(ct.name, ct.columns);
            }
            return .{ .empty = "CREATE TABLE" };
        },
        .alter_table => |at| {
            switch (at.action) {
                .add_column => |add| try eng.addColumn(at.table, add.column, add.if_not_exists),
                .drop_column => |drop| try eng.dropColumn(at.table, drop.name, drop.if_exists),
                .set_default => |set| try eng.setDefault(at.table, set.column, set.default_expr),
                .drop_default => |drop| try eng.setDefault(at.table, drop.column, .none),
                .set_not_null => |set| try eng.setNotNull(at.table, set.column, true),
                .drop_not_null => |drop| try eng.setNotNull(at.table, drop.column, false),
            }
            return .{ .empty = "ALTER TABLE" };
        },
        .insert => |ins| {
            const n = try execInsert(gpa, eng, session, ins);
            return .{ .empty = try formatTag(gpa, "INSERT 0 {d}", .{n}) };
        },
        .select => |sel| {
            return .{ .rows = try execSelect(gpa, eng, session, sel) };
        },
        .update => |upd| {
            const n = try execUpdate(gpa, eng, session, upd);
            return .{ .empty = try formatTag(gpa, "UPDATE {d}", .{n}) };
        },
        .delete => |del| {
            const n = try execDelete(gpa, eng, session, del);
            return .{ .empty = try formatTag(gpa, "DELETE {d}", .{n}) };
        },
    };
}

// Leaked command tags for dynamic counts — reclaimed only process-end. Prefer arena in protocol later.
var tag_arena: std.heap.ArenaAllocator = undefined;
var tag_arena_init = false;

fn formatTag(gpa: Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    _ = gpa;
    if (!tag_arena_init) {
        tag_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        tag_arena_init = true;
    }
    return std.fmt.allocPrint(tag_arena.allocator(), fmt, args);
}

fn findColumn(table: *engine_mod.Table, name: []const u8) ?usize {
    for (table.columns, 0..) |c, i| {
        if (token.eqlIgnoreCase(c.name, name)) return i;
    }
    return null;
}

fn bindPreds(gpa: Allocator, table: *engine_mod.Table, preds: []const parse.Predicate) ![]engine_mod.Pred {
    const out = try gpa.alloc(engine_mod.Pred, preds.len);
    errdefer gpa.free(out);
    for (preds, 0..) |p, i| {
        out[i] = switch (p) {
            .eq => |e| blk: {
                const idx = findColumn(table, e.column) orelse return error.ColumnNotFound;
                break :blk .{ .eq = .{ .col_index = idx, .value = e.value } };
            },
            .is_null => |n| blk: {
                const idx = findColumn(table, n.column) orelse return error.ColumnNotFound;
                break :blk .{ .is_null = .{ .col_index = idx, .negated = n.negated } };
            },
        };
    }
    return out;
}

fn coerceForColumn(col: value.Column, v: value.Value, gpa: Allocator) !value.Value {
    // Allow int literal into text column (e.g. status codes stored as varchar) — stringify.
    // Allow float-text into text. Allow int into int.
    switch (v) {
        .null => return .null,
        .int => |n| {
            if (col.type_tag == .int) return .{ .int = n };
            if (col.type_tag == .text) {
                const s = try std.fmt.allocPrint(gpa, "{d}", .{n});
                return .{ .text = s };
            }
            return error.TypeMismatch;
        },
        .text => |t| {
            if (col.type_tag == .text) return .{ .text = try gpa.dupe(u8, t) };
            if (col.type_tag == .int) {
                const n = std.fmt.parseInt(i64, t, 10) catch return error.TypeMismatch;
                return .{ .int = n };
            }
            return error.TypeMismatch;
        },
        .bool => |b| {
            if (col.type_tag == .bool) return .{ .bool = b };
            if (col.type_tag == .text) {
                const s = try gpa.dupe(u8, if (b) "t" else "f");
                return .{ .text = s };
            }
            return error.TypeMismatch;
        },
    }
}

fn evalDefault(gpa: Allocator, col: value.Column) !value.Value {
    return switch (col.default_expr) {
        .none => .null,
        .now => .{ .text = try parse.formatNow(gpa) },
        .literal => |lit| try lit.clone(gpa),
    };
}

fn buildInsertRow(gpa: Allocator, eng: *engine_mod.Engine, ins: parse.Insert, values: []const value.Value) ![]value.Value {
    const table = eng.getTable(ins.table) orelse return error.TableNotFound;

    const ordered = try gpa.alloc(value.Value, table.columns.len);
    errdefer {
        for (ordered) |*v| v.deinit(gpa);
        gpa.free(ordered);
    }
    for (ordered) |*v| v.* = .null;

    if (ins.columns) |colnames| {
        if (colnames.len != values.len) return error.ColumnCountMismatch;
        for (colnames, values) |cname, val| {
            const idx = findColumn(table, cname) orelse return error.ColumnNotFound;
            ordered[idx].deinit(gpa);
            ordered[idx] = try coerceForColumn(table.columns[idx], val, gpa);
        }
    } else {
        if (values.len != table.columns.len) return error.ColumnCountMismatch;
        for (values, 0..) |val, i| {
            ordered[i].deinit(gpa);
            ordered[i] = try coerceForColumn(table.columns[i], val, gpa);
        }
    }

    // Apply defaults / serial for missing columns
    for (table.columns, 0..) |col, i| {
        if (ordered[i] != .null) continue;
        if (col.serial) {
            const id = try eng.allocSerial(ins.table);
            ordered[i] = .{ .int = id };
            continue;
        }
        if (col.default_expr != .none) {
            var def = try evalDefault(gpa, col);
            defer def.deinit(gpa);
            ordered[i] = try coerceForColumn(col, def, gpa);
            continue;
        }
        if (col.not_null) return error.NotNullViolation;
        if (col.primary_key) return error.MissingPrimaryKey;
    }
    return ordered;
}

fn execInsert(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, ins: parse.Insert) !usize {
    // A multi-row INSERT is one statement: stage all rows before publication so
    // a later constraint failure cannot partially commit earlier groups.
    var implicit_session: Session = undefined;
    const target = if (session.state == .active) session else blk: {
        implicit_session = Session.init(gpa);
        try implicit_session.begin();
        break :blk &implicit_session;
    };
    defer if (session.state != .active) implicit_session.deinit();

    for (ins.rows) |values| {
        const ordered = try buildInsertRow(gpa, eng, ins, values);
        defer {
            for (ordered) |*v| v.deinit(gpa);
            gpa.free(ordered);
        }
        try target.stageInsert(eng, ins.table, ordered);
    }

    if (session.state != .active) try implicit_session.commit(eng);
    return ins.rows.len;
}

fn rowMatchesPreds(row_values: []const value.Value, preds: []const engine_mod.Pred) bool {
    for (preds) |p| {
        switch (p) {
            .eq => |e| {
                if (!value.Value.eql(row_values[e.col_index], e.value)) return false;
            },
            .is_null => |n| {
                const is_null = row_values[n.col_index] == .null;
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

fn execUpdate(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, upd: parse.Update) !usize {
    const table = eng.getTable(upd.table) orelse return error.TableNotFound;
    const preds = try bindPreds(gpa, table, upd.where_preds);
    defer gpa.free(preds);

    if (session.state == .active) {
        const pki = table.pk_index orelse return error.TxnRequiresPrimaryKey;
        const rows = try session.collectVisibleRows(gpa, table, upd.table);
        defer Session.freeVisibleRows(gpa, rows);

        var count: usize = 0;
        for (rows) |row| {
            if (!rowMatchesPreds(row.values, preds)) continue;
            const pk = row.values[pki];

            const ordered = try gpa.alloc(value.Value, table.columns.len);
            defer {
                for (ordered) |*v| v.deinit(gpa);
                gpa.free(ordered);
            }
            for (row.values, 0..) |v, i| {
                ordered[i] = try v.clone(gpa);
            }
            for (upd.sets) |set| {
                const cidx = findColumn(table, set.column) orelse return error.ColumnNotFound;
                if (cidx == pki) {
                    if (!value.Value.eql(set.value, pk)) return error.PrimaryKeyImmutable;
                    continue;
                }
                ordered[cidx].deinit(gpa);
                ordered[cidx] = try coerceForColumn(table.columns[cidx], set.value, gpa);
            }
            try session.stageUpdate(eng, upd.table, pk, ordered);
            count += 1;
        }
        return count;
    }

    const indices = try eng.matchIndices(table, preds);
    defer gpa.free(indices);

    var count: usize = 0;

    if (table.pk_index) |pki| {
        var pks: std.ArrayList(value.Value) = .empty;
        defer {
            for (pks.items) |*v| v.deinit(gpa);
            pks.deinit(gpa);
        }
        for (indices) |idx| {
            try pks.append(gpa, try table.rows.items[idx].values[pki].clone(gpa));
        }

        for (pks.items) |pk| {
            var res = try eng.selectByPk(upd.table, pk);
            defer res.deinit();
            if (res.rows.len == 0) continue;
            const current = res.rows[0];

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
                if (cidx == pki) {
                    if (!value.Value.eql(set.value, pk)) return error.PrimaryKeyImmutable;
                    continue;
                }
                ordered[cidx].deinit(gpa);
                ordered[cidx] = try coerceForColumn(table.columns[cidx], set.value, gpa);
            }

            try eng.update(upd.table, pk, ordered);
            count += 1;
        }
    } else {
        // No single-column PK: update by descending index so swap-remove stays valid.
        var i: usize = indices.len;
        while (i > 0) {
            i -= 1;
            const idx = indices[i];
            if (idx >= table.rows.items.len) continue;
            const current = table.rows.items[idx];
            const ordered = try gpa.alloc(value.Value, table.columns.len);
            defer {
                for (ordered) |*v| v.deinit(gpa);
                gpa.free(ordered);
            }
            for (current.values, 0..) |v, ci| {
                ordered[ci] = try v.clone(gpa);
            }
            for (upd.sets) |set| {
                const cidx = findColumn(table, set.column) orelse return error.ColumnNotFound;
                ordered[cidx].deinit(gpa);
                ordered[cidx] = try coerceForColumn(table.columns[cidx], set.value, gpa);
            }
            try eng.updateAt(upd.table, idx, ordered);
            count += 1;
        }
    }
    return count;
}

fn execDelete(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, del: parse.Delete) !usize {
    const table = eng.getTable(del.table) orelse return error.TableNotFound;
    const preds = try bindPreds(gpa, table, del.where_preds);
    defer gpa.free(preds);

    if (session.state == .active) {
        const pki = table.pk_index orelse return error.TxnRequiresPrimaryKey;
        const rows = try session.collectVisibleRows(gpa, table, del.table);
        defer Session.freeVisibleRows(gpa, rows);

        var count: usize = 0;
        for (rows) |row| {
            if (!rowMatchesPreds(row.values, preds)) continue;
            try session.stageDelete(eng, del.table, row.values[pki]);
            count += 1;
        }
        return count;
    }

    const indices = try eng.matchIndices(table, preds);
    defer gpa.free(indices);

    if (table.pk_index) |pki| {
        var pks: std.ArrayList(value.Value) = .empty;
        defer {
            for (pks.items) |*v| v.deinit(gpa);
            pks.deinit(gpa);
        }
        for (indices) |idx| {
            try pks.append(gpa, try table.rows.items[idx].values[pki].clone(gpa));
        }
        for (pks.items) |pk| {
            try eng.delete(del.table, pk);
        }
        return pks.items.len;
    }

    // Delete high indices first
    var count: usize = 0;
    var i: usize = indices.len;
    while (i > 0) {
        i -= 1;
        try eng.deleteAt(del.table, indices[i]);
        count += 1;
    }
    return count;
}

fn valueToText(gpa: Allocator, arena_data: *std.ArrayList([]u8), v: value.Value) !?[]const u8 {
    switch (v) {
        .null => return null,
        .text => |t| {
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

/// Compare values using SQL ordering for the scalar types currently stored by
/// Pico. ASC places NULL last, matching PostgreSQL's default; DESC reverses it.
fn compareOrderValues(a: value.Value, b: value.Value, descending: bool) std.math.Order {
    const base: std.math.Order = switch (a) {
        .null => switch (b) {
            .null => .eq,
            else => .gt,
        },
        .int => |av| switch (b) {
            .null => .lt,
            .int => |bv| std.math.order(av, bv),
            else => .eq,
        },
        .text => |av| switch (b) {
            .null => .lt,
            .text => |bv| std.mem.order(u8, av, bv),
            else => .eq,
        },
        .bool => |av| switch (b) {
            .null => .lt,
            .bool => |bv| std.math.order(@intFromBool(av), @intFromBool(bv)),
            else => .eq,
        },
    };
    return if (descending) switch (base) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    } else base;
}

fn sortRowIndices(indices: []usize, rows: []const engine_mod.Row, column: usize, descending: bool) void {
    // Stable insertion sort keeps the scan order for equal values. The Phase 0
    // memtable is small and this avoids allocating a second row representation.
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const current = indices[i];
        var j = i;
        while (j > 0 and compareOrderValues(rows[indices[j - 1]].values[column], rows[current].values[column], descending) == .gt) : (j -= 1) {
            indices[j] = indices[j - 1];
        }
        indices[j] = current;
    }
}

fn execSelect(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, sel: parse.Select) !QueryResult.Rows {
    const table = eng.getTable(sel.table) orelse return error.TableNotFound;

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

    const preds = try bindPreds(gpa, table, sel.where_preds);
    defer gpa.free(preds);

    const order_column = if (sel.order_by) |order|
        findColumn(table, order.column) orelse return error.ColumnNotFound
    else
        null;

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

    if (session.state == .active) {
        const rows = try session.collectVisibleRows(gpa, table, sel.table);
        defer Session.freeVisibleRows(gpa, rows);

        var matched: std.ArrayList(usize) = .empty;
        defer matched.deinit(gpa);
        for (rows, 0..) |row, i| {
            if (rowMatchesPreds(row.values, preds)) try matched.append(gpa, i);
        }
        if (order_column) |column| {
            sortRowIndices(matched.items, rows, column, sel.order_by.?.descending);
        }

        var start: usize = @intCast(sel.offset);
        if (start > matched.items.len) start = matched.items.len;
        var end = matched.items.len;
        if (sel.limit) |lim| {
            const lim_usz: usize = @intCast(lim);
            if (start + lim_usz < end) end = start + lim_usz;
        }

        for (matched.items[start..end]) |idx| {
            const row = rows[idx];
            const line = try gpa.alloc(?[]const u8, proj.items.len);
            errdefer gpa.free(line);
            for (proj.items, 0..) |pi, i| {
                line[i] = try valueToText(gpa, &arena_data, row.values[pi]);
            }
            try cells.append(gpa, line);
        }
    } else {
        const indices = try eng.matchIndices(table, preds);
        defer gpa.free(indices);

        if (order_column) |column| {
            sortRowIndices(indices, table.rows.items, column, sel.order_by.?.descending);
        }

        var start: usize = @intCast(sel.offset);
        if (start > indices.len) start = indices.len;
        var end = indices.len;
        if (sel.limit) |lim| {
            const lim_usz: usize = @intCast(lim);
            if (start + lim_usz < end) end = start + lim_usz;
        }
        const slice = indices[start..end];

        for (slice) |idx| {
            const row = table.rows.items[idx];
            const line = try gpa.alloc(?[]const u8, proj.items.len);
            errdefer gpa.free(line);
            for (proj.items, 0..) |pi, i| {
                line[i] = try valueToText(gpa, &arena_data, row.values[pi]);
            }
            try cells.append(gpa, line);
        }
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
    var session = Session.init(gpa);
    defer session.deinit();

    var r1 = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
    defer r1.deinit();
    try std.testing.expect(r1 == .empty);

    var r2 = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (1, 'bob')");
    defer r2.deinit();

    var r3 = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1");
    defer r3.deinit();
    try std.testing.expect(r3 == .rows);
    try std.testing.expectEqual(@as(usize, 1), r3.rows.cells.len);
    try std.testing.expectEqualStrings("bob", r3.rows.cells[0][0].?);

    var r4 = try execute(gpa, &eng, &session, "UPDATE t SET name = 'bobby' WHERE id = 1");
    defer r4.deinit();
    try std.testing.expect(r4 == .empty);

    var r5 = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1");
    defer r5.deinit();
    try std.testing.expectEqualStrings("bobby", r5.rows.cells[0][0].?);

    var r6 = try execute(gpa, &eng, &session, "DELETE FROM t WHERE id = 1");
    defer r6.deinit();

    var r7 = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1");
    defer r7.deinit();
    try std.testing.expectEqual(@as(usize, 0), r7.rows.cells.len);

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}

test "exec select order by sorts before limit and offset" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-order-by";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, rank INT, name TEXT)");
    defer create.deinit();
    var insert = try execute(gpa, &eng, &session, "INSERT INTO t VALUES (1, 20, 'zoe'), (2, 10, 'amy'), (3, NULL, 'nil'), (4, 30, 'max')");
    defer insert.deinit();

    var asc = try execute(gpa, &eng, &session, "SELECT name FROM t ORDER BY rank ASC LIMIT 2 OFFSET 1");
    defer asc.deinit();
    try std.testing.expectEqual(@as(usize, 2), asc.rows.cells.len);
    try std.testing.expectEqualStrings("zoe", asc.rows.cells[0][0].?);
    try std.testing.expectEqualStrings("max", asc.rows.cells[1][0].?);

    var desc = try execute(gpa, &eng, &session, "SELECT name FROM t ORDER BY rank DESC");
    defer desc.deinit();
    try std.testing.expectEqualStrings("nil", desc.rows.cells[0][0].?);
    try std.testing.expectEqualStrings("max", desc.rows.cells[1][0].?);
}

test "exec multi-row insert is atomic and reports its row count" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-multi-insert";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT UNIQUE)");
    defer create.deinit();

    var inserted = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (1, 'alice'), (2, 'bob')");
    defer inserted.deinit();
    try std.testing.expectEqualStrings("INSERT 0 2", inserted.empty);
    try std.testing.expectEqual(@as(usize, 2), eng.getTable("t").?.rows.items.len);

    try std.testing.expectError(
        error.UniqueViolation,
        execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (3, 'carol'), (4, 'alice')"),
    );
    // The valid first group must not have leaked through before the later error.
    try std.testing.expectEqual(@as(usize, 2), eng.getTable("t").?.rows.items.len);
}

test "exec multi-row insert survives WAL recovery as one batch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-multi-insert-recovery";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();

        var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
        defer create.deinit();
        var inserted = try execute(gpa, &eng, &session, "INSERT INTO t VALUES (1, 'alice'), (2, 'bob')");
        defer inserted.deinit();
    }

    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();
        var rows = try execute(gpa, &eng, &session, "SELECT id, name FROM t");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.cells.len);
    }
}

test "exec sub2api-shaped settings and users" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-sub2api";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    const ddl =
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  filename TEXT PRIMARY KEY,
        \\  checksum TEXT NOT NULL,
        \\  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        \\);
        \\CREATE TABLE IF NOT EXISTS settings (
        \\  key VARCHAR(100) PRIMARY KEY,
        \\  value TEXT NOT NULL,
        \\  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        \\);
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id BIGSERIAL PRIMARY KEY,
        \\  email VARCHAR(255) NOT NULL UNIQUE,
        \\  password_hash VARCHAR(255) NOT NULL,
        \\  role VARCHAR(20) NOT NULL DEFAULT 'user',
        \\  balance DECIMAL(20, 8) NOT NULL DEFAULT 0,
        \\  status VARCHAR(20) NOT NULL DEFAULT 'active',
        \\  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        \\  deleted_at TIMESTAMPTZ
        \\);
    ;

    const results = try executeScript(gpa, &eng, &session, ddl);
    defer {
        for (results) |*r| r.deinit();
        gpa.free(results);
    }

    var r1 = try execute(gpa, &eng, &session, "INSERT INTO schema_migrations (filename, checksum) VALUES ('001_init.sql', 'abc')");
    defer r1.deinit();

    var r2 = try execute(gpa, &eng, &session, "INSERT INTO settings (key, value) VALUES ('site_name', 'Sub2API')");
    defer r2.deinit();

    var r3 = try execute(gpa, &eng, &session, "SELECT value FROM settings WHERE key = 'site_name'");
    defer r3.deinit();
    try std.testing.expectEqualStrings("Sub2API", r3.rows.cells[0][0].?);

    var r4 = try execute(gpa, &eng, &session, "INSERT INTO users (email, password_hash) VALUES ('admin@example.com', 'hash')");
    defer r4.deinit();

    var r5 = try execute(gpa, &eng, &session, "SELECT id, email, role, balance FROM users WHERE email = 'admin@example.com' AND deleted_at IS NULL");
    defer r5.deinit();
    try std.testing.expectEqual(@as(usize, 1), r5.rows.cells.len);
    try std.testing.expectEqualStrings("1", r5.rows.cells[0][0].?);
    try std.testing.expectEqualStrings("admin@example.com", r5.rows.cells[0][1].?);
    try std.testing.expectEqualStrings("user", r5.rows.cells[0][2].?);
    try std.testing.expectEqualStrings("0", r5.rows.cells[0][3].?);

    var r6 = try execute(gpa, &eng, &session, "UPDATE users SET status = 'disabled' WHERE email = 'admin@example.com'");
    defer r6.deinit();

    var r7 = try execute(gpa, &eng, &session, "SELECT status FROM users WHERE id = 1");
    defer r7.deinit();
    try std.testing.expectEqualStrings("disabled", r7.rows.cells[0][0].?);

    // IF NOT EXISTS second time
    var r8 = try execute(gpa, &eng, &session, "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)");
    defer r8.deinit();

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}

test "exec rejects syntax whose semantics are not implemented" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-rejections";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "CREATE INDEX idx_t_id ON t(id)"));
    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, parent_id INT REFERENCES parent(id))"));

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
    defer create.deinit();
    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "INSERT INTO t VALUES (1, 'alice') RETURNING id"));
    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "SELECT * FROM t ORDER BY id, name"));
}

test "alter table changes survive WAL recovery" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-alter-recovery";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();
        var create = try execute(gpa, &eng, &session, "CREATE TABLE accounts (id INT PRIMARY KEY, name TEXT)");
        defer create.deinit();
        var insert = try execute(gpa, &eng, &session, "INSERT INTO accounts VALUES (1, 'alice')");
        defer insert.deinit();
        var add = try execute(gpa, &eng, &session, "ALTER TABLE accounts ADD COLUMN active BOOLEAN NOT NULL DEFAULT true");
        defer add.deinit();
        var set_default = try execute(gpa, &eng, &session, "ALTER TABLE accounts ALTER COLUMN name SET DEFAULT 'anonymous'");
        defer set_default.deinit();
        var set_null = try execute(gpa, &eng, &session, "ALTER TABLE accounts ALTER COLUMN name SET NOT NULL");
        defer set_null.deinit();
        var clear_default = try execute(gpa, &eng, &session, "ALTER TABLE accounts ALTER COLUMN name DROP DEFAULT");
        defer clear_default.deinit();
        var clear_null = try execute(gpa, &eng, &session, "ALTER TABLE accounts ALTER COLUMN name DROP NOT NULL");
        defer clear_null.deinit();
        var drop = try execute(gpa, &eng, &session, "ALTER TABLE accounts DROP COLUMN name");
        defer drop.deinit();
    }
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();
        var result = try execute(gpa, &eng, &session, "SELECT active FROM accounts WHERE id = 1");
        defer result.deinit();
        try std.testing.expectEqualStrings("t", result.rows.cells[0][0].?);
        const active = eng.getTable("accounts").?.columns[1];
        try std.testing.expect(active.not_null);
        try std.testing.expect(active.default_expr == .literal);
    }
}

test "exec begin commit publishes write set; rollback discards" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-txn";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
    defer create.deinit();

    var begin1 = try execute(gpa, &eng, &session, "BEGIN");
    defer begin1.deinit();
    try std.testing.expectEqualStrings("BEGIN", begin1.empty);
    try std.testing.expect(session.state == .active);

    var ins = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (1, 'alice')");
    defer ins.deinit();

    // Private write set: published table empty, SELECT in txn sees the row.
    try std.testing.expectEqual(@as(usize, 0), eng.getTable("t").?.rows.items.len);
    var sel_tx = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1");
    defer sel_tx.deinit();
    try std.testing.expectEqualStrings("alice", sel_tx.rows.cells[0][0].?);

    var commit = try execute(gpa, &eng, &session, "COMMIT");
    defer commit.deinit();
    try std.testing.expect(session.state == .idle);
    try std.testing.expectEqual(@as(usize, 1), eng.getTable("t").?.rows.items.len);

    var begin2 = try execute(gpa, &eng, &session, "BEGIN");
    defer begin2.deinit();
    var ins2 = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (2, 'bob')");
    defer ins2.deinit();
    var rb = try execute(gpa, &eng, &session, "ROLLBACK");
    defer rb.deinit();
    try std.testing.expectEqual(@as(usize, 1), eng.getTable("t").?.rows.items.len);

    var sel = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 2");
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 0), sel.rows.cells.len);
}

test "exec statement error fails transaction until rollback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-txn-failed";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT NOT NULL)");
    defer create.deinit();
    var begin = try execute(gpa, &eng, &session, "BEGIN");
    defer begin.deinit();
    var ins = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (1, 'ok')");
    defer ins.deinit();

    try std.testing.expectError(error.NotNullViolation, execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (2, NULL)"));
    try std.testing.expect(session.state == .failed);
    try std.testing.expectError(error.InFailedTransaction, execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1"));
    try std.testing.expectError(error.InFailedTransaction, execute(gpa, &eng, &session, "COMMIT"));

    var rb = try execute(gpa, &eng, &session, "ROLLBACK");
    defer rb.deinit();
    try std.testing.expect(session.state == .idle);
    try std.testing.expectEqual(@as(usize, 0), eng.getTable("t").?.rows.items.len);
}

test "exec committed transaction survives WAL recovery; rolled back does not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-txn-recovery";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();

        var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
        defer create.deinit();

        var begin_c = try execute(gpa, &eng, &session, "BEGIN");
        defer begin_c.deinit();
        var insert_c = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (1, 'committed')");
        defer insert_c.deinit();
        var commit_c = try execute(gpa, &eng, &session, "COMMIT");
        defer commit_c.deinit();

        var begin_r = try execute(gpa, &eng, &session, "BEGIN");
        defer begin_r.deinit();
        var insert_r = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (2, 'rolled')");
        defer insert_r.deinit();
        // Crash-equivalent: drop the engine without COMMIT. Write set never entered WAL.
    }

    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();
        var all = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1");
        defer all.deinit();
        try std.testing.expectEqualStrings("committed", all.rows.cells[0][0].?);
        var ghost = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 2");
        defer ghost.deinit();
        try std.testing.expectEqual(@as(usize, 0), ghost.rows.cells.len);
    }
}

const Io = std.Io;
