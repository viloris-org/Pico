//! Native MCP stdio adapter for the read-only Runa Flow development slice.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flow = @import("../flow/exec.zig");
const engine_mod = @import("../storage/engine.zig");

pub const protocol_version = "2025-11-25";
pub const MAX_MESSAGE_BYTES: usize = 256 * 1024;
pub const MAX_ROWS: usize = 1_000;
pub const MAX_CELL_BYTES: usize = 64 * 1024;
pub const MAX_RESULT_BYTES: usize = 1024 * 1024;

const Phase = enum { awaiting_initialize, awaiting_initialized, ready };

pub const Server = struct {
    gpa: Allocator,
    eng: *engine_mod.Engine,
    phase: Phase = .awaiting_initialize,

    pub fn init(gpa: Allocator, eng: *engine_mod.Engine) Server {
        return .{ .gpa = gpa, .eng = eng };
    }

    /// Handles one newline-delimited JSON-RPC message. Returns true when a
    /// response was written; notifications intentionally have no response.
    pub fn handleLine(self: *Server, line: []const u8, w: *Io.Writer) !bool {
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, line, .{
            .max_value_len = MAX_MESSAGE_BYTES,
        }) catch {
            try writeError(w, null, -32700, "parse error");
            return true;
        };
        defer parsed.deinit();

        const request = switch (parsed.value) {
            .object => |object| object,
            else => {
                try writeError(w, null, -32600, "request must be an object");
                return true;
            },
        };
        const id = request.getPtr("id");
        const method = stringValue(request.get("method")) orelse {
            if (id) |request_id| try writeError(w, request_id, -32600, "method must be a string");
            return id != null;
        };
        if (!std.mem.eql(u8, stringValue(request.get("jsonrpc")) orelse "", "2.0")) {
            if (id) |request_id| try writeError(w, request_id, -32600, "jsonrpc must be 2.0");
            return id != null;
        }

        if (std.mem.eql(u8, method, "notifications/initialized")) {
            if (self.phase == .awaiting_initialized) self.phase = .ready;
            return false;
        }
        const request_id = id orelse return false;

        if (std.mem.eql(u8, method, "initialize")) {
            if (self.phase != .awaiting_initialize) {
                try writeError(w, request_id, -32600, "initialize is only valid once");
            } else {
                self.phase = .awaiting_initialized;
                try writeInitialize(w, request_id);
            }
            return true;
        }
        if (std.mem.eql(u8, method, "ping")) {
            try writeEmptyResult(w, request_id);
            return true;
        }
        if (self.phase != .ready) {
            try writeError(w, request_id, -32002, "MCP client has not completed initialization");
            return true;
        }
        if (std.mem.eql(u8, method, "tools/list")) {
            try writeToolsList(w, request_id);
            return true;
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            try self.handleToolCall(request.get("params"), request_id, w);
            return true;
        }
        try writeError(w, request_id, -32601, "method not found");
        return true;
    }

    fn handleToolCall(self: *Server, params_value: ?std.json.Value, id: *const std.json.Value, w: *Io.Writer) !void {
        const params = objectValue(params_value) orelse {
            try writeToolError(w, id, "tools/call requires an object params value");
            return;
        };
        const name = stringValue(params.get("name")) orelse {
            try writeToolError(w, id, "tools/call requires a tool name");
            return;
        };
        if (!std.mem.eql(u8, name, "runadb_flow_emit")) {
            try writeToolError(w, id, "unknown RunaDB MCP tool");
            return;
        }
        const arguments = objectValue(params.get("arguments")) orelse {
            try writeToolError(w, id, "runadb_flow_emit requires an arguments object");
            return;
        };
        const source = stringValue(arguments.get("source")) orelse {
            try writeToolError(w, id, "runadb_flow_emit requires a source string");
            return;
        };
        if (source.len > MAX_MESSAGE_BYTES) {
            try writeToolError(w, id, "Runa Flow source exceeds the MCP message limit");
            return;
        }
        var request = flow.compile(self.gpa, source) catch |err| {
            try writeToolError(w, id, @errorName(err));
            return;
        };
        defer request.deinit(self.gpa);
        var result = flow.execute(self.gpa, self.eng, &request) catch |err| {
            try writeToolError(w, id, @errorName(err));
            return;
        };
        defer result.deinit();
        try writeFlowResult(w, id, &result);
    }
};

pub fn runStdio(gpa: Allocator, io: Io, eng: *engine_mod.Engine) !void {
    var input_buffer: [MAX_MESSAGE_BYTES]u8 = undefined;
    var output_buffer: [16 * 1024]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &input_buffer);
    var writer = Io.File.stdout().writer(io, &output_buffer);
    var server = Server.init(gpa, eng);
    while (try reader.interface.takeDelimiter('\n')) |line| {
        _ = server.handleLine(line, &writer.interface) catch |err| {
            std.log.warn("MCP request failed: {s}", .{@errorName(err)});
            try writeError(&writer.interface, null, -32603, "internal error");
        };
        try writer.interface.flush();
    }
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    return if (value) |item| switch (item) {
        .string => |text| text,
        else => null,
    } else null;
}

fn objectValue(value: ?std.json.Value) ?std.json.ObjectMap {
    return if (value) |item| switch (item) {
        .object => |object| object,
        else => null,
    } else null;
}

fn beginResponse(json: *std.json.Stringify, id: *const std.json.Value) !void {
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("id");
    try json.write(id.*);
}

fn endResponse(json: *std.json.Stringify) !void {
    try json.endObject();
    try json.writer.writeByte('\n');
}

fn writeError(w: *Io.Writer, id: ?*const std.json.Value, code: i32, message: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = w };
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("id");
    if (id) |request_id| try json.write(request_id.*) else try json.write(null);
    try json.objectField("error");
    try json.beginObject();
    try json.objectField("code");
    try json.write(code);
    try json.objectField("message");
    try json.write(message);
    try json.endObject();
    try endResponse(&json);
}

fn writeInitialize(w: *Io.Writer, id: *const std.json.Value) !void {
    var json: std.json.Stringify = .{ .writer = w };
    try beginResponse(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("protocolVersion");
    try json.write(protocol_version);
    try json.objectField("capabilities");
    try json.beginObject();
    try json.objectField("tools");
    try json.beginObject();
    try json.endObject();
    try json.endObject();
    try json.objectField("serverInfo");
    try json.beginObject();
    try json.objectField("name");
    try json.write("runadb");
    try json.objectField("version");
    try json.write("0.0.1");
    try json.endObject();
    try json.endObject();
    try endResponse(&json);
}

fn writeEmptyResult(w: *Io.Writer, id: *const std.json.Value) !void {
    var json: std.json.Stringify = .{ .writer = w };
    try beginResponse(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.endObject();
    try endResponse(&json);
}

fn writeToolsList(w: *Io.Writer, id: *const std.json.Value) !void {
    var json: std.json.Stringify = .{ .writer = w };
    try beginResponse(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("tools");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("name");
    try json.write("runadb_flow_emit");
    try json.objectField("description");
    try json.write("Run the implemented read-only Runa Flow emit pipeline.");
    try json.objectField("inputSchema");
    try json.beginObject();
    try json.objectField("type");
    try json.write("object");
    try json.objectField("properties");
    try json.beginObject();
    try json.objectField("source");
    try json.beginObject();
    try json.objectField("type");
    try json.write("string");
    try json.endObject();
    try json.endObject();
    try json.objectField("required");
    try json.beginArray();
    try json.write("source");
    try json.endArray();
    try json.objectField("additionalProperties");
    try json.write(false);
    try json.endObject();
    try json.endObject();
    try json.endArray();
    try json.endObject();
    try endResponse(&json);
}

fn writeToolError(w: *Io.Writer, id: *const std.json.Value, message: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = w };
    try beginResponse(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write("text");
    try json.objectField("text");
    try json.write(message);
    try json.endObject();
    try json.endArray();
    try json.objectField("isError");
    try json.write(true);
    try json.endObject();
    try endResponse(&json);
}

fn writeFlowResult(w: *Io.Writer, id: *const std.json.Value, result: *const flow.Result) !void {
    if (result.cells.len > MAX_ROWS) return writeToolError(w, id, "Runa Flow result exceeds the MCP row limit");
    var measured: usize = 128;
    for (result.columns) |column| measured = try checkedAdd(measured, jsonStringUpperBound(column.len));
    for (result.cells) |row| for (row) |cell| if (cell) |text| {
        if (text.len > MAX_CELL_BYTES) return writeToolError(w, id, "Runa Flow result contains an oversized cell");
        measured = try checkedAdd(measured, jsonStringUpperBound(text.len));
    };
    if (measured > MAX_RESULT_BYTES) return writeToolError(w, id, "Runa Flow result exceeds the MCP response limit");

    var json: std.json.Stringify = .{ .writer = w };
    try beginResponse(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write("text");
    try json.objectField("text");
    try json.write("Runa Flow emit completed.");
    try json.endObject();
    try json.endArray();
    try json.objectField("structuredContent");
    try json.beginObject();
    try json.objectField("columns");
    try json.beginArray();
    for (result.columns) |column| try json.write(column);
    try json.endArray();
    try json.objectField("rows");
    try json.beginArray();
    for (result.cells) |row| {
        try json.beginArray();
        for (row) |cell| if (cell) |text| try json.write(text) else try json.write(null);
        try json.endArray();
    }
    try json.endArray();
    try json.endObject();
    try json.endObject();
    try endResponse(&json);
}

fn checkedAdd(left: usize, right: usize) !usize {
    return std.math.add(usize, left, right) catch error.ResultTooLarge;
}

fn jsonStringUpperBound(length: usize) usize {
    return std.math.mul(usize, length, 6) catch std.math.maxInt(usize);
}

test "MCP lifecycle gates tools and advertises the read-only tool" {
    var eng = try engine_mod.Engine.open(std.testing.allocator, std.testing.io, "zig-cache/runadb-mcp-lifecycle", true);
    defer eng.deinit();
    defer Io.Dir.cwd().deleteTree(std.testing.io, "zig-cache/runadb-mcp-lifecycle") catch {};
    var server = Server.init(std.testing.allocator, &eng);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expect(try server.handleLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "not completed initialization") != null);
    out.clearRetainingCapacity();
    try std.testing.expect(try server.handleLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}", &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), protocol_version) != null);
    out.clearRetainingCapacity();
    try std.testing.expect(!(try server.handleLine("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", &out.writer)));
    try std.testing.expect(try server.handleLine("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}", &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "runadb_flow_emit") != null);
}

test "MCP flow tool returns structured read results and rejects malformed requests" {
    const gpa = std.testing.allocator;
    const dir_name = "zig-cache/runadb-mcp-tool";
    Io.Dir.cwd().deleteTree(std.testing.io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(std.testing.io, dir_name) catch {};
    var eng = try engine_mod.Engine.open(gpa, std.testing.io, dir_name, true);
    defer eng.deinit();
    var columns = [_]@import("../storage/value.zig").Column{
        .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text },
    };
    defer for (&columns) |*column| column.deinit(gpa);
    try eng.createTable("users", &columns);
    var name: @import("../storage/value.zig").Value = .{ .text = try gpa.dupe(u8, "Ada") };
    defer name.deinit(gpa);
    try eng.insert("users", &.{ .{ .int = 1 }, name });

    var server = Server.init(gpa, &eng);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", &out.writer);
    out.clearRetainingCapacity();
    _ = try server.handleLine("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", &out.writer);
    _ = try server.handleLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"runadb_flow_emit\",\"arguments\":{\"source\":\"from users\\n| emit { id, name }\"}}}", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "structuredContent") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Ada") != null);
    out.clearRetainingCapacity();
    _ = try server.handleLine("not json", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "parse error") != null);
}
