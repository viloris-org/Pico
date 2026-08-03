# TCP Transport Retirement: Migration Conditions and Removal Policy

## Status

Accepted. This ADR publishes the roadmap Phase 9 migration condition that
governs flipping the RunaDB Client default to QUIC and removing the TCP
listener. It amends ADR-0015 §5 and ADR-0023 §2.2, which left the transition
period open.

## Context

ADR-0015 decided that zquic-based QUIC replaces TCP as the RunaDB transport
and sketched a two-listener migration period (TCP `5434`, UDP `5435`) with a
deprecation and removal to follow. ADR-0023 pinned the client side: no silent
TCP fallback, explicit `--tcp` / `--quic` selection, and a CLI default that
stays TCP until roadmap Phase 9 verification completes. Phase 9 (ROADMAP.md)
requires the server QUIC listener and the client QUIC path to demonstrate
equivalent RunaDB Wire Protocol behavior, and requires that "TCP removal is
performed only under the published migration condition".

In this checkout the server QUIC listener (`src/net/quic.zig`) implements the
ADR-0023 §2.1 stream contract and is verified end to end by the SDK QUIC
client and the in-process integration test. Certificate pinning regressions
(no pin, correct pin, wrong pin), a QUIC request round-trip through the SDK
public API, and idle-timeout behavior against the SDK client are now covered
by the SDK integration suite. The CLI still defaults to TCP.

What is still missing before the migration condition can be met is not
transport code but the Phase 7 administration surface: Stream 0 Ed25519
authentication (ADR-0014), and the status/observability surface that carries
the transport telemetry defined below.

## Decision

QUIC is the primary RunaDB transport. TCP is deprecated, and its removal is
governed by the published condition in this ADR. Reintroducing a
compatibility transport after removal requires a new ADR.

### 1. Supported versions during the migration window

- Every RunaDB Server release that ships the QUIC listener also keeps the TCP
  listener (`--runa-port`, default `5434`) until the removal release.
- Every RunaDB Client (CLI and Zig SDK) release keeps explicit `--tcp` /
  `.kind = .tcp` selection until the removal release.
- The compatibility matrix in the SDK README and the wire protocol
  documentation lists the TCP/QUIC support state of each published
  client/server version pair. The removal release updates the matrix to
  TCP removed / QUIC only.

### 2. Fallback behavior

- There is no silent TCP fallback (ADR-0023 §2.2 stands): a QUIC connect
  against a server without a QUIC listener fails with a defined error
  (`HandshakeTimeout`, `QuicRejected`, `CertificateMismatch`,
  `QuicUnavailable`). Silent fallback is rejected because it masks deployment
  errors and protocol regressions.
- During the migration window TCP is explicit and opt-in: `--tcp` on the CLI,
  `.kind = .tcp` in the SDK.
- The CLI default flips from TCP to QUIC in the first release that satisfies
  the Phase 9 exit criteria (ROADMAP.md): QUIC handshake, authentication,
  concurrent query streams, certificate failures, graceful close,
  cancellation, and client interoperability verified, with the TCP and QUIC
  contract suites demonstrating equivalent RunaDB Wire Protocol behavior.
  Because Stream 0 Ed25519 authentication is ADR-0014 (Phase 7) work, the
  flip release is at earliest the release that also carries that
  authentication.

### 3. Telemetry required before removal

A removal decision must be based on measured usage, not on code readiness.
Before the removal release is named, the following counters must exist and be
observable (bounded, non-secret logs today; the Phase 7 `RUNADB STATUS`
surface when it lands):

- Accepted connections per transport: TCP listener vs QUIC listener.
- Per-transport failure counts at connect and per statement
  (handshake timeouts, ALPN/certificate failures, protocol errors).
- RunaDB Wire Protocol version distribution across connections (to prove
  every TCP connection can move to QUIC on a supported protocol version).
- Active and idle connection counts per transport over a rolling window, to
  detect clients that depend on TCP-specific behavior (long-lived idle
  connections, proxy/NAT environments without UDP).

The removal decision uses a rolling 30-day window of these counters.

### 4. Deprecation notice

- The deprecation notice ships in the release notes and the CLI help text of
  the flip release (the first release whose CLI defaults to QUIC). Its
  wording is fixed at that release: "TCP transport is deprecated. The TCP
  listener and `--tcp` client option are removed in `<removal target>`,
  pending the telemetry condition in ADR-0024. Upgrade clients that connect
  over TCP to QUIC before that release."
- The SDK README and the wire protocol documentation carry the same notice
  from the flip release onward.

### 5. Fixed removal release decision

- The removal target is declared at deprecation time and is fixed: the third
  minor release after the flip release (for example, if the flip lands in
  `0.3.0`, removal is targeted for `0.6.0`).
- Removal happens in that targeted release only if the 30-day telemetry
  window immediately before it records fewer than 5% of live connections and
  fewer than 5% of statements over TCP. If the threshold is not met, removal
  is deferred by one minor release and the notice is updated; the threshold
  and decision rule themselves do not change without a new ADR.
- The removal release deletes: the TCP listener and its CLI flags
  (`--runa-port`, `--tcp`), the SDK TCP transport, the TCP transitional
  tests, port `5434`, and TCP documentation. Reintroducing any compatibility
  transport requires a new ADR.

## Decision Drivers

1. A published, measurable condition keeps the transport contract honest and
   gives operators a fixed upgrade path (ROADMAP "TCP removal is performed
   only under the published migration condition").
2. Named removal target plus objective telemetry threshold avoids both
   open-ended deprecation and a removal driven by code readiness alone.
3. No silent fallback preserves the defined-error contract that ADR-0023
   already accepted.
4. Keeping the flip gated on the Phase 9 exit criteria (including Stream 0
   authentication) matches the roadmap's evidence-first sequencing.

## Consequences

- The CLI default and TCP removal are no longer open-ended: the flip release
  and removal target are fixed by this policy, subject to the telemetry
  threshold.
- Transport telemetry counters must be added before the removal window (the
  Phase 7 status surface is the natural owner).
- Until the flip release, the CLI default stays TCP and the QUIC path is
  explicit (`--quic`), as today.
- Docs, the compatibility matrix, and the SDK README must be updated at the
  flip release and again at the removal release; each update is part of the
  change that performs the flip or removal.

## Delivery

1. Land the verification evidence for the QUIC path: certificate pinning
  regressions and idle-timeout behavior against the SDK client (this
  change).
2. Add the transport telemetry counters (bounded logs now; Phase 7 status
  surface later).
3. Flip the CLI default to QUIC and publish the deprecation notice in the
  release that also carries Stream 0 authentication (Phase 7).
4. Execute the removal in the named target release when the telemetry
  threshold is met, deleting the TCP listener, client fallback, transitional
  tests, port, and documentation.
