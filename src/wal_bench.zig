const std = @import("std");
const Io = std.Io;
const pico = @import("pico");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const n: usize = 3000;

    try runEngine(gpa, io, n);
    try runWal(gpa, io, n, true, "wal.appendInsert sync");
    try runWal(gpa, io, n, false, "wal.appendInsert nosync");
    try runGroup(gpa, io, n);
}

fn elapsed(start: Io.Clock.Timestamp, io: Io) u64 {
    return @intCast(@max(@as(i96, 1), start.untilNow(io).raw.nanoseconds));
}

fn runEngine(gpa: std.mem.Allocator, io: Io, n: usize) !void {
    const dir = "zig-cache/pico-wal-micro-eng";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try pico.engine.Engine.open(gpa, io, dir, true);
    defer eng.deinit();
    const id_name = try gpa.dupe(u8, "id");
    defer gpa.free(id_name);
    try eng.createTable("t", &.{
        .{ .name = id_name, .type_tag = .int, .primary_key = true },
    });
    const t0 = Io.Clock.Timestamp.now(io, .awake);
    for (0..n) |i| {
        try eng.insert("t", &.{.{ .int = @intCast(i) }});
    }
    const ns = elapsed(t0, io);
    std.debug.print("engine.insert sync: {d:.0} ops/s ({d} ns/op)\n", .{
        @as(f64, @floatFromInt(n)) * 1e9 / @as(f64, @floatFromInt(ns)),
        ns / n,
    });
}

fn runWal(gpa: std.mem.Allocator, io: Io, n: usize, sync: bool, label: []const u8) !void {
    const dir = if (sync) "zig-cache/pico-wal-micro-s" else "zig-cache/pico-wal-micro-ns";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var wal = try pico.wal.Wal.open(gpa, io, dir, sync);
    defer wal.deinit();
    const t0 = Io.Clock.Timestamp.now(io, .awake);
    for (0..n) |i| {
        try wal.appendInsert(.{ .table = "t", .values = &.{.{ .int = @intCast(i) }} });
    }
    const ns = elapsed(t0, io);
    std.debug.print("{s}: {d:.0} ops/s ({d} ns/op)\n", .{
        label,
        @as(f64, @floatFromInt(n)) * 1e9 / @as(f64, @floatFromInt(ns)),
        ns / n,
    });
}

fn runGroup(gpa: std.mem.Allocator, io: Io, n: usize) !void {
    const dir = "zig-cache/pico-wal-micro-gc";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var wal = try pico.wal.Wal.open(gpa, io, dir, true);
    defer wal.deinit();
    const workers = 8;
    const per = n / workers;
    var start = std.atomic.Value(bool).init(false);
    const Ctx = struct {
        wal: *pico.wal.Wal,
        start: *std.atomic.Value(bool),
        first: u32,
        count: u32,
        fn run(self: @This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            var i: u32 = 0;
            while (i < self.count) : (i += 1) {
                self.wal.appendInsert(.{
                    .table = "t",
                    .values = &.{.{ .int = @intCast(self.first + i) }},
                }) catch unreachable;
            }
        }
    };
    var threads: [workers]std.Thread = undefined;
    const t0 = Io.Clock.Timestamp.now(io, .awake);
    for (&threads, 0..) |*th, w| {
        th.* = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .wal = &wal,
            .start = &start,
            .first = @intCast(w * per),
            .count = @intCast(per),
        }});
    }
    start.store(true, .release);
    for (&threads) |th| th.join();
    const ns = elapsed(t0, io);
    std.debug.print("wal concurrent group-commit 8t: {d:.0} ops/s ({d} ns/op)\n", .{
        @as(f64, @floatFromInt(n)) * 1e9 / @as(f64, @floatFromInt(ns)),
        ns / n,
    });
}
