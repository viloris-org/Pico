const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("../storage/value.zig");

pub const Stmt = union(enum) {
    create_table: CreateTable,
    alter_table: AlterTable,
    create_index: CreateIndex,
    insert: Insert,
    select: Select,
    update: Update,
    delete: Delete,
    begin_tx,
    commit_tx,
    rollback_tx,
    empty,
};

pub const AlterTable = struct {
    table: []const u8,
    table_owned: bool = false,
    action: Action,

    pub const Action = union(enum) {
        add_column: struct { column: value.Column, if_not_exists: bool },
        drop_column: struct { name: []const u8, name_owned: bool = false, if_exists: bool },
        set_default: struct { column: []const u8, column_owned: bool = false, default_expr: value.DefaultExpr },
        drop_default: struct { column: []const u8, column_owned: bool = false },
        set_not_null: struct { column: []const u8, column_owned: bool = false },
        drop_not_null: struct { column: []const u8, column_owned: bool = false },
    };
};

pub const CreateTable = struct {
    name: []const u8,
    name_owned: bool = false,
    columns: []value.Column, // owned names + defaults
    if_not_exists: bool,
};

pub const CreateIndex = struct {
    /// Accepted for wire compatibility; storage is scan-based for now.
    if_not_exists: bool,
};

pub const Insert = struct {
    table: []const u8,
    table_owned: bool = false,
    columns: ?[][]const u8, // optional column list (may own entries)
    columns_owned: bool = false,
    rows: [][]value.Value, // owned value groups
};

/// Single WHERE predicate (AND-combined in a list).
pub const Predicate = union(enum) {
    /// col = value
    eq: struct {
        column: []const u8,
        column_owned: bool = false,
        value: value.Value, // owned
    },
    /// col IS NULL / IS NOT NULL
    is_null: struct {
        column: []const u8,
        column_owned: bool = false,
        negated: bool,
    },
    /// col <op> value where op != =
    cmp: struct {
        column: []const u8,
        column_owned: bool = false,
        op: CmpOp,
        value: value.Value, // owned
    },
    /// col [NOT] IN (value, ...)
    in_list: struct {
        column: []const u8,
        column_owned: bool = false,
        values: []value.Value, // owned
        negated: bool,
    },
    /// col [NOT] LIKE pattern. The pattern is a SQL string literal.
    like: struct {
        column: []const u8,
        column_owned: bool = false,
        pattern: value.Value, // owned
        negated: bool,
    },
    /// expr1 OR expr2 — each group is AND-combined
    or_group: struct {
        groups: [][]Predicate, // owned; each inner slice is AND-combined
    },

    pub const CmpOp = enum(u8) {
        neq,
        lt,
        gt,
        lte,
        gte,
    };

    pub fn deinit(self: *Predicate, gpa: Allocator) void {
        switch (self.*) {
            .eq => |*e| {
                if (e.column_owned) gpa.free(e.column);
                e.value.deinit(gpa);
            },
            .is_null => |*n| {
                if (n.column_owned) gpa.free(n.column);
            },
            .cmp => |*c| {
                if (c.column_owned) gpa.free(c.column);
                c.value.deinit(gpa);
            },
            .in_list => |*list| {
                if (list.column_owned) gpa.free(list.column);
                for (list.values) |*v| v.deinit(gpa);
                gpa.free(list.values);
            },
            .like => |*like| {
                if (like.column_owned) gpa.free(like.column);
                like.pattern.deinit(gpa);
            },
            .or_group => |*o| {
                for (o.groups) |group| {
                    for (group) |*p| p.deinit(gpa);
                    gpa.free(group);
                }
                gpa.free(o.groups);
            },
        }
    }
};

pub const Select = struct {
    table: []const u8,
    table_owned: bool = false,
    /// null means SELECT *
    columns: ?[][]const u8,
    columns_owned: bool = false,
    where_preds: []Predicate, // owned slice
    /// One ordering key. Multi-key ordering remains outside the current subset.
    order_by: ?OrderTerm = null,
    limit: ?u64 = null,
    offset: u64 = 0,
};

pub const OrderTerm = struct {
    column: []const u8,
    column_owned: bool = false,
    descending: bool = false,
};

pub const SetClause = struct {
    column: []const u8,
    column_owned: bool = false,
    value: value.Value, // owned
};

pub const Update = struct {
    table: []const u8,
    table_owned: bool = false,
    sets: []SetClause, // owned slice; values owned
    where_preds: []Predicate,
};

pub const Delete = struct {
    table: []const u8,
    table_owned: bool = false,
    where_preds: []Predicate,
};

pub fn formatNow(gpa: Allocator) ![]u8 {
    // TIMESTAMPTZ is stored as text in the SQL subset. Prefer a real wall-clock
    // second when the target provides linux syscalls; otherwise a mono counter.
    const sec: i64 = if (@import("builtin").os.tag == .linux) blk: {
        var ts: std.os.linux.timespec = undefined;
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        break :blk if (rc == 0) ts.sec else monoNow();
    } else monoNow();
    return std.fmt.allocPrint(gpa, "{d}", .{sec});
}

var mono_now_counter: i64 = 1_700_000_000;
fn monoNow() i64 {
    mono_now_counter += 1;
    return mono_now_counter;
}

pub fn freeStmt(gpa: Allocator, stmt: *Stmt) void {
    switch (stmt.*) {
        .create_table => |*ct| {
            if (ct.name_owned) gpa.free(ct.name);
            for (ct.columns) |*c| c.deinit(gpa);
            gpa.free(ct.columns);
        },
        .create_index => {},
        .alter_table => |*at| {
            if (at.table_owned) gpa.free(at.table);
            switch (at.action) {
                .add_column => |*add| add.column.deinit(gpa),
                .drop_column => |drop| if (drop.name_owned) gpa.free(drop.name),
                .set_default => |*set| {
                    if (set.column_owned) gpa.free(set.column);
                    set.default_expr.deinit(gpa);
                },
                .drop_default => |drop| if (drop.column_owned) gpa.free(drop.column),
                .set_not_null => |set| if (set.column_owned) gpa.free(set.column),
                .drop_not_null => |drop| if (drop.column_owned) gpa.free(drop.column),
            }
        },
        .insert => |*ins| {
            if (ins.table_owned) gpa.free(ins.table);
            if (ins.columns) |c| {
                if (ins.columns_owned) {
                    for (c) |name| gpa.free(name);
                }
                gpa.free(c);
            }
            for (ins.rows) |row| {
                for (row) |*v| v.deinit(gpa);
                gpa.free(row);
            }
            gpa.free(ins.rows);
        },
        .select => |*sel| {
            if (sel.table_owned) gpa.free(sel.table);
            if (sel.columns) |c| {
                if (sel.columns_owned) {
                    for (c) |name| gpa.free(name);
                }
                gpa.free(c);
            }
            if (sel.order_by) |order| {
                if (order.column_owned) gpa.free(order.column);
            }
            for (sel.where_preds) |*p| p.deinit(gpa);
            gpa.free(sel.where_preds);
        },
        .update => |*upd| {
            if (upd.table_owned) gpa.free(upd.table);
            for (upd.sets) |*s| {
                if (s.column_owned) gpa.free(s.column);
                s.value.deinit(gpa);
            }
            gpa.free(upd.sets);
            for (upd.where_preds) |*p| p.deinit(gpa);
            gpa.free(upd.where_preds);
        },
        .delete => |*del| {
            if (del.table_owned) gpa.free(del.table);
            for (del.where_preds) |*p| p.deinit(gpa);
            gpa.free(del.where_preds);
        },
        .begin_tx, .commit_tx, .rollback_tx, .empty => {},
    }
    stmt.* = .empty;
}
