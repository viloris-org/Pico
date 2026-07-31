const std = @import("std");
const Io = std.Io;
const runadb = @import("runadb");

const Config = struct {
    rows: usize = 10_000,
    sync_wal: bool = false,
};

const Measurement = struct {
    name: []const u8,
    operations: usize,
    elapsed_ns: u64,
};

pub fn main(init: std.process.Init) !void {
    const cfg = try parseArgs(init);
    const gpa = init.gpa;
    const io = init.io;
    const data_dir = "zig-cache/runa-bench";

    Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    var eng = try runadb.engine.Engine.open(gpa, io, data_dir, cfg.sync_wal);
    defer eng.deinit();
    var connection = runadb.txn.session.Session.init(gpa);
    defer connection.deinit();

    var create = try runadb.sql.exec.execute(
        gpa,
        &eng,
        &connection,
        "CREATE TABLE bench_items (id INT PRIMARY KEY, name TEXT)",
    );
    defer create.deinit();

    std.debug.print(
        "RunaDB SQL-path benchmark: rows={d}, WAL sync={s}\n",
        .{ cfg.rows, if (cfg.sync_wal) "on" else "off" },
    );

    printMeasurement(try benchmarkAutocommitInsert(gpa, io, &eng, &connection, cfg.rows));
    printMeasurement(try benchmarkPrimaryKeySelect(gpa, io, &eng, &connection, cfg.rows));
    printMeasurement(try benchmarkTransactionInsert(gpa, io, &eng, &connection, cfg.rows));
}

fn parseArgs(init: std.process.Init) !Config {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var cfg: Config = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--rows") and i + 1 < args.len) {
            i += 1;
            cfg.rows = try std.fmt.parseInt(usize, args[i], 10);
            if (cfg.rows == 0) return error.InvalidRowCount;
        } else if (std.mem.eql(u8, arg, "--sync-wal")) {
            cfg.sync_wal = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else {
            printUsage();
            return error.InvalidArgument;
        }
    }
    return cfg;
}

fn benchmarkAutocommitInsert(
    gpa: std.mem.Allocator,
    io: Io,
    eng: *runadb.engine.Engine,
    connection: *runadb.txn.session.Session,
    rows: usize,
) !Measurement {
    const start = Io.Clock.Timestamp.now(io, .awake);
    for (0..rows) |index| {
        var query_buf: [128]u8 = undefined;
        const id = index + 1;
        const query = try std.fmt.bufPrint(
            &query_buf,
            "INSERT INTO bench_items VALUES ({d}, 'item-{d}')",
            .{ id, id },
        );
        var result = try runadb.sql.exec.execute(gpa, eng, connection, query);
        result.deinit();
    }
    return .{
        .name = "autocommit INSERT",
        .operations = rows,
        .elapsed_ns = elapsedNanoseconds(start, io),
    };
}

fn benchmarkPrimaryKeySelect(
    gpa: std.mem.Allocator,
    io: Io,
    eng: *runadb.engine.Engine,
    connection: *runadb.txn.session.Session,
    rows: usize,
) !Measurement {
    const start = Io.Clock.Timestamp.now(io, .awake);
    for (0..rows) |index| {
        var query_buf: [96]u8 = undefined;
        const query = try std.fmt.bufPrint(
            &query_buf,
            "SELECT name FROM bench_items WHERE id = {d}",
            .{index + 1},
        );
        var result = try runadb.sql.exec.execute(gpa, eng, connection, query);
        if (result != .rows or result.rows.cells.len != 1) {
            result.deinit();
            return error.BenchmarkDataMissing;
        }
        result.deinit();
    }
    return .{
        .name = "primary-key SELECT",
        .operations = rows,
        .elapsed_ns = elapsedNanoseconds(start, io),
    };
}

fn benchmarkTransactionInsert(
    gpa: std.mem.Allocator,
    io: Io,
    eng: *runadb.engine.Engine,
    connection: *runadb.txn.session.Session,
    rows: usize,
) !Measurement {
    const start = Io.Clock.Timestamp.now(io, .awake);
    var begin = try runadb.sql.exec.execute(gpa, eng, connection, "BEGIN");
    begin.deinit();
    errdefer connection.rollback();

    for (0..rows) |index| {
        var query_buf: [144]u8 = undefined;
        const id = rows + index + 1;
        const query = try std.fmt.bufPrint(
            &query_buf,
            "INSERT INTO bench_items VALUES ({d}, 'batched-{d}')",
            .{ id, id },
        );
        var result = try runadb.sql.exec.execute(gpa, eng, connection, query);
        result.deinit();
    }

    var commit = try runadb.sql.exec.execute(gpa, eng, connection, "COMMIT");
    commit.deinit();
    return .{
        .name = "transactional INSERT + COMMIT",
        .operations = rows,
        .elapsed_ns = elapsedNanoseconds(start, io),
    };
}

fn elapsedNanoseconds(start: Io.Clock.Timestamp, io: Io) u64 {
    return @intCast(@max(@as(i96, 1), start.untilNow(io).raw.nanoseconds));
}

fn printMeasurement(measurement: Measurement) void {
    const elapsed_s = @as(f64, @floatFromInt(measurement.elapsed_ns)) / std.time.ns_per_s;
    const ops_per_second = @as(f64, @floatFromInt(measurement.operations)) / elapsed_s;
    const ns_per_op = @as(f64, @floatFromInt(measurement.elapsed_ns)) /
        @as(f64, @floatFromInt(measurement.operations));
    std.debug.print(
        "{s}: {d} ops in {d:.3} ms | {d:.0} ops/s | {d:.0} ns/op\n",
        .{ measurement.name, measurement.operations, elapsed_s * 1_000.0, ops_per_second, ns_per_op },
    );
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zig build bench [-- --rows <count>] [--sync-wal]
        \\
        \\  --rows <count>  Operations in each benchmark (default 10000)
        \\  --sync-wal      Include WAL synchronization in the measurement
        \\
    , .{});
}
