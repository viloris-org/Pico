//! Bounded instance connection table (roadmap Phase 3).
//!
//! The registry is the source of truth for cancellation routing: a
//! `cancel_request` carries a credential and the registry maps it to a live
//! Connection in constant time, marks that Connection's current statement, and
//! reports the outcome for observability. Missing, mismatched, closed, or
//! expired credentials finish as protocol-defined no-ops. The table is bounded
//! so a flood of Connections cannot grow it without limit; when it is full,
//! new registrations are rejected rather than admitted silently.
//!
//! The registry owns neither socket buffers nor result sets, so a slow or
//! closed reader cannot be kept alive by it. In the current sequential
//! listener at most one Connection is registered at a time; the bounded table
//! and the credential lookup are the foundation the concurrent runtime
//! (Phase 6) builds on.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const connection_mod = @import("connection.zig");

/// Outcome of a cancellation lookup, for observability. Both outcomes are
/// protocol no-ops on the wire; only the counters differ.
pub const CancelOutcome = enum {
    /// The credential named a Connection with a statement currently executing
    /// and that statement was marked.
    hit,
    /// The credential named no live Connection, named a Connection with no
    /// statement executing (idle or between statements), or was already
    /// revoked. Defined by the protocol as a no-op.
    noop,
};

pub const Config = struct {
    /// Maximum simultaneous registrations before new ones are rejected.
    capacity: usize = 1024,
};

pub const Registry = struct {
    gpa: Allocator,
    io: Io,
    cfg: Config = .{},
    /// Credential -> live Connection. Constant-time lookup without scanning.
    by_credential: std.AutoHashMap(connection_mod.Credential, *connection_mod.State),
    next_id: u64 = 1,
    mutex: Io.Mutex = .init,
    /// Observability counters for cancellation routing.
    cancel_hits: u64 = 0,
    cancel_noops: u64 = 0,
    registrations_rejected: u64 = 0,

    pub fn init(gpa: Allocator, io: Io, cfg: Config) Registry {
        return .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .by_credential = std.AutoHashMap(connection_mod.Credential, *connection_mod.State).init(gpa),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.by_credential.deinit();
        self.* = undefined;
    }

    /// Register a Connection, assigning its internal ID. Rejects with
    /// `error.RegistryFull` when the table is full (admission is bounded) and
    /// `error.OutOfMemory` when the map cannot grow; the caller reports these
    /// distinctly rather than conflating capacity with allocation failure.
    pub fn register(self: *Registry, state: *connection_mod.State) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.by_credential.count() >= self.cfg.capacity) {
            self.registrations_rejected += 1;
            return error.RegistryFull;
        }
        state.id = self.next_id;
        self.next_id += 1;
        try self.by_credential.put(state.credential, state);
    }

    /// Revoke a Connection's registration. A credential is never reused before
    /// the old registration is fully revoked. Uses the uncancellable lock so
    /// revocation always completes: the registry may hold a pointer to a
    /// stack-local Connection `State`, so a failed lock would strand a
    /// credential that later routes cancellation into freed memory.
    pub fn unregister(self: *Registry, state: *connection_mod.State) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.by_credential.remove(state.credential);
    }

    /// Route a cancellation request. Constant-time lookup; marks the target
    /// Connection's current statement only while it is executing. No waiting,
    /// no execution context, no response frame — missing, revoked, or idle
    /// credentials are protocol no-ops. In the sequential listener every wire
    /// cancel targets an idle Connection, so `cancel_noops` is the honest
    /// counter there; `cancel_hits` becomes meaningful under the concurrent
    /// (Phase 6) runtime.
    pub fn cancelByCredential(self: *Registry, credential: connection_mod.Credential) !CancelOutcome {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.by_credential.getPtr(credential) orelse {
            self.cancel_noops += 1;
            return .noop;
        };
        if (!entry.*.executing.load(.acquire)) {
            self.cancel_noops += 1;
            return .noop;
        }
        entry.*.markCancelled();
        self.cancel_hits += 1;
        return .hit;
    }

    /// Number of currently registered Connections, under the mutex so the
    /// count cannot race with concurrent register/unregister (Phase 6).
    pub fn liveCount(self: *Registry) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.by_credential.count();
    }
};

test "registry routes a credential to the right connection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var registry = Registry.init(gpa, io, .{});
    defer registry.deinit();

    var conn_a = connection_mod.State.init(0, .{1} ** connection_mod.CREDENTIAL_LENGTH);
    var conn_b = connection_mod.State.init(0, .{2} ** connection_mod.CREDENTIAL_LENGTH);
    try registry.register(&conn_a);
    try registry.register(&conn_b);
    try std.testing.expectEqual(@as(usize, 2), registry.liveCount());

    conn_a.beginStatement();
    conn_b.beginStatement();
    conn_a.setExecuting(true);
    conn_b.setExecuting(true);
    try std.testing.expectEqual(.hit, try registry.cancelByCredential(conn_a.credential));
    try std.testing.expectError(error.Canceled, conn_a.checkCancelled());
    try conn_b.checkCancelled(); // untouched
    try std.testing.expectEqual(@as(u64, 1), registry.cancel_hits);

    // An idle Connection (not executing) is a no-op, not a hit.
    conn_a.setExecuting(false);
    conn_a.beginStatement(); // clears the stale mark
    try std.testing.expectEqual(.noop, try registry.cancelByCredential(conn_a.credential));
    try std.testing.expectEqual(@as(u64, 1), registry.cancel_hits);
    try std.testing.expectEqual(@as(u64, 1), registry.cancel_noops);
}

test "unknown and revoked credentials are protocol no-ops" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var registry = Registry.init(gpa, io, .{});
    defer registry.deinit();

    var conn = connection_mod.State.init(0, .{3} ** connection_mod.CREDENTIAL_LENGTH);
    try registry.register(&conn);

    // Unknown credential: no-op, counted.
    try std.testing.expectEqual(.noop, try registry.cancelByCredential(.{0xAB} ** connection_mod.CREDENTIAL_LENGTH));
    try std.testing.expectEqual(@as(u64, 1), registry.cancel_noops);

    // After the connection closes, its credential is revoked and expires.
    registry.unregister(&conn);
    try std.testing.expectEqual(.noop, try registry.cancelByCredential(conn.credential));
    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());
}

test "registry admission is bounded" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var registry = Registry.init(gpa, io, .{ .capacity = 2 });
    defer registry.deinit();

    var conn_a = connection_mod.State.init(0, .{4} ** connection_mod.CREDENTIAL_LENGTH);
    var conn_b = connection_mod.State.init(0, .{5} ** connection_mod.CREDENTIAL_LENGTH);
    var conn_c = connection_mod.State.init(0, .{6} ** connection_mod.CREDENTIAL_LENGTH);
    try registry.register(&conn_a);
    try registry.register(&conn_b);
    try std.testing.expectError(error.RegistryFull, registry.register(&conn_c));
    try std.testing.expectEqual(@as(u64, 1), registry.registrations_rejected);

    // Freeing a slot admits new work.
    registry.unregister(&conn_a);
    try registry.register(&conn_c);
    try std.testing.expectEqual(@as(usize, 2), registry.liveCount());
}
