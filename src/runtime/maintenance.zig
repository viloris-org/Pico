//! Bounded maintenance worker for the RunaDB runtime (roadmap Phase 5/6:
//! "scheduler-integrated background flush/compaction scheduling with
//! backpressure").
//!
//! This module is the second slice of the I/O scheduling contract in
//! `docs/architecture/io-scheduling.md`: the scheduler core
//! (`src/runtime/scheduler.zig`) defines operation states, fixed per-class
//! capacity, and the tick discipline against a fake platform backend; this
//! module supplies a **real worker-thread platform backend** and the
//! cross-thread admission boundary that a running instance needs.
//!
//! ## Ownership and threading model
//!
//! A single worker thread owns the `Scheduler` exclusively: it admits inbound
//! jobs into the scheduler's `maintenance` class, runs the tick (which submits
//! ready ops to the platform and processes completions inside the callback
//! budget), and then runs every platform-submitted job itself — compaction,
//! checkpoint preparation, or other cancellable cleanup — on the same thread,
//! **outside** the scheduler and the engine statement lock. Owners never touch
//! the scheduler: they push jobs into a bounded, mutex-guarded inbound queue
//! and observe outcomes through each job's `on_done` callback.
//!
//! Admission is an admission decision, not a hint:
//!
//! - The scheduler's `maintenance` class slot/byte budget and high/low
//!   backpressure watermarks bound execution; the worker stops admitting when
//!   the class rejects and retries as the class drains (hysteresis is the
//!   scheduler's own).
//! - The inbound queue is bounded (`Config.inbound_capacity`); `submitJob`
//!   rejects with `error.MaintenanceFull` while it is full — the overload
//!   signal that lets an owner (checkpoint, operator request) pause at its
//!   earliest safe boundary instead of growing an unbounded wait queue.
//!
//! ## Cancellation
//!
//! `cancelJob` sets a per-job flag honored at the last safe checkpoints: when
//! the worker admits the job from the inbound queue, and just before it runs a
//! platform-submitted job. A job already running is never revoked — a
//! submitted maintenance op completes, matching the contract ("a submitted op
//! is never cancelled; cancellation after submission is cooperative").
//!
//! ## Teardown
//!
//! `deinit` stops the worker, joins it, releases every job still queued in the
//! scheduler with the cancelled outcome (`Scheduler.cancelAllQueued`), and
//! drains the completion queue so every run job's callback fires exactly once.
//! After `deinit` returns, no callback is pending and no owned job leaks.
//!
//! ## Module boundary
//!
//! This module owns no storage semantics: a job is an opaque `run` function
//! pointer plus context. The engine's LSM store, a future checkpoint path, or
//! any background cleanup wires real work by submitting jobs that call the
//! storage boundary under the engine's writer lock (see
//! `src/storage/engine.zig` `compactionCandidates` and the scheduler-fed load
//! regression in `src/net/runtime_test.zig`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const scheduler_mod = @import("scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;
const Op = scheduler_mod.Op;
const Class = scheduler_mod.Class;

/// Terminal outcome of a maintenance job. `completed`, `failed`, and
/// `cancelled` are mutually exclusive; every submitted job reaches exactly one
/// of them.
pub const JobResult = union(enum) {
    not_run,
    completed,
    failed: anyerror,
    cancelled,
};

/// One maintenance job. Owned by the submitter until a terminal outcome; the
/// worker borrows it while it is queued or running and `on_done` (on the
/// worker thread, or the deinit thread for teardown-cancelled jobs) hands it
/// back. When `owned_gpa` is set, the module destroys the job with that
/// allocator after `on_done`, so a heap-allocated job never leaks.
pub const Job = struct {
    /// Scheduler op; `submitJob` wires `class`, `cancellable`, and `callback`.
    /// A job not admitted to the scheduler never transitions this op.
    op: Op = .{},
    /// Owner identifier (Connection id, commit-batch id, background task).
    /// Must be below the scheduler's `max_owners`.
    owner: u32 = 0,
    /// Reserved byte weight for this job; part of the class byte budget.
    bytes: u64 = 0,
    /// Runs on the maintenance worker thread. Must be safe to run with no
    /// scheduler or engine locks held beyond what it takes itself (compaction
    /// takes the engine writer lock inside `Engine.compact`).
    run_fn: *const fn (ctx: ?*anyopaque) anyerror!void,
    /// Opaque context passed to `run_fn` and `on_done`.
    ctx: ?*anyopaque = null,
    /// Invoked exactly once per job, with the terminal outcome, on the worker
    /// thread (or the deinit thread for jobs released during teardown). May
    /// free `ctx`; must not touch the scheduler.
    on_done: ?*const fn (job: *Job, result: JobResult) void = null,
    /// When set, the module destroys `job` with this allocator after `on_done`.
    owned_gpa: ?Allocator = null,
    /// Set by `cancelJob`; honored at admission and just before the job runs.
    cancel_requested: std.atomic.Value(bool) = .init(false),
    /// Opaque trace tag; never interpreted by the module.
    tag: u64 = 0,
    /// Terminal outcome, set before `on_done` fires.
    result: JobResult = .not_run,
    /// Back-reference for the completion callback; initialized by `submitJob`.
    maint: *Maintenance = undefined,
};

pub const Config = struct {
    /// Scheduler configuration. The `maintenance` class slot/byte budget and
    /// backpressure watermarks are what bound execution; the worker feeds the
    /// class at most what it admits.
    scheduler: scheduler_mod.Config = .{},
    /// Bounded inbound admission queue: jobs waiting to be admitted to the
    /// scheduler's maintenance class. `submitJob` rejects once full. Must be
    /// >= 1.
    inbound_capacity: usize = 8,
    /// Worker idle wait; also the recovery bound for a lost wakeup.
    idle_wait_ns: u64 = 20 * std.time.ns_per_ms,
};

pub const Metrics = struct {
    jobs_submitted: std.atomic.Value(u64) = .init(0),
    jobs_completed: std.atomic.Value(u64) = .init(0),
    jobs_failed: std.atomic.Value(u64) = .init(0),
    jobs_cancelled: std.atomic.Value(u64) = .init(0),
    /// `submitJob` rejections while the inbound queue was full (maintenance
    /// saturation; the retryable overload signal to the owner).
    admission_rejections: std.atomic.Value(u64) = .init(0),
    peak_inbound_depth: std.atomic.Value(usize) = .init(0),
};

pub const InitError = error{
    InvalidCapacity,
    OutOfMemory,
    SystemResources,
    ThreadQuotaExceeded,
    LockedMemoryLimitExceeded,
    Unexpected,
};
pub const SubmitError = error{ MaintenanceFull, InvalidOwner } || Allocator.Error;

/// Bounded maintenance worker. `init` initializes the caller-owned struct in
/// place and spawns the worker thread, which runs until `deinit` stops it and
/// releases every queued job with the cancelled outcome. The struct must
/// outlive the worker (it is referenced by the thread), so callers should
/// declare it at the scope that also tears it down.
pub const Maintenance = struct {
    gpa: Allocator,
    io: Io,
    cfg: Config,
    scheduler: Scheduler,
    inbound: InboundQueue,
    /// Ops submitted to the platform by the last tick, awaiting their job run.
    /// Worker-local ring, bounded by the maintenance class slot budget.
    run_vec: []?*Op,
    run_head: usize = 0,
    run_len: usize = 0,
    /// Run jobs awaiting scheduler extraction. Worker-local ring, bounded by
    /// the maintenance class slot budget.
    completion_vec: []?*Op,
    completion_head: usize = 0,
    completion_len: usize = 0,
    /// Set by `submitJob`/`cancelJob`/`deinit` to wake the worker.
    wake: Io.Event = .unset,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    metrics: Metrics = .{},
    /// Maintenance class slot budget; bounds both worker-local rings.
    max_slots: usize = 1,

    /// Initialize `self` in place and start the worker thread. The struct must
    /// stay alive (and in place) until `deinit`. After a successful `init`,
    /// `deinit` must be called; after a failed `init`, nothing is owned.
    pub fn init(self: *Maintenance, gpa: Allocator, io: Io, cfg: Config) InitError!void {
        if (cfg.inbound_capacity < 1) return error.InvalidCapacity;
        const max_slots = cfg.scheduler.class_capacity[@intFromEnum(Class.maintenance)].max_slots;
        var sched = try Scheduler.init(gpa, io, cfg.scheduler);
        var transferred = false;
        errdefer if (!transferred) sched.deinit();
        const run_vec = try gpa.alloc(?*Op, max_slots);
        errdefer if (!transferred) gpa.free(run_vec);
        const completion_vec = try gpa.alloc(?*Op, max_slots);
        errdefer if (!transferred) gpa.free(completion_vec);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .scheduler = sched,
            .inbound = .{ .capacity = cfg.inbound_capacity },
            .run_vec = run_vec,
            .completion_vec = completion_vec,
            .max_slots = max_slots,
        };
        transferred = true;
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.inbound.deinit(gpa, io);
            self.scheduler.deinit();
            gpa.free(self.run_vec);
            gpa.free(self.completion_vec);
            self.* = undefined;
            return err;
        };
    }

    /// Stop the worker, join it, and release every job still queued with the
    /// cancelled outcome. After this returns, no callback is pending and no
    /// owned job leaks.
    pub fn deinit(self: *Maintenance) void {
        self.stop.store(true, .release);
        self.wake.set(self.io);
        if (self.thread) |t| t.join();
        // The worker drained the inbound queue on exit; release ops it had
        // admitted to the scheduler but never submitted, then drain the
        // completion queue so every run job's callback fires exactly once.
        _ = self.scheduler.cancelAllQueued(Class.maintenance);
        var platform = self.platformBackend();
        var guard: usize = 0;
        while (!self.scheduler.isIdle()) : (guard += 1) {
            std.debug.assert(guard < 10_000);
            self.scheduler.tick(&platform);
        }
        self.gpa.free(self.run_vec);
        self.gpa.free(self.completion_vec);
        self.inbound.deinit(self.gpa, self.io);
        self.scheduler.deinit();
        // Keep `metrics` readable for post-mortem accounting; the struct is
        // otherwise unusable after deinit (thread stopped, queues freed).
        self.thread = null;
    }

    /// Admit one job. Rejects with `error.MaintenanceFull` while the inbound
    /// queue is full (the maintenance saturation signal). On success the
    /// worker owns the job until `on_done` fires; on error the caller keeps
    /// ownership and may free or re-submit it.
    pub fn submitJob(self: *Maintenance, job: *Job, owner: u32, bytes: u64) SubmitError!void {
        if (owner >= self.cfg.scheduler.max_owners) return error.InvalidOwner;
        job.maint = self;
        job.owner = owner;
        job.bytes = bytes;
        job.op.class = .maintenance;
        job.op.cancellable = true;
        job.op.callback = opCompletion;
        const pushed = try self.inbound.push(self.gpa, self.io, job);
        if (!pushed) {
            _ = self.metrics.admission_rejections.fetchAdd(1, .release);
            return error.MaintenanceFull;
        }
        _ = self.metrics.jobs_submitted.fetchAdd(1, .release);
        const depth = self.inbound.len(self.io);
        _ = self.metrics.peak_inbound_depth.fetchMax(depth, .monotonic);
        self.wake.set(self.io);
    }

    /// Best-effort cancellation of a submitted job: honored when the worker
    /// admits the job from the inbound queue and just before it runs. A job
    /// already running completes; the contract does not revoke submitted work.
    pub fn cancelJob(self: *Maintenance, job: *Job) void {
        job.cancel_requested.store(true, .release);
        self.wake.set(self.io);
    }

    /// Scheduler metrics for the maintenance class (queue depth, in-flight,
    /// backpressure transitions, cancellations).
    pub fn maintenanceClassMetrics(self: *const Maintenance) scheduler_mod.ClassMetrics {
        return self.scheduler.classMetrics(Class.maintenance);
    }

    pub fn metricsSnapshot(self: *const Maintenance) Metrics {
        return self.metrics;
    }

    /// Number of jobs waiting in the inbound admission queue.
    pub fn inboundCount(self: *const Maintenance, io: Io) usize {
        return self.inbound.len(io);
    }

    // ── Worker loop (worker thread only) ──

    fn workerMain(self: *Maintenance) void {
        while (!self.stop.load(.acquire)) {
            self.workerIteration();
        }
        // Teardown drain: release every job still waiting in the inbound queue
        // with the cancelled outcome so owners' callbacks fire.
        while (self.inbound.pop(self.io)) |job| self.completeJob(job, .cancelled);
    }

    fn workerIteration(self: *Maintenance) void {
        self.admitInbound();
        var platform = self.platformBackend();
        self.scheduler.tick(&platform);
        self.runPlatformJobs();
        if (self.scheduler.isIdle() and self.run_len == 0 and self.completion_len == 0 and
            self.inbound.len(self.io) == 0)
        {
            self.wake.waitTimeout(self.io, .{ .duration = .{ .raw = Io.Duration.fromNanoseconds(@intCast(self.cfg.idle_wait_ns)), .clock = .awake } }) catch {};
            self.wake.reset();
        }
    }

    /// Admit inbound jobs into the scheduler's maintenance class up to the
    /// class's admission capacity. On the first rejection (backpressure or a
    /// full class) the job stays at the head of the inbound queue and admission
    /// pauses until the class drains — the scheduler's high/low watermarks
    /// provide the hysteresis.
    fn admitInbound(self: *Maintenance) void {
        while (true) {
            const job = self.inbound.peek(self.io) orelse return;
            if (job.cancel_requested.load(.acquire)) {
                _ = self.inbound.pop(self.io);
                self.completeJob(job, .cancelled);
                continue;
            }
            self.scheduler.enqueue(&job.op, .maintenance, job.owner, job.bytes) catch |err| switch (err) {
                error.Backpressure, error.QueueFull => return,
                error.CriticalCapacityExhausted, error.InvalidOwner => unreachable,
            };
            _ = self.inbound.pop(self.io);
        }
    }

    /// Run every platform-submitted job (bounded by the maintenance class slot
    /// budget), then hand the op back to the scheduler's completion path. A
    /// job whose cancel flag was set before it ran is reported cancelled
    /// without invoking `run_fn`.
    fn runPlatformJobs(self: *Maintenance) void {
        while (self.runPop()) |op| {
            const job: *Job = @fieldParentPtr("op", op);
            if (job.cancel_requested.load(.acquire)) {
                job.result = .cancelled;
            } else {
                job.run_fn(job.ctx) catch |err| {
                    job.result = .{ .failed = err };
                    self.completionPush(op);
                    continue;
                };
                job.result = .completed;
            }
            self.completionPush(op);
        }
    }

    /// Terminal bookkeeping: record the outcome, fire `on_done` exactly once,
    /// and destroy the job when the submitter delegated ownership.
    fn completeJob(self: *Maintenance, job: *Job, result: JobResult) void {
        _ = switch (result) {
            .not_run => {},
            .completed => self.metrics.jobs_completed.fetchAdd(1, .release),
            .failed => self.metrics.jobs_failed.fetchAdd(1, .release),
            .cancelled => self.metrics.jobs_cancelled.fetchAdd(1, .release),
        };
        job.result = result;
        if (job.on_done) |cb| cb(job, result);
        if (job.owned_gpa) |gpa| gpa.destroy(job);
    }

    // ── Platform backend (worker thread only) ──

    fn platformBackend(self: *Maintenance) scheduler_mod.Platform {
        return .{ .ctx = self, .submit = platformSubmit, .extract = platformExtract };
    }

    fn platformSubmit(ctx: ?*anyopaque, op: *Op) void {
        const self: *Maintenance = @ptrCast(@alignCast(ctx.?));
        // The scheduler submits at most the maintenance slot budget, and the
        // run ring is drained after every tick, so this cannot overflow.
        self.runPush(op);
    }

    fn platformExtract(ctx: ?*anyopaque, out: []*Op) usize {
        const self: *Maintenance = @ptrCast(@alignCast(ctx.?));
        var n: usize = 0;
        while (n < out.len) : (n += 1) {
            const op = self.completionPop() orelse break;
            out[n] = op;
        }
        return n;
    }

    fn opCompletion(op: *Op) void {
        const job: *Job = @fieldParentPtr("op", op);
        // A teardown cancellation marks the op `.cancelled`; a normal
        // completion arrives with the outcome the worker recorded in `result`.
        const result: JobResult = if (op.state == .cancelled) .cancelled else job.result;
        job.maint.completeJob(job, result);
    }

    // Worker-local rings. Both are bounded by `max_slots`: the scheduler never
    // has more maintenance ops in flight, so push cannot overflow.

    fn runPush(self: *Maintenance, op: *Op) void {
        std.debug.assert(self.run_len < self.run_vec.len);
        self.run_vec[(self.run_head + self.run_len) % self.run_vec.len] = op;
        self.run_len += 1;
    }

    fn runPop(self: *Maintenance) ?*Op {
        if (self.run_len == 0) return null;
        const op = self.run_vec[self.run_head];
        self.run_head = (self.run_head + 1) % self.run_vec.len;
        self.run_len -= 1;
        return op;
    }

    fn completionPush(self: *Maintenance, op: *Op) void {
        std.debug.assert(self.completion_len < self.completion_vec.len);
        self.completion_vec[(self.completion_head + self.completion_len) % self.completion_vec.len] = op;
        self.completion_len += 1;
    }

    fn completionPop(self: *Maintenance) ?*Op {
        if (self.completion_len == 0) return null;
        const op = self.completion_vec[self.completion_head];
        self.completion_head = (self.completion_head + 1) % self.completion_vec.len;
        self.completion_len -= 1;
        return op;
    }
};

/// Cross-thread bounded FIFO of admitted-but-not-yet-scheduled jobs. `push`
/// and `pop` are mutex-guarded; the worker is the only popper, owners push.
const InboundQueue = struct {
    mutex: Io.Mutex = .init,
    items: std.ArrayListUnmanaged(*Job) = .empty,
    head: usize = 0,
    capacity: usize = 0,

    fn push(self: *InboundQueue, gpa: Allocator, io: Io, job: *Job) Allocator.Error!bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.items.items.len - self.head >= self.capacity) return false;
        try self.items.append(gpa, job);
        return true;
    }

    fn peek(self: *InboundQueue, io: Io) ?*Job {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.head >= self.items.items.len) return null;
        return self.items.items[self.head];
    }

    fn pop(self: *InboundQueue, io: Io) ?*Job {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.head >= self.items.items.len) return null;
        const job = self.items.items[self.head];
        self.head += 1;
        if (self.head == self.items.items.len) {
            self.items.items.len = 0;
            self.head = 0;
        }
        return job;
    }

    fn len(self: *InboundQueue, io: Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.items.items.len - self.head;
    }

    fn deinit(self: *InboundQueue, gpa: Allocator, io: Io) void {
        self.mutex.lockUncancelable(io);
        self.items.deinit(gpa);
        self.mutex.unlock(io);
        self.* = undefined;
    }
};

// ── Tests ──

const TestJobCtx = struct {
    io: Io,
    ran: std.atomic.Value(usize) = .init(0),
};

fn runIncrement(ctx: ?*anyopaque) anyerror!void {
    const c: *TestJobCtx = @ptrCast(@alignCast(ctx.?));
    _ = c.ran.fetchAdd(1, .monotonic);
}

fn runSlow(ctx: ?*anyopaque) anyerror!void {
    const c: *TestJobCtx = @ptrCast(@alignCast(ctx.?));
    Io.sleep(c.io, .fromMilliseconds(300), .awake) catch {};
    _ = c.ran.fetchAdd(1, .monotonic);
}

fn runFail(ctx: ?*anyopaque) anyerror!void {
    _ = ctx;
    return error.MaintenanceJobFailed;
}

/// One-slot maintenance config for deterministic saturation/cancellation
/// tests: a single in-flight job serializes everything behind it.
fn testConfig() Config {
    var cfg = Config{ .inbound_capacity = 2 };
    cfg.scheduler.class_capacity[@intFromEnum(Class.maintenance)] = .{ .max_slots = 1, .max_bytes = 0 };
    cfg.scheduler.backpressure_high[@intFromEnum(Class.maintenance)] = 1;
    cfg.scheduler.backpressure_low[@intFromEnum(Class.maintenance)] = 1;
    cfg.scheduler.tick_submit_budget_slots = 8;
    return cfg;
}

/// Poll the maintenance metrics until the terminal-outcome counts reach the
/// expected values. Metrics are atomic, so this is safe against the worker.
fn pollMetrics(m: *Maintenance, want_completed: u64, want_failed: u64, want_cancelled: u64) void {
    var guard: usize = 0;
    while (true) : (guard += 1) {
        std.debug.assert(guard < 60_000);
        if (m.metrics.jobs_completed.load(.acquire) == want_completed and
            m.metrics.jobs_failed.load(.acquire) == want_failed and
            m.metrics.jobs_cancelled.load(.acquire) == want_cancelled)
        {
            return;
        }
        Io.sleep(m.io, .fromMilliseconds(1), .awake) catch {};
    }
}

test "jobs run on the worker and complete exactly once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var m: Maintenance = undefined;
    try m.init(gpa, io, .{});
    defer m.deinit();

    var ctx = TestJobCtx{ .io = io };
    var jobs: [3]Job = undefined;
    for (&jobs, 0..) |*job, i| {
        job.* = .{ .run_fn = runIncrement, .ctx = &ctx, .tag = @intCast(i) };
        try m.submitJob(job, 0, 1);
    }
    pollMetrics(&m, 3, 0, 0);
    try std.testing.expectEqual(@as(usize, 3), ctx.ran.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), m.metrics.jobs_submitted.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), m.metrics.jobs_completed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), m.metrics.jobs_failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), m.metrics.jobs_cancelled.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), m.metrics.admission_rejections.load(.acquire));
}

test "a failing job is isolated and the worker keeps serving" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var m: Maintenance = undefined;
    try m.init(gpa, io, testConfig());
    defer m.deinit();

    var ctx = TestJobCtx{ .io = io };
    var fail_job = Job{ .run_fn = runFail, .ctx = &ctx };
    var ok_job = Job{ .run_fn = runIncrement, .ctx = &ctx };
    try m.submitJob(&fail_job, 0, 1);
    try m.submitJob(&ok_job, 0, 1);
    pollMetrics(&m, 1, 1, 0);
    try std.testing.expectEqual(@as(usize, 1), ctx.ran.load(.acquire));
    try std.testing.expect(std.meta.activeTag(fail_job.result) == .failed);
    try std.testing.expect(std.meta.activeTag(ok_job.result) == .completed);

    // The worker survived the failure: a follow-up job completes.
    var third = Job{ .run_fn = runIncrement, .ctx = &ctx };
    try m.submitJob(&third, 0, 1);
    pollMetrics(&m, 2, 1, 0);
    try std.testing.expectEqual(@as(usize, 2), ctx.ran.load(.acquire));
}

test "maintenance admission is bounded and rejects at saturation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var m: Maintenance = undefined;
    try m.init(gpa, io, testConfig());
    defer m.deinit();

    var ctx = TestJobCtx{ .io = io };
    // The first job occupies the single maintenance slot for 300ms. Wait until
    // the worker has admitted it (in flight), then fill the inbound queue:
    // within the slow job's window the scheduler cannot admit another op, so
    // the fourth admission must reject deterministically.
    var jobs: [4]Job = undefined;
    for (&jobs, 0..) |*job, i| job.* = .{ .run_fn = runSlow, .ctx = &ctx, .tag = @intCast(i) };
    try m.submitJob(&jobs[0], 0, 1);
    for (0..1000) |_| {
        if (m.maintenanceClassMetrics().submitted >= 1) break;
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(u64, 1), m.maintenanceClassMetrics().submitted);
    try m.submitJob(&jobs[1], 0, 1);
    try m.submitJob(&jobs[2], 0, 1);
    try std.testing.expectError(error.MaintenanceFull, m.submitJob(&jobs[3], 0, 1));
    try std.testing.expectEqual(@as(u64, 1), m.metrics.admission_rejections.load(.acquire));
    // The peak inbound depth never exceeded the configured bound.
    try std.testing.expect(m.metrics.peak_inbound_depth.load(.acquire) <= testConfig().inbound_capacity);

    // Every accepted job still reaches a terminal outcome; the rejected one
    // was never submitted.
    pollMetrics(&m, 3, 0, 0);
    try std.testing.expectEqual(@as(usize, 3), ctx.ran.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), m.metrics.jobs_completed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), m.metrics.jobs_submitted.load(.acquire));
    // The slow jobs are serialized through the single maintenance slot, so the
    // scheduler maintenance class never exceeded its configured bound.
    try std.testing.expectEqual(@as(u64, 3), m.maintenanceClassMetrics().submitted);
}

test "a queued job can be cancelled at the admission boundary" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var m: Maintenance = undefined;
    try m.init(gpa, io, testConfig());
    defer m.deinit();

    var ctx = TestJobCtx{ .io = io };
    var slow_job = Job{ .run_fn = runSlow, .ctx = &ctx };
    var queued_job = Job{ .run_fn = runIncrement, .ctx = &ctx };
    try m.submitJob(&slow_job, 0, 1);
    // Let the worker admit the slow job into its single slot.
    for (0..1000) |_| {
        if (m.maintenanceClassMetrics().submitted >= 1) break;
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    // The queued job waits behind it; cancelling it must fire on_done with the
    // cancelled outcome and never run it.
    try m.submitJob(&queued_job, 0, 1);
    m.cancelJob(&queued_job);
    pollMetrics(&m, 1, 0, 1);
    try std.testing.expect(std.meta.activeTag(queued_job.result) == .cancelled);
    try std.testing.expectEqual(@as(usize, 1), ctx.ran.load(.acquire)); // only the slow job ran
    try std.testing.expectEqual(@as(u64, 1), m.metrics.jobs_cancelled.load(.acquire));
}

test "teardown releases queued jobs with the cancelled outcome and reclaims owned jobs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cfg = testConfig();
    cfg.inbound_capacity = 8; // every submitted job must be admitted to the queue
    var m: Maintenance = undefined;
    try m.init(gpa, io, cfg);

    // Owned, heap-allocated jobs: the module must destroy them even when
    // teardown interrupts them mid-queue.
    var ctx = TestJobCtx{ .io = io };
    var jobs: [6]*Job = undefined;
    for (&jobs) |*jobp| {
        const job = try gpa.create(Job);
        job.* = .{ .run_fn = runSlow, .ctx = &ctx, .owned_gpa = gpa };
        try m.submitJob(job, 0, 1);
        jobp.* = job;
    }
    // Tear down without waiting: the in-flight job completes, the rest are
    // cancelled. Every submitted job reaches exactly one terminal outcome.
    m.deinit();
    const submitted = m.metrics.jobs_submitted.load(.acquire);
    const terminal = m.metrics.jobs_completed.load(.acquire) +
        m.metrics.jobs_failed.load(.acquire) +
        m.metrics.jobs_cancelled.load(.acquire);
    try std.testing.expectEqual(submitted, terminal);
    try std.testing.expect(submitted == 6);
}

test "invalid owner ids are rejected at admission" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var m: Maintenance = undefined;
    try m.init(gpa, io, .{});
    defer m.deinit();
    var job = Job{ .run_fn = runIncrement, .ctx = null };
    const max_owners: u32 = @intCast(m.cfg.scheduler.max_owners);
    try std.testing.expectError(error.InvalidOwner, m.submitJob(&job, max_owners, 1));
    try std.testing.expectEqual(@as(u64, 0), m.metrics.jobs_submitted.load(.acquire));
}
