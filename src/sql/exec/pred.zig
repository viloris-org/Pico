const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("../../storage/engine.zig");
const value = @import("../../storage/value.zig");
const parse = @import("../parse.zig");
const token = @import("../token.zig");

pub fn findColumn(table: *engine_mod.Table, name: []const u8) ?usize {
    for (table.columns, 0..) |c, i| {
        if (token.eqlIgnoreCase(c.name, name)) return i;
    }
    return null;
}

pub fn bindPreds(gpa: Allocator, table: *engine_mod.Table, preds: []const parse.Predicate) ![]engine_mod.Pred {
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
            .cmp => |c| blk: {
                const idx = findColumn(table, c.column) orelse return error.ColumnNotFound;
                break :blk .{ .cmp = .{ .col_index = idx, .op = switch (c.op) {
                    .neq => .neq,
                    .lt => .lt,
                    .gt => .gt,
                    .lte => .lte,
                    .gte => .gte,
                }, .value = c.value } };
            },
            .or_group => |o| blk: {
                const groups = try gpa.alloc([]engine_mod.Pred, o.groups.len);
                errdefer gpa.free(groups);
                for (o.groups, 0..) |group, gi| {
                    groups[gi] = try bindPreds(gpa, table, group);
                }
                break :blk .{ .or_group = .{ .groups = groups } };
            },
        };
    }
    return out;
}

/// Free engine Pred allocations. Leaf variants borrow values; only .or_group owns
/// nested group slices that need explicit deallocation.
pub fn deinitEnginePreds(gpa: Allocator, preds: []engine_mod.Pred) void {
    for (preds) |p| {
        if (p == .or_group) {
            for (p.or_group.groups) |group| gpa.free(group);
            gpa.free(p.or_group.groups);
        }
    }
    gpa.free(preds);
}

pub fn rowMatchesPreds(row_values: []const value.Value, preds: []const engine_mod.Pred) bool {
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
            .cmp => |c| {
                const ord = value.Value.order(row_values[c.col_index], c.value) orelse return false;
                const pass = switch (c.op) {
                    .neq => ord != .eq,
                    .lt => ord == .lt,
                    .gt => ord == .gt,
                    .lte => ord != .gt,
                    .gte => ord != .lt,
                };
                if (!pass) return false;
            },
            .or_group => |o| {
                var any_match = false;
                for (o.groups) |group| {
                    if (rowMatchesPreds(row_values, group)) {
                        any_match = true;
                        break;
                    }
                }
                if (!any_match) return false;
            },
        }
    }
    return true;
}
