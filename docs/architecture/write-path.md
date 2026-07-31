# Write Path and WriteBatch

> **Key files:** `src/storage/engine.zig` (single-writer engine facade), `src/storage/wal.zig` (`txn_batch` records), `src/txn/session.zig` (transaction write set), `src/sql/exec/insert.zig`, `src/sql/exec/update.zig`, `src/sql/exec/delete.zig`

## Overview

RunaDB uses **single-writer commit ordering** (see ADR-0005): one writer serializes the commit and
application of every change. A write is validated against constraints, persisted to WAL, and
then applied to the in-memory table (or a future LSM structure). Multiple operations in an
explicit transaction are bundled as an atomic `WriteBatch`, represented in RunaDB by a
`txn_batch` WAL record.

This document describes the write-path API, the WriteBatch representation and semantics, the two
write phases (transaction staging and commit), and the target single-writer batching design.

## Write API

### Single-Statement Writes (Autocommit)

Every DML statement in autocommit follows:

```
Client -> SQL parse/execute -> Engine.DML() -> Engine.validate()
                                           -> Wal.append{Insert|Update|Delete}()
                                           -> Table.{insert|update|delete}()
                                           -> return result
```

`Engine` provides:

| Method | Description |
|------|-------------|
| `insert(table, values)` | Insert one row, including constraint validation |
| `update(table, pk, values)` | Update by primary key |
| `delete(table, pk)` | Delete by primary key |
| `addColumn`, `dropColumn`, `setDefault`, `setNotNull` | DDL changes |

All methods follow `validate -> WAL -> apply`:

1. **Validate** constraints (PK uniqueness, `unique`, `not null`, type matching, and column existence). On failure return early and **do not write WAL**.
2. **Append WAL** by serializing the operation and writing it, including `fsync` when required.
3. **Apply** the operation to the in-memory table.

```mermaid
sequenceDiagram
    participant C as caller (SQL Exec)
    participant E as Engine
    participant T as in-memory Table
    participant W as WAL
    C->>E: insert("users", values)
    E->>T: validateInsert(values)
    T-->>E: ok/error
    alt validation fails
        E-->>C: error, no WAL write
    else validation succeeds
        E->>W: appendInsert(table, values)
        W-->>E: write confirmed
        E->>T: insert(values)
        T-->>E: ok
        E-->>C: success
    end
```

### Explicit Transaction Writes

Explicit transactions (`BEGIN` / `COMMIT` / `ROLLBACK`) use two write phases.

**Staging while the transaction is active:**

1. Each DML operation is staged in the `Session` private write set (`ArrayList(WriteOp)`).
2. Staging validates visibility against the **base table**, including PK and unique constraints against committed rows.
3. Staging performs incremental validation against the write set, so earlier operations in the same transaction affect later conflict checks.
4. The staged write set is invisible to other connections (a private MVCC write set).

**Commit:**

```
Client -> COMMIT -> Session.commit()
                   -> Session.validateAgainstWriteSet() (final validation)
                   -> toWalOp() (write set to TxnOp array)
                   -> Engine.commitTxnOps(ops)
                   -> Wal.appendTxnBatch(ops) (one atomic frame)
                   -> apply each op with Table.{insert|update|delete}()
                   -> clear write set
                   -> return COMMIT success
```

```mermaid
sequenceDiagram
    participant C as client
    participant S as Session
    participant E as Engine
    participant W as WAL
    participant T as Table
    Note over C,S: BEGIN
    C->>S: INSERT ... (DML)
    S->>S: stage in write set
    S-->>C: INSERT 1
    C->>S: INSERT ... (DML)
    S->>S: stage in write set
    S-->>C: INSERT 1
    Note over C,S: COMMIT
    C->>S: COMMIT
    S->>S: final validation
    S->>E: commitTxnOps(ops)
    E->>W: appendTxnBatch(ops)
    W-->>E: write confirmed
    E->>T: apply operations in order
    T-->>E: ok
    E-->>S: ok
    S->>S: clear write set
    S-->>C: COMMIT
```

**Rollback:**

```
ROLLBACK -> Session.rollback()
         -> clear write set (clear ArrayList)
         -> return ROLLBACK
```

Rollback performs no WAL or engine operation; it discards the private in-memory write set.

## WriteBatch Model

### `txn_batch` in RunaDB

RunaDB represents one explicit transaction as one atomic **`txn_batch` WAL record**:

```
WAL frame:
  [len: u32][crc32: u32][type_byte: txn_batch(9)]
  [n_ops: u16]
  [op_1_len: u32][op_1_payload]
  [op_2_len: u32][op_2_payload]
  ...
```

- Each `txn_batch` frame contains one or more nested `insert`/`update`/`delete` operations.
- One frame-level CRC covers the complete payload.
- Recovery either applies every operation in a complete, valid frame or discards the complete damaged/truncated frame.
- This provides transaction **atomicity** and **durability** once the commit is confirmed.

### `txn_batch` Contract

| Field or property | RunaDB contract |
|------|----------------|
| Commit order | No explicit sequence in Phase 0; operations are serialized by `Engine`. The target single writer allocates `commit_seq` at publication. |
| Operation count | `n_ops` is a 2-byte count. |
| Object identity | Every operation identifies its table by name; RunaDB has no storage namespace field in the record. |
| Integrity | One frame-level CRC32 protects the complete payload; keys are not protected independently. |
| Supported operations | Nested `insert`, `update`, and `delete` operations only. Merge and range-deletion operations are not part of RunaDB SQL. |

### WriteBatch Atomicity Boundary

- **Autocommit statement**: one WAL frame equals one operation (DML or DDL), implicitly atomic.
- **Explicit transaction**: one `txn_batch` WAL frame equals the complete write set.
- **DDL is currently forbidden in transactions**: DDL is not staged in an explicit transaction, avoiding complex metadata/row ordering dependencies during recovery.

## Two-Phase Write Details

### Write-Set Staging

The Session private write-set type is:

```zig
const WriteOp = union(enum) {
    insert: struct { table: []const u8, values: []value.Value },
    update: struct { table: []const u8, pk: value.Value, values: []value.Value },
    delete: struct { table: []const u8, pk: value.Value },
};
```

- Each `WriteOp` is a complete staged record with copied values.
- During staging, `visibleRow()` queries both the base table and prior write-set operations to maintain incremental consistency.
- Staging is allowed only when Session state is `active`.

### Final Validation

`Session.commit()` performs final validation before creating the WAL record:

1. Recheck constraints for every write-set operation (PK/unique conflicts).
2. Validate the read set (rows read by SELECT); if another commit changed one, report a serialization failure (target feature; read-set tracking is not implemented yet).

### Conversion to WAL Operations

`Session.toWalOp()` converts `ArrayList(WriteOp)` to `[]TxnOp`:

- Conversion releases staged-value ownership (shallow copy -> moved to the WAL encoder).
- `Engine.commitTxnOps()` accepts `[]TxnOp`.

## Single Writer and Group Commit (Target)

### Current Path

`Engine` is currently the single-writer facade. Each `commitTxnOps` call directly appends one
frame with `wal.appendTxnBatch(ops)` (and may sync), then serially applies each `applyTxnOp(op)`.
The WAL layer already shares durability rounds among concurrent appenders (`syncThrough`), so
multi-threaded writers can amortize `fdatasync` without an engine commit queue. A single
serialized client still pays one durability round per autocommit frame; engine-level batching
is the next step for multi-connection OLTP.

### Target: Group-Commit Queue

```mermaid
flowchart LR
    A["txn 1 commit request"] --> Q["commit queue\n(bounded FIFO)"]
    B["txn 2 commit request"] --> Q
    C["txn N commit request"] --> Q
    Q --> BATCH["form batch"]
    BATCH --> WAL["batched WAL write + one fsync"]
    WAL --> APPLY["serial apply to LSM"]
```

**Batch rules:**

1. Periodically or at a count threshold, collect queued commit requests into one batch.
2. Combine the batch's write sets into one WAL batch (one or more frames sharing one `fsync`).
3. Assign monotonically increasing commit sequences to each write set in the batch.
4. After WAL confirmation, apply each write set to LSM in sequence order.
5. Return success to clients before LSM confirmation; at the default durability level WAL sync already provides persistence.

**Benefits:** under high contention, `fsync` calls drop from once per transaction to once per batch,
and small transactions share batch-write overhead.

**Current status:** not implemented. Each `Engine.commitTxnOps` call performs one WAL write.
The `commit` module will add the queue and batching (see the evolution order in
`ARCHITECTURE.md`).

### Commit Request Contract (Target)

The boundary between `txn` and the single writer is a complete, immutable commit request. It
must contain enough logical information for the writer to make one deterministic decision; the
writer must not revisit the connection, rerun SQL text, or depend on a mutable execution object.

| Field | Owner before queueing | Purpose at the single writer |
| --- | --- | --- |
| `read_seq` | `txn` | Establishes which published write-range history must be checked. |
| Read conflict ranges | `txn` | Represents point, index, table, and catalog dependencies that could make the transaction's reads stale. |
| Write conflict ranges | `txn` | Is published into ordered conflict history after acceptance and protects later readers. |
| Observed-version stamps | `txn` | Revalidates rows targeted by update or delete against the published state. |
| Logical write set | `txn` | Supplies constraint validation, WAL encoding, and atomic catalog/table/index publication. |
| Durability level and result route | `connection` / `txn` | Determines the WAL persistence boundary and where a completion may be delivered; neither changes commit order. |

The writer processes requests in FIFO queue order. For each request it compares the read ranges
with writes published after `read_seq`, rechecks row and constraint invariants against earlier
accepted requests in the same round, and either rejects it or assigns the next `commit_seq`.
An accepted request contributes its write ranges before the next request is validated. Therefore,
two overlapping requests in one group-commit round have the same outcome they would have had if
the writer had processed them as separate rounds in that order.

### Write-Intensive Admission and Progress

The commit queue is a protection boundary, not an unbounded waiting room. It has explicit limits for request count and staged bytes; a request also has limits for operation count, encoded WAL size, conflict-range count, and conflict-range bytes. Connection and operation admission occurs before a strict transaction is issued a snapshot whenever possible; range limits are enforced as dependencies are collected and before a request enters the queue. When a limit is reached, RunaDB applies bounded backpressure and then rejects new work with an explicit retryable overload outcome rather than accepting unlimited memory growth or allowing a hot connection to monopolize the writer.

Group commit amortizes WAL sync only. It must not merge independent transactions, reorder accepted requests, skip per-transaction conflict/constraint validation, or make a group visible atomically as though it were one user transaction. Within a round, validate and assign commit sequences one request at a time, then write one or more complete transaction records before their shared strict durability round. A failed request does not prevent later independent requests from being considered, and never consumes a visible commit sequence.

Under sustained write load, RunaDB prioritizes predictable degradation:

1. Keep a small bounded batching window and a maximum batch byte/count budget, so queueing delay has an upper bound under normal admission.
2. Reserve queue capacity and WAL/I/O progress for commit, recovery, and manifest publication; compaction may prepare files concurrently but must yield before it exhausts the resources needed to make commits durable.
3. Reject oversized write sets before they can monopolize a group-commit round. Clients split independently valid work only when their application semantics permit it.
4. Measure hot primary-key, unique-index, and future strict-OCC range conflicts separately from queue or WAL saturation. Retries cannot fix a saturated device, and extra batching cannot fix a single hot logical key.
5. Return conflict and overload outcomes promptly. RunaDB Client drivers should retry only transactions declared retryable, using capped exponential backoff with jitter and an idempotency strategy for externally visible effects; the server never retries a transaction on the client's behalf.

Hot-key contention is primarily a data-model and workflow problem. Where application semantics allow it, distribute independently accumulated values across multiple rows and aggregate them later, or append independent work records and process their order-sensitive effects separately. These techniques preserve the normal strict path because they reduce overlap in logical write ranges; they are not permission to use stale reads, omit conflict ranges, or silently weaken constraints. Any future atomic-update syntax or server-side aggregation must define its conflict ranges, interaction with reset/constraint operations, WAL representation, and recovery behavior before it is advertised in RunaDB SQL.

The first implementation should expose queue depth/bytes, admission rejections, queue wait, batch count/bytes, successful commits, conflict outcomes by kind, WAL append and sync latency, write-set size, and compaction backlog. Report these by durability level and at least p50/p95/p99, so a low-latency async workload cannot mask strict-durability tail latency. Any per-connection quota or fairness policy is runtime scheduling, not a change to commit order.

## Durability Levels and Sync Policy

| Level | `sync_on_append` | Behavior | Guarantee |
|------|------------------|----------|-----------|
| Strict (default) | `true` | Data-sync each durability round | Confirmed commits survive process crash and power-loss models |
| Async | `false` | Write to the OS page cache and sync in batches | A process crash may lose the last unsynced frames |
| Manual | Configuration-controlled | The application explicitly calls `SyncWAL()` | The application is responsible |

- **Strict** is the default and recommended production setting.
- Async is suitable for development/testing or explicitly accepted data-loss risk.
- `Engine.open()` configures the durability level through `sync_wal`; expose it as a server setting.

## Error Handling and Rollback Paths

| Failure point | Behavior |
|--------|------|
| Constraint validation fails | Operation is not written to WAL; return an explicit error |
| WAL append fails | Operation is not durable; engine returns an I/O error |
| WAL sync fails | Same |
| In-memory table apply fails | WAL already contains the operation but memory apply failed, an internal inconsistency (not expected currently) |
| Commit-time validation fails | Discard the write set and return an error; no WAL cleanup is required |

**Future enhancement**: if WAL writing succeeds but memory application fails, record the WAL
truncation position and exclude that record during the next recovery. Current in-memory
application is a pure data-structure operation, so failure is currently expected only for OOM.

## Current Implementation vs Target

| Feature | Current (Phase 0) | Target |
|------|----------------|------|
| Single-writer path | `Engine` processes directly in sequence | Bounded commit queue + batching |
| Group Commit | WAL-layer shared durability among concurrent appenders | Engine commit queue + batched writes + shared `fsync` |
| WriteBatch | Single-operation DML frames / explicit-transaction `txn_batch` | Write-set planning integrated with the VDBE execution program |
| Commit sequence | None (implicit engine order) | Monotonic `commit_seq` (MVCC foundation) |
| Two-phase write | Session staging + `Engine.commitTxnOps` | Read-set tracking + serializable validation |
| Write stall | None | Bounded admission and explicit retryable overload; LSM/compaction pressure feeds back before resource exhaustion |
| Write amplification metrics | None | Write amplification, queue/admission, conflict, commit-latency, and batch-size metrics |

## RunaDB Decisions

- [ADR-0005 Single writer + MVCC concurrency model](../adr/0005-single-writer-mvcc.md): concurrency-model tradeoffs.
- [ADR-0006 WAL durability decision](../adr/0006-wal-durability-defaults.md): sync policy.
- [WAL and crash recovery](wal-and-recovery.md): WAL frame format and recovery semantics.
- [LSM storage engine design](lsm-storage.md): target LSM write path.
- [Concurrency control contract](concurrency-control.md): MVCC and commit order.
