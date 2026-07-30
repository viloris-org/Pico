//! Pico wire protocol server handler.
//! Handles one client connection speaking the native Pico protocol.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const exec = @import("../sql/exec.zig");
const engine_mod = @import("../storage/engine.zig");
const proto = @import("clint_proto");

const ConnError = error{
    Protocol,
    UnexpectedEof,
    MessageTooLarge,
    VersionMismatch,
    Canceled,
    EndOfStream,
    ReadFailed,
    WriteFailed,
} || Allocator.Error || Io.Cancelable || Io.UnexpectedError;

/// Handle one Pico protocol connection until terminate or error.
pub fn handleConnection(
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    eng: *engine_mod.Engine,
) ConnError!void {
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    const r = &reader.interface;
    const w = &writer.interface;

    var session = exec.Session.init(gpa);
    defer {
        session.rollback();
        session.deinit();
    }

    // ── Handshake: read HELLO ──
    {
        const msg_type, const payload = try readFrame(r);
        if (msg_type != .hello or payload.len != 4) return error.Protocol;

        const major = std.mem.readInt(u16, payload[0..2], .big);
        const minor = std.mem.readInt(u16, payload[2..4], .big);

        if (major != proto.PROTOCOL_VERSION_MAJOR) {
            try sendHelloError(w, "unsupported protocol version");
            try w.flush();
            return error.VersionMismatch;
        }
        _ = minor;

        try sendHelloOk(w);
        try w.flush();
    }

    // ── Main loop ──
    while (true) {
        const msg_type, const payload = readFrame(r) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        switch (msg_type) {
            .query => {
                var pos: usize = 0;
                const sql = readStringFromPayload(payload, &pos) catch {
                    try sendError(w, 2, "P0000", "invalid query message");
                    try w.flush();
                    continue;
                };
                if (pos != payload.len) {
                    try sendError(w, 2, "P0000", "invalid query message");
                    try w.flush();
                    continue;
                }

                var result = exec.execute(gpa, eng, &session, sql) catch |err| {
                    try sendError(w, 2, "P0001", @errorName(err));
                    try w.flush();
                    continue;
                };
                defer result.deinit();

                switch (result) {
                    .empty => |tag| {
                        try sendCommandComplete(w, tag, 0);
                    },
                    .rows => |rows| {
                        try sendRowDescription(w, rows.col_names);
                        for (rows.cells) |cell_row| {
                            try sendRowData(w, cell_row);
                        }
                        try sendCommandComplete(w, "SELECT", rows.cells.len);
                    },
                }
                try w.flush();
            },
            .goodbye => {
                if (!validGoodbyePayload(payload)) return error.Protocol;
                try sendGoodbye(w, "ok");
                try w.flush();
                return;
            },
            else => {
                try sendError(w, 2, "P0002", "unknown message type");
                try w.flush();
                return;
            },
        }
    }
}

// ── Frame I/O ──

/// Read one protocol frame: returns (type, payload).
fn readFrame(r: anytype) !struct { proto.Type, []const u8 } {
    const header = try r.takeArray(proto.HEADER_SIZE);
    const body_len = std.mem.readInt(u32, header[0..4], .big);
    if (body_len < 1) return error.Protocol;
    if (body_len > proto.MAX_BODY_LENGTH) return error.MessageTooLarge;
    const msg_type: proto.Type = @enumFromInt(header[4]);
    const payload_len: usize = @intCast(body_len - 1);
    const payload = try r.take(payload_len);
    return .{ msg_type, payload };
}

/// Send a framed message.
fn sendFrame(w: anytype, msg_type: proto.Type, payload: []const u8) !void {
    try sendFrameHeader(w, msg_type, payload.len);
    if (payload.len > 0) try w.writeAll(payload);
}

fn sendFrameHeader(w: anytype, msg_type: proto.Type, payload_len: usize) !void {
    if (payload_len > proto.MAX_BODY_LENGTH - 1) return error.MessageTooLarge;
    const body_len: u32 = @intCast(1 + payload_len);
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], body_len, .big);
    header[4] = @intFromEnum(msg_type);
    try w.writeAll(&header);
}

// ── Message helpers ──

fn sendHelloOk(w: anytype) !void {
    const s = "Pico 0.0.1";
    try sendFrameHeader(w, .hello_ok, try stringPayloadLen(s));
    try sendString(w, s);
}

fn sendHelloError(w: anytype, reason: []const u8) !void {
    try sendFrameHeader(w, .hello_error, try stringPayloadLen(reason));
    try sendString(w, reason);
}

fn sendRowDescription(w: anytype, col_names: [][]const u8) !void {
    if (col_names.len > std.math.maxInt(u16)) return error.MessageTooLarge;
    const cc: u16 = @intCast(col_names.len);
    var payload_len: usize = 2;
    for (col_names) |name| {
        payload_len = try addPayloadLength(payload_len, try stringPayloadLen(name));
    }
    try sendFrameHeader(w, .row_description, payload_len);
    var count_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &count_buf, cc, .big);
    try w.writeAll(&count_buf);
    for (col_names) |name| try sendString(w, name);
}

fn sendRowData(w: anytype, cells: []?[]const u8) !void {
    if (cells.len > std.math.maxInt(u16)) return error.MessageTooLarge;
    const cc: u16 = @intCast(cells.len);
    var payload_len: usize = 2;
    for (cells) |cell| {
        payload_len = try addPayloadLength(payload_len, 1);
        if (cell) |val| payload_len = try addPayloadLength(payload_len, try stringPayloadLen(val));
    }
    try sendFrameHeader(w, .row_data, payload_len);
    var count_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &count_buf, cc, .big);
    try w.writeAll(&count_buf);
    for (cells) |cell| {
        if (cell) |value| {
            try w.writeByte(0);
            try sendString(w, value);
        } else {
            try w.writeByte(1);
        }
    }
}

fn sendCommandComplete(w: anytype, tag: []const u8, affected_rows: usize) !void {
    const ar: u64 = @intCast(affected_rows);
    try sendFrameHeader(w, .command_complete, try addPayloadLength(8, try stringPayloadLen(tag)));
    var affected_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &affected_buf, ar, .big);
    try w.writeAll(&affected_buf);
    try sendString(w, tag);
}

fn sendError(w: anytype, severity: u8, code: []const u8, message: []const u8) !void {
    if (severity > 3) return error.Protocol;
    var payload_len: usize = 1;
    payload_len = try addPayloadLength(payload_len, try stringPayloadLen(code));
    payload_len = try addPayloadLength(payload_len, try stringPayloadLen(message));
    try sendFrameHeader(w, .server_error, payload_len);
    try w.writeByte(severity);
    try sendString(w, code);
    try sendString(w, message);
}

fn sendGoodbye(w: anytype, reason: []const u8) !void {
    try sendFrameHeader(w, .goodbye, try stringPayloadLen(reason));
    try sendString(w, reason);
}

// ── String wire format helpers ──

fn readStringFromPayload(payload: []const u8, pos: *usize) ![]const u8 {
    if (pos.* + 4 > payload.len) return error.Protocol;
    const len = std.mem.readInt(u32, payload[pos.*..][0..4], .big);
    pos.* += 4;
    if (len > proto.MAX_STRING_LENGTH) return error.MessageTooLarge;
    if (len > payload.len - pos.*) return error.Protocol;
    const result = payload[pos.* .. pos.* + len];
    pos.* += len;
    return result;
}

fn stringPayloadLen(value: []const u8) !usize {
    if (value.len > proto.MAX_STRING_LENGTH) return error.MessageTooLarge;
    return addPayloadLength(4, value.len);
}

fn addPayloadLength(current: usize, additional: usize) !usize {
    const total = std.math.add(usize, current, additional) catch return error.MessageTooLarge;
    if (total > proto.MAX_BODY_LENGTH - 1) return error.MessageTooLarge;
    return total;
}

fn sendString(w: anytype, value: []const u8) !void {
    if (value.len > proto.MAX_STRING_LENGTH) return error.MessageTooLarge;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(value.len), .big);
    try w.writeAll(&len_buf);
    try w.writeAll(value);
}

fn validGoodbyePayload(payload: []const u8) bool {
    if (payload.len == 0) return true;
    var pos: usize = 0;
    _ = readStringFromPayload(payload, &pos) catch return false;
    return pos == payload.len;
}

test "row data encoding supports values larger than the old fixed buffer" {
    var value: [5_000]u8 = undefined;
    @memset(&value, 'x');
    const cells = [_]?[]const u8{value[0..]};
    var output: [5_012]u8 = undefined;
    var writer: Io.Writer = .fixed(&output);

    try sendRowData(&writer, &cells);

    const encoded = writer.buffered();
    try std.testing.expectEqual(@as(usize, output.len), encoded.len);
    try std.testing.expectEqual(@as(u32, 5_008), std.mem.readInt(u32, encoded[0..4], .big));
    try std.testing.expectEqual(proto.Type.row_data, @as(proto.Type, @enumFromInt(encoded[4])));
}
