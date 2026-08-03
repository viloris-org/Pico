//! RunaDB QUIC transport listener (ADR-0015, ADR-0023 §2.1).
//!
//! The server accepts QUIC connections on UDP (default port 5435) through the
//! vendored pure-Zig zquic stack (`lib/zquic/`), ALPN `runadb`, with opaque
//! raw application streams. RunaDB Wire Protocol frames run over QUIC
//! streams; the stream contract is pinned by ADR-0023 §2.1:
//!
//! * Client bidi stream 0 is the **control stream**: `hello` /
//!   `hello_ok` / `hello_error`, fire-and-forget `cancel_request`, and
//!   `goodbye`. It is opened by the client at connect time and stays open for
//!   the Connection lifetime; the server never FINs its side.
//! * Client bidi streams 4, 8, 12, … are **query streams**: one request
//!   (`flow_source`, `flow_ir`, attachment staging) followed by its result
//!   sequence (`row_description`, `row_data`*, `command_complete` /
//!   `server_error`). The client half-closes its send side after the request;
//!   the server responds on the same stream and FINs when the result sequence
//!   ends.
//!
//! Concurrency model: one zquic `Server` owns every `ConnState`, so all QUIC
//! I/O runs on a single event-loop thread. Each QUIC connection gets one
//! handler thread (mirroring the TCP runtime) that owns the connection's
//! protocol session: statement execution still serializes on the engine's
//! instance-wide statement lock, and QUIC streams let a slow request on one
//! connection never block the event loop or another connection's I/O. The
//! event loop forwards complete protocol frames to handler threads (frames
//! are length-prefixed, so reassembly is done by the transport) and drains
//! their response buffers onto QUIC streams.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zquic = @import("zquic");
const io_mod = zquic.transport.io;
const compat = zquic.compat;
const engine_mod = @import("../storage/engine.zig");
const connection_mod = @import("connection.zig");
const registry_mod = @import("registry.zig");
const runadb = @import("runadb.zig");
const proto = @import("clint_proto");

pub const DEFAULT_PORT: u16 = 5435;
pub const ALPN: []const u8 = "runadb";
/// Control stream id (client bidi stream 0, RFC 9000 §2.1).
pub const CONTROL_STREAM: u64 = 0;

/// One QUIC stream's response side, written by the session handler thread and
/// drained by the event loop. The stream's own mutex guards `send`/`sent`/
/// `fin_pending`; the handler appends, the event loop hands bytes to zquic.
const QuicStream = struct {
    gpa: Allocator,
    io: Io,
    stream_id: u64,
    mutex: Io.Mutex = .init,
    /// Response bytes written by the session handler, pending send.
    send: std.ArrayListUnmanaged(u8) = .empty,
    /// Bytes of `send` already handed to zquic (`send.items[0..sent]` are
    /// consumed; the tail is pending).
    sent: usize = 0,
    /// QUIC stream offset of the next byte to send.
    wire_offset: u64 = 0,
    /// The session handler finished this stream; FIN after `send` drains.
    fin_pending: bool = false,
    fin_sent: bool = false,
    /// The event loop has forwarded every received byte and the peer FIN'd;
    /// the handler has acknowledged the stream (in the done queue).
    handler_done: bool = false,
    writer: Io.Writer = undefined,
    writer_buf: [4 * 1024]u8 = undefined,

    /// Initialize in place. The `Io.Writer` buffers into `self.writer_buf`,
    /// so the struct must not be copied after init (a by-value return would
    /// leave the writer pointing at the init-local's stack buffer).
    fn init(self: *QuicStream, gpa: Allocator, io: Io, stream_id: u64) void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .stream_id = stream_id,
            .writer_buf = undefined,
        };
        self.writer = Io.Writer{ .vtable = &writer_vtable, .buffer = &self.writer_buf };
    }

    fn deinit(self: *QuicStream) void {
        self.send.deinit(self.gpa);
        self.* = undefined;
    }

    /// The session handler's writer for this stream: buffered writes drained
    /// into `send` on flush.
    fn streamWriter(self: *QuicStream) *Io.Writer {
        return &self.writer;
    }

    const writer_vtable = Io.Writer.VTable{
        .drain = streamDrain,
    };

    fn streamDrain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *QuicStream = @fieldParentPtr("writer", w);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // The Io.Writer buffers bytes in `w.buffer[0..w.end]`; drain consumes
        // it first, then every data slice (the last repeated `splat` times).
        if (w.end > 0) {
            self.send.appendSlice(self.gpa, w.buffer[0..w.end]) catch return error.WriteFailed;
            w.end = 0;
        }
        var consumed: usize = 0;
        for (data) |slice| {
            self.send.appendSlice(self.gpa, slice) catch return error.WriteFailed;
            consumed += slice.len;
        }
        if (splat > 1 and data.len > 0) {
            const last = data[data.len - 1];
            for (0..splat - 1) |_| {
                self.send.appendSlice(self.gpa, last) catch return error.WriteFailed;
                consumed += last.len;
            }
        }
        return consumed;
    }
};

/// A complete protocol frame delivered to the session handler, plus stream
/// lifecycle markers. Payloads are allocated by the event loop and freed by
/// the handler after processing.
const ToHandler = union(enum) {
    frame: struct {
        stream: *QuicStream,
        msg_type: proto.Type,
        payload: []u8,
    },
    /// The peer FIN'd its send side on this stream and the event loop has
    /// forwarded every byte; the handler finishes the response (FIN) and the
    /// event loop may release the stream slot.
    eof: *QuicStream,
    /// The QUIC connection is closing; unwind the session.
    close,
};

/// Unbounded FIFO with a condition variable; the event loop pushes, the
/// handler pops (blocking). Frames are never dropped; backpressure is
/// unbounded by design (frames are bounded by MAX_BODY_LENGTH and the server
/// is a single instance).
const Mailbox = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    items: std.ArrayListUnmanaged(ToHandler) = .empty,
    head: usize = 0,
    closed: bool = false,

    fn push(self: *Mailbox, gpa: Allocator, item: ToHandler) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.items.append(gpa, item);
        self.cond.signal(self.io);
    }

    /// Pop the next message, blocking until one arrives or the mailbox is
    /// closed and drained. Returns null on close.
    fn pop(self: *Mailbox) ?ToHandler {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.head == self.items.items.len and !self.closed) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        if (self.head == self.items.items.len) return null;
        const item = self.items.items[self.head];
        self.head += 1;
        if (self.head > 1024 and self.head * 2 > self.items.items.len) {
            const remaining = self.items.items.len - self.head;
            std.mem.copyForwards(ToHandler, self.items.items[0..remaining], self.items.items[self.head..]);
            self.items.items.len = remaining;
            self.head = 0;
        }
        return item;
    }

    fn signalClosed(self: *Mailbox) void {
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn deinit(self: *Mailbox, gpa: Allocator) void {
        self.mutex.lockUncancelable(self.io);
        for (self.items.items[self.head..]) |item| {
            switch (item) {
                .frame => |f| gpa.free(f.payload),
                else => {},
            }
        }
        self.items.deinit(gpa);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }
};

/// Stream ids the session handler has finished; the event loop releases their
/// raw-app slots and reap-pins.
const DoneQueue = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    items: std.ArrayListUnmanaged(u64) = .empty,

    fn push(self: *DoneQueue, gpa: Allocator, stream_id: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.items.append(gpa, stream_id);
    }

    fn drainAll(self: *DoneQueue, gpa: Allocator, out: *std.ArrayListUnmanaged(u64)) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        out.appendSlice(gpa, self.items.items) catch {};
        self.items.clearRetainingCapacity();
    }

    fn deinit(self: *DoneQueue, gpa: Allocator) void {
        self.mutex.lockUncancelable(self.io);
        self.items.deinit(gpa);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }
};

/// Per-stream frame reassembly state, owned by the event loop. Frames are
/// `[u32 BE body_len][u8 type][payload]` with `body_len = 1 + payload.len`.
const ParseState = struct {
    /// Bytes of the raw-app slot buffer already consumed.
    consumed: usize = 0,
    header: [proto.HEADER_SIZE]u8 = undefined,
    header_len: usize = 0,
    body_len: u32 = 0,
    /// Payload bytes collected so far (after the type byte).
    payload: std.ArrayListUnmanaged(u8) = .empty,
    payload_have: usize = 0,

    fn deinit(self: *ParseState, gpa: Allocator) void {
        self.payload.deinit(gpa);
        self.* = undefined;
    }
};

/// Per-QUIC-connection session. Owned by the event loop; the handler thread
/// runs the protocol session against the frames the event loop forwards.
const QuicConnection = struct {
    gpa: Allocator,
    io: Io,
    eng: *engine_mod.Engine,
    registry: *registry_mod.Registry,
    zconn: *io_mod.ConnState,
    /// Cancellation/identity state registered with the instance registry on
    /// the control-stream `hello`.
    state: connection_mod.State,
    registered: bool = false,
    /// True once the control stream handshake completed.
    authenticated: bool = false,
    /// One in-flight attachment staging slot per connection (mirrors TCP).
    attachment: ?runadb.Attachment = null,
    thread: ?std.Thread = null,
    mailbox: Mailbox = undefined,
    done: DoneQueue = undefined,
    /// The session handler requested the whole connection close (goodbye).
    close_requested: std.atomic.Value(bool) = .init(false),
    /// stream_id -> response stream (event-loop owned).
    streams: std.AutoHashMapUnmanaged(u64, *QuicStream) = .empty,
    /// stream_id -> frame reassembly state (event-loop owned).
    parse: std.AutoHashMapUnmanaged(u64, ParseState) = .empty,
    /// stream ids whose EOF was already signalled to the handler.
    eof_sent: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn init(gpa: Allocator, io: Io, eng: *engine_mod.Engine, registry: *registry_mod.Registry, zconn: *io_mod.ConnState) QuicConnection {
        return .{
            .gpa = gpa,
            .io = io,
            .eng = eng,
            .registry = registry,
            .zconn = zconn,
            .state = connection_mod.State.init(0, connection_mod.randomCredential(io)),
            .mailbox = .{ .io = io },
            .done = .{ .io = io },
        };
    }

    fn getStream(self: *QuicConnection, stream_id: u64) *QuicStream {
        const gop = self.streams.getOrPut(self.gpa, stream_id) catch unreachable;
        if (!gop.found_existing) {
            const qs = self.gpa.create(QuicStream) catch unreachable;
            QuicStream.init(qs, self.gpa, self.io, stream_id);
            gop.value_ptr.* = qs;
        }
        return gop.value_ptr.*;
    }

    fn getParse(self: *QuicConnection, stream_id: u64) *ParseState {
        const gop = self.parse.getOrPut(self.gpa, stream_id) catch unreachable;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }
};

pub const Config = struct {
    port: u16 = DEFAULT_PORT,
    /// PEM certificate for TLS (self-signed development certificates are
    /// acceptable; the SDK pins the leaf digest, ADR-0023 §2.3).
    cert_pem: []const u8,
    key_pem: []const u8,
    /// Local QUIC idle timeout (RFC 9000 §10.1) in milliseconds: how long a
    /// connected peer may stay silent before this listener reaps it. The
    /// effective timeout is min(local, peer-advertised). Default 30_000.
    idle_timeout_ms: u32 = 30_000,
};

/// The QUIC listener: owns the zquic `Server` and drives its event loop.
pub const QuicServer = struct {
    gpa: Allocator,
    io: Io,
    eng: *engine_mod.Engine,
    registry: *registry_mod.Registry,
    zserver: *io_mod.Server,
    /// Slot-index -> live session. `zserver.conns` slots are stable until
    /// reap; this mirrors it so teardown is O(1).
    qc_by_slot: []?*QuicConnection,

    /// Bind and start. When `sock` is non-null, it must be a bound UDP socket
    /// and zquic takes ownership (`initFromSocket`), which tests use for
    /// ephemeral ports; otherwise zquic binds `0.0.0.0:cfg.port`.
    pub fn init(gpa: Allocator, io: Io, cfg: Config, eng: *engine_mod.Engine, registry: *registry_mod.Registry, sock: ?std.posix.socket_t) !*QuicServer {
        const server_cfg = io_mod.ServerConfig{
            .port = cfg.port,
            .cert_pem = cfg.cert_pem,
            .key_pem = cfg.key_pem,
            .raw_application_streams = true,
            .alpn = ALPN,
            .max_incoming_streams = 4096,
            .max_incoming_uni_streams = 64,
            .max_idle_timeout_ms = cfg.idle_timeout_ms,
        };
        const zserver = if (sock) |s|
            try io_mod.Server.initFromSocket(gpa, server_cfg, s, true)
        else
            try io_mod.Server.init(gpa, server_cfg);
        errdefer zserver.deinit();

        const self = try gpa.create(QuicServer);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .eng = eng,
            .registry = registry,
            .zserver = zserver,
            .qc_by_slot = try gpa.alloc(?*QuicConnection, io_mod.MAX_CONNECTIONS),
        };
        @memset(self.qc_by_slot, null);
        return self;
    }

    pub fn deinit(self: *QuicServer) void {
        // Tear down every live session (signals + joins the session threads)
        // before freeing the zquic server: the handler threads may still hold
        // references to connection-owned state.
        for (self.qc_by_slot) |*slot| {
            if (slot.*) |qc| {
                self.teardownSession(qc);
                slot.* = null;
            }
        }
        self.zserver.deinit();
        self.gpa.free(self.qc_by_slot);
        self.gpa.destroy(self);
    }

    /// Bound UDP port (tests bind an ephemeral socket).
    pub fn boundPort(self: *const QuicServer) u16 {
        var sa: std.posix.sockaddr.storage = undefined;
        var sl: std.posix.socklen_t = @sizeOf(@TypeOf(sa));
        if (std.posix.errno(std.posix.system.getsockname(self.zserver.sock, @ptrCast(&sa), &sl)) != .SUCCESS) return 0;
        return addrFromStorage(&sa).getPort();
    }

    /// Run the event loop until the process exits. Blocking.
    pub fn run(self: *QuicServer) !void {
        while (true) {
            self.pumpOnce();
            self.dispatch() catch |err| {
                // Allocation/registration failures are per-connection; the
                // listener keeps serving.
                std.log.warn("quic: dispatch error: {s}", .{@errorName(err)});
            };
        }
    }

    /// One event-loop iteration: drain the UDP socket into zquic, run timers
    /// and send queues, then dispatch connection work.
    fn pumpOnce(self: *QuicServer) void {
        self.zserver.resetDriveSendBudgets();
        var fds = [1]std.posix.pollfd{.{
            .fd = self.zserver.sock,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = std.posix.poll(&fds, 10) catch {};
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            var buf: [io_mod.MAX_DATAGRAM_SIZE]u8 = undefined;
            while (true) {
                var sa: std.posix.sockaddr.storage = undefined;
                var sl: std.posix.socklen_t = @sizeOf(@TypeOf(sa));
                const n = compat.recvfrom(self.zserver.sock, &buf, std.posix.MSG.DONTWAIT, @ptrCast(&sa), &sl) catch break;
                self.zserver.feedPacket(buf[0..n], addrFromStorage(&sa));
            }
        }
        self.zserver.processPendingWork();
    }

    /// Scan zquic's connection table: spawn sessions for new connections,
    /// forward inbound frames, drain outbound responses, tear down finished
    /// connections.
    fn dispatch(self: *QuicServer) !void {
        var done_buf: std.ArrayListUnmanaged(u64) = .empty;
        defer done_buf.deinit(self.gpa);

        for (&self.zserver.conns, 0..) |*slot, i| {
            if (slot.*) |zconn| {
                if (self.qc_by_slot[i] == null and zconn.phase == .connected) {
                    const qc = try self.gpa.create(QuicConnection);
                    qc.* = QuicConnection.init(self.gpa, self.io, self.eng, self.registry, zconn);
                    qc.thread = std.Thread.spawn(.{}, sessionThread, .{qc}) catch |err| {
                        std.log.warn("quic listener: failed to spawn session thread: {s}", .{@errorName(err)});
                        self.gpa.destroy(qc);
                        continue;
                    };
                    self.qc_by_slot[i] = qc;
                    std.log.info("quic: connection accepted ({d})", .{qc.state.id});
                }
                if (self.qc_by_slot[i]) |qc| {
                    self.drainInbound(zconn, qc);
                    self.drainOutbound(zconn, qc);
                    // A session that finished its control handshake marks the
                    // connection done; the whole QUIC connection closes. The
                    // response (e.g. GOODBYE) was already drained above, so the
                    // peer sees the final frame before CONNECTION_CLOSE.
                    if (qc.close_requested.load(.acquire)) {
                        self.zserver.closeConnection(zconn, 0, "goodbye");
                        qc.close_requested.store(false, .monotonic);
                    }
                    if (zconn.draining or zconn.phase == .closed) {
                        // Release every raw-app slot so zquic's reap can free
                        // the connection, then unwind the session.
                        self.releaseAllSlots(zconn);
                        self.teardownSession(qc);
                        self.qc_by_slot[i] = null;
                        continue;
                    }
                    // Handler-acknowledged streams: release slots + parse state.
                    done_buf.clearRetainingCapacity();
                    qc.done.drainAll(self.gpa, &done_buf);
                    for (done_buf.items) |sid| {
                        _ = io_mod.releaseRawAppStream(zconn, sid, self.gpa);
                        if (qc.parse.getPtr(sid)) |ps| {
                            ps.deinit(self.gpa);
                            _ = qc.parse.remove(sid);
                        }
                        if (qc.streams.getPtr(sid)) |qs| {
                            // Free when the response is fully sent.
                            qs.*.handler_done = true;
                        }
                    }
                    // Free response streams that are fully sent and done.
                    var finished: std.ArrayListUnmanaged(*QuicStream) = .empty;
                    var it = qc.streams.iterator();
                    while (it.next()) |entry| {
                        const qs = entry.value_ptr.*;
                        qs.mutex.lockUncancelable(qs.io);
                        const is_finished = qs.handler_done and qs.fin_sent and qs.sent == qs.send.items.len;
                        qs.mutex.unlock(qs.io);
                        if (is_finished) try finished.append(self.gpa, qs);
                    }
                    for (finished.items) |qs| {
                        _ = qc.streams.remove(qs.stream_id);
                        qs.deinit();
                        self.gpa.destroy(qs);
                    }
                    finished.deinit(self.gpa);
                }
            } else if (self.qc_by_slot[i]) |qc| {
                // Slot reaped: the connection is gone; unwind the session.
                self.teardownSession(qc);
                self.qc_by_slot[i] = null;
            }
        }
    }

    /// Forward newly received bytes from raw-app slots into frame parse state
    /// and hand complete frames to the session handler.
    fn drainInbound(self: *QuicServer, zconn: *io_mod.ConnState, qc: *QuicConnection) void {
        for (&zconn.raw_app_streams) |*slot| {
            if (!slot.active) continue;
            const sid = slot.stream_id;
            const buf = slot.buf.items;
            if (buf.len == 0 and !slot.fin_received) continue;

            const qs = qc.getStream(sid);
            const ps = qc.getParse(sid);

            // Assemble frames from buf[ps.consumed..].
            while (true) {
                if (ps.header_len < proto.HEADER_SIZE) {
                    const need = proto.HEADER_SIZE - ps.header_len;
                    const have = buf.len -| ps.consumed;
                    if (have == 0) break;
                    const take_n = @min(need, have);
                    @memcpy(ps.header[ps.header_len..][0..take_n], buf[ps.consumed..][0..take_n]);
                    ps.consumed += take_n;
                    ps.header_len += take_n;
                    if (ps.header_len < proto.HEADER_SIZE) break;
                    ps.body_len = std.mem.readInt(u32, ps.header[0..4], .big);
                    if (ps.body_len < 1 or ps.body_len > proto.MAX_BODY_LENGTH) {
                        std.log.warn("quic: connection {d} sent a malformed frame; closing", .{qc.state.id});
                        self.zserver.closeConnection(zconn, 0x00, "malformed frame");
                        qc.close_requested.store(true, .monotonic);
                        return;
                    }
                    ps.payload_have = 0;
                }
                const payload_len: usize = @intCast(ps.body_len - 1);
                if (ps.payload_have < payload_len) {
                    if (ps.payload_have == 0) {
                        ps.payload.clearRetainingCapacity();
                        ps.payload.ensureTotalCapacity(self.gpa, payload_len) catch {
                            self.zserver.closeConnection(zconn, 0x01, "out of memory");
                            qc.close_requested.store(true, .monotonic);
                            return;
                        };
                        ps.payload.items.len = payload_len;
                    }
                    const target = ps.payload.items;
                    const need = target.len - ps.payload_have;
                    const have = buf.len -| ps.consumed;
                    if (have == 0) break;
                    const take_n = @min(need, have);
                    @memcpy(target[ps.payload_have..][0..take_n], buf[ps.consumed..][0..take_n]);
                    ps.payload_have += take_n;
                    ps.consumed += take_n;
                    if (ps.payload_have < target.len) break;
                }

                // Complete frame: hand a private copy to the handler.
                const msg_type: proto.Type = @enumFromInt(ps.header[4]);
                const payload = self.gpa.alloc(u8, payload_len) catch {
                    self.zserver.closeConnection(zconn, 0x01, "out of memory");
                    qc.close_requested.store(true, .monotonic);
                    return;
                };
                if (payload_len > 0) {
                    @memcpy(payload, ps.payload.items);
                }
                qc.mailbox.push(self.gpa, .{ .frame = .{ .stream = qs, .msg_type = msg_type, .payload = payload } }) catch {
                    self.gpa.free(payload);
                    self.zserver.closeConnection(zconn, 0x01, "out of memory");
                    qc.close_requested.store(true, .monotonic);
                    return;
                };
                ps.header_len = 0;
                ps.payload_have = 0;
            }

            // Peer finished its send side and every byte is forwarded: tell
            // the handler so it can FIN the response and release the stream.
            if (slot.fullyReceived() and !qc.eof_sent.contains(sid)) {
                qc.eof_sent.put(self.gpa, sid, {}) catch {};
                qc.mailbox.push(self.gpa, .{ .eof = qs }) catch {};
            }
        }
    }

    /// Send pending response bytes for every stream of a connection.
    fn drainOutbound(self: *QuicServer, zconn: *io_mod.ConnState, qc: *QuicConnection) void {
        var it = qc.streams.iterator();
        while (it.next()) |entry| {
            const qs = entry.value_ptr.*;
            qs.mutex.lockUncancelable(qs.io);
            defer qs.mutex.unlock(qs.io);
            if (qs.sent == qs.send.items.len) {
                if (qs.fin_pending and !qs.fin_sent) {
                    _ = self.zserver.sendRawStreamData(zconn, qs.stream_id, qs.wire_offset, &.{}, true);
                    qs.fin_sent = true;
                }
                continue;
            }
            const chunk_len = @min(16 * 1024, qs.send.items.len - qs.sent);
            const chunk = qs.send.items[qs.sent..][0..chunk_len];
            const fin = qs.fin_pending and qs.sent + chunk_len == qs.send.items.len;
            const accepted = self.zserver.sendRawStreamData(zconn, qs.stream_id, qs.wire_offset, chunk, fin);
            if (accepted > 0) {
                qs.wire_offset += accepted;
                qs.sent += accepted;
                if (fin) qs.fin_sent = true;
            }
        }
    }

    fn releaseAllSlots(self: *QuicServer, zconn: *io_mod.ConnState) void {
        for (&zconn.raw_app_streams) |*slot| {
            if (slot.active) {
                _ = io_mod.releaseRawAppStream(zconn, slot.stream_id, self.gpa);
            }
        }
    }

    /// Stop the session thread and free every connection-owned resource. Must
    /// be called from the event loop (the only thread that joins the session
    /// thread and frees QuicStreams).
    fn teardownSession(self: *QuicServer, qc: *QuicConnection) void {
        qc.mailbox.signalClosed();
        if (qc.thread) |t| {
            t.join();
            qc.thread = null;
        }
        if (qc.registered) {
            qc.registry.unregister(&qc.state);
            qc.registered = false;
        }
        if (qc.attachment) |*item| {
            // Release any staged reservation exactly once (uncancellable, so
            // the accounting can never leak). Mirror of the TCP handler.
            if (item.staging_reserved) {
                qc.eng.lockUncancelable(qc.io);
                qc.eng.abortStage(item.expected_length);
                qc.eng.unlock(qc.io);
            }
            item.deinit(qc.gpa);
            qc.attachment = null;
        }
        qc.mailbox.deinit(qc.gpa);
        qc.done.deinit(qc.gpa);
        var it = qc.streams.iterator();
        while (it.next()) |entry| {
            const qs = entry.value_ptr.*;
            qs.deinit();
            self.gpa.destroy(qs);
        }
        qc.streams.deinit(self.gpa);
        var pit = qc.parse.iterator();
        while (pit.next()) |entry| {
            entry.value_ptr.deinit(self.gpa);
        }
        qc.parse.deinit(self.gpa);
        qc.eof_sent.deinit(self.gpa);
        self.gpa.destroy(qc);
    }
};

/// The per-connection protocol session: pops frames from the mailbox and runs
/// them against the shared connection state, writing responses onto each
/// frame's stream.
fn sessionThread(qc: *QuicConnection) void {
    const gpa = qc.gpa;

    while (true) {
        const msg = qc.mailbox.pop() orelse break;
        switch (msg) {
            .close => break,
            .eof => |qs| {
                qs.mutex.lockUncancelable(qs.io);
                qs.fin_pending = true;
                qs.mutex.unlock(qs.io);
                qc.done.push(gpa, qs.stream_id) catch {};
            },
            .frame => |f| {
                defer gpa.free(f.payload);
                sessionHandleFrame(qc, f.stream, f.msg_type, f.payload) catch |err| {
                    std.log.warn("quic: connection {d} session error: {s}", .{ qc.state.id, @errorName(err) });
                    qc.close_requested.store(true, .monotonic);
                    break;
                };
            },
        }
    }
}

/// Handle one frame in the context of a QUIC connection session.
fn sessionHandleFrame(
    qc: *QuicConnection,
    stream: *QuicStream,
    msg_type: proto.Type,
    payload: []const u8,
) runadb.ConnError!void {
    const gpa = qc.gpa;
    const io = qc.io;
    const w = stream.streamWriter();

    if (msg_type == .hello) {
        // Control-stream handshake only (ADR-0023 §2.1). On any other stream,
        // or a second hello, the connection is protocol-violating.
        if (qc.authenticated or stream.stream_id != CONTROL_STREAM) return error.Protocol;
        if (payload.len != 4) return error.Protocol;
        const major = std.mem.readInt(u16, payload[0..2], .big);
        const minor = std.mem.readInt(u16, payload[2..4], .big);
        _ = minor;
        if (major != proto.PROTOCOL_VERSION_MAJOR) {
            try runadb.sendHelloError(w, "unsupported protocol version");
            try w.flush();
            qc.close_requested.store(true, .monotonic);
            return;
        }
        // Register only after the version check (bounded admission).
        qc.registry.register(&qc.state) catch |err| {
            try runadb.sendHelloError(w, switch (err) {
                error.RegistryFull => "instance connection table full",
                error.OutOfMemory => "instance out of memory",
                else => "connection rejected",
            });
            try w.flush();
            qc.close_requested.store(true, .monotonic);
            return;
        };
        qc.registered = true;
        try runadb.sendHelloOk(w, qc.state.credential);
        try w.flush();
        qc.authenticated = true;
        return;
    }

    // Every other frame type requires the control handshake first; query
    // streams carry requests, the control stream carries cancel/goodbye.
    if (!qc.authenticated) return error.Protocol;

    const keep_going = try runadb.handleFrame(gpa, io, w, msg_type, payload, qc.eng, qc.registry, &qc.state, &qc.attachment);
    if (!keep_going) {
        if (msg_type == .goodbye) {
            // The goodbye response was written on this stream; the connection
            // itself closes (the event loop sends CONNECTION_CLOSE).
            qc.close_requested.store(true, .monotonic);
        }
        return;
    }
}

fn addrFromStorage(sa: *const std.posix.sockaddr.storage) compat.Address {
    // Same raw copy zquic's loopback harness uses: the storage is larger than
    // compat.Address (the union is sized for sockaddr_in6), so memcpy the
    // leading bytes instead of a size-mismatched @bitCast.
    var a: compat.Address = undefined;
    @memcpy(std.mem.asBytes(&a)[0..@sizeOf(compat.Address)], std.mem.asBytes(sa)[0..@sizeOf(compat.Address)]);
    return a;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "quic transport constants match the ADR-0023 stream contract" {
    try std.testing.expectEqual(@as(u16, 5435), DEFAULT_PORT);
    try std.testing.expectEqualStrings("runadb", ALPN);
    try std.testing.expectEqual(@as(u64, 0), CONTROL_STREAM);
}

// ── In-process QUIC integration tests ───────────────────────────────────────
//
// These drive a real zquic client against the QuicServer event loop over a
// loopback UDP socket, exercising the ADR-0023 §2.1 stream contract end to
// end: the control-stream handshake, per-query streams, concurrent streams,
// and graceful close. The engine is real (scratch data directory), so
// statement execution runs through the same path the TCP listener uses.

const dev_cert_pem = @embedFile("dev-cert.pem");
const dev_key_pem = @embedFile("dev-key.pem");

/// Minimal zquic client driving the RunaDB Wire Protocol over raw application
/// streams (mirrors the SDK's QUIC transport, sdk/zig/transport/quic.zig).
const TestClient = struct {
    gpa: Allocator,
    client: *io_mod.Client,
    addr: compat.Address,
    /// The server event loop, pumped alongside the client: in-process tests
    /// share one thread, so both legs must be driven together.
    server: ?*QuicServer,
    /// Bytes consumed per stream from the raw-app receive buffer.
    consumed: std.AutoHashMap(u64, usize),

    fn connect(gpa: Allocator, server_port: u16) !TestClient {
        const addr = try compat.Address.parseIp4("127.0.0.1", server_port);
        const client = try gpa.create(io_mod.Client);
        errdefer gpa.destroy(client);
        try io_mod.Client.initInPlace(gpa, .{
            .host = "127.0.0.1",
            .port = server_port,
            .urls = &.{},
            .raw_application_streams = true,
            .alpn = ALPN,
        }, client);
        errdefer client.deinit();
        try client.startHandshake(addr);
        return .{
            .gpa = gpa,
            .client = client,
            .addr = addr,
            .server = null,
            .consumed = std.AutoHashMap(u64, usize).init(gpa),
        };
    }

    /// Pump both legs: the server event loop (dispatch included) and the
    /// client. Required whenever the client blocks on a send or receive: the
    /// server has no thread of its own in tests.
    fn pumpBoth(self: *TestClient) void {
        if (self.server) |qs| {
            qs.pumpOnce();
            qs.dispatch() catch {};
        }
        self.pump();
    }

    /// Pump only the server leg (no client keepalives/ACKs). Used by the
    /// idle-timeout regression: pumping the client would send keepalive
    /// PINGs that refresh the server's idle timer and defeat the reap.
    fn pumpServer(self: *TestClient) void {
        if (self.server) |qs| {
            qs.pumpOnce();
            qs.dispatch() catch {};
        }
    }

    fn deinit(self: *TestClient) void {
        self.consumed.deinit();
        self.client.deinit();
        self.gpa.destroy(self.client);
    }

    /// One event-loop iteration for the client leg.
    fn pump(self: *TestClient) void {
        // One embedder drive: reset the per-drive STREAM-send budget exactly
        // once, then drain sends, pump the socket, and flush (zquic contract,
        // mirroring the loopback harness in lib/zquic/src/transport/io.zig).
        self.client.resetDriveSendBudget();
        self.client.processPendingWork(self.addr);
        self.client.flushSendBatch();
        var fds = [1]std.posix.pollfd{.{
            .fd = self.client.sock,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = std.posix.poll(&fds, 5) catch {};
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            var buf: [io_mod.MAX_DATAGRAM_SIZE]u8 = undefined;
            while (true) {
                var sa: std.posix.sockaddr.storage = undefined;
                var sl: std.posix.socklen_t = @sizeOf(@TypeOf(sa));
                const n = compat.recvfrom(self.client.sock, &buf, std.posix.MSG.DONTWAIT, @ptrCast(&sa), &sl) catch break;
                self.client.feedPacket(buf[0..n]);
            }
        }
        self.client.processPendingWork(self.addr);
        self.client.flushSendBatch();
        self.client.flushDeferredAck();
    }

    fn openStream(self: *TestClient) !u64 {
        return self.client.tryOpenLocalBidiStream();
    }

    /// Write a complete protocol frame at the stream's absolute offset,
    /// half-closing the stream afterwards.
    fn sendFrame(self: *TestClient, stream_id: u64, msg_type: proto.Type, payload: []const u8) !void {
        if (payload.len > proto.MAX_BODY_LENGTH - 1) return error.MessageTooLarge;
        const body_len: u32 = @intCast(1 + payload.len);
        var header: [5]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], body_len, .big);
        header[4] = @intFromEnum(msg_type);
        var offset: u64 = 0;
        try self.sendAllAt(stream_id, &offset, &header);
        try self.sendAllAt(stream_id, &offset, payload);
        // Half-close the send side: the server treats the request as complete.
        // A FIN-only STREAM frame returns 0 from sendRawStreamData even when
        // accepted (there is no payload to count), so this is fire-and-forget.
        _ = self.client.sendRawStreamData(stream_id, offset, &.{}, true);
        self.client.flushSendBatch();
    }

    /// Send `data` at the stream's absolute offset (`offset` is advanced by
    /// the bytes accepted).
    fn sendAllAt(self: *TestClient, stream_id: u64, offset: *u64, data: []const u8) !void {
        const deadline = compat.milliTimestamp() + 15_000;
        var sent: usize = 0;
        while (sent < data.len) {
            if (compat.milliTimestamp() >= deadline) return error.TestTimeout;
            const acc = self.client.sendRawStreamData(stream_id, offset.*, data[sent..], false);
            if (acc == 0) {
                self.pumpBoth();
                continue;
            }
            offset.* += acc;
            sent += acc;
        }
    }

    /// Read exactly `buf.len` bytes from a stream, pumping until available.
    fn readAll(self: *TestClient, stream_id: u64, buf: []u8) !void {
        const deadline = compat.milliTimestamp() + 15_000;
        var filled: usize = 0;
        while (filled < buf.len) {
            if (compat.milliTimestamp() >= deadline) return error.TestTimeout;
            const avail = self.client.rawAppRecvBuffer(stream_id) orelse &.{};
            const consumed = self.consumed.get(stream_id) orelse 0;
            const unread = avail.len -| consumed;
            if (unread > 0) {
                const take_n = @min(buf.len - filled, unread);
                @memcpy(buf[filled..][0..take_n], avail[consumed..][0..take_n]);
                try self.consumed.put(stream_id, consumed + take_n);
                filled += take_n;
                continue;
            }
            if (self.client.rawAppStreamFullyReceived(stream_id)) return error.EndOfStream;
            if (self.client.conn.draining or self.client.conn.phase == .closed) return error.ConnectionClosed;
            self.pumpBoth();
        }
    }

    /// Read one protocol frame: (type, payload). The payload is caller-owned.
    fn readFrame(self: *TestClient, stream_id: u64) !struct { proto.Type, []u8 } {
        var header: [proto.HEADER_SIZE]u8 = undefined;
        try self.readAll(stream_id, &header);
        const body_len = std.mem.readInt(u32, header[0..4], .big);
        if (body_len < 1 or body_len > proto.MAX_BODY_LENGTH) {
            return error.Protocol;
        }
        const payload = try self.gpa.alloc(u8, @intCast(body_len - 1));
        errdefer self.gpa.free(payload);
        try self.readAll(stream_id, payload);
        return .{ @enumFromInt(header[4]), payload };
    }

    fn releaseStream(self: *TestClient, stream_id: u64) void {
        _ = self.client.releaseRawAppStream(stream_id);
    }
};

/// Build a minimal `document_insert` IR request (op 4, zero fields).
fn buildInsertIr(gpa: Allocator, collection: []const u8, id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 5, .big); // FORMAT_VERSION (src/flow/ir.zig)
    try out.appendSlice(gpa, buf[0..2]);
    std.mem.writeInt(u64, &buf, 0, .big); // model_revision
    try out.appendSlice(gpa, &buf);
    try out.append(gpa, 4); // document_insert
    try appendIrString(gpa, &out, collection);
    try appendIrString(gpa, &out, id);
    std.mem.writeInt(u16, buf[0..2], 0, .big); // zero fields
    try out.appendSlice(gpa, buf[0..2]);
    return out.toOwnedSlice(gpa);
}

fn appendIrString(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len > std.math.maxInt(u16)) return error.StringTooLarge;
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, @intCast(s.len), .big);
    try out.appendSlice(gpa, &buf);
    try out.appendSlice(gpa, s);
}

fn bindEphemeralUdp(_: Allocator) !struct { sock: std.posix.socket_t, port: u16 } {
    const sock = try compat.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    errdefer compat.close(sock);
    const bind_addr = try compat.Address.parseIp4("127.0.0.1", 0);
    try compat.bind(sock, &bind_addr.any, bind_addr.getOsSockLen());
    var sa: std.posix.sockaddr.storage = undefined;
    var sl: std.posix.socklen_t = @sizeOf(@TypeOf(sa));
    if (std.posix.errno(std.posix.system.getsockname(sock, @ptrCast(&sa), &sl)) != .SUCCESS) return error.GetSockNameFailed;
    return .{ .sock = sock, .port = addrFromStorage(&sa).getPort() };
}

// End-to-end QUIC test: control-stream handshake, per-query streams,
// concurrent streams, and graceful close against a real engine.
test "quic transport: handshake, query round-trip, concurrent streams, goodbye" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-quic-integration";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var registry = registry_mod.Registry.init(gpa, io, .{});
    defer registry.deinit();

    const bound = try bindEphemeralUdp(gpa);
    const qs = try QuicServer.init(gpa, io, .{
        .port = 0,
        .cert_pem = dev_cert_pem,
        .key_pem = dev_key_pem,
    }, &eng, &registry, bound.sock);
    defer qs.deinit();
    try std.testing.expect(qs.boundPort() > 0);

    var client = try TestClient.connect(gpa, qs.boundPort());
    defer client.deinit();
    client.server = qs;

    // ── TLS 1.3 handshake ──
    {
        // Pump both legs until the TLS 1.3 handshake completes. The server
        // reaches `.connected` in the same exchange, so the client phase is
        // the observable proxy for both sides.
        const deadline = compat.milliTimestamp() + 10_000;
        while (client.client.conn.phase != .connected) {
            if (compat.milliTimestamp() >= deadline) return error.TestTimeout;
            client.pumpBoth();
        }
        try std.testing.expectEqual(io_mod.ConnPhase.connected, client.client.conn.phase);
    }

    // ── Control stream (client bidi stream 0): hello → hello_ok ──
    const control = try client.openStream();
    try std.testing.expectEqual(@as(u64, CONTROL_STREAM), control);
    var cancel_credential: [proto.CANCEL_CREDENTIAL_LENGTH]u8 = undefined;
    {
        var hello_payload: [4]u8 = undefined;
        std.mem.writeInt(u16, hello_payload[0..2], proto.PROTOCOL_VERSION_MAJOR, .big);
        std.mem.writeInt(u16, hello_payload[2..4], proto.PROTOCOL_VERSION_MINOR, .big);
        try client.sendFrame(control, .hello, &hello_payload);

        const frame = try client.readFrame(control);
        defer gpa.free(frame[1]);
        try std.testing.expectEqual(proto.Type.hello_ok, frame[0]);
        const payload = frame[1];
        if (payload.len < 4 + proto.CANCEL_CREDENTIAL_LENGTH) return error.Protocol;
        const ver_len = std.mem.readInt(u32, payload[0..4], .big);
        if (4 + ver_len + proto.CANCEL_CREDENTIAL_LENGTH != payload.len) return error.Protocol;
        const version = payload[4 .. 4 + ver_len];
        try std.testing.expect(std.mem.eql(u8, "RunaDB", version[0..6]));
        @memcpy(&cancel_credential, payload[4 + ver_len ..][0..proto.CANCEL_CREDENTIAL_LENGTH]);
    }

    // ── Query stream: document_insert IR → command_complete ──
    const s1 = try client.openStream();
    try std.testing.expectEqual(@as(u64, 4), s1);
    {
        const ir = try buildInsertIr(gpa, "customers", "c1");
        defer gpa.free(ir);
        var wrapped: [2 + 64 * 1024]u8 = undefined;
        std.mem.writeInt(u16, wrapped[0..2], proto.IR_FORMAT_VERSION, .big);
        @memcpy(wrapped[2..][0..ir.len], ir);
        try client.sendFrame(s1, .flow_ir, wrapped[0 .. 2 + ir.len]);

        const frame = try client.readFrame(s1);
        defer gpa.free(frame[1]);
        try std.testing.expectEqual(proto.Type.row_description, frame[0]);
        const frame2 = try client.readFrame(s1);
        defer gpa.free(frame2[1]);
        try std.testing.expectEqual(proto.Type.row_data, frame2[0]);
        const frame3 = try client.readFrame(s1);
        defer gpa.free(frame3[1]);
        try std.testing.expectEqual(proto.Type.command_complete, frame3[0]);
    }

    // ── Query stream: Flow emit over the inserted table → one row ──
    const s2 = try client.openStream();
    try std.testing.expectEqual(@as(u64, 8), s2);
    {
        const source = "from customers\n| emit { id }";
        var payload: [4 + 64 * 1024]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], @intCast(source.len), .big);
        @memcpy(payload[4..][0..source.len], source);
        try client.sendFrame(s2, .flow_source, payload[0 .. 4 + source.len]);

        const frame = try client.readFrame(s2);
        defer gpa.free(frame[1]);
        try std.testing.expectEqual(proto.Type.row_description, frame[0]);
        const frame2 = try client.readFrame(s2);
        defer gpa.free(frame2[1]);
        try std.testing.expectEqual(proto.Type.row_data, frame2[0]);
        const frame3 = try client.readFrame(s2);
        defer gpa.free(frame3[1]);
        try std.testing.expectEqual(proto.Type.command_complete, frame3[0]);
        // The server must FIN its response side once the result sequence ends.
        {
            const deadline = compat.milliTimestamp() + 10_000;
            while (!client.client.rawAppStreamFullyReceived(s2)) {
                if (compat.milliTimestamp() >= deadline) return error.TestTimeout;
                client.pumpBoth();
            }
        }
    }

    // ── Concurrent query streams (12 and 16 in flight together) ──
    const c1 = try client.openStream();
    const c2 = try client.openStream();
    try std.testing.expectEqual(@as(u64, 12), c1);
    try std.testing.expectEqual(@as(u64, 16), c2);
    {
        const source = "from customers\n| emit { id }";
        var payload: [4 + 64 * 1024]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], @intCast(source.len), .big);
        @memcpy(payload[4..][0..source.len], source);
        try client.sendFrame(c1, .flow_source, payload[0 .. 4 + source.len]);
        try client.sendFrame(c2, .flow_source, payload[0 .. 4 + source.len]);

        // Drain both result sequences (row_description, row_data,
        // command_complete) and verify both complete.
        const deadline = compat.milliTimestamp() + 10_000;
        while (true) {
            if (compat.milliTimestamp() >= deadline) return error.TestTimeout;
            const f1 = client.client.rawAppStreamFullyReceived(c1);
            const f2 = client.client.rawAppStreamFullyReceived(c2);
            if (f1 and f2) break;
            client.pumpBoth();
        }
        // Parse each stream's frames: 3 frames per stream.
        for ([_]u64{ c1, c2 }) |sid| {
            const a = try client.readFrame(sid);
            defer gpa.free(a[1]);
            try std.testing.expectEqual(proto.Type.row_description, a[0]);
            const b = try client.readFrame(sid);
            defer gpa.free(b[1]);
            try std.testing.expectEqual(proto.Type.row_data, b[0]);
            const c = try client.readFrame(sid);
            defer gpa.free(c[1]);
            try std.testing.expectEqual(proto.Type.command_complete, c[0]);
            client.releaseStream(sid);
        }
        client.releaseStream(s1);
        client.releaseStream(s2);
    }

    // ── Goodbye on a query stream: server replies and closes the connection ──
    const s3 = try client.openStream();
    {
        try client.sendFrame(s3, .goodbye, "");
        const frame = try client.readFrame(s3);
        defer gpa.free(frame[1]);
        try std.testing.expectEqual(proto.Type.goodbye, frame[0]);
    }

    // The server should have sent CONNECTION_CLOSE and the client's
    // connection should drain/close; pump until it does.
    {
        const deadline = compat.milliTimestamp() + 10_000;
        while (client.client.conn.phase != .closed and !client.client.conn.draining) {
            if (compat.milliTimestamp() >= deadline) return error.TestTimeout;
            client.pumpBoth();
        }
    }
    // The registry must have revoked the connection.
    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());
}

test "quic transport: client handshake failure leaves no registry entries" {
    // Connecting to a port with no listener must fail the client's
    // handshake rather than registering anything server-side.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-quic-refused";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var registry = registry_mod.Registry.init(gpa, io, .{});
    defer registry.deinit();

    const bound = try bindEphemeralUdp(gpa);
    const qs = try QuicServer.init(gpa, io, .{
        .port = 0,
        .cert_pem = dev_cert_pem,
        .key_pem = dev_key_pem,
    }, &eng, &registry, bound.sock);
    defer qs.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());
}

test "quic transport: idle timeout reaps a silent connection" {
    // RFC 9000 §10.1: the listener reaps a connection whose peer sends
    // nothing for the effective idle timeout (min of local config and the
    // peer's advertised value). The session is torn down and unregistered.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-quic-idle";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var registry = registry_mod.Registry.init(gpa, io, .{});
    defer registry.deinit();

    const bound = try bindEphemeralUdp(gpa);
    const qs = try QuicServer.init(gpa, io, .{
        .port = 0,
        .cert_pem = dev_cert_pem,
        .key_pem = dev_key_pem,
        .idle_timeout_ms = 1200,
    }, &eng, &registry, bound.sock);
    defer qs.deinit();
    try std.testing.expect(qs.boundPort() > 0);

    var client = try TestClient.connect(gpa, qs.boundPort());
    defer client.deinit();
    client.server = qs;

    // TLS 1.3 handshake plus the control-stream hello exchange.
    {
        const deadline = compat.milliTimestamp() + 10_000;
        while (client.client.conn.phase != .connected) {
            if (compat.milliTimestamp() >= deadline) return error.TestTimeout;
            client.pumpBoth();
        }
        const control = try client.openStream();
        try std.testing.expectEqual(@as(u64, CONTROL_STREAM), control);
        var hello_payload: [4]u8 = undefined;
        std.mem.writeInt(u16, hello_payload[0..2], proto.PROTOCOL_VERSION_MAJOR, .big);
        std.mem.writeInt(u16, hello_payload[2..4], proto.PROTOCOL_VERSION_MINOR, .big);
        try client.sendFrame(control, .hello, &hello_payload);
        const frame = try client.readFrame(control);
        defer gpa.free(frame[1]);
        try std.testing.expectEqual(proto.Type.hello_ok, frame[0]);
    }
    try std.testing.expectEqual(@as(usize, 1), registry.liveCount());

    // Go silent: pump only the server leg so the client cannot refresh the
    // server's idle timer with ACKs or keepalive PINGs. The listener must
    // reap the connection after ~1200 ms, tear down the session, and
    // unregister it.
    {
        const deadline = compat.milliTimestamp() + 10_000;
        while (registry.liveCount() != 0) {
            if (compat.milliTimestamp() >= deadline) return error.TestTimeout;
            client.pumpServer();
            try Io.sleep(io, .fromMilliseconds(20), .awake);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());
}
