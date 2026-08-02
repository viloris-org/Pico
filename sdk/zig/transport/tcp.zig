//! RunaDB Zig SDK — TCP transport (currently implemented and verified).
//!
//! One TCP connection carries the Connection's whole byte stream: `hello`
//! negotiation, requests, result sequences, cancellation, and `goodbye` all
//! share it, matching the RunaDB Wire Protocol v3.0 Connection contract.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const codec = @import("../codec.zig");

pub const TcpConn = struct {
    allocator: Allocator,
    io: Io,
    stream: Io.net.Stream,
    read_buf: [16 * 1024]u8,
    write_buf: [4 * 1024]u8,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,

    /// Heap-allocated so the reader/writer self-references (`&self.read_buf`)
    /// survive the `Connection` returning by value; the old in-place approach
    /// required a re-bind on every method call.
    pub fn connect(allocator: Allocator, io: Io, host: []const u8, port: u16) !*TcpConn {
        const addr = try Io.net.IpAddress.parse(host, port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);

        const self = try allocator.create(TcpConn);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .read_buf = undefined,
            .write_buf = undefined,
            .reader = undefined,
            .writer = undefined,
        };
        self.reader = stream.reader(io, &self.read_buf);
        self.writer = stream.writer(io, &self.write_buf);
        return self;
    }

    /// The Connection's single byte stream.
    pub fn byteStream(self: *TcpConn) codec.Stream {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn close(self: *TcpConn) void {
        self.stream.close(self.io);
    }

    pub fn deinit(self: *TcpConn) void {
        self.close();
        self.allocator.destroy(self);
    }

    const vtable = codec.Stream.VTable{
        .readAll = tcpReadAll,
        .writeAll = tcpWriteAll,
        .flush = tcpFlush,
        .fin = tcpFin,
        .close = tcpCloseStream,
    };

    /// Read exactly `buf.len` bytes. The underlying `Io.Reader` asserts that
    /// `take(n)` never exceeds its internal buffer capacity, so large payloads
    /// (up to the 1 MiB protocol body limit) are consumed in bounded chunks.
    fn tcpReadAll(ctx: *anyopaque, buf: []u8) anyerror!void {
        const self: *TcpConn = @ptrCast(@alignCast(ctx));
        var filled: usize = 0;
        while (filled < buf.len) {
            const remaining = buf.len - filled;
            const buffered = self.reader.interface.bufferedLen();
            if (buffered > 0) {
                const take_n = @min(remaining, buffered);
                const chunk = try self.reader.interface.take(take_n);
                @memcpy(buf[filled..][0..take_n], chunk);
                filled += take_n;
            } else {
                self.reader.interface.fillMore() catch |err| {
                    return switch (err) {
                        error.EndOfStream => error.EndOfStream,
                        else => error.ReadFailed,
                    };
                };
            }
        }
    }

    fn tcpWriteAll(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *TcpConn = @ptrCast(@alignCast(ctx));
        self.writer.interface.writeAll(bytes) catch return error.ReadFailed;
    }

    fn tcpFlush(ctx: *anyopaque) anyerror!void {
        const self: *TcpConn = @ptrCast(@alignCast(ctx));
        self.writer.interface.flush() catch return error.ReadFailed;
    }

    fn tcpFin(ctx: *anyopaque) anyerror!void {
        _ = ctx; // TCP has no per-request half-close; the Connection owns lifetime.
    }

    fn tcpCloseStream(ctx: *anyopaque) void {
        _ = ctx; // Closing the Connection closes its single stream.
    }
};
