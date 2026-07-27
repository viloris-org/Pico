const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine_mod = @import("../storage/engine.zig");
const pg = @import("pg.zig");

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5433,
    data_dir: []const u8 = "data",
    sync_wal: bool = true,
};

pub fn run(gpa: Allocator, io: Io, cfg: Config) !void {
    var eng = try engine_mod.Engine.open(gpa, io, cfg.data_dir, cfg.sync_wal);
    defer eng.deinit();

    const addr = try Io.net.IpAddress.parse(cfg.host, cfg.port);
    var server = try addr.listen(io, .{
        .reuse_address = true,
    });
    defer server.deinit(io);

    std.log.info("Pico listening on {s}:{d} (data_dir={s})", .{ cfg.host, cfg.port, cfg.data_dir });

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        // Phase 0: sequential connections (single writer, simple).
        defer stream.close(io);
        pg.handleConnection(gpa, io, stream, &eng) catch |err| {
            std.log.warn("connection closed with error: {s}", .{@errorName(err)});
        };
    }
}
