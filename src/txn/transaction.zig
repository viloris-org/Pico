//! Transaction ownership area (roadmap Phase 3).
//!
//! A `Transaction` owns the per-connection state that RunaDB requires to turn
//! validated mutation IR into one atomic commit: a snapshot watermark, a private
//! write set, and a lifecycle through `active`, `failed`, and `commit_wait`.
//!
//! The transaction does not write the WAL or mutate shared tables directly.
//! Staging validates each operation against the base committed state plus the
//! transaction's own earlier writes (read-your-writes and incremental
//! validation), then `commit` hands the immutable write set to the single-writer
//! commit coordinator, which assigns the commit sequence, persists the WAL
//! record, and publishes the changes in commit order.
//!
//! A failed transaction rejects every operation except rollback, so a partial
//! write set can never be committed silently. Disconnecting an active
//! transaction rolls it back; nothing crosses the irreversible commit point
//! without a durable WAL record.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("../storage/value.zig");
const wal_mod = @import("../storage/wal.zig");
const table_mod = @import("../storage/table.zig");

pub const TxnError = table_mod.Error || Allocator.Error || error{
    InvalidState,
    TransactionFailed,
    OperationCountExceeded,
    StagedBytesExceeded,
};

pub const State = enum {
    idle,
    active,
    failed,
    commit_wait,
};

/// One staged mutation, fully owned by the transaction. `observed_version` is
/// the row version the transaction saw for an update/delete target; the commit
/// coordinator revalidates it against the published state to detect write-write
/// conflicts.
pub const WriteOp = struct {
    table: []u8,
    pk: value.Value,
    values: []value.Value,
    op: wal_mod.TxnOp.Tag,
    observed_version: ?u64 = null,
    bytes: u64,

    pub fn deinit(self: *WriteOp, gpa: Allocator) void {
        gpa.free(self.table);
        self.pk.deinit(gpa);
        for (self.values) |*v| v.deinit(gpa);
        gpa.free(self.values);
        self.* = undefined;
    }
};

/// Bounds for one transaction's write set, enforced during staging so a
/// misbehaving connection cannot stage unbounded memory before the commit queue
/// ever sees it.
pub const Limits = struct {
    max_ops: usize = 10_000,
    max_staged_bytes: u64 = 64 * 1024 * 1024,
};

pub const Transaction = struct {
    gpa: Allocator,
    state: State = .idle,
    /// Snapshot watermark: the published commit sequence at the first read or
    /// the start of the transaction, whichever comes first. Reads at this
    /// watermark never observe commits published after it.
    snapshot_seq: u64 = 0,
    write_set: std.ArrayList(WriteOp) = .empty,
    limits: Limits = .{},
    staged_bytes: u64 = 0,
    next_op_id: u64 = 0,

    pub fn begin(gpa: Allocator, snapshot_seq: u64) Transaction {
        return .{
            .gpa = gpa,
            .state = .active,
            .snapshot_seq = snapshot_seq,
        };
    }

    pub fn deinit(self: *Transaction) void {
        for (self.write_set.items) |*op| op.deinit(self.gpa);
        self.write_set.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn isActive(self: *const Transaction) bool {
        return self.state == .active;
    }

    pub fn isFailed(self: *const Transaction) bool {
        return self.state == .failed;
    }

    pub fn isCommitWaiting(self: *const Transaction) bool {
        return self.state == .commit_wait;
    }

    /// Rollback discards the private write set and returns the transaction to
    /// idle. It performs no WAL or storage operation: nothing was ever made
    /// visible to other connections.
    pub fn rollback(self: *Transaction) TxnError!void {
        if (self.state == .idle) return error.InvalidState;
        for (self.write_set.items) |*op| op.deinit(self.gpa);
        self.write_set.clearRetainingCapacity();
        self.staged_bytes = 0;
        self.state = .idle;
    }

    /// Stage an insert. The caller supplies the full row values and the primary
    /// key (for write-set conflict checks); the transaction clones them so the
    /// write set is immutable once staged.
    pub fn stageInsert(self: *Transaction, table_name: []const u8, pk: value.Value, values: []const value.Value) TxnError!void {
        try self.expectWritable();
        try self.reserve(estimatedRowBytes(values));
        var op = try self.buildOp(table_name, .insert, pk, values, null);
        errdefer op.deinit(self.gpa);
        try self.write_set.append(self.gpa, op);
        self.staged_bytes += op.bytes;
        self.next_op_id += 1;
    }

    /// Stage an update. `observed_version` is the row version this transaction
    /// saw while building the write set; the coordinator rejects the commit if
    /// the published row has since changed.
    pub fn stageUpdate(
        self: *Transaction,
        table_name: []const u8,
        pk: value.Value,
        values: []const value.Value,
        observed_version: u64,
    ) TxnError!void {
        try self.expectWritable();
        try self.reserve(estimatedRowBytes(values));
        var op = try self.buildOp(table_name, .update, pk, values, observed_version);
        errdefer op.deinit(self.gpa);
        try self.write_set.append(self.gpa, op);
        self.staged_bytes += op.bytes;
        self.next_op_id += 1;
    }

    pub fn stageDelete(self: *Transaction, table_name: []const u8, pk: value.Value, observed_version: u64) TxnError!void {
        try self.expectWritable();
        try self.reserve(@sizeOf(value.Value) + table_name.len);
        var op = try self.buildOp(table_name, .delete, pk, &.{}, observed_version);
        errdefer op.deinit(self.gpa);
        try self.write_set.append(self.gpa, op);
        self.staged_bytes += op.bytes;
        self.next_op_id += 1;
    }

    fn expectWritable(self: *const Transaction) TxnError!void {
        if (self.state != .active) return error.InvalidState;
    }

    fn reserve(self: *const Transaction, bytes: u64) TxnError!void {
        if (self.write_set.items.len >= self.limits.max_ops) return error.OperationCountExceeded;
        if (self.staged_bytes + bytes > self.limits.max_staged_bytes) return error.StagedBytesExceeded;
    }

    fn buildOp(
        self: *Transaction,
        table_name: []const u8,
        op: wal_mod.TxnOp.Tag,
        pk: value.Value,
        values: []const value.Value,
        observed_version: ?u64,
    ) TxnError!WriteOp {
        var result: WriteOp = .{
            .table = try self.gpa.dupe(u8, table_name),
            .pk = .null,
            .values = &.{},
            .op = op,
            .observed_version = observed_version,
            .bytes = 0,
        };
        errdefer result.deinit(self.gpa);
        if (pk != .null) {
            result.pk = try pk.clone(self.gpa);
        }
        if (values.len != 0) {
            const owned = try self.gpa.alloc(value.Value, values.len);
            errdefer {
                for (owned) |*v| v.deinit(self.gpa);
                self.gpa.free(owned);
            }
            for (values, 0..) |v, i| owned[i] = try v.clone(self.gpa);
            result.values = owned;
        }
        result.bytes = table_name.len + @sizeOf(value.Value) * (values.len + 1);
        return result;
    }

    /// Convert the staged write set into the immutable `TxnOp` array the
    /// coordinator commits. The caller owns the result; values are moved out of
    /// the write set so nothing is shared with the (now idle) transaction.
    pub fn toWalOps(self: *Transaction) ![]wal_mod.TxnOp {
        const ops = try self.gpa.alloc(wal_mod.TxnOp, self.write_set.items.len);
        errdefer self.gpa.free(ops);
        for (self.write_set.items, 0..) |*op, i| {
            switch (op.op) {
                .insert => ops[i] = .{ .insert = .{ .table = op.table, .values = op.values } },
                .update => ops[i] = .{ .update = .{ .table = op.table, .pk = op.pk, .values = op.values } },
                .delete => ops[i] = .{ .delete = .{ .table = op.table, .pk = op.pk } },
            }
            // Transfer ownership: mark the write set entry as vacated.
            op.table = &.{};
            op.pk = .null;
            op.values = &.{};
        }
        for (self.write_set.items) |*op| op.deinit(self.gpa);
        self.write_set.clearRetainingCapacity();
        self.staged_bytes = 0;
        self.state = .idle;
        return ops;
    }
};

fn estimatedRowBytes(values: []const value.Value) u64 {
    var total: u64 = @sizeOf(value.Value);
    for (values) |v| {
        total += @sizeOf(value.Value);
        switch (v) {
            .text => |t| total += t.len,
            .vector => |vec| total += @sizeOf(f32) * vec.len,
            else => {},
        }
    }
    return total;
}
