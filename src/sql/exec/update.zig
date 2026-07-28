const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("../../storage/engine.zig");
const value = @import("../../storage/value.zig");
const parse = @import("../parse.zig");
const session_mod = @import("../../txn/session.zig");
const pred = @import("pred.zig");
const select = @import("select.zig");

const Session = session_mod.Session;
const ExecError = @import("core.zig").ExecError;

pub fn execUpdate(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, upd: parse.Update) !usize {
    const table = eng.getTable(upd.table) orelse return error.TableNotFound;
    const preds = try pred.bindPreds(gpa, table, upd.where_preds);
    defer pred.deinitEnginePreds(gpa, preds);

    if (session.state == .active) {
        const pki = table.pk_index orelse return error.TxnRequiresPrimaryKey;
        const rows = try session.collectVisibleRows(gpa, table, upd.table);
        defer Session.freeVisibleRows(gpa, rows);

        var count: usize = 0;
        for (rows) |row| {
            if (!pred.rowMatchesPreds(row.values, preds)) continue;
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
                const cidx = pred.findColumn(table, set.column) orelse return error.ColumnNotFound;
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
                const cidx = pred.findColumn(table, set.column) orelse return error.ColumnNotFound;
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
                const cidx = pred.findColumn(table, set.column) orelse return error.ColumnNotFound;
                ordered[cidx].deinit(gpa);
                ordered[cidx] = try coerceForColumn(table.columns[cidx], set.value, gpa);
            }
            try eng.updateAt(upd.table, idx, ordered);
            count += 1;
        }
    }
    return count;
}

fn coerceForColumn(col: value.Column, v: value.Value, gpa: Allocator) !value.Value {
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
