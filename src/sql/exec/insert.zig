const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("../../storage/engine.zig");
const value = @import("../../storage/value.zig");
const parse = @import("../parse.zig");
const session_mod = @import("../../txn/session.zig");
const pred = @import("pred.zig");

const Session = session_mod.Session;
const ExecError = @import("core.zig").ExecError;

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
            const idx = pred.findColumn(table, cname) orelse return error.ColumnNotFound;
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

pub fn execInsert(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, ins: parse.Insert) !usize {
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
