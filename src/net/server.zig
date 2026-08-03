const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine_mod = @import("../storage/engine.zig");
const connection_mod = @import("connection.zig");
const registry_mod = @import("registry.zig");
const mcp = @import("mcp.zig");
const runadb = @import("runadb.zig");
const quic = @import("quic.zig");

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    runa_port: u16 = 5434,
    /// UDP QUIC listener port (ADR-0015 §5); 0 disables the QUIC listener.
    quic_port: u16 = 5435,
    data_dir: []const u8 = "data",
    sync_wal: bool = true,
    mcp_stdio: bool = false,
    /// PEM certificate/key overrides; default to the embedded development
    /// self-signed certificate (src/net/dev-cert.pem, RSA-2048).
    quic_cert_pem: ?[]const u8 = null,
    quic_key_pem: ?[]const u8 = null,
    /// QUIC idle timeout (RFC 9000 §10.1) in milliseconds; the listener reaps
    /// a connected peer that stays silent this long (min with the peer's
    /// advertised timeout). Default 30_000.
    quic_idle_timeout_ms: u32 = 30_000,
};

pub fn run(gpa: Allocator, io: Io, cfg: Config) !void {
    var eng = try engine_mod.Engine.open(gpa, io, cfg.data_dir, cfg.sync_wal);
    defer eng.deinit();

    if (cfg.mcp_stdio) {
        std.log.info("RunaDB MCP stdio adapter listening", .{});
        return mcp.runStdio(gpa, io, &eng);
    }
    if (cfg.runa_port == 0 and cfg.quic_port == 0) return error.NoListener;
    std.log.info("Data directory: {s}", .{cfg.data_dir});

    if (cfg.quic_port > 0) {
        const quic_cfg = quic.Config{
            .port = cfg.quic_port,
            .cert_pem = cfg.quic_cert_pem orelse @embedFile("dev-cert.pem"),
            .key_pem = cfg.quic_key_pem orelse @embedFile("dev-key.pem"),
            .idle_timeout_ms = cfg.quic_idle_timeout_ms,
        };
        var quic_registry = registry_mod.Registry.init(gpa, io, .{});
        const qs = try quic.QuicServer.init(gpa, io, quic_cfg, &eng, &quic_registry, null);
        std.log.info("RunaDB Wire Protocol v3 QUIC listening on udp 0.0.0.0:{d} (ALPN {s})", .{ cfg.quic_port, quic.ALPN });
        if (cfg.runa_port == 0) {
            // QUIC-only mode: the QUIC event loop owns the main thread.
            return qs.run();
        }
        const thread = try std.Thread.spawn(.{}, quicServerThread, .{qs});
        thread.detach();
    }
    if (cfg.runa_port == 0) return error.NoListener;
    std.log.info("RunaDB Wire Protocol v3 listening on {s}:{d}", .{ cfg.host, cfg.runa_port });
    try runRunaListener(.{
        .gpa = gpa,
        .io = io,
        .host = cfg.host,
        .port = cfg.runa_port,
        .eng = &eng,
    });
}

fn quicServerThread(qs: *quic.QuicServer) void {
    qs.run() catch |err| {
        std.log.err("quic listener: {s}", .{@errorName(err)});
    };
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
