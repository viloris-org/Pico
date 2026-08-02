const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine_mod = @import("../storage/engine.zig");
const connection_mod = @import("connection.zig");
const registry_mod = @import("registry.zig");
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
    std.log.info("RunaDB Wire Protocol v3 listening on {s}:{d}", .{ cfg.host, cfg.runa_port });
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

/// One accepted connection, owned by a detached handler thread. The thread
/// closes the stream on every exit path; the accept loop never touches it
/// after `dispatchConnection` returns.
const ConnectionWorker = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    eng: *engine_mod.Engine,
    registry: *registry_mod.Registry,
    credential: connection_mod.Credential,

    fn run(self: ConnectionWorker) void {
        defer self.stream.close(self.io);
        runadb.handleConnection(self.gpa, self.io, self.stream, self.eng, self.registry, self.credential) catch |err| {
            std.log.warn("RunaDB connection closed with error: {s}", .{@errorName(err)});
        };
    }
};

/// Accept one connection and dispatch it onto a detached handler thread so
/// multiple clients make progress concurrently (roadmap Phase 6). All logical
/// mutation still routes through the single-writer commit coordinator, and each
/// statement's engine access is serialized by the engine's statement-execution
/// lock, so the bounded registry (capacity 1024) is the only concurrency bound.
/// On a spawn failure the stream is closed here and the connection is dropped.
pub fn dispatchConnection(
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    eng: *engine_mod.Engine,
    registry: *registry_mod.Registry,
) void {
    const worker = ConnectionWorker{
        .gpa = gpa,
        .io = io,
        .stream = stream,
        .eng = eng,
        .registry = registry,
        .credential = connection_mod.randomCredential(io),
    };
    if (std.Thread.spawn(.{}, ConnectionWorker.run, .{worker})) |thread| {
        thread.detach();
    } else |err| {
        stream.close(io);
        std.log.warn("runa listener: failed to spawn connection thread: {s}", .{@errorName(err)});
    }
}

fn runRunaListener(cfg: RunaListenerConfig) !void {
    const gpa = cfg.gpa;
    const io = cfg.io;

    const addr = try Io.net.IpAddress.parse(cfg.host, cfg.port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var registry = registry_mod.Registry.init(gpa, io, .{});
    defer registry.deinit();

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("runa listener: accept failed: {s}", .{@errorName(err)});
            continue;
        };
        dispatchConnection(gpa, io, stream, cfg.eng, &registry);
    }
}
