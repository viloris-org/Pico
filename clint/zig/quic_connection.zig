//! Pico QUIC connection — manages a QUIC connection to a Pico Server using zquic.
//!
//! Mirrors the TCP `Connection` interface (`connect`, `execute`, `close`),
//! but uses zquic's embedder Client API for QUIC transport.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zquic = @import("zquic");
const proto = @import("clint_proto");
const codec = @import("codec.zig");

/// Maximum UDP payload size.
const MAX_DATAGRAM_SIZE: usize = 1500;

/// Maximum time (ms) to wait for handshake completion.
const HANDSHAKE_POLL_MS: i64 = 5000;

/// A QUIC-based Pico protocol connection.
pub const QuicConnection = struct {
    allocator: Allocator,
    client: *zquic.transport.io.Client,
    sock: std.posix.socket_t,
    server_addr: zquic.compat.Address,
    stream_id: u64,
    /// Buffer for assembling received stream data (raw bytes).
    recv_buf: std.ArrayListUnmanaged(u8),
    /// Current read position within recv_buf.
    recv_pos: usize,
    /// Maximum event-loop drive ticks before timing out.
    max_drive_ticks: usize,

    /// Connect to a Pico QUIC server.
    pub fn connect(allocator: Allocator, host: []const u8, port: u16) !QuicConnection {
        // ── 1. Create UDP socket ──
        const sock = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
            0,
        );
        errdefer std.posix.close(sock);

        const bind_any = try std.net.Address.parseIp4("0.0.0.0", 0);
        try std.posix.bind(sock, &bind_any.any, bind_any.getOsSockLen());

        // ── 2. Resolve server address ──
        const server_addr = zquic.compat.Address.parseIp4(host, port) catch
            return error.InvalidAddress;

        // ── 3. Create zquic Client (heap-allocated) ──
        const client = try allocator.create(zquic.transport.io.Client);
        errdefer allocator.destroy(client);

        try zquic.transport.io.Client.initFromSocketInPlace(allocator, .{
            .host = host,
            .port = port,
            .alpn = "pico",
            .raw_application_streams = true,
        }, sock, true, client);
        errdefer client.deinit();

        // ── 4. Start handshake ──
        try client.startHandshake(server_addr);

        var self = QuicConnection{
            .allocator = allocator,
            .client = client,
            .sock = sock,
            .server_addr = server_addr,
            .stream_id = 0,
            .recv_buf = .{},
            .recv_pos = 0,
            .max_drive_ticks = 1000,
        };

        // ── 5. Drive handshake to completion ──
        try self.driveUntilHandshakeComplete();

        // ── 6. Open a bidirectional stream for Pico protocol ──
        self.stream_id = try client.rawAllocateNextLocalBidiStream();

        // ── 7. Send HELLO ──
        {
            var payload_buf: [4]u8 = undefined;
            std.mem.writeInt(u16, payload_buf[0..2], proto.PROTOCOL_VERSION_MAJOR, .big);
            std.mem.writeInt(u16, payload_buf[2..4], proto.PROTOCOL_VERSION_MINOR, .big);
            try self.sendStreamData(&payload_buf, false);
        }

        // ── 8. Read HELLO response ──
        try self.driveUntilDataAvailable();
        const msg = try self.readOneMessage();
        switch (msg) {
            .hello_ok => return self,
            .hello_error => return error.ServerRejected,
            else => return error.Protocol,
        }
    }

    /// Execute a SQL statement. Returns a result iterator.
    pub fn execute(self: *QuicConnection, arena: Allocator, sql: []const u8) !QueryResult {
        _ = arena;
        const sl: u32 = @intCast(sql.len);
        var payload_buf: [4 + 64 * 1024]u8 = undefined;
        if (sl > 64 * 1024) return error.MessageTooLarge;
        std.mem.writeInt(u32, payload_buf[0..4], sl, .big);
        @memcpy(payload_buf[4..][0..sl], sql);
        try self.sendStreamData(payload_buf[0 .. 4 + sl], false);

        return QueryResult{
            .conn = self,
            .done = false,
        };
    }

    /// Close the QUIC connection gracefully.
    pub fn close(self: *QuicConnection) void {
        self.client.deinit();
        self.recv_buf.deinit(self.allocator);
    }

    // ── Internal helpers ──

    /// Drive the event loop until the handshake completes.
    fn driveUntilHandshakeComplete(self: *QuicConnection) !void {
        var elapsed_ms: i64 = 0;
        var recv_buf: [MAX_DATAGRAM_SIZE]u8 = undefined;
        var src_addr: std.posix.sockaddr = undefined;
        var src_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        while (self.client.conn.phase != .connected) {
            if (elapsed_ms > HANDSHAKE_POLL_MS) return error.Timeout;

            self.client.resetDriveSendBudget();

            while (true) {
                const len = std.posix.recvfrom(self.sock, &recv_buf, 0, &src_addr, &src_addr_len) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return error.ReadFailed,
                };
                src_addr_len = @sizeOf(std.posix.sockaddr);
                self.client.feedPacket(recv_buf[0..len]);
            }

            self.client.processPendingWork(self.server_addr);

            std.time.sleep(5 * std.time.ns_per_ms);
            elapsed_ms += 5;
        }
    }

    /// Drive the event loop until new stream data arrives.
    fn driveUntilDataAvailable(self: *QuicConnection) !void {
        if (self.hasCompleteMessage()) return;

        var recv_buf: [MAX_DATAGRAM_SIZE]u8 = undefined;
        var src_addr: std.posix.sockaddr = undefined;
        var src_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        var ticks: usize = 0;
        while (ticks < self.max_drive_ticks) {
            self.client.resetDriveSendBudget();

            while (true) {
                const len = std.posix.recvfrom(self.sock, &recv_buf, 0, &src_addr, &src_addr_len) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return error.ReadFailed,
                };
                src_addr_len = @sizeOf(std.posix.sockaddr);
                self.client.feedPacket(recv_buf[0..len]);
            }

            self.client.processPendingWork(self.server_addr);
            self.collectReceivedData();

            if (self.hasCompleteMessage()) return;

            std.time.sleep(5 * std.time.ns_per_ms);
            ticks += 1;
        }

        return error.Timeout;
    }

    /// Collect received stream data from all active raw app stream slots.
    fn collectReceivedData(self: *QuicConnection) void {
        for (&self.client.conn.raw_app_streams) |*slot| {
            if (!slot.active) continue;
            const slot_data = slot.buf.items;
            // Append any new data not yet in our buffer.
            const current_len = self.recv_buf.items.len;
            if (slot_data.len > current_len) {
                self.recv_buf.appendSlice(self.allocator, slot_data[current_len..]) catch {};
            }
        }
    }

    /// Check if a complete Pico protocol frame is available in recv_buf.
    fn hasCompleteMessage(self: *QuicConnection) bool {
        const avail = self.recv_buf.items.len -| self.recv_pos;
        if (avail < proto.HEADER_SIZE) return false;
        const body_len = std.mem.readInt(
            u32,
            self.recv_buf.items[self.recv_pos..][0..4],
            .big,
        );
        return avail >= proto.HEADER_SIZE + body_len;
    }

    /// Read one Pico protocol message from the received buffer.
    fn readOneMessage(self: *QuicConnection) !codec.Message {
        try self.driveUntilDataAvailable();

        if (self.recv_buf.items.len - self.recv_pos < proto.HEADER_SIZE)
            return error.EndOfStream;

        const header = self.recv_buf.items[self.recv_pos..][0..proto.HEADER_SIZE];
        const body_len = std.mem.readInt(u32, header[0..4], .big);
        if (body_len < 1) return error.Protocol;
        if (body_len > proto.MAX_BODY_LENGTH) return error.MessageTooLarge;

        const total_len: usize = proto.HEADER_SIZE + body_len;
        if (self.recv_buf.items.len - self.recv_pos < total_len)
            return error.EndOfStream;

        const frame = self.recv_buf.items[self.recv_pos .. self.recv_pos + total_len];
        self.recv_pos += total_len;

        // Wrap the frame in a FixedBufferStream and use codec.readMessage.
        var fbs = std.io.fixedBufferStream(frame);
        const msg = try codec.readMessage(self.allocator, fbs.reader().interface());
        return msg;
    }

    /// Send data on the QUIC stream (handles partial sends).
    fn sendStreamData(self: *QuicConnection, data: []const u8, fin: bool) !void {
        var offset: u64 = 0;
        while (offset < data.len) {
            self.client.resetDriveSendBudget();

            const accepted = self.client.sendRawStreamData(
                self.stream_id,
                offset,
                data[offset..],
                fin and offset + data.len - offset >= data.len,
            );
            offset += accepted;

            // Drive pending work to flush sends.
            var drain_buf: [128]u8 = undefined;
            var src_addr: std.posix.sockaddr = undefined;
            var src_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            _ = std.posix.recvfrom(self.sock, &drain_buf, 0, &src_addr, &src_addr_len) catch {};
            self.client.processPendingWork(self.server_addr);

            if (accepted == 0) {
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }
    }
};

/// Iterator over query result messages (QUIC version).
pub const QueryResult = struct {
    conn: *QuicConnection,
    done: bool,

    /// Read the next message from the query response stream.
    /// Returns null when COMMAND_COMPLETE or GOODBYE is received.
    pub fn next(self: *QueryResult, arena: Allocator) !?codec.Message {
        _ = arena;
        if (self.done) return null;

        const msg = try self.conn.readOneMessage();
        switch (msg) {
            .command_complete, .goodbye => {
                self.done = true;
                return msg;
            },
            else => return msg,
        }
    }

    /// Consume all remaining messages.
    pub fn drain(self: *QueryResult, arena: Allocator) !void {
        while (try self.next(arena)) |_| {}
    }
};
