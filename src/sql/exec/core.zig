const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("../../storage/engine.zig");
const value = @import("../../storage/value.zig");
const parse = @import("../parse.zig");
const token = @import("../token.zig");
const session_mod = @import("../../txn/session.zig");

const insert_mod = @import("insert.zig");
const select_mod = @import("select.zig");
const update_mod = @import("update.zig");
const delete_mod = @import("delete.zig");

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
            const n = try insert_mod.execInsert(gpa, eng, session, ins);
            return .{ .empty = try formatTag(gpa, "INSERT 0 {d}", .{n}) };
        },
        .select => |sel| {
            return .{ .rows = try select_mod.execSelect(gpa, eng, session, sel) };
        },
        .update => |upd| {
            const n = try update_mod.execUpdate(gpa, eng, session, upd);
            return .{ .empty = try formatTag(gpa, "UPDATE {d}", .{n}) };
        },
        .delete => |del| {
            const n = try delete_mod.execDelete(gpa, eng, session, del);
            return .{ .empty = try formatTag(gpa, "DELETE {d}", .{n}) };
        },
    };
}

/// Format a command tag string. Tags are allocated from page_allocator and
/// leaked process-end (same semantics as the previous arena, without global
/// mutable state). These are small fixed-format strings (e.g. "INSERT 0 1").
fn formatTag(gpa: Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    _ = gpa;
    return std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
}
