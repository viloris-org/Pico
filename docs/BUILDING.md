# Pico Agent Build Guide

This guide defines how agents build Pico quickly without weakening Pico's public
contracts, recovery guarantees, or product boundaries. It is an implementation
and delivery guide, not an architecture decision record (ADR).

Read this entire document before changing code. Also read
[CONTEXT.md](../CONTEXT.md), [ARCHITECTURE.md](ARCHITECTURE.md), the applicable
files in [docs/adr](adr/), and the local code around the planned change. Existing
code is evidence of the current implementation; ADRs and architecture contracts
define the intended constraints.

## Purpose and Non-Goals

Pico is a lightweight, single-node, network-accessible OLTP database. Pico
Server and Pico Client are independent products that share a repository. Pico
Client delivers the official CLI, drivers, developer tools, and SDKs. Their
only shared implementation contract is the versioned Pico Wire Protocol under
`clint/proto/`; their public contracts are the Pico Wire Protocol, Pico SQL, and
the public error model.

This guide optimizes for small, independently reviewable vertical slices. A
slice is complete only when its behavior and failure modes have evidence. A
large patch that appears to add several capabilities but cannot establish their
transaction, durability, or recovery behavior is not fast progress.

This guide does not authorize any of the following:

- Changing an accepted ADR without a new or superseding ADR.
- Adding cluster, replication, sharding, failover, or cross-instance semantics.
- Promising PostgreSQL protocol, SQL, driver, tool, type, or error compatibility.
- Turning a checkpoint into a backup or point-in-time recovery feature.
- Making asynchronous or otherwise relaxed durability the production default.
- Accepting SQL or protocol input and silently ignoring part of its requested
  effect.

## Build and Test Commands

Pico requires Zig 0.16 or newer. The repository vendors its current Zig
dependencies, so a standard build does not require an additional package
manager or system library setup.

Run the default build and complete test suite from the repository root:

```bash
zig build
zig build test
```

The default build installs the independently deployable `pico` server and
`pico-cli` client into `zig-out/bin/`. The available development entry points
are:

| Command | Result |
| --- | --- |
| `zig build run -- [server options]` | Build and run Pico Server. |
| `zig build cli -- [client options]` | Build and run Pico Client. |
| `zig build bench -Doptimize=ReleaseFast -- [benchmark options]` | Run the SQL-path benchmark. |
| `zig build wal-bench -Doptimize=ReleaseFast` | Run WAL microbenchmarks. |

Use `zig build --help` to inspect the build steps and Zig options supported by
the checked-out revision. Benchmarks are measurements, not correctness
evidence. In particular, a result collected with WAL synchronization disabled
must be labeled as non-durable.

## Pico Client and SDK Goals

SDK implementation is a first-class delivery goal, not a server-side utility
or a later wrapper around private APIs. The initial target is the **Pico Zig
SDK** in `clint/zig/`. Additional official language SDKs belong in their own
`clint/<language>/` directories after their language, package layout, version
policy, and supported Pico Server/protocol versions are explicitly scoped.

Every official SDK must:

- Use only the versioned Pico Wire Protocol and documented Pico SQL behavior.
  It must never open a data directory or import server implementation modules.
- Expose Connection lifecycle, statement execution, result consumption,
  transaction control, timeout/cancellation behavior when supported by the
  protocol, and stable client-facing errors for the capabilities it claims.
- Preserve protocol framing, version negotiation, backpressure, and error
  semantics rather than recreating server behavior locally.
- Declare the Pico Wire Protocol versions and Pico Server versions it supports.
  SDK, CLI, and server releases may move independently; compatibility must be
  tested rather than inferred from a shared repository revision.
- Provide an end-to-end compatibility suite that exercises the SDK against a
  real Pico Server through the public protocol boundary.

An SDK may offer language-idiomatic APIs, but it must not invent SQL semantics,
transaction guarantees, retry behavior, or durability claims. A client-side
retry must be explicit, opt-in where it can repeat a write, and justified by
the server's documented error and transaction semantics.

## Authority Order

When documents or code disagree, resolve the conflict in this order:

1. An accepted ADR, unless a newer ADR explicitly supersedes it.
2. `CONTEXT.md` terminology and hard product constraints.
3. `docs/architecture-contract.yml` and the detailed architecture documents.
4. The public support matrix, protocol specification, and published error model.
5. Existing tests that state the current behavior.
6. Existing implementation patterns.

Do not solve an authority conflict by making the code silently choose one
interpretation. Stop, state the conflict in the task or PR, and propose the
smallest necessary ADR or documentation update before changing the behavior.

## Non-Negotiable Rules

### Product and Public Contracts

- Refer to the public contracts as **Pico Wire Protocol** and **Pico SQL**.
  Pico does not promise PostgreSQL compatibility.
- Pico Client code belongs under `clint/`; Pico Server code belongs under
  `src/`. They may share only definitions in `clint/proto/`. There are no other
  cross-directory implementation imports or runtime calls.
- A temporary PostgreSQL Frontend/Backend adapter is a migration aid. It is not
  a product acceptance target and must not define Pico behavior, error mapping,
  SQL scope, or compatibility claims.
- Every supported Pico SQL feature must be represented accurately in
  [docs/sql-subset.md](sql-subset.md). Unsupported syntax must return a stable,
  explicit error rather than a partial success.
- Any public protocol change must define the protocol-version behavior,
  compatibility result, error behavior, and official Pico Client coverage at
  the same time as its implementation.

### Commit, Durability, and Recovery

- The single writer is the only component that orders and publishes commits.
  Networking, disk I/O, compaction, and reads may be concurrent; mutation
  publication may not be concurrent or reordered.
- At the default durability level, a successful `COMMIT` response requires the
  complete logical change in the WAL and a completed WAL synchronization. Data
  files may lag that commit.
- Group commit may share a synchronization round. It must preserve observable
  commit order and cannot publish a transaction before its WAL evidence exists.
- A transaction's write set is private until its commit is published. Reads
  use snapshots and must not observe a partial or uncommitted write set.
- WAL, catalog, manifest, checkpoint, and immutable-table formats are recovery
  protocols. Give new on-disk bytes an explicit version and validation rules.
- Recovery may discard only a truncated final WAL record as the WAL contract
  permits. A checksum failure in a complete record, an unknown format, a
  missing middle record, or an inconsistent checkpoint must reject startup and
  preserve evidence. Do not invent repair behavior.
- All storage file access uses VFS logical names scoped to the instance's data
  directory. Do not pass arbitrary OS paths into storage components.

### Scope and Honesty

- Mark target-only architecture as `Target`; do not imply that it is already
  implemented in comments, documentation, protocol replies, or support tables.
- Do not add placeholder success paths. A parser acceptance path is a product
  commitment unless it reliably rejects later with a documented error.
- Do not introduce an abstraction merely to anticipate future work. Add an
  interface only when it has a current caller, enforces a current boundary, or
  removes meaningful duplication.
- Prefer an explicit resource-limit error to unbounded queues, allocations, or
  hidden durability relaxation.

## Repository Map and Dependency Rules

The table below maps a change to the layer that owns it. A caller may request
an operation from the owner; it must not reproduce the owner's policy.

| Area | Owns | May depend on | Must not own or depend on |
| --- | --- | --- | --- |
| `clint/proto/` | Versioned shared message definitions and wire-level constants | Shared protocol-only utilities | Server or client implementation internals |
| `clint/` | Official CLI, drivers, developer tools, SDKs, local interaction, client Connection state, and protocol encoding/decoding | `clint/proto/` | Data-directory access, server storage, server transaction implementation |
| `clint/zig/` | Pico Zig SDK public API, Zig Connection lifecycle, protocol client, result/error mapping, and SDK integration tests | `clint/proto/`, Zig-local client modules | `src/` internals, data-directory access, server-side transaction or durability policy |
| `src/net/` | Connection lifecycle, frame decoding and encoding, connection backpressure, protocol error mapping | `src/sql/`, `src/util/`, `clint/proto/` | WAL, table, catalog, LSM, VFS, or SQL storage policy |
| `src/sql/` | Pico SQL tokenization, parsing, binding, semantic validation, and execution scheduling | Transaction/catalog facade, `src/util/` | Wire frames, WAL records, data-directory files, SSTable formats |
| `src/txn/` | Transaction state, snapshots, private write sets, conflict inputs, commit requests | Catalog/storage facade, `src/util/` | Direct protocol handling or independently publishing commits |
| `src/commit` (target) | Commit sequence, bounded commit queue, group commit, conflict validation, publication | Transaction, catalog, storage, `src/util/` | SQL parsing or network framing |
| `src/catalog` (target) | Database, table, column, constraint, and index definitions | Storage, `src/util/` | SQL text, network framing, direct client state |
| `src/storage/wal` | WAL encoding, append, validation, sync boundary, and recovery scan | VFS, `src/util/` | SQL text and protocol frames |
| `src/storage/lsm` (target) | Ordered-set reads and writes, memtables, immutable tables, manifests | VFS, optional pager, `src/util/` | SQL syntax and commit-policy decisions |
| `src/storage/compaction` (target) | Bounded maintenance work and file preparation | LSM, VFS, `src/util/` | Commit ordering and direct visibility publication |
| `src/storage/vfs` | Data-directory fencing, logical-name validation, file handles, positional I/O, atomic file publication | `src/util/` | SQL, protocol, transaction policy |
| `src/storage/pager` | Fixed page frames, pinning, dirty writeback, and truncation for one file | VFS, `src/util/` | User commit semantics or recovery policy by itself |
| `src/util/` | Small, domain-neutral helpers | None or the Zig standard library | SQL, wire, transaction, durability, or storage policy |

The currently implemented `storage/engine` is a transitional facade. It keeps
the current validate -> WAL append -> apply -> recovery sequence together while
the target catalog, commit, and LSM modules are not independent. New
persistence code must not bypass it and create divergent table and WAL state.
When target modules are introduced, move responsibilities out of `engine` and
`table`; do not turn the transitional facade into a permanent mixed-responsibility
module. `storage/engine` must not acquire a new responsibility. Do not add more
than 50 lines of new production logic to it in one change. Complex new logic
must begin in its target owner, such as `src/commit/`, `src/catalog/`,
`src/storage/lsm/`, or `src/storage/compaction/`, with `engine` limited to
adapting the current boundary. A mechanical responsibility move may exceed this
limit only when it removes code from `engine` overall and preserves its
validate -> WAL append -> apply -> recovery ownership.

The allowed dependency direction is:

```text
Pico Client --> clint/proto <-- src/net
                             |
src/net --> src/sql --> src/txn, src/catalog --> src/storage
                      src/txn --> src/commit --> src/storage
src/storage/{wal,lsm,pager} --> src/storage/vfs --> src/util
src/net, src/sql, src/txn, src/storage --------------------> src/util
```

`catalog`, `commit`, `lsm`, and `compaction` in this diagram are target module
boundaries. Their absence from the current tree does not permit a reverse
dependency from an existing layer.

## Agent Work Protocol

### Before Editing

For every nontrivial task, record the following in the task description or PR
description before writing production code:

```text
IMPLEMENTATION PLAN
  surface:       Pico SQL | Pico Wire Protocol | server internal | Pico Client | Pico SDK
  user result:   <new behavior or explicit rejection>
  owner:         <module that owns new mutable state>
  invariants:    <behavior that must hold on success, failure, crash, and contention>
  dependencies:  <completed work, protocol version, format version, ADR; or none>
  evidence:      <specific tests, recovery cases, integration cases, benchmark>
  status:        Draft | Implemented | Verified | Blocked
```

Use Pico's defined terms: **Connection**, **transaction**, **snapshot**,
**commit**, **durability level**, **WAL**, **checkpoint**, **recovery**, and
**contention**. Do not call a Connection a Session when the distinction
matters, and do not call a checkpoint a backup.

Then inspect the nearest existing implementation and tests. Match its public
naming, error style, allocator ownership, cleanup conventions, and test shape
unless the task explicitly changes that local convention. Do not perform a
repository-wide refactor in order to make one local task convenient.

### During Implementation

Build in the smallest useful vertical slices, normally in this order:

1. Define the input boundary and expected rejection behavior.
2. Add deterministic tests for pure encoding, parsing, state-machine, or data
   structure logic.
3. Implement the logic inside the module that owns its state.
4. Connect callers through the existing boundary rather than reaching into the
   owner's state.
5. Add error, cancellation, contention, resource-exhaustion, and malformed
   input behavior appropriate to the surface.
6. Add Pico Client or SDK-to-server coverage for a public behavior.
7. For a persistent write path, add failure-injection and restart recovery
   coverage before advertising the behavior as supported.

Use these markers only when the missing work is explicit and bounded:

```text
TODO(design): <unknown design decision>; close when <decision or ADR exists>
TODO(protocol): <missing version/error behavior>; close when <contract test exists>
TODO(recovery): <missing crash case>; close when <restart regression exists>
TODO(test): <missing deterministic coverage>; close when <test path exists>
TODO(migration): <temporary compatibility behavior>; close when <removal condition is met>
PERF(measure): <known non-final implementation>; measure with <benchmark and workload>
```

Do not use a TODO marker to conceal a behavior that a user can invoke. If a
path can be reached but lacks defined semantics, reject it at the public
boundary until it is implemented and verified.

### Before Handoff

Every material change must include a handoff block in the PR description or
task result:

```text
IMPLEMENTATION STATUS
  surface:     <Pico SQL / Pico Wire Protocol / internal / Pico Client / Pico SDK>
  state:       Draft | Implemented | Verified | Blocked
  owner:       <module that owns the state>
  evidence:    <test files and commands actually run>
  recovery:    n/a | <fault-injection and restart cases>
  observability:<metrics or logs changed; n/a if none>
  follow-ups:  <remaining TODO markers; none if empty>
```

Use status words precisely:

| Status | Meaning | May be published as supported? |
| --- | --- | --- |
| `Draft` | Interface, experiment, or test skeleton exists; behavior is incomplete or undecided. | No |
| `Implemented` | Expected path works locally, but the required evidence is incomplete. | No |
| `Verified` | The behavior and required failure evidence satisfy this guide. | Yes, if public docs are also updated |
| `Blocked` | Work cannot proceed without a named dependency, decision, or external condition. | No |

## Definition of Done

The following table is the minimum evidence. A higher-risk change may require
more. A lower-risk label does not exempt a change that touches a public or
recovery boundary.

| Change class | Required evidence before `Verified` |
| --- | --- |
| Local utility or data structure | Deterministic unit tests for normal behavior, error behavior, and relevant resource limits. |
| Pico SQL syntax or semantics | Parser tests, binding/execution tests, rejection tests, stable error mapping, and an updated SQL support matrix. |
| Pico Wire Protocol | Frame codec tests, version-negotiation tests, malformed-frame tests, server behavior tests, and official Pico Client end-to-end coverage. |
| Pico Client behavior | Client codec/connection tests and an end-to-end test against the public Pico Wire Protocol, without importing server internals. |
| Pico SDK behavior | Public API tests for Connection lifecycle, result/error mapping, transaction behavior, cancellation or timeout where supported, and an SDK-to-server compatibility suite over the Pico Wire Protocol. |
| Transaction or contention behavior | Commit/rollback, failed-transaction state, visibility, conflict, cancellation, and bounded-queue tests as applicable. |
| VFS, WAL, catalog, checkpoint, manifest, or LSM format | Format version and rejection tests, corruption tests, I/O-failure tests, truncated-tail tests where applicable, and restart recovery regressions. |
| A path that can return successful `COMMIT` | WAL-first ordering, selected durability level, single-writer publication, and interruption at each persistence/publication point; restart must expose only the confirmed commit prefix. |
| Compaction or file reclamation | Snapshot visibility, manifest publication, file validation, delayed reclamation, and recovery tests under concurrent reads and writes. |
| Performance or resource limit | Reproducible benchmark command, workload parameters, optimization level, machine context when relevant, durability level, and a comparison with a recorded baseline. |

At a minimum, run these commands for a code change:

```bash
zig build
zig build test
```

Run narrower tests while iterating, then run the full test step before handoff.
Do not substitute a benchmark, a successful manual server startup, or a client
connection for correctness evidence. A performance number collected with WAL
synchronization disabled must be labeled as a non-durable measurement.

Tests must prove the behavior under test. Do not add meaningless assertions
(including assertions whose result is statically known without exercising the
subject), test-only success stubs, or `catch unreachable` in place of checking
an expected failure. An error-path test must assert the precise error, for
example `try std.testing.expectError(error.TableNotFound, operation(...))`, and
then verify any required post-error state.

## Public Contract Changes

### Pico SQL

For every new SQL capability:

1. Specify the accepted syntax and its semantic boundary.
2. Define how invalid, unsupported, and partially supported forms fail.
3. Implement parsing, semantic validation, execution, and transaction behavior
   together; no stage may report successful completion while omitting effects.
4. Add parser, execution, rejection, recovery, and official Pico Client tests
   as applicable.
5. Update [docs/sql-subset.md](sql-subset.md) only after the capability is
   `Verified`.

If the capability affects catalog state, indexes, constraints, transaction
visibility, or commit, it is also a persistence change. Apply the WAL and
recovery requirements even if the SQL parser change itself appears small.

### Pico Wire Protocol

For every protocol change:

1. Change shared definitions only under `clint/proto/`.
2. State whether an older peer can accept the new message or field. If not,
   specify negotiation or a stable rejection result.
3. Bound every frame, string, collection, and streamed result. A malformed or
   oversized frame must fail the responsible Connection without unbounded
   allocation or corruption of shared server state.
4. Keep protocol decoding separate from SQL execution and storage errors; map
   errors at the network boundary.
5. Test both sides of the protocol independently and together through Pico
   Client and Pico Server.

Do not make a server-internal struct, storage format, or Zig API a protocol
contract by serializing it directly.

### Pico SDKs

The Pico Zig SDK is built in `clint/zig/` and is the reference implementation
for the official SDK delivery process. An SDK task must state its language,
public package/module entry point, supported protocol versions, supported Pico
Server versions, and compatibility test command before implementation begins.

Build SDK work in this order:

1. Keep shared frame definitions and version constants in `clint/proto/`; do
   not copy them into an SDK.
2. Implement bounded framing, version negotiation, Connection setup and close,
   and protocol-error decoding.
3. Add the public statement, result, and error API for behavior the server
   already supports. Do not expose a method that reports success for an
   unsupported server capability.
4. Add transaction APIs only when their begin, commit, rollback, error, and
   Connection-close behavior exactly match Pico Server semantics.
5. Add end-to-end tests using a launched Pico Server and the SDK's public API.
   Include supported behavior, server rejection, malformed peer data, version
   mismatch, and Connection-close cases.
6. Publish or update the SDK compatibility matrix only after those tests are
   `Verified`.

SDK convenience must remain local to the language binding. It may improve
resource management and ergonomics, but it cannot bypass server-side limits or
turn an uncertain outcome into a successful operation. If a Connection breaks
during a write, the SDK must return an outcome consistent with the protocol and
document whether the caller can safely retry; it must not automatically repeat
the write unless the public contract makes that repetition safe.

## Persistent-State Change Protocol

Treat any change to WAL records, catalog records, manifest data, checkpoint
metadata, or immutable-table format as a recovery change.

Before changing a persistent format, document:

```text
FORMAT CHANGE
  owner:          <wal / catalog / lsm / vfs>
  format version: <old -> new>
  writer behavior:<what new writers emit>
  reader behavior:<old/new/unknown format handling>
  recovery rule:  <validated prefix and rejection behavior>
  migration:      <none / explicit migration / explicit refusal>
  tests:          <encoding, corruption, truncation, restart>
```

Follow these rules:

- Validate lengths, version tags, record boundaries, and checksums before
  treating bytes as state.
- Write a new immutable artifact completely, synchronize it when required,
  validate it, and only then atomically publish a manifest or checkpoint that
  references it.
- Never reclaim an old file while a visible snapshot can still reference it.
- Make interrupted writes recover to a verified prefix or reject startup. Do
  not scan forward for a plausible record after a complete-record failure.
- Preserve diagnostic evidence when recovery rejects the data directory.
- Keep checkpoint semantics internal. Checkpoints advance persistent progress
  and WAL reclamation; they are not a user backup interface.

## Concurrency, Backpressure, and Resource Rules

- Model every shared mutation with one owner and one publication point.
- Lock acquisition follows this global order: Connection lock -> transaction
  state lock -> commit queue lock. Code must never acquire an earlier lock
  while holding a later one. A new lock that can coexist with these locks must
  document its position in this hierarchy and preserve the same order before
  it is introduced.
- Use bounded queues for commit, network output, compaction, and other
  producer-consumer paths. Define the error or backpressure behavior when a
  queue is full.
- A slow Connection must not create unbounded buffered output or block unrelated
  Connections indefinitely.
- Reads may run concurrently on snapshots; ordinary reads must not observe
  partial writes or require a global write lock.
- Compaction can prepare output concurrently but may publish it only through
  the manifest/commit ownership path.
- A static page cache is a fixed resource budget. Cache exhaustion must fail
  explicitly, for example with `CacheFull`; it must not allocate additional
  frames on an unbounded general-purpose heap path.
- A Zig function that allocates must accept the `std.mem.Allocator` it uses
  explicitly. Establish and document ownership of every returned or retained
  allocation, and use `defer` or `errdefer` to release each owned allocation on
  all success and error paths. Tests that exercise allocations must use
  `std.testing.allocator` so leaks fail the test.
- Instrument write-path latency, WAL synchronization latency, commit-queue
  depth and batch size, recovery duration and replay count, durability level,
  WAL size, checkpoint progress, compaction backlog, and recovery-rejection
  reasons as the corresponding paths are introduced.

## Documentation and Test Maintenance

Update documentation in the same change when behavior changes:

| Changed surface | Documentation to inspect or update |
| --- | --- |
| Pico SQL support | `docs/sql-subset.md`, user examples, public errors |
| Pico Wire Protocol | `clint/proto/` documentation, version/compatibility documentation, client examples |
| Pico SDK public API or compatibility | SDK package/module documentation, version compatibility matrix, SDK examples, and SDK-to-server integration test instructions |
| Product boundary or terminology | `CONTEXT.md`, `docs/products.md`, applicable ADR |
| Storage, transaction, or recovery contract | `docs/ARCHITECTURE.md`, relevant detailed architecture document, applicable ADR |
| Build target, CLI, benchmark, or operator setting | `README.md`, `README.zh-CN.md` when the translated material is present, and command help |

Keep comments local and durable. A comment should explain a non-obvious
invariant, ordering requirement, ownership decision, or deliberate performance
tradeoff. Remove comments that merely restate code. Do not document a planned
feature as though it currently works.

## Review Checklist

Reviewers and agents should answer every applicable question before marking a
change `Verified`:

- Does the change preserve the accepted ADRs and use Pico terminology?
- Is the new mutable state owned by one module, and is the dependency direction
  correct?
- Does a public behavior cross only the Pico Wire Protocol and Pico SQL
  boundaries, with no server/client internal import?
- If the change affects an SDK, does that SDK declare its supported protocol and
  server versions, preserve Connection and error semantics, and prove behavior
  through its public API against a real Pico Server?
- Are success, rejection, malformed input, cancellation, I/O failure, resource
  exhaustion, contention, and Connection-close behavior defined where relevant?
- If a write becomes visible, does WAL evidence exist first and does the default
  durability level still require synchronization before confirmation?
- Can recovery distinguish a truncated tail from corruption in a complete
  record, and are both cases tested?
- Does the implementation expose only a transactionally complete state to
  readers and recovery?
- Are protocol and SQL support documents updated only for verified behavior?
- Were `zig build` and `zig build test` run, and are the actual results
  recorded in the handoff block?
- Are new TODO or PERF markers specific, searchable, and paired with a closure
  condition?

## Reference

The operating style of this guide is informed by Bun's
[Zig to Rust porting guide](https://github.com/oven-sh/bun/blob/46d3bc29f270fa881dd5730ef1549e88407701a5/docs/PORTING.md): establish hard
rules and explicit mappings first, then advance work through staged,
inspectable deliverables. Pico does not inherit Bun's language-porting, crate,
or Rust-specific rules.
