# RunaDB Zig SDK

Status: Draft. The public module entry point is `clint/zig/lib.zig`.

The SDK uses only the RunaDB Wire Protocol and Runa Flow. It does not import RunaDB
Server modules or access an instance data directory. The current compatibility
claim is intentionally narrow:

| Client package | RunaDB Wire Protocol | RunaDB Server |
| --- | --- | --- |
| Checked-out RunaDB Zig SDK | `3.0` | `RunaDB 0.0.1` in this checked-out revision |

Other server versions are unverified until they have a compatibility regression.
Run `zig build test` to build the independently deployable `runadb` binary and
exercise the SDK against it over native TCP.

`Connection.connect` performs version negotiation. `Connection.executeFlow` and
`Connection.executeIr` return
a result sequence containing row metadata and rows, a command completion, or a
server error. `SERVER_ERROR`, `COMMAND_COMPLETE`, and `GOODBYE` end that result
sequence. Call `Connection.deinit` to close a Connection and free client-owned
resources.

`Connection.observe` stages a payload in bounded protocol chunks and submits a
canonical `observe` IR request. It returns the committed `evidence_id` as a
normal result row. `Connection.readEvidencePayload` retrieves one payload and
validates its ID, declared length, chunk bounds, and BLAKE3-256 digest before
returning bytes to the caller. The payload limit is 8,388,608 bytes.

`Connection.insertDocument` ingests one document into a document collection
through a canonical `document_insert` IR request. It takes the collection name,
the document id, and a list of `{ path, value }` fields (dotted paths allowed);
the Server creates the collection on its first insert and rejects a duplicate
id. The result's single row carries the inserted `document_id`. Document reads
use `executeFlow` (or `executeIr`) with the ordinary `emit` request over the
collection.

`Connection.addNode` and `Connection.addEdge` ingest into a graph collection
through canonical `graph_add_node`/`graph_add_edge` IR. `addNode` takes the
graph name, a node id, and node fields, creating the graph on its first node;
`addEdge` takes the graph name and a `(from, label, to)` triple between two
existing nodes. Graph reads use `executeFlow` with the `navigate` stage, for
example `from social | navigate mentors as mentee | emit { name, mentee.name }`.

Protocol v3.0 defines a fire-and-forget `cancel_request`; in the sequential
runtime a cancel is delivered only between statements (a no-op by design), and
a delivered `CANCELED` result arrives with the concurrent runtime. There is no
timeout or retry message. The implemented Flow source slice is read-only;
Observation Evidence and document mutations are not retried automatically.
