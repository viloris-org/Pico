const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bytes = @import("../util/bytes.zig");
const exec = @import("../sql/exec.zig");
const engine_mod = @import("../storage/engine.zig");

/// PostgreSQL protocol version 3.0
pub const PROTOCOL_VERSION: i32 = 196608;
/// SSLRequest code
pub const SSL_REQUEST: i32 = 80877103;

pub const ConnError = error{
    Protocol,
    UnexpectedEof,
    MessageTooLarge,
} || Allocator.Error || Io.Cancelable || Io.UnexpectedError;

/// Handle one client connection until terminate or error.
pub fn handleConnection(
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    eng: *engine_mod.Engine,
) !void {
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    const r = &reader.interface;
    const w = &writer.interface;

    // Startup / optional SSLRequest
    while (true) {
        const len_buf = try r.takeArray(4);
        const msg_len = bytes.readI32BE(len_buf);
        if (msg_len < 4) return error.Protocol;
        const body_len: usize = @intCast(msg_len - 4);
        if (body_len > 1024 * 1024) return error.MessageTooLarge;
        const body = try r.take(body_len);

        if (msg_len == 8 and body_len == 4) {
            const code = bytes.readI32BE(body[0..4]);
            if (code == SSL_REQUEST) {
                try w.writeByte('N'); // no SSL
                try w.flush();
                continue;
            }
        }

        // StartupMessage
        if (body_len < 4) return error.Protocol;
        const version = bytes.readI32BE(body[0..4]);
        if (version != PROTOCOL_VERSION) return error.Protocol;
        // Ignore parameters for Phase 0 (user, database, ...)
        break;
    }

    // AuthenticationOk
    try sendAuthOk(w);
    // ParameterStatus (minimal)
    try sendParameterStatus(w, "server_version", "pico 0.0.1");
    try sendParameterStatus(w, "client_encoding", "UTF8");
    try sendParameterStatus(w, "server_encoding", "UTF8");
    try sendParameterStatus(w, "DateStyle", "ISO, MDY");
    try sendParameterStatus(w, "integer_datetimes", "on");
    // BackendKeyData
    try sendBackendKeyData(w, 1, 1);
    try sendReadyForQuery(w, 'I');
    try w.flush();

    // Simple query loop
    while (true) {
        const type_byte = r.takeByte() catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        const len_buf = try r.takeArray(4);
        const msg_len = bytes.readI32BE(len_buf);
        if (msg_len < 4) return error.Protocol;
        const body_len: usize = @intCast(msg_len - 4);
        if (body_len > 16 * 1024 * 1024) return error.MessageTooLarge;
        const body = if (body_len > 0) try r.take(body_len) else &[_]u8{};

        switch (type_byte) {
            'X' => return, // Terminate
            'Q' => {
                // Query: body is null-terminated SQL
                const sql = std.mem.sliceTo(body, 0);
                try handleQuery(gpa, eng, w, sql);
                try sendReadyForQuery(w, 'I');
                try w.flush();
            },
            'S' => {
                // Sync (extended protocol) — respond ReadyForQuery
                try sendReadyForQuery(w, 'I');
                try w.flush();
            },
            'H', 'C', 'B', 'E', 'D', 'P' => {
                // Extended protocol stubs — not supported yet
                try sendError(w, "0A000", "extended query protocol not supported in Phase 0");
                try sendReadyForQuery(w, 'I');
                try w.flush();
            },
            else => {
                try sendError(w, "08P01", "unsupported message type");
                try sendReadyForQuery(w, 'I');
                try w.flush();
            },
        }
    }
}

fn handleQuery(gpa: Allocator, eng: *engine_mod.Engine, w: *Io.Writer, sql: []const u8) !void {
    // psql may send multiple statements; Phase 0: execute first non-empty only, or split by ;
    // Actually simple: run whole string — our parser takes one statement.
    // Empty query
    const trimmed = std.mem.trim(u8, sql, " \t\r\n;");
    if (trimmed.len == 0) {
        try sendCommandComplete(w, "EMPTY");
        return;
    }

    var result = exec.execute(gpa, eng, sql) catch |err| {
        try sendError(w, "42000", execErrorMessage(err));
        return;
    };
    defer result.deinit();

    switch (result) {
        .empty => |tag| try sendCommandComplete(w, tag),
        .rows => |rows| {
            try sendRowDescription(w, rows.col_names);
            for (rows.cells) |row| {
                try sendDataRow(w, row);
            }
            var tag_buf: [64]u8 = undefined;
            const tag = try std.fmt.bufPrint(&tag_buf, "SELECT {d}", .{rows.cells.len});
            try sendCommandComplete(w, tag);
        },
    }
}

fn execErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.TableExists => "table already exists",
        error.TableNotFound => "table not found",
        error.DuplicatePrimaryKey => "duplicate primary key",
        error.MissingPrimaryKey => "primary key required",
        error.PrimaryKeyNotFound => "no row with that primary key",
        error.PrimaryKeyImmutable => "primary key cannot be changed",
        error.ColumnCountMismatch => "column count mismatch",
        error.TypeMismatch => "type mismatch",
        error.ColumnNotFound => "column not found",
        error.UnsupportedSyntax => "unsupported SQL syntax (Pico subset)",
        error.UnexpectedToken => "syntax error",
        error.NotImplemented => "feature not implemented",
        else => "query failed",
    };
}

fn sendAuthOk(w: *Io.Writer) !void {
    // 'R' + len 8 + auth 0
    try w.writeByte('R');
    var b: [8]u8 = undefined;
    bytes.writeI32BE(b[0..4], 8);
    bytes.writeI32BE(b[4..8], 0);
    try w.writeAll(&b);
}

fn sendParameterStatus(w: *Io.Writer, key: []const u8, val: []const u8) !void {
    // 'S' + int32 len + key\0 + val\0
    const len: i32 = @intCast(4 + key.len + 1 + val.len + 1);
    try w.writeByte('S');
    var lb: [4]u8 = undefined;
    bytes.writeI32BE(&lb, len);
    try w.writeAll(&lb);
    try w.writeAll(key);
    try w.writeByte(0);
    try w.writeAll(val);
    try w.writeByte(0);
}

fn sendBackendKeyData(w: *Io.Writer, pid: i32, key: i32) !void {
    try w.writeByte('K');
    var b: [12]u8 = undefined;
    bytes.writeI32BE(b[0..4], 12);
    bytes.writeI32BE(b[4..8], pid);
    bytes.writeI32BE(b[8..12], key);
    try w.writeAll(&b);
}

fn sendReadyForQuery(w: *Io.Writer, status: u8) !void {
    try w.writeByte('Z');
    var b: [5]u8 = undefined;
    bytes.writeI32BE(b[0..4], 5);
    b[4] = status;
    try w.writeAll(&b);
}

fn sendCommandComplete(w: *Io.Writer, tag: []const u8) !void {
    const len: i32 = @intCast(4 + tag.len + 1);
    try w.writeByte('C');
    var lb: [4]u8 = undefined;
    bytes.writeI32BE(&lb, len);
    try w.writeAll(&lb);
    try w.writeAll(tag);
    try w.writeByte(0);
}

fn sendError(w: *Io.Writer, code: []const u8, message: []const u8) !void {
    // 'E' + fields: S ERROR, C code, M message, \0
    // Each field: type byte + string + \0, terminated by \0
    const severity = "ERROR";
    const total: i32 = @intCast(4 + 1 + severity.len + 1 + 1 + code.len + 1 + 1 + message.len + 1 + 1);
    try w.writeByte('E');
    var lb: [4]u8 = undefined;
    bytes.writeI32BE(&lb, total);
    try w.writeAll(&lb);
    try w.writeByte('S');
    try w.writeAll(severity);
    try w.writeByte(0);
    try w.writeByte('C');
    try w.writeAll(code);
    try w.writeByte(0);
    try w.writeByte('M');
    try w.writeAll(message);
    try w.writeByte(0);
    try w.writeByte(0);
}

fn sendRowDescription(w: *Io.Writer, names: []const []const u8) !void {
    // 'T' + len + field count + fields
    // Each field: name\0 + tableoid i32 + attnum i16 + typeoid i32 + typlen i16 + typmod i32 + format i16
    var payload_len: usize = 2; // field count
    for (names) |n| {
        payload_len += n.len + 1 + 4 + 2 + 4 + 2 + 4 + 2;
    }
    const len: i32 = @intCast(4 + payload_len);
    try w.writeByte('T');
    var lb: [4]u8 = undefined;
    bytes.writeI32BE(&lb, len);
    try w.writeAll(&lb);
    var fc: [2]u8 = undefined;
    bytes.writeU16BE(&fc, @intCast(names.len));
    try w.writeAll(&fc);

    for (names) |n| {
        try w.writeAll(n);
        try w.writeByte(0);
        var field: [18]u8 = undefined;
        bytes.writeI32BE(field[0..4], 0); // table oid
        bytes.writeU16BE(field[4..6], 0); // attnum
        bytes.writeI32BE(field[6..10], 25); // TEXTOID
        bytes.writeU16BE(field[10..12], 0xffff); // typlen variable = -1 as u16
        bytes.writeI32BE(field[12..16], -1); // typmod
        bytes.writeU16BE(field[16..18], 0); // text format
        try w.writeAll(&field);
    }
}

fn sendDataRow(w: *Io.Writer, cells: []const ?[]const u8) !void {
    var payload_len: usize = 2;
    for (cells) |c| {
        payload_len += 4;
        if (c) |s| payload_len += s.len;
    }
    const len: i32 = @intCast(4 + payload_len);
    try w.writeByte('D');
    var lb: [4]u8 = undefined;
    bytes.writeI32BE(&lb, len);
    try w.writeAll(&lb);
    var fc: [2]u8 = undefined;
    bytes.writeU16BE(&fc, @intCast(cells.len));
    try w.writeAll(&fc);
    for (cells) |c| {
        if (c) |s| {
            var cl: [4]u8 = undefined;
            bytes.writeI32BE(&cl, @intCast(s.len));
            try w.writeAll(&cl);
            try w.writeAll(s);
        } else {
            var cl: [4]u8 = undefined;
            bytes.writeI32BE(&cl, -1);
            try w.writeAll(&cl);
        }
    }
}
