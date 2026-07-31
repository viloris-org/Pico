# Native MCP Stdio Adapter

## Status

Accepted. This ADR authorizes a bounded development interface. Remote MCP
access and agent-initiated modification are planned follow-up capabilities, but
are not authorized until their authentication, authorization, and PEM
validation contracts are implemented.

## Context

Agents need a standard way to discover and invoke RunaDB capabilities. MCP
uses JSON-RPC and defines stdio and Streamable HTTP transports. RunaDB Server
currently has no authentication, authorization, TLS, or PEM validation, and
the implemented Runa Flow slice is read-only. Exposing an unauthenticated
network MCP endpoint would therefore create an unbounded remote authority
surface before its identity and policy contracts exist.

## Decision

RunaDB Server provides a native MCP server through an explicit
`--mcp-stdio` process mode. It implements MCP protocol version `2025-11-25`
over newline-delimited JSON-RPC on standard input and output. Standard output
contains only MCP messages; diagnostics use standard error.

The initial tool set contains only `runadb_flow_emit`. Its `source` argument
is compiled and executed through the same Runa Flow boundary as other source
requests. It accepts only the implemented read-only `emit` operation. It does
not expose the Data Directory, storage modules, WAL, attachment staging,
canonical IR bytes, or any write operation. Results are bounded to 1,000 rows,
64 KiB per cell, and 1 MiB of JSON response data; limit and validation failures
are returned as MCP tool errors and do not change instance state.

The adapter owns only Connection-local MCP lifecycle state. The engine remains
the owner of data, durability, recovery, and mutation ordering. MCP is an
adapter beside the RunaDB Wire Protocol, not a replacement for it and not an
extension of the RunaDB Client product boundary.

## Non-Goals And Follow-Up

Streamable HTTP, remote access, PEM validation, mutual TLS, authentication,
authorization, audit records, write tools, resources, prompts, sampling, and
server-initiated MCP requests are not implemented in this release. Remote MCP
access and agent-initiated modification remain planned capabilities. Before
either is enabled, a focused ADR must define identity, authorization mapping to
tools and Runa Flow Requests, PEM/TLS lifecycle, origin validation, audit
behavior, rate and result limits, failure handling, and end-to-end evidence.

## Evidence

`src/net/mcp.zig` tests cover lifecycle ordering, tool discovery, successful
read execution, tool rejection, and malformed JSON-RPC. The command-level
example in `README.md` is verified with `zig build test`.
