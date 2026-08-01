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

Protocol v3.0 defines a fire-and-forget `cancel_request`; in the sequential
runtime a cancel is delivered only between statements (a no-op by design), and
a delivered `CANCELED` result arrives with the concurrent runtime. There is no
timeout or retry message. The implemented Flow source slice is read-only;
Observation Evidence mutations are not retried automatically.
