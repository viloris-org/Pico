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
    NotNullViolation,
    UniqueViolation,
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
pub fn execute(gpa: Allocator, eng: *engine_mod.Engine, sql: []const u8) !QueryResult {
    var results = try executeScript(gpa, eng, sql);
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
pub fn executeScript(gpa: Allocator, eng: *engine_mod.Engine, sql: []const u8) ![]QueryResult {
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
        try out.append(gpa, try execStmt(gpa, eng, stmt));
    }

    if (out.items.len == 0) {
        try out.append(gpa, .{ .empty = "EMPTY" });
    }
    return try out.toOwnedSlice(gpa);
}

fn execStmt(gpa: Allocator, eng: *engine_mod.Engine, stmt: parse.Stmt) !QueryResult {
    return switch (stmt) {
        .empty => .{ .empty = "EMPTY" },
        .begin_tx => .{ .empty = "BEGIN" },
        .commit_tx => .{ .empty = "COMMIT" },
        .rollback_tx => .{ .empty = "ROLLBACK" },
        .create_index => .{ .empty = "CREATE INDEX" },
        .create_table => |ct| {
            if (ct.if_not_exists) {
                try eng.createTableIfNotExists(ct.name, ct.columns);
            } else {
                try eng.createTable(ct.name, ct.columns);
            }
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
            const n = try execUpdate(gpa, eng, upd);
            // Tag buffer lifetime: return static-ish via allocated? PG uses "UPDATE n".
            // Store in empty as static only works for fixed; use heap tag via... QueryResult.empty is []const u8.
            // Allocate tag on gpa — but empty deinit doesn't free. Use stack-fixed via fmt into static threadlocal? 
            // For protocol path we need dynamic. Change empty to own optional later.
            // Workaround: only return common tags; for count use format into a leaked... bad.
            // Better: encode count in a small static pool — for tests, "UPDATE 1" is enough if n==1.
            return .{ .empty = try formatTag(gpa, "UPDATE {d}", .{n}) };
        },
        .delete => |del| {
            const n = try execDelete(gpa, eng, del);
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

fn execInsert(gpa: Allocator, eng: *engine_mod.Engine, ins: parse.Insert) !void {
    const table = eng.getTable(ins.table) orelse return error.TableNotFound;

    const ordered = try gpa.alloc(value.Value, table.columns.len);
    defer {
        for (ordered) |*v| v.deinit(gpa);
        gpa.free(ordered);
    }
    for (ordered) |*v| v.* = .null;

    if (ins.columns) |colnames| {
        if (colnames.len != ins.values.len) return error.ColumnCountMismatch;
        for (colnames, ins.values) |cname, val| {
            const idx = findColumn(table, cname) orelse return error.ColumnNotFound;
            ordered[idx].deinit(gpa);
            ordered[idx] = try coerceForColumn(table.columns[idx], val, gpa);
        }
    } else {
        if (ins.values.len != table.columns.len) return error.ColumnCountMismatch;
        for (ins.values, 0..) |val, i| {
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

    try eng.insert(ins.table, ordered);
}

fn execUpdate(gpa: Allocator, eng: *engine_mod.Engine, upd: parse.Update) !usize {
    const table = eng.getTable(upd.table) orelse return error.TableNotFound;
    const preds = try bindPreds(gpa, table, upd.where_preds);
    defer gpa.free(preds);

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

fn execDelete(gpa: Allocator, eng: *engine_mod.Engine, del: parse.Delete) !usize {
    const table = eng.getTable(del.table) orelse return error.TableNotFound;
    const preds = try bindPreds(gpa, table, del.where_preds);
    defer gpa.free(preds);

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

fn execSelect(gpa: Allocator, eng: *engine_mod.Engine, sel: parse.Select) !QueryResult.Rows {
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

    const indices = try eng.matchIndices(table, preds);
    defer gpa.free(indices);

    // Apply OFFSET / LIMIT
    var start: usize = @intCast(sel.offset);
    if (start > indices.len) start = indices.len;
    var end = indices.len;
    if (sel.limit) |lim| {
        const lim_usz: usize = @intCast(lim);
        if (start + lim_usz < end) end = start + lim_usz;
    }
    const slice = indices[start..end];

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

    for (slice) |idx| {
        const row = table.rows.items[idx];
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

test "exec sub2api-shaped settings and users" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-sub2api";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();

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
        \\CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
    ;

    const results = try executeScript(gpa, &eng, ddl);
    defer {
        for (results) |*r| r.deinit();
        gpa.free(results);
    }

    var r1 = try execute(gpa, &eng, "INSERT INTO schema_migrations (filename, checksum) VALUES ('001_init.sql', 'abc')");
    defer r1.deinit();

    var r2 = try execute(gpa, &eng, "INSERT INTO settings (key, value) VALUES ('site_name', 'Sub2API')");
    defer r2.deinit();

    var r3 = try execute(gpa, &eng, "SELECT value FROM settings WHERE key = 'site_name'");
    defer r3.deinit();
    try std.testing.expectEqualStrings("Sub2API", r3.rows.cells[0][0].?);

    var r4 = try execute(gpa, &eng, "INSERT INTO users (email, password_hash) VALUES ('admin@example.com', 'hash')");
    defer r4.deinit();

    var r5 = try execute(gpa, &eng, "SELECT id, email, role, balance FROM users WHERE email = 'admin@example.com' AND deleted_at IS NULL");
    defer r5.deinit();
    try std.testing.expectEqual(@as(usize, 1), r5.rows.cells.len);
    try std.testing.expectEqualStrings("1", r5.rows.cells[0][0].?);
    try std.testing.expectEqualStrings("admin@example.com", r5.rows.cells[0][1].?);
    try std.testing.expectEqualStrings("user", r5.rows.cells[0][2].?);
    try std.testing.expectEqualStrings("0", r5.rows.cells[0][3].?);

    var r6 = try execute(gpa, &eng, "UPDATE users SET status = 'disabled' WHERE email = 'admin@example.com'");
    defer r6.deinit();

    var r7 = try execute(gpa, &eng, "SELECT status FROM users WHERE id = 1");
    defer r7.deinit();
    try std.testing.expectEqualStrings("disabled", r7.rows.cells[0][0].?);

    // IF NOT EXISTS second time
    var r8 = try execute(gpa, &eng, "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)");
    defer r8.deinit();

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}

const Io = std.Io;
