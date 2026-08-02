//! RunaDB Connection — high-level SDK API over the transport abstraction.
//!
//! `Connection.connect` establishes the transport (QUIC by default per
//! ADR-0015/ADR-0023, TCP for the current checkout), negotiates the protocol
//! version with the `hello` exchange, and returns a Connection bound to the
//! server. Requests are submitted with `executeFlow` / `executeIr` and the
//! document, graph, and evidence helpers; each returns a `QueryResult`
//! iterator that must be consumed or drained before the next statement.
//!
//! Usage:
//! ```zig
//! var conn = try sdk.Connection.connect(gpa, io, .{
//!     .host = "127.0.0.1",
//!     .kind = .tcp,
//! });
//! defer conn.deinit(io);
//! var result = try conn.executeFlow(arena, "from customer\n| emit { id }");
//! while (try result.next(arena)) |msg| { ... }
//! ```

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proto = @import("clint_proto");
const codec = @import("codec.zig");
const transport = @import("transport.zig");
const tcp = @import("transport/tcp.zig");
const quic = @import("transport/quic.zig");

pub const Connection = struct {
    allocator: Allocator,
    io: Io,
    impl: Impl,
    server_version: []const u8,
    next_upload_id: u64 = 1,
    /// Unpredictable credential received in HELLO_OK; names this Connection for
    /// the Server's cancellation routing.
    cancel_credential: [proto.CANCEL_CREDENTIAL_LENGTH]u8 = .{0} ** proto.CANCEL_CREDENTIAL_LENGTH,
    /// A result sequence is in progress; the sequential statement contract
    /// rejects a new request until the current one is consumed or drained.
    in_flight: bool = false,

    const Impl = union(enum) {
        tcp: *tcp.TcpConn,
        quic: *quic.QuicConn,
    };

    pub fn connect(allocator: Allocator, io: Io, config: transport.Config) !Connection {
        var self: Connection = switch (config.kind) {
            .tcp => .{
                .allocator = allocator,
                .io = io,
                .impl = .{ .tcp = try tcp.TcpConn.connect(allocator, io, config.host, config.effectivePort()) },
                .server_version = "",
            },
            .quic => .{
                .allocator = allocator,
                .io = io,
                .impl = .{ .quic = try quic.QuicConn.connect(allocator, config) },
                .server_version = "",
            },
        };
        errdefer self.deinit(io);

        // Version negotiation: HELLO / HELLO_OK (or HELLO_ERROR) on the
        // control stream (TCP: the connection stream; QUIC: stream 0).
        const control = try self.controlStream();
        var payload_buf: [4]u8 = undefined;
        std.mem.writeInt(u16, payload_buf[0..2], proto.PROTOCOL_VERSION_MAJOR, .big);
        std.mem.writeInt(u16, payload_buf[2..4], proto.PROTOCOL_VERSION_MINOR, .big);
        try codec.writeMessage(control, .hello, &payload_buf);
        try control.flush();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const msg = try codec.readMessage(arena.allocator(), control);
        switch (msg) {
            .hello_ok => |ok| {
                self.server_version = try allocator.dupe(u8, ok.server_version);
                self.cancel_credential = ok.cancel_credential;
                return self;
            },
            .hello_error => return error.ServerRejected,
            else => return error.Protocol,
        }
    }

    /// The Connection's control stream: TCP connection stream, or the QUIC
    /// control stream (client bidi stream 0, lazily opened).
    fn controlStream(self: *Connection) !codec.Stream {
        return switch (self.impl) {
            .tcp => |t| t.byteStream(),
            .quic => |q| (try q.controlStream()).stream(),
        };
    }

    /// Open a request stream and mark the Connection in flight. The returned
    /// Request must be finished (or released on error) before the next
    /// statement.
    fn beginRequest(self: *Connection) !Request {
        if (self.in_flight) return error.StatementInProgress;
        self.in_flight = true;
        return switch (self.impl) {
            .tcp => |t| .{ .connection = self, .stream = t.byteStream(), .quic_stream = null },
            .quic => |q| blk: {
                const qs = try q.openStream();
                errdefer self.allocator.destroy(qs);
                break :blk .{ .connection = self, .stream = qs.stream(), .quic_stream = qs };
            },
        };
    }

    /// End a request: release the QUIC stream (if any) and clear `in_flight`.
    fn releaseRequest(self: *Connection, qs: ?*quic.QuicStream) void {
        if (qs) |stream| {
            stream.close();
            self.allocator.destroy(stream);
        }
        self.in_flight = false;
    }

    /// Submit Runa Flow source. Returns a result iterator.
    /// The caller must consume or drain the result before issuing another statement.
    pub fn executeFlow(self: *Connection, arena: Allocator, source: []const u8) !QueryResult {
        _ = arena;
        if (source.len > 64 * 1024) return error.MessageTooLarge;
        var req = try self.beginRequest();
        errdefer req.release();
        var payload_buf: [4 + 64 * 1024]u8 = undefined;
        std.mem.writeInt(u32, payload_buf[0..4], @intCast(source.len), .big);
        @memcpy(payload_buf[4..][0..source.len], source);
        try req.writeMessage(.flow_source, payload_buf[0 .. 4 + source.len]);
        try req.finish();
        return req.result();
    }

    /// Submit canonical Runa Query IR with its explicit format version.
    pub fn executeIr(self: *Connection, ir_format_version: u16, bytes: []const u8) !QueryResult {
        if (bytes.len > 64 * 1024) return error.MessageTooLarge;
        var req = try self.beginRequest();
        errdefer req.release();
        var payload_buf: [2 + 64 * 1024]u8 = undefined;
        std.mem.writeInt(u16, payload_buf[0..2], ir_format_version, .big);
        @memcpy(payload_buf[2..][0..bytes.len], bytes);
        try req.writeMessage(.flow_ir, payload_buf[0 .. 2 + bytes.len]);
        try req.finish();
        return req.result();
    }

    /// Stage and commit immutable Observation Evidence through canonical IR.
    pub fn observe(self: *Connection, object_id: []const u8, modality: proto.Modality, media_type: []const u8, observed_at: []const u8, origin: []const u8, payload: []const u8) !QueryResult {
        if (payload.len > proto.MAX_ATTACHMENT_LENGTH) return error.MessageTooLarge;
        var req = try self.beginRequest();
        errdefer req.release();
        const upload_id = self.next_upload_id;
        self.next_upload_id += 1;
        var payload_digest: [proto.PAYLOAD_DIGEST_LENGTH]u8 = undefined;
        std.crypto.hash.Blake3.hash(payload, &payload_digest, .{});

        var begin: [8 + 8 + proto.PAYLOAD_DIGEST_LENGTH]u8 = undefined;
        std.mem.writeInt(u64, begin[0..8], upload_id, .big);
        std.mem.writeInt(u64, begin[8..16], payload.len, .big);
        @memcpy(begin[16..], &payload_digest);
        try req.writeMessage(.attachment_begin, &begin);
        try req.flush();
        var offset: usize = 0;
        while (offset < payload.len) {
            const length = @min(proto.MAX_ATTACHMENT_CHUNK_LENGTH, payload.len - offset);
            var chunk: [8 + proto.MAX_ATTACHMENT_CHUNK_LENGTH]u8 = undefined;
            std.mem.writeInt(u64, chunk[0..8], upload_id, .big);
            @memcpy(chunk[8..][0..length], payload[offset .. offset + length]);
            try req.writeMessage(.attachment_chunk, chunk[0 .. 8 + length]);
            try req.flush();
            offset += length;
        }
        var finish: [8]u8 = undefined;
        std.mem.writeInt(u64, &finish, upload_id, .big);
        try req.writeMessage(.attachment_finish, &finish);

        const ir_bytes = try buildObserveIr(self.allocator, upload_id, object_id, modality, media_type, observed_at, origin);
        defer self.allocator.free(ir_bytes);
        var wrapped = try self.allocator.alloc(u8, 2 + ir_bytes.len);
        defer self.allocator.free(wrapped);
        std.mem.writeInt(u16, wrapped[0..2], proto.IR_FORMAT_VERSION, .big);
        @memcpy(wrapped[2..], ir_bytes);
        try req.writeMessage(.flow_ir, wrapped);
        try req.finish();
        return req.result();
    }

    /// Read and verify one committed evidence payload.
    pub fn readEvidencePayload(self: *Connection, gpa: Allocator, evidence_id: u64) ![]u8 {
        var req = try self.beginRequest();
        defer req.release();
        const ir_bytes = try buildReadPayloadIr(gpa, evidence_id);
        defer gpa.free(ir_bytes);
        var wrapped = try gpa.alloc(u8, 2 + ir_bytes.len);
        defer gpa.free(wrapped);
        std.mem.writeInt(u16, wrapped[0..2], proto.IR_FORMAT_VERSION, .big);
        @memcpy(wrapped[2..], ir_bytes);
        try req.writeMessage(.flow_ir, wrapped);
        try req.finish();

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const first = try codec.readMessage(arena.allocator(), req.stream);
        const begin = switch (first) {
            .payload_begin => |item| item,
            .server_error => return error.ServerRejected,
            else => return error.Protocol,
        };
        if (begin.evidence_id != evidence_id or begin.payload_length > proto.MAX_ATTACHMENT_LENGTH) return error.Protocol;
        const result = try gpa.alloc(u8, @intCast(begin.payload_length));
        errdefer gpa.free(result);
        var offset: usize = 0;
        while (true) {
            const message = try codec.readMessage(arena.allocator(), req.stream);
            switch (message) {
                .payload_chunk => |chunk| {
                    if (chunk.evidence_id != evidence_id or chunk.bytes.len > result.len - offset) return error.Protocol;
                    @memcpy(result[offset..][0..chunk.bytes.len], chunk.bytes);
                    offset += chunk.bytes.len;
                },
                .payload_finish => |finish| {
                    if (finish.evidence_id != evidence_id or offset != result.len) return error.Protocol;
                    var actual: [proto.PAYLOAD_DIGEST_LENGTH]u8 = undefined;
                    std.crypto.hash.Blake3.hash(result, &actual, .{});
                    if (!std.mem.eql(u8, &actual, begin.payload_digest)) return error.Protocol;
                    break;
                },
                else => return error.Protocol,
            }
        }
        const complete = try codec.readMessage(arena.allocator(), req.stream);
        if (complete != .command_complete) return error.Protocol;
        return result;
    }

    /// Ingest one document into a named document collection through canonical
    /// Runa Query IR. `fields` values are borrowed and must outlive the call.
    /// The Server rejects a duplicate document id; the result's single row
    /// carries the inserted id.
    pub fn insertDocument(self: *Connection, collection: []const u8, id: []const u8, fields: []const proto.DocumentField) !QueryResult {
        const ir_bytes = try buildInsertDocumentIr(self.allocator, collection, id, fields);
        defer self.allocator.free(ir_bytes);
        return sendFlowIr(self, ir_bytes);
    }

    /// Add one node to a graph, creating the graph on its first node. `fields`
    /// values are borrowed and must outlive the call.
    pub fn addNode(self: *Connection, graph: []const u8, id: []const u8, fields: []const proto.DocumentField) !QueryResult {
        const ir_bytes = try buildGraphAddNodeIr(self.allocator, graph, id, fields);
        defer self.allocator.free(ir_bytes);
        return sendFlowIr(self, ir_bytes);
    }

    /// Add one directed labeled edge between two existing nodes. The Server
    /// rejects an edge whose endpoints do not exist.
    pub fn addEdge(self: *Connection, graph: []const u8, from: []const u8, label: []const u8, to: []const u8) !QueryResult {
        const ir_bytes = try buildGraphAddEdgeIr(self.allocator, graph, from, label, to);
        defer self.allocator.free(ir_bytes);
        return sendFlowIr(self, ir_bytes);
    }

    /// Request cooperative cancellation of the statement currently executing
    /// on this Connection. Fire-and-forget: the Server never replies, and an
    /// unknown or already-revoked credential is a protocol no-op. A cancellation
    /// mark applies only to the statement in flight; it cannot roll back a
    /// committed transaction.
    pub fn cancel(self: *Connection) !void {
        const control = try self.controlStream();
        try codec.writeMessage(control, .cancel_request, &self.cancel_credential);
        try control.flush();
    }

    /// Send `goodbye` and close the transport. Resources are released by
    /// `deinit`.
    pub fn close(self: *Connection, io: Io) void {
        _ = io;
        const control = self.controlStream() catch return;
        codec.writeMessage(control, .goodbye, "") catch {};
        control.flush() catch {};
    }

    /// Close the Connection and release all client-owned resources.
    pub fn deinit(self: *Connection, io: Io) void {
        self.close(io);
        switch (self.impl) {
            .tcp => |t| t.deinit(),
            .quic => |q| {
                q.close("goodbye");
                q.deinit();
            },
        }
        self.allocator.free(self.server_version);
        self.server_version = "";
    }
};

/// An open request stream. Writes protocol messages, then `finish` flushes
/// them (and half-closes the QUIC send side). `release` ends the request.
const Request = struct {
    connection: *Connection,
    stream: codec.Stream,
    quic_stream: ?*quic.QuicStream = null,

    fn writeMessage(self: *Request, msg_type: proto.Type, payload: []const u8) !void {
        try codec.writeMessage(self.stream, msg_type, payload);
    }

    /// Flush buffered request bytes (keeps QUIC send buffers bounded for
    /// multi-message staging like attachment uploads).
    fn flush(self: *Request) !void {
        try self.stream.flush();
    }

    /// Flush and half-close the request stream's send side.
    fn finish(self: *Request) !void {
        try self.stream.flush();
        try self.stream.fin();
    }

    fn release(self: *Request) void {
        self.connection.releaseRequest(self.quic_stream);
    }

    fn result(self: *Request) QueryResult {
        return .{
            .allocator = self.connection.allocator,
            .stream = self.stream,
            .connection = self.connection,
            .quic_stream = self.quic_stream,
        };
    }
};

/// Wrap canonical IR bytes with the negotiated format version and send them as
/// a FLOW_IR request. The caller owns `ir_bytes` and frees it after this call.
fn sendFlowIr(self: *Connection, ir_bytes: []const u8) !QueryResult {
    var req = try self.beginRequest();
    errdefer req.release();
    var wrapped = try self.allocator.alloc(u8, 2 + ir_bytes.len);
    defer self.allocator.free(wrapped);
    std.mem.writeInt(u16, wrapped[0..2], proto.IR_FORMAT_VERSION, .big);
    @memcpy(wrapped[2..], ir_bytes);
    try req.writeMessage(.flow_ir, wrapped);
    try req.finish();
    return req.result();
}

fn buildObserveIr(gpa: Allocator, upload_id: u64, object_id: []const u8, modality: proto.Modality, media_type: []const u8, observed_at: []const u8, origin: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try appendInt(&output, gpa, u16, proto.IR_FORMAT_VERSION);
    try appendInt(&output, gpa, u64, 0);
    try output.append(gpa, 2);
    try appendInt(&output, gpa, u64, upload_id);
    try appendIrString(&output, gpa, object_id);
    try output.append(gpa, @intFromEnum(modality));
    try appendIrString(&output, gpa, media_type);
    try appendIrString(&output, gpa, observed_at);
    try appendIrString(&output, gpa, origin);
    return output.toOwnedSlice(gpa);
}

fn buildReadPayloadIr(gpa: Allocator, evidence_id: u64) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try appendInt(&output, gpa, u16, proto.IR_FORMAT_VERSION);
    try appendInt(&output, gpa, u64, 0);
    try output.append(gpa, 3);
    try appendInt(&output, gpa, u64, evidence_id);
    return output.toOwnedSlice(gpa);
}

fn buildInsertDocumentIr(gpa: Allocator, collection: []const u8, id: []const u8, fields: []const proto.DocumentField) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try appendInt(&output, gpa, u16, proto.IR_FORMAT_VERSION);
    try appendInt(&output, gpa, u64, 0);
    try output.append(gpa, 4); // document_insert operation
    try appendIrString(&output, gpa, collection);
    try appendIrString(&output, gpa, id);
    if (fields.len > std.math.maxInt(u16)) return error.StringTooLarge;
    try appendInt(&output, gpa, u16, @intCast(fields.len));
    for (fields) |field| {
        try appendIrString(&output, gpa, field.path);
        try appendIrValue(&output, gpa, field.value);
    }
    return output.toOwnedSlice(gpa);
}

fn buildGraphAddNodeIr(gpa: Allocator, graph: []const u8, id: []const u8, fields: []const proto.DocumentField) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try appendInt(&output, gpa, u16, proto.IR_FORMAT_VERSION);
    try appendInt(&output, gpa, u64, 0);
    try output.append(gpa, 5); // graph_add_node operation
    try appendIrString(&output, gpa, graph);
    try appendIrString(&output, gpa, id);
    if (fields.len > std.math.maxInt(u16)) return error.StringTooLarge;
    try appendInt(&output, gpa, u16, @intCast(fields.len));
    for (fields) |field| {
        try appendIrString(&output, gpa, field.path);
        try appendIrValue(&output, gpa, field.value);
    }
    return output.toOwnedSlice(gpa);
}

fn buildGraphAddEdgeIr(gpa: Allocator, graph: []const u8, from: []const u8, label: []const u8, to: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try appendInt(&output, gpa, u16, proto.IR_FORMAT_VERSION);
    try appendInt(&output, gpa, u64, 0);
    try output.append(gpa, 6); // graph_add_edge operation
    try appendIrString(&output, gpa, graph);
    try appendIrString(&output, gpa, from);
    try appendIrString(&output, gpa, label);
    try appendIrString(&output, gpa, to);
    return output.toOwnedSlice(gpa);
}

/// Canonical scalar encoding for document values, matching the Server's
/// `readIrValue` in src/flow/ir.zig. Vectors are not part of the document
/// slice, so there is no vector tag on the wire.
fn appendIrValue(output: *std.ArrayList(u8), gpa: Allocator, item: proto.DocumentValue) !void {
    switch (item) {
        .null => try output.append(gpa, 0),
        .int => |integer| {
            try output.append(gpa, 1);
            try appendInt(output, gpa, i64, integer);
        },
        .text => |text| {
            try output.append(gpa, 2);
            try appendIrString(output, gpa, text);
        },
        .bool => |boolean| {
            try output.append(gpa, 3);
            try output.append(gpa, if (boolean) 1 else 0);
        },
    }
}

fn appendInt(output: *std.ArrayList(u8), gpa: Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .big);
    try output.appendSlice(gpa, &buffer);
}

fn appendIrString(output: *std.ArrayList(u8), gpa: Allocator, value: []const u8) !void {
    if (value.len > std.math.maxInt(u16)) return error.StringTooLarge;
    try appendInt(output, gpa, u16, @intCast(value.len));
    try output.appendSlice(gpa, value);
}

/// Iterator over query result messages.
pub const QueryResult = struct {
    allocator: Allocator,
    stream: codec.Stream,
    /// The owning Connection, used to release the request stream. Null in
    /// tests that drive a standalone stream.
    connection: ?*Connection = null,
    quic_stream: ?*quic.QuicStream = null,
    done: bool = false,
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

        const msg = codec.readMessage(arena, self.stream) catch |err| {
            self.finish();
            return err;
        };
        switch (self.state) {
            .initial => switch (msg) {
                .row_description => {
                    self.state = .rows;
                    self.column_count = msg.row_description.column_count;
                    return msg;
                },
                .command_complete, .server_error, .goodbye => {
                    self.finish();
                    return msg;
                },
                else => {
                    self.finish();
                    return error.Protocol;
                },
            },
            .rows => switch (msg) {
                .row_data => {
                    if (msg.row_data.values.len != @as(usize, self.column_count.?)) {
                        self.finish();
                        return error.Protocol;
                    }
                    return msg;
                },
                // Streaming results (roadmap Phase 6): a statement canceled
                // mid-stream (or failing mid-stream) ends with SERVER_ERROR
                // after the rows already produced. It is the statement's
                // terminal message, exactly like SERVER_ERROR before any row
                // was sent.
                .server_error => {
                    self.finish();
                    return msg;
                },
                .command_complete, .goodbye => {
                    self.finish();
                    return msg;
                },
                else => {
                    self.finish();
                    return error.Protocol;
                },
            },
        }
    }

    /// Consume all remaining messages (drain).
    pub fn drain(self: *QueryResult, arena: Allocator) !void {
        while (try self.next(arena)) |_| {}
    }

    fn finish(self: *QueryResult) void {
        self.done = true;
        if (self.connection) |c| c.releaseRequest(self.quic_stream);
    }
};

test "query result rejects a response before its row description" {
    const bytes = [_]u8{
        0, 0, 0, 3, @intFromEnum(proto.Type.row_data), 0, 0,
    };
    var ts = codec.TestStream.init(&bytes, std.testing.allocator);
    defer ts.deinit();
    var result = QueryResult{
        .allocator = std.testing.allocator,
        .stream = ts.stream(),
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
    var ts = codec.TestStream.init(&bytes, std.testing.allocator);
    defer ts.deinit();
    var result = QueryResult{
        .allocator = std.testing.allocator,
        .stream = ts.stream(),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Protocol, result.next(arena.allocator()));
    try std.testing.expect((try result.next(arena.allocator())) == null);
}

test "query result accepts rows followed by command completion" {
    const bytes = [_]u8{
        0,                                         0, 0, 8, @intFromEnum(proto.Type.row_description), 0, 1, 0, 0, 0, 1, 'x',
        0,                                         0, 0, 4, @intFromEnum(proto.Type.row_data),        0, 1, 1, 0, 0, 0, 13,
        @intFromEnum(proto.Type.command_complete), 0, 0, 0, 0,                                        0, 0, 0, 1, 0, 0, 0,
        0,
    };
    var ts = codec.TestStream.init(&bytes, std.testing.allocator);
    defer ts.deinit();
    var result = QueryResult{
        .allocator = std.testing.allocator,
        .stream = ts.stream(),
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
        0, 0, 0, 8, @intFromEnum(proto.Type.row_description), 0, 1, 0, 0, 0, 1, 'x',
        0, 0, 0, 3, @intFromEnum(proto.Type.row_data),        0, 0,
    };
    var ts = codec.TestStream.init(&bytes, std.testing.allocator);
    defer ts.deinit();
    var result = QueryResult{
        .allocator = std.testing.allocator,
        .stream = ts.stream(),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expect((try result.next(arena.allocator())).? == .row_description);
    try std.testing.expectError(error.Protocol, result.next(arena.allocator()));
    try std.testing.expect((try result.next(arena.allocator())) == null);
}
