# Pico

Pico is a **lightweight, single-node, network-accessible** OLTP database built in Zig. It is easy to deploy, uses few resources, and starts quickly. Its write path remains predictable under high contention, it provides the fault recovery and durability expected of a public product, and it supports an independent ecosystem built around the Pico Wire Protocol and Pico SQL without promising PostgreSQL compatibility.

## Language

### Product and Deployment

**Pico**:
The database product ecosystem consisting of **Pico Server** and **Pico Client**. The two products work together through the Pico Wire Protocol and Pico SQL.
_Avoid_: Equating Pico with a single binary, engine, or kernel (unless specifically referring to the storage subsystem)

**Pico Server**:
The independently deployable database server process built in this repository. It owns the data and defines transaction, durability, and recovery semantics.
_Avoid_: Built-in client, database engine (unless specifically referring to the storage subsystem)

**Pico Client**:
The independently released product that provides the official CLI, drivers, and developer tools. It does not read the data directory or depend on internal server modules.
_Avoid_: Server CLI, built-in driver, server SDK

**Instance**:
A running Pico process and its associated data directory. The current product is **single-node, single-instance** and is not a cluster.
_Avoid_: Node (before replication/clustering is introduced), cluster member

**Data Directory**:
The local directory containing an instance's persistent state, including the WAL, data files, and catalog metadata. Each instance corresponds to one data directory.
_Avoid_: Database file (which implies a single file), repository

### Connections and Protocols

**Connection**:
A network session between a client and an instance. It carries authentication, session state, and requests and responses.
_Avoid_: Session (prefer Connection when it could be confused with a transaction session), Socket (an implementation detail)

**Pico Wire Protocol**:
The versioned message contract defined by Pico and exchanged over a connection. It is Pico's external interface and does not promise compatibility with the PostgreSQL Frontend/Backend Protocol.
_Avoid_: API, RPC (unless referring to an internal module boundary), "PostgreSQL-compatible protocol"

**Pico Client**:
An official CLI, driver, or tool in the Pico Client product. Pico Client releases its language coverage, version policy, and support scope separately and declares its support for Pico Server through a compatibility matrix.
_Avoid_: Driver compatibility, `psql` / libpq / pgx compatibility, dedicated SDK (until a specific tool is defined)

### Data Model

**Database**:
A named namespace within an instance that holds a set of **relations** and catalog objects. A client selects the current database when connecting.
_Avoid_: Schema (until a PG-style schema hierarchy is introduced), Catalog (use only when specifically referring to the system catalog)

**Relation / Table**:
A named set of rows with fixed column definitions. It is the primary user-visible storage object. The terms are interchangeable in informal speech, but documentation should prefer **table**.
_Avoid_: Collection, Bucket, Namespace (when referring to a table)

**Row**:
A record in a table composed of column values. Under MVCC, it may correspond to multiple **versions**.
_Avoid_: Document, Tuple (unless discussing the physical or algebraic layer)

**Primary Key**:
A key that uniquely identifies a row in a table. It is the default basis for locating updates and deletes on the write path.
_Avoid_: ID (when it is not clear whether it is a primary key)

**Secondary Index**:
An auxiliary access path built on non-primary-key columns (or expressions, if supported in the future). It does not change the table's primary storage identity.
_Avoid_: Key (when used alone and therefore ambiguous)

**Catalog**:
System metadata describing objects such as databases, tables, columns, and indexes. It is distinct from user table data.
_Avoid_: Schema definition (which is easily confused with an SQL schema)

### Queries and Transactions

**Statement**:
An SQL text submitted by a client, or its parsed form. It is executed sequentially on a connection or according to protocol rules.
_Avoid_: Request (too broad), Query (use Query only for SELECT when a distinction is needed)

**Pico SQL**:
The intentionally supported, OLTP-oriented scope of the Pico SQL dialect. Only the statements, types, and semantics in the published support matrix are promised; PostgreSQL SQL is not the compatibility target.
_Avoid_: PostgreSQL-compatible, PostgreSQL SQL subset, complete dialect

**Transaction**:
An atomic unit of work consisting of a group of statements, delimited by **BEGIN / COMMIT / ROLLBACK**, or by a single autocommitted statement.
_Avoid_: Batch (a write-path implementation technique, not user transaction semantics)

**Snapshot**:
The view of data visible to a transaction at a point in time. Reads operate on snapshots, making non-blocking reads possible.
_Avoid_: Backup snapshot (in physical backup contexts, explicitly say "backup point")

**Commit**:
The successful completion of a transaction. Its write set becomes visible to later snapshots and enters the persistence path according to the current **durability level**.
_Avoid_: Flush, Sync (implementation actions, not user semantics)

**Rollback**:
A transaction abandons its write set and produces no externally visible effect.

### Durability and Faults

**Durability Level**:
The configurable strictness of persistence for an instance, session, or workload. It determines the strength of the guarantees after commit in the event of a process crash or machine power loss.
_Avoid_: fsync switch (an implementation control that should be mapped externally to a durability level)

**WAL (Write-Ahead Log)**:
An append-only log written before data files. It is the basis for crash recovery and establishes durability ordering for the write path.
_Avoid_: binlog (unless replication integration is being discussed), redo log (acceptable as an internal synonym; use WAL consistently in external documentation)

**Recovery**:
The process of bringing an instance's state to a consistent point at startup using the WAL and checkpoints. It must complete within an acceptable startup time.
_Avoid_: Repair (which implies rescuing damaged data), replay (which emphasizes an implementation step)

**Checkpoint**:
The process of materializing persisted progress into data files and manifests so that old WAL can be truncated or reclaimed.
_Avoid_: Snapshot (to distinguish it from an MVCC snapshot), backup

### Concurrency and the Write Path

**Write Path**:
The path from a statement producing a modification to its entry in the WAL and storage structures. The product prioritizes predictable throughput under high contention and must not crash because of lock storms.
_Avoid_: Insert path (which covers only one kind of statement)

**Contention**:
Competition that occurs when multiple transactions modify the same or adjacent data simultaneously. The design goal is **predictable degradation**, not silent hangs on hot spots.
_Avoid_: Lock (an implementation mechanism), conflict (usable for a narrower write-write conflict)

**Single Writer**:
A concurrency model in which only one execution flow applies changes and orders commits at a time (see the ADR). Readers may run in parallel.
_Avoid_: Single-threaded (the implementation may use multiple threads while serializing mutation)

### Storage Files and Execution

**VFS (Virtual File System)**:
A storage-file abstraction bound to a **data directory**. It validates logical filenames, manages handle lifetimes, provides positional I/O and synchronization, and atomically publishes manifests, SSTables, and similar artifacts. The storage layer uses only logical names and does not construct absolute paths.
_Avoid_: Pluggable multi-filesystem product feature, passing OS paths directly to WAL/LSM

**Page**:
A fixed-size disk and cache unit addressed by page number. Its offset is `page_id * page_size`. It is used by files requiring page-oriented layouts, not for a user-visible "row" or SQL page.
_Avoid_: Using "page" for network protocol frames or result-set pagination (say LIMIT/OFFSET or result streams for the latter)

**Pager**:
A module that provides page acquisition, pinning, dirty marking, writeback, and truncation for a single file. It does **not** define transaction or crash-recovery policy on its own.
_Avoid_: Treating Pager as SQLite's complete pager subsystem with a rollback journal

**Static Page Cache**:
A cache with a fixed number and size of page frames determined at compile time (or once at startup). The `acquire` path does not grow the page-frame pool using the general-purpose heap and fails explicitly when exhausted (for example, with `CacheFull`).
_Avoid_: A soft limit that recommends `cache_size` and mallocs when insufficient; treating cache hits as a source of correctness

**Execution Program / VDBE**:
The sequence of operations compiled from a bound statement, together with one execution instance of that sequence (registers, cursors, and program counter). External compatibility with SQLite bytecode is not promised; product descriptions should primarily discuss execution of the SQL subset.
_Avoid_: Virtual machine (easily confused with the whole instance or an OS VM), treating direct AST interpretation as the long-term architectural endpoint without stating the boundary

**Opcode**:
A single-step instruction in an execution program. Documentation should state whether it performs I/O, is a cancellation point, or only modifies the write set.
_Avoid_: Bytecode ABI (not a stable external interface without a separate ADR)

**Cursor**:
An execution-layer handle for ordered iteration or point lookup over a table or secondary index under a particular **snapshot**. It does not expose SST filenames or page numbers as SQL semantics.
_Avoid_: Declarative SQL cursor syntax (do not present it as a product feature before it is supported)

## Example dialogue

> **Developer**: The current implementation can connect with `psql`. Does that count as a Pico product compatibility commitment?
> **Domain**: No. That is an implementation detail of the migration adapter; the external contracts are the versioned **Pico Wire Protocol** and **Pico SQL**. The adapter must not define SQL, type, or transaction semantics.
>
> **Developer**: If two connections modify the same primary key at the same time, is that **contention** or a fault?
> **Domain**: It is **contention**. One **transaction** will **commit**; the other waits according to isolation rules or fails with a write conflict. The **write path** must remain predictable and must not lock up the entire instance.
>
> **Developer**: After `kill -9` and a restart, is the data still there?
> **Domain**: It depends on the **durability level**. At the default level, modifications that were **committed** and entered the **WAL** persistence path should be visible after **recovery**; an uncommitted **transaction** is treated as **rolled back**.
>
> **Developer**: Is a **checkpoint** for users to make backups?
> **Domain**: No. A checkpoint is an internal instance mechanism for truncating the WAL and advancing persistence progress. A point-in-time copy requested by a user should be called a backup and defined separately.
>
> **Developer**: Can one **instance** serve as three "databases"?
> **Domain**: Yes, an instance can contain multiple **databases**, each with its own **tables** and **catalog** objects. However, there is currently no cluster semantics involving multiple instances.
>
> **Developer**: Can storage directly call `open("/var/pico/../other/wal")`?
> **Domain**: No. It must go through **VFS** and use only logical filenames within the **data directory**. Path traversal is an error, not something to "normalize" for you.
>
> **Developer**: Does Pager `sync` mean **COMMIT** succeeded?
> **Domain**: No. The durability boundary of a user **commit** is WAL plus single-writer publication; Pager only manages cached writeback for a page file.
>
> **Developer**: Should we provide external compatibility with SQLite VDBE bytecode?
> **Domain**: No. Internally there may be an **execution program** and opcodes; that is an implementation layer. Externally, the product is the **wire protocol** plus the **SQL subset**.

## Flagged ambiguities

- **Session**: Frequently mixed with Connection at the protocol layer. Pico documentation uses **Connection** by default; when referring to session-level state outside transaction boundaries (time zone, search_path, and so on), write "session state" and do not introduce an undefined Session entity by itself.
- **Schema**: Has a namespace meaning in PostgreSQL; until Pico introduces an equivalent, avoid using schema to mean "table structure" or "database." Say "table definition / column definition" for table structure.
- **Query**: Can mean any statement in informal speech; where documentation needs a distinction, Query means a read-only statement and Statement means any statement.
- **Security**: In product discussions, "secure enough" means **fault and durability** (crash recovery, validation, and durability level), not access control or encryption. Authentication and authorization are separate capabilities and must not be conflated with durability as "security."
- **VDBE**: Usable when comparing with SQLite; in product documentation, prefer **execution program** and state that SQLite bytecode is not compatible.
- **Pager**: Do not assume it means "SQLite pager with a journal"; Pico's Pager is a static page cache plus a file backend, and the primary recovery path remains the WAL.
