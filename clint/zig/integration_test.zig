//! RunaDB Client compatibility tests against the independently built server.
//! This module imports only the public client package and communicates over TCP.

const std = @import("std");
const Io = std.Io;
const clint = @import("clint");

const server_port: u16 = 64334;
const data_dir = "zig-cache/runa-client-protocol-integration";

test "RunaDB Client submits Runa Flow and receives binding errors" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server_path = std.mem.span(std.c.getenv("RUNA_TEST_SERVER") orelse return error.ServerPathMissing);

    Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    const port_text = "64334";
    const child_args = [_][]const u8{
        server_path,
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

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var failed = try conn.executeFlow(arena.allocator(), "from customer\n| emit { id }");
    const failure = (try failed.next(arena.allocator())).?;
    switch (failure) {
        .server_error => |server_error| {
            try std.testing.expectEqual(@as(u8, 2), server_error.severity);
            try std.testing.expectEqualStrings("RF1002", server_error.code);
            try std.testing.expectEqualStrings("SemanticNameNotFound", server_error.message);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try failed.next(arena.allocator())) == null);

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
