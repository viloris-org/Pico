//! RunaDB Client — Zig client library.
//!
//! Provides a high-level API for connecting to a RunaDB Server,
//! submitting Runa Flow requests, and processing results.
//!
//! Usage:
//! ```zig
//! const io = std.io.getStdIo();
//! var conn = try clint.connect(allocator, io, "127.0.0.1", 5434);
//! defer conn.close(io);
//! const result = try conn.executeFlow(arena, "from customer\n| emit { id }");
//! while (try result.next(arena)) |msg| { ... }
//! ```

pub const proto = @import("clint_proto");
pub const codec = @import("codec.zig");
pub const connection = @import("connection.zig");

pub const Connection = connection.Connection;
pub const QueryResult = connection.QueryResult;
pub const Message = codec.Message;
pub const ProtocolError = codec.ProtocolError;
