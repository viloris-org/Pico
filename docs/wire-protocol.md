# RunaDB Wire Protocol v0.1

Status: Draft legacy implementation reference. This document specifies the
currently implemented native TCP transport framing and message sequence. The
RunaDB Wire Protocol is RunaDB's public contract; it does not promise compatibility
with the PostgreSQL Frontend/Backend Protocol. ADR-0017 defines Runa Flow and
Runa Query IR as the target query contract for the next incompatible protocol
major version; this v0.1 document continues to describe the current SQL-text
payload only.

## Compatibility

The protocol version is a `(major, minor)` pair. The current version is `0.1`.
A server accepts a `HELLO` only when its major version is `0`; it currently
accepts any minor version in that major line. A different major version receives
`HELLO_ERROR` with the reason `unsupported protocol version`, after which the
Connection closes.

RunaDB Client and RunaDB Server versions are independent. A released client or
server must declare the protocol versions it supports and verify that support
through the public protocol boundary.

The checked-out RunaDB Zig SDK supports protocol version `0.1` and uses the native
TCP transport described here. Its current server-version compatibility claim and
API lifecycle are in [RunaDB Zig SDK](../clint/zig/README.md). `zig build test`
launches the independently built `runadb` server and exercises Connection setup,
statement execution, result consumption, server errors, and Connection close
through the public client package.

## Framing

Each message is encoded as:

```text
u32 big-endian body length | u8 message type | body payload
```

The body length includes the type byte and is between 1 and 1,048,576 bytes.
Strings are encoded as a `u32` big-endian byte length followed by that many
UTF-8 bytes, and are limited to 65,536 bytes. Receivers reject malformed
lengths, truncated fields, invalid null flags, invalid severity values, and
unexpected trailing bytes in a message body. A malformed transport frame or
message shape closes the responsible Connection without changing shared server
state. A syntactically framed `QUERY` with an invalid query payload instead
receives `SERVER_ERROR P0000` and leaves the Connection available for another
statement.

## Message Sequence

1. The client sends `HELLO` (`0x01`) with exactly two big-endian `u16` values:
   protocol major then protocol minor.
2. The server replies with `HELLO_OK` (`0x02`) and its length-prefixed version
   string, or `HELLO_ERROR` (`0x03`) and a length-prefixed reason.
3. An accepted client sends one `QUERY` (`0x10`) containing exactly one
   length-prefixed legacy RunaDB SQL statement. The server replies with either:
   `COMMAND_COMPLETE` (`0x13`), or `ROW_DESCRIPTION` (`0x11`), zero or more
   `ROW_DATA` (`0x12`) messages with the described column count, then
   `COMMAND_COMPLETE`. RunaDB Client rejects a response that violates this
   sequence or column-count invariant as a protocol error and ends that result
   stream.
4. Either peer can send `GOODBYE` (`0xff`). A client may send an empty body;
   the server replies with its length-prefixed reason and closes the Connection.

The current TCP Connection executes statements sequentially. Query
multiplexing is not part of this v0.1 TCP behavior.

## Result and Error Payloads

`ROW_DESCRIPTION` begins with a `u16` column count followed by that many
length-prefixed column names. `ROW_DATA` begins with a `u16` column count. Each
column has a null flag (`0` for a value, `1` for NULL); values then carry a
length-prefixed text representation. `COMMAND_COMPLETE` contains a big-endian
`u64` affected-row count and a length-prefixed command tag.

`SERVER_ERROR` (`0x14`) contains a severity byte (`0` information, `1`
warning, `2` error, `3` fatal), a length-prefixed code, and a length-prefixed
message. The current server emits:

| Code | Meaning |
| --- | --- |
| `P0000` | Malformed query payload |
| `P0001` | Legacy RunaDB SQL or execution failure; the message names the failure |
| `P0002` | Unknown message type after the handshake |

These codes are draft until the public error model is versioned separately.
Clients must not infer retry safety from any v0.1 error. In particular, a
Connection failure during a write leaves the commit outcome unknown to the
client.

The next protocol major will define separate request encodings for Runa Flow
source and canonical Runa Query IR, together with their format-version and
validation errors. It will not reuse this SQL-text payload as the new public
query contract.
