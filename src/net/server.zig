const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine_mod = @import("../storage/engine.zig");
const mcp = @import("mcp.zig");
const runadb = @import("runadb.zig");

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    runa_port: u16 = 5434,
    data_dir: []const u8 = "data",
    sync_wal: bool = true,
    mcp_stdio: bool = false,
};

pub fn run(gpa: Allocator, io: Io, cfg: Config) !void {
    var eng = try engine_mod.Engine.open(gpa, io, cfg.data_dir, cfg.sync_wal);
    defer eng.deinit();

    if (cfg.mcp_stdio) {
        std.log.info("RunaDB MCP stdio adapter listening", .{});
        return mcp.runStdio(gpa, io, &eng);
    }
    if (cfg.runa_port == 0) return error.NoListener;
    std.log.info("RunaDB Wire Protocol v2 listening on {s}:{d}", .{ cfg.host, cfg.runa_port });
    std.log.info("Data directory: {s}", .{cfg.data_dir});
    try runRunaListener(.{
        .gpa = gpa,
        .io = io,
        .host = cfg.host,
        .port = cfg.runa_port,
        .eng = &eng,
    });
}

const RunaListenerConfig = struct {
    gpa: Allocator,
    io: Io,
    host: []const u8,
    port: u16,
    eng: *engine_mod.Engine,
};

fn runRunaListener(cfg: RunaListenerConfig) !void {
    const gpa = cfg.gpa;
    const io = cfg.io;

    const addr = try Io.net.IpAddress.parse(cfg.host, cfg.port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("runa listener: accept failed: {s}", .{@errorName(err)});
            continue;
        };
        defer stream.close(io);
        runadb.handleConnection(gpa, io, stream, cfg.eng) catch |err| {
            std.log.warn("RunaDB connection closed with error: {s}", .{@errorName(err)});
        };
    }
}
