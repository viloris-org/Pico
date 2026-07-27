# Pico — Agent Instructions

Pico is a **single-node, lightweight, network-accessible OLTP database** implemented in **Zig**. Clients connect via the **PostgreSQL wire protocol** and a deliberate **SQL subset** (not full PostgreSQL).

## Source of truth

| Doc | Use for |
|-----|---------|
| [`CONTEXT.md`](CONTEXT.md) | Domain language. Prefer those terms; respect `_Avoid_` notes. |
| [`docs/adr/`](docs/adr/) | Accepted architecture decisions. Do not reverse without a new ADR. |

Read `CONTEXT.md` before naming public APIs, errors, docs, or config. New product decisions belong in ADRs, not only in code comments.

## Product constraints (v1)

From ADRs 0001–0007 — treat as hard defaults:

1. **Single-instance server**, not embedded-first, not multi-node cluster.
2. **PostgreSQL Frontend/Backend Protocol** for wire access; protocol ≠ full SQL compatibility.
3. **OLTP SQL subset** only; unsupported SQL must fail clearly (no silent wrong results).
4. **LSM-style** primary storage for tables/indexes; keep logical boundary “ordered set + WAL + MVCC”.
5. **Single-writer commit ordering** + **MVCC** reads; multi-thread OK for net/IO/compaction, not concurrent commit of write sets.
6. **WAL first**, durable commit by default, **group commit**; looser durability must be explicit and non-default.
7. **Zig** for the server/engine; no heavy managed runtime on the critical path.

Out of scope until a new ADR: multi-node consensus, full PG dialect, OLAP engine, treating checkpoint as user backup.

## Language & terminology

- Prefer Chinese domain terms from `CONTEXT.md` in product/docs discussion when the user does; code identifiers stay English.
- Say **驱动兼容 / 线协议** or **SQL 子集**, never bare “兼容 PostgreSQL”.
- **连接** not Session for client sessions; **争用** not “lock storm” as the product concept; **耐久级别** not raw “fsync switch” in user-facing text.
- “安全” in product talk means crash/durability guarantees, not auth/crypto, unless explicitly about access control.

## Implementation norms

- Prefer small modules with clear ownership (protocol, SQL, catalog, txn/MVCC, WAL, LSM, runtime). Avoid overweight files that mix unrelated responsibilities.
- Keep public interfaces small; push policy and details inward.
- Storage/txn code must stay recoverable: crash recovery is correctness, not a nicety.
- Observability for compaction, write-path latency, durability level, and recovery is first-class—not a later bolt-on.
- Protocol and SQL tests should include real clients where practical (`psql` and at least one mainstream PG driver), not only unit codecs.

## Build & test (when code exists)

```bash
zig build
zig build test
```

Prefer deterministic tests, fault injection, and recovery regressions over “it starts”. Add integration coverage for wire protocol and durability claims when those surfaces land.

## What not to do

- Do not introduce cluster/shard/failover semantics into v1 storage or txn paths.
- Do not expand catalog/types “for future full PG” without an ADR and support-matrix update.
- Do not default production durability to async/unsafe modes.
- Do not treat checkpoint as user backup or PITR.
- Do not invent a custom client SDK as the primary access path; wire protocol is the product surface.

## Working style

- Match existing style when code appears; do not drive-by reformat or expand scope.
- When a change conflicts with an ADR or `CONTEXT.md`, stop and propose an ADR update first.
- Keep agent-facing rules in this file short; put long design narrative in ADRs / `CONTEXT.md`.
