# RunaDB Wire Protocol v3.0

Status: Implemented development contract. This native TCP protocol is the
incompatible successor to the removed SQL-text v0.1 endpoint. It does not
promise compatibility with the PostgreSQL Frontend/Backend Protocol.

## Compatibility

The protocol version is a `(major, minor)` pair. The checked-out Server and
Client implement `3.0`. A `HELLO` with a major other than `3` receives
`HELLO_ERROR` with `unsupported protocol version`, then the Connection closes.
Minor-version compatibility has not yet been defined. The major bump from `2`
to `3` is the negotiated surface for the cancellation credential that `HELLO_OK`
now appends: a `v2` peer is rejected at the version check before that framing is
parsed, so it never sees an ambiguous trailing-payload error.

## Framing

Each message is `u32` big-endian body length, `u8` message type, then the body.
The body length includes the type byte and is from 1 through 1,048,576 bytes.
Strings are `u32` big-endian byte length followed by UTF-8 bytes, limited to
65,536 bytes. Malformed transport framing closes the responsible Connection
without changing shared state. A framed Request with an invalid payload returns
`SERVER_ERROR` and leaves the Connection available for another Request.

## Message Sequence

1. Client sends `HELLO` (`0x01`) with two big-endian `u16` values: major then
   minor.
2. Server returns `HELLO_OK` (`0x02`) or `HELLO_ERROR` (`0x03`), each with a
   length-prefixed reason or Server version string. `HELLO_OK` appends the
   Connection's 16-byte cancellation credential after the version string; it is
   unique within the Connection lifetime and must not be logged.
3. Client sends `FLOW_SOURCE` (`0x10`), one length-prefixed Runa Flow source
   request, or `FLOW_IR` (`0x15`), a big-endian `u16` IR format version plus
   canonical Runa Query IR bytes. The implemented IR format version is `4`.
4. Server responds with `ROW_DESCRIPTION` (`0x11`), zero or more `ROW_DATA`
   (`0x12`) messages, and `COMMAND_COMPLETE` (`0x13`), or with `SERVER_ERROR`
   (`0x14`). The initial Flow slice's successful completion tag is `EMIT`.
5. At any point after the handshake, a client may send `CANCEL_REQUEST`
   (`0x30`) with the 16-byte credential of another live Connection to request
   cooperative cancellation of that Connection's currently executing statement
   (see [Cancellation](#cancellation)).
6. Either peer sends `GOODBYE` (`0xff`) to close the Connection.

Requests execute sequentially on a TCP Connection; multiplexing is not part of
this version.

## Cancellation

`CANCEL_REQUEST` (`0x30`) carries the 16-byte credential delivered in
`HELLO_OK`. The Server looks the credential up in its bounded connection table
and marks the named Connection's current statement; the executing statement
stops at its next cooperative cancellation point with a `CANCELED` outcome.
Delivery is fire-and-forget: the Server never replies to a `CANCEL_REQUEST`.
Missing, mismatched, closed, or expired credentials finish as a protocol no-op;
only the Server's observability counters change. A payload that is not exactly
16 bytes is a malformed request: the Server returns `SERVER_ERROR` with code
`CN1001` and leaves the sending Connection available for another Request.

A cancellation mark applies only to the statement running when it arrives and
is cleared when that Connection starts its next statement. Cancellation is
cooperative: parsing, scanning, result streaming, commit-queue waits, and
pre-sync execution observe the mark between bounded work units. Before the
irreversible commit point, a cancelled transaction discards its private write
set and any queued commit request; once a complete commit record has reached
the selected durability level, cancellation cannot make it uncommitted. The
single writer still publishes, and the response is discarded or delivered
according to Connection liveness. Cancelling a committed transaction is a
no-op; a stale mark never aborts a later statement.

## Observation Evidence Attachments

Protocol v2 implements bounded payload transfer for a canonical `observe` IR
request. One Connection may stage one attachment at a time:

1. `ATTACHMENT_BEGIN` (`0x20`) carries a big-endian `u64` upload ID, a
   big-endian `u64` payload length, and a 32-byte BLAKE3-256 digest.
2. Each `ATTACHMENT_CHUNK` (`0x21`) carries the upload ID and at most 262,144
   payload bytes.
3. `ATTACHMENT_FINISH` (`0x22`) carries the upload ID. The Server validates the
   declared length and digest; `ATTACHMENT_ABORT` (`0x23`) discards the stage.
4. A following `FLOW_IR` `observe` operation must reference that upload ID. On
   commit it returns one `evidence_id` row and `COMMAND_COMPLETE(OBSERVE, 1)`.

An attachment is limited to 8,388,608 bytes and is staged in bounded
Connection-owned memory; it is not durable or resumable. A malformed, oversized,
incomplete, mismatched, aborted, or Connection-abandoned attachment never
becomes visible Observation Evidence. Payload bytes are published in the Data
Directory before WAL evidence; WAL synchronization at the default durability
level precedes visibility.

A `read_evidence_payload` IR operation returns `PAYLOAD_BEGIN` (`0x28`), zero
or more `PAYLOAD_CHUNK` (`0x29`) frames, and `PAYLOAD_FINISH` (`0x2a`), followed
by `COMMAND_COMPLETE`. The official RunaDB Client validates the returned ID,
length, chunk bounds, and BLAKE3-256 digest.

## Result And Errors

`ROW_DESCRIPTION` begins with a `u16` column count and names. `ROW_DATA` begins
with a `u16` count; each value has a null flag and, when present, a
length-prefixed text representation. `COMMAND_COMPLETE` contains a big-endian
`u64` row count and a tag.

| Code | Meaning |
| --- | --- |
| `RF1000` | Malformed Runa Flow source payload |
| `RF1001` | Runa Flow parse or static validation failure |
| `RF1002` | Semantic binding or read execution failure |
| `RF1003` | Malformed Runa Query IR payload |
| `RF1004` | Unsupported Runa Query IR format version |
| `RF1005` | Unknown message type after handshake |
| `CN1001` | Malformed `CANCEL_REQUEST` payload |
| `EV1001` | Attachment state, limit, length, or digest failure |
| `EV1002` | Invalid modality |
| `EV1003` | Observation Evidence validation or commit failure |
| `EV1004` | Evidence payload not found or unreadable |

These errors and the relation binding are development-only. Protocol v3
implements durable Observation Evidence writes, metadata reads, and payload
reads; other World Continuum mutations remain unsupported.
In particular, an IR payload with an empty projection or a relation or field
identifier that cannot be produced by the published source grammar is malformed
and receives `RF1003`.
