//! RunaDB Zig SDK — public entry point.
//!
//! The SDK implements the RunaDB Client product surface: it speaks only the
//! RunaDB Wire Protocol (defined in `clint/proto/`) and documented Runa Flow /
//! Runa Query IR, and never opens a data directory or imports server modules.
//!
//! Transports (ADR-0023): QUIC is the target default (vendored zquic) and is
//! verified against the server QUIC listener in this checkout (roadmap Phase
//! 9); native TCP remains implemented and verified, deprecated per ADR-0024.
//! There is no silent fallback — select the kind explicitly in
//! `transport.Config`.
//!
//! Usage:
//! ```zig
//! var conn = try sdk.Connection.connect(gpa, io, .{
//!     .host = "127.0.0.1",
//!     .kind = .quic, // verified; .tcp also verified (deprecated, ADR-0024)
//! });
//! defer conn.deinit(io);
//! var result = try conn.executeFlow(arena, "from customer\n| emit { id }");
//! while (try result.nextRow(arena)) |row| {
//!     const id = row.int(row.indexOf("id").?);
//! }
//! ```

pub const proto = @import("clint_proto");
pub const codec = @import("codec.zig");
pub const connection = @import("connection.zig");
pub const transport = @import("transport.zig");
pub const tcp_transport = @import("transport/tcp.zig");
pub const quic_transport = @import("transport/quic.zig");

pub const Connection = connection.Connection;
pub const QueryResult = connection.QueryResult;
pub const Row = connection.Row;
pub const Failure = connection.Failure;
pub const Message = codec.Message;
pub const ProtocolError = codec.ProtocolError;
/// Connection establishment configuration (host, port, transport kind,
/// QUIC server-certificate pin, timeouts). See `transport.zig`.
pub const Config = transport.Config;
pub const TransportKind = transport.Kind;

/// RunaDB Wire Protocol version spoken by this SDK (v3.0; `clint/proto`).
pub const protocol_major = proto.PROTOCOL_VERSION_MAJOR;
pub const protocol_minor = proto.PROTOCOL_VERSION_MINOR;
/// Canonical Runa Query IR format version written by this SDK.
pub const ir_format_version = proto.IR_FORMAT_VERSION;

test {
    _ = codec;
    _ = connection;
    _ = transport;
    _ = tcp_transport;
    _ = quic_transport;
}
