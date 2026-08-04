//! RunaDB Client compatibility tests against the independently built server.
//! This module imports only the public client package and communicates over
//! native TCP (the transport implemented in this checkout; ADR-0023 §2.2).

const std = @import("std");
const Io = std.Io;
const sdk = @import("sdk_zig");
const proto = sdk.proto;
const codec = sdk.codec;

const server_port: u16 = 64334;
const data_dir = "zig-cache/runa-client-protocol-integration";

test "RunaDB Client v3 protocol lifecycle, evidence, and request errors" {
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
        "--quic-port",
        "0",
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

    {
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

    try expectEvidenceRoundTrip(gpa, io);
    try expectDocumentRoundTrip(gpa, io);
    try expectGraphRoundTrip(gpa, io);
    try expectKvRoundTrip(gpa, io);
    try expectVersionRejection(gpa, io);
    try expectMalformedRequestsKeepConnectionUsable(gpa, io);
    try expectCancellationNoOps(gpa, io);
    try expectClientCancelIsNoop(gpa, io);
    try expectMidStatementCancel(gpa, io);
    try expectGoodbyeConfirmationAndClose(gpa, io);
}

/// Cancellation requests are fire-and-forget: an unknown, mismatched, closed,
/// or expired credential finishes as a protocol no-op and the sending
/// Connection stays usable. A malformed payload is a protocol error: the
/// Server replies with `CN1001` and closes the Connection.
fn expectCancellationNoOps(gpa: std.mem.Allocator, io: Io) !void {
    {
        // An unknown credential is a no-op: the Server never replies, and the
        // next Request still executes on the same Connection.
        const raw = try connectRaw(gpa, io);
        defer raw.deinit();
        const stream = raw.byteStream();
        try writeHello(stream, proto.PROTOCOL_VERSION_MAJOR, proto.PROTOCOL_VERSION_MINOR);
        try expectHelloOk(gpa, stream);

        const bogus_credential = [_]u8{0xAB} ** proto.CANCEL_CREDENTIAL_LENGTH;
        try codec.writeMessage(stream, .cancel_request, &bogus_credential);
        try stream.flush();
        const source = "from customer\n| emit { id }";
        var source_payload: [4 + source.len]u8 = undefined;
        std.mem.writeInt(u32, source_payload[0..4], source.len, .big);
        @memcpy(source_payload[4..], source);
        try codec.writeMessage(stream, .flow_source, &source_payload);
        try stream.flush();
        try expectServerError(gpa, stream, "RF1002");
    }

    // A malformed cancel payload is a protocol error: `CN1001` is sent, then
    // the Server closes the Connection. Each case needs a fresh connection
    // because the close is terminal.
    try expectMalformedCancelCloses(gpa, io, &.{0x01});
    const long_payload = [_]u8{0} ** (proto.CANCEL_CREDENTIAL_LENGTH + 1);
    try expectMalformedCancelCloses(gpa, io, &long_payload);
}

/// Send a malformed cancel_request on a fresh Connection: expect a `CN1001`
/// error reply followed by the Server closing the Connection.
fn expectMalformedCancelCloses(gpa: std.mem.Allocator, io: Io, payload: []const u8) !void {
    const raw = try connectRaw(gpa, io);
    defer raw.deinit();
    const stream = raw.byteStream();
    try writeHello(stream, proto.PROTOCOL_VERSION_MAJOR, proto.PROTOCOL_VERSION_MINOR);
    try expectHelloOk(gpa, stream);

    try codec.writeMessage(stream, .cancel_request, payload);
    try stream.flush();
    try expectServerError(gpa, stream, "CN1001");

    // The Server closes the Connection after the protocol error, so the next
    // read reports the close rather than a usable stream.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectError(error.EndOfStream, codec.readMessage(arena.allocator(), stream));
}

/// The official client receives its own cancellation credential in HELLO_OK.
/// Sending it while no statement is running must not abort the next statement:
/// the mark applies only to the statement in flight.
fn expectClientCancelIsNoop(gpa: std.mem.Allocator, io: Io) !void {
    var conn = try connectWhenReady(gpa, io);
    defer conn.deinit(io);

    try conn.cancel();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var result = try conn.executeFlow(arena.allocator(), "from customer\n| emit { id }");
    const failure = (try result.next(arena.allocator())).?;
    switch (failure) {
        .server_error => |server_error| try std.testing.expectEqualStrings("RF1002", server_error.code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try result.next(arena.allocator())) == null);
}

fn expectEvidenceRoundTrip(gpa: std.mem.Allocator, io: Io) !void {
    var conn = try connectWhenReady(gpa, io);
    defer conn.deinit(io);
    const payload = "\x89PNG\r\nRunaDB evidence payload";
    var result = try conn.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "integration-camera", payload);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // observe is a single-row statement: the row helper consumes the framing
    // (ROW_DESCRIPTION) and the terminal COMMAND_COMPLETE for us.
    const row = try result.expectOneRow(arena.allocator());
    const evidence_id = try row.uint(0);

    const recovered = try conn.readEvidencePayload(gpa, evidence_id);
    defer gpa.free(recovered);
    try std.testing.expectEqualStrings(payload, recovered);

    var second = try conn.observe("camera_2", .image, "image/png", "2026-07-31T12:01:00+08:00", "integration-camera", "second payload");
    try second.drain(arena.allocator());

    var metadata = try conn.executeFlow(arena.allocator(), "from observation_evidence\n| emit { object_id, modality, media_type, payload_length }\n| limit 1");
    try std.testing.expect((try metadata.next(arena.allocator())).? == .row_description);
    const metadata_row = (try metadata.next(arena.allocator())).?;
    switch (metadata_row) {
        .row_data => |data| {
            try std.testing.expectEqualStrings("camera_1", data.values[0]);
            try std.testing.expectEqualStrings("image", data.values[1]);
            try std.testing.expectEqualStrings("image/png", data.values[2]);
            try std.testing.expectEqual(payload.len, try std.fmt.parseInt(usize, data.values[3], 10));
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try metadata.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try metadata.next(arena.allocator())) == null);

    // where filters the evidence view by a typed field, then limit bounds rows.
    var filtered = try conn.executeFlow(arena.allocator(), "from observation_evidence\n| where object_id = 'camera_1'\n| emit { object_id, payload_length }\n| limit 2");
    try std.testing.expect((try filtered.next(arena.allocator())).? == .row_description);
    const filtered_row = (try filtered.next(arena.allocator())).?;
    switch (filtered_row) {
        .row_data => |data| {
            try std.testing.expectEqualStrings("camera_1", data.values[0]);
            try std.testing.expectEqual(payload.len, try std.fmt.parseInt(usize, data.values[1], 10));
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try filtered.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try filtered.next(arena.allocator())) == null);
}

/// Documents ingest through canonical IR (document_insert) and read back
/// through Flow source with dotted-path projection, predicates, and nulls.
fn expectDocumentRoundTrip(gpa: std.mem.Allocator, io: Io) !void {
    var conn = try connectWhenReady(gpa, io);
    defer conn.deinit(io);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const fields = [_]proto.DocumentField{
        .{ .path = "title", .value = .{ .text = "Dune" } },
        .{ .path = "author.name", .value = .{ .text = "Herbert" } },
        .{ .path = "pages", .value = .{ .int = 412 } },
    };
    var inserted = try conn.insertDocument("books", "1", &fields);
    const insert_row = try inserted.expectOneRow(arena.allocator());
    try std.testing.expectEqualStrings("1", insert_row.raw(0));

    var read = try conn.executeFlow(arena.allocator(), "from books\n| where author.name = 'Herbert'\n| emit { title, author.name, pages }\n| limit 5");
    try std.testing.expect((try read.next(arena.allocator())).? == .row_description);
    const read_row = (try read.next(arena.allocator())).?;
    switch (read_row) {
        .row_data => |data| {
            try std.testing.expectEqualStrings("Dune", data.values[0]);
            try std.testing.expectEqualStrings("Herbert", data.values[1]);
            try std.testing.expectEqualStrings("412", data.values[2]);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try read.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try read.next(arena.allocator())) == null);

    // A predicate on a path absent from every document matches nothing; the
    // absent path itself emits as null.
    var missing = try conn.executeFlow(arena.allocator(), "from books\n| where genre = 'scifi'\n| emit { title, genre }");
    try std.testing.expect((try missing.next(arena.allocator())).? == .row_description);
    try std.testing.expect((try missing.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try missing.next(arena.allocator())) == null);

    var null_emit = try conn.executeFlow(arena.allocator(), "from books\n| emit { title, genre }\n| limit 1");
    try std.testing.expect((try null_emit.next(arena.allocator())).? == .row_description);
    const null_row = (try null_emit.next(arena.allocator())).?;
    switch (null_row) {
        .row_data => |data| {
            try std.testing.expectEqualStrings("Dune", data.values[0]);
            try std.testing.expect(data.nulls[1]);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try null_emit.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try null_emit.next(arena.allocator())) == null);
}

/// Graphs ingest nodes and edges through canonical IR and traverse through the
/// `navigate` Flow stage over the wire.
fn expectGraphRoundTrip(gpa: std.mem.Allocator, io: Io) !void {
    var conn = try connectWhenReady(gpa, io);
    defer conn.deinit(io);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const ada = [_]proto.DocumentField{.{ .path = "name", .value = .{ .text = "Ada" } }};
    const grace = [_]proto.DocumentField{.{ .path = "name", .value = .{ .text = "Grace" } }};
    const lin = [_]proto.DocumentField{.{ .path = "name", .value = .{ .text = "Lin" } }};

    var node_a = try conn.addNode("social", "1", &ada);
    try node_a.drain(arena.allocator());
    var node_g = try conn.addNode("social", "2", &grace);
    try node_g.drain(arena.allocator());
    var node_l = try conn.addNode("social", "3", &lin);
    try node_l.drain(arena.allocator());

    var edge_a = try conn.addEdge("social", "1", "mentors", "2");
    try edge_a.drain(arena.allocator());
    var edge_b = try conn.addEdge("social", "1", "mentors", "3");
    try edge_b.drain(arena.allocator());

    var read = try conn.executeFlow(arena.allocator(), "from social\n| navigate mentors as mentee\n| emit { name, mentee.name }\n| limit 5");
    try std.testing.expect((try read.next(arena.allocator())).? == .row_description);
    const row1 = (try read.next(arena.allocator())).?;
    switch (row1) {
        .row_data => |data| {
            try std.testing.expectEqualStrings("Ada", data.values[0]);
            try std.testing.expectEqualStrings("Grace", data.values[1]);
        },
        else => return error.TestUnexpectedResult,
    }
    const row2 = (try read.next(arena.allocator())).?;
    switch (row2) {
        .row_data => |data| {
            try std.testing.expectEqualStrings("Ada", data.values[0]);
            try std.testing.expectEqualStrings("Lin", data.values[1]);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try read.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try read.next(arena.allocator())) == null);

    // Adding an edge to an unknown node is rejected by the Server.
    var bad = try conn.addEdge("social", "1", "mentors", "99");
    const bad_message = (try bad.next(arena.allocator())).?;
    switch (bad_message) {
        .server_error => |server_error| {
            try std.testing.expectEqualStrings("GF1002", server_error.code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try bad.next(arena.allocator())) == null);
}

/// KV collections ingest through canonical IR (`putKv`) and read through the
/// Flow `from`/`emit` stages over the wire (roadmap Phase 2 KV slice).
fn expectKvRoundTrip(gpa: std.mem.Allocator, io: Io) !void {
    var conn = try connectWhenReady(gpa, io);
    defer conn.deinit(io);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // putKv creates the collection on its first put (self-contained ingest).
    var put_theme = try conn.putKv("session", "theme", .{ .text = "dark" });
    const theme_row = try put_theme.expectOneRow(arena.allocator());
    try std.testing.expectEqualStrings("theme", theme_row.raw(0));
    try std.testing.expectEqualStrings("dark", theme_row.raw(1));

    var put_retries = try conn.putKv("session", "retries", .{ .int = 3 });
    try put_retries.drain(arena.allocator());

    // Upsert replaces the value of an existing key.
    var put_again = try conn.putKv("session", "retries", .{ .int = 9 });
    const retries_row = try put_again.expectOneRow(arena.allocator());
    try std.testing.expectEqualStrings("9", retries_row.raw(1));

    // Point read by key through Runa Flow.
    var read = try conn.executeFlow(arena.allocator(), "from session\n| where key = 'theme'\n| emit { key, value }\n| limit 5");
    try std.testing.expect((try read.next(arena.allocator())).? == .row_description);
    const read_row = (try read.next(arena.allocator())).?;
    switch (read_row) {
        .row_data => |data| {
            try std.testing.expectEqualStrings("theme", data.values[0]);
            try std.testing.expectEqualStrings("dark", data.values[1]);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try read.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try read.next(arena.allocator())) == null);

    // A predicate on the value filters typed scalars; an absent key matches
    // nothing.
    var filtered = try conn.executeFlow(arena.allocator(), "from session\n| where value = 9\n| emit { key }");
    try std.testing.expect((try filtered.next(arena.allocator())).? == .row_description);
    const filtered_row = (try filtered.next(arena.allocator())).?;
    switch (filtered_row) {
        .row_data => |data| try std.testing.expectEqualStrings("retries", data.values[0]),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try filtered.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try filtered.next(arena.allocator())) == null);

    var absent = try conn.executeFlow(arena.allocator(), "from session\n| where key = 'missing'\n| emit { key, value }");
    try std.testing.expect((try absent.next(arena.allocator())).? == .row_description);
    try std.testing.expect((try absent.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try absent.next(arena.allocator())) == null);

    // An empty key is a static shape violation: the canonical IR is rejected
    // at validation (RF1003) and the Connection stays usable.
    var bad = try conn.putKv("session", "", .{ .int = 1 });
    const bad_message = (try bad.next(arena.allocator())).?;
    switch (bad_message) {
        .server_error => |server_error| {
            try std.testing.expectEqualStrings("RF1003", server_error.code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try bad.next(arena.allocator())) == null);
}

fn connectWhenReady(gpa: std.mem.Allocator, io: Io) !sdk.Connection {
    var last_error: ?anyerror = null;
    for (0..100) |_| {
        if (sdk.Connection.connect(gpa, io, .{
            .host = "127.0.0.1",
            .port = server_port,
            .kind = .tcp,
        })) |conn| {
            return conn;
        } else |err| {
            last_error = err;
            try Io.sleep(io, .fromMilliseconds(10), .awake);
        }
    }
    return last_error orelse error.ServerDidNotStart;
}

/// A raw TCP connection used for protocol-level framing regressions.
fn connectRaw(gpa: std.mem.Allocator, io: Io) !*sdk.tcp_transport.TcpConn {
    return sdk.tcp_transport.TcpConn.connect(gpa, io, "127.0.0.1", server_port);
}

fn writeHello(stream: codec.Stream, major: u16, minor: u16) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], major, .big);
    std.mem.writeInt(u16, payload[2..4], minor, .big);
    try codec.writeMessage(stream, .hello, &payload);
    try stream.flush();
}

fn expectHelloOk(allocator: std.mem.Allocator, stream: codec.Stream) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response = try codec.readMessage(arena.allocator(), stream);
    try std.testing.expect(response == .hello_ok);
}

/// Read HELLO_OK and return the Connection's cancellation credential, which
/// names that Connection for the Server's cancellation routing.
fn expectHelloOkCredential(allocator: std.mem.Allocator, stream: codec.Stream) ![proto.CANCEL_CREDENTIAL_LENGTH]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response = try codec.readMessage(arena.allocator(), stream);
    switch (response) {
        .hello_ok => |ok| return ok.cancel_credential,
        else => return error.TestUnexpectedResult,
    }
}

fn expectServerError(
    allocator: std.mem.Allocator,
    stream: codec.Stream,
    expected_code: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response = try codec.readMessage(arena.allocator(), stream);
    switch (response) {
        .server_error => |server_error| {
            try std.testing.expectEqual(@as(u8, 2), server_error.severity);
            try std.testing.expectEqualStrings(expected_code, server_error.code);
        },
        else => return error.TestUnexpectedResult,
    }
}

/// Drain a canceled statement's result stream to its terminal outcome
/// (roadmap Phase 6 streaming): `ROW_DESCRIPTION`/`ROW_DATA` frames may
/// precede the `SERVER_ERROR` `RF1006`, which must arrive; a
/// `COMMAND_COMPLETE` (a full success) or any other frame fails the
/// expectation.
fn expectCanceledOutcomeAfterRows(allocator: std.mem.Allocator, stream: codec.Stream) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var iterations: usize = 0;
    while (true) : (iterations += 1) {
        if (iterations > 100_000) return error.TestTimeout;
        const msg = try codec.readMessage(arena.allocator(), stream);
        switch (msg) {
            .row_description, .row_data => continue,
            .server_error => |server_error| {
                try std.testing.expectEqual(@as(u8, 2), server_error.severity);
                try std.testing.expectEqualStrings("RF1006", server_error.code);
                return;
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

fn expectVersionRejection(allocator: std.mem.Allocator, io: Io) !void {
    const raw = try connectRaw(allocator, io);
    defer raw.deinit();
    const stream = raw.byteStream();

    try writeHello(stream, proto.PROTOCOL_VERSION_MAJOR + 1, proto.PROTOCOL_VERSION_MINOR);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response = try codec.readMessage(arena.allocator(), stream);
    switch (response) {
        .hello_error => |hello_error| {
            try std.testing.expectEqualStrings("unsupported protocol version", hello_error.reason);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectError(error.EndOfStream, codec.readMessage(arena.allocator(), stream));
}

fn expectMalformedRequestsKeepConnectionUsable(allocator: std.mem.Allocator, io: Io) !void {
    const raw = try connectRaw(allocator, io);
    defer raw.deinit();
    const stream = raw.byteStream();
    try writeHello(stream, proto.PROTOCOL_VERSION_MAJOR, proto.PROTOCOL_VERSION_MINOR);
    try expectHelloOk(allocator, stream);

    // The source string declares one byte but provides none.
    const truncated_source = [_]u8{ 0, 0, 0, 1 };
    try codec.writeMessage(stream, .flow_source, &truncated_source);
    try stream.flush();
    try expectServerError(allocator, stream, "RF1000");

    var unsupported_ir_version: [2]u8 = undefined;
    std.mem.writeInt(u16, &unsupported_ir_version, proto.IR_FORMAT_VERSION + 1, .big);
    try codec.writeMessage(stream, .flow_ir, &unsupported_ir_version);
    try stream.flush();
    try expectServerError(allocator, stream, "RF1004");

    // The wrapper declares the supported IR format, but the canonical IR has
    // no projection fields. Direct IR input must obey the same static shape
    // constraints as Runa Flow source.
    const empty_projection_ir = [_]u8{
        0, 6, // wire IR format version
        0, 6, // canonical IR format version
        0, 0, 0, 0, 0, 0, 0, 0, // model revision
        1, // emit operation
        0, 8, 'c', 'u', 's', 't', 'o', 'm', 'e', 'r', // relation
        0, // where predicate count
        0, 0, // projection field count
        0, // no limit
        0, // no navigate
    };
    try codec.writeMessage(stream, .flow_ir, &empty_projection_ir);
    try stream.flush();
    try expectServerError(allocator, stream, "RF1003");

    // A parse rejection also leaves the Connection usable.
    const invalid_source = "from customer\n| emit { }";
    var source_payload: [4 + invalid_source.len]u8 = undefined;
    std.mem.writeInt(u32, source_payload[0..4], invalid_source.len, .big);
    @memcpy(source_payload[4..], invalid_source);
    try codec.writeMessage(stream, .flow_source, &source_payload);
    try stream.flush();
    try expectServerError(allocator, stream, "RF1001");

    // A where predicate whose literal type does not match the column fails
    // semantic binding and keeps the Connection usable.
    const type_mismatch_source = "from observation_evidence\n| where evidence_id = 'nope'\n| emit { evidence_id }";
    var mismatch_payload: [4 + type_mismatch_source.len]u8 = undefined;
    std.mem.writeInt(u32, mismatch_payload[0..4], type_mismatch_source.len, .big);
    @memcpy(mismatch_payload[4..], type_mismatch_source);
    try codec.writeMessage(stream, .flow_source, &mismatch_payload);
    try stream.flush();
    try expectServerError(allocator, stream, "RF1002");

    // An unknown where column also fails semantic binding.
    const unknown_column_source = "from observation_evidence\n| where missing = 1\n| emit { evidence_id }";
    var unknown_payload: [4 + unknown_column_source.len]u8 = undefined;
    std.mem.writeInt(u32, unknown_payload[0..4], unknown_column_source.len, .big);
    @memcpy(unknown_payload[4..], unknown_column_source);
    try codec.writeMessage(stream, .flow_source, &unknown_payload);
    try stream.flush();
    try expectServerError(allocator, stream, "RF1002");

    // SQL text has no compatibility or translation path in the v3 endpoint.
    const sql_text = "SELECT 1";
    var sql_payload: [4 + sql_text.len]u8 = undefined;
    std.mem.writeInt(u32, sql_payload[0..4], sql_text.len, .big);
    @memcpy(sql_payload[4..], sql_text);
    try codec.writeMessage(stream, .flow_source, &sql_payload);
    try stream.flush();
    try expectServerError(allocator, stream, "RF1001");
}

fn expectGoodbyeConfirmationAndClose(allocator: std.mem.Allocator, io: Io) !void {
    const raw = try connectRaw(allocator, io);
    defer raw.deinit();
    const stream = raw.byteStream();
    try writeHello(stream, proto.PROTOCOL_VERSION_MAJOR, proto.PROTOCOL_VERSION_MINOR);
    try expectHelloOk(allocator, stream);

    try codec.writeMessage(stream, .goodbye, "");
    try stream.flush();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response = try codec.readMessage(arena.allocator(), stream);
    switch (response) {
        .goodbye => |goodbye| try std.testing.expectEqualStrings("ok", goodbye.reason),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.EndOfStream, codec.readMessage(arena.allocator(), stream));
}

/// Mid-statement cancellation against the real Server process (roadmap Phase 6):
/// a large `emit` scan on the target Connection is aborted by a
/// `CANCEL_REQUEST` carrying the target's credential, delivered fire-and-forget
/// on a second Connection. The statement ends with `SERVER_ERROR` `RF1006` (the
/// delivered `CANCELED` outcome) and the target Connection stays usable. The
/// collection is seeded through the official client; the cancel delivery uses
/// raw framing with the official client's codec, like the other cancellation
/// regressions, because the client API cancels only the sending Connection.
/// The seed is sized so the scan window is orders of magnitude longer than the
/// cancel delivery time, so the mark lands while the statement is scanning.
fn expectMidStatementCancel(gpa: std.mem.Allocator, io: Io) !void {
    const doc_count: usize = 20_000;

    // Seed a document collection through the official client so the target has
    // a long scan to abort. Each insert is committed and drained.
    {
        var seeder = try connectWhenReady(gpa, io);
        defer seeder.deinit(io);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();
        for (0..doc_count) |i| {
            const id_text = try std.fmt.allocPrint(aa, "d{d}", .{i});
            const fields = [_]proto.DocumentField{.{ .path = "seq", .value = .{ .int = @intCast(i) } }};
            var inserted = try seeder.insertDocument("docs", id_text, &fields);
            try inserted.drain(aa);
        }
    }

    // The canceler handshakes first so its cancel is ready the instant the
    // target's emit starts scanning.
    const canceler = try connectRaw(gpa, io);
    defer canceler.deinit();
    const cancel_stream = canceler.byteStream();
    try writeHello(cancel_stream, proto.PROTOCOL_VERSION_MAJOR, proto.PROTOCOL_VERSION_MINOR);
    try expectHelloOk(gpa, cancel_stream);

    const target = try connectRaw(gpa, io);
    defer target.deinit();
    const target_stream = target.byteStream();
    try writeHello(target_stream, proto.PROTOCOL_VERSION_MAJOR, proto.PROTOCOL_VERSION_MINOR);
    const target_credential = try expectHelloOkCredential(gpa, target_stream);

    // The target submits the large scan and does not read yet.
    const source = "from docs\n| emit { seq }";
    var source_payload: [4 + source.len]u8 = undefined;
    std.mem.writeInt(u32, source_payload[0..4], source.len, .big);
    @memcpy(source_payload[4..], source);
    try codec.writeMessage(target_stream, .flow_source, &source_payload);
    try target_stream.flush();

    // Deliver the cancel fire-and-forget; the Server never replies.
    try codec.writeMessage(cancel_stream, .cancel_request, &target_credential);
    try cancel_stream.flush();

    // The canceled statement delivers the CANCELED outcome. With streaming
    // (roadmap Phase 6), the mark lands while the server is scanning: if the
    // cancel was delivered before the first batch, no frame has been sent and
    // SERVER_ERROR RF1006 is the first frame; otherwise a bounded prefix of
    // rows is already in flight. Either way the statement ends with
    // SERVER_ERROR RF1006 — drain until it arrives (COMMAND_COMPLETE is never
    // sent for a canceled stream).
    try expectCanceledOutcomeAfterRows(gpa, target_stream);

    // The Connection stays usable: a follow-up statement returns a full result.
    const follow_up = "from docs\n| emit { seq }\n| limit 1";
    var follow_payload: [4 + follow_up.len]u8 = undefined;
    std.mem.writeInt(u32, follow_payload[0..4], follow_up.len, .big);
    @memcpy(follow_payload[4..], follow_up);
    try codec.writeMessage(target_stream, .flow_source, &follow_payload);
    try target_stream.flush();
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();
        var seen_row = false;
        while (true) {
            const msg = try codec.readMessage(aa, target_stream);
            switch (msg) {
                .row_description => {},
                .row_data => seen_row = true,
                .command_complete => break,
                else => return error.TestUnexpectedResult,
            }
        }
        if (!seen_row) return error.TestUnexpectedResult;
    }
}

// ── QUIC transport (ADR-0015, ADR-0023 §2) ─────────────────────────────────
//
// These tests run the SDK's public Connection API over the vendored zquic
// QUIC transport against the independently built server's QUIC listener
// (`--quic-port`, roadmap Phase 9). The server is spawned QUIC-only (TCP
// disabled) with a dedicated self-signed test certificate so the client can
// pin the exact expected identity (ADR-0023 §2.3): no pin exposes the
// presented leaf digest for trust-on-first-use, the correct pin succeeds,
// and a wrong pin fails with `CertificateMismatch` — never a silent TCP
// fallback.

const quic_port: u16 = 64335;
const quic_data_dir = "zig-cache/runa-client-quic-integration";
const quic_idle_port: u16 = 64336;
const quic_idle_data_dir = "zig-cache/runa-client-quic-idle";

const quic_test_cert = @embedFile("testdata/quic-test-cert.pem");
const quic_test_key = @embedFile("testdata/quic-test-key.pem");
const quic_other_cert = @embedFile("testdata/quic-test-cert-other.pem");

test "QUIC transport: certificate pinning regressions and round-trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server_path = std.mem.span(std.c.getenv("RUNA_TEST_SERVER") orelse return error.ServerPathMissing);

    Io.Dir.cwd().deleteTree(io, quic_data_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, quic_data_dir) catch {};

    const port_text = "64335";
    const child_args = [_][]const u8{
        server_path,
        "--quic-port",
        port_text,
        "--runa-port",
        "0",
        "--data-dir",
        quic_data_dir,
        "--cert",
        "sdk/zig/testdata/quic-test-cert.pem",
        "--key",
        "sdk/zig/testdata/quic-test-key.pem",
    };
    var child = try std.process.spawn(io, .{
        .argv = &child_args,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);

    // ── No pin: the connection proceeds and the presented leaf digest is
    // exposed for trust-on-first-use inspection; the digest must equal the
    // SHA-256 of the server's certificate DER.
    {
        var conn = try connectQuicWhenReady(gpa, io, quic_port, null);
        defer conn.deinit(io);
        try std.testing.expectEqualStrings("RunaDB 0.0.1", conn.server_version);
        const digest = conn.server_cert_digest orelse return error.TestUnexpectedResult;
        const expected = try sha256OfPem(gpa, quic_test_cert);
        try std.testing.expectEqualSlices(u8, &expected, &digest);

        // A request round-trip over a QUIC query stream through the public
        // API: unknown semantic name is rejected by the Server (RF1002).
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var result = try conn.executeFlow(arena.allocator(), "from customer\n| emit { id }");
        const failure = (try result.next(arena.allocator())).?;
        switch (failure) {
            .server_error => |server_error| {
                try std.testing.expectEqualStrings("RF1002", server_error.code);
            },
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expect((try result.next(arena.allocator())) == null);

        // A document insert + read-back round-trip proves query streams carry
        // request frames and result sequences over QUIC.
        const fields = [_]proto.DocumentField{
            .{ .path = "title", .value = .{ .text = "Foundation" } },
        };
        var inserted = try conn.insertDocument("qbooks", "1", &fields);
        const insert_row = try inserted.expectOneRow(arena.allocator());
        try std.testing.expectEqualStrings("1", insert_row.raw(0));
        var read = try conn.executeFlow(arena.allocator(), "from qbooks\n| emit { title }");
        try std.testing.expect((try read.next(arena.allocator())).? == .row_description);
        const row = (try read.next(arena.allocator())).?;
        switch (row) {
            .row_data => |data| try std.testing.expectEqualStrings("Foundation", data.values[0]),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expect((try read.next(arena.allocator())).? == .command_complete);
        try std.testing.expect((try read.next(arena.allocator())) == null);
    }

    // ── Correct pin: the presented leaf matches the pinned certificate. ──
    {
        var conn = try connectQuicWhenReady(gpa, io, quic_port, quic_test_cert);
        defer conn.deinit(io);
        try std.testing.expectEqualStrings("RunaDB 0.0.1", conn.server_version);
    }

    // ── Wrong pin: CertificateMismatch; no silent fallback. ──
    {
        const err = sdk.Connection.connect(gpa, io, .{
            .host = "127.0.0.1",
            .port = quic_port,
            .kind = .quic,
            .server_cert_pem = quic_other_cert,
            .connect_timeout_ms = 3000,
        }) catch |e| e;
        try std.testing.expectEqual(error.CertificateMismatch, err);
    }
}

test "QUIC transport: idle timeout against the SDK client" {
    // RFC 9000 §10.1: the server reaps a connection whose peer sends nothing
    // for the effective idle timeout (min of the listener's
    // --quic-idle-timeout-ms and the client's advertised max_idle_timeout).
    // The SDK pumps its QUIC event loop only during requests, so a silent
    // Connection is reaped; the next request then fails with a bounded,
    // defined error (Timeout after read_timeout_ms) instead of hanging.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server_path = std.mem.span(std.c.getenv("RUNA_TEST_SERVER") orelse return error.ServerPathMissing);

    Io.Dir.cwd().deleteTree(io, quic_idle_data_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, quic_idle_data_dir) catch {};

    const port_text = "64336";
    const child_args = [_][]const u8{
        server_path,
        "--quic-port",
        port_text,
        "--runa-port",
        "0",
        "--data-dir",
        quic_idle_data_dir,
        "--cert",
        "sdk/zig/testdata/quic-test-cert.pem",
        "--key",
        "sdk/zig/testdata/quic-test-key.pem",
        "--quic-idle-timeout-ms",
        "1200",
    };
    var child = try std.process.spawn(io, .{
        .argv = &child_args,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var conn = try connectQuicWhenReady(gpa, io, quic_idle_port, quic_test_cert);
    defer conn.deinit(io);
    try std.testing.expectEqualStrings("RunaDB 0.0.1", conn.server_version);

    // Go silent for longer than the server's 1200 ms idle timeout. The SDK
    // does not pump between requests, so no keepalive keeps the connection
    // alive; the server reaps it.
    try Io.sleep(io, .fromMilliseconds(2000), .awake);

    // The next request must fail with the SDK's bounded read timeout — a
    // defined error, never a silent hang or a stale success.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var result = try conn.executeFlow(arena.allocator(), "from customer\n| emit { id }");
    const read_err = result.next(arena.allocator()) catch |e| e;
    try std.testing.expectEqual(error.Timeout, read_err);
}

/// SHA-256 of the DER body of a PEM certificate (mirrors the SDK's pinned
/// digest computation, ADR-0023 §2.3).
fn sha256OfPem(gpa: std.mem.Allocator, pem: []const u8) ![32]u8 {
    const begin = "-----BEGIN CERTIFICATE-----";
    const end_m = "-----END CERTIFICATE-----";
    const bi = std.mem.indexOf(u8, pem, begin) orelse return error.NoCertificate;
    const after = bi + begin.len;
    const ei = std.mem.indexOf(u8, pem[after..], end_m) orelse return error.NoCertEnd;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (pem[after .. after + ei]) |c| {
        if (c != '\n' and c != '\r' and c != ' ') {
            try body.append(gpa, c);
        }
    }
    const decoder = std.base64.standard.Decoder;
    const der_len = try decoder.calcSizeForSlice(body.items);
    const der = try gpa.alloc(u8, der_len);
    defer gpa.free(der);
    try decoder.decode(der, body.items);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(der, &digest, .{});
    return digest;
}

/// Connect the SDK's QUIC transport to `port`, retrying while the server
/// process starts up. `pin` is the optional pinned certificate PEM.
fn connectQuicWhenReady(gpa: std.mem.Allocator, io: Io, port: u16, pin: ?[]const u8) !sdk.Connection {
    var last_error: ?anyerror = null;
    for (0..100) |_| {
        if (sdk.Connection.connect(gpa, io, .{
            .host = "127.0.0.1",
            .port = port,
            .kind = .quic,
            .server_cert_pem = pin,
            .connect_timeout_ms = 3000,
            .read_timeout_ms = 1500,
        })) |conn| {
            return conn;
        } else |err| {
            last_error = err;
            try Io.sleep(io, .fromMilliseconds(10), .awake);
        }
    }
    return last_error orelse error.ServerDidNotStart;
}
