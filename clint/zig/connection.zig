//! Pico connection — manages a TCP connection to a Pico Server.
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

    /// Read the next message from the query response stream.
    /// Returns null when COMMAND_COMPLETE or GOODBYE is received.
    pub fn next(self: *QueryResult, arena: Allocator) !?codec.Message {
        if (self.done) return null;

        const msg = try codec.readMessage(arena, self.reader);
        switch (msg) {
            .command_complete, .server_error, .goodbye => {
                self.done = true;
                return msg;
            },
            else => return msg,
        }
    }

    /// Consume all remaining messages (drain).
    pub fn drain(self: *QueryResult, arena: Allocator) !void {
        while (try self.next(arena)) |_| {}
    }
};
