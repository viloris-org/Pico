# RunaDB Wire Protocol v1.0

Status: Implemented development contract. This native TCP protocol is the
incompatible successor to the removed SQL-text v0.1 endpoint. It does not
promise compatibility with the PostgreSQL Frontend/Backend Protocol.

## Compatibility

The protocol version is a `(major, minor)` pair. The checked-out Server and
Client implement `1.0`. A `HELLO` with a major other than `1` receives
`HELLO_ERROR` with `unsupported protocol version`, then the Connection closes.
Minor-version compatibility has not yet been defined.

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
   length-prefixed reason or Server version string.
3. Client sends `FLOW_SOURCE` (`0x10`), one length-prefixed Runa Flow source
   request, or `FLOW_IR` (`0x15`), a big-endian `u16` IR format version plus
   canonical Runa Query IR bytes. The implemented IR format version is `1`.
4. Server responds with `ROW_DESCRIPTION` (`0x11`), zero or more `ROW_DATA`
   (`0x12`) messages, and `COMMAND_COMPLETE` (`0x13`), or with `SERVER_ERROR`
   (`0x14`). The initial Flow slice's successful completion tag is `EMIT`.
5. Either peer sends `GOODBYE` (`0xff`) to close the Connection.

Requests execute sequentially on a TCP Connection; multiplexing is not part of
this version.

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

These errors and the relation binding are development-only. The implemented
Flow slice is read-only; it has no write retry or durability semantics.
