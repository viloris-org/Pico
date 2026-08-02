# RunaDB — Agent Instructions

This repository contains **RunaDB Server** and **RunaDB Client** (CLI, drivers,
SDKs), both implemented in **Zig**. RunaDB's long-horizon direction is a
high-performance, unified, verifiable data system; its current implemented
baseline is a single-node, lightweight, network-accessible OLTP database. The
two products communicate only through the versioned **RunaDB Wire Protocol**
defined under `clint/proto/`; requests use **Runa Flow** or canonical **Runa
Query IR**. They are separate products sharing a
repository — see ADR-0011. RunaDB does not promise PostgreSQL compatibility.

## Source of truth

| Doc | Use for |
|-----|---------|
| [`CONTEXT.md`](CONTEXT.md) | Domain language. Prefer those terms; respect `_Avoid_` notes. |
| [`docs/adr/`](docs/adr/) | Accepted architecture decisions. Do not reverse without a new ADR. |
| [`docs/DOCUMENTATION.md`](docs/DOCUMENTATION.md) | Documentation writing. Read before creating or revising repository documentation. |
| [`docs/BUILDING.md`](docs/BUILDING.md) | Code construction and maintenance. Read before implementing or changing code. |

Read `CONTEXT.md` before naming public APIs, errors, docs, or config. New product decisions belong in ADRs, not only in code comments.

## Current Baseline Constraints

From ADR-0016 and the applicable focused ADRs, treat these as hard defaults for
the current baseline. A future capability may change them only through an ADR
that defines its semantics, recovery, observability, compatibility, and tests:

1. **Single-instance server** today, not embedded-first or a multi-node
   cluster. Distributed work requires a dedicated topology, consistency, and
   failure-model ADR.
2. **RunaDB Wire Protocol**, **Runa Flow**, and **Runa Query IR** are the public contracts. SQL execution and PostgreSQL protocol compatibility are not supported.
3. **RunaDB Client and RunaDB Server are separate products sharing one repo**: CLI and protocol code lives under `clint/`, official language SDKs under `sdk/<lang>/` (ADR-0023), server code under `src/`. They communicate only through `clint/proto/` protocol definitions. No cross-directory non-protocol references.
4. The implemented Runa Flow slice is read-only. Unsupported operations must
   fail clearly; new models and multimodal values need explicit Flow, IR, and
   Wire Protocol contracts.
5. **LSM-style** primary storage for tables/indexes; keep logical boundary “ordered set + WAL + MVCC”.
6. **Single-writer commit ordering** + **MVCC** reads; multi-thread OK for net/IO/compaction, not concurrent commit of write sets.
7. **WAL first**, durable commit by default, **group commit**; looser durability must be explicit and non-default.
8. **Zig** for the server/engine; no heavy managed runtime on the critical path.

Out of scope until a new focused ADR: multi-node consensus, PostgreSQL
compatibility, OLAP/HTAP execution, treating a checkpoint as user backup, AI
execution semantics, historical-retention guarantees, and cryptographic
algorithms or privacy guarantees.

## Language & terminology

- Prefer domain terms from `CONTEXT.md` in product/docs discussion when the user does; code identifiers stay English.
- Say **RunaDB Wire Protocol**, **Runa Flow**, or **Runa Query IR**; do not describe RunaDB as SQL- or PostgreSQL-compatible.
- Use **Connection**, not Session, for client sessions; **contention**, not “lock storm,” as the product concept; **durability level**, not a raw “fsync switch,” in user-facing text.
- “Safety” in product discussions means crash/durability guarantees, not authentication/cryptography, unless access control is explicitly intended.

## Implementation norms

- Prefer small modules with clear ownership (protocol, Flow/IR, catalog, txn/MVCC, WAL, LSM, runtime). Avoid overweight files that mix unrelated responsibilities.
- Keep public interfaces small; push policy and details inward.
- Storage/txn code must stay recoverable: crash recovery is correctness, not a nicety.
- Observability for compaction, write-path latency, durability level, and recovery is first-class—not a later bolt-on.
- Protocol and Flow/IR tests should include the official RunaDB CLI/driver where practical, not only unit codecs.

## Build & test (when code exists)

```bash
zig build
zig build test
```

Prefer deterministic tests, fault injection, and recovery regressions over “it starts”. Add integration coverage for wire protocol and durability claims when those surfaces land.

## What not to do

- Do not introduce cluster/shard/failover semantics into current storage or
  transaction paths without a focused ADR.
- Do not add SQL or PostgreSQL compatibility without a focused ADR.
- Do not present future multi-model, AI, distributed, post-quantum, privacy,
  or autonomy capabilities as implemented before their contracts and evidence
  exist.
- Do not default production durability to async/unsafe modes.
- Do not treat checkpoint as user backup or PITR.
- Do not make an unofficial SDK the primary access path; the versioned RunaDB wire protocol is the product surface.

## Working style

- Match existing style when code appears; do not drive-by reformat or expand scope.
- When a change conflicts with an ADR or `CONTEXT.md`, stop and propose an ADR update first.
- Keep agent-facing rules in this file short; put long design narrative in ADRs / `CONTEXT.md`.
