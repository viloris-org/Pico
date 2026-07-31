const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine_mod = @import("../storage/engine.zig");
const pg = @import("pg.zig");
const runadb = @import("runadb.zig");
const quic = @import("quic.zig");

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5433,
    runa_port: u16 = 5434,
    /// QUIC listener port. Set to 0 to disable QUIC.
    quic_port: u16 = 5435,
    data_dir: []const u8 = "data",
    sync_wal: bool = true,
    /// Path to TLS certificate file (required for QUIC listener).
    tls_cert_path: []const u8 = "",
    /// Path to TLS private key file (required for QUIC listener).
    tls_key_path: []const u8 = "",
    /// PEM-encoded TLS certificate (takes precedence over tls_cert_path).
    tls_cert_pem: ?[]const u8 = null,
    /// PEM-encoded TLS private key (takes precedence over tls_key_path).
    tls_key_pem: ?[]const u8 = null,
};

pub fn run(gpa: Allocator, io: Io, cfg: Config) !void {
    var eng = try engine_mod.Engine.open(gpa, io, cfg.data_dir, cfg.sync_wal);
    defer eng.deinit();

    // Start RunaDB TCP native protocol listener on a background thread.
    var runa_thread: ?std.Thread = null;
    if (cfg.runa_port > 0) {
        const runa_cfg = RunaListenerConfig{
            .gpa = gpa,
            .io = io,
            .host = cfg.host,
            .port = cfg.runa_port,
            .eng = &eng,
        };
        runa_thread = try std.Thread.spawn(.{}, runRunaListener, .{runa_cfg});
    }
    defer {
        if (runa_thread) |t| t.detach();
    }

    // Start QUIC (zquic) listener on a background thread.
    var quic_thread: ?std.Thread = null;
    if (cfg.quic_port > 0) {
        // TLS certs are required for QUIC.
        const has_tls = cfg.tls_cert_pem != null or cfg.tls_cert_path.len > 0;
        if (!has_tls) {
            std.log.warn("QUIC listener disabled: no TLS certificate provided. " ++
                "Use --tls-cert and --tls-key, or run 'runa create instance'.", .{});
        } else {
            const quic_cfg = quic.Config{
                .host = cfg.host,
                .port = cfg.quic_port,
                .cert_pem = cfg.tls_cert_pem,
                .key_pem = cfg.tls_key_pem,
                .cert_path = cfg.tls_cert_path,
                .key_path = cfg.tls_key_path,
                .cubic = true,
            };
            quic_thread = try std.Thread.spawn(.{}, runQuicListener, .{ gpa, quic_cfg, &eng });
        }
    }
    defer {
        if (quic_thread) |t| t.detach();
    }

    // PG protocol listener (main thread).
    const pg_addr = try Io.net.IpAddress.parse(cfg.host, cfg.port);
    var pg_server = try pg_addr.listen(io, .{
        .reuse_address = true,
    });
    defer pg_server.deinit(io);

    std.log.info("RunaDB PG protocol listening on {s}:{d}", .{ cfg.host, cfg.port });
    if (cfg.runa_port > 0) {
        std.log.info("RunaDB native protocol (TCP) listening on {s}:{d}", .{ cfg.host, cfg.runa_port });
    }
    if (cfg.quic_port > 0) {
        std.log.info("RunaDB native protocol (QUIC/UDP) on {s}:{d}", .{ cfg.host, cfg.quic_port });
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

fn runQuicListener(gpa: Allocator, cfg: quic.Config, eng: *engine_mod.Engine) void {
    quic.runListener(gpa, cfg, eng) catch |err| {
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

fn runRunaListener(cfg: RunaListenerConfig) void {
    const gpa = cfg.gpa;
    const io = cfg.io;

    const addr = Io.net.IpAddress.parse(cfg.host, cfg.port) catch |err| {
        std.log.err("runa listener: parse address failed: {s}", .{@errorName(err)});
        return;
    };
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.log.err("runa listener: listen failed: {s}", .{@errorName(err)});
        return;
    };
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
