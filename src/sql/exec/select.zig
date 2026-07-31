const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("../../storage/engine.zig");
const value = @import("../../storage/value.zig");
const parse = @import("../parse.zig");
const session_mod = @import("../../txn/session.zig");
const pred = @import("pred.zig");

const Session = session_mod.Session;
const QueryResult = @import("core.zig").QueryResult;

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
/// RunaDB. ASC places NULL last, matching PostgreSQL's default; DESC reverses it.
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

pub fn execSelect(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, sel: parse.Select) !QueryResult.Rows {
    const table = eng.getTable(sel.table) orelse return error.TableNotFound;

    var proj: std.ArrayList(usize) = .empty;
    defer proj.deinit(gpa);
    if (sel.columns) |names| {
        for (names) |n| {
            const idx = pred.findColumn(table, n) orelse return error.ColumnNotFound;
            try proj.append(gpa, idx);
        }
    } else {
        for (table.columns, 0..) |_, i| try proj.append(gpa, i);
    }

    const preds = try pred.bindPreds(gpa, table, sel.where_preds);
    defer pred.deinitEnginePreds(gpa, preds);

    const order_column = if (sel.order_by) |order|
        pred.findColumn(table, order.column) orelse return error.ColumnNotFound
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
            if (pred.rowMatchesPreds(row.values, preds)) try matched.append(gpa, i);
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
