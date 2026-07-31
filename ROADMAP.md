# RunaDB Roadmap

## Purpose and Status

**Status: Draft planning document.** This roadmap orders the work required to
deliver RunaDB Server and RunaDB Client as independent, interoperable products. It
does not change a public contract, promise release dates, or declare a planned
capability supported.

RunaDB's long-horizon direction is a unified, verifiable data system spanning
multiple data models, multimodal values, AI-assisted execution, continuum-scale
deployment, long-lived history, privacy, and sustainable operation. This
roadmap currently orders only the recoverable single-instance OLTP foundation.
Its public contracts are RunaDB SQL, the versioned RunaDB Wire Protocol, and the
public error model. RunaDB Client and RunaDB Server communicate only through those
contracts. PostgreSQL compatibility and treating a checkpoint as a backup
remain out of scope; distributed, analytical, and other future capabilities
require dedicated ADRs before entering this roadmap.

The roadmap is ordered by technical dependencies, not calendar dates. A phase
is complete only when its exit criteria are met and its public documentation
uses the appropriate status: `Draft`, `Implemented`, or `Verified` as defined
in [the build guide](docs/BUILDING.md).

## Current Baseline

The current implementation is an early, evolving baseline. The following
capabilities exist but are not collectively a release claim:

| Area | Current baseline | Authoritative detail |
| --- | --- | --- |
| RunaDB SQL | Core table definition and DML, predicates, ordering, limits, and explicit transaction syntax | [SQL subset support matrix](docs/sql-subset.md) |
| Persistence | WAL-backed table changes, CRC32 validation, and recovery of a valid committed prefix | [WAL and crash recovery](docs/architecture/wal-and-recovery.md) |
| Native client path | RunaDB Wire Protocol v0.1 over sequential TCP and a RunaDB Zig client integration suite | [RunaDB Wire Protocol v0.1](docs/wire-protocol.md) |
| PostgreSQL adapter | Transitional development adapter only; not a product compatibility commitment | [ADR-0009](docs/adr/0009-runadb-native-ecosystem.md) |
| Target architecture | LSM storage, MVCC, single-writer commits, group commit, VFS, Pager, execution programs, and asynchronous runtime boundaries are designed but not all implemented | [Architecture](docs/ARCHITECTURE.md) |
| Accepted later work | RunaDB SQL administration, interactive RunaDB Client, Ed25519 authentication and permissions, and QUIC transport | [ADRs](docs/adr/) |

The [README](README.md), SQL support matrix, and protocol specification own
current support claims. This document intentionally does not duplicate them.

## Long-Horizon Direction

ADR-0016 establishes RunaDB's direction beyond the current foundation: unified
relational, document, graph, vector, time-series, key-value, spatial, and
multimodal data; AI-assisted and neuro-symbolic execution; transactional,
analytical, and streaming workloads; distributed edge-to-cloud operation;
verifiable provenance and history; cryptographic agility; privacy; energy
efficiency; and open, portable evolution.

Those are design commitments, not implementation claims or a phase sequence.
Each capability enters the delivery roadmap only after a focused ADR defines
its semantics, consistency and durability behavior, authorization, provenance,
format migration, observability, recovery, and evidence requirements.

## Delivery Principles

- Preserve the single-instance, single-writer commit model. Readers may run in
  parallel, but no change may introduce concurrent write-set publication.
- Keep the write path WAL-first. The default durability level must confirm
  persistence before a successful `COMMIT`; relaxed durability must remain
  explicit and non-default.
- Reject unsupported RunaDB SQL and protocol input clearly. Never silently accept
  a partially implemented semantic.
- Version every persistent or public format change and add compatibility,
  malformed-input, and recovery coverage before publishing support.
- Maintain the RunaDB Client/RunaDB Server product boundary: no client access to a
  data directory or server-internal module, and no server dependency on client
  implementation code.
- Land observable behavior with its evidence: deterministic tests, fault
  injection or restart recovery where relevant, official-client end-to-end
  coverage for public contracts, and reproducible benchmarks for performance
  claims.

## Roadmap

### Phase 0: Stabilize the Public Baseline

**Goal:** Make the existing native RunaDB path a dependable development and
compatibility baseline before deep storage and concurrency changes.

- Complete the RunaDB Wire Protocol v0.1 error model, version-negotiation
  behavior, connection lifecycle, message-size handling, and malformed-frame
  tests.
- Keep the SQL support matrix exact: document every supported statement,
  type, constraint, error, and explicit rejection with its regression location.
- Expand RunaDB Client-to-Server contract tests for successful statements,
  server errors, connection closure, unknown write outcomes, and compatibility
  across independently built products.
- Define a release-oriented observability baseline for startup recovery, WAL
  size and frames, write-path latency, connection count, and durability level.
- Classify the PostgreSQL adapter as migration-only in code, tests, examples,
  and release material; remove it from RunaDB product acceptance criteria.

**Exit criteria:** Protocol v0.1 and RunaDB SQL documentation agree with tests;
the official RunaDB Client exercises the public contract; malformed input cannot
change shared state; and a recovery regression covers the advertised WAL
behavior.

### Phase 1: Transaction Semantics and Commit Coordination

**Goal:** Replace compatibility transaction labels with verified transaction
semantics while retaining one commit order.

- Introduce transaction-owned write sets, snapshots, failed-transaction state,
  and explicit commit/rollback boundaries in the `txn` ownership area.
- Add a dedicated single-writer commit coordinator that assigns commit order,
  validates write conflicts, writes WAL records, and publishes confirmed
  changes in that order.
- Implement group commit without weakening the default durability level.
  Group membership, cancellation, I/O failure, and response ordering must have
  defined outcomes.
- Define and test the initial isolation level and its visibility rules. Reads
  must use snapshots; write-write contention must either wait within bounded
  rules or fail with a documented conflict error.
- Add cancellation and resource-bound behavior so a blocked or disconnected
  connection cannot leak write-set or commit-queue state.

**Exit criteria:** Deterministic tests cover autocommit, multi-statement
commit, rollback, failed transactions, visibility, conflicts, cancellation,
and bounded contention. Failure injection at every WAL and publication boundary
shows that restart exposes only the confirmed commit prefix.

### Phase 2: Durable Storage Foundation

**Goal:** Establish the data-directory and file-management primitives required
for durable LSM storage.

- Finish the VFS data-directory fence, logical filename validation, instance
  locking, positional I/O, synchronization, and atomic artifact publication.
- Finish the fixed-size Pager and static page cache with explicit pinning,
  dirty writeback, exhaustion, and truncation behavior.
- Version catalog, manifest, WAL, and internal storage formats. Unknown or
  corrupt complete formats must fail recovery rather than be replayed or
  ignored.
- Define checkpoint publication and WAL reclamation around a durable manifest
  boundary. A checkpoint remains an internal recovery mechanism, not a backup.
- Add catalog ownership and recovery so metadata and user data share the same
  commit and crash-consistency rules.

**Exit criteria:** VFS path-fence and atomic-publication tests, Pager
alignment/cache-full/pin tests, format-rejection tests, checkpoint recovery,
and catalog recovery are verified. No persistent file is published outside the
VFS or without a versioned validation path.

### Phase 3: LSM Storage and MVCC Retention

**Goal:** Move table and index storage from the in-memory baseline to ordered,
recoverable LSM structures while preserving snapshot visibility.

- Implement MemTables, sorted-string tables, indexes, manifests, and point and
  range read paths behind the storage ownership boundary.
- Add flush and compaction scheduling with explicit backpressure and resource
  limits. Compaction must not run SQL execution or commit logic directly.
- Retain versions until no active snapshot can observe them; delay file
  reclamation until manifest and reader-safety conditions hold.
- Implement secondary indexes only after the table, catalog, MVCC, and recovery
  invariants support their atomic maintenance. Publish `CREATE INDEX` only with
  complete semantics and regressions.
- Measure write amplification, compaction latency, read latency, WAL growth,
  cache pressure, and recovery time under documented workloads.

**Exit criteria:** Restart, corruption, interrupted-flush, manifest,
snapshot-visibility, concurrent-read/write, compaction, and delayed-reclamation
regressions pass. Benchmark baselines identify workload, optimization level,
machine context, and durability level.

### Phase 4: Execution and Runtime Evolution

**Goal:** Scale execution and connection handling without crossing ownership
boundaries or weakening commit correctness.

- Introduce execution programs incrementally, preserving golden result and
  error parity with direct RunaDB SQL interpretation during the transition.
- Add streaming result production, cancellation points, result backpressure,
  and resource accounting at execution-program boundaries.
- Implement the runtime I/O scheduler, connection lifecycle, and bounded work
  queues described by the target architecture.
- Permit concurrent network and I/O work while routing all logical mutation
  through the Phase 1 single-writer coordinator.
- Add load and fault tests for slow consumers, cancellation, connection loss,
  queue saturation, and compaction pressure.

**Exit criteria:** Execution-program parity, opcode-boundary cancellation,
streaming backpressure, queue-bound, and concurrent-read/write regressions
pass. Load tests show bounded resource use and predictable contention behavior.

### Phase 5: RunaDB SQL Administration and Access Control

**Goal:** Deliver operable, authenticated instances through RunaDB SQL and the
official RunaDB Client.

- Implement `RUNADB STATUS`, `RUNADB CONFIG`, and `RUNADB SHUTDOWN` with precise
  permissions, runtime-only configuration semantics where specified, and safe
  shutdown/checkpoint sequencing.
- Implement the Ed25519 challenge-response handshake, OpenSSH public-key
  parsing, key fingerprints, and `HELLO` protocol extensions.
- Add `runadb_catalog.users`, user/key management statements, permission bitmap
  enforcement for every statement, and durable bootstrap of the first admin.
- Implement key rotation, development-only insecure mode, and CA certificate
  mode according to ADR-0014.
- Audit all authentication failures, permission denials, configuration changes,
  shutdown decisions, and recovery failures with bounded, non-secret logs.

**Exit criteria:** End-to-end tests cover bootstrap, authentication failures,
every permission bit, authorization errors that keep a Connection usable, key
rotation, CA expiration, safe shutdown, and recovery of the system catalog.

### Phase 6: RunaDB Client Product Completion

**Goal:** Make RunaDB Client the practical default interface without coupling it
to RunaDB Server internals.

- Complete the Zig client public API, lifecycle, result/error mapping,
  timeouts and cancellation where supported, and protocol-version declarations.
- Build the interactive CLI: line editing, history, completion, syntax
  highlighting, multiline input, formatting, timing, and documented
  meta-commands.
- Add `runadb create instance`, authentication configuration, and `runadb
  rotate-key` workflows with non-interactive behavior suitable for automation.
- Maintain client/server compatibility matrices and integration suites across
  independently built versions.
- Define public release/versioning policy for the CLI and each official driver
  before expanding language coverage.

**Exit criteria:** Interactive and non-interactive behavior has deterministic
or PTY coverage; client APIs have contract tests against RunaDB Server; and
supported client/server version pairs are published and verified through the
RunaDB Wire Protocol.

### Phase 7: QUIC Transition and TCP Retirement

**Goal:** Make zquic-based QUIC the primary RunaDB transport while retaining one
RunaDB application protocol and a controlled TCP migration path.

- Complete QUIC stream dispatch, Stream 0 authentication, per-query stream
  lifecycle, result sequencing, cancellation, graceful close, and idle-timeout
  behavior.
- Validate TLS certificates, ALPN, certificate-failure behavior, and transport
  recovery using the vendored pure-Zig zquic dependency.
- Enable the RunaDB Client QUIC path as the default only after the native TCP and
  QUIC contract suites demonstrate equivalent RunaDB Wire Protocol behavior.
- Publish TCP migration conditions: supported versions, fallback behavior,
  telemetry needed to assess usage, deprecation notice, and a fixed removal
  release decision.
- Remove the TCP listener, client fallback, transitional tests, ports, and
  documentation only after that published condition is met. Reintroducing a
  compatibility transport requires an ADR.

**Exit criteria:** QUIC handshake, authentication, concurrent query streams,
certificate failures, graceful close, cancellation, and client interoperability
tests are verified. TCP removal is performed only under the published migration
condition.

## Cross-Cutting Release Gates

Every phase and release must maintain these conditions:

| Gate | Required evidence |
| --- | --- |
| Public contract | Versioned protocol or RunaDB SQL support-matrix update, explicit errors, and official RunaDB Client end-to-end coverage |
| Durable commit | WAL-first ordering, selected durability-level behavior, interruption testing, and restart recovery of only the confirmed prefix |
| Persistent format | Versioning, malformed/corrupt-data rejection, I/O failure coverage, and recovery regression |
| Concurrency | Commit order, snapshot visibility, conflict/cancellation behavior, bounded queues, and contention tests |
| Storage reclamation | Atomic manifest publication, reader/snapshot safety, delayed reclamation, and crash recovery |
| Performance claim | Reproducible command, workload, optimization level, machine context, durability level, and recorded baseline |
| Documentation | Correct status, American English, valid links and examples, and no claim of PostgreSQL compatibility or cluster semantics |

Run the baseline checks for every code change:

```bash
zig build
zig build test
```

Additional phase-specific checks must be recorded with the change that claims
the corresponding capability is `Verified`.

## Deferred Work

The following work is intentionally absent from this roadmap unless a new ADR
changes the product direction:

- Multi-node consensus, replication, sharding, failover, and distributed
  transactions.
- PostgreSQL protocol, SQL, driver, tool, type-system, or error compatibility.
- OLAP execution, data warehousing, and broad analytical SQL features.
- Backup, point-in-time recovery, or describing a checkpoint as either.
- Unbounded caches, unbounded queues, or asynchronous durability as the
  production default.

## Change Control

This roadmap may be refined as evidence changes, but it cannot supersede an
accepted ADR. A proposal that changes the product boundary, durability level,
commit ordering, persistent format contract, SQL scope, or transport migration
policy requires an ADR and corresponding protocol, SQL, architecture, and test
updates.
