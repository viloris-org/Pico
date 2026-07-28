const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine_mod = @import("../storage/engine.zig");
const pg = @import("pg.zig");
const pico = @import("pico.zig");

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5433,
    pico_port: u16 = 5434,
    data_dir: []const u8 = "data",
    sync_wal: bool = true,
};

pub fn run(gpa: Allocator, io: Io, cfg: Config) !void {
    var eng = try engine_mod.Engine.open(gpa, io, cfg.data_dir, cfg.sync_wal);
    defer eng.deinit();

    // Start Pico protocol listener on a background thread if port is set.
    var pico_thread: ?std.Thread = null;
    if (cfg.pico_port > 0) {
        const pico_cfg = PicoListenerConfig{
            .gpa = gpa,
            .io = io,
            .host = cfg.host,
            .port = cfg.pico_port,
            .eng = &eng,
        };
        pico_thread = try std.Thread.spawn(.{}, runPicoListener, .{pico_cfg});
    }
    defer {
        if (pico_thread) |t| {
            t.detach();
        }
    }

    // PG protocol listener (main thread).
    const pg_addr = try Io.net.IpAddress.parse(cfg.host, cfg.port);
    var pg_server = try pg_addr.listen(io, .{
        .reuse_address = true,
    });
    defer pg_server.deinit(io);

    std.log.info("Pico PG protocol listening on {s}:{d}", .{ cfg.host, cfg.port });
    if (cfg.pico_port > 0) {
        std.log.info("Pico native protocol listening on {s}:{d}", .{ cfg.host, cfg.pico_port });
    }
    std.log.info("Data directory: {s}", .{cfg.data_dir});

    while (true) {
        const stream = pg_server.accept(io) catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        // Phase 0: sequential connections (single writer, simple).
        defer stream.close(io);
        pg.handleConnection(gpa, io, stream, &eng) catch |err| {
            std.log.warn("PG connection closed with error: {s}", .{@errorName(err)});
        };
    }
}

const PicoListenerConfig = struct {
    gpa: Allocator,
    io: Io,
    host: []const u8,
    port: u16,
    eng: *engine_mod.Engine,
};

fn runPicoListener(cfg: PicoListenerConfig) void {
    const gpa = cfg.gpa;
    const io = cfg.io;

    const addr = Io.net.IpAddress.parse(cfg.host, cfg.port) catch |err| {
        std.log.err("pico listener: parse address failed: {s}", .{@errorName(err)});
        return;
    };
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.log.err("pico listener: listen failed: {s}", .{@errorName(err)});
        return;
    };
    defer server.deinit(io);

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("pico listener: accept failed: {s}", .{@errorName(err)});
            continue;
        };
        defer stream.close(io);
        pico.handleConnection(gpa, io, stream, cfg.eng) catch |err| {
            std.log.warn("Pico connection closed with error: {s}", .{@errorName(err)});
        };
    }
}
