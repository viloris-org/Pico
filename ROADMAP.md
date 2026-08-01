# RunaDB Roadmap

## Purpose and Status

**Status: Draft planning document.** This roadmap orders the work required to
deliver RunaDB Server and RunaDB Client as independent, interoperable products. It
does not change a public contract, promise release dates, or declare a planned
capability supported.

RunaDB's long-horizon direction is a unified, verifiable data system spanning
multiple data models, multimodal values, AI-assisted execution, continuum-scale
deployment, long-lived history, privacy, and sustainable operation. This
roadmap begins with the recoverable single-instance OLTP foundation, then moves
the public request boundary to Runa Flow, Runa Query IR, and a semantic model as
defined by ADR-0017. RunaDB Wire Protocol v2 has removed the legacy SQL and
PostgreSQL endpoints. RunaDB Client and RunaDB Server communicate only through
versioned protocol definitions and the public error model. PostgreSQL
compatibility and treating a checkpoint as a backup remain out of scope;
distributed, analytical, and other future capabilities require dedicated ADRs
before entering this roadmap.

The roadmap is ordered by technical dependencies, not calendar dates. A phase
is complete only when its exit criteria are met and its public documentation
uses the appropriate status: `Draft`, `Implemented`, or `Verified` as defined
in [the build guide](docs/BUILDING.md).

## Current Baseline

The current implementation is an early, evolving baseline. The following
capabilities exist but are not collectively a release claim:

| Area | Current baseline | Authoritative detail |
| --- | --- | --- |
| Runa Flow | Read-only relation projection from source or canonical Runa Query IR | [Runa Flow](docs/runa-flow.md) |
| Persistence | WAL-backed table changes, CRC32 validation, and recovery of a valid committed prefix | [WAL and crash recovery](docs/architecture/wal-and-recovery.md) |
| Native client path | RunaDB Wire Protocol v2 over sequential TCP and a RunaDB Zig client integration suite | [RunaDB Wire Protocol v2](docs/wire-protocol.md) |
| Observation Evidence | Immutable evidence ingestion, metadata inspection, bounded payload retrieval, checkpoint retention, restart recovery, orphan reclamation, and startup rejection of corrupt committed payloads through the official RunaDB Client | [Runa Flow](docs/runa-flow.md), [Wire Protocol v2](docs/wire-protocol.md), [ADR-0019](docs/adr/0019-observation-evidence-payload-storage.md) |
| MCP stdio adapter | Opt-in `--mcp-stdio` process mode serving the read-only `runadb_flow_emit` tool over MCP `2025-11-25` JSON-RPC | [ADR-0021](docs/adr/0021-native-mcp-stdio-adapter.md) |
| Transaction semantics | Single-writer commit coordinator, `txn` write sets with commit/rollback, group commit, observed-version write-write conflict detection, and a recovered commit watermark | [Write Path and WriteBatch](docs/architecture/write-path.md), [Concurrency Control](docs/architecture/concurrency-control.md) |
| Target architecture | LSM storage, MVCC, single-writer commits, group commit, VFS, Pager, execution programs, and asynchronous runtime boundaries are designed but not all implemented | [Architecture](docs/ARCHITECTURE.md) |
| Public development contract | Runa Flow, Runa Query IR, semantic model revision `0`, and RunaDB Wire Protocol v2 | [ADR-0017](docs/adr/0017-runa-flow-language-and-semantic-model.md) |
| Accepted later work | Interactive RunaDB Client, Ed25519 authentication and permissions, and QUIC transport | [ADRs](docs/adr/) |
| Frozen internal slice | `runadb.vector` column ranking and vector WAL values remain implemented in-process but are not exposed through Runa Flow, Runa Query IR, or the wire protocol; deprecated and permanently frozen | [ADR-0020](docs/adr/0020-embedding-and-vector-retrieval-primitives.md) |

The [README](README.md), Runa Flow reference, and Wire Protocol specification
own current implementation claims. This document intentionally
does not duplicate them.

## Long-Horizon Direction

ADR-0016 establishes RunaDB's direction beyond the current foundation: unified
relational, document, graph, vector, time-series, key-value, spatial, and
multimodal data; AI-assisted and neuro-symbolic execution; transactional,
analytical, and streaming workloads; distributed edge-to-cloud operation;
verifiable provenance and history; cryptographic agility; privacy; energy
efficiency; and open, portable evolution.

ADR-0018 refines that direction with the **World Continuum** as the sole
top-level target data model: Continuum Objects, immutable Observation Evidence,
State Fields, Representation Charts, Causal Dynamics, and Counterfactual
Branches. Relation, document, key-value, media, vector, sensor, and agent-memory
forms become views or bindings within that model, not competing stores.
ADR-0019 delivers the first persistent slice of that model: immutable
Observation Evidence payload storage. ADR-0022 defines **MEMO (Memory as a
Model)** as the future retrieval and memory capability, replacing the embedding
and RAG primitives that ADR-0020 permanently froze and deprecated.

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
- Reject unsupported Runa Flow, Runa Query IR, and protocol
  input clearly. Never silently accept a partially implemented semantic.
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

### Phase 0: Retire The Legacy SQL Baseline

**Status:** Complete. The SQL parser/executor, PostgreSQL adapter, SQL-specific
client APIs, and protocol v0.1 endpoint have been removed.

**Exit evidence:** The build graph contains no SQL or PostgreSQL protocol
module; Wire Protocol v2 rejects old peers by major version; current public
documentation describes only Flow/IR request execution.

### Phase 1: Runa Flow Contract and Protocol Major

**Goal:** Define the replacement public boundary before treating new data-model
capabilities or language syntax as deliverable work.

- Publish the Runa Flow grammar, static type rules, canonical Runa Query IR
  schema, semantic-model schema, and distinct parse, binding, type, policy,
  resource, and execution errors.
- Define the next incompatible RunaDB Wire Protocol major version, including
  protocol-major and IR-format negotiation, rejection behavior, and official
  RunaDB Client coverage.
- Establish versioning and migration/rejection rules for Runa Flow source,
  Query IR, semantic-model revisions, model bindings, and future persisted
  values. An unsupported old form must leave the data directory unchanged.
- Define the source-to-IR explanation boundary and the validation boundary for
  natural-language requests. Generated requests remain advisory until validated
  Runa Query IR is accepted for execution.
- Keep SQL absent and prevent a silent SQL-to-Flow translation path.

**Exit criteria:** The target language, IR, semantic model, error model, and
protocol-major negotiation are published as coherent drafts with deterministic
validation and rejection coverage. No capability is called supported merely
because its source syntax or IR shape exists.

### Phase 2: Read-Only Semantic-Model Vertical Slices

**Goal:** Prove the new public boundary through narrow, end-to-end read paths
before adding mutations or declaring multiple data models supported.

**Status:** The relation slice and the Observation Evidence slice (ADR-0019) are
implemented through the official RunaDB Client as a protocol v2 development
capability, including immutable evidence ingestion, metadata inspection, bounded
payload retrieval, checkpoint retention, restart recovery, orphan reclamation,
and startup rejection of corrupt committed payloads. The opt-in MCP stdio
adapter (ADR-0021) exposes the same read-only boundary through
`runadb_flow_emit`. The document and graph slices, the remaining World Continuum
inspection forms, and the evidence operator contract (metrics, quotas, and
staged-upload accounting) remain outstanding below.

- Build relation, document, and graph read-only vertical slices through the
  official RunaDB Client, from Runa Flow source through binding and canonical
  Runa Query IR to result explanation.
- Define each operation's input and result shape, cardinality, ordering,
  nullability, authorization requirements, resource accounting, and explicit
  unsupported outcomes.
- Keep semantic-model declarations distinct from physical table, index, and
  value bindings so execution may evolve without changing language semantics.
- Add deterministic source-to-IR, IR-to-result, malformed-input, authorization,
  resource-limit, and Connection lifecycle coverage.

**Exit criteria:** Each slice is supported and tested only for its published
semantics; source and equivalent IR produce the same result or error; and no
slice implies a capability beyond its published semantics — including document,
graph, temporal, vector-retrieval, or World Continuum State Field and
Representation Chart support.

### Phase 3: Transaction Semantics and Commit Coordination

**Status:** Core coordinator and write-set semantics implemented as a development
slice. The `txn` ownership area, single-writer commit coordinator, group commit,
observed-version write-write conflict detection, bounded admission, and the
durable commit watermark are implemented and deterministically tested. The
remaining items below are the Read Committed runtime wiring, connection-level
cancellation delivery, and production support verification.

**Goal:** Replace compatibility transaction labels with verified transaction
semantics while retaining one commit order.

- Introduce transaction-owned write sets, snapshots, failed-transaction state,
  and explicit commit/rollback boundaries in the `txn` ownership area.
- Add a dedicated single-writer commit coordinator that assigns commit order,
  validates write conflicts, writes WAL records, and publishes confirmed
  changes in that order.
- Implement group commit without weakening the default durability level. Group
  membership, cancellation, I/O failure, and response ordering must have
  defined outcomes.
- Define and test the initial isolation level and its visibility rules. Reads
  must use snapshots; write-write contention must either wait within bounded
  rules or fail with a documented conflict error.
- Add cancellation and resource-bound behavior so a blocked or disconnected
  connection cannot leak write-set or commit-queue state.

**Exit criteria:** Deterministic tests cover autocommit, multi-statement commit,
rollback, failed transactions, visibility, conflicts, cancellation, and bounded
contention. Failure injection at every WAL and publication boundary shows that
restart exposes only the confirmed commit prefix.

### Phase 4: Durable Storage Foundation

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

### Phase 5: LSM Storage and MVCC Retention

**Goal:** Move table and index storage from the in-memory baseline to ordered,
recoverable LSM structures while preserving snapshot visibility.

- Implement MemTables, sorted-string tables, indexes, manifests, and point and
  range read paths behind the storage ownership boundary.
- Add flush and compaction scheduling with explicit backpressure and resource
  limits. Compaction must not run Request execution or commit logic directly.
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

### Phase 6: Execution and Runtime Evolution

**Goal:** Scale execution and connection handling without crossing ownership
boundaries or weakening commit correctness.

- Introduce execution programs incrementally, preserving golden result and
  error parity with validated Runa Query IR execution.
- Add streaming result production, cancellation points, result backpressure,
  and resource accounting at execution-program boundaries.
- Implement the runtime I/O scheduler, connection lifecycle, and bounded work
  queues described by the target architecture.
- Permit concurrent network and I/O work while routing all logical mutation
  through the Phase 3 single-writer coordinator.
- Add load and fault tests for slow consumers, cancellation, connection loss,
  queue saturation, and compaction pressure.

**Exit criteria:** Execution-program parity, opcode-boundary cancellation,
streaming backpressure, queue-bound, and concurrent-read/write regressions
pass. Load tests show bounded resource use and predictable contention behavior.

### Phase 7: Administration and Access Control

**Goal:** Deliver operable, authenticated instances through the target protocol
and official RunaDB Client.

- Define administration requests, including status, configuration, and shutdown,
  in Runa Flow and Runa Query IR with precise permissions, runtime-only
  configuration semantics where specified, and safe shutdown/checkpoint
  sequencing.
- Implement the Ed25519 challenge-response handshake, OpenSSH public-key
  parsing, key fingerprints, and `HELLO` protocol extensions.
- Add `runadb_catalog.users`, user/key-management requests, permission bitmap
  enforcement for every request, and durable bootstrap of the first admin.
- Implement key rotation, development-only insecure mode, and CA certificate
  mode according to ADR-0014.
- Audit all authentication failures, permission denials, configuration changes,
  shutdown decisions, and recovery failures with bounded, non-secret logs.

**Exit criteria:** End-to-end tests cover bootstrap, authentication failures,
every permission bit, authorization errors that keep a Connection usable, key
rotation, CA expiration, safe shutdown, and recovery of the system catalog.

### Phase 8: RunaDB Client Product Completion

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

### Phase 9: QUIC Transition and TCP Retirement

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
| Public contract | Versioned protocol, Runa Flow, Runa Query IR, or semantic-model update; explicit errors; and official RunaDB Client end-to-end coverage |
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
- OLAP execution, data warehousing, and broad analytical language features.
- Backup, point-in-time recovery, or describing a checkpoint as either.
- Unbounded caches, unbounded queues, or asynchronous durability as the
  production default.

World Continuum forms beyond the implemented Observation Evidence slice
(ADR-0018) and the MEMO retrieval capability (ADR-0022) are accepted target
contracts; they are described in [Long-Horizon Direction](#long-horizon-direction)
and enter the delivery sequence only after their focused verification work is
specified.

## Change Control

This roadmap may be refined as evidence changes, but it cannot supersede an
accepted ADR. A proposal that changes the product boundary, durability level,
commit ordering, persistent format contract, Runa Flow or Runa Query IR
semantics, or transport migration policy requires an ADR and corresponding
protocol, language, architecture, and test updates.
