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
        if (msg_type != .hello) return error.Protocol;
        if (payload.len < 4) return error.Protocol;

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
    const body_len: u32 = @intCast(1 + payload.len);
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], body_len, .big);
    header[4] = @intFromEnum(msg_type);
    try w.writeAll(&header);
    if (payload.len > 0) try w.writeAll(payload);
}

// ── Message helpers ──

fn sendHelloOk(w: anytype) !void {
    const s = "Pico 0.0.1";
    const sl: u32 = @intCast(s.len);
    var payload_buf: [256]u8 = undefined;
    std.mem.writeInt(u32, payload_buf[0..4], sl, .big);
    @memcpy(payload_buf[4..][0..sl], s);
    try sendFrame(w, .hello_ok, payload_buf[0 .. 4 + sl]);
}

fn sendHelloError(w: anytype, reason: []const u8) !void {
    const rl: u32 = @intCast(reason.len);
    var buf: [256]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], rl, .big);
    @memcpy(buf[4..][0..rl], reason);
    try sendFrame(w, .hello_error, buf[0 .. 4 + rl]);
}

fn sendRowDescription(w: anytype, col_names: [][]const u8) !void {
    // Build payload in write buffer ahead
    var payload_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const cc: u16 = @intCast(col_names.len);
    std.mem.writeInt(u16, payload_buf[pos..][0..2], cc, .big);
    pos += 2;
    for (col_names) |name| {
        const nl: u32 = @intCast(name.len);
        std.mem.writeInt(u32, payload_buf[pos..][0..4], nl, .big);
        pos += 4;
        @memcpy(payload_buf[pos..][0..nl], name);
        pos += nl;
    }
    try sendFrame(w, .row_description, payload_buf[0..pos]);
}

fn sendRowData(w: anytype, cells: []?[]const u8) !void {
    var payload_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const cc: u16 = @intCast(cells.len);
    std.mem.writeInt(u16, payload_buf[pos..][0..2], cc, .big);
    pos += 2;
    for (cells) |cell| {
        if (cell) |val| {
            payload_buf[pos] = 0;
            pos += 1;
            const vl: u32 = @intCast(val.len);
            std.mem.writeInt(u32, payload_buf[pos..][0..4], vl, .big);
            pos += 4;
            @memcpy(payload_buf[pos..][0..vl], val);
            pos += vl;
        } else {
            payload_buf[pos] = 1;
            pos += 1;
        }
    }
    try sendFrame(w, .row_data, payload_buf[0..pos]);
}

fn sendCommandComplete(w: anytype, tag: []const u8, affected_rows: usize) !void {
    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    const ar: u64 = @intCast(affected_rows);
    std.mem.writeInt(u64, buf[pos..][0..8], ar, .big);
    pos += 8;
    const tl: u32 = @intCast(tag.len);
    std.mem.writeInt(u32, buf[pos..][0..4], tl, .big);
    pos += 4;
    @memcpy(buf[pos..][0..tl], tag);
    pos += tl;
    try sendFrame(w, .command_complete, buf[0..pos]);
}

fn sendError(w: anytype, severity: u8, code: []const u8, message: []const u8) !void {
    _ = severity;
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = 2;
    pos += 1;
    const cl: u32 = @intCast(code.len);
    std.mem.writeInt(u32, buf[pos..][0..4], cl, .big);
    pos += 4;
    @memcpy(buf[pos..][0..cl], code);
    pos += cl;
    const ml: u32 = @intCast(message.len);
    std.mem.writeInt(u32, buf[pos..][0..4], ml, .big);
    pos += 4;
    @memcpy(buf[pos..][0..ml], message);
    pos += ml;
    try sendFrame(w, proto.Type.server_error, buf[0..pos]);
}

fn sendGoodbye(w: anytype, reason: []const u8) !void {
    const rl: u32 = @intCast(reason.len);
    var buf: [256]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], rl, .big);
    @memcpy(buf[4..][0..rl], reason);
    try sendFrame(w, .goodbye, buf[0 .. 4 + rl]);
}

// ── String wire format helpers ──

fn readStringFromPayload(payload: []const u8, pos: *usize) ![]const u8 {
    if (pos.* + 4 > payload.len) return error.Protocol;
    const len = std.mem.readInt(u32, payload[pos.*..][0..4], .big);
    pos.* += 4;
    if (len > proto.MAX_STRING_LENGTH) return error.MessageTooLarge;
    const result = payload[pos.* .. pos.* + len];
    pos.* += len;
    return result;
}
