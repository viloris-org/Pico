//! RunaDB wire protocol server handler.
//! Handles one client connection speaking the native RunaDB protocol.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flow = @import("../flow/exec.zig");
const flow_ir = @import("../flow/ir.zig");
const engine_mod = @import("../storage/engine.zig");
const evidence_mod = @import("../storage/evidence.zig");
const document_mod = @import("../storage/document.zig");
const connection_mod = @import("connection.zig");
const registry_mod = @import("registry.zig");
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
    RegistryFull,
} || Allocator.Error || Io.Cancelable || Io.UnexpectedError;

const Attachment = struct {
    upload_id: u64,
    expected_length: u64,
    expected_digest: [proto.PAYLOAD_DIGEST_LENGTH]u8,
    bytes: std.ArrayList(u8) = .empty,
    finished: bool = false,
    /// True while this connection holds an instance-wide staging reservation
    /// (begun but not yet finished or aborted). Guards the engine accounting so
    /// a reservation is released exactly once on every exit path.
    staging_reserved: bool = false,

    fn deinit(self: *Attachment, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        self.* = undefined;
    }
};

/// RAII guard over the engine's statement-execution lock (roadmap Phase 6). A
/// connection thread holds the lock for the whole execution of one request —
/// compile + bind + execute and any mutation — and releases it before the
/// fully-owned result is sent over the wire. Because only one statement runs at
/// a time, concurrent connections never observe the engine mid-statement, and a
/// DDL that frees engine column state can never race a result being sent. The
/// engine's `writer_mutex` and the coordinator's mutex nest under this lock.
const EngineGuard = struct {
    eng: *engine_mod.Engine,
    io: Io,
    held: bool = true,

    fn acquire(eng: *engine_mod.Engine, io: Io) (Io.Cancelable)!EngineGuard {
        try eng.lock(io);
        return .{ .eng = eng, .io = io };
    }

    fn release(self: *EngineGuard) void {
        if (self.held) {
            self.held = false;
            self.eng.unlock(self.io);
        }
    }

    fn deinit(self: *EngineGuard) void {
        self.release();
    }
};

/// Handle one RunaDB protocol connection until terminate or error. The
/// connection registers with the instance registry after accept and revokes
/// its credential on every exit path, so a disconnected connection can never
/// leak cancellation state.
pub fn handleConnection(
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    eng: *engine_mod.Engine,
    registry: *registry_mod.Registry,
    credential: connection_mod.Credential,
) ConnError!void {
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    const r = &reader.interface;
    const w = &writer.interface;

    var conn = connection_mod.State.init(0, credential);
    var registered = false;
    defer if (registered) registry.unregister(&conn);

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

        // Register only after the version check: a peer that never completes
        // the handshake, or is rejected on version, must not hold a slot in
        // the bounded connection table. The credential is delivered in
        // HELLO_OK immediately after, so no cancel can arrive before this
        // registration. Admission errors are reported distinctly: capacity
        // exhaustion is not an allocation failure.
        registry.register(&conn) catch |err| {
            try sendHelloError(w, switch (err) {
                error.RegistryFull => "instance connection table full",
                error.OutOfMemory => "instance out of memory",
                else => "connection rejected",
            });
            try w.flush();
            return err;
        };
        registered = true;

        try sendHelloOk(w, conn.credential);
        try w.flush();
    }

    var attachment: ?Attachment = null;
    defer if (attachment) |*item| {
        // A connection that drops mid-upload must release its staging
        // reservation so the instance-wide quota cannot leak. The staging
        // counters are shared engine state, so the release runs under the
        // uncancelable statement lock: it must complete exactly once on every
        // exit path.
        if (item.staging_reserved) {
            eng.lockUncancelable(io);
            eng.abortStage(item.expected_length);
            eng.unlock(io);
        }
        item.deinit(gpa);
    };

    // ── Main loop ──
    while (true) {
        const msg_type, const payload = readFrame(r) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        switch (msg_type) {
            .flow_source => {
                // Statement start: a fresh generation clears any stale mark so
                // a cancel delivered while idle never aborts this statement.
                // Entry and exit are single atomic transitions on the
                // connection state, and the cooperative check is the Phase 6
                // seam; in the sequential listener a cancel is delivered only
                // between statements, so these never fire here.
                conn.beginStatement();
                defer conn.endStatement();
                conn.checkCancelled() catch |err| {
                    try sendError(w, 2, "RF1002", @errorName(err));
                    try w.flush();
                    continue;
                };
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
                var guard = try EngineGuard.acquire(eng, io);
                defer guard.deinit();
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

                // The result is fully owned; release the engine before sending.
                guard.release();
                try sendRowDescription(w, result.columns);
                for (result.cells) |cell_row| {
                    try sendRowData(w, cell_row);
                }
                try sendCommandComplete(w, "EMIT", result.cells.len);
                try w.flush();
            },
            .flow_ir => {
                // Statement start (see .flow_source for the Phase 6 seam note).
                conn.beginStatement();
                defer conn.endStatement();
                conn.checkCancelled() catch |err| {
                    try sendError(w, 2, "RF1002", @errorName(err));
                    try w.flush();
                    continue;
                };
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
                        var guard = try EngineGuard.acquire(eng, io);
                        defer guard.deinit();
                        var result = flow.execute(gpa, eng, &request) catch |err| {
                            try sendError(w, 2, "RF1002", @errorName(err));
                            try w.flush();
                            continue;
                        };
                        defer result.deinit();
                        guard.release();
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
                        var guard = try EngineGuard.acquire(eng, io);
                        defer guard.deinit();
                        const evidence_id = eng.observe(observation.object_id, modality, observation.media_type, observation.observed_at, observation.origin, "development", staged.bytes.items) catch |err| {
                            try sendError(w, 2, "EV1003", @errorName(err));
                            try w.flush();
                            continue;
                        };
                        guard.release();
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
                        var guard = try EngineGuard.acquire(eng, io);
                        defer guard.deinit();
                        const payload_bytes = eng.readEvidencePayload(request.evidence_id) catch |err| {
                            try sendError(w, 2, "EV1004", @errorName(err));
                            try w.flush();
                            continue;
                        };
                        guard.release();
                        defer gpa.free(payload_bytes);
                        try sendPayload(w, request.evidence_id, payload_bytes);
                        try sendCommandComplete(w, "READ EVIDENCE PAYLOAD", 1);
                        try w.flush();
                    },
                    .document_insert => {
                        const insert = request.document_insert.?;
                        // Borrow the request's fields; the engine clones them
                        // into the collection, so nothing is moved or shared.
                        var fields: std.ArrayList(document_mod.Field) = .empty;
                        defer fields.deinit(gpa);
                        try fields.ensureTotalCapacity(gpa, insert.fields.len);
                        for (insert.fields) |*field| {
                            fields.appendAssumeCapacity(.{ .path = field.path, .item = field.item });
                        }
                        var guard = try EngineGuard.acquire(eng, io);
                        defer guard.deinit();
                        eng.insertDocument(insert.collection, insert.id, fields.items) catch |err| {
                            try sendError(w, 2, "DF1001", @errorName(err));
                            try w.flush();
                            continue;
                        };
                        guard.release();
                        var columns = [_][]const u8{"document_id"};
                        var cells = [_]?[]const u8{insert.id};
                        try sendRowDescription(w, &columns);
                        try sendRowData(w, &cells);
                        try sendCommandComplete(w, "INSERT DOCUMENT", 1);
                        try w.flush();
                    },
                    .graph_add_node => {
                        const insert = request.graph_add_node.?;
                        var fields: std.ArrayList(document_mod.Field) = .empty;
                        defer fields.deinit(gpa);
                        try fields.ensureTotalCapacity(gpa, insert.fields.len);
                        for (insert.fields) |*field| {
                            fields.appendAssumeCapacity(.{ .path = field.path, .item = field.item });
                        }
                        var guard = try EngineGuard.acquire(eng, io);
                        defer guard.deinit();
                        eng.addNode(insert.graph, insert.id, fields.items) catch |err| {
                            try sendError(w, 2, "GF1001", @errorName(err));
                            try w.flush();
                            continue;
                        };
                        guard.release();
                        var node_columns = [_][]const u8{"node_id"};
                        var node_cells = [_]?[]const u8{insert.id};
                        try sendRowDescription(w, &node_columns);
                        try sendRowData(w, &node_cells);
                        try sendCommandComplete(w, "ADD NODE", 1);
                        try w.flush();
                    },
                    .graph_add_edge => {
                        const edge = request.graph_add_edge.?;
                        var guard = try EngineGuard.acquire(eng, io);
                        defer guard.deinit();
                        eng.addEdge(edge.graph, edge.from, edge.label, edge.to) catch |err| {
                            try sendError(w, 2, "GF1002", @errorName(err));
                            try w.flush();
                            continue;
                        };
                        guard.release();
                        var edge_columns = [_][]const u8{"from", "label", "to"};
                        var edge_cells = [_]?[]const u8{ edge.from, edge.label, edge.to };
                        try sendRowDescription(w, &edge_columns);
                        try sendRowData(w, &edge_cells);
                        try sendCommandComplete(w, "ADD EDGE", 1);
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
                var guard = try EngineGuard.acquire(eng, io);
                defer guard.deinit();
                eng.beginStage(expected_length) catch {
                    try sendError(w, 2, "EV1001", "staging quota exceeded");
                    try w.flush();
                    continue;
                };
                guard.release();
                attachment = .{ .upload_id = upload_id, .expected_length = expected_length, .expected_digest = expected_digest, .staging_reserved = true };
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
                    // The reservation is shared engine state: releasing it runs
                    // under the statement lock so it cannot race another
                    // connection's staging accounting.
                    if (staged.staging_reserved) {
                        var guard = try EngineGuard.acquire(eng, io);
                        defer guard.deinit();
                        eng.abortStage(staged.expected_length);
                        guard.release();
                    }
                    staged.deinit(gpa);
                    attachment = null;
                    try sendError(w, 2, "EV1001", "attachment length or digest mismatch");
                    try w.flush();
                    continue;
                }
                var guard = try EngineGuard.acquire(eng, io);
                defer guard.deinit();
                eng.finishStage(staged.expected_length);
                guard.release();
                staged.finished = true;
                staged.staging_reserved = false;
            },
            .attachment_abort => {
                if (payload.len != 8 or attachment == null or std.mem.readInt(u64, payload[0..8], .big) != attachment.?.upload_id) {
                    try sendError(w, 2, "EV1001", "invalid attachment abort");
                    try w.flush();
                    continue;
                }
                const item = &attachment.?;
                var guard = try EngineGuard.acquire(eng, io);
                defer guard.deinit();
                if (item.staging_reserved) eng.abortStage(item.expected_length);
                guard.release();
                item.deinit(gpa);
                attachment = null;
            },
            .cancel_request => {
                // Fire-and-forget: no response frame is defined for a
                // well-formed request. Missing, mismatched, closed, or expired
                // credentials finish as a no-op; only the observability
                // counters change. A malformed payload is a protocol error:
                // the Server replies CN1001 and closes the Connection, so the
                // error can never be misattributed to a later pipelined frame.
                if (payload.len != proto.CANCEL_CREDENTIAL_LENGTH) {
                    try sendError(w, 2, "CN1001", "malformed cancel request payload");
                    try w.flush();
                    return;
                }
                var credential_bytes: [proto.CANCEL_CREDENTIAL_LENGTH]u8 = undefined;
                @memcpy(&credential_bytes, payload);
                _ = registry.cancelByCredential(credential_bytes) catch {};
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

fn sendHelloOk(w: anytype, credential: [proto.CANCEL_CREDENTIAL_LENGTH]u8) !void {
    const s = "RunaDB 0.0.1";
    const payload_len = try addPayloadLength(try stringPayloadLen(s), proto.CANCEL_CREDENTIAL_LENGTH);
    try sendFrameHeader(w, .hello_ok, payload_len);
    try sendString(w, s);
    // The cancellation credential follows the version string and is unique
    // within the Connection lifetime.
    try w.writeAll(&credential);
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
    var cells = [_]?[]const u8{value[0..]};
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
