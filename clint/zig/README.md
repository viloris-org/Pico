# RunaDB Zig SDK

Status: Draft. The public module entry point is `clint/zig/lib.zig`.

The SDK uses only the RunaDB Wire Protocol and RunaDB SQL. It does not import RunaDB
Server modules or access an instance data directory. The current compatibility
claim is intentionally narrow:

| Client package | RunaDB Wire Protocol | RunaDB Server |
| --- | --- | --- |
| Checked-out RunaDB Zig SDK | `0.1` | `RunaDB 0.0.1` in this checked-out revision |

Other server versions are unverified until they have a compatibility regression.
Run `zig build test` to build the independently deployable `runadb` binary and
exercise the SDK against it over native TCP.

`Connection.connect` performs version negotiation. `Connection.execute` returns
a result sequence containing row metadata and rows, a command completion, or a
server error. `SERVER_ERROR`, `COMMAND_COMPLETE`, and `GOODBYE` end that result
sequence. Call `Connection.deinit` to close a Connection and free client-owned
resources.

The protocol has no timeout, cancellation, or retry message in v0.1. A broken
Connection during a write leaves the commit outcome unknown; the SDK does not
retry it automatically.
