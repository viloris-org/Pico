//! Pico Wire Protocol — shared message type definitions.
//! Used by both Pico Server (src/net/pico.zig) and Pico Client (clint/).
//! Version: v0.1 (draft — not yet stable).

pub const PROTOCOL_VERSION_MAJOR: u16 = 0;
pub const PROTOCOL_VERSION_MINOR: u16 = 1;

/// Message type identifiers.
pub const Type = enum(u8) {
    /// Client → Server: initiates connection, carries protocol version.
    hello = 0x01,
    /// Server → Client: accepts connection, carries server version string.
    hello_ok = 0x02,
    /// Server → Client: rejects connection with a reason.
    hello_error = 0x03,

    /// Client → Server: executes a SQL statement.
    query = 0x10,
    /// Server → Client: column metadata for result rows.
    row_description = 0x11,
    /// Server → Client: a single row of data.
    row_data = 0x12,
    /// Server → Client: statement finished successfully.
    command_complete = 0x13,
    /// Server → Client: statement failed.
    server_error = 0x14,

    /// Either side: clean close.
    goodbye = 0xFF,

    _,
};

// ── Message payload structures ──

/// Payload of hello (client → server).
pub const Hello = packed struct {
    version_major: u16,
    version_minor: u16,
};

/// Payload of hello_ok (server → client).
/// Followed by a length-prefixed server version string.

/// Payload of hello_error (server → client).
/// Followed by a length-prefixed reason string.

/// Payload of query (client → server).
/// Followed by a length-prefixed SQL text.

/// Payload of row_description (server → client).
pub const RowDescription = packed struct {
    column_count: u16,
};
/// For each column, a length-prefixed name string follows.

/// Payload of row_data (server → client).
pub const RowData = packed struct {
    column_count: u16,
};
/// For each column, a null flag (u8, 0=not null, 1=null) followed by a
/// length-prefixed text value (omitted if null).

/// Payload of command_complete (server → client).
/// Followed by a length-prefixed tag string (e.g. "INSERT 0 1", "SELECT 3").
pub const CommandComplete = packed struct {
    affected_rows: u64,
};

/// Payload of error (server → client).
/// Followed by severity byte, then length-prefixed code and message strings.
pub const Error = packed struct {
    severity: u8, // 0=INFO, 1=WARNING, 2=ERROR, 3=FATAL
};

/// Payload of goodbye (either side).
/// Followed by a length-prefixed reason string.

// ── Wire format helpers ──

/// Maximum message body length (1 MB).
pub const MAX_BODY_LENGTH: usize = 1024 * 1024;

/// Minimum header size: 4-byte length + 1-byte type.
pub const HEADER_SIZE: usize = 5;

/// String on the wire: u32 (big-endian length) + UTF-8 bytes.
pub const MAX_STRING_LENGTH: usize = 64 * 1024;
