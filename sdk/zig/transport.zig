//! RunaDB Zig SDK — transport abstraction (ADR-0023 §2).
//!
//! A `Transport` is one bidirectional byte stream carrying RunaDB Wire
//! Protocol messages. TCP provides a single stream per Connection; QUIC
//! provides the control stream (client bidi stream 0) plus one stream per
//! request (client bidi streams 4, 8, 12, …). The `Connection` in
//! `connection.zig` is the only consumer of the concrete transports.

const std = @import("std");

pub const Kind = enum {
    /// QUIC (vendored zquic, ADR-0015) — the SDK's target default transport.
    /// Requires a server QUIC listener; until roadmap Phase 9 lands, a QUIC
    /// connect fails with a defined error (`HandshakeTimeout`,
    /// `QuicRejected`, or `CertificateMismatch`) instead of falling back.
    quic,
    /// Native TCP — the transport currently implemented and verified against
    /// the RunaDB Server in this checkout.
    tcp,
};

/// QUIC listener port (ADR-0015 §5).
pub const DEFAULT_QUIC_PORT: u16 = 5435;
/// TCP listener port (current default).
pub const DEFAULT_TCP_PORT: u16 = 5434;
/// TLS ALPN identifier negotiated with the server (ADR-0015 §2).
pub const ALPN: []const u8 = "runadb";

pub const Config = struct {
    host: []const u8,
    /// Port; defaults to the kind's default (QUIC 5435, TCP 5434).
    port: ?u16 = null,
    kind: Kind = .quic,
    /// QUIC server identity: PEM of the pinned server certificate (including
    /// self-signed development certificates). The SDK compares the SHA-256
    /// digest of the presented leaf certificate and fails with
    /// `CertificateMismatch` on difference. When null, the connection
    /// proceeds and the presented certificate fingerprint is exposed on the
    /// Connection for trust-on-first-use inspection (ADR-0023 §2.3).
    server_cert_pem: ?[]const u8 = null,
    /// Upper bound for connection establishment: TCP connect or QUIC
    /// handshake plus the `hello` exchange.
    connect_timeout_ms: u32 = 10_000,
    /// Upper bound for a QUIC stream read while awaiting result messages.
    /// TCP retains blocking stream semantics in this checkout.
    read_timeout_ms: u32 = 30_000,

    pub fn effectivePort(self: Config) u16 {
        return self.port orelse switch (self.kind) {
            .quic => DEFAULT_QUIC_PORT,
            .tcp => DEFAULT_TCP_PORT,
        };
    }
};

/// Result of a successful QUIC handshake: which stream numbers the server
/// must use for control and queries (ADR-0023 §2.1). Client-initiated
/// bidirectional stream IDs are 0, 4, 8, … (RFC 9000 §2.1).
pub const StreamMap = struct {
    /// Control stream: `hello` / `hello_ok` / `hello_error`, `cancel_request`,
    /// `goodbye`.
    pub const control: u64 = 0;
    /// First query stream; each request opens the next client bidi stream.
    pub const first_query: u64 = 4;
    pub const stride: u64 = 4;
};
