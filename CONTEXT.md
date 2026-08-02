# RunaDB

RunaDB is a high-performance, general-purpose **unified data system** built in
Zig. Its target data model is a verifiable **World Continuum**: observations,
continuous state, representations, relationships, and hypotheses share common
query, governance, history, and integrity contracts. The current implementation
is a lightweight, single-instance, network-accessible OLTP baseline. Its write
path remains predictable under contention and it provides recoverable durable
storage. Runa Flow is the native formal data language. The legacy RunaDB SQL
parser, executor, and protocol endpoints have been removed.

## Language

### Product and Deployment

**RunaDB**:
The database product ecosystem consisting of **RunaDB Server** and **RunaDB Client**. The two products work together through the RunaDB Wire Protocol and, in the target contract, Runa Flow.
_Avoid_: Equating RunaDB with a single binary, engine, or kernel (unless specifically referring to the storage subsystem)

**RunaDB Server**:
The independently deployable database server process built in this repository. It owns the data and defines transaction, durability, and recovery semantics.
_Avoid_: Built-in client, database engine (unless specifically referring to the storage subsystem)

**RunaDB Client**:
The independently released product that provides the official CLI, drivers, and developer tools. It does not read the data directory or depend on internal server modules.
_Avoid_: Server CLI, built-in driver, server SDK

**Instance**:
A running RunaDB Server deployment and its associated persistent state. The
current baseline is **single-node, single-instance**; future distributed
deployments must define their own topology, placement, and consistency terms.
_Avoid_: Treating an instance as a cluster member before a distributed contract exists

**Data Directory**:
The local directory containing an instance's persistent state, including the WAL, data files, and catalog metadata. Each instance corresponds to one data directory.
_Avoid_: Database file (which implies a single file), repository

### Connections and Protocols

**Connection**:
A network session between a client and an instance. It carries authentication, session state, and requests and responses.
_Avoid_: Session (prefer Connection when it could be confused with a transaction session), Socket (an implementation detail)

**RunaDB Wire Protocol**:
The versioned message contract defined by RunaDB and exchanged over a connection. It is RunaDB's external interface and does not promise compatibility with the PostgreSQL Frontend/Backend Protocol.
_Avoid_: API, RPC (unless referring to an internal module boundary), "PostgreSQL-compatible protocol"

**RunaDB Client**:
An official CLI, driver, or tool in the RunaDB Client product. RunaDB Client releases its language coverage, version policy, and support scope separately and declares its support for RunaDB Server through a compatibility matrix. The official Zig SDK (`sdk/zig/`) is a specific RunaDB Client tool defined in ADR-0023.
_Avoid_: Driver compatibility, `psql` / libpq / pgx compatibility, dedicated SDK (use `sdk/zig/` when a specific SDK tool is meant)

### Data Model

**Database**:
A named namespace within an instance that holds a set of **relations** and catalog objects. A client selects the current database when connecting.
_Avoid_: Schema (until a PG-style schema hierarchy is introduced), Catalog (use only when specifically referring to the system catalog)

**Relation / Table**:
A named set of rows with declared column definitions. It is the current primary
user-visible storage object. The terms are interchangeable in informal speech,
but documentation should prefer **table**.
_Avoid_: Collection, Bucket, Namespace (when referring to a table)

**Data Model**:
The semantic representation used for a class of data and operations, such as
relational, document, graph, vector, time-series, key-value, or spatial. A
model is not a separate database product; when supported, it participates in
RunaDB's common catalog, governance, history, and query semantics.
_Avoid_: Multi-model as a claim that all listed models are already implemented

**Multimodal Value**:
A typed value representing or referring to text, image, audio, video, sensor,
or other non-tabular content, together with declared metadata and ownership.
Its interpretation, embedding, and derived features are not interchangeable
with the source value.
_Avoid_: Blob when the type, provenance, or semantic role is relevant

**World Continuum**:
The target logical state of an instance: a versioned, governed continuum of
Continuum Objects, Observation Evidence, State Fields, Representation Charts,
and Counterfactual Branches. It is not a claim that a single learned coordinate
system can replace factual evidence or declared semantics.
_Avoid_: Vector database, file store plus embeddings, universal embedding

**Continuum Object**:
A stable logical identity in a World Continuum with declared kind, temporal
extent, relationships, and state bindings. It replaces a table, document,
key-value entry, or media item as the target primary user-visible data
abstraction; those are views or bindings, not competing top-level models.
_Avoid_: Row, document, record, entity when its continuum identity matters

**Observation Evidence**:
An immutable, attributed observation accepted as factual input to a World
Continuum. It preserves the information, origin, time, coordinate reference,
and declared interpretation needed to validate or re-project later state.
_Avoid_: Raw file, blob, ground truth (unless independently established)

**State Field**:
A versioned, continuous or discretized estimate of state over one or more
declared domains such as time, space, relationships, or latent coordinates.
It is derived from Observation Evidence or a declared transition and is not
silently interchangeable with factual evidence.
_Avoid_: Embedding column, cache, truth

**Representation Chart**:
A versioned declaration of a coordinate domain, projection or decoding model,
input coverage, uncertainty semantics, and compatibility rules for a State
Field. It permits multiple evolving representations without silently
reinterpreting existing state.
_Avoid_: Model version when the coordinate and coverage contract matters

**Causal Dynamics**:
A declared, versioned transition and intervention contract for how a State
Field may evolve under stated conditions. Its predictions are model-derived
hypotheses, not Observation Evidence.
_Avoid_: World model when the transition or intervention contract is relevant

**Counterfactual Branch**:
An isolated, versioned hypothetical World Continuum state produced under
declared assumptions, interventions, and model versions. It cannot become
factual state merely by being computed.
_Avoid_: Prediction, simulation result, alternate reality when the assumptions
and isolation boundary matter

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

**Request**:
A client-submitted operation, represented as Runa Flow source, Runa Query IR,
or a validated administrative form. It is executed sequentially on a Connection
or according to protocol rules.
_Avoid_: Statement (SQL-specific), Query (use Query only for a read operation)

**Runa Flow**:
RunaDB's target native formal data language. It expresses requests as typed,
ordered pipelines that bind semantic names before physical planning.
_Avoid_: RunaDB SQL, SQL dialect, SQL-compatible

**Runa Query IR**:
The canonical, versioned, serializable typed representation of a Runa Flow
request after semantic binding and validation.
_Avoid_: AST (which is source-oriented), execution plan (a physical artifact)

**Semantic Model**:
Versioned catalog metadata that declares entities, relationships, attributes,
measures, constraints, policy references, and temporal meanings independently
from physical storage bindings.
_Avoid_: Physical schema, table schema, ontology (unless a dedicated contract defines it)

**Natural-Language Request**:
Advisory input that may compile into candidate Runa Flow and Runa Query IR. It
does not execute until the same validation boundary as a formal request accepts
the resulting IR.
_Avoid_: Natural-language query (which implies direct execution), prompt as an execution contract

**Agent**:
A Continuum Object that can hold declared goals, memory, observations,
relationships, and action proposals. An Agent does not receive authority to
change factual state except through validated Requests and ordinary policy.
_Avoid_: Autonomous actor when policy, approval, or rollback is absent

**Transaction**:
An atomic unit of work consisting of a group of Requests, or one autocommitted
Request. Its language surface is a versioned protocol contract.
_Avoid_: Batch (a write-path implementation technique, not user transaction semantics)

**Snapshot**:
The view of data visible to a transaction at a point in time. Reads operate on snapshots, making non-blocking reads possible.
_Avoid_: Backup snapshot (in physical backup contexts, explicitly say "backup point")

**Historical Version**:
A retained, immutable representation of a committed value or object state that
can be addressed by valid time, transaction time, or a declared version
identifier. Retention and time-travel visibility must be explicit; they are not
implied by MVCC alone.

**Provenance**:
Metadata and evidence describing the origin, transformations, ownership, and
derivations of data or a result. Provenance is verifiable only when its
integrity mechanism, retention, and trust boundary are defined.
_Avoid_: Lineage as a vague synonym when the required evidence is unclear

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
The path from a Request producing a modification to its entry in the WAL and
storage structures. The product prioritizes predictable throughput under high
contention and must not crash because of lock storms.
_Avoid_: Insert path (which covers only one kind of Request)

**Contention**:
Competition that occurs when multiple transactions modify the same or adjacent data simultaneously. The design goal is **predictable degradation**, not silent hangs on hot spots.
_Avoid_: Lock (an implementation mechanism), conflict (usable for a narrower write-write conflict)

### AI, Governance, and Evolution

**AI-Assisted Execution**:
Use of learned models to retrieve, rank, interpret, optimize, or operate on
data. It must preserve the same authorization and auditable execution boundary
as direct Runa Flow. A learned output does not override declared constraints or
transaction semantics.
_Avoid_: Autonomous when an operator policy, approval, or rollback path is absent

**Neuro-Symbolic Execution**:
Execution that combines learned interpretation with symbolic predicates,
constraints, or reasoning. Symbolic results remain the source of truth for
precise logic and access decisions.

**MEMO (Memory as a Model)**:
RunaDB's target memory and retrieval capability, per ADR-0022. Knowledge from
a target corpus is encoded into a compact **Memory model**; a frozen reasoning
model (**Executive model**) retrieves from it through a structured multi-turn
protocol. A **reflection** is a self-contained, corpus-derived question-answer
pair used to train the Memory model. MEMO replaces the frozen embedding and
RAG primitives of ADR-0020.
_Avoid_: Retrieval-augmented generation, embedding index, vector search as the
current or future public retrieval capability

**Reflection**:
A self-contained, corpus-derived question-answer pair that exposes underlying
corpus knowledge without requiring access to the source document. Reflections
are derived training representations, not Observation Evidence.
_Avoid_: Ground truth, factual record

**Memory Model**:
The compact model trained to answer from its parameters alone, encoding
knowledge from a target corpus as a learned State Field. Its Representation
Chart declares the training corpus, Generator model lineage, coverage,
uncertainty, and compatibility rules.
_Avoid_: Vector index, retrieval cache, embedding store

**Executive Model**:
The frozen reasoning model that answers user queries by querying the Memory
model through the MEMO retrieval protocol. It is treated as a black box;
RunaDB does not access its weights, gradients, or output logits.
_Avoid_: Hosted model, in-process inference on the critical path

**Generator Model**:
The external LLM used offline to distill a target corpus into a reflection QA
dataset for Memory model training. It may be smaller than the Executive model.
_Avoid_: Retrieval model, ranker, in-database inference

**Consistency Level**:
The declared visibility and ordering guarantees for reads and writes across an
identified scope. Strong consistency, eventual consistency, and any intermediate
level are distinct contracts; a deployment topology does not imply one.

**Cryptographic Agility**:
The ability to version, migrate, and retire cryptographic algorithms and keys
without making protected data unreadable or weakening its declared protection.
It includes planning for post-quantum cryptography, but does not claim it is
currently implemented.

**Energy Efficiency**:
The measured resource cost of storing, moving, and computing over data. It is a
product metric alongside latency, throughput, durability, and recovery time.

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
The sequence of operations compiled from a bound Request, together with one
execution instance of that sequence (registers, cursors, and program counter).
External compatibility with SQLite bytecode is not promised; product
descriptions should primarily discuss Runa Flow execution when it is supported.
_Avoid_: Virtual machine (easily confused with the whole instance or an OS VM), treating direct AST interpretation as the long-term architectural endpoint without stating the boundary

**Opcode**:
A single-step instruction in an execution program. Documentation should state whether it performs I/O, is a cancellation point, or only modifies the write set.
_Avoid_: Bytecode ABI (not a stable external interface without a separate ADR)

**Cursor**:
An execution-layer handle for ordered iteration or point lookup over a table or secondary index under a particular **snapshot**. It does not expose SST filenames or page numbers as SQL semantics.
_Avoid_: Declarative SQL cursor syntax (do not present it as a product feature before it is supported)

## Example dialogue

> **Developer**: Can the current implementation connect with `psql` or execute SQL?
> **Domain**: No. The external contracts are the versioned **RunaDB Wire Protocol**, **Runa Flow**, and **Runa Query IR**. A future compatibility adapter would require a focused ADR and could not define language, type, or transaction semantics.
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
> **Developer**: Can storage directly call `open("/var/runadb/../other/wal")`?
> **Domain**: No. It must go through **VFS** and use only logical filenames within the **data directory**. Path traversal is an error, not something to "normalize" for you.
>
> **Developer**: Does Pager `sync` mean **COMMIT** succeeded?
> **Domain**: No. The durability boundary of a user **commit** is WAL plus single-writer publication; Pager only manages cached writeback for a page file.
>
> **Developer**: Should we provide external compatibility with SQLite VDBE bytecode?
> **Domain**: No. Internally there may be an **execution program** and opcodes; that is an implementation layer. Externally, the target product is the **RunaDB Wire Protocol** plus **Runa Flow**.

## Flagged ambiguities

- **Session**: Frequently mixed with Connection at the protocol layer. RunaDB documentation uses **Connection** by default; when referring to session-level state outside transaction boundaries (time zone, search_path, and so on), write "session state" and do not introduce an undefined Session entity by itself.
- **Schema**: Has a namespace meaning in PostgreSQL; until RunaDB introduces an equivalent, avoid using schema to mean "table structure" or "database." Say "table definition / column definition" for table structure.
- **Query**: Can mean any Request in informal speech; where documentation needs a distinction, Query means a read-only Request and Request means any operation.
- **Security**: In product discussions, "secure enough" means **fault and durability** (crash recovery, validation, and durability level), not access control or encryption. Authentication and authorization are separate capabilities and must not be conflated with durability as "security."
- **VDBE**: Usable when comparing with SQLite; in product documentation, prefer **execution program** and state that SQLite bytecode is not compatible.
- **Pager**: Do not assume it means "SQLite pager with a journal"; RunaDB's Pager is a static page cache plus a file backend, and the primary recovery path remains the WAL.
