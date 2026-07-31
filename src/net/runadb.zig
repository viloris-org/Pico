//! RunaDB wire protocol server handler.
//! Handles one client connection speaking the native RunaDB protocol.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flow = @import("../flow/exec.zig");
const flow_ir = @import("../flow/ir.zig");
const engine_mod = @import("../storage/engine.zig");
const evidence_mod = @import("../storage/evidence.zig");
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

const Attachment = struct {
    upload_id: u64,
    expected_length: u64,
    expected_digest: [proto.PAYLOAD_DIGEST_LENGTH]u8,
    bytes: std.ArrayList(u8) = .empty,
    finished: bool = false,

    fn deinit(self: *Attachment, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        self.* = undefined;
    }
};

/// Handle one RunaDB protocol connection until terminate or error.
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

    var attachment: ?Attachment = null;
    defer if (attachment) |*item| item.deinit(gpa);

    // ── Main loop ──
    while (true) {
        const msg_type, const payload = readFrame(r) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        switch (msg_type) {
            .flow_source => {
                var pos: usize = 0;
                const source = readStringFromPayload(payload, &pos) catch {
                    try sendError(w, 2, "RF1000", "invalid Runa Flow source payload");
                    try w.flush();
                    continue;
                };
                if (pos != payload.len) {
                    try sendError(w, 2, "RF1000", "invalid Runa Flow source payload");
                    try w.flush();
                    continue;
                }
                var request = flow.compile(gpa, source) catch |err| {
                    try sendError(w, 2, "RF1001", @errorName(err));
                    try w.flush();
                    continue;
                };
                defer request.deinit(gpa);
                var result = flow.execute(gpa, eng, &request) catch |err| {
                    try sendError(w, 2, "RF1002", @errorName(err));
                    try w.flush();
                    continue;
                };
                defer result.deinit();

                try sendRowDescription(w, result.columns);
                for (result.cells) |cell_row| {
                    try sendRowData(w, cell_row);
                }
                try sendCommandComplete(w, "EMIT", result.cells.len);
                try w.flush();
            },
            .flow_ir => {
                if (payload.len < 2) {
                    try sendError(w, 2, "RF1003", "invalid Runa Query IR payload");
                    try w.flush();
                    continue;
                }
                const format_version = std.mem.readInt(u16, payload[0..2], .big);
                if (format_version != proto.IR_FORMAT_VERSION) {
                    try sendError(w, 2, "RF1004", "unsupported Runa Query IR format version");
                    try w.flush();
                    continue;
                }
                var request = flow_ir.decode(gpa, payload[2..]) catch |err| {
                    try sendError(w, 2, "RF1003", @errorName(err));
                    try w.flush();
                    continue;
                };
                defer request.deinit(gpa);
                switch (request.operation) {
                    .emit => {
                        var result = flow.execute(gpa, eng, &request) catch |err| {
                            try sendError(w, 2, "RF1002", @errorName(err));
                            try w.flush();
                            continue;
                        };
                        defer result.deinit();
                        try sendRowDescription(w, result.columns);
                        for (result.cells) |cell_row| try sendRowData(w, cell_row);
                        try sendCommandComplete(w, "EMIT", result.cells.len);
                        try w.flush();
                    },
                    .observe => {
                        const staged = if (attachment) |*item| item else {
                            try sendError(w, 2, "EV1001", "completed attachment required");
                            try w.flush();
                            continue;
                        };
                        if (!staged.finished or staged.upload_id != request.observe.?.upload_id) {
                            try sendError(w, 2, "EV1001", "attachment is incomplete or does not match the request");
                            try w.flush();
                            continue;
                        }
                        const modality = std.enums.fromInt(evidence_mod.Modality, request.observe.?.modality) orelse {
                            try sendError(w, 2, "EV1002", "invalid modality");
                            try w.flush();
                            continue;
                        };
                        const observation = request.observe.?;
                        const evidence_id = eng.observe(observation.object_id, modality, observation.media_type, observation.observed_at, observation.origin, "development", staged.bytes.items) catch |err| {
                            try sendError(w, 2, "EV1003", @errorName(err));
                            try w.flush();
                            continue;
                        };
                        staged.deinit(gpa);
                        attachment = null;
                        var id_buf: [32]u8 = undefined;
                        const id_text = std.fmt.bufPrint(&id_buf, "{d}", .{evidence_id}) catch unreachable;
                        var columns = [_][]const u8{"evidence_id"};
                        var cells = [_]?[]const u8{id_text};
                        try sendRowDescription(w, &columns);
                        try sendRowData(w, &cells);
                        try sendCommandComplete(w, "OBSERVE", 1);
                        try w.flush();
                    },
                    .read_evidence_payload => {
                        const payload_bytes = eng.readEvidencePayload(request.evidence_id) catch |err| {
                            try sendError(w, 2, "EV1004", @errorName(err));
                            try w.flush();
                            continue;
                        };
                        defer gpa.free(payload_bytes);
                        try sendPayload(w, request.evidence_id, payload_bytes);
                        try sendCommandComplete(w, "READ EVIDENCE PAYLOAD", 1);
                        try w.flush();
                    },
                }
            },
            .attachment_begin => {
                if (payload.len != 8 + 8 + proto.PAYLOAD_DIGEST_LENGTH or attachment != null) {
                    try sendError(w, 2, "EV1001", "invalid attachment begin");
                    try w.flush();
                    continue;
                }
                const upload_id = std.mem.readInt(u64, payload[0..8], .big);
                const expected_length = std.mem.readInt(u64, payload[8..16], .big);
                if (upload_id == 0 or expected_length > proto.MAX_ATTACHMENT_LENGTH) {
                    try sendError(w, 2, "EV1001", "attachment limit exceeded");
                    try w.flush();
                    continue;
                }
                var expected_digest: [proto.PAYLOAD_DIGEST_LENGTH]u8 = undefined;
                @memcpy(&expected_digest, payload[16..]);
                attachment = .{ .upload_id = upload_id, .expected_length = expected_length, .expected_digest = expected_digest };
            },
            .attachment_chunk => {
                if (attachment == null or payload.len < 8 or payload.len - 8 > proto.MAX_ATTACHMENT_CHUNK_LENGTH) {
                    try sendError(w, 2, "EV1001", "invalid attachment chunk");
                    try w.flush();
                    continue;
                }
                const upload_id = std.mem.readInt(u64, payload[0..8], .big);
                const staged = &attachment.?;
                if (staged.finished or staged.upload_id != upload_id or staged.bytes.items.len + payload.len - 8 > staged.expected_length) {
                    try sendError(w, 2, "EV1001", "attachment chunk does not match declared shape");
                    try w.flush();
                    continue;
                }
                try staged.bytes.appendSlice(gpa, payload[8..]);
            },
            .attachment_finish => {
                if (attachment == null or payload.len != 8) {
                    try sendError(w, 2, "EV1001", "invalid attachment finish");
                    try w.flush();
                    continue;
                }
                const upload_id = std.mem.readInt(u64, payload[0..8], .big);
                const staged = &attachment.?;
                if (staged.upload_id != upload_id or staged.bytes.items.len != staged.expected_length or !std.mem.eql(u8, &evidence_mod.digest(staged.bytes.items), &staged.expected_digest)) {
                    staged.deinit(gpa);
                    attachment = null;
                    try sendError(w, 2, "EV1001", "attachment length or digest mismatch");
                    try w.flush();
                    continue;
                }
                staged.finished = true;
            },
            .attachment_abort => {
                if (payload.len != 8 or attachment == null or std.mem.readInt(u64, payload[0..8], .big) != attachment.?.upload_id) {
                    try sendError(w, 2, "EV1001", "invalid attachment abort");
                    try w.flush();
                    continue;
                }
                attachment.?.deinit(gpa);
                attachment = null;
            },
            .goodbye => {
                if (!validGoodbyePayload(payload)) return error.Protocol;
                try sendGoodbye(w, "ok");
                try w.flush();
                return;
            },
            else => {
                try sendError(w, 2, "RF1005", "unknown message type");
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
    const s = "RunaDB 0.0.1";
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

fn sendPayload(w: anytype, evidence_id: u64, payload: []const u8) !void {
    var begin: [8 + 8 + proto.PAYLOAD_DIGEST_LENGTH]u8 = undefined;
    std.mem.writeInt(u64, begin[0..8], evidence_id, .big);
    std.mem.writeInt(u64, begin[8..16], payload.len, .big);
    const payload_digest = evidence_mod.digest(payload);
    @memcpy(begin[16..], &payload_digest);
    try sendFrame(w, .payload_begin, &begin);

    var offset: usize = 0;
    while (offset < payload.len) {
        const length = @min(proto.MAX_ATTACHMENT_CHUNK_LENGTH, payload.len - offset);
        try sendFrameHeader(w, .payload_chunk, 8 + length);
        var id: [8]u8 = undefined;
        std.mem.writeInt(u64, &id, evidence_id, .big);
        try w.writeAll(&id);
        try w.writeAll(payload[offset .. offset + length]);
        offset += length;
    }
    var finish: [8]u8 = undefined;
    std.mem.writeInt(u64, &finish, evidence_id, .big);
    try sendFrame(w, .payload_finish, &finish);
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

// ── Wire Protocol malformed-frame tests ──

test "readFrame rejects zero body length" {
    const bytes = [_]u8{ 0, 0, 0, 0, @intFromEnum(proto.Type.flow_source) };
    var reader: Io.Reader = .fixed(&bytes);
    try std.testing.expectError(error.Protocol, readFrame(&reader));
}

test "readFrame rejects body length exceeding maximum" {
    var bytes: [5]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], @intCast(proto.MAX_BODY_LENGTH + 1), .big);
    bytes[4] = @intFromEnum(proto.Type.flow_source);
    var reader: Io.Reader = .fixed(&bytes);
    try std.testing.expectError(error.MessageTooLarge, readFrame(&reader));
}

test "readFrame returns error when payload bytes are missing" {
    // Header says 10-byte body (9-byte payload) but buffer ends after the header.
    var bytes: [5]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 10, .big);
    bytes[4] = @intFromEnum(proto.Type.flow_source);
    var reader: Io.Reader = .fixed(&bytes);
    try std.testing.expectError(error.EndOfStream, readFrame(&reader));
}

test "validGoodbyePayload accepts empty payload" {
    try std.testing.expect(validGoodbyePayload(&.{}));
}

test "validGoodbyePayload accepts a well-formed reason string" {
    const payload = [_]u8{ 0, 0, 0, 2, 'o', 'k' };
    try std.testing.expect(validGoodbyePayload(&payload));
}

test "validGoodbyePayload rejects a truncated string" {
    // length prefix declares 5 bytes but only 3 follow
    const payload = [_]u8{ 0, 0, 0, 5, 'b', 'y', 'e' };
    try std.testing.expect(!validGoodbyePayload(&payload));
}

test "validGoodbyePayload rejects trailing bytes after reason string" {
    const payload = [_]u8{ 0, 0, 0, 2, 'o', 'k', 0xff };
    try std.testing.expect(!validGoodbyePayload(&payload));
}

test "sendHelloError encodes frame type and reason string" {
    // Expected frame: [body_len u32 BE][type u8][str_len u32 BE][str bytes]
    // reason = "bad version" (11 chars); body_len = 1 + 4 + 11 = 16
    var output: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&output);
    try sendHelloError(&writer, "bad version");
    const encoded = writer.buffered();
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, encoded[0..4], .big));
    try std.testing.expectEqual(@as(u8, @intFromEnum(proto.Type.hello_error)), encoded[4]);
    try std.testing.expectEqual(@as(u32, 11), std.mem.readInt(u32, encoded[5..9], .big));
    try std.testing.expectEqualStrings("bad version", encoded[9..20]);
}

test "sendError encodes severity, code, and message fields" {
    // Expected layout after the 5-byte frame header:
    //   [severity u8][code_len u32 BE][code][msg_len u32 BE][msg]
    var output: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&output);
    try sendError(&writer, 2, "P0001", "NotFound");
    const encoded = writer.buffered();
    try std.testing.expectEqual(@as(u8, @intFromEnum(proto.Type.server_error)), encoded[4]);
    try std.testing.expectEqual(@as(u8, 2), encoded[5]);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, encoded[6..10], .big));
    try std.testing.expectEqualStrings("P0001", encoded[10..15]);
}
