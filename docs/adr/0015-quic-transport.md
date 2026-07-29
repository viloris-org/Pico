# Transport Layer: Replace TCP with zquic (Pure Zig QUIC)

## Status

Accepted

## Context

Pico currently uses TCP plus custom binary frames (`[4-byte length][1-byte type][payload]`). With the native ecosystem in ADR-0009, TCP imposes three constraints: serialized requests prevent query pipelining, transport encryption must be implemented above the transport, and TCP head-of-line blocking prevents stream multiplexing.

An initial PQUIC design would have implemented an OLTP-specific QUIC subset, but review identified unacceptable costs: no forward secrecy, custom congestion control and retransmission, and a custom TLS replacement. Switching to Cloudflare’s `quiche` would add C and BoringSSL dependencies, conflicting with Pico’s zero-external-dependency strategy.

The decision is therefore to vendor the mature pure-Zig implementation [zigstack/zquic](https://github.com/zigstack/zquic) under `lib/zquic/`. It implements RFC 9000/9001/9002, uses the Zig 0.16.x toolchain, and has no external dependencies. QUIC owns transport security, multiplexing, and reliability; Pico continues to define the application protocol and authentication.

## Decision

**Switch transport from TCP to zquic (QUIC).** Vendor zquic in `lib/zquic/` as a Git submodule and import it as a Zig module. Pico messages such as SQL query, RowData, and CommandComplete run over QUIC streams.

### 1. Architecture

```
Pico application protocol
  Authentication (ADR-0014): Ed25519 challenge-response + permission bitmap
  Message layer (`clint/proto/def.zig`): Query | RowDescription | RowData | ...
QUIC transport (zquic)
  Multiplexed streams | TLS 1.3 | Congestion control | Retransmission + ACK | UDP socket
UDP
```

### 2. Application Protocol Mapping

Stream 0 is the control stream for authentication and metadata. Streams 1+ carry independent queries; each query opens a stream and closes it after its result sequence.

```
Client -> Server: [type=0x10] [SQL text]              // Query
Server -> Client: [type=0x11] [columns...]            // RowDescription
Server -> Client: [type=0x12] [values...]             // RowData
Server -> Client: [type=0x13] [tag] [rows]            // CommandComplete
Server -> Client: [type=0x14] [code] [msg]            // ServerError
```

Message types and serialization remain unchanged and reuse `clint/proto/def.zig`.

### 3. Authentication and Transport Security

| Responsibility | Owner | Description |
|---|---|---|
| Transport encryption | zquic (TLS 1.3) | AEAD encryption and forward secrecy |
| Server identity | zquic (TLS certificate) | Self-signed or CA-issued certificate |
| User authentication | Pico application | Ed25519 challenge-response on Stream 0 (ADR-0014) |
| Permission checks | Pico application | Bitmap check before every statement |

```text
Client -> Server: Stream 0 CLIENT_HELLO (key_fingerprint)
Server -> Client: Stream 0 SERVER_CHALLENGE (nonce)
Client -> Server: Stream 0 CLIENT_AUTH (signature)
Server -> Client: Stream 0 SERVER_OK (permissions) or SERVER_ERROR
```

After authentication, the server records `(quic_connection, user, permissions)` and associates all query streams with that context.

### 4. Build Integration

```zig
const zquic_mod = b.addModule("zquic", .{
    .root_source_file = b.path("lib/zquic/src/zquic.zig"),
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zquic", zquic_mod);
```

The embedder API is pure Zig:

```zig
var server = try zquic.Server.init(allocator, .{
    .cert_pem = cert_data,
    .key_pem = key_data,
    .alpn = &.{"pico"},
});
var conn = try server.accept();
defer conn.deinit();
const written = try conn.sendStreamData(stream_id, buf, .fin);
const read = try conn.recvStreamData(stream_id, buf, &fin);
```

No C bindings or BoringSSL are required.

### 5. TCP Compatibility

```text
Pico Server listens on two ports during migration:
  TCP :5434 — existing Pico protocol
  UDP :5435 — QUIC / zquic (primary protocol)
```

```bash
pico-cli                  # QUIC by default (UDP 5435)
pico-cli --tcp            # TCP fallback (5434)
```

Remove TCP after the transition period.

### 6. Connection Lifecycle

```
CLOSED -> QUIC_ESTABLISHED -> AUTHENTICATED -> query streams 1..N -> CLOSED
```

The first transition uses UDP and TLS 1.3; the second is the Ed25519 handshake on Stream 0; streams 1..N can run concurrently without blocking one another. A QUIC close or idle timeout returns the connection to `CLOSED`.

## Decision Drivers

1. QUIC provides multiplexing, TLS 1.3 with forward secrecy, congestion control, and loss recovery.
2. Pure Zig avoids BoringSSL and C compiler dependencies.
3. Authentication remains Pico’s Ed25519 application-layer system.
4. Existing `clint/proto/def.zig` codecs require no message changes.
5. TCP remains available during a gradual migration.
6. Vendoring `lib/zquic/` permits exact version pinning and local patches.

## Consequences

- Add `lib/zquic/` as a roughly 3 MB Git submodule dependency and track upstream security updates.
- Add QUIC listeners under `src/net/` and QUIC connections under `clint/zig/connection.zig`.
- Generate self-signed certificates for development and tests.
- Test handshake, Stream 0 authentication, concurrent query streams, graceful close, certificate failures, and interoperability.

## Delivery

1. Integrate zquic through `build.zig` module import.
2. Add the QUIC listener and connection manager under `src/net/`.
3. Connect Stream 0 to ADR-0014 authentication and attach the existing codec to QUIC streams.
4. Add the client QUIC implementation and `--udp` (default) / `--tcp` options.
5. Add handshake, authentication, query round-trip, and concurrent-stream integration tests.
6. Define the TCP transition end condition and removal plan.
