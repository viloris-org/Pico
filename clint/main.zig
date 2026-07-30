//! Pico CLI — interactive REPL for Pico Server.
//!
//! Usage:
//!   pico-cli [--host <addr>] [--port <port>]

const std = @import("std");
const Io = std.Io;
const clint = @import("clint");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena_alloc = init.arena.allocator();

    // Parse args
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 5434;

    const raw_args = try init.minimal.args.toSlice(arena_alloc);
    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const a = raw_args[i];
        if (std.mem.eql(u8, a, "--host") and i + 1 < raw_args.len) {
            i += 1;
            host = raw_args[i];
        } else if (std.mem.eql(u8, a, "--port") and i + 1 < raw_args.len) {
            i += 1;
            port = try std.fmt.parseInt(u16, raw_args[i], 10);
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try printUsage();
            return;
        } else {
            std.log.err("unknown argument: {s}", .{a});
            try printUsage();
            return error.BadArgs;
        }
    }

    // Connect
    std.log.info("connecting to Pico at {s}:{d}...", .{ host, port });
    var conn = clint.Connection.connect(gpa, io, host, port) catch |err| {
        std.log.err("connection failed: {s}", .{@errorName(err)});
        return err;
    };
    defer conn.deinit(io);

    // Stdout writer
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    try w.print("Connected to Pico (server version: {s})\n", .{conn.server_version});
    try w.print("Type SQL statements, or \\q to quit.\n\n", .{});
    try w.flush();

    // Read all stdin via syscall
    var all_input = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer all_input.deinit(gpa);
    {
        var chunk_buf: [4096]u8 = undefined;
        while (true) {
            const n = readStdinBlocking(&chunk_buf);
            if (n == 0) break;
            try all_input.appendSlice(gpa, chunk_buf[0..n]);
        }
    }

    // Split input into lines and process each
    var line_start: usize = 0;
    while (line_start < all_input.items.len) {
        // Find end of line
        var line_end = line_start;
        while (line_end < all_input.items.len and all_input.items[line_end] != '\n') : (line_end += 1) {}
        const raw_line = all_input.items[line_start..line_end];
        line_start = line_end + 1; // skip newline

        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "\\q") or std.mem.eql(u8, line, "\\quit")) break;
        if (std.mem.eql(u8, line, "\\h") or std.mem.eql(u8, line, "\\help")) {
            try w.print("\\q, \\quit  quit\n\\h, \\help  show this help\n", .{});
            try w.flush();
            continue;
        }

        // Execute SQL
        var stmt_arena = std.heap.ArenaAllocator.init(gpa);
        defer stmt_arena.deinit();
        const stmt_alloc = stmt_arena.allocator();

        var result = conn.execute(stmt_alloc, line) catch |err| {
            try w.print("ERROR: {s}\n", .{@errorName(err)});
            try w.flush();
            continue;
        };

        var row_count: usize = 0;
        while (try result.next(stmt_alloc)) |msg| {
            switch (msg) {
                .row_description => |rd| {
                    for (rd.columns, 0..) |col, j| {
                        if (j > 0) try w.print(" | ", .{});
                        try w.print("{s}", .{col});
                    }
                    try w.print("\n", .{});
                    for (0..rd.columns.len) |j| {
                        if (j > 0) try w.print("-+-", .{});
                        for (0..rd.columns[j].len) |_| try w.print("-", .{});
                    }
                    try w.print("\n", .{});
                },
                .row_data => |rd| {
                    for (rd.values, 0..) |val, j| {
                        if (j > 0) try w.print(" | ", .{});
                        if (rd.nulls[j]) {
                            try w.print("NULL", .{});
                        } else {
                            try w.print("{s}", .{val});
                        }
                    }
                    try w.print("\n", .{});
                    row_count += 1;
                },
                .command_complete => |cc| {
                    try w.print("{s} ({d} rows)\n", .{ cc.tag, row_count });
                },
                .server_error => |e| {
                    try w.print("ERROR [{s}]: {s}\n", .{ e.code, e.message });
                },
                .goodbye => {
                    try w.print("Connection closed by server.\n", .{});
                    return;
                },
                else => {},
            }
        }
        try w.print("\n", .{});
        try w.flush();
    }
}

/// Read from stdin. Returns 0 on EOF.
fn readStdinBlocking(buf: []u8) usize {
    const rc = std.os.linux.read(0, @as([*]u8, buf.ptr), buf.len);
    // Linux read returns -errno as a huge usize on error; treat as 0
    if (rc >> 63 != 0) return 0;
    return rc;
}

fn printUsage() !void {
    std.debug.print(
        \\Pico CLI — interactive REPL for Pico Server
        \\
        \\Usage: pico-cli [options]
        \\
        \\Options:
        \\  --host <addr>    Server address (default 127.0.0.1)
        \\  --port <port>    Server port (default 5434)
        \\  -h, --help       Show help
        \\
        \\Meta commands (inside REPL):
        \\  \q, \quit        Quit
        \\  \h, \help        Show help
        \\
    , .{});
}
