//! RunaDB Client compatibility tests against the independently built server.
//! This module imports only the public client package and communicates over TCP.

const std = @import("std");
const Io = std.Io;
const clint = @import("clint");
const proto = clint.proto;

const server_port: u16 = 64334;
const data_dir = "zig-cache/runa-client-protocol-integration";

test "RunaDB Client v2 protocol lifecycle, evidence, and request errors" {
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
    try expectVersionRejection(gpa, io);
    try expectMalformedRequestsKeepConnectionUsable(gpa, io);
    try expectGoodbyeConfirmationAndClose(gpa, io);
}

fn expectEvidenceRoundTrip(gpa: std.mem.Allocator, io: Io) !void {
    var conn = try connectWhenReady(gpa, io);
    defer conn.deinit(io);
    const payload = "\x89PNG\r\nRunaDB evidence payload";
    var result = try conn.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "integration-camera", payload);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expect((try result.next(arena.allocator())).? == .row_description);
    const row = (try result.next(arena.allocator())).?;
    const evidence_id = switch (row) {
        .row_data => |data| try std.fmt.parseInt(u64, data.values[0], 10),
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect((try result.next(arena.allocator())).? == .command_complete);
    try std.testing.expect((try result.next(arena.allocator())) == null);

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

fn connectWhenReady(gpa: std.mem.Allocator, io: Io) !clint.Connection {
    var last_error: ?anyerror = null;
    for (0..100) |_| {
        if (clint.Connection.connect(gpa, io, "127.0.0.1", server_port)) |conn| {
            return conn;
        } else |err| {
            last_error = err;
            try Io.sleep(io, .fromMilliseconds(10), .awake);
        }
    }
    return last_error orelse error.ServerDidNotStart;
}

fn connectRaw(io: Io) !Io.net.Stream {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", server_port);
    return addr.connect(io, .{ .mode = .stream });
}

fn writeHello(writer: *Io.Writer, major: u16, minor: u16) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], major, .big);
    std.mem.writeInt(u16, payload[2..4], minor, .big);
    try clint.codec.writeMessage(writer, .hello, &payload);
    try writer.flush();
}

fn expectHelloOk(allocator: std.mem.Allocator, reader: *Io.Reader) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response = try clint.codec.readMessage(arena.allocator(), reader);
    try std.testing.expect(response == .hello_ok);
}

fn expectServerError(
    allocator: std.mem.Allocator,
    reader: *Io.Reader,
    expected_code: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response = try clint.codec.readMessage(arena.allocator(), reader);
    switch (response) {
        .server_error => |server_error| {
            try std.testing.expectEqual(@as(u8, 2), server_error.severity);
            try std.testing.expectEqualStrings(expected_code, server_error.code);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectVersionRejection(allocator: std.mem.Allocator, io: Io) !void {
    const stream = try connectRaw(io);
    defer stream.close(io);

    var read_buf: [1024]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    try writeHello(&writer.interface, proto.PROTOCOL_VERSION_MAJOR + 1, proto.PROTOCOL_VERSION_MINOR);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response = try clint.codec.readMessage(arena.allocator(), &reader.interface);
    switch (response) {
        .hello_error => |hello_error| {
            try std.testing.expectEqualStrings("unsupported protocol version", hello_error.reason);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectError(error.EndOfStream, clint.codec.readMessage(arena.allocator(), &reader.interface));
}

fn expectMalformedRequestsKeepConnectionUsable(allocator: std.mem.Allocator, io: Io) !void {
    const stream = try connectRaw(io);
    defer stream.close(io);

    var read_buf: [1024]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    try writeHello(&writer.interface, proto.PROTOCOL_VERSION_MAJOR, proto.PROTOCOL_VERSION_MINOR);
    try expectHelloOk(allocator, &reader.interface);

    // The source string declares one byte but provides none.
    const truncated_source = [_]u8{ 0, 0, 0, 1 };
    try clint.codec.writeMessage(&writer.interface, .flow_source, &truncated_source);
    try writer.interface.flush();
    try expectServerError(allocator, &reader.interface, "RF1000");

    var unsupported_ir_version: [2]u8 = undefined;
    std.mem.writeInt(u16, &unsupported_ir_version, proto.IR_FORMAT_VERSION + 1, .big);
    try clint.codec.writeMessage(&writer.interface, .flow_ir, &unsupported_ir_version);
    try writer.interface.flush();
    try expectServerError(allocator, &reader.interface, "RF1004");

    // The wrapper declares the supported IR format, but the canonical IR has
    // no projection fields. Direct IR input must obey the same static shape
    // constraints as Runa Flow source.
    const empty_projection_ir = [_]u8{
        0, 4, // wire IR format version
        0, 4, // canonical IR format version
        0, 0, 0, 0, 0, 0, 0, 0, // model revision
        1, // emit operation
        0, 8, 'c', 'u', 's', 't', 'o', 'm', 'e', 'r', // relation
        0, // where predicate count
        0, 0, // projection field count
        0, // no limit
    };
    try clint.codec.writeMessage(&writer.interface, .flow_ir, &empty_projection_ir);
    try writer.interface.flush();
    try expectServerError(allocator, &reader.interface, "RF1003");

    // A parse rejection also leaves the Connection usable.
    const invalid_source = "from customer\n| emit { }";
    var source_payload: [4 + invalid_source.len]u8 = undefined;
    std.mem.writeInt(u32, source_payload[0..4], invalid_source.len, .big);
    @memcpy(source_payload[4..], invalid_source);
    try clint.codec.writeMessage(&writer.interface, .flow_source, &source_payload);
    try writer.interface.flush();
    try expectServerError(allocator, &reader.interface, "RF1001");

    // A where predicate whose literal type does not match the column fails
    // semantic binding and keeps the Connection usable.
    const type_mismatch_source = "from observation_evidence\n| where evidence_id = 'nope'\n| emit { evidence_id }";
    var mismatch_payload: [4 + type_mismatch_source.len]u8 = undefined;
    std.mem.writeInt(u32, mismatch_payload[0..4], type_mismatch_source.len, .big);
    @memcpy(mismatch_payload[4..], type_mismatch_source);
    try clint.codec.writeMessage(&writer.interface, .flow_source, &mismatch_payload);
    try writer.interface.flush();
    try expectServerError(allocator, &reader.interface, "RF1002");

    // An unknown where column also fails semantic binding.
    const unknown_column_source = "from observation_evidence\n| where missing = 1\n| emit { evidence_id }";
    var unknown_payload: [4 + unknown_column_source.len]u8 = undefined;
    std.mem.writeInt(u32, unknown_payload[0..4], unknown_column_source.len, .big);
    @memcpy(unknown_payload[4..], unknown_column_source);
    try clint.codec.writeMessage(&writer.interface, .flow_source, &unknown_payload);
    try writer.interface.flush();
    try expectServerError(allocator, &reader.interface, "RF1002");

    // SQL text has no compatibility or translation path in the v2 endpoint.
    const sql_text = "SELECT 1";
    var sql_payload: [4 + sql_text.len]u8 = undefined;
    std.mem.writeInt(u32, sql_payload[0..4], sql_text.len, .big);
    @memcpy(sql_payload[4..], sql_text);
    try clint.codec.writeMessage(&writer.interface, .flow_source, &sql_payload);
    try writer.interface.flush();
    try expectServerError(allocator, &reader.interface, "RF1001");
}

fn expectGoodbyeConfirmationAndClose(allocator: std.mem.Allocator, io: Io) !void {
    const stream = try connectRaw(io);
    defer stream.close(io);

    var read_buf: [1024]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    try writeHello(&writer.interface, proto.PROTOCOL_VERSION_MAJOR, proto.PROTOCOL_VERSION_MINOR);
    try expectHelloOk(allocator, &reader.interface);

    try clint.codec.writeMessage(&writer.interface, .goodbye, "");
    try writer.interface.flush();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const response = try clint.codec.readMessage(arena.allocator(), &reader.interface);
    switch (response) {
        .goodbye => |goodbye| try std.testing.expectEqualStrings("ok", goodbye.reason),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.EndOfStream, clint.codec.readMessage(arena.allocator(), &reader.interface));
}
