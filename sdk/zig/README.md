# RunaDB Zig SDK

Status: **Draft.** The public module entry point is `sdk/zig/lib.zig`
(`@import("sdk_zig")` in this repository; the package is
`.runadb_zig_sdk`). The SDK uses only the RunaDB Wire Protocol and Runa
Flow; it does not import RunaDB Server modules or access an instance data
directory. See ADR-0023 for the SDK directory and transport decisions. The
TCP and QUIC transports are verified in this checkout (see Transports); the
SDK package as a whole is not a release claim.

## Compatibility

| Client package | RunaDB Wire Protocol | RunaDB Server | Transport |
| --- | --- | --- | --- |
| Checked-out RunaDB Zig SDK | `3.0` | `RunaDB 0.0.1` in this checked-out revision | TCP (verified), QUIC (verified) |

Other server versions are unverified until they have a compatibility
regression. Run `zig build test` to build the independently deployable
`runadb` binary and exercise the SDK against it over native TCP and QUIC
(the QUIC listener and the SDK QUIC transport, roadmap Phase 9).

## Transports (ADR-0023)

- **TCP** is implemented and verified in this checkout (port 5434); the CLI
  still defaults to it until the Phase 9 migration condition (ADR-0024) is
  met.
- **QUIC** (vendored zquic, ALPN `runadb`, UDP 5435) is the target default
  transport and is verified end to end in this checkout: the server QUIC
  listener (`src/net/quic.zig`, ADR-0023 §2.1 stream contract) is exercised
  by the SDK QUIC client through the public API, and the integration suite
  covers certificate pinning regressions (no pin / correct pin / wrong pin),
  a request round-trip, and idle-timeout behavior. A QUIC connect against a
  server without a QUIC listener fails with a defined error
  (`HandshakeTimeout`, `QuicRejected`, `CertificateMismatch`) — there is no
  silent TCP fallback.

Select the transport explicitly:

```zig
var conn = try sdk.Connection.connect(gpa, io, .{
    .host = "127.0.0.1",
    .kind = .quic,   // verified in this checkout (server QUIC listener)
    // .kind = .tcp, // also verified; CLI default until ADR-0024
});
```

QUIC server identity is pinned: pass `server_cert_pem` (the PEM of the
expected server certificate) and the SDK compares the SHA-256 digest of the
presented leaf certificate, failing with `CertificateMismatch` on difference.
Without a pin, the connection proceeds and the presented certificate's SHA-256
digest is exposed as `Connection.server_cert_digest` for trust-on-first-use
inspection (full X.509 chain validation is future work). The QUIC idle
timeout is configurable with `Config.idle_timeout_ms` (RFC 9000 §10.1, default
30 000 ms, matching the server listener); a connection whose peer stays
silent past the effective timeout is reaped, and a subsequent request fails
with the SDK's bounded read timeout.

## API

`Connection.connect` performs version negotiation. `Connection.executeFlow`
and `Connection.executeIr` return a result sequence containing row metadata
and rows, a command completion, or a server error. `SERVER_ERROR`,
`COMMAND_COMPLETE`, and `GOODBYE` end that result sequence. Call
`Connection.deinit` to close a Connection and free client-owned resources.
The sequential statement contract is preserved: consume or drain a
`QueryResult` before issuing the next statement; issuing a request while a
result sequence is in flight fails with `StatementInProgress`.

### Typed rows and result helpers

`QueryResult` offers a typed row surface in addition to the raw message
iterator (`QueryResult.next`). `nextRow` skips the leading `ROW_DESCRIPTION`
and returns each data row as a `Row` with named, typed column access
(`row.text(i)`, `row.int(i)`, `row.uint(i)`, `row.boolean(i)`, `row.isNull(i)`,
and `row.indexOf("name")`), returning `null` at the statement's terminal
message:

```zig
var result = try conn.executeFlow(arena, "from books\n| emit { title, pages }");
while (try result.nextRow(arena)) |row| {
    const title = row.text(0).?; // optional: null for NULL cells
    const pages = try row.int(1);
}
```

Single-row statements (`observe`, `insertDocument`, `addNode`, `addEdge`)
return exactly one row and can be consumed with `result.expectOneRow(arena)`.
A failed statement surfaces as `error.StatementFailed`, with the severity,
code, and message available on `result.failure`; `result.affectedRows(arena)`
returns the committed row count from `COMMAND_COMPLETE`, and
`result.ensureSuccess(arena)` drains, failing on error.

`Connection.observe` stages a payload in bounded protocol chunks and submits a
canonical `observe` IR request. It returns the committed `evidence_id` as a
normal result row. `Connection.readEvidencePayload` retrieves one payload and
validates its ID, declared length, chunk bounds, and BLAKE3-256 digest before
returning bytes to the caller. The payload limit is 8,388,608 bytes.

`Connection.insertDocument` ingests one document into a document collection
through a canonical `document_insert` IR request. It takes the collection
name, the document id, and a list of `{ path, value }` fields (dotted paths
allowed); the Server creates the collection on its first insert and rejects a
duplicate id. The result's single row carries the inserted `document_id`.
Document reads use `executeFlow` (or `executeIr`) with the ordinary `emit`
request over the collection.

`Connection.addNode` and `Connection.addEdge` ingest into a graph collection
through canonical `graph_add_node`/`graph_add_edge` IR. `addNode` takes the
graph name, a node id, and node fields, creating the graph on its first node;
`addEdge` takes the graph name and a `(from, label, to)` triple between two
existing nodes. Graph reads use `executeFlow` with the `navigate` stage, for
example `from social | navigate mentors as mentee | emit { name, mentee.name }`.

`Connection.putKv` upserts one key/value pair into a KV collection through a
canonical `kv_put` IR request. It takes the collection name, a text key, and a
scalar value; the Server creates the collection on its first put and replaces
the value of an existing key. The result's single row carries the stored `key`
and `value`. KV reads use `executeFlow` with the ordinary `emit` request over
the collection, for example `from session | where key = 'theme' | emit { key,
value }`.

Protocol v3.0 defines a fire-and-forget `cancel_request`; in the sequential
runtime a cancel is delivered only between statements (a no-op by design), and
a delivered `CANCELED` result arrives with the concurrent runtime. There is
no timeout or retry message. The implemented Flow source slice is read-only;
Observation Evidence and document mutations are not retried automatically.

## QUIC stream contract (ADR-0023 §2.1)

One TLS 1.3 connection (ALPN `runadb`) carries the RunaDB Wire Protocol over
zquic: client bidi stream 0 is the control stream (`hello` / `hello_ok` /
`hello_error`, `cancel_request`, `goodbye`); each request opens the next
client bidi stream (4, 8, 12, …), writes the request messages, half-closes
its send side, and reads the result sequence until `command_complete` /
`server_error` / `goodbye`. Message types and serialization are unchanged
from `clint/proto/def.zig`.

## Building the SDK on its own

```bash
cd sdk/zig
zig build test
```

The package build wires `clint/proto/`, the vendored zquic transport
(`lib/zquic/`), and the vendored `zig_varint` dependency
(`zig-pkg/`) from the repository layout.
