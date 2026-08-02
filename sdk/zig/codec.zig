//! RunaDB wire protocol codec — read/write protocol messages over a byte
//! stream. Used by the RunaDB Zig SDK (`sdk/zig/`). The server handler has
//! its own read/write but consumes `clint_proto` type definitions.
//!
//! The codec is transport-agnostic: it operates on a `Stream`, an opaque
//! bidirectional byte stream. TCP provides one stream per Connection; QUIC
//! provides the control stream plus one stream per request (ADR-0023 §2.1).

const std = @import("std");
const proto = @import("clint_proto");
const Allocator = std.mem.Allocator;

pub const ProtocolError = error{
    UnexpectedEof,
    Protocol,
    MessageTooLarge,
    VersionMismatch,
    ServerRejected,
    StringTooLarge,
    EndOfStream,
    ReadFailed,
    Timeout,
    ConnectionClosed,
    ConnectionReset,
    QuicUnavailable,
    QuicRejected,
    HandshakeTimeout,
    CertificateMismatch,
    UnsupportedAddress,
    StatementInProgress,
} || Allocator.Error;

/// An opaque bidirectional byte stream carrying RunaDB Wire Protocol
/// messages. The vtable functions are provided by the transport
/// implementation (TCP or QUIC).
pub const Stream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read exactly `buf.len` bytes. Errors: `EndOfStream` (peer finished
        /// the stream before `buf.len` bytes), `Timeout`, `ConnectionReset`,
        /// `ConnectionClosed`, `ReadFailed`.
        readAll: *const fn (ctx: *anyopaque, buf: []u8) anyerror!void,
        /// Write bytes. May buffer; call `flush` to send.
        writeAll: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
        /// Send any buffered bytes.
        flush: *const fn (ctx: *anyopaque) anyerror!void,
        /// Half-close the send side. No-op on transports without half-close
        /// (TCP: the Connection owns stream lifetime).
        fin: *const fn (ctx: *anyopaque) anyerror!void,
        /// Release the stream (QUIC: free the raw-app slot; TCP: no-op —
        /// closing the Connection closes its single stream).
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn readAll(self: Stream, buf: []u8) anyerror!void {
        return self.vtable.readAll(self.ptr, buf);
    }
    pub fn writeAll(self: Stream, bytes: []const u8) anyerror!void {
        return self.vtable.writeAll(self.ptr, bytes);
    }
    pub fn flush(self: Stream) anyerror!void {
        return self.vtable.flush(self.ptr);
    }
    pub fn fin(self: Stream) anyerror!void {
        return self.vtable.fin(self.ptr);
    }
    pub fn close(self: Stream) void {
        self.vtable.close(self.ptr);
    }
};

pub const Message = union(enum) {
    hello_ok: struct {
        server_version: []const u8,
        /// Unpredictable per-Connection cancellation credential.
        cancel_credential: [proto.CANCEL_CREDENTIAL_LENGTH]u8,
    },
    hello_error: struct { reason: []const u8 },
    row_description: struct {
        column_count: u16,
        columns: []const []const u8,
    },
    row_data: struct {
        values: []const []const u8, // empty strings for nulls; check nulls[]
        nulls: []const bool,
    },
    command_complete: struct {
        tag: []const u8,
        affected_rows: u64,
    },
    server_error: struct {
        severity: u8,
        code: []const u8,
        message: []const u8,
    },
    payload_begin: struct {
        evidence_id: u64,
        payload_length: u64,
        payload_digest: []const u8,
    },
    payload_chunk: struct {
        evidence_id: u64,
        bytes: []const u8,
    },
    payload_finish: struct { evidence_id: u64 },
    goodbye: struct { reason: []const u8 },
};

/// Read one protocol message from a stream.
/// Caller owns allocated memory (strings are arena-allocated from arena).
pub fn readMessage(arena: Allocator, stream: Stream) ProtocolError!Message {
    // Read header: 4-byte length + 1-byte type
    var header: [proto.HEADER_SIZE]u8 = undefined;
    stream.readAll(&header) catch |err| return mapReadError(err);
    const body_len = std.mem.readInt(u32, header[0..4], .big);
    if (body_len < 1) return error.Protocol;
    if (body_len > proto.MAX_BODY_LENGTH) return error.MessageTooLarge;
    const msg_type_int = header[4];
    const msg_type: proto.Type = @enumFromInt(msg_type_int);
    const payload_len: usize = @intCast(body_len - 1);
    const payload = try arena.alloc(u8, payload_len);
    if (payload_len > 0) {
        stream.readAll(payload) catch |err| return mapReadError(err);
    }
    var pos: usize = 0;

    const message = switch (msg_type) {
        .hello_ok => blk: {
            const sv = try readString(arena, payload, &pos);
            if (payload.len - pos != proto.CANCEL_CREDENTIAL_LENGTH) return error.Protocol;
            var credential: [proto.CANCEL_CREDENTIAL_LENGTH]u8 = undefined;
            @memcpy(&credential, payload[pos..]);
            pos = payload.len;
            break :blk Message{ .hello_ok = .{ .server_version = sv, .cancel_credential = credential } };
        },
        .hello_error => blk: {
            const reason = try readString(arena, payload, &pos);
            break :blk Message{ .hello_error = .{ .reason = reason } };
        },
        .row_description => blk: {
            if (payload.len < 2) return error.UnexpectedEof;
            const col_count = std.mem.readInt(u16, payload[pos..][0..2], .big);
            pos += 2;
            var columns = try arena.alloc([]const u8, col_count);
            for (0..col_count) |i| {
                columns[i] = try readString(arena, payload, &pos);
            }
            break :blk Message{ .row_description = .{
                .column_count = col_count,
                .columns = columns,
            } };
        },
        .row_data => blk: {
            if (payload.len < 2) return error.UnexpectedEof;
            const col_count = std.mem.readInt(u16, payload[pos..][0..2], .big);
            pos += 2;
            var values = try arena.alloc([]const u8, col_count);
            var nulls = try arena.alloc(bool, col_count);
            for (0..col_count) |i| {
                if (pos >= payload.len) return error.UnexpectedEof;
                const null_flag = payload[pos];
                if (null_flag > 1) return error.Protocol;
                const is_null = null_flag == 1;
                pos += 1;
                nulls[i] = is_null;
                if (is_null) {
                    values[i] = "";
                } else {
                    values[i] = try readString(arena, payload, &pos);
                }
            }
            break :blk Message{ .row_data = .{
                .values = values,
                .nulls = nulls,
            } };
        },
        .command_complete => blk: {
            if (payload.len < 8) return error.UnexpectedEof;
            const affected = std.mem.readInt(u64, payload[pos..][0..8], .big);
            pos += 8;
            const tag = try readString(arena, payload, &pos);
            break :blk Message{ .command_complete = .{
                .tag = tag,
                .affected_rows = affected,
            } };
        },
        .server_error => blk: {
            if (payload.len < 1) return error.UnexpectedEof;
            const severity = payload[pos];
            if (severity > 3) return error.Protocol;
            pos += 1;
            const code = try readString(arena, payload, &pos);
            const message = try readString(arena, payload, &pos);
            break :blk Message{ .server_error = .{
                .severity = severity,
                .code = code,
                .message = message,
            } };
        },
        .payload_begin => blk: {
            if (payload.len != 8 + 8 + proto.PAYLOAD_DIGEST_LENGTH) return error.Protocol;
            const digest = try arena.dupe(u8, payload[16..]);
            pos = payload.len;
            break :blk Message{ .payload_begin = .{
                .evidence_id = std.mem.readInt(u64, payload[0..8], .big),
                .payload_length = std.mem.readInt(u64, payload[8..16], .big),
                .payload_digest = digest,
            } };
        },
        .payload_chunk => blk: {
            if (payload.len < 8 or payload.len - 8 > proto.MAX_ATTACHMENT_CHUNK_LENGTH) return error.Protocol;
            const data = try arena.dupe(u8, payload[8..]);
            pos = payload.len;
            break :blk Message{ .payload_chunk = .{
                .evidence_id = std.mem.readInt(u64, payload[0..8], .big),
                .bytes = data,
            } };
        },
        .payload_finish => blk: {
            if (payload.len != 8) return error.Protocol;
            pos = payload.len;
            break :blk Message{ .payload_finish = .{ .evidence_id = std.mem.readInt(u64, payload[0..8], .big) } };
        },
        .goodbye => blk: {
            const reason = if (pos < payload.len) try readString(arena, payload, &pos) else "";
            break :blk Message{ .goodbye = .{ .reason = reason } };
        },
        else => return error.Protocol,
    };

    if (pos != payload.len) return error.Protocol;
    return message;
}

/// Map a stream read error onto the protocol error set.
fn mapReadError(err: anyerror) ProtocolError {
    return switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.Timeout => error.Timeout,
        error.ConnectionReset => error.ConnectionReset,
        error.ConnectionClosed => error.ConnectionClosed,
        error.QuicUnavailable => error.QuicUnavailable,
        error.QuicRejected => error.QuicRejected,
        error.HandshakeTimeout => error.HandshakeTimeout,
        error.CertificateMismatch => error.CertificateMismatch,
        error.UnsupportedAddress => error.UnsupportedAddress,
        else => error.ReadFailed,
    };
}

/// Write a protocol message to a stream. The caller is responsible for
/// flushing when the request is complete.
pub fn writeMessage(stream: Stream, msg_type: proto.Type, payload: []const u8) ProtocolError!void {
    if (payload.len > proto.MAX_BODY_LENGTH - 1) return error.MessageTooLarge;
    const body_len: u32 = @intCast(1 + payload.len); // type byte + payload
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], body_len, .big);
    header[4] = @intFromEnum(msg_type);
    stream.writeAll(&header) catch |err| return mapWriteError(err);
    if (payload.len > 0) {
        stream.writeAll(payload) catch |err| return mapWriteError(err);
    }
}

fn mapWriteError(err: anyerror) ProtocolError {
    return switch (err) {
        error.ConnectionClosed => error.ConnectionClosed,
        error.ConnectionReset => error.ConnectionReset,
        error.QuicUnavailable => error.QuicUnavailable,
        error.Timeout => error.Timeout,
        else => error.ReadFailed,
    };
}

// ── String wire format: u32(BE) len + bytes ──

fn readString(arena: Allocator, buf: []const u8, pos: *usize) ProtocolError![]const u8 {
    if (pos.* + 4 > buf.len) return error.UnexpectedEof;
    const len = std.mem.readInt(u32, buf[pos.*..][0..4], .big);
    pos.* += 4;
    if (len > proto.MAX_STRING_LENGTH) return error.StringTooLarge;
    if (len > buf.len - pos.*) return error.UnexpectedEof;
    const slice = try arena.alloc(u8, len);
    @memcpy(slice, buf[pos.*..][0..len]);
    pos.* += len;
    return slice;
}

pub fn writeString(stream: Stream, s: []const u8) !void {
    if (s.len > proto.MAX_STRING_LENGTH) return error.StringTooLarge;
    const len: u32 = @intCast(s.len);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, len, .big);
    try stream.writeAll(&len_buf);
    try stream.writeAll(s);
}

/// Build a hello payload.
pub fn buildHelloPayload(allocator: Allocator) ![]u8 {
    const payload = try allocator.alloc(u8, 4);
    std.mem.writeInt(u16, payload[0..2], proto.PROTOCOL_VERSION_MAJOR, .big);
    std.mem.writeInt(u16, payload[2..4], proto.PROTOCOL_VERSION_MINOR, .big);
    return payload;
}

// ── Tests ──

/// In-memory byte stream used by codec tests (and connection tests): reads
/// from `input`, writes are appended to `sink`.
pub const TestStream = struct {
    input: []const u8,
    pos: usize = 0,
    sink: std.ArrayList(u8) = .empty,
    allocator: Allocator,
    closed: bool = false,

    pub fn init(input: []const u8, allocator: Allocator) TestStream {
        return .{ .input = input, .allocator = allocator };
    }

    pub fn deinit(self: *TestStream) void {
        self.sink.deinit(self.allocator);
    }

    fn readAll(ctx: *anyopaque, buf: []u8) anyerror!void {
        const self: *TestStream = @ptrCast(@alignCast(ctx));
        if (self.pos + buf.len > self.input.len) return error.EndOfStream;
        @memcpy(buf, self.input[self.pos..][0..buf.len]);
        self.pos += buf.len;
    }
    fn writeAll(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *TestStream = @ptrCast(@alignCast(ctx));
        try self.sink.appendSlice(self.allocator, bytes);
    }
    fn flush(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }
    fn fin(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }
    fn closeFn(ctx: *anyopaque) void {
        const self: *TestStream = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }

    pub fn stream(self: *TestStream) Stream {
        const vtable = Stream.VTable{
            .readAll = readAll,
            .writeAll = writeAll,
            .flush = flush,
            .fin = fin,
            .close = closeFn,
        };
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "codec decodes a complete command response" {
    const bytes = [_]u8{
        0,   0,   0,   19,  @intFromEnum(proto.Type.command_complete),
        0,   0,   0,   0,   0,
        0,   0,   3,   0,   0,
        0,   6,   'I', 'N', 'S',
        'E', 'R', 'T',
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts = TestStream.init(&bytes, std.testing.allocator);
    defer ts.deinit();

    const message = try readMessage(arena.allocator(), ts.stream());
    switch (message) {
        .command_complete => |complete| {
            try std.testing.expectEqual(@as(u64, 3), complete.affected_rows);
            try std.testing.expectEqualStrings("INSERT", complete.tag);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "codec rejects malformed message payloads" {
    const cases = [_]struct {
        bytes: []const u8,
        expected: anyerror,
    }{
        .{ .bytes = &.{ 0, 0, 0, 1, @intFromEnum(proto.Type.row_description) }, .expected = error.UnexpectedEof },
        .{ .bytes = &.{ 0, 0, 0, 4, @intFromEnum(proto.Type.row_data), 0, 1, 2 }, .expected = error.Protocol },
        .{ .bytes = &.{
            0, 0, 0,   14, @intFromEnum(proto.Type.command_complete),
            0, 0, 0,   0,  0,
            0, 0, 0,   0,  0,
            0, 5, 'x',
        }, .expected = error.UnexpectedEof },
        .{ .bytes = &.{ 0, 0, 0, 7, @intFromEnum(proto.Type.hello_ok), 0, 0, 0, 1, 'x', 'y' }, .expected = error.Protocol },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ts = TestStream.init(case.bytes, std.testing.allocator);
        defer ts.deinit();
        try std.testing.expectError(case.expected, readMessage(arena.allocator(), ts.stream()));
    }
}

test "codec round-trips a message through write then read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts = TestStream.init("", std.testing.allocator);
    defer ts.deinit();

    // command_complete payload: affected_rows (u64 BE) + length-prefixed tag.
    var payload: [8 + 4 + 8]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], 3, .big);
    std.mem.writeInt(u32, payload[8..12], 8, .big);
    @memcpy(payload[12..], "SELECT 3");
    try writeMessage(ts.stream(), .command_complete, &payload);

    // Feed the captured bytes back in and decode.
    var reader = TestStream.init(ts.sink.items, std.testing.allocator);
    defer reader.deinit();
    const message = try readMessage(arena.allocator(), reader.stream());
    switch (message) {
        .command_complete => |complete| {
            try std.testing.expectEqual(@as(u64, 3), complete.affected_rows);
            try std.testing.expectEqualStrings("SELECT 3", complete.tag);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "codec rejects oversized outbound frames before writing" {
    var payload: [proto.MAX_BODY_LENGTH]u8 = undefined;
    var ts = TestStream.init("", std.testing.allocator);
    defer ts.deinit();

    try std.testing.expectError(
        error.MessageTooLarge,
        writeMessage(ts.stream(), .goodbye, &payload),
    );
}

test "stream reports end-of-stream on truncated input" {
    const bytes = [_]u8{ 0, 0, 0, 10, @intFromEnum(proto.Type.row_description), 0, 1 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts = TestStream.init(&bytes, std.testing.allocator);
    defer ts.deinit();
    try std.testing.expectError(error.EndOfStream, readMessage(arena.allocator(), ts.stream()));
}
