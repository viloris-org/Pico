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
//!
//! The generation, the executing flag, and the cancellation mark live in one
//! machine word (`State.state`). Statement entry, statement exit, and the
//! router's mark are each a single atomic compare-and-swap, so a cancellation
//! mark is bound to the exact statement the router observed: if the connection
//! starts its next statement between the router's read and its mark, the mark
//! fails and is dropped rather than aborting the later statement.

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
    /// Statement state in a single machine word: generation in bits 0..61,
    /// executing in bit 62, cancelled in bit 63. The connection thread and the
    /// registry's cancellation routing transition it with compare-and-swap, so
    /// no lock serializes a statement boundary against a cancellation mark.
    state: std.atomic.Value(u64) = .init(0),

    /// Bit layout of `state`.
    const CANCEL_BIT: u64 = 1 << 63;
    const EXEC_BIT: u64 = 1 << 62;
    const GEN_MASK: u64 = (1 << 62) - 1; // bits 0..61

    pub fn init(id: u64, credential: Credential) State {
        return .{ .id = id, .credential = credential };
    }

    /// Transition `ready -> executing` in one atomic step: advance the
    /// generation, enter the executing region, and clear any stale mark. A
    /// cancellation routed concurrently is bound to the generation observed
    /// before this transition and cannot land on this statement.
    pub fn beginStatement(self: *State) void {
        var observed = self.state.load(.acquire);
        while (true) {
            var gen = (observed & GEN_MASK) +% 1;
            gen &= GEN_MASK;
            if (gen == 0) gen = 1; // never wrap back to the idle sentinel
            const next = gen | EXEC_BIT; // clears CANCEL_BIT with the transition
            const actual = self.state.cmpxchgWeak(observed, next, .acq_rel, .acquire) orelse return;
            observed = actual;
        }
    }

    /// Transition `executing -> ready`: leave the executing region and clear
    /// the mark. The state between statements is (generation, idle, unmarked),
    /// so a cancellation routed in that window is honestly counted as a no-op
    /// and cannot abort the next statement.
    pub fn endStatement(self: *State) void {
        var observed = self.state.load(.acquire);
        while (true) {
            const next = observed & GEN_MASK; // clears EXEC_BIT and CANCEL_BIT
            const actual = self.state.cmpxchgWeak(observed, next, .acq_rel, .acquire) orelse return;
            observed = actual;
        }
    }

    /// Cooperative cancellation check between bounded work units. Reads only
    /// the mark bit: statement entry clears it atomically, and the router sets
    /// it only on a state that is executing, so a set bit always means the
    /// current statement is marked.
    pub fn checkCancelled(self: *const State) !void {
        if ((self.state.load(.acquire) & CANCEL_BIT) != 0) return error.Canceled;
    }

    /// Deliver a cancellation mark for the statement currently executing: read
    /// the word, then atomically bind the mark to exactly what was read.
    /// Returns true when the mark was committed onto an executing statement;
    /// false when the Connection was idle, the statement was already marked by
    /// an earlier cancel, or a new statement began between the read and the
    /// mark. A mark never applies to a later statement.
    pub fn markCancelled(self: *State) bool {
        return self.markObserved(self.state.load(.acquire));
    }

    /// Attempt to commit a cancellation mark onto the exact state observed
    /// while routing. The mark requires the observed state to be executing and
    /// not yet marked; the compare-and-swap then fails if the Connection
    /// changed in any way — went idle, started the next statement, or another
    /// cancel already landed — in which case the mark is dropped rather than
    /// misapplied.
    pub fn markObserved(self: *State, observed: u64) bool {
        if ((observed & (EXEC_BIT | CANCEL_BIT)) != EXEC_BIT) return false;
        const actual = self.state.cmpxchgStrong(observed, observed | CANCEL_BIT, .acq_rel, .monotonic);
        if (actual) |_| return false;
        return true;
    }

    /// Current statement generation (0 until the first statement starts).
    pub fn generation(self: *const State) u64 {
        return self.state.load(.monotonic) & GEN_MASK;
    }

    /// Whether a statement is currently in its executing region.
    pub fn isExecuting(self: *const State) bool {
        return (self.state.load(.acquire) & EXEC_BIT) != 0;
    }

    /// Whether the current statement has been marked for cancellation.
    pub fn isMarked(self: *const State) bool {
        return (self.state.load(.acquire) & CANCEL_BIT) != 0;
    }

    /// A mark applies only to the statement that was running when it arrived;
    /// a credential that no longer names a live Connection is a protocol no-op.
    pub fn isLive(self: *const State) bool {
        return self.generation() > 0;
    }
};

test "a cancellation mark aborts only the current statement" {
    var state = State.init(1, .{1} ** CREDENTIAL_LENGTH);
    state.beginStatement();
    try state.checkCancelled();

    try std.testing.expect(state.markCancelled());
    try std.testing.expectError(error.Canceled, state.checkCancelled());
    try std.testing.expect(state.isMarked());

    // The next statement clears the mark and advances the generation.
    const before = state.generation();
    state.beginStatement();
    try std.testing.expectEqual(before + 1, state.generation());
    try std.testing.expect(!state.isMarked());
    try state.checkCancelled();
}

test "a mark delivered while idle never aborts the next statement" {
    var state = State.init(2, .{2} ** CREDENTIAL_LENGTH);
    // No statement running; a stale cancel is a no-op.
    try std.testing.expect(!state.markCancelled());
    state.beginStatement();
    try state.checkCancelled();
}

test "a mark racing a statement boundary never aborts the next statement" {
    var state = State.init(3, .{3} ** CREDENTIAL_LENGTH);
    state.beginStatement(); // statement N starts and executes
    try std.testing.expect(state.isExecuting());

    // The router observes statement N executing...
    const observed = state.state.load(.monotonic);
    try std.testing.expect((observed & State.EXEC_BIT) != 0);

    // ...but N finishes and N+1 starts before the mark lands.
    state.endStatement();
    state.beginStatement();

    // The mark, bound to the observed generation, must fail to apply and the
    // new statement must not observe it.
    try std.testing.expect(!state.markObserved(observed));
    try state.checkCancelled();
    try std.testing.expect(!state.isMarked());
}

test "a mark applied mid-statement lands on that statement and clears at exit" {
    var state = State.init(4, .{4} ** CREDENTIAL_LENGTH);
    state.beginStatement();
    try std.testing.expect(state.markCancelled());
    try std.testing.expectError(error.Canceled, state.checkCancelled());

    state.endStatement();
    // Exit clears both the executing flag and the mark.
    try std.testing.expect(!state.isExecuting());
    try std.testing.expect(!state.isMarked());

    // The next statement is clean.
    state.beginStatement();
    try state.checkCancelled();
    try std.testing.expect(state.isExecuting());
}

test "a stale observation never commits a mark onto a later generation" {
    var state = State.init(5, .{5} ** CREDENTIAL_LENGTH);
    state.beginStatement(); // generation 1
    const observed = state.state.load(.monotonic);
    state.endStatement();
    state.beginStatement(); // generation 2
    state.endStatement();
    state.beginStatement(); // generation 3
    try std.testing.expect(!state.markObserved(observed));
    try state.checkCancelled();
}

test "beginStatement never wraps the generation back to the idle sentinel" {
    var state = State.init(6, .{6} ** CREDENTIAL_LENGTH);
    // Simulate a connection that has executed 2^62 - 1 statements.
    state.state.store(State.GEN_MASK, .monotonic);
    state.beginStatement();
    try std.testing.expectEqual(@as(u64, 1), state.generation());
    try std.testing.expect(state.isLive());
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
