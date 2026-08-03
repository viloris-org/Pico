# Official SDK Directory and the Zig SDK QUIC Transport Contract

## Status

Accepted. Amends ADR-0011 (Co-Locate RunaDB Client and RunaDB Server in One
Repository) and pins the client side of ADR-0015 (Replace TCP with zquic).

## Context

ADR-0011 places future language SDKs in subdirectories under `clint/`
(`clint/zig/`, `clint/go/`). The checked-out Zig SDK currently lives at
`clint/zig/` and communicates over native TCP only.

ADR-0015 decides that QUIC (vendored zquic) replaces TCP as the RunaDB
transport and sketches the application-protocol mapping (Stream 0 control
stream, query streams, ALPN `runadb`), but leaves the client implementation
and the precise stream contract open. Roadmap Phase 9 ("QUIC Transition and
TCP Retirement") makes the server-side QUIC listener and the client QUIC
default dependent on completed verification; neither exists in this
checkout.

Two problems must be resolved before the Zig SDK can target QUIC:

1. **Layout.** SDKs are independently released products with their own
   versioning and packaging (ADR-0010, ADR-0011). A top-level `sdk/<lang>/`
   directory states that boundary in the repository layout, keeps `clint/`
   for the CLI and the shared protocol, and lets future SDKs (`sdk/go/`,
   `sdk/python/`) sit beside `sdk/zig/` without being mistaken for CLI
   internals.
2. **Transport contract.** The client-side mapping of RunaDB Wire Protocol
   messages onto QUIC streams must be precise enough for the SDK today and
   for the server QUIC listener (Phase 9) later, and must define failure
   behavior while the server has no QUIC listener.

## Decision

### 1. Official SDKs live at the top level under `sdk/<lang>/`

- `clint/` keeps the shared protocol definitions (`clint/proto/`), the CLI
  (`clint/main.zig`), and other RunaDB Client tooling.
- The checked-out Zig SDK migrates from `clint/zig/` to `sdk/zig/` in this
  change. `clint/zig/` is removed; no duplicate client code is retained.
- Future official language SDKs are created under `sdk/<lang>/`; ADR-0011's
  "future SDKs under `clint/`" sentence is superseded for official SDKs.
- The SDK still depends only on `clint/proto/` (the versioned shared wire
  contract), zquic (`lib/zquic/`), and the standard library. It never opens
  a data directory and never imports `src/`.

### 2. The Zig SDK transport contract (client side of ADR-0015)

The SDK exposes one `Connection` API over a pluggable transport. Message
types and serialization are unchanged and reuse `clint/proto/def.zig`.

#### 2.1 QUIC stream mapping

One TLS 1.3 connection (ALPN `runadb`, zquic) carries:

| Stream | Role | Messages |
| --- | --- | --- |
| Client bidi stream 0 (control) | Connection lifecycle | `hello` → `hello_ok` / `hello_error`; `cancel_request`; `goodbye` |
| Client bidi streams 4, 8, 12, … (one per request) | One request + its result sequence | request messages (`flow_source`, `flow_ir`, attachment staging) then `row_description`*, `row_data`*, `command_complete` / `server_error` |

- The client writes the complete request on a query stream and half-closes
  its send side (STREAM FIN). The server responds on the same stream and
  FINs when the result sequence ends. The SDK reads until
  `command_complete`, `server_error`, or `goodbye`, then releases the
  stream.
- The control stream stays open for the Connection lifetime; it carries the
  v3.0 `hello` exchange (the current implemented handshake), fire-and-forget
  `cancel_request` between statements, and `goodbye`. ADR-0014's Ed25519
  challenge-response remains target design; when it lands it replaces the
  `hello` messages on the control stream, not the stream model.
- The sequential statement contract is preserved: the SDK processes one
  result sequence at a time per Connection. QUIC's concurrent-stream
  capability is not exposed through the SDK API yet; concurrent statements
  are future work.

#### 2.2 Defaults and fallback

- `Connection.connect` defaults to QUIC on UDP port 5435 (ADR-0015 §5).
- There is no silent TCP fallback: a QUIC connect against a server without
  a QUIC listener fails with a defined error (`HandshakeTimeout`,
  `QuicRejected`, `CertificateMismatch`, or `QuicUnavailable`). Silent
  fallback is rejected because it would mask deployment errors and protocol
  regressions; an explicit opt-in fallback policy is deferred until Phase 9
  telemetry exists.
- The CLI and integration tests pin `.tcp` (port 5434) in this checkout and
  flip the CLI default to QUIC only after Phase 9 exit criteria pass
  (ROADMAP.md). The CLI exposes `--quic` and `--tcp` flags.

#### 2.3 Server identity on QUIC

zquic does not verify the server's X.509 chain; the SDK pins the server
leaf certificate. `Config.server_cert_pem` accepts the PEM of the expected
(self-signed or CA-issued) certificate; the SDK compares the SHA-256 digest
of the presented leaf with the pinned certificate and fails with
`CertificateMismatch` on difference. Without a pin, the connection proceeds
and the SDK exposes the presented certificate fingerprint for
trust-on-first-use inspection. Full chain validation is future work.

#### 2.4 Status

- **Implemented and verified in this checkout:** TCP transport, `hello`
  negotiation, Flow/IR requests, evidence payloads, document and graph
  ingestion, cancellation, and the CLI `--tcp` path, against the
  independently built server.
- **Implemented and verified in this checkout:** the server QUIC listener
  (`src/net/quic.zig`, roadmap Phase 9). It implements the §2.1 stream
  contract exactly: control stream 0 carries `hello` / `hello_ok` /
  `hello_error`, fire-and-forget `cancel_request`, and `goodbye`; query
  streams (client bidi 4, 8, 12, …) carry one request + result sequence and
  the server FINs its response side when the result sequence ends. The
  listener is exercised end to end by the SDK QUIC client (`runa-cli
  --quic`) against the independently built server binary, and by the
  in-process integration test in `src/net/quic.zig` (handshake, query
  round-trip, concurrent streams, goodbye, idle teardown).
- **Implemented and verified in this checkout:** certificate pinning
  regressions and idle-timeout behavior against the SDK client. The SDK
  integration suite connects through the public Connection API over QUIC to
  an independently built QUIC-only server: no pin exposes the presented leaf
  digest, the correct pinned certificate connects, a wrong pinned
  certificate fails with `CertificateMismatch` (no silent fallback), a
  request round-trip and document insert/read-back pass, and a connection
  idle past the listener's configured `max_idle_timeout` is reaped so the
  next request fails with the SDK's bounded read timeout. The listener's
  local idle timeout is configurable (`quic.Config.idle_timeout_ms`, server
  `--quic-idle-timeout-ms`, SDK `Config.idle_timeout_ms`), default 30 s.
- **Implemented client code (SDK):** the QUIC transport in `sdk/zig/
  transport/quic.zig` compiles against the vendored zquic client, drives
  the zquic event loop, and is verified against the server QUIC listener
  above.
- The CLI default stays TCP (`--tcp`) until the Phase 9 exit criteria pass
  and the migration condition in ADR-0024 is met (ROADMAP.md); `--quic`
  selects the QUIC transport explicitly.

## Decision Drivers

1. Top-level `sdk/` matches the two-product boundary (ADR-0010/0011) and
   gives each language SDK an independent release surface.
2. A precise QUIC stream contract lets the SDK and the future server
   listener be built independently against one spec (ADR-0015 §2 was
   intentionally coarse).
3. Keeping the sequential Connection contract avoids inventing concurrency
   semantics before the server runtime defines them (ADR-0005 single writer).
4. Explicit transport selection and defined failures satisfy BUILDING.md's
   "reject a reachable public path whose semantics are not defined".

## Consequences

- `clint/zig/` is removed; its tests and build wiring move to `sdk/zig/`.
- `sdk/zig/` imports `clint/proto/` (shared) and zquic; it must not import
  `src/`.
- The CLI keeps TCP as its working default until Phase 9 verification, then
  flips to QUIC per ADR-0015 §5.
- A server QUIC listener must implement the §2.1 stream contract (control
  stream 0, per-query streams, FIN semantics) to be interoperable with the
  SDK client.
- Docs, module boundaries, and the repository README are updated in this
  change; `CONTEXT.md` terms (Connection, RunaDB Wire Protocol, Runa Flow)
  are unchanged.

## Delivery

1. Move `clint/zig/` to `sdk/zig/` and restructure around a `Transport`
   abstraction (this change).
2. Add the zquic module wiring to the root build and the `--tcp` / `--quic`
   CLI flags (this change).
3. Server QUIC listener implementing the §2.1 contract (roadmap Phase 9).
4. Flip the CLI default to QUIC and remove the TCP listener after the
   published Phase 9 migration condition (ROADMAP.md).
