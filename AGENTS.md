# Pico — Agent Instructions

This repository contains **Pico Server** (a **single-node, lightweight, network-accessible OLTP database**) and **Pico Client** (CLI, drivers, SDKs), both implemented in **Zig**. They communicate only through a versioned **Pico wire protocol** and **Pico SQL** defined under `clint/proto/`. The two are separate products sharing a repository — see ADR-0011. Pico does not promise PostgreSQL compatibility.

## Source of truth

| Doc | Use for |
|-----|---------|
| [`CONTEXT.md`](CONTEXT.md) | Domain language. Prefer those terms; respect `_Avoid_` notes. |
| [`docs/adr/`](docs/adr/) | Accepted architecture decisions. Do not reverse without a new ADR. |
| [`docs/DOCUMENTATION.md`](docs/DOCUMENTATION.md) | Documentation writing. Read before creating or revising repository documentation. |
| [`docs/BUILDING.md`](docs/BUILDING.md) | Code construction and maintenance. Read before implementing or changing code. |

Read `CONTEXT.md` before naming public APIs, errors, docs, or config. New product decisions belong in ADRs, not only in code comments.

## Product constraints (v1)

From ADRs 0001 and 0004–0009 — treat as hard defaults:

1. **Single-instance server**, not embedded-first, not multi-node cluster.
2. **Pico wire protocol** and **Pico SQL** are the public contracts; no PostgreSQL protocol, SQL, driver, or tool compatibility is promised.
3. **Pico Client and Pico Server are separate products sharing one repo**: client code lives under `clint/`, server code under `src/`. They communicate only through `clint/proto/` protocol definitions. No cross-directory non-protocol references.
4. **OLTP SQL subset** only; unsupported SQL must fail clearly (no silent wrong results).
5. **LSM-style** primary storage for tables/indexes; keep logical boundary “ordered set + WAL + MVCC”.
6. **Single-writer commit ordering** + **MVCC** reads; multi-thread OK for net/IO/compaction, not concurrent commit of write sets.
7. **WAL first**, durable commit by default, **group commit**; looser durability must be explicit and non-default.
8. **Zig** for the server/engine; no heavy managed runtime on the critical path.

Out of scope until a new ADR: multi-node consensus, PostgreSQL compatibility, OLAP engine, treating checkpoint as user backup.

## Language & terminology

- Prefer domain terms from `CONTEXT.md` in product/docs discussion when the user does; code identifiers stay English.
- Say **Pico Wire Protocol** or **Pico SQL**; do not describe Pico as PostgreSQL-compatible.
- Use **Connection**, not Session, for client sessions; **contention**, not “lock storm,” as the product concept; **durability level**, not a raw “fsync switch,” in user-facing text.
- “Safety” in product discussions means crash/durability guarantees, not authentication/cryptography, unless access control is explicitly intended.

## Implementation norms

- Prefer small modules with clear ownership (protocol, SQL, catalog, txn/MVCC, WAL, LSM, runtime). Avoid overweight files that mix unrelated responsibilities.
- Keep public interfaces small; push policy and details inward.
- Storage/txn code must stay recoverable: crash recovery is correctness, not a nicety.
- Observability for compaction, write-path latency, durability level, and recovery is first-class—not a later bolt-on.
- Protocol and SQL tests should include the official Pico CLI/driver where practical, not only unit codecs. The current PG adapter has separate, transitional coverage only.

## Build & test (when code exists)

```bash
zig build
zig build test
```

Prefer deterministic tests, fault injection, and recovery regressions over “it starts”. Add integration coverage for wire protocol and durability claims when those surfaces land.

## What not to do

- Do not introduce cluster/shard/failover semantics into v1 storage or txn paths.
- Do not expand catalog/types to imitate PostgreSQL without an ADR and support-matrix update.
- Do not default production durability to async/unsafe modes.
- Do not treat checkpoint as user backup or PITR.
- Do not make an unofficial SDK the primary access path; the versioned Pico wire protocol is the product surface.

## Working style

- Match existing style when code appears; do not drive-by reformat or expand scope.
- When a change conflicts with an ADR or `CONTEXT.md`, stop and propose an ADR update first.
- Keep agent-facing rules in this file short; put long design narrative in ADRs / `CONTEXT.md`.
