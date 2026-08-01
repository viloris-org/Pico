//! Single-writer commit coordinator (roadmap Phase 3).
//!
//! All mutations from every connection converge here. The coordinator is the
//! only place that assigns a commit sequence, writes the WAL record for a
//! write set, applies it to the shared tables, and advances the published
//! watermark. That ordering is RunaDB's commit-order contract: one observable
//! order, WAL-durable before visibility, and no partial commit.
//!
//! Group commit: requests queued together are drained as a batch. Each accepted
//! request keeps its own `commit_seq` and its own `txn_batch` WAL frame, but the
//! frames share one durability round, so concurrent small transactions amortize
//! the fsync without merging their identity or reordering them. Within a round,
//! later requests validate against the effects of earlier accepted requests
//! (the shadow), giving each request the same outcome it would have had if the
//! writer had processed them as separate rounds in that order.
//!
//! Conflict validation: every update/delete records the row version it observed
//! while staging. The coordinator revalidates that stamp against the published
//! state (plus earlier accepted requests in the same round), so a lost update
//! fails with `WriteWriteConflict` instead of overwriting silently. Inserts
//! re-check primary-key uniqueness the same way.
//!
//! Bounded admission: the queue has a fixed capacity. When it is full, new work
//! is rejected with `CommitQueueFull` rather than growing without bound, so a
//! hot connection cannot monopolize the writer or the memory behind it.
//!
//! The coordinator is generic over the storage context so it never imports the
//! engine module; it calls back through comptime hooks, matching the style of
//! `wal.replayWal`. Row-shape validation (types, not-null, unique columns,
//! primary-key immutability) belongs to the engine, which sees the shadow so it
//! can account for a transaction's own earlier writes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const wal_mod = @import("../storage/wal.zig");
const value = @import("../storage/value.zig");

pub const CoordError = error{
    CommitQueueFull,
    WriteWriteConflict,
    DuplicatePrimaryKey,
    UniqueViolation,
    PrimaryKeyNotFound,
    InvalidRequest,
    WalAppendFailed,
} || Allocator.Error || Io.Cancelable;

pub const Config = struct {
    /// Maximum number of queued commit requests before new ones are rejected.
    queue_capacity: usize = 64,
    /// Maximum combined staged bytes across the queue before rejection.
    max_queued_bytes: u64 = 256 * 1024 * 1024,
};

/// One immutable commit request, produced by a `txn.Transaction`.
pub const Request = struct {
    gpa: Allocator,
    ops: []wal_mod.TxnOp,
    /// Parallel to `ops`: the observed row version for update/delete targets.
    /// `null` marks a row this transaction inserted itself (no external version
    /// to revalidate against). Inserts use null.
    observed: []?u64,
    /// Snapshot watermark the transaction started from; used for admission
    /// ordering and observability. Validation itself uses the observed stamps.
    read_seq: u64 = 0,
    result: ?CoordError = null,
    done: bool = false,

    pub fn deinit(self: *Request) void {
        for (self.ops) |*op| {
            switch (op.*) {
                .insert => |rec| {
                    self.gpa.free(rec.table);
                    for (@constCast(rec.values)) |*v| v.deinit(self.gpa);
                    self.gpa.free(rec.values);
                },
                .update => |rec| {
                    self.gpa.free(rec.table);
                    var pk = rec.pk;
                    pk.deinit(self.gpa);
                    for (@constCast(rec.values)) |*v| v.deinit(self.gpa);
                    self.gpa.free(rec.values);
                },
                .delete => |rec| {
                    self.gpa.free(rec.table);
                    var pk = rec.pk;
                    pk.deinit(self.gpa);
                },
            }
        }
        self.gpa.free(self.ops);
        self.gpa.free(self.observed);
        self.* = undefined;
    }
};

/// A row-version effect from an earlier accepted request in the same round.
/// The coordinator appends one entry per accepted op; the engine reads the
/// slice through the `validateOp` hook so it can check unique columns and
/// self-inserted targets against the whole round, not just live tables.
pub const ShadowEntry = struct {
    table: []const u8,
    pk: value.Value,
    values: []const value.Value,
    version: u64,
    present: bool,
};

/// Hooks the coordinator needs from the storage context.
pub fn Hooks(comptime Ctx: type) type {
    return struct {
        walAppend: *const fn (Ctx) *wal_mod.Wal,
        rowVersion: *const fn (Ctx, []const u8, value.Value) ?u64,
        pkExists: *const fn (Ctx, []const u8, value.Value) bool,
        /// Resolve the primary key of an insert's values from the table schema,
        /// or null when the table has no single-column primary key.
        pkOf: *const fn (Ctx, []const u8, []const value.Value) ?value.Value,
        applyOp: *const fn (Ctx, *const wal_mod.TxnOp) anyerror!void,
        /// Full row-shape validation (types, not-null, unique columns,
        /// primary-key existence) for `op`. `shadow` holds earlier accepted ops
        /// from this round, so the engine can validate a transaction's own
        /// prior inserts.
        validateOp: *const fn (Ctx, *const wal_mod.TxnOp, []const ShadowEntry) CoordError!void,
    };
}

pub fn Coordinator(comptime Ctx: type, comptime hooks: Hooks(Ctx)) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        io: Io,
        cfg: Config = .{},
        /// Serializes the drain so only one writer is active at a time.
        writer_mutex: Io.Mutex = .init,
        /// Pending requests not yet assigned a commit sequence.
        queue: std.ArrayList(*Request) = .empty,
        queued_bytes: u64 = 0,
        next_commit_seq: u64 = 1,
        published_commit_seq: u64 = 0,
        /// Counters for observability.
        commits: u64 = 0,
        conflicts: u64 = 0,
        queue_rejections: u64 = 0,

        pub fn init(gpa: Allocator, io: Io) Self {
            return .{ .gpa = gpa, .io = io };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit(self.gpa);
            self.* = undefined;
        }

        pub fn publishedSeq(self: *const Self) u64 {
            return self.published_commit_seq;
        }

        /// Snapshot watermark for a new transaction: the current published
        /// commit sequence.
        pub fn snapshot(self: *const Self) u64 {
            return self.published_commit_seq;
        }

        /// Adopt the watermark rebuilt during recovery so new commits continue
        /// above the last confirmed one.
        pub fn restoreWatermark(self: *Self, seq: u64) void {
            self.published_commit_seq = seq;
            self.next_commit_seq = seq + 1;
        }

        /// Enqueue a request for the next drain. Rejects when the queue is full
        /// or the queued byte budget is exceeded, so admission is bounded.
        pub fn submit(self: *Self, ctx: Ctx, request: *Request) CoordError!void {
            _ = ctx;
            try self.writer_mutex.lock(self.io);
            defer self.writer_mutex.unlock(self.io);
            if (self.queue.items.len >= self.cfg.queue_capacity) {
                self.queue_rejections += 1;
                return error.CommitQueueFull;
            }
            const bytes = requestBytes(request);
            if (self.queued_bytes + bytes > self.cfg.max_queued_bytes) {
                self.queue_rejections += 1;
                return error.CommitQueueFull;
            }
            try self.queue.append(self.gpa, request);
            self.queued_bytes += bytes;
        }

        /// Drain the queue as one group-commit round. Returns once every queued
        /// request has a result. Safe to call with an empty queue.
        pub fn drain(self: *Self, ctx: Ctx) !void {
            try self.writer_mutex.lock(self.io);
            defer self.writer_mutex.unlock(self.io);

            var batch: std.ArrayList(*Request) = .empty;
            defer batch.deinit(self.gpa);
            try batch.appendSlice(self.gpa, self.queue.items);
            self.queue.clearRetainingCapacity();
            self.queued_bytes = 0;
            if (batch.items.len == 0) return;

            // Pass 1: validate in FIFO order, tracking prior requests' effects
            // in a shadow so later requests see them without touching shared
            // tables before the WAL is durable.
            var shadow: std.ArrayList(ShadowEntry) = .empty;
            defer shadow.deinit(self.gpa);

            var accepted: std.ArrayList(*Request) = .empty;
            defer accepted.deinit(self.gpa);
            var seqs: std.ArrayList(u64) = .empty;
            defer seqs.deinit(self.gpa);

            for (batch.items) |req| {
                const valid = self.validateRequest(ctx, req, &shadow) catch |err| {
                    req.result = err;
                    req.done = true;
                    self.conflicts += 1;
                    continue;
                };
                if (!valid) continue;
                try accepted.append(self.gpa, req);
            }

            if (accepted.items.len == 0) return;

            // Pass 2: assign commit sequences in FIFO order.
            const wal = hooks.walAppend(ctx);
            var batches: std.ArrayList(wal_mod.Wal.TxnBatchGroup) = .empty;
            defer batches.deinit(self.gpa);
            try batches.ensureTotalCapacity(self.gpa, accepted.items.len);
            for (accepted.items) |req| {
                const seq = self.next_commit_seq;
                self.next_commit_seq += 1;
                batches.appendAssumeCapacity(.{ .commit_seq = seq, .ops = req.ops });
            }

            // Pass 3: persist every accepted write set in one durability round.
            wal.appendTxnBatchGroup(batches.items) catch {
                // No WAL record was published; no request may appear committed.
                for (accepted.items) |req| {
                    req.result = error.WalAppendFailed;
                    req.done = true;
                }
                self.conflicts += accepted.items.len;
                return;
            };

            // Pass 4: apply in commit order and advance the watermark after
            // each, so readers never observe a later commit before an earlier
            // one.
            for (accepted.items, 0..) |req, i| {
                const seq = batches.items[i].commit_seq;
                for (req.ops) |*op| {
                    hooks.applyOp(ctx, op) catch |err| {
                        req.result = mapApplyError(err);
                        req.done = true;
                        self.conflicts += 1;
                        break;
                    };
                }
                if (req.result == null) {
                    self.published_commit_seq = seq;
                    req.done = true;
                    self.commits += 1;
                }
            }
        }

        fn validateRequest(self: *Self, ctx: Ctx, req: *Request, shadow: *std.ArrayList(ShadowEntry)) CoordError!bool {
            // Interleave validation and shadow application per op so a request
            // sees its own earlier writes (insert then update the same row).
            for (req.ops, req.observed) |*op, observed| {
                // Full row-shape validation (types, not-null, unique columns,
                // primary-key existence) lives in the engine hook, which sees
                // the shadow so a transaction's own prior inserts count.
                try hooks.validateOp(ctx, op, shadow.items);
                switch (op.*) {
                    .insert => {},
                    .update => |upd| {
                        const effective = try self.shadowLookup(ctx, shadow, upd.table, upd.pk);
                        const published_version: ?u64 = if (effective) |e| blk: {
                            if (!e.present) break :blk null;
                            break :blk e.version;
                        } else null;
                        if (observed) |observed_version| {
                            if (published_version == null or published_version.? != observed_version) {
                                return error.WriteWriteConflict;
                            }
                        } else if (published_version == null) {
                            // Self-inserted target: the row must already be
                            // present from this request's own insert.
                            return error.PrimaryKeyNotFound;
                        }
                    },
                    .delete => |del| {
                        const effective = try self.shadowLookup(ctx, shadow, del.table, del.pk);
                        const published_version: ?u64 = if (effective) |e| blk: {
                            if (!e.present) break :blk null;
                            break :blk e.version;
                        } else null;
                        if (observed) |observed_version| {
                            if (published_version == null or published_version.? != observed_version) {
                                return error.WriteWriteConflict;
                            }
                        } else if (published_version == null) {
                            return error.PrimaryKeyNotFound;
                        }
                    },
                }
                try self.shadowApply(ctx, shadow, op, observed);
            }
            return true;
        }

        fn shadowApply(self: *Self, ctx: Ctx, shadow: *std.ArrayList(ShadowEntry), op: *const wal_mod.TxnOp, observed: ?u64) !void {
            switch (op.*) {
                .insert => |rec| try shadow.append(self.gpa, .{
                    .table = rec.table,
                    .pk = hooks.pkOf(ctx, rec.table, rec.values) orelse .null,
                    .values = rec.values,
                    .version = 0,
                    .present = true,
                }),
                .update => |rec| try shadow.append(self.gpa, .{
                    .table = rec.table,
                    .pk = rec.pk,
                    .values = rec.values,
                    .version = observed orelse 0,
                    .present = true,
                }),
                .delete => |rec| try shadow.append(self.gpa, .{
                    .table = rec.table,
                    .pk = rec.pk,
                    .values = &.{},
                    .version = 0,
                    .present = false,
                }),
            }
        }

        /// Resolve the effective row version for `(table, pk)`: the shadow wins
        /// over the published state, falling back to the live tables.
        fn shadowLookup(
            self: *Self,
            ctx: Ctx,
            shadow: *const std.ArrayList(ShadowEntry),
            table: []const u8,
            pk: value.Value,
        ) !?ShadowEntry {
            _ = self;
            for (shadow.items) |entry| {
                if (std.mem.eql(u8, entry.table, table) and entry.pk.eql(pk)) return entry;
            }
            if (hooks.pkExists(ctx, table, pk)) {
                return .{
                    .table = table,
                    .pk = pk,
                    .values = &.{},
                    .version = hooks.rowVersion(ctx, table, pk) orelse 0,
                    .present = true,
                };
            }
            return null;
        }
    };
}

fn requestBytes(req: *const Request) u64 {
    var total: u64 = @sizeOf(wal_mod.TxnOp) * req.ops.len;
    for (req.ops) |op| switch (op) {
        .insert => |rec| {
            total += rec.table.len;
            for (rec.values) |_| total += @sizeOf(value.Value);
        },
        .update => |rec| {
            total += rec.table.len;
            for (rec.values) |_| total += @sizeOf(value.Value);
        },
        .delete => |rec| {
            total += rec.table.len;
        },
    };
    return total;
}

fn mapApplyError(err: anyerror) CoordError {
    return switch (err) {
        error.DuplicatePrimaryKey => error.DuplicatePrimaryKey,
        error.UniqueViolation => error.UniqueViolation,
        error.PrimaryKeyNotFound => error.PrimaryKeyNotFound,
        else => error.WalAppendFailed,
    };
}
