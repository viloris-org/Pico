//! Per-connection identity and cancellation state (roadmap Phase 3).
//!
//! Each RunaDB Connection owns a monotonically increasing internal ID and an
//! unpredictable cancellation credential that is unique within the connection
//! lifetime. A statement generation advances on every `ready -> executing`
//! transition and clears its cancellation flag, so a mark delivered while no
//! statement is running can never abort a later statement.
//!
//! Cancellation is cooperative: the executing statement calls `checkCancelled`
//! between bounded work units and stops with `error.Canceled` when marked.
//! Delivery rules (who may cancel, what a stale credential means, the
//! irreversible commit point) are owned by
//! `docs/architecture/runtime-and-concurrency.md`; this module owns only the
//! per-connection state machine that those rules operate on.

const std = @import("std");
const Io = std.Io;
const proto = @import("clint_proto");

pub const Credential = [proto.CANCEL_CREDENTIAL_LENGTH]u8;
pub const CREDENTIAL_LENGTH: usize = proto.CANCEL_CREDENTIAL_LENGTH;

/// Generate an unpredictable credential. The Server creates one per
/// Connection after startup; credentials are never reused and never appear in
/// metrics or logs.
pub fn randomCredential(io: Io) Credential {
    var credential: Credential = undefined;
    Io.random(io, &credential);
    return credential;
}

pub const State = struct {
    /// Monotonically increasing internal ID assigned by the instance registry.
    id: u64 = 0,
    /// Cancellation credential delivered to the client in HELLO_OK.
    credential: Credential = .{0} ** CREDENTIAL_LENGTH,
    /// Incremented on every statement start; a cancellation mark applies only
    /// to the generation it was set under. Atomic so the connection thread and
    /// the registry's cancellation routing never race on it (Phase 6 runtime).
    generation: std.atomic.Value(u64) = .init(0),
    /// Cooperative cancellation mark for the current generation. Atomic for the
    /// same reason: `beginStatement` (connection thread) clears it while
    /// `markCancelled` (registry routing) sets it.
    cancelled: std.atomic.Value(bool) = .init(false),
    /// Whether a statement is currently executing and so may observe a mark.
    /// Atomic so `cancelByCredential` can distinguish a real hit from an idle
    /// between-statement no-op.
    executing: std.atomic.Value(bool) = .init(false),

    pub fn init(id: u64, credential: Credential) State {
        return .{ .id = id, .credential = credential };
    }

    /// Transition `ready -> executing`: start a new statement, clearing any
    /// stale mark from a previous statement. A mark set while idle is a no-op.
    pub fn beginStatement(self: *State) void {
        _ = self.generation.fetchAdd(1, .acq_rel);
        self.cancelled.store(false, .release);
    }

    /// Mark the Connection as executing (or not). A statement holds the mark
    /// true for the duration of its execution region.
    pub fn setExecuting(self: *State, executing: bool) void {
        self.executing.store(executing, .release);
    }

    /// Cooperative cancellation check between bounded work units.
    pub fn checkCancelled(self: *const State) !void {
        if (self.cancelled.load(.acquire)) return error.Canceled;
    }

    /// Deliver a cancellation mark for the statement currently executing.
    /// Applies to the current generation only.
    pub fn markCancelled(self: *State) void {
        self.cancelled.store(true, .release);
    }

    /// A mark applies only to the statement that was running when it arrived;
    /// a credential that no longer names a live Connection is a protocol no-op.
    pub fn isLive(self: *const State) bool {
        return self.generation.load(.monotonic) > 0;
    }
};

test "a cancellation mark aborts only the current statement" {
    var state = State.init(1, .{1} ** CREDENTIAL_LENGTH);
    state.beginStatement();
    try state.checkCancelled();

    state.markCancelled();
    try std.testing.expectError(error.Canceled, state.checkCancelled());

    // The next statement clears the mark and advances the generation.
    const before = state.generation.load(.monotonic);
    state.beginStatement();
    try std.testing.expectEqual(before + 1, state.generation.load(.monotonic));
    try state.checkCancelled();
}

test "a mark delivered while idle never aborts the next statement" {
    var state = State.init(2, .{2} ** CREDENTIAL_LENGTH);
    // No statement running; a stale cancel arrives.
    state.markCancelled();
    state.beginStatement();
    try state.checkCancelled();
}

test "credentials are unpredictable and distinct" {
    const io = std.testing.io;
    const a = randomCredential(io);
    const b = randomCredential(io);
    // Two draws must differ (astronomically likely for 128-bit credentials).
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "state tracks the assigned id and credential" {
    const credential = .{7} ** CREDENTIAL_LENGTH;
    var state = State.init(42, credential);
    try std.testing.expectEqual(@as(u64, 42), state.id);
    try std.testing.expectEqualSlices(u8, &credential, &state.credential);
    try std.testing.expect(!state.isLive());
    state.beginStatement();
    try std.testing.expect(state.isLive());
}
