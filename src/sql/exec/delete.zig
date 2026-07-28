const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("../../storage/engine.zig");
const value = @import("../../storage/value.zig");
const parse = @import("../parse.zig");
const session_mod = @import("../../txn/session.zig");
const pred = @import("pred.zig");

const Session = session_mod.Session;
const ExecError = @import("core.zig").ExecError;

pub fn execDelete(gpa: Allocator, eng: *engine_mod.Engine, session: *Session, del: parse.Delete) !usize {
    const table = eng.getTable(del.table) orelse return error.TableNotFound;
    const preds = try pred.bindPreds(gpa, table, del.where_preds);
    defer pred.deinitEnginePreds(gpa, preds);

    if (session.state == .active) {
        const pki = table.pk_index orelse return error.TxnRequiresPrimaryKey;
        const rows = try session.collectVisibleRows(gpa, table, del.table);
        defer Session.freeVisibleRows(gpa, rows);

        var count: usize = 0;
        for (rows) |row| {
            if (!pred.rowMatchesPreds(row.values, preds)) continue;
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
