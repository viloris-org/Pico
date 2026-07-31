# RunaDB Build Loop

This is the stable, loop-loaded guide for changing RunaDB. It is an
implementation guide, not an architecture decision record (ADR). Keep it
short: add a rule only after repeated, observed engineering friction. Detailed
procedures belong in the linked owner documents.

## Read First

Read [CONTEXT.md](../CONTEXT.md) before naming a public API, error, or product
concept. Accepted ADRs override every other source. Then read the local code,
tests, and the one or more references that own the changed surface:

| Changed surface | Read |
| --- | --- |
| Module ownership or dependencies | [architecture](ARCHITECTURE.md), [module boundaries](engineering/module-boundaries.md) |
| RunaDB SQL or RunaDB Wire Protocol | [SQL support](sql-subset.md), [wire protocol](wire-protocol.md), [change protocols](engineering/change-protocols.md) |
| SDK or Client behavior | [module boundaries](engineering/module-boundaries.md), [change protocols](engineering/change-protocols.md) |
| WAL, recovery, VFS, formats, LSM, or compaction | [architecture](ARCHITECTURE.md), [storage references](architecture/), [change protocols](engineering/change-protocols.md) |
| Tests, handoff, documentation, or review | [verification](engineering/verification.md), [documentation standard](DOCUMENTATION.md) |
| Concurrency, queues, allocation, or observability | [runtime rules](engineering/runtime-rules.md), [architecture](architecture/concurrency-control.md) |

When authority conflicts, use this order: accepted ADR, `CONTEXT.md`,
architecture contracts, public support/protocol/error documentation, tests,
then implementation. Stop and state a conflict rather than silently choosing
an interpretation.

## Hard Boundaries

- The current baseline is a single-instance, network-accessible OLTP server.
  Do not add cluster, replication, sharding, failover, or cross-instance rules
  without a focused ADR.
- RunaDB Client (`clint/`) and RunaDB Server (`src/`) share only the versioned
  RunaDB Wire Protocol definitions in `clint/proto/`.
- Public contracts are RunaDB Wire Protocol and RunaDB SQL. Do not promise
  PostgreSQL compatibility. Unsupported public input must fail explicitly.
- The single writer alone orders and publishes commits. A transaction write set
  remains private until publication; reads use snapshots.
- WAL evidence precedes visibility. At the default durability level, successful
  `COMMIT` requires complete WAL evidence and completed WAL synchronization.
- Persistent formats are recovery protocols: version and validate new bytes.
  A truncated final WAL record may be discarded only as its contract permits;
  complete-record corruption must reject startup and preserve evidence.
- Do not make a checkpoint a backup, relax default durability, add placeholder
  success paths, or document target work as implemented.

## Work Loop

1. Take one independently verifiable item. State its user result, owner,
   invariants, dependencies, and evidence in the task or PR.
2. Inspect the local implementation, tests, and the owning contract. Match
   existing naming, allocator ownership, cleanup, errors, and test shape.
3. Make the smallest complete vertical change through the existing ownership
   boundary. Do not refactor the repository to simplify a local task.
4. Add deterministic normal, rejection, and failure evidence appropriate to
   the surface. A persistent write path requires interruption and restart
   recovery evidence before it is supported.
5. Run focused tests while iterating, then run the full commands below for a
   code change. Record actual results, not intended results.
6. Update the owning public or architecture documentation with verified
   behavior only. Hand off using the fields in [verification](engineering/verification.md).

Use bounded TODO markers only for explicit work with a closure condition:
`TODO(design)`, `TODO(protocol)`, `TODO(recovery)`, `TODO(test)`,
`TODO(migration)`, or `PERF(measure)`. Reject a reachable public path whose
semantics are not defined.

## Build And Test

RunaDB requires Zig 0.16 or newer. From the repository root, run:

```bash
zig build
zig build test
```

Use `zig build --help` for checked-out build steps. Benchmarks measure a stated
workload; they are not correctness evidence. Label results with WAL
synchronization disabled as non-durable.

## Handoff

Report the changed surface, state (`Draft`, `Implemented`, `Verified`, or
`Blocked`), mutable-state owner, commands and tests actually run, recovery and
observability impact, and remaining bounded work. `Verified` is the only state
that may be described as supported after the owning public documentation also
changes.
