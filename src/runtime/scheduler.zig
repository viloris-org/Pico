//! Bounded work-queue scheduler for the RunaDB runtime (roadmap Phase 6).
//!
//! This module is the first slice of the I/O scheduling contract in
//! `docs/architecture/io-scheduling.md`: operation states, fixed capacity, and
//! the completion queue, validated against a fake platform backend. It is a
//! scheduling module only — it owns no Runa Flow semantics, MVCC visibility,
//! WAL contents, or protocol state — and follows the `runtime` module boundary
//! in `docs/architecture-contract.yml` (owned data: `io_scheduler_state`,
//! `completion_queues`).
//!
//! ## Ownership model
//!
//! Callers own `Op` values (typically pooled per Connection, commit batch, or
//! background task) and admit them with `enqueue`. The scheduler references an
//! op only while it is queued, in flight, or awaiting its callback; when the
//! callback runs (or `cancel` releases a queued op) the op returns to its
//! owner, which may re-enqueue it for another I/O phase. An op's callback is
//! invoked exactly once.
//!
//! ## Tick discipline
//!
//! One `tick` performs only bounded work: extract a bounded batch of platform
//! completions (recording only results — no callbacks), process the bounded
//! completion queue within a callback budget, then select the next batch by
//! class priority and submit it. Callbacks may change their own op's state,
//! release resources, or enqueue follow-up work, but never run the scheduler
//! and never touch the platform directly: work enqueued during a callback
//! phase is submitted in the next tick's submission phase, so new I/O enters
//! the platform only from the scheduler. Callback depth stays one, enforced by
//! assertion: a callback must not `cancel` another op or run `tick`.
//!
//! ## Classes and capacity
//!
//! `critical` (WAL append/sync, recovery reads, manifest finalization,
//! shutdown) is replenished first and never queued behind network writes or
//! compaction; its admission failure is the explicit instance-failure signal
//! (`error.CriticalCapacityExhausted`). `foreground_read` and
//! `foreground_write` are served round-robin at owner (Connection) granularity
//! so one large result set cannot monopolize the foreground budget.
//! `maintenance` (compaction, checkpoint preparation, cleanup) may use only
//! the per-tick submission budget that critical and foreground do not
//! consume, so it yields under foreground pressure and regains bounded
//! progress when the foreground is idle. Backpressure uses high/low watermarks
//! with hysteresis so a single completion event cannot flap a class.
//!
//! The current slice is single-threaded: `enqueue`, `cancel`, and `tick` are
//! not yet guarded by a runtime mutex. The socket-I/O reactor, per-Connection
//! byte backpressure, reserved WAL slots, and compaction scheduling arrive in
//! later slices of the same contract.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// I/O work classes from the I/O scheduling contract. A class is a scheduling
/// and observability property, not a storage ownership boundary.
pub const Class = enum(u8) {
    critical,
    foreground_read,
    foreground_write,
    maintenance,

    pub const count: usize = 4;
};

/// Operation state machine from `docs/architecture/io-scheduling.md`:
/// `queued -> submitted -> completed -> callback_ready -> released`, with
/// `queued -> cancelled` (cancellable work only) and `cancelled -> released`.
pub const State = enum(u8) {
    queued,
    submitted,
    completed,
    callback_ready,
    released,
    cancelled,
};

/// One schedulable I/O operation. Owned by the caller (typically pooled per
/// Connection, commit batch, or background task); the scheduler references it
/// only while it is queued, in flight, or awaiting its callback.
pub const Op = struct {
    /// An op not owned by the scheduler starts (and ends) its life in
    /// `released`; `enqueue` requires exactly this state.
    state: State = .released,
    class: Class = .maintenance,
    /// Owner identifier (Connection id, commit-batch id, or background-task
    /// id). Must be below `Config.max_owners`; the scheduler never reorders
    /// ops of one owner, so a Connection's response order is preserved under
    /// concurrent scheduling.
    owner: u32 = 0,
    /// Reserved payload bytes for this op, bounded per class so that limiting
    /// only operation slots cannot hide an unbounded byte queue.
    bytes: u64 = 0,
    /// Set for read-only/maintenance work that may be cancelled before
    /// submission. A submitted op is never cancelled: cancellation after
    /// submission is cooperative (marks that prevent follow-up work, not
    /// revocations of work already in the platform).
    cancellable: bool = false,
    /// Tick at which this op was enqueued. Ops enqueued during a callback
    /// phase carry the current tick and are submitted in the next tick's
    /// submission phase.
    enqueued_tick: u64 = 0,
    enqueued_ns: i64 = 0,
    completed_ns: i64 = 0,
    /// Opaque tag for tracing/tests; the scheduler never interprets it.
    tag: u64 = 0,
    /// Invoked exactly once by the scheduler: from the completion queue with
    /// the op already marked `released`, or from `cancel` with the op marked
    /// `cancelled`. The callback may re-enqueue this op for another I/O phase;
    /// it must not call `tick` or `cancel` on another op.
    callback: ?*const fn (*Op) void = null,
    /// Class-queue linkage (intrusive FIFO list).
    queue_next: ?*Op = null,
    /// Completion-queue linkage (intrusive bounded list).
    cq_next: ?*Op = null,
};

/// Per-class operation slot and byte budget.
pub const ClassCapacity = struct {
    max_slots: usize = 1,
    /// 0 = bytes unlimited (slots still bound the class).
    max_bytes: u64 = 0,
};

pub const Config = struct {
    /// Per-class budgets. A class's admitted ops (queued + in-flight +
    /// completed-but-not-callbacked) never exceed these, so limiting only one
    /// budget cannot hide an unbounded queue in another.
    class_capacity: [Class.count]ClassCapacity = .{
        .{ .max_slots = 8, .max_bytes = 4 * 1024 * 1024 },
        .{ .max_slots = 256, .max_bytes = 32 * 1024 * 1024 },
        .{ .max_slots = 256, .max_bytes = 32 * 1024 * 1024 },
        .{ .max_slots = 4, .max_bytes = 8 * 1024 * 1024 },
    },
    /// Bounded completion queue: ops whose completion was extracted but whose
    /// callback has not yet run. When full, extraction stops; completions
    /// recorded while it is full wait in the bounded pending list.
    completion_queue_capacity: usize = 256,
    /// Maximum platform completions extracted per tick. Extraction records
    /// only results; callbacks run later, within `max_callbacks_per_tick`.
    max_extract_batch: usize = 64,
    /// Maximum callbacks processed per tick. When exhausted, remaining
    /// `callback_ready` ops wait for the next tick and the budget-exhaustion
    /// metric records the event.
    max_callbacks_per_tick: usize = 64,
    /// Optional CPU-time budget for one callback phase (ns); 0 disables.
    callback_time_budget_ns: u64 = 0,
    /// Shared per-tick submission budget. `critical` consumes it first, then
    /// `foreground_read`/`foreground_write`, then `maintenance` with the
    /// remainder. Must be at least `class_capacity[critical].max_slots` so
    /// critical I/O is never starved by the shared budget.
    tick_submit_budget_slots: usize = 256,
    /// Foreground round-robin: within one round (one rotation lap), each owner
    /// submits at most this many ops and bytes before the scheduler yields to
    /// other owners.
    foreground_per_owner_per_round: usize = 8,
    foreground_bytes_per_owner_per_round: u64 = 1024 * 1024,
    /// Upper bound on distinct owner ids (`owner < max_owners`). Preallocated
    /// round-robin accounting, so a tick never allocates.
    max_owners: usize = 1024,
    /// Backpressure watermarks per class (queued-count thresholds). Admission
    /// rejects with `error.Backpressure` once the queued count reaches `high`;
    /// while backpressured it keeps rejecting until the count falls to `low`,
    /// so one completion event cannot flap the class. `critical` never
    /// backpressures: its capacity is reserved for WAL/recovery/shutdown and
    /// must be configured with `high`/`low` both zero.
    backpressure_high: [Class.count]usize = .{ 0, 64, 64, 4 },
    backpressure_low: [Class.count]usize = .{ 0, 32, 32, 2 },
    /// Optional completion-queue age alert (ns); 0 disables. When a callback
    /// processes an op that waited longer, the class's `queue_age_alert`
    /// metric increments and `max_completion_age_ns` is updated.
    completion_queue_age_alert_ns: u64 = 0,
    /// Clock for age accounting; injectable for deterministic tests.
    now: *const fn (io: Io) i64 = defaultNow,
    /// Safety valve on rotation passes per submission phase; the pass count is
    /// also bounded by the queue length because each pass submits at least one
    /// op.
    max_submit_passes: usize = 1 << 16,
};

pub const InitError = error{ InvalidCapacity } || Allocator.Error;

/// Platform backend: sockets, files, or (in tests) a fake. The scheduler
/// submits ops and extracts completion events; the platform never runs
/// application callbacks.
pub const Platform = struct {
    ctx: ?*anyopaque = null,
    /// Submit one operation. Called only from the scheduler's submission
    /// phase, never from a callback. The platform must surface completion
    /// through `extract` and must not invoke application callbacks.
    submit: *const fn (ctx: ?*anyopaque, op: *Op) void,
    /// Extract up to `out.len` completed operations (each in `submitted`
    /// state). Returns the count written. Must not run application callbacks.
    extract: *const fn (ctx: ?*anyopaque, out: []*Op) usize,
};

pub const EnqueueError = error{
    /// The class is at or above its backpressure high watermark. The owner
    /// pauses at its earliest safe boundary; admission resumes at the low
    /// watermark.
    Backpressure,
    /// The class's slot or byte budget is exhausted. The owner pauses; a
    /// completion releases capacity.
    QueueFull,
    /// Critical capacity is exhausted. The caller stops admitting work that
    /// would create new persistent state and, if critical I/O cannot make
    /// progress, enters the instance-level failure path.
    CriticalCapacityExhausted,
    /// `owner` is not below `Config.max_owners`.
    InvalidOwner,
};

pub const CancelError = error{
    NotQueued,
    NotCancellable,
};

const OwnerRound = struct {
    touched: bool = false,
    count: usize = 0,
    bytes: u64 = 0,
};

pub const ClassMetrics = struct {
    /// Lifetime submissions to the platform (state entered `submitted`).
    submitted: u64 = 0,
    /// Lifetime platform completions extracted (state entered `completed`).
    completed: u64 = 0,
    /// Lifetime callbacks invoked from the completion queue.
    callbacked: u64 = 0,
    /// Lifetime cancellations of queued ops.
    cancelled: u64 = 0,
    peak_queue_depth: usize = 0,
    /// Entries into and exits from the backpressured state.
    backpressure_transitions: u64 = 0,
    backpressured: bool = false,
    /// Times a callback processed an op whose completion-queue wait exceeded
    /// `Config.completion_queue_age_alert_ns`.
    queue_age_alert: u64 = 0,
};

pub const Metrics = struct {
    ticks: u64 = 0,
    /// Highest nested callback depth observed. The scheduler asserts this
    /// stays one: callbacks never run the scheduler or each other.
    callback_depth_max: usize = 0,
    callback_budget_exhausted: u64 = 0,
    callback_time_budget_exhausted: u64 = 0,
    /// Total platform completion events extracted.
    extraction_events: u64 = 0,
    /// Times admission of a critical op failed because critical capacity was
    /// exhausted (the instance-failure signal).
    critical_capacity_exhausted: u64 = 0,
    /// Ticks where the shared submission budget hit zero with work still
    /// queued for a later class.
    submission_budget_exhausted: u64 = 0,
    /// Highest completion-queue wait observed (ns).
    max_completion_age_ns: u64 = 0,
    by_class: [Class.count]ClassMetrics = [_]ClassMetrics{.{}} ** Class.count,
};

/// Bounded work-queue scheduler. Single-threaded in this slice: `enqueue`,
/// `cancel`, and `tick` must not run concurrently. The runtime guards the
/// scheduler with a mutex when connection threads arrive.
pub const Scheduler = struct {
    gpa: Allocator,
    io: Io,
    config: Config,
    queue_head: [Class.count]?*Op = .{null} ** Class.count,
    queue_tail: [Class.count]?*Op = .{null} ** Class.count,
    queue_len: [Class.count]usize = .{0} ** Class.count,
    queue_bytes: [Class.count]u64 = .{0} ** Class.count,
    in_flight: [Class.count]usize = .{0} ** Class.count,
    in_flight_bytes: [Class.count]u64 = .{0} ** Class.count,
    /// Completed but not yet callbacked: ops in the completion queue plus the
    /// bounded pending list of completions extracted while the queue was full.
    completed_nc: [Class.count]usize = .{0} ** Class.count,
    cq_head: ?*Op = null,
    cq_tail: ?*Op = null,
    cq_len: usize = 0,
    completed_head: ?*Op = null,
    completed_tail: ?*Op = null,
    completed_len: usize = 0,
    tick_count: u64 = 0,
    in_tick: bool = false,
    in_callback: bool = false,
    /// Round-robin scratch, preallocated so ticks never allocate.
    owner_round: []OwnerRound,
    round_touched: std.ArrayList(u32),
    extract_buf: []*Op,
    metrics: Metrics = .{},

    pub fn init(gpa: Allocator, io: Io, config: Config) InitError!Scheduler {
        try validateConfig(config);
        const owner_round = try gpa.alloc(OwnerRound, config.max_owners);
        errdefer gpa.free(owner_round);
        var round_touched: std.ArrayList(u32) = .empty;
        errdefer round_touched.deinit(gpa);
        try round_touched.ensureTotalCapacity(gpa, config.max_owners);
        const extract_buf = try gpa.alloc(*Op, config.max_extract_batch);
        errdefer gpa.free(extract_buf);
        return .{
            .gpa = gpa,
            .io = io,
            .config = config,
            .owner_round = owner_round,
            .round_touched = round_touched,
            .extract_buf = extract_buf,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.gpa.free(self.owner_round);
        self.round_touched.deinit(self.gpa);
        self.gpa.free(self.extract_buf);
        self.* = undefined;
    }

    // ── Admission ──

    /// Admit one operation. `op` must currently be `released` (or `cancelled`)
    /// and must not already be owned by the scheduler. On success the
    /// scheduler owns the op until its callback runs or `cancel` releases it.
    pub fn enqueue(self: *Scheduler, op: *Op, class: Class, owner: u32, bytes: u64) EnqueueError!void {
        std.debug.assert(op.state == .released or op.state == .cancelled);
        if (owner >= self.config.max_owners) return error.InvalidOwner;
        const ci = @intFromEnum(class);
        const cap = self.config.class_capacity[ci];

        // Backpressure is an admission decision, not a hint. Critical capacity
        // is reserved for WAL/recovery/shutdown and never backpressures; its
        // full condition is the instance-failure signal below.
        if (class != .critical) {
            const bm = &self.metrics.by_class[ci];
            if (bm.backpressured) {
                // Hysteresis: keep rejecting until the queue drains to the low
                // watermark, so one completion event cannot flap the class.
                if (self.queue_len[ci] > self.config.backpressure_low[ci]) return error.Backpressure;
                bm.backpressured = false;
                bm.backpressure_transitions += 1;
            } else if (self.queue_len[ci] >= self.config.backpressure_high[ci]) {
                bm.backpressured = true;
                bm.backpressure_transitions += 1;
                return error.Backpressure;
            }
        }

        // Hard capacity across queued + in-flight + completed-not-callbacked:
        // slot and byte limits together bound the class.
        const nc = self.queue_len[ci] + self.in_flight[ci] + self.completed_nc[ci];
        const nc_bytes = self.queue_bytes[ci] + self.in_flight_bytes[ci];
        if (nc >= cap.max_slots or (cap.max_bytes != 0 and nc_bytes + bytes > cap.max_bytes)) {
            if (class == .critical) {
                self.metrics.critical_capacity_exhausted += 1;
                return error.CriticalCapacityExhausted;
            }
            return error.QueueFull;
        }

        op.state = .queued;
        op.class = class;
        op.owner = owner;
        op.bytes = bytes;
        op.enqueued_tick = self.tick_count;
        op.enqueued_ns = self.config.now(self.io);
        op.queue_next = null;
        op.cq_next = null;
        self.pushTail(ci, op);
        if (self.queue_len[ci] > self.metrics.by_class[ci].peak_queue_depth) {
            self.metrics.by_class[ci].peak_queue_depth = self.queue_len[ci];
        }
    }

    /// Cancel a queued, cancellable op before it is submitted. The op is
    /// removed from its class queue, marked `cancelled`, and its callback is
    /// invoked so the owner can release resources. A submitted op is never
    /// cancelled: cancellation after submission is cooperative.
    pub fn cancel(self: *Scheduler, op: *Op) CancelError!void {
        if (op.state != .queued) return error.NotQueued;
        if (!op.cancellable) return error.NotCancellable;
        const ci = @intFromEnum(op.class);
        var prev: ?*Op = null;
        var cur = self.queue_head[ci];
        while (cur) |c| {
            if (c == op) break;
            prev = cur;
            cur = c.queue_next;
        }
        if (cur == null) return error.NotQueued;
        if (prev) |p| {
            p.queue_next = op.queue_next;
        } else {
            self.queue_head[ci] = op.queue_next;
        }
        if (op.queue_next == null) self.queue_tail[ci] = prev;
        op.queue_next = null;
        self.queue_len[ci] -= 1;
        self.queue_bytes[ci] -= op.bytes;
        op.state = .cancelled;
        self.metrics.by_class[ci].cancelled += 1;
        self.maybeClearBackpressure(op.class);
        if (op.callback) |cb| self.invokeCallback(op, cb);
    }

    // ── Ticks ──

    /// Run one scheduler tick: bounded extraction, bounded callback
    /// processing, then a priority-ordered submission phase.
    pub fn tick(self: *Scheduler, platform: *Platform) void {
        std.debug.assert(!self.in_tick);
        self.in_tick = true;
        defer self.in_tick = false;
        self.tick_count += 1;
        self.metrics.ticks += 1;

        // 1. Move completions extracted while the completion queue was full
        //    into it (bounded by free space).
        self.drainCompleted();
        // 2. Extract platform completion events in a bounded batch; records
        //    only results, never runs callbacks.
        self.extract(platform);
        // 3. Process the completion queue within the callback budget.
        self.runCallbacks();
        // 4. Select and submit the next batch by class priority. Work enqueued
        //    by this tick's callbacks is deferred to the next tick's
        //    submission phase.
        self.submitReady(platform);
    }

    fn drainCompleted(self: *Scheduler) void {
        while (self.completed_head) |op| {
            if (self.cq_len >= self.config.completion_queue_capacity) break;
            self.completed_head = op.cq_next;
            if (self.completed_head == null) self.completed_tail = null;
            self.completed_len -= 1;
            op.cq_next = null;
            op.state = .callback_ready;
            self.appendCq(op);
        }
    }

    fn extract(self: *Scheduler, platform: *Platform) void {
        std.debug.assert(!self.in_callback);
        const count = platform.extract(platform.ctx, self.extract_buf);
        for (self.extract_buf[0..count]) |op| {
            std.debug.assert(op.state == .submitted);
            const ci = @intFromEnum(op.class);
            op.state = .completed;
            op.completed_ns = self.config.now(self.io);
            self.in_flight[ci] -= 1;
            self.in_flight_bytes[ci] -= op.bytes;
            self.completed_nc[ci] += 1;
            self.metrics.by_class[ci].completed += 1;
            self.metrics.extraction_events += 1;
            if (self.cq_len < self.config.completion_queue_capacity) {
                op.state = .callback_ready;
                self.appendCq(op);
            } else {
                // Completion queue full: record the completion and defer the
                // callback to the next tick's drain phase.
                op.cq_next = null;
                if (self.completed_head == null) {
                    self.completed_head = op;
                    self.completed_tail = op;
                } else {
                    self.completed_tail.?.cq_next = op;
                    self.completed_tail = op;
                }
                self.completed_len += 1;
            }
        }
    }

    fn runCallbacks(self: *Scheduler) void {
        var processed: usize = 0;
        const start = self.config.now(self.io);
        while (self.cq_head) |op| {
            if (processed >= self.config.max_callbacks_per_tick) {
                self.metrics.callback_budget_exhausted += 1;
                break;
            }
            if (self.config.callback_time_budget_ns != 0) {
                const elapsed: u64 = @intCast(self.config.now(self.io) - start);
                if (elapsed >= self.config.callback_time_budget_ns) {
                    self.metrics.callback_time_budget_exhausted += 1;
                    break;
                }
            }
            _ = self.popCq() orelse break;
            const ci = @intFromEnum(op.class);
            const age: u64 = @intCast(self.config.now(self.io) - op.enqueued_ns);
            if (age > self.metrics.max_completion_age_ns) self.metrics.max_completion_age_ns = age;
            if (self.config.completion_queue_age_alert_ns != 0 and age > self.config.completion_queue_age_alert_ns) {
                self.metrics.by_class[ci].queue_age_alert += 1;
            }
            self.completed_nc[ci] -= 1;
            self.metrics.by_class[ci].callbacked += 1;
            op.state = .released;
            if (op.callback) |cb| self.invokeCallback(op, cb);
            processed += 1;
        }
    }

    fn submitReady(self: *Scheduler, platform: *Platform) void {
        var budget = self.config.tick_submit_budget_slots;
        budget = self.submitClass(platform, .critical, budget);
        budget = self.submitClass(platform, .foreground_read, budget);
        budget = self.submitClass(platform, .foreground_write, budget);
        _ = self.submitClass(platform, .maintenance, budget);
        if (budget == 0 and self.anyQueued()) {
            self.metrics.submission_budget_exhausted += 1;
        }
    }

    fn anyQueued(self: *const Scheduler) bool {
        for (self.queue_len) |len| if (len != 0) return true;
        return false;
    }

    /// Submit queued ops of `class` up to `budget_slots` (the shared per-tick
    /// budget), the class's in-flight capacity, and the round-robin rules.
    /// Returns the remaining budget.
    fn submitClass(self: *Scheduler, platform: *Platform, class: Class, budget_slots: usize) usize {
        if (budget_slots == 0) return 0;
        const ci = @intFromEnum(class);
        const cap = self.config.class_capacity[ci];
        const foreground = class == .foreground_read or class == .foreground_write;
        // Fresh round-robin accounting for this batch (one round per tick per
        // class): reset owners touched by the previous batch. This is what
        // makes a round a per-tick concept — an owner submits at most
        // `foreground_per_owner_per_round` ops per tick regardless of how much
        // queue it has.
        for (self.round_touched.items) |owner| self.owner_round[owner] = .{};
        self.round_touched.clearRetainingCapacity();
        var submitted: usize = 0;
        var pass: usize = 0;
        while (pass < self.config.max_submit_passes) : (pass += 1) {
            const start_len = self.queue_len[ci];
            if (start_len == 0 or submitted >= budget_slots) break;
            var made_progress = false;
            var examined: usize = 0;
            while (examined < start_len) : (examined += 1) {
                if (submitted >= budget_slots) break;
                const op = self.popHead(ci) orelse break;
                // Work enqueued during this tick's callback phase is submitted
                // in the next tick's submission phase.
                if (op.enqueued_tick >= self.tick_count) {
                    self.pushTail(ci, op);
                    continue;
                }
                if (foreground) {
                    const round = &self.owner_round[op.owner];
                    if (!round.touched) {
                        round.* = .{ .touched = true, .count = 0, .bytes = 0 };
                        self.round_touched.appendAssumeCapacity(op.owner);
                    }
                    if (round.count >= self.config.foreground_per_owner_per_round or
                        round.bytes + op.bytes > self.config.foreground_bytes_per_owner_per_round)
                    {
                        // Yield to other owners; retried in the next round.
                        self.pushTail(ci, op);
                        continue;
                    }
                }
                // In-flight capacity check; restore the op and stop on
                // exhaustion so we never over-submit the class.
                if (self.in_flight[ci] + 1 > cap.max_slots or
                    (cap.max_bytes != 0 and self.in_flight_bytes[ci] + op.bytes > cap.max_bytes))
                {
                    self.pushFront(ci, op);
                    break;
                }
                op.state = .submitted;
                self.in_flight[ci] += 1;
                self.in_flight_bytes[ci] += op.bytes;
                self.metrics.by_class[ci].submitted += 1;
                if (foreground) {
                    const round = &self.owner_round[op.owner];
                    round.count += 1;
                    round.bytes += op.bytes;
                }
                platform.submit(platform.ctx, op);
                submitted += 1;
                made_progress = true;
            }
            if (!made_progress) break;
        }
        self.maybeClearBackpressure(class);
        return budget_slots - submitted;
    }

    fn maybeClearBackpressure(self: *Scheduler, class: Class) void {
        const ci = @intFromEnum(class);
        const bm = &self.metrics.by_class[ci];
        if (bm.backpressured and self.queue_len[ci] <= self.config.backpressure_low[ci]) {
            bm.backpressured = false;
            bm.backpressure_transitions += 1;
        }
    }

    // ── Intrusive list helpers ──
    //
    // `pushTail`/`pushFront` maintain `queue_len`/`queue_bytes`; `popHead`
    // decrements them. Rotations in the submission phase (deferred ops,
    // owner round caps, capacity-full restores) therefore leave the counters
    // net unchanged, and `enqueue` uses `pushTail` without extra accounting.

    fn pushTail(self: *Scheduler, ci: usize, op: *Op) void {
        op.queue_next = null;
        if (self.queue_tail[ci]) |tail| {
            tail.queue_next = op;
        } else {
            self.queue_head[ci] = op;
        }
        self.queue_tail[ci] = op;
        self.queue_len[ci] += 1;
        self.queue_bytes[ci] += op.bytes;
    }

    fn pushFront(self: *Scheduler, ci: usize, op: *Op) void {
        op.queue_next = self.queue_head[ci];
        self.queue_head[ci] = op;
        if (self.queue_tail[ci] == null) self.queue_tail[ci] = op;
        self.queue_len[ci] += 1;
        self.queue_bytes[ci] += op.bytes;
    }

    fn popHead(self: *Scheduler, ci: usize) ?*Op {
        const head = self.queue_head[ci] orelse return null;
        self.queue_head[ci] = head.queue_next;
        if (self.queue_head[ci] == null) self.queue_tail[ci] = null;
        head.queue_next = null;
        self.queue_len[ci] -= 1;
        self.queue_bytes[ci] -= head.bytes;
        return head;
    }

    fn appendCq(self: *Scheduler, op: *Op) void {
        op.cq_next = null;
        if (self.cq_tail) |tail| {
            tail.cq_next = op;
        } else {
            self.cq_head = op;
        }
        self.cq_tail = op;
        self.cq_len += 1;
    }

    fn popCq(self: *Scheduler) ?*Op {
        const head = self.cq_head orelse return null;
        self.cq_head = head.cq_next;
        if (self.cq_head == null) self.cq_tail = null;
        head.cq_next = null;
        self.cq_len -= 1;
        return head;
    }

    fn invokeCallback(self: *Scheduler, op: *Op, cb: *const fn (*Op) void) void {
        // Callback depth stays one: a callback may change its own op's state,
        // release resources, or enqueue follow-up work, but it must not run
        // the scheduler or cancel another op (which would nest callbacks).
        std.debug.assert(!self.in_callback);
        self.in_callback = true;
        if (self.metrics.callback_depth_max < 1) self.metrics.callback_depth_max = 1;
        cb(op);
        self.in_callback = false;
    }

    // ── Observability ──

    pub fn queuedCount(self: *const Scheduler, class: Class) usize {
        return self.queue_len[@intFromEnum(class)];
    }

    pub fn inFlightCount(self: *const Scheduler, class: Class) usize {
        return self.in_flight[@intFromEnum(class)];
    }

    pub fn completedNotCallbacked(self: *const Scheduler, class: Class) usize {
        return self.completed_nc[@intFromEnum(class)];
    }

    pub fn backpressured(self: *const Scheduler, class: Class) bool {
        return self.metrics.by_class[@intFromEnum(class)].backpressured;
    }

    pub fn classMetrics(self: *const Scheduler, class: Class) ClassMetrics {
        return self.metrics.by_class[@intFromEnum(class)];
    }

    pub fn metricsSnapshot(self: *const Scheduler) Metrics {
        return self.metrics;
    }

    /// True when no op is queued, in flight, or awaiting a callback.
    pub fn isIdle(self: *const Scheduler) bool {
        for (self.queue_len) |len| if (len != 0) return false;
        for (self.in_flight) |n| if (n != 0) return false;
        if (self.cq_len != 0 or self.completed_len != 0) return false;
        return true;
    }
};

fn validateConfig(config: Config) InitError!void {
    const critical_ci = @intFromEnum(Class.critical);
    if (config.class_capacity[critical_ci].max_slots < 1) return error.InvalidCapacity;
    // Critical I/O is replenished first and must never be starved by the
    // shared per-tick submission budget.
    if (config.tick_submit_budget_slots < config.class_capacity[critical_ci].max_slots) return error.InvalidCapacity;
    if (config.completion_queue_capacity < 1) return error.InvalidCapacity;
    if (config.max_extract_batch < 1) return error.InvalidCapacity;
    if (config.max_callbacks_per_tick < 1) return error.InvalidCapacity;
    if (config.foreground_per_owner_per_round < 1) return error.InvalidCapacity;
    if (config.max_owners < 1) return error.InvalidCapacity;
    if (config.max_submit_passes < 1) return error.InvalidCapacity;
    for (config.class_capacity) |cap| {
        if (cap.max_slots < 1) return error.InvalidCapacity;
    }
    for (0..Class.count) |i| {
        if (config.backpressure_high[i] < config.backpressure_low[i]) return error.InvalidCapacity;
        if (i == critical_ci) {
            // Critical capacity is reserved; it never backpressures.
            if (config.backpressure_high[i] != 0 or config.backpressure_low[i] != 0) return error.InvalidCapacity;
        }
    }
}

fn defaultNow(io: Io) i64 {
    return @intCast(Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
}

// ── Tests ──

const FakePlatform = struct {
    gpa: Allocator,
    /// Ops the platform completed and not yet extracted, in completion order.
    completed: std.ArrayList(*Op),
    /// Submission order observed by the platform, for priority/order tests.
    submitted_log: std.ArrayList(*Op),
    submitted_count: usize = 0,
    /// When true, `submit` completes the op immediately (appends to
    /// `completed`). When false, tests complete ops explicitly with
    /// `complete`.
    immediate: bool,

    fn init(gpa: Allocator, immediate: bool) FakePlatform {
        return .{
            .gpa = gpa,
            .completed = .empty,
            .submitted_log = .empty,
            .immediate = immediate,
        };
    }

    fn deinit(self: *FakePlatform) void {
        self.completed.deinit(self.gpa);
        self.submitted_log.deinit(self.gpa);
        self.* = undefined;
    }

    fn submitCb(ctx: ?*anyopaque, op: *Op) void {
        const self: *FakePlatform = @ptrCast(@alignCast(ctx.?));
        self.submitted_count += 1;
        self.submitted_log.append(self.gpa, op) catch unreachable;
        if (self.immediate) self.completed.append(self.gpa, op) catch unreachable;
    }

    fn extractCb(ctx: ?*anyopaque, out: []*Op) usize {
        const self: *FakePlatform = @ptrCast(@alignCast(ctx.?));
        var n: usize = 0;
        while (n < out.len and self.completed.items.len > 0) : (n += 1) {
            out[n] = self.completed.orderedRemove(0);
        }
        return n;
    }

    /// Manually complete an in-flight op (state `.submitted`).
    fn complete(self: *FakePlatform, op: *Op) void {
        std.debug.assert(op.state == .submitted);
        self.completed.append(self.gpa, op) catch unreachable;
    }

    fn platform(self: *FakePlatform) Platform {
        return .{ .ctx = self, .submit = submitCb, .extract = extractCb };
    }
};

/// Minimal capacity config for tests: one slot per class where not overridden,
/// small budgets, and 16 owner ids.
fn testConfig() Config {
    return .{
        .class_capacity = .{
            .{ .max_slots = 8, .max_bytes = 0 },
            .{ .max_slots = 8, .max_bytes = 0 },
            .{ .max_slots = 8, .max_bytes = 0 },
            .{ .max_slots = 8, .max_bytes = 0 },
        },
        .completion_queue_capacity = 16,
        .max_extract_batch = 8,
        .max_callbacks_per_tick = 8,
        .tick_submit_budget_slots = 8,
        .foreground_per_owner_per_round = 8,
        .max_owners = 16,
        .backpressure_high = .{ 0, 8, 8, 8 },
        .backpressure_low = .{ 0, 4, 4, 4 },
    };
}

var g_callback_count: usize = 0;

fn countCallback(op: *Op) void {
    _ = op;
    g_callback_count += 1;
}

/// Drain ticks until the scheduler is idle and the platform has nothing left
/// to extract. Immediate platforms need a couple of ticks per submission
/// round; chains of callback-enqueued follow-ups need one tick per hop.
fn drain(sched: *Scheduler, platform: *Platform) void {
    var guard: usize = 0;
    while (!sched.isIdle() or (platform.ctx != null and platformHasCompletions(platform))) : (guard += 1) {
        std.debug.assert(guard < 10_000);
        sched.tick(platform);
    }
}

fn platformHasCompletions(platform: *const Platform) bool {
    const fake: *const FakePlatform = @ptrCast(@alignCast(platform.ctx.?));
    return fake.completed.items.len != 0;
}

test "ops flow through the state machine and all counters balance" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sched = try Scheduler.init(gpa, io, testConfig());
    defer sched.deinit();
    var platform = FakePlatform.init(gpa, true);
    defer platform.deinit();
    var plat = platform.platform();

    const n = 5;
    const ops = try gpa.alloc(Op, n);
    defer gpa.free(ops);
    g_callback_count = 0;
    for (ops, 0..) |*op, i| {
        op.* = .{ .owner = 0, .tag = @intCast(i), .callback = countCallback };
        try sched.enqueue(op, .foreground_read, 0, 10);
        try std.testing.expectEqual(State.queued, op.state);
    }
    try std.testing.expectEqual(@as(usize, n), sched.queuedCount(.foreground_read));

    // Tick 1 submits the batch; tick 2 extracts and callbacks it.
    sched.tick(&plat);
    for (ops) |*op| try std.testing.expectEqual(State.submitted, op.state);
    sched.tick(&plat);
    for (ops) |*op| try std.testing.expectEqual(State.released, op.state);

    try std.testing.expectEqual(@as(usize, n), g_callback_count);
    try std.testing.expectEqual(@as(usize, n), sched.classMetrics(.foreground_read).submitted);
    try std.testing.expectEqual(@as(usize, n), sched.classMetrics(.foreground_read).completed);
    try std.testing.expectEqual(@as(usize, n), sched.classMetrics(.foreground_read).callbacked);
    try std.testing.expectEqual(@as(usize, 0), sched.inFlightCount(.foreground_read));
    try std.testing.expectEqual(@as(usize, 0), sched.queuedCount(.foreground_read));
    try std.testing.expect(sched.isIdle());
}

test "callback-enqueued follow-ups are submitted only in the next tick" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sched = try Scheduler.init(gpa, io, testConfig());
    defer sched.deinit();
    var platform = FakePlatform.init(gpa, true);
    defer platform.deinit();
    var plat = platform.platform();

    var follow_up = Op{ .owner = 0, .callback = countCallback };
    const ChainCb = struct {
        fn cb(op: *Op) void {
            _ = op;
            g_callback_count += 1;
            // The scheduler is reachable through the global; this enqueue must
            // not submit to the platform during the same tick.
            g_chained_sched.?.enqueue(g_chained_follow_up.?, .foreground_read, 0, 1) catch unreachable;
        }
    };

    var head = Op{ .owner = 0, .callback = ChainCb.cb };
    g_chained_sched = &sched;
    g_chained_follow_up = &follow_up;
    defer {
        g_chained_sched = null;
        g_chained_follow_up = null;
    }

    g_callback_count = 0;
    try sched.enqueue(&head, .foreground_read, 0, 10);

    // Tick 1: head submits (and completes instantly into the platform).
    sched.tick(&plat);
    try std.testing.expectEqual(State.submitted, head.state);
    try std.testing.expectEqual(@as(usize, 1), platform.submitted_count);
    try std.testing.expectEqual(State.released, follow_up.state);

    // Tick 2: head is extracted and callbacked; the follow-up is enqueued
    // during the callback phase, so it stays queued until the next tick.
    sched.tick(&plat);
    try std.testing.expectEqual(State.released, head.state);
    try std.testing.expectEqual(@as(usize, 1), g_callback_count);
    try std.testing.expectEqual(State.queued, follow_up.state);
    try std.testing.expectEqual(@as(usize, 1), platform.submitted_count);
    try std.testing.expectEqual(@as(u64, 2), follow_up.enqueued_tick);

    // Tick 3 submits the follow-up; tick 4 callbacks it.
    sched.tick(&plat);
    try std.testing.expectEqual(State.submitted, follow_up.state);
    try std.testing.expectEqual(@as(usize, 2), platform.submitted_count);
    sched.tick(&plat);
    try std.testing.expectEqual(State.released, follow_up.state);
    try std.testing.expectEqual(@as(usize, 2), g_callback_count);
    try std.testing.expect(sched.isIdle());
}

var g_chained_sched: ?*Scheduler = null;
var g_chained_follow_up: ?*Op = null;

test "critical submits first, foreground next, maintenance only with the remaining budget" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cfg = testConfig();
    cfg.tick_submit_budget_slots = 3;
    cfg.class_capacity[@intFromEnum(Class.critical)] = .{ .max_slots = 1, .max_bytes = 0 };
    var sched = try Scheduler.init(gpa, io, cfg);
    defer sched.deinit();
    var platform = FakePlatform.init(gpa, true);
    defer platform.deinit();
    var plat = platform.platform();

    var maintenance_op = Op{ .owner = 0, .tag = 30 };
    var fg_ops = [_]Op{ .{ .owner = 0, .tag = 10 }, .{ .owner = 0, .tag = 11 } };
    var critical_op = Op{ .owner = 0, .tag = 20 };

    try sched.enqueue(&maintenance_op, .maintenance, 0, 1);
    try sched.enqueue(&fg_ops[0], .foreground_read, 0, 1);
    try sched.enqueue(&fg_ops[1], .foreground_read, 0, 1);
    try sched.enqueue(&critical_op, .critical, 0, 1);

    sched.tick(&plat);
    // Budget 3: critical first, then foreground, then maintenance gets nothing.
    try std.testing.expectEqual(State.submitted, critical_op.state);
    try std.testing.expectEqual(State.submitted, fg_ops[0].state);
    try std.testing.expectEqual(State.submitted, fg_ops[1].state);
    try std.testing.expectEqual(State.queued, maintenance_op.state);
    try std.testing.expect(platform.submitted_log.items[0] == &critical_op);
    try std.testing.expect(platform.submitted_log.items[1] == &fg_ops[0]);
    try std.testing.expectEqual(@as(u64, 1), sched.metricsSnapshot().submission_budget_exhausted);

    // Next tick extracts the three and — with a fresh per-tick budget — lets
    // maintenance progress: it was only starved by the previous tick's budget.
    sched.tick(&plat);
    try std.testing.expectEqual(State.released, critical_op.state);
    try std.testing.expectEqual(State.released, fg_ops[0].state);
    try std.testing.expectEqual(State.released, fg_ops[1].state);
    try std.testing.expectEqual(State.submitted, maintenance_op.state);
    sched.tick(&plat); // extract maintenance
    try std.testing.expectEqual(State.released, maintenance_op.state);
    try std.testing.expectEqual(@as(u64, 1), sched.classMetrics(.maintenance).submitted);
    try std.testing.expect(sched.isIdle());
}

test "foreground round-robin caps each owner per round and preserves per-owner order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cfg = testConfig();
    cfg.foreground_per_owner_per_round = 2;
    cfg.tick_submit_budget_slots = 8;
    var sched = try Scheduler.init(gpa, io, cfg);
    defer sched.deinit();
    var platform = FakePlatform.init(gpa, true);
    defer platform.deinit();
    var plat = platform.platform();

    var ops_a = [_]Op{.{ .owner = 0, .tag = 0 }} ** 4;
    var ops_b = [_]Op{.{ .owner = 1, .tag = 100 }} ** 4;
    for (&ops_a, 0..) |*op, i| op.tag = i;
    for (&ops_b, 0..) |*op, i| op.tag = 100 + i;
    for (&ops_a) |*op| try sched.enqueue(op, .foreground_read, 0, 1);
    for (&ops_b) |*op| try sched.enqueue(op, .foreground_read, 1, 1);

    sched.tick(&plat);
    // Per round (one rotation lap), each owner submits at most 2 ops.
    try std.testing.expectEqual(@as(usize, 4), platform.submitted_log.items.len);
    const m = sched.classMetrics(.foreground_read);
    try std.testing.expectEqual(@as(u64, 4), m.submitted);

    // Owner 0 submitted exactly its first two ops (tags 0,1) before the
    // scheduler yielded to owner 1 (tags 100,101), then the round repeats.
    try std.testing.expect(platform.submitted_log.items[0] == &ops_a[0]);
    try std.testing.expect(platform.submitted_log.items[1] == &ops_a[1]);
    try std.testing.expect(platform.submitted_log.items[2] == &ops_b[0]);
    try std.testing.expect(platform.submitted_log.items[3] == &ops_b[1]);

    // Two more ticks drain the rest; per-owner submission order is preserved.
    sched.tick(&plat); // extract round 1; submit round 2 (tags 2,3 and 102,103)
    try std.testing.expectEqual(@as(usize, 8), platform.submitted_log.items.len);
    try std.testing.expect(platform.submitted_log.items[4] == &ops_a[2]);
    try std.testing.expect(platform.submitted_log.items[5] == &ops_a[3]);
    try std.testing.expect(platform.submitted_log.items[6] == &ops_b[2]);
    try std.testing.expect(platform.submitted_log.items[7] == &ops_b[3]);
    sched.tick(&plat);
    for (&ops_a) |*op| try std.testing.expectEqual(State.released, op.state);
    for (&ops_b) |*op| try std.testing.expectEqual(State.released, op.state);
    try std.testing.expect(sched.isIdle());
}

test "backpressure uses hysteresis and capacity exhaustion is explicit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cfg = testConfig();
    cfg.class_capacity[@intFromEnum(Class.foreground_read)] = .{ .max_slots = 4, .max_bytes = 0 };
    cfg.backpressure_high[@intFromEnum(Class.foreground_read)] = 3;
    cfg.backpressure_low[@intFromEnum(Class.foreground_read)] = 1;
    // One op per round so each tick drains exactly one queued op.
    cfg.foreground_per_owner_per_round = 1;
    var sched = try Scheduler.init(gpa, io, cfg);
    defer sched.deinit();
    var platform = FakePlatform.init(gpa, true);
    defer platform.deinit();
    var plat = platform.platform();

    var ops = [_]Op{.{}} ** 4;
    try sched.enqueue(&ops[0], .foreground_read, 0, 1);
    try sched.enqueue(&ops[1], .foreground_read, 0, 1);
    try sched.enqueue(&ops[2], .foreground_read, 0, 1);
    // High watermark reached: admission rejects.
    try std.testing.expectError(error.Backpressure, sched.enqueue(&ops[3], .foreground_read, 0, 1));
    try std.testing.expect(sched.backpressured(.foreground_read));
    try std.testing.expectEqual(@as(u64, 1), sched.classMetrics(.foreground_read).backpressure_transitions);

    // One submission drains to 2 queued — still above the low watermark of 1,
    // so admission keeps rejecting (no flap from a single completion).
    sched.tick(&plat);
    try std.testing.expectEqual(@as(usize, 2), sched.queuedCount(.foreground_read));
    try std.testing.expectError(error.Backpressure, sched.enqueue(&ops[3], .foreground_read, 0, 1));
    try std.testing.expect(sched.backpressured(.foreground_read));

    // A second submission drains to 1 == low: backpressure clears.
    sched.tick(&plat);
    try std.testing.expectEqual(@as(usize, 1), sched.queuedCount(.foreground_read));
    try std.testing.expect(!sched.backpressured(.foreground_read));
    try std.testing.expectEqual(@as(u64, 2), sched.classMetrics(.foreground_read).backpressure_transitions);
    try sched.enqueue(&ops[3], .foreground_read, 0, 1);
    try std.testing.expectEqual(@as(usize, 2), sched.queuedCount(.foreground_read));

    // The slot bound is a separate, hard limit: with 2 slots, no backpressure
    // watermark, and both slots occupied (queued or in flight), admission
    // rejects with QueueFull and recovers when a slot frees.
    var cfg2 = testConfig();
    cfg2.class_capacity[@intFromEnum(Class.foreground_read)] = .{ .max_slots = 2, .max_bytes = 0 };
    cfg2.backpressure_high[@intFromEnum(Class.foreground_read)] = 8;
    cfg2.backpressure_low[@intFromEnum(Class.foreground_read)] = 8;
    var sched2 = try Scheduler.init(gpa, io, cfg2);
    defer sched2.deinit();
    var platform2 = FakePlatform.init(gpa, true);
    defer platform2.deinit();
    var plat2 = platform2.platform();
    var bound_ops = [_]Op{.{}} ** 2;
    try sched2.enqueue(&bound_ops[0], .foreground_read, 0, 1);
    try sched2.enqueue(&bound_ops[1], .foreground_read, 0, 1);
    var extra = Op{};
    try std.testing.expectError(error.QueueFull, sched2.enqueue(&extra, .foreground_read, 0, 1));
    // Both submitted in one tick (per-owner round default 8): still full.
    sched2.tick(&plat2);
    try std.testing.expectError(error.QueueFull, sched2.enqueue(&extra, .foreground_read, 0, 1));
    // Extraction + callbacks release the slots.
    sched2.tick(&plat2);
    try std.testing.expect(sched2.isIdle());
    try sched2.enqueue(&extra, .foreground_read, 0, 1);

    // Hysteresis instance: finish the drained queue. With per_owner_per_round
    // 1, ops[2] and ops[3] are submitted in separate ticks, then drained.
    sched.tick(&plat); // extract ops[1]; submit ops[2]
    sched.tick(&plat); // extract ops[2]; submit ops[3]
    sched.tick(&plat); // extract ops[3]
    try std.testing.expect(sched.isIdle());
}

test "critical capacity exhaustion is the instance-failure signal and recovers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cfg = testConfig();
    cfg.class_capacity[@intFromEnum(Class.critical)] = .{ .max_slots = 1, .max_bytes = 0 };
    var sched = try Scheduler.init(gpa, io, cfg);
    defer sched.deinit();
    var platform = FakePlatform.init(gpa, false); // manual completions
    defer platform.deinit();
    var plat = platform.platform();

    var op1 = Op{};
    var op2 = Op{};
    try sched.enqueue(&op1, .critical, 0, 1);
    sched.tick(&plat); // op1 goes in flight
    try std.testing.expectEqual(State.submitted, op1.state);
    try std.testing.expectError(error.CriticalCapacityExhausted, sched.enqueue(&op2, .critical, 0, 1));
    try std.testing.expectEqual(@as(u64, 1), sched.metricsSnapshot().critical_capacity_exhausted);

    // A completed critical op releases the slot: admission resumes.
    platform.complete(&op1);
    sched.tick(&plat);
    try std.testing.expectEqual(State.released, op1.state);
    try sched.enqueue(&op2, .critical, 0, 1);
    sched.tick(&plat);
    try std.testing.expectEqual(State.submitted, op2.state);
    platform.complete(&op2);
    sched.tick(&plat);
    try std.testing.expectEqual(State.released, op2.state);
    try std.testing.expect(sched.isIdle());
}

test "callback budget exhaustion defers work to the next tick" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cfg = testConfig();
    cfg.max_callbacks_per_tick = 2;
    cfg.completion_queue_capacity = 16;
    var sched = try Scheduler.init(gpa, io, cfg);
    defer sched.deinit();
    var platform = FakePlatform.init(gpa, true);
    defer platform.deinit();
    var plat = platform.platform();

    const n = 5;
    const ops = try gpa.alloc(Op, n);
    defer gpa.free(ops);
    g_callback_count = 0;
    for (ops) |*op| {
        op.* = .{ .owner = 0, .callback = countCallback };
        try sched.enqueue(op, .foreground_read, 0, 1);
    }
    sched.tick(&plat); // submit all 5; they complete instantly into the platform

    // Tick 2: extract all 5 into the completion queue; only 2 callbacks run.
    sched.tick(&plat);
    try std.testing.expectEqual(@as(usize, 2), g_callback_count);
    try std.testing.expectEqual(@as(usize, 3), sched.completedNotCallbacked(.foreground_read));
    try std.testing.expectEqual(@as(u64, 1), sched.metricsSnapshot().callback_budget_exhausted);

    // Tick 3: 2 more callbacks; tick 4: the last one.
    sched.tick(&plat);
    try std.testing.expectEqual(@as(usize, 4), g_callback_count);
    try std.testing.expectEqual(@as(u64, 2), sched.metricsSnapshot().callback_budget_exhausted);
    sched.tick(&plat);
    try std.testing.expectEqual(@as(usize, 5), g_callback_count);
    try std.testing.expectEqual(@as(usize, 0), sched.completedNotCallbacked(.foreground_read));
    for (ops) |*op| try std.testing.expectEqual(State.released, op.state);
    try std.testing.expect(sched.isIdle());
}

test "a full completion queue throttles extraction without losing completions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cfg = testConfig();
    cfg.completion_queue_capacity = 2;
    cfg.max_extract_batch = 4;
    cfg.max_callbacks_per_tick = 4;
    var sched = try Scheduler.init(gpa, io, cfg);
    defer sched.deinit();
    var platform = FakePlatform.init(gpa, false); // manual completions
    defer platform.deinit();
    var plat = platform.platform();

    const n = 4;
    const ops = try gpa.alloc(Op, n);
    defer gpa.free(ops);
    g_callback_count = 0;
    for (ops) |*op| {
        op.* = .{ .owner = 0, .callback = countCallback };
        try sched.enqueue(op, .foreground_read, 0, 1);
    }
    sched.tick(&plat); // all 4 in flight
    for (ops) |*op| platform.complete(op);

    // Tick 2: extract all 4; only 2 fit the completion queue, the other 2 are
    // recorded as completed and wait in the bounded pending list. Two callbacks
    // run (the queue's 2); the pending 2 stay completed-but-not-callbacked.
    sched.tick(&plat);
    try std.testing.expectEqual(@as(usize, 2), g_callback_count);
    try std.testing.expectEqual(@as(usize, 2), sched.completedNotCallbacked(.foreground_read));
    try std.testing.expectEqual(@as(u64, 4), sched.metricsSnapshot().extraction_events);

    // Tick 3: the pending completions enter the queue and are callbacked.
    sched.tick(&plat);
    try std.testing.expectEqual(@as(usize, 4), g_callback_count);
    try std.testing.expectEqual(@as(usize, 0), sched.completedNotCallbacked(.foreground_read));
    for (ops) |*op| try std.testing.expectEqual(State.released, op.state);
    try std.testing.expect(sched.isIdle());
}

test "cancel releases a queued cancellable op exactly once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sched = try Scheduler.init(gpa, io, testConfig());
    defer sched.deinit();
    var platform = FakePlatform.init(gpa, false);
    defer platform.deinit();
    var plat = platform.platform();

    var cancellable_op = Op{ .owner = 0, .cancellable = true, .callback = countCallback };
    var fixed_op = Op{ .owner = 0, .cancellable = false, .callback = countCallback };
    g_callback_count = 0;
    try sched.enqueue(&cancellable_op, .maintenance, 0, 1);
    try sched.enqueue(&fixed_op, .maintenance, 0, 1);

    // A non-cancellable op cannot be cancelled.
    try std.testing.expectError(error.NotCancellable, sched.cancel(&fixed_op));
    try std.testing.expectEqual(State.queued, fixed_op.state);

    // A submitted op cannot be cancelled.
    sched.tick(&plat);
    try std.testing.expectEqual(State.submitted, fixed_op.state);
    try std.testing.expectError(error.NotQueued, sched.cancel(&fixed_op));

    // A queued cancellable op cancels, invokes its callback, and frees its slot.
    var second = Op{ .owner = 0, .cancellable = true, .callback = countCallback };
    try sched.enqueue(&second, .maintenance, 0, 1);
    try std.testing.expectEqual(@as(usize, 1), sched.queuedCount(.maintenance));
    try sched.cancel(&second);
    try std.testing.expectEqual(State.cancelled, second.state);
    try std.testing.expectEqual(@as(usize, 1), g_callback_count);
    try std.testing.expectEqual(@as(usize, 0), sched.queuedCount(.maintenance));
    try std.testing.expectEqual(@as(u64, 1), sched.classMetrics(.maintenance).cancelled);
    // The cancelled op may be re-enqueued (state `cancelled` is reusable).
    try sched.enqueue(&second, .maintenance, 0, 1);

    // Clean up: complete the in-flight ops, then the re-enqueued op once it is
    // submitted, and drain deterministically.
    platform.complete(&fixed_op);
    platform.complete(&cancellable_op);
    sched.tick(&plat); // extract fixed+cancellable; submit `second`
    try std.testing.expectEqual(State.submitted, second.state);
    platform.complete(&second);
    sched.tick(&plat); // extract + callback `second`
    try std.testing.expectEqual(State.released, second.state);
    try std.testing.expect(sched.isIdle());
}

test "capacity and watermark validation rejects broken configurations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var no_critical = testConfig();
    no_critical.class_capacity[@intFromEnum(Class.critical)] = .{ .max_slots = 0, .max_bytes = 0 };
    try std.testing.expectError(error.InvalidCapacity, Scheduler.init(gpa, io, no_critical));

    var starved_critical = testConfig();
    starved_critical.class_capacity[@intFromEnum(Class.critical)] = .{ .max_slots = 16, .max_bytes = 0 };
    starved_critical.tick_submit_budget_slots = 8;
    try std.testing.expectError(error.InvalidCapacity, Scheduler.init(gpa, io, starved_critical));

    var bad_watermark = testConfig();
    bad_watermark.backpressure_high[@intFromEnum(Class.foreground_read)] = 1;
    bad_watermark.backpressure_low[@intFromEnum(Class.foreground_read)] = 4;
    try std.testing.expectError(error.InvalidCapacity, Scheduler.init(gpa, io, bad_watermark));

    var critical_backpressure = testConfig();
    critical_backpressure.backpressure_high[@intFromEnum(Class.critical)] = 2;
    critical_backpressure.backpressure_low[@intFromEnum(Class.critical)] = 1;
    try std.testing.expectError(error.InvalidCapacity, Scheduler.init(gpa, io, critical_backpressure));

    var ok = try Scheduler.init(gpa, io, testConfig());
    ok.deinit();
}

test "invalid owner id is rejected at admission" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sched = try Scheduler.init(gpa, io, testConfig());
    defer sched.deinit();
    var platform = FakePlatform.init(gpa, false);
    defer platform.deinit();

    var op = Op{};
    const max_owners: u32 = @intCast(testConfig().max_owners);
    try std.testing.expectError(error.InvalidOwner, sched.enqueue(&op, .foreground_read, max_owners, 1));
    try std.testing.expectError(error.InvalidOwner, sched.enqueue(&op, .foreground_read, std.math.maxInt(u32), 1));
    _ = &platform;
}
