//! Pico QUIC transport — server-side listener using zquic.
//!
//! Runs an external-drive event loop over a UDP socket, feeding packets into
//! zquic's Server.  Received STREAM data is dispatched to the same Pico wire
//! protocol handler used by the TCP listener (`pico.handleConnection`-style
//! logic, but adapted to QUIC streams).
//!
//! Architecture:
//!   ┌──────────────────────────────┐
//!   │  QUICListener                │
//!   │  ├─ poll-based recv loop     │
//!   │  ├─ feedPacket → zquic       │
//!   │  ├─ processPendingWork       │
//!   │  └─ dispatch stream data     │
//!   ├──────────────────────────────┤
//!   │  zquic.transport.io.Server   │
//!   │  conns: [256]?*ConnState     │
//!   │  raw_application_streams=true│
//!   └──────────────────────────────┘

const std = @import("std");
const Allocator = std.mem.Allocator;
const zquic = @import("zquic");
const exec = @import("../sql/exec.zig");
const engine_mod = @import("../storage/engine.zig");
const proto = @import("clint_proto");

/// Maximum UDP payload we read in a single recvfrom call.
const MAX_DATAGRAM_SIZE: usize = 1500;

/// Maximum number of UDP datagrams to drain per event-loop tick.
const MAX_BATCH_RECV: usize = 64;

/// Linux SOCK_NONBLOCK (0o4000) — std.posix may not expose it in Zig 0.16.
const SOCK_NONBLOCK: u32 = 0o4000;

/// Configuration for the QUIC listener.
pub const Config = struct {
    /// UDP bind address.
    host: []const u8 = "127.0.0.1",
    /// UDP port.
    port: u16 = 5435,
    /// PEM-encoded TLS certificate (in-memory; takes precedence over cert_path).
    cert_pem: ?[]const u8 = null,
    /// PEM-encoded TLS private key (in-memory; takes precedence over key_path).
    key_pem: ?[]const u8 = null,
    /// Path to TLS certificate file (used when cert_pem is null).
    cert_path: []const u8 = "",
    /// Path to TLS private key file (used when key_pem is null).
    key_path: []const u8 = "",
    /// Use CUBIC congestion control instead of NewReno.
    cubic: bool = true,
};

/// Run the QUIC listener event loop (blocks forever).
/// Designed to be spawned in a background thread, matching the existing
/// TCP listener pattern in `net/server.zig`.
pub fn runListener(gpa: Allocator, cfg: Config, eng: *engine_mod.Engine) !void {
    // ── 1. Create UDP socket (non-blocking) ──
    const sock = try zquic.compat.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | SOCK_NONBLOCK,
        0,
    );
    errdefer zquic.compat.close(sock);

    const addr = try zquic.compat.Address.parseIp4(cfg.host, cfg.port);
    try zquic.compat.bind(sock, &addr.any, addr.getOsSockLen());

    // ── 2. Initialise zquic Server ──
    const server = try zquic.transport.io.Server.initFromSocket(gpa, .{
        .port = cfg.port,
        .cert_pem = cfg.cert_pem,
        .key_pem = cfg.key_pem,
        .cert_path = cfg.cert_path,
        .key_path = cfg.key_path,
        .alpn = "pico",
        .raw_application_streams = true,
        .cubic = cfg.cubic,
        .migrate = false,
    }, sock, true);
    defer server.deinit();

    std.log.info("Pico QUIC protocol listening on udp://{s}:{d}", .{ cfg.host, cfg.port });

    // ── 3. Event loop (poll-based, no busy-wait) ──
    var recv_buf: [MAX_DATAGRAM_SIZE]u8 = undefined;
    var src_addr: std.posix.sockaddr = undefined;
    var src_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

    while (true) {
        // Wait for incoming data (10ms timeout to allow periodic housekeeping).
        var pfd = [_]std.posix.pollfd{
            .{ .fd = sock, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const n_ready = std.os.linux.poll(&pfd, 1, 10);
        if (n_ready == 0) {
            // Timeout — still run periodic work.
            server.resetDriveSendBudgets();
            server.processPendingWork();
            dispatchConnections(gpa, server, eng);
            continue;
        }

        // Reset per-drive send budgets (MUST be called once per tick).
        server.resetDriveSendBudgets();

        // Drain available UDP datagrams.
        var drained: usize = 0;
        while (drained < MAX_BATCH_RECV) {
            const len = zquic.compat.recvfrom(
                sock,
                recv_buf[0..],
                0,
                &src_addr,
                &src_addr_len,
            ) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    std.log.err("quic: recvfrom failed: {s}", .{@errorName(err)});
                    break;
                },
            };
            src_addr_len = @sizeOf(std.posix.sockaddr);
            drained += 1;

            // Convert raw sockaddr to compat.Address for feedPacket.
            const compat_addr = zquic.compat.Address{ .any = src_addr };
            server.feedPacket(recv_buf[0..len], compat_addr);
        }

        // Run pending recovery / flush work.
        server.processPendingWork();

        // Dispatch received stream data to Pico protocol handlers.
        dispatchConnections(gpa, server, eng);
    }
}

/// Scan all connections for received STREAM data and dispatch to the Pico
/// protocol handler.
fn dispatchConnections(gpa: Allocator, server: *zquic.transport.io.Server, eng: *engine_mod.Engine) void {
    _ = gpa;
    _ = server;
    _ = eng;
    // TODO: implement stream dispatch in follow-up step.
    // For each connected connection, iterate raw_app_streams slots,
    // extract Pico protocol frames, execute SQL, send response via
    // server.sendRawStreamData().
}
