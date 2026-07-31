# Engineering Module Boundaries

This reference owns the detailed dependency and delivery boundaries used by
[the build loop](../BUILDING.md). It does not supersede an ADR.

## Dependency Map

| Area | Owns | May depend on | Must not own or depend on |
| --- | --- | --- | --- |
| `clint/proto/` | Versioned shared messages and wire constants | Protocol-only utilities | Client or server internals |
| `clint/` | Official CLI, drivers, tools, SDKs, Connection state, protocol codec | `clint/proto/` | Data directory, server storage, transaction internals |
| `clint/zig/` | Zig SDK API, Connection lifecycle, result/error mapping, integration tests | Client modules, `clint/proto/` | `src/`, data directory, server policy |
| `src/net/` | Connection lifecycle, framing, backpressure, protocol error mapping | `src/sql/`, `src/util/`, `clint/proto/` | WAL, catalog, LSM, VFS, SQL storage policy |
| `src/sql/` | RunaDB SQL tokenize, parse, bind, validate, schedule execution | Transaction/catalog facade, `src/util/` | Wire framing, storage formats |
| `src/txn/` | Transaction state, snapshots, private writes, conflict inputs, commit requests | Catalog/storage facade, `src/util/` | Direct protocol handling or commit publication |
| `src/commit` (target) | Commit sequence, bounded queue, group commit, conflict validation, publication | Transaction, catalog, storage, `src/util/` | SQL parsing or network framing |
| `src/catalog` (target) | Database, table, column, constraint, index definitions | Storage, `src/util/` | SQL text, network framing, client state |
| `src/storage/wal` | WAL encode, append, validate, sync, recovery scan | VFS, `src/util/` | SQL text or protocol frames |
| `src/storage/lsm` (target) | Ordered-set reads/writes, memtables, immutable tables, manifests | VFS, pager, `src/util/` | SQL syntax, commit policy |
| `src/storage/compaction` (target) | Bounded maintenance and file preparation | LSM, VFS, `src/util/` | Commit ordering or direct publication |
| `src/storage/vfs` | Data-directory fencing, logical names, handles, positional I/O, atomic publication | `src/util/` | SQL, protocol, transaction policy |
| `src/storage/pager` | Fixed frames, pinning, dirty writeback, truncation for one file | VFS, `src/util/` | User commit semantics or recovery policy |
| `src/util/` | Small domain-neutral helpers | Standard library | SQL, wire, transaction, durability, storage policy |

Allowed direction:

```text
RunaDB Client --> clint/proto <-- src/net
                             |
src/net --> src/sql --> src/txn, src/catalog --> src/storage
                      src/txn --> src/commit --> src/storage
src/storage/{wal,lsm,pager} --> src/storage/vfs --> src/util
src/net, src/sql, src/txn, src/storage --------------------> src/util
```

The current `storage/engine` is a transitional facade for validate -> WAL
append -> apply -> recovery. New persistence code must not bypass it. Do not
add more than 50 lines of production logic to it in one change, except a
mechanical responsibility move that reduces it overall. Put complex new logic
in its target owner.

## Client And SDK Delivery

An official SDK uses only the RunaDB Wire Protocol and documented RunaDB SQL;
it never opens a data directory or imports server modules. It must declare the
RunaDB Wire Protocol and Server versions it supports and prove compatibility
against a real Server through its public API.

The SDK owns language-idiomatic lifecycle, statement/result consumption, error
mapping, and supported transaction controls. It must preserve framing, version
negotiation, backpressure, and server errors. A write retry is explicit and
opt-in where it may repeat a write; a broken Connection must report an outcome
consistent with the protocol.

For detailed public-change and test requirements, read
[change protocols](change-protocols.md) and [verification](verification.md).

