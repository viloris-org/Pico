//! RunaDB connection — manages a TCP connection to a RunaDB Server.
//! Handles handshake, message framing, and lifecycle.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proto = @import("clint_proto");
const codec = @import("codec.zig");

pub const Connection = struct {
    allocator: Allocator,
    stream: Io.net.Stream,
    read_buf: [16 * 1024]u8,
    write_buf: [4 * 1024]u8,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    server_version: []const u8,

    pub fn connect(allocator: Allocator, io: Io, host: []const u8, port: u16) !Connection {
        const addr = try Io.net.IpAddress.parse(host, port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);

        var self = Connection{
            .allocator = allocator,
            .stream = stream,
            .read_buf = undefined,
            .write_buf = undefined,
            .reader = undefined,
            .writer = undefined,
            .server_version = "",
        };

        self.reader = stream.reader(io, &self.read_buf);
        self.writer = stream.writer(io, &self.write_buf);

        // Send HELLO
        {
            var payload_buf: [4]u8 = undefined;
            std.mem.writeInt(u16, payload_buf[0..2], proto.PROTOCOL_VERSION_MAJOR, .big);
            std.mem.writeInt(u16, payload_buf[2..4], proto.PROTOCOL_VERSION_MINOR, .big);
            try codec.writeMessage(&self.writer.interface, .hello, &payload_buf);
            try self.writer.interface.flush();
        }

        // Read response — use arena for temporary allocations
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const msg = try codec.readMessage(arena_alloc, &self.reader.interface);
        switch (msg) {
            .hello_ok => |ok| {
                self.server_version = try allocator.dupe(u8, ok.server_version);
                return self;
            },
            .hello_error => {
                stream.close(io);
                return error.ServerRejected;
            },
            else => {
                stream.close(io);
                return error.Protocol;
            },
        }
    }

    /// Execute a SQL statement. Returns a result iterator.
    /// The caller must consume or drain the result before issuing another statement.
    pub fn execute(self: *Connection, arena: Allocator, sql: []const u8) !QueryResult {
        _ = arena;
        // Write the query message
        {
            const sl: u32 = @intCast(sql.len);
            var payload_buf: [4 + 64 * 1024]u8 = undefined;
            if (sl > 64 * 1024) return error.MessageTooLarge;
            std.mem.writeInt(u32, payload_buf[0..4], sl, .big);
            @memcpy(payload_buf[4..][0..sl], sql);
            try codec.writeMessage(&self.writer.interface, .query, payload_buf[0 .. 4 + sl]);
            try self.writer.interface.flush();
        }

        return QueryResult{
            .allocator = self.allocator,
            .reader = &self.reader.interface,
            .done = false,
        };
    }

    /// Close the connection gracefully.
    pub fn close(self: *Connection, io: Io) void {
        codec.writeMessage(&self.writer.interface, .goodbye, "") catch {};
        self.writer.interface.flush() catch {};
        self.stream.close(io);
    }

    /// Close the Connection and release all client-owned resources.
    pub fn deinit(self: *Connection, io: Io) void {
        self.close(io);
        self.allocator.free(self.server_version);
        self.server_version = "";
    }
};

/// Iterator over query result messages.
pub const QueryResult = struct {
    allocator: Allocator,
    reader: *Io.Reader,
    done: bool,
    state: State = .initial,
    column_count: ?u16 = null,

    const State = enum {
        initial,
        rows,
    };

    /// Read the next message from the query response stream.
    /// Returns null when COMMAND_COMPLETE or GOODBYE is received.
    pub fn next(self: *QueryResult, arena: Allocator) !?codec.Message {
        if (self.done) return null;

        const msg = try codec.readMessage(arena, self.reader);
        switch (self.state) {
            .initial => switch (msg) {
                .row_description => {
                    self.state = .rows;
                    self.column_count = msg.row_description.column_count;
                    return msg;
                },
                .command_complete, .server_error, .goodbye => {
                    self.done = true;
                    return msg;
                },
                else => {
                    self.done = true;
                    return error.Protocol;
                },
            },
            .rows => switch (msg) {
                .row_data => {
                    if (msg.row_data.values.len != @as(usize, self.column_count.?)) {
                        self.done = true;
                        return error.Protocol;
                    }
                    return msg;
                },
                .command_complete, .goodbye => {
                    self.done = true;
                    return msg;
                },
                else => {
                    self.done = true;
                    return error.Protocol;
                },
            },
        }
    }

    /// Consume all remaining messages (drain).
    pub fn drain(self: *QueryResult, arena: Allocator) !void {
        while (try self.next(arena)) |_| {}
    }
};

test "query result rejects a response before its row description" {
    const bytes = [_]u8{
        0, 0, 0, 3, @intFromEnum(proto.Type.row_data), 0, 0,
    };
    var reader: Io.Reader = .fixed(&bytes);
    var result = QueryResult{
        .allocator = std.testing.allocator,
        .reader = &reader,
        .done = false,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Protocol, result.next(arena.allocator()));
    try std.testing.expect((try result.next(arena.allocator())) == null);
}

test "query result rejects a handshake response after a query" {
    const bytes = [_]u8{
        0, 0, 0, 5, @intFromEnum(proto.Type.hello_ok), 0, 0, 0, 0,
    };
    var reader: Io.Reader = .fixed(&bytes);
    var result = QueryResult{
        .allocator = std.testing.allocator,
        .reader = &reader,
        .done = false,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Protocol, result.next(arena.allocator()));
    try std.testing.expect((try result.next(arena.allocator())) == null);
}

test "query result accepts rows followed by command completion" {
    const bytes = [_]u8{
        0,                                         0, 0, 7, @intFromEnum(proto.Type.row_description), 0, 1, 0, 0, 0, 1, 'x',
        0,                                         0, 0, 4, @intFromEnum(proto.Type.row_data),        0, 1, 1, 0, 0, 0, 13,
        @intFromEnum(proto.Type.command_complete), 0, 0, 0, 0,                                        0, 0, 0, 1, 0, 0, 0,
        0,
    };
    var reader: Io.Reader = .fixed(&bytes);
    var result = QueryResult{
        .allocator = std.testing.allocator,
        .reader = &reader,
        .done = false,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expect((try result.next(arena.allocator())).? == .row_description);
    try std.testing.expect((try result.next(arena.allocator())).? == .row_data);
    try std.testing.expect((try result.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try result.next(arena.allocator())) == null);
}

test "query result rejects a row with a different column count" {
    const bytes = [_]u8{
        0, 0, 0, 7, @intFromEnum(proto.Type.row_description), 0, 1, 0, 0, 0, 1, 'x',
        0, 0, 0, 3, @intFromEnum(proto.Type.row_data),        0, 0,
    };
    var reader: Io.Reader = .fixed(&bytes);
    var result = QueryResult{
        .allocator = std.testing.allocator,
        .reader = &reader,
        .done = false,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expect((try result.next(arena.allocator())).? == .row_description);
    try std.testing.expectError(error.Protocol, result.next(arena.allocator()));
    try std.testing.expect((try result.next(arena.allocator())) == null);
}
