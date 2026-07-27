const std = @import("std");
const Io = std.Io;
const pico = @import("pico");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const raw_args = try init.minimal.args.toSlice(arena);

    var cfg: pico.server.Config = .{};
    var i: usize = 1; // skip argv0
    while (i < raw_args.len) : (i += 1) {
        const a = raw_args[i];
        if (std.mem.eql(u8, a, "--port") and i + 1 < raw_args.len) {
            i += 1;
            cfg.port = try std.fmt.parseInt(u16, raw_args[i], 10);
        } else if (std.mem.eql(u8, a, "--data-dir") and i + 1 < raw_args.len) {
            i += 1;
            cfg.data_dir = raw_args[i];
        } else if (std.mem.eql(u8, a, "--host") and i + 1 < raw_args.len) {
            i += 1;
            cfg.host = raw_args[i];
        } else if (std.mem.eql(u8, a, "--no-sync")) {
            cfg.sync_wal = false;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try printUsage();
            return;
        } else {
            std.log.err("unknown argument: {s}", .{a});
            try printUsage();
            return error.BadArgs;
        }
    }

    try pico.server.run(gpa, io, cfg);
}

fn printUsage() !void {
    std.debug.print(
        \\Pico — lightweight networked OLTP database
        \\
        \\Usage: pico [options]
        \\
        \\Options:
        \\  --host <addr>       Listen address (default 127.0.0.1)
        \\  --port <port>       Listen port (default 5433)
        \\  --data-dir <path>   Data directory (default ./data)
        \\  --no-sync           Disable WAL fsync (dev only)
        \\  -h, --help          Show help
        \\
    , .{});
}
