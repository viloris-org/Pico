//! Concurrent runtime tests (roadmap Phase 6 Part A).
//!
//! Phase 6 serializes each connection's statement execution behind the engine's
//! statement-execution lock and serves each connection on its own thread, so
//! these tests drive real concurrency:
//!
//! * A wire-level test that binds a listener, runs the same accept loop as
//!   `src/net/server.zig` on a background thread, opens several client
//!   connections concurrently, and verifies snapshot-consistent reads, ordered
//!   results, committed-write visibility, and clean closes.
//! * An engine-level test that spawns reader and writer threads, each taking the
//!   engine lock around engine calls, and verifies the serialization-lock
//!   discipline and snapshot stability under concurrency.
//! * A focused test that flow result column metadata is owned and survives a DDL
//!   that would invalidate a borrowed name.
//!
//! The wire test uses raw sockets with the shared `clint_proto` framing, not the
//! client library, honoring module boundaries: `src/net` may import `clint_proto`
//! but not `clint/`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flow = @import("../flow/exec.zig");
const engine_mod = @import("../storage/engine.zig");
const value = @import("../storage/value.zig");
const document_mod = @import("../storage/document.zig");
const registry_mod = @import("registry.zig");
const server = @import("server.zig");
const proto = @import("clint_proto");

// ── Engine-level concurrency ──

/// Writer: assigns ids under the engine lock (so commit order equals id order)
/// and autocommits them through the single-writer coordinator. Because the lock
/// is held across the id assignment and the synchronous commit, id `i` commits
/// at `commit_seq` `i+1`; a reader at watermark `s` sees exactly ids {0..s-1}.
const EngineWriter = struct {
    eng: *engine_mod.Engine,
    io: Io,
    next_id: *std.atomic.Value(u64),
    start: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    writes: usize,
    table: []const u8,

    fn run(self: EngineWriter) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        for (0..self.writes) |_| {
            self.eng.lock(self.io) catch {
                self.failed.store(true, .release);
                return;
            };
            const id = self.next_id.fetchAdd(1, .monotonic);
            const result = self.eng.insert(self.table, &.{.{ .int = @intCast(id) }});
            self.eng.unlock(self.io);
            result catch {
                self.failed.store(true, .release);
                return;
            };
        }
    }
};

/// Reader: takes the engine lock, records the published watermark, scans the
/// table at that snapshot, and verifies the result is exactly the versions
/// committed at or before the snapshot. Returns false on any mismatch; the
/// verification runs inside the lock but only sets the shared failure flag, so a
/// failure cannot deadlock other threads on a leaked lock.
const EngineReader = struct {
    eng: *engine_mod.Engine,
    io: Io,
    start: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    reads: usize,
    table: []const u8,

    fn run(self: EngineReader) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        for (0..self.reads) |_| {
            const ok = self.readOnce() catch {
                self.failed.store(true, .release);
                return;
            };
            if (!ok) {
                self.failed.store(true, .release);
                return;
            }
        }
    }

    fn readOnce(self: EngineReader) !bool {
        self.eng.lock(self.io) catch return false;
        defer self.eng.unlock(self.io);
        const s = self.eng.publishedSeq();
        var res = try self.eng.selectAll(self.table, s);
        defer res.deinit();
        // Exactly the versions committed at/before the snapshot: id i commits
        // at commit_seq i+1, so at watermark s the visible ids are {0..s-1},
        // in insertion (ascending) order, each stamped with its commit sequence.
        if (@as(u64, res.rows.len) != s) return false;
        for (res.rows, 0..) |row, index| {
            if (row.values[0].int != @as(i64, @intCast(index))) return false;
            if (row.created_seq != @as(u64, index) + 1) return false;
            if (row.created_seq > s) return false;
        }
        return true;
    }
};

test "engine serializes concurrent readers and writers on the statement lock" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-runtime-engine-concurrent";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();

    var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
    defer cols[0].deinit(gpa);
    try eng.createTable("t", &cols);

    const writers = 4;
    const reader_count = 4;
    const writes_per_writer = 50;
    const reads_per_reader = 40;
    const total_writes = writers * writes_per_writer;

    var next_id = std.atomic.Value(u64).init(0);
    var start = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);

    var writer_threads: [writers]std.Thread = undefined;
    for (&writer_threads) |*th| {
        th.* = try std.Thread.spawn(.{}, EngineWriter.run, .{EngineWriter{
            .eng = &eng,
            .io = io,
            .next_id = &next_id,
            .start = &start,
            .failed = &failed,
            .writes = writes_per_writer,
            .table = "t",
        }});
    }
    var reader_threads: [reader_count]std.Thread = undefined;
    for (&reader_threads) |*th| {
        th.* = try std.Thread.spawn(.{}, EngineReader.run, .{EngineReader{
            .eng = &eng,
            .io = io,
            .start = &start,
            .failed = &failed,
            .reads = reads_per_reader,
            .table = "t",
        }});
    }
    start.store(true, .release);
    for (&writer_threads) |th| th.join();
    for (&reader_threads) |th| th.join();
    try std.testing.expect(!failed.load(.acquire));

    // Consistent final state: every id committed exactly once.
    var final = try eng.selectAll("t", eng.publishedSeq());
    defer final.deinit();
    try std.testing.expectEqual(@as(usize, total_writes), final.rows.len);
    for (final.rows, 0..) |row, index| {
        try std.testing.expectEqual(@as(i64, @intCast(index)), row.values[0].int);
    }
}

// ── Owned result column metadata ──

test "flow result column metadata is owned and survives a later DDL" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-runtime-owned-columns";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var cols = [_]value.Column{
        .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text },
    };
    defer for (&cols) |*c| c.deinit(gpa);
    try eng.createTable("customer", &cols);
    var name_val: value.Value = .{ .text = try gpa.dupe(u8, "Ada") };
    defer name_val.deinit(gpa);
    try eng.insert("customer", &.{ .{ .int = 1 }, name_val });

    var request = try flow.compile(gpa, "from customer\n| emit { id, name }");
    defer request.deinit(gpa);
    var result = try flow.execute(gpa, &eng, &request);
    defer result.deinit();

    // Drop and re-add a column: a borrowed column name would now be freed
    // memory. The owned result metadata must still read correctly.
    try eng.dropColumn("customer", "name", false);
    var name2: value.Column = .{ .name = try gpa.dupe(u8, "name2"), .type_tag = .text };
    defer name2.deinit(gpa);
    try eng.addColumn("customer", name2, false);

    try std.testing.expectEqualStrings("id", result.columns[0]);
    try std.testing.expectEqualStrings("name", result.columns[1]);
    try std.testing.expectEqualStrings("Ada", result.cells[0][1].?);
}

// ── Wire-level threaded-listener test ──

/// Accept loop identical in shape to `server.zig`'s listener: it accepts on the
/// main thread and hands each stream to `server.dispatchConnection`, which
/// spawns the per-connection handler thread. The test stops it by setting
/// `stop` and connecting a sentinel that unblocks the pending accept.
const AcceptLoop = struct {
    gpa: Allocator,
    io: Io,
    listener: *Io.net.Server,
    eng: *engine_mod.Engine,
    registry: *registry_mod.Registry,
    stop: *std.atomic.Value(bool),

    fn run(self: AcceptLoop) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch |err| {
                if (self.stop.load(.acquire)) return;
                std.log.err("runtime test accept failed: {s}", .{@errorName(err)});
                continue;
            };
            if (self.stop.load(.acquire)) {
                // The sentinel connect that unblocked accept; the test closes it.
                return;
            }
            server.dispatchConnection(self.gpa, self.io, stream, self.eng, self.registry);
        }
    }
};

/// Minimal client over the shared `clint_proto` framing, used instead of the
/// client library to respect module boundaries. `connect` initializes in place
/// so the reader/writer never dangle into a temporary's buffers.
const TestClient = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    read_buf: [16 * 1024]u8,
    write_buf: [16 * 1024]u8,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    closed: bool = false,
    /// Cancellation credential delivered in HELLO_OK; names this Connection
    /// for the Server's cancellation routing.
    cancel_credential: [proto.CANCEL_CREDENTIAL_LENGTH]u8 = .{0} ** proto.CANCEL_CREDENTIAL_LENGTH,

    fn connect(self: *TestClient, gpa: Allocator, io: Io, port: u16) !void {
        const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .read_buf = undefined,
            .write_buf = undefined,
            .reader = undefined,
            .writer = undefined,
            .closed = false,
        };
        self.reader = stream.reader(io, &self.read_buf);
        self.writer = stream.writer(io, &self.write_buf);

        var hello_payload: [4]u8 = undefined;
        std.mem.writeInt(u16, hello_payload[0..2], proto.PROTOCOL_VERSION_MAJOR, .big);
        std.mem.writeInt(u16, hello_payload[2..4], proto.PROTOCOL_VERSION_MINOR, .big);
        try self.sendFrame(.hello, &hello_payload);
        try self.writer.interface.flush();

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const frame = try readFrame(&self.reader.interface, arena.allocator());
        if (frame.msg_type != .hello_ok) return error.Protocol;
        // HELLO_OK payload: [u32 version length][version][16-byte credential].
        const payload = frame.payload;
        if (payload.len < 4) return error.Protocol;
        const version_len = std.mem.readInt(u32, payload[0..4], .big);
        if (payload.len != 4 + version_len + proto.CANCEL_CREDENTIAL_LENGTH) return error.Protocol;
        @memcpy(&self.cancel_credential, payload[4 + version_len ..]);
    }

    fn sendFrame(self: *TestClient, msg_type: proto.Type, payload: []const u8) !void {
        if (payload.len > proto.MAX_BODY_LENGTH - 1) return error.MessageTooLarge;
        const body_len: u32 = @intCast(1 + payload.len);
        var header: [5]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], body_len, .big);
        header[4] = @intFromEnum(msg_type);
        try self.writer.interface.writeAll(&header);
        if (payload.len > 0) try self.writer.interface.writeAll(payload);
    }

    /// Best-effort teardown: sends GOODBYE and closes the stream without
    /// waiting for the reply. Safe to call more than once.
    fn close(self: *TestClient) void {
        if (self.closed) return;
        self.closed = true;
        self.sendFrame(.goodbye, &.{}) catch {};
        self.writer.interface.flush() catch {};
        self.stream.close(self.io);
    }

    /// Clean-close protocol check: GOODBYE round-trips a reply, then the
    /// stream closes.
    fn goodbye(self: *TestClient) !void {
        if (self.closed) return;
        try self.sendFrame(.goodbye, &.{});
        try self.writer.interface.flush();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const frame = try readFrame(&self.reader.interface, arena.allocator());
        if (frame.msg_type != .goodbye) return error.Protocol;
        self.closed = true;
        self.stream.close(self.io);
    }
};

/// Client-side writer: connects and autocommits `count` document inserts on
/// collection "docs", each carrying a 1-based `seq` field. Every insert is
/// drained before the next, so writes commit in order.
const DocumentWriter = struct {
    gpa: Allocator,
    io: Io,
    port: u16,
    start: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    count: usize,

    fn run(self: DocumentWriter) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        var client: TestClient = undefined;
        client.connect(self.gpa, self.io, self.port) catch {
            self.failed.store(true, .release);
            return;
        };
        defer client.close();
        for (0..self.count) |i| {
            if (insertDocument(self.gpa, &client, i + 1, @intCast(i + 1))) |_| {} else |_| {
                self.failed.store(true, .release);
                return;
            }
        }
    }
};

/// Send one document_insert over an established client connection and drain the
/// response. `id` and `seq` are 1-based.
fn insertDocument(gpa: Allocator, client: *TestClient, id: usize, seq: i64) !void {
    const id_text = try std.fmt.allocPrint(gpa, "d{d}", .{id});
    defer gpa.free(id_text);
    const ir = try buildDocumentInsertIr(gpa, "docs", id_text, seq);
    defer gpa.free(ir);
    var wrapped = try gpa.alloc(u8, 2 + ir.len);
    defer gpa.free(wrapped);
    std.mem.writeInt(u16, wrapped[0..2], proto.IR_FORMAT_VERSION, .big);
    @memcpy(wrapped[2..], ir);
    try client.sendFrame(.flow_ir, wrapped);
    try client.writer.interface.flush();
    try drainMutationResponse(client, gpa);
}

// ── Wire framing helpers ──

const Frame = struct { msg_type: proto.Type, payload: []const u8 };

fn readFrame(reader: *Io.Reader, arena: Allocator) !Frame {
    const header = try reader.takeArray(proto.HEADER_SIZE);
    const body_len = std.mem.readInt(u32, header[0..4], .big);
    if (body_len < 1) return error.Protocol;
    if (body_len > proto.MAX_BODY_LENGTH) return error.MessageTooLarge;
    const msg_type: proto.Type = @enumFromInt(header[4]);
    const payload_len: usize = @intCast(body_len - 1);
    const payload = try arena.alloc(u8, payload_len);
    if (payload_len > 0) {
        const body = try reader.take(payload_len);
        @memcpy(payload, body);
    }
    return .{ .msg_type = msg_type, .payload = payload };
}

/// Parse a single-int-column ROW_DATA payload into its integer value.
fn parseSingleIntColumn(payload: []const u8) !u64 {
    if (payload.len < 2) return error.Protocol;
    const col_count = std.mem.readInt(u16, payload[0..2], .big);
    if (col_count != 1) return error.Protocol;
    var pos: usize = 2;
    if (pos >= payload.len) return error.Protocol;
    const null_flag = payload[pos];
    pos += 1;
    if (null_flag != 0) return error.Protocol;
    if (payload.len - pos < 4) return error.Protocol;
    const len = std.mem.readInt(u32, payload[pos..][0..4], .big);
    pos += 4;
    if (payload.len - pos < len) return error.Protocol;
    return std.fmt.parseInt(u64, payload[pos .. pos + len], 10);
}

/// Send a FLOW_SOURCE emit and collect the single integer column of every row.
/// The caller owns the returned slice.
fn execCollectInts(client: *TestClient, gpa: Allocator, source: []const u8) ![]u64 {
    var payload: [4 + 128]u8 = undefined;
    if (source.len > 128) return error.MessageTooLarge;
    std.mem.writeInt(u32, payload[0..4], @intCast(source.len), .big);
    @memcpy(payload[4..][0..source.len], source);
    try client.sendFrame(.flow_source, payload[0 .. 4 + source.len]);
    try client.writer.interface.flush();

    var ints: std.ArrayList(u64) = .empty;
    errdefer ints.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    while (true) {
        const frame = try readFrame(&client.reader.interface, aa);
        switch (frame.msg_type) {
            .row_description => {},
            .row_data => try ints.append(gpa, try parseSingleIntColumn(frame.payload)),
            .command_complete => break,
            .server_error => return error.ServerError,
            else => return error.Protocol,
        }
    }
    return ints.toOwnedSlice(gpa);
}

/// Read the relation table `items`; it is seeded and never mutated, so every
/// result is the stable snapshot {1, 2, 3} even while other connections commit.
fn readItems(client: *TestClient, gpa: Allocator) ![]u64 {
    return execCollectInts(client, gpa, "from items\n| emit { id }");
}

/// Read all documents in `docs` and verify the `seq` values are a contiguous
/// ascending prefix [1..n]; returns n. A document insert is atomic under the
/// engine lock, so a concurrent read always observes a whole committed prefix.
fn readDocsPrefix(client: *TestClient, gpa: Allocator) !usize {
    const seqs = try execCollectInts(client, gpa, "from docs\n| emit { seq }");
    defer gpa.free(seqs);
    var expected: u64 = 1;
    for (seqs) |seq| {
        if (seq != expected) return error.NonContiguousDocumentRead;
        expected += 1;
    }
    return seqs.len;
}

/// Drain a mutation response (ROW_DESCRIPTION, ROW_DATA, COMMAND_COMPLETE).
fn drainMutationResponse(client: *TestClient, gpa: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    while (true) {
        const frame = try readFrame(&client.reader.interface, aa);
        switch (frame.msg_type) {
            .row_description, .row_data => {},
            .command_complete => break,
            .server_error => return error.ServerError,
            else => return error.Protocol,
        }
    }
}

/// Canonical IR for a document_insert with one int field `seq`, matching the
/// server's `decodeDocumentInsert` (src/flow/ir.zig) and the client encoder.
fn buildDocumentInsertIr(gpa: Allocator, collection: []const u8, id: []const u8, seq: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendU16(&out, gpa, proto.IR_FORMAT_VERSION);
    try appendU64(&out, gpa, 0); // model revision
    try out.append(gpa, 4); // document_insert operation
    try appendIrString(&out, gpa, collection);
    try appendIrString(&out, gpa, id);
    try appendU16(&out, gpa, 1); // one field
    try appendIrString(&out, gpa, "seq");
    try out.append(gpa, 1); // int value tag
    try appendI64(&out, gpa, seq);
    return out.toOwnedSlice(gpa);
}

fn appendU16(out: *std.ArrayList(u8), gpa: Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .big);
    try out.appendSlice(gpa, &buf);
}

fn appendU64(out: *std.ArrayList(u8), gpa: Allocator, v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .big);
    try out.appendSlice(gpa, &buf);
}

fn appendI64(out: *std.ArrayList(u8), gpa: Allocator, v: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, v, .big);
    try out.appendSlice(gpa, &buf);
}

fn appendIrString(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    if (s.len > std.math.maxInt(u16)) return error.StringTooLarge;
    try appendU16(out, gpa, @intCast(s.len));
    try out.appendSlice(gpa, s);
}

test "threaded listener serves concurrent connections with snapshot-consistent, ordered results" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-runtime-threaded-listener";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();

    // Seed a relation table so a reader has a stable snapshot to observe while
    // a writer commits on another connection.
    {
        var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
        defer cols[0].deinit(gpa);
        try eng.createTable("items", &cols);
        try eng.insert("items", &.{.{ .int = 1 }});
        try eng.insert("items", &.{.{ .int = 2 }});
        try eng.insert("items", &.{.{ .int = 3 }});
    }

    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var registry = registry_mod.Registry.init(gpa, io, .{});
    defer registry.deinit();

    var stop = std.atomic.Value(bool).init(false);
    const accept_thread = try std.Thread.spawn(.{}, AcceptLoop.run, .{AcceptLoop{
        .gpa = gpa,
        .io = io,
        .listener = &listener,
        .eng = &eng,
        .registry = &registry,
        .stop = &stop,
    }});

    // A reader is established first; a writer then commits documents on a
    // second connection while the reader keeps reading.
    var reader: TestClient = undefined;
    try reader.connect(gpa, io, port);
    defer reader.close();

    var writer_start = std.atomic.Value(bool).init(false);
    var writer_failed = std.atomic.Value(bool).init(false);
    const writer_thread = try std.Thread.spawn(.{}, DocumentWriter.run, .{DocumentWriter{
        .gpa = gpa,
        .io = io,
        .port = port,
        .start = &writer_start,
        .failed = &writer_failed,
        .count = 30,
    }});

    writer_start.store(true, .release);
    for (0..8) |_| {
        // A relation read stays snapshot-stable {1,2,3} while the writer commits.
        const ids = try readItems(&reader, gpa);
        defer gpa.free(ids);
        try std.testing.expectEqual(@as(usize, 3), ids.len);
        try std.testing.expectEqual(@as(u64, 1), ids[0]);
        try std.testing.expectEqual(@as(u64, 2), ids[1]);
        try std.testing.expectEqual(@as(u64, 3), ids[2]);
    }
    for (0..8) |_| {
        // Concurrent document reads observe only whole committed prefixes: the
        // engine lock serializes a document write against a document read.
        _ = try readDocsPrefix(&reader, gpa);
    }
    writer_thread.join();
    try std.testing.expect(!writer_failed.load(.acquire));

    // A committed write is visible to a later reader.
    const final_count = try readDocsPrefix(&reader, gpa);
    try std.testing.expectEqual(@as(usize, 30), final_count);

    // Clean close: GOODBYE round-trips a reply, then the stream closes.
    try reader.goodbye();

    // Results come back in order across several statements on one connection.
    var ordered: TestClient = undefined;
    try ordered.connect(gpa, io, port);
    defer ordered.close();
    try std.testing.expectEqual(@as(usize, 30), try readDocsPrefix(&ordered, gpa));
    for (0..5) |_| {
        _ = try readDocsPrefix(&ordered, gpa);
    }
    try ordered.goodbye();

    // Wait for every connection handler thread to unregister and finish before
    // tearing the engine down, so no handler outlives the test.
    for (0..1000) |_| {
        if (registry.liveCount() == 0) break;
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());

    // Stop the accept loop: the sentinel connect unblocks the pending accept;
    // the loop sees `stop` and exits without dispatching it.
    stop.store(true, .release);
    const sentinel = listener.socket.address.connect(io, .{ .mode = .stream }) catch null;
    accept_thread.join();
    if (sentinel) |s| s.close(io);
}

// ── Mid-statement cancellation delivery (Phase 6 Part B) ──

/// Extract the error code from a SERVER_ERROR payload:
/// [severity u8][code_len u32 BE][code][msg_len u32 BE][msg].
fn parseServerErrorCode(payload: []const u8) ![]const u8 {
    if (payload.len < 1 + 4) return error.Protocol;
    const code_len = std.mem.readInt(u32, payload[1..][0..4], .big);
    if (payload.len < 1 + 4 + code_len) return error.Protocol;
    return payload[1 + 4 ..][0..code_len];
}

/// Read the next frame and expect exactly the delivered CANCELED outcome
/// (`SERVER_ERROR` with code `RF1006`): the statement was aborted by a
/// `CANCEL_REQUEST` routed while it was scanning.
fn expectCanceledOutcome(client: *TestClient, gpa: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const frame = try readFrame(&client.reader.interface, arena.allocator());
    if (frame.msg_type != .server_error) return error.Protocol;
    const code = try parseServerErrorCode(frame.payload);
    if (!std.mem.eql(u8, code, "RF1006")) return error.WrongCanceledCode;
}

test "a CANCEL_REQUEST aborts a mid-statement scan and keeps the connection usable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-runtime-mid-statement-cancel";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();

    // Seed a document collection so the target has a real scan to abort. The
    // deterministic part of the test is the engine lock: the test holds it, so
    // the target's handler is provably inside its statement (blocked at the
    // statement lock) when the cancel lands, and cannot finish before the mark.
    {
        try eng.createDocument("docs");
        var fields: [1]document_mod.Field = undefined;
        fields[0] = .{ .path = try gpa.dupe(u8, "seq"), .item = .{ .int = 0 } };
        defer fields[0].deinit(gpa);
        var id_buf: [16]u8 = undefined;
        for (0..2_000) |i| {
            fields[0].item = .{ .int = @intCast(i) };
            const id = std.fmt.bufPrint(&id_buf, "d{d}", .{i}) catch unreachable;
            try eng.insertDocument("docs", id, &fields);
        }
    }

    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var registry = registry_mod.Registry.init(gpa, io, .{});
    defer registry.deinit();

    var stop = std.atomic.Value(bool).init(false);
    const accept_thread = try std.Thread.spawn(.{}, AcceptLoop.run, .{AcceptLoop{
        .gpa = gpa,
        .io = io,
        .listener = &listener,
        .eng = &eng,
        .registry = &registry,
        .stop = &stop,
    }});

    // Hold the engine statement lock; the target handler blocks on it.
    try eng.lock(io);
    var lock_held = true;
    defer if (lock_held) eng.unlock(io);

    var target: TestClient = undefined;
    try target.connect(gpa, io, port);
    defer target.close();

    // The target submits a scan over the seeded collection and does not read;
    // its handler thread blocks at the statement lock we hold.
    const source = "from docs\n| emit { seq }";
    var payload: [4 + 128]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], @intCast(source.len), .big);
    @memcpy(payload[4..][0..source.len], source);
    try target.sendFrame(.flow_source, payload[0 .. 4 + source.len]);
    try target.writer.interface.flush();

    // Give the handler time to register and reach the statement lock. It must:
    // with the lock held, the statement cannot complete before the cancel.
    for (0..1000) |_| {
        if (registry.liveCount() >= 1) break;
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try Io.sleep(io, .fromMilliseconds(20), .awake);

    // A second connection delivers the cancel with the target's credential.
    var canceler: TestClient = undefined;
    try canceler.connect(gpa, io, port);
    defer canceler.close();
    try canceler.sendFrame(.cancel_request, &target.cancel_credential);
    try canceler.writer.interface.flush();

    // The mark lands on the executing statement: the registry reports a hit.
    var hit = false;
    for (0..1000) |_| {
        if (registry.cancel_hits == 1) {
            hit = true;
            break;
        }
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(hit);

    // Release the lock: the target's scan runs, observes the mark at its first
    // bounded work unit, and delivers the CANCELED outcome over the wire.
    eng.unlock(io);
    lock_held = false;
    try expectCanceledOutcome(&target, gpa);

    // The Connection stays usable: its next statement executes normally.
    const ids = try execCollectInts(&target, gpa, "from docs\n| emit { seq }\n| limit 2");
    defer gpa.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(@as(u64, 0), ids[0]);
    try std.testing.expectEqual(@as(u64, 1), ids[1]);

    try target.goodbye();
    try canceler.goodbye();

    // Wait for every connection handler thread to unregister before tearing
    // the engine down, so no handler outlives the test.
    for (0..1000) |_| {
        if (registry.liveCount() == 0) break;
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());

    stop.store(true, .release);
    const sentinel = listener.socket.address.connect(io, .{ .mode = .stream }) catch null;
    accept_thread.join();
    if (sentinel) |s| s.close(io);
}

// ── Slow-consumer and connection-loss fault tests (Phase 6) ──

test "a slow reader does not hold the engine lock and closes cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-runtime-slow-consumer";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();

    // Seed a collection whose full emit materializes ~30 MiB of rows: far more
    // than any pair of socket buffers can hold, so a Connection that never
    // reads provably keeps its handler blocked in the result send.
    {
        try eng.createDocument("bigdocs");
        var text_buf: [3072]u8 = undefined;
        @memset(&text_buf, 'x');
        const text = try gpa.dupe(u8, &text_buf);
        defer gpa.free(text);
        var fields: [2]document_mod.Field = undefined;
        fields[0] = .{ .path = try gpa.dupe(u8, "seq"), .item = .{ .int = 0 } };
        defer gpa.free(fields[0].path);
        fields[1] = .{ .path = try gpa.dupe(u8, "payload"), .item = .{ .text = text } };
        defer gpa.free(fields[1].path);
        var id_buf: [16]u8 = undefined;
        for (0..10_000) |i| {
            fields[0].item = .{ .int = @intCast(i) };
            const id = std.fmt.bufPrint(&id_buf, "d{d}", .{i}) catch unreachable;
            try eng.insertDocument("bigdocs", id, &fields);
        }
    }

    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var registry = registry_mod.Registry.init(gpa, io, .{});
    defer registry.deinit();

    var stop = std.atomic.Value(bool).init(false);
    const accept_thread = try std.Thread.spawn(.{}, AcceptLoop.run, .{AcceptLoop{
        .gpa = gpa,
        .io = io,
        .listener = &listener,
        .eng = &eng,
        .registry = &registry,
        .stop = &stop,
    }});

    // The slow Connection submits the large emit and never reads, so its
    // handler blocks in the result send once the socket buffers fill.
    var slow: TestClient = undefined;
    try slow.connect(gpa, io, port);
    const source = "from bigdocs\n| emit { payload }";
    var payload: [4 + 128]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], @intCast(source.len), .big);
    @memcpy(payload[4..][0..source.len], source);
    try slow.sendFrame(.flow_source, payload[0 .. 4 + source.len]);
    try slow.writer.interface.flush();

    // Observe the statement lock go busy (the handler is materializing the
    // ~30 MiB result under the lock) and then free (it released the lock to
    // start sending). The send cannot finish because slow never reads, so at
    // the free moment the handler is provably blocked in the send with the
    // lock released: a slow reader does not hold the engine lock.
    var observed_busy = false;
    var acquired = false;
    for (0..1000) |_| {
        if (eng.tryLock()) {
            if (observed_busy) {
                acquired = true;
                break;
            }
            eng.unlock(io);
        } else {
            observed_busy = true;
        }
        try Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(observed_busy);
    try std.testing.expect(acquired);
    eng.unlock(io);

    // Another Connection still makes progress while slow's send is blocked.
    var fast: TestClient = undefined;
    try fast.connect(gpa, io, port);
    const seqs = try execCollectInts(&fast, gpa, "from bigdocs\n| emit { seq }\n| limit 1");
    defer gpa.free(seqs);
    try std.testing.expectEqual(@as(usize, 1), seqs.len);
    try std.testing.expectEqual(@as(u64, 0), seqs[0]);
    try fast.goodbye();

    // Connection loss: closing the slow stream unblocks its send, the handler
    // cleans up (revoking the credential), and the registry empties.
    slow.close();
    for (0..2000) |_| {
        if (registry.liveCount() == 0) break;
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());

    stop.store(true, .release);
    const sentinel = listener.socket.address.connect(io, .{ .mode = .stream }) catch null;
    accept_thread.join();
    if (sentinel) |s| s.close(io);
}
