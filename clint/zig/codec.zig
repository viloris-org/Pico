//! Pico wire protocol codec — read/write protocol messages to a stream.
//! Used by the client library. The server handler uses its own read/write
//! but consumes clint_proto type definitions.

const std = @import("std");
const proto = @import("clint_proto");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const ProtocolError = error{
    UnexpectedEof,
    Protocol,
    MessageTooLarge,
    VersionMismatch,
    ServerRejected,
    StringTooLarge,
    EndOfStream,
    ReadFailed,
} || Allocator.Error;

pub const Message = union(enum) {
    hello_ok: struct { server_version: []const u8 },
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
    goodbye: struct { reason: []const u8 },
};

/// Read one protocol message from a stream.
/// Caller owns allocated memory (strings are arena-allocated from arena).
pub fn readMessage(arena: Allocator, reader: anytype) ProtocolError!Message {
    // Read header: 4-byte length + 1-byte type
    const header = try reader.takeArray(proto.HEADER_SIZE);
    const body_len = std.mem.readInt(u32, header[0..4], .big);
    if (body_len < 1) return error.Protocol;
    if (body_len > proto.MAX_BODY_LENGTH) return error.MessageTooLarge;
    const msg_type_int = header[4];
    const msg_type: proto.Type = @enumFromInt(msg_type_int);
    const payload_len: usize = @intCast(body_len - 1);
    const payload = try arena.alloc(u8, payload_len);
    if (payload_len > 0) {
        const body = try reader.take(payload_len);
        @memcpy(payload, body);
    }
    var pos: usize = 0;

    return switch (msg_type) {
        .hello_ok => blk: {
            const sv = try readString(arena, payload, &pos);
            break :blk Message{ .hello_ok = .{ .server_version = sv } };
        },
        .hello_error => blk: {
            const reason = try readString(arena, payload, &pos);
            break :blk Message{ .hello_error = .{ .reason = reason } };
        },
        .row_description => blk: {
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
            const col_count = std.mem.readInt(u16, payload[pos..][0..2], .big);
            pos += 2;
            var values = try arena.alloc([]const u8, col_count);
            var nulls = try arena.alloc(bool, col_count);
            for (0..col_count) |i| {
                const is_null = payload[pos] != 0;
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
            const affected = std.mem.readInt(u64, payload[pos..][0..8], .big);
            pos += 8;
            const tag = try readString(arena, payload, &pos);
            break :blk Message{ .command_complete = .{
                .tag = tag,
                .affected_rows = affected,
            } };
        },
        .server_error => blk: {
            const severity = payload[pos];
            pos += 1;
            const code = try readString(arena, payload, &pos);
            const message = try readString(arena, payload, &pos);
            break :blk Message{ .server_error = .{
                .severity = severity,
                .code = code,
                .message = message,
            } };
        },
        .goodbye => blk: {
            const reason = if (pos < payload.len) try readString(arena, payload, &pos) else "";
            break :blk Message{ .goodbye = .{ .reason = reason } };
        },
        else => return error.Protocol,
    };
}

/// Write a protocol message to a stream.
pub fn writeMessage(writer: *Io.Writer, msg_type: proto.Type, payload: []const u8) !void {
    const body_len: u32 = @intCast(1 + payload.len); // type byte + payload
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], body_len, .big);
    header[4] = @intFromEnum(msg_type);
    try writer.writeAll(&header);
    if (payload.len > 0) {
        try writer.writeAll(payload);
    }
}

// ── String wire format: u32(BE) len + bytes ──

fn readString(arena: Allocator, buf: []const u8, pos: *usize) ProtocolError![]const u8 {
    if (pos.* + 4 > buf.len) return error.UnexpectedEof;
    const len = std.mem.readInt(u32, buf[pos.*..][0..4], .big);
    pos.* += 4;
    if (len > proto.MAX_STRING_LENGTH) return error.StringTooLarge;
    const slice = try arena.alloc(u8, len);
    @memcpy(slice, buf[pos.*..][0..len]);
    pos.* += len;
    return slice;
}

pub fn writeString(writer: anytype, s: []const u8) !void {
    const len: u32 = @intCast(s.len);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, len, .big);
    try writer.writeAll(&len_buf);
    try writer.writeAll(s);
}

/// Build a hello payload.
pub fn buildHelloPayload(allocator: Allocator) ![]u8 {
    const payload = try allocator.alloc(u8, 4);
    std.mem.writeInt(u16, payload[0..2], proto.PROTOCOL_VERSION_MAJOR, .big);
    std.mem.writeInt(u16, payload[2..4], proto.PROTOCOL_VERSION_MINOR, .big);
    return payload;
}
