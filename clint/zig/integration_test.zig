//! RunaDB Client compatibility tests against the independently built server.
//! This module imports only the public client package and communicates over TCP.

const std = @import("std");
const Io = std.Io;
const clint = @import("clint");

const server_port: u16 = 64334;
const pg_port: u16 = 64333;
const data_dir = "zig-cache/runa-client-protocol-integration";

test "RunaDB Client executes a statement and consumes a streamed result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server_path = std.mem.span(std.c.getenv("RUNA_TEST_SERVER") orelse return error.ServerPathMissing);

    Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    const port_text = "64334";
    const pg_port_text = "64333";
    const child_args = [_][]const u8{
        server_path,
        "--port",
        pg_port_text,
        "--runa-port",
        port_text,
        "--data-dir",
        data_dir,
    };
    var child = try std.process.spawn(io, .{
        .argv = &child_args,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var conn = try connectWhenReady(gpa, io);
    defer conn.deinit(io);
    try std.testing.expectEqualStrings("RunaDB 0.0.1", conn.server_version);

    try expectCommandComplete(&conn, gpa, "CREATE TABLE t (id INT PRIMARY KEY, value TEXT)", "CREATE TABLE", 0);

    var value: [5_000]u8 = undefined;
    @memset(&value, 'x');
    const insert_sql = try std.fmt.allocPrint(gpa, "INSERT INTO t VALUES (1, '{s}')", .{value});
    defer gpa.free(insert_sql);
    try expectCommandComplete(&conn, gpa, insert_sql, "INSERT 0 1", 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var failed = try conn.execute(arena.allocator(), "CREATE INDEX idx_t_id ON t(id)");
    const failure = (try failed.next(arena.allocator())).?;
    switch (failure) {
        .server_error => |server_error| {
            try std.testing.expectEqual(@as(u8, 2), server_error.severity);
            try std.testing.expectEqualStrings("P0001", server_error.code);
            try std.testing.expectEqualStrings("UnsupportedSyntax", server_error.message);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try failed.next(arena.allocator())) == null);

    var result = try conn.execute(arena.allocator(), "SELECT value FROM t WHERE id = 1");

    const description = (try result.next(arena.allocator())).?;
    switch (description) {
        .row_description => |columns| {
            try std.testing.expectEqual(@as(u16, 1), columns.column_count);
            try std.testing.expectEqualStrings("value", columns.columns[0]);
        },
        else => return error.TestUnexpectedResult,
    }

    const row = (try result.next(arena.allocator())).?;
    switch (row) {
        .row_data => |data| {
            try std.testing.expect(!data.nulls[0]);
            try std.testing.expectEqualStrings(&value, data.values[0]);
        },
        else => return error.TestUnexpectedResult,
    }

    const complete = (try result.next(arena.allocator())).?;
    switch (complete) {
        .command_complete => |command| {
            try std.testing.expectEqual(@as(u64, 1), command.affected_rows);
            try std.testing.expectEqualStrings("SELECT", command.tag);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try result.next(arena.allocator())) == null);
}

fn connectWhenReady(gpa: std.mem.Allocator, io: Io) !clint.Connection {
    var last_error: ?anyerror = null;
    for (0..100) |_| {
        if (clint.Connection.connect(gpa, io, "127.0.0.1", server_port)) |conn| {
            return conn;
        } else |err| {
            last_error = err;
            try Io.sleep(io, .fromMilliseconds(10), .awake);
        }
    }
    return last_error orelse error.ServerDidNotStart;
}

fn expectCommandComplete(
    conn: *clint.Connection,
    gpa: std.mem.Allocator,
    sql: []const u8,
    expected_tag: []const u8,
    expected_rows: u64,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var result = try conn.execute(arena.allocator(), sql);
    const message = (try result.next(arena.allocator())).?;
    switch (message) {
        .command_complete => |complete| {
            try std.testing.expectEqualStrings(expected_tag, complete.tag);
            try std.testing.expectEqual(expected_rows, complete.affected_rows);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try result.next(arena.allocator())) == null);
}
