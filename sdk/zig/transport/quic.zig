//! RunaDB Zig SDK — QUIC transport over the vendored zquic client
//! (ADR-0015, ADR-0023 §2).
//!
//! Status: **target design** — the client code compiles and drives the zquic
//! event loop, but no RunaDB Server accepts QUIC connections in this
//! checkout (roadmap Phase 9), so this path has no end-to-end regression.
//! A QUIC connect against a server without a QUIC listener fails with a
//! defined error; there is no silent TCP fallback.
//!
//! Stream contract (ADR-0023 §2.1): client bidi stream 0 is the control
//! stream (`hello` / `hello_ok` / `hello_error`, `cancel_request`,
//! `goodbye`); each request opens the next client bidi stream (4, 8, 12, …),
//! writes the request messages, half-closes its send side, and reads the
//! result sequence until `command_complete` / `server_error` / `goodbye`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zquic = @import("zquic");
const io_mod = zquic.transport.io;
const compat = zquic.compat;
const codec = @import("../codec.zig");
const transport = @import("../transport.zig");

pub const QuicConn = struct {
    allocator: Allocator,
    config: transport.Config,
    client: *io_mod.Client,
    server_addr: compat.Address,
    /// SHA-256 digest of the presented server leaf certificate. Populated
    /// when the handshake completed (`peer_cert_presented`); used for
    /// certificate pinning (ADR-0023 §2.3).
    peer_cert_digest: [32]u8 = undefined,
    peer_cert_presented: bool = false,
    /// Lazily opened control stream (client bidi stream 0); closed on deinit.
    control: ?*QuicStream = null,

    pub fn connect(allocator: Allocator, config: transport.Config) !*QuicConn {
        const server_addr = try resolveAddress(config.host, config.effectivePort());

        const client = try allocator.create(io_mod.Client);
        errdefer allocator.destroy(client);
        try io_mod.Client.initInPlace(allocator, clientConfig(config), client);
        errdefer client.deinit();

        try client.startHandshake(server_addr);

        const self = try allocator.create(QuicConn);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .client = client,
            .server_addr = server_addr,
        };
        errdefer {
            client.deinit();
            allocator.destroy(client);
            allocator.destroy(self);
        }

        // Drive the zquic event loop until the TLS 1.3 handshake completes,
        // the peer closes the connection (e.g. ALPN rejection), or the
        // connect deadline expires.
        const deadline = compat.milliTimestamp() + @as(i64, @intCast(config.connect_timeout_ms));
        while (client.conn.phase != .connected) {
            if (client.conn.draining or client.conn.phase == .closed) return error.QuicRejected;
            if (compat.milliTimestamp() >= deadline) return error.HandshakeTimeout;
            try self.pump(100);
        }

        // Server identity: pin the leaf certificate or expose its digest for
        // trust-on-first-use inspection (ADR-0023 §2.3). zquic does not
        // perform X.509 chain validation.
        const der = client.peerLeafCertificateDer() orelse return error.CertificateMismatch;
        std.crypto.hash.sha2.Sha256.hash(der, &self.peer_cert_digest, .{});
        self.peer_cert_presented = true;
        if (config.server_cert_pem) |pem| {
            const pinned_der = try io_mod.parseCertDerFromPem(allocator, pem);
            defer allocator.free(pinned_der);
            var pinned: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(pinned_der, &pinned, .{});
            if (!std.mem.eql(u8, &self.peer_cert_digest, &pinned)) return error.CertificateMismatch;
        }

        return self;
    }

    /// The control stream (client bidi stream 0), opened on first use and
    /// kept for the Connection lifetime.
    pub fn controlStream(self: *QuicConn) !*QuicStream {
        if (self.control) |stream| return stream;
        const stream = try self.openStream();
        self.control = stream;
        return stream;
    }

    /// Open the control stream (client bidi stream 0) or the next query
    /// stream. The stream is a handle over the QUIC connection; the caller
    /// closes it when the request result sequence ends.
    pub fn openStream(self: *QuicConn) !*QuicStream {
        const stream_id = try self.client.tryOpenLocalBidiStream();
        const stream = try self.allocator.create(QuicStream);
        stream.* = .{
            .conn = self,
            .allocator = self.allocator,
            .stream_id = stream_id,
        };
        return stream;
    }

    /// One event-loop iteration: retransmit/PTO bookkeeping, poll the UDP
    /// socket, feed received datagrams into zquic.
    pub fn pump(self: *QuicConn, timeout_ms: u32) !void {
        self.client.processPendingWork(self.server_addr);
        self.client.flushSendBatch();

        var fds = [1]std.posix.pollfd{.{
            .fd = self.client.sock,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch 0;
        if (ready > 0) {
            if (fds[0].revents & std.posix.POLL.ERR != 0) {
                // Drain a pending ICMP/socket error so the next poll() is not
                // immediately re-woken by POLLERR.
                var dummy: [io_mod.MAX_DATAGRAM_SIZE]u8 = undefined;
                var dummy_addr: std.posix.sockaddr.storage = undefined;
                var dummy_len: std.posix.socklen_t = @sizeOf(@TypeOf(dummy_addr));
                _ = compat.recvfrom(self.client.sock, &dummy, 0, @ptrCast(&dummy_addr), &dummy_len) catch {};
                return;
            }
            if (fds[0].revents & std.posix.POLL.IN != 0) {
                var buf: [io_mod.MAX_DATAGRAM_SIZE]u8 = undefined;
                var src_addr: std.posix.sockaddr.storage = undefined;
                var src_len: std.posix.socklen_t = @sizeOf(@TypeOf(src_addr));
                const n = compat.recvfrom(self.client.sock, &buf, 0, @ptrCast(&src_addr), &src_len) catch return;
                self.client.feedPacket(buf[0..n]);
            }
        }
        self.client.processPendingWork(self.server_addr);
        self.client.flushSendBatch();
    }

    pub fn close(self: *QuicConn, reason: []const u8) void {
        self.client.closeConnection(0, reason);
    }

    pub fn deinit(self: *QuicConn) void {
        if (self.control) |stream| {
            stream.close();
            self.allocator.destroy(stream);
        }
        self.client.deinit();
        self.allocator.destroy(self.client);
        self.allocator.destroy(self);
    }
};

fn clientConfig(config: transport.Config) io_mod.ClientConfig {
    return .{
        .host = config.host,
        .port = config.effectivePort(),
        .urls = &.{},
        .http09 = false,
        .http3 = false,
        .alpn = transport.ALPN,
        .raw_application_streams = true,
    };
}

/// Resolve the server address. IPv4 and IPv6 literals are supported;
/// hostname resolution is target-design work for the QUIC path.
fn resolveAddress(host: []const u8, port: u16) !compat.Address {
    if (compat.Address.parseIp4(host, port)) |addr| return addr else |_| {}
    const ip6 = Io.net.IpAddress.parseIp6(host, port) catch return error.UnsupportedAddress;
    return switch (ip6) {
        .ip6 => |a| compat.Address{ .in6 = .{
            .family = std.posix.AF.INET6,
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = 0,
            .addr = a.bytes,
            .scope_id = 0,
        } },
        else => error.UnsupportedAddress,
    };
}

/// One QUIC stream. The send side buffers request bytes and sends them on
/// `flush` (FIN on the last flush); the receive side reads the reassembled
/// raw-app buffer, pumping the event loop as needed.
pub const QuicStream = struct {
    conn: *QuicConn,
    allocator: Allocator,
    stream_id: u64,
    send_offset: u64 = 0,
    send_pending: std.ArrayList(u8) = .empty,
    recv_consumed: usize = 0,
    fin_sent: bool = false,
    closed: bool = false,

    pub fn stream(self: *QuicStream) codec.Stream {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn writeAll(self: *QuicStream, bytes: []const u8) anyerror!void {
        try self.send_pending.appendSlice(self.allocator, bytes);
    }

    /// Send buffered bytes, optionally with STREAM FIN. Bounded by
    /// `read_timeout_ms`; stalls (peer flow-control window) pump the event
    /// loop until progress or timeout.
    fn flush(self: *QuicStream, fin: bool) anyerror!void {
        const deadline = compat.milliTimestamp() + @as(i64, @intCast(self.conn.config.read_timeout_ms));
        while (self.send_pending.items.len > 0) {
            const sent = self.conn.client.sendRawStreamData(
                self.stream_id,
                self.send_offset,
                self.send_pending.items,
                false,
            );
            if (sent > 0) {
                const remaining = self.send_pending.items.len - sent;
                std.mem.copyForwards(u8, self.send_pending.items[0..remaining], self.send_pending.items[sent..]);
                self.send_pending.shrinkRetainingCapacity(remaining);
                self.send_offset += sent;
                continue;
            }
            if (compat.milliTimestamp() >= deadline) return error.Timeout;
            try self.conn.pump(100);
        }
        if (fin and !self.fin_sent) {
            _ = self.conn.client.sendRawStreamData(self.stream_id, self.send_offset, &.{}, true);
            self.fin_sent = true;
        }
        self.conn.client.flushSendBatch();
    }

    fn readAll(self: *QuicStream, buf: []u8) anyerror!void {
        const deadline = compat.milliTimestamp() + @as(i64, @intCast(self.conn.config.read_timeout_ms));
        var filled: usize = 0;
        while (filled < buf.len) {
            const avail = self.conn.client.rawAppRecvBuffer(self.stream_id) orelse &.{};
            const unread = avail.len -| self.recv_consumed;
            if (unread > 0) {
                const take_n = @min(buf.len - filled, unread);
                @memcpy(buf[filled..][0..take_n], avail[self.recv_consumed..][0..take_n]);
                self.recv_consumed += take_n;
                filled += take_n;
                continue;
            }
            if (self.conn.client.rawAppStreamFullyReceived(self.stream_id)) return error.EndOfStream;
            if (self.conn.client.rawAppStreamResetReceived(self.stream_id)) |_| return error.ConnectionReset;
            if (compat.milliTimestamp() >= deadline) return error.Timeout;
            try self.conn.pump(100);
        }
    }

    /// Release the stream: free the raw-app receive slot and the send buffer.
    /// Idempotent.
    pub fn close(self: *QuicStream) void {
        if (self.closed) return;
        self.closed = true;
        _ = self.conn.client.releaseRawAppStream(self.stream_id);
        self.send_pending.deinit(self.allocator);
    }

    const vtable = codec.Stream.VTable{
        .readAll = quicReadAll,
        .writeAll = quicWriteAll,
        .flush = quicFlush,
        .fin = quicFin,
        .close = quicClose,
    };

    fn quicReadAll(ctx: *anyopaque, buf: []u8) anyerror!void {
        const self: *QuicStream = @ptrCast(@alignCast(ctx));
        try self.readAll(buf);
    }
    fn quicWriteAll(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *QuicStream = @ptrCast(@alignCast(ctx));
        try self.writeAll(bytes);
    }
    fn quicFlush(ctx: *anyopaque) anyerror!void {
        const self: *QuicStream = @ptrCast(@alignCast(ctx));
        try self.flush(false);
    }
    fn quicFin(ctx: *anyopaque) anyerror!void {
        const self: *QuicStream = @ptrCast(@alignCast(ctx));
        try self.flush(true);
    }
    fn quicClose(ctx: *anyopaque) void {
        const self: *QuicStream = @ptrCast(@alignCast(ctx));
        self.close();
    }
};

test "quic stream mapping: control is 0, queries step by 4" {
    const transport_mod = @import("../transport.zig");
    try std.testing.expectEqual(@as(u64, 0), transport_mod.StreamMap.control);
    try std.testing.expectEqual(@as(u64, 4), transport_mod.StreamMap.first_query);
    try std.testing.expectEqual(@as(u64, 4), transport_mod.StreamMap.stride);
}

test "quic config defaults: ALPN and ports" {
    const transport_mod = @import("../transport.zig");
    try std.testing.expectEqualStrings("runadb", transport_mod.ALPN);
    try std.testing.expectEqual(@as(u16, 5435), transport_mod.DEFAULT_QUIC_PORT);
    try std.testing.expectEqual(@as(u16, 5434), transport_mod.DEFAULT_TCP_PORT);
}
