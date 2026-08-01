# RunaDB Server

English

RunaDB Server is the current OLTP foundation of RunaDB, a long-horizon,
high-performance unified data system written in Zig. RunaDB's direction is to
bring relational, document, graph, vector, time-series, key-value, spatial,
and multimodal data under common query, governance, history, and integrity
contracts. RunaDB Server currently runs as a standalone, single-instance network
service. It is one of two independently released RunaDB products; RunaDB Client
provides the CLI, drivers, and developer tools.

Runa Flow is RunaDB's native public request language. The implemented Wire
Protocol v2.0 development slice accepts `from <relation> | where <predicate>
| emit { <field> }` as source or canonical Runa Query IR. It also supports
immutable Observation Evidence ingestion, metadata inspection, and bounded
payload retrieval through the official RunaDB Client. SQL text is not an
accepted protocol request.

RunaDB Server and RunaDB Client communicate only through versioned protocol
definitions and the public error model. See [product boundaries](docs/products.md)
and [ADR-0017](docs/adr/0017-runa-flow-language-and-semantic-model.md).

## Status

RunaDB Server is under active development. The current implementation provides:

- A native RunaDB Wire Protocol TCP listener and RunaDB Client CLI
- An opt-in MCP stdio adapter for Agent use with the read-only Runa Flow slice
- Single-instance operation with a local data directory
- The read-only Runa Flow relation projection slice
- Canonical Runa Query IR format version `4`
- Immutable Observation Evidence payload storage and verified recovery
- WAL-backed persistence and crash recovery
- WAL frame versioning and CRC32 validation
- WAL checkpoint (compaction): bounded WAL size and bounded recovery time
- A single-writer commit coordinator: transaction write sets with commit/rollback,
  group commit, observed-version write-write conflict detection, bounded commit
  admission, and a durable MVCC commit watermark recovered on restart

The storage format and execution architecture are still evolving. Persistent
LSM tables, secondary indexes, MVCC snapshot reads over retained versions, and
the extended query protocol are planned parts of the architecture, not all
current product capabilities. The transaction coordinator and commit ordering
exist as an engine-level development slice; they are not yet exposed through the
wire protocol or MCP. Runa Flow, Runa Query IR, and the semantic model are the
next public-contract work; relation, document, and graph capabilities become
support claims only when their complete semantics and evidence are published.
Multi-model and multimodal data, AI-assisted execution, distributed deployments,
HTAP, streaming, historical queries, post-quantum cryptography, and autonomous
operations remain long-horizon target designs. See
[ADR-0016](docs/adr/0016-long-horizon-unified-database.md) and
[ADR-0017](docs/adr/0017-runa-flow-language-and-semantic-model.md).

Mutations, transactions, document and graph operations, semantic-model
persistence, authorization, and World Continuum bindings are not implemented
as public capabilities.

## Build

RunaDB currently requires Zig 0.16 or newer.

```bash
zig build
zig build test
```

## Run

Start a server with the default loopback address, port, and data directory:

```bash
zig build run
```

Configure the server with command-line options:

```bash
zig build run -- \
  --host 127.0.0.1 \
  --runa-port 5434 \
  --data-dir ./data
```

Available options:

| Option | Default | Description |
| --- | --- | --- |
| `--host <address>` | `127.0.0.1` | Listen address |
| `--runa-port <port>` | `5434` | RunaDB Wire Protocol TCP port (`0` disables it) |
| `--data-dir <path>` | `./data` | Instance data directory |
| `--no-sync` | disabled | Disable WAL synchronization; development only |
| `--mcp-stdio` | disabled | Serve MCP `2025-11-25` JSON-RPC over stdin/stdout; only the read-only `runadb_flow_emit` tool is available |

## MCP

RunaDB Server has an opt-in native MCP stdio adapter for local Agent use. Run
it as a subprocess with its standard input and output connected to the MCP
client:

```bash
zig build run -- --mcp-stdio --data-dir ./data
```

The adapter implements MCP `2025-11-25` lifecycle and tools. Its sole tool,
`runadb_flow_emit`, accepts a `source` string using the implemented read-only
Runa Flow grammar and returns bounded structured rows. Standard output contains
only MCP JSON-RPC messages. Streamable HTTP, remote access, authorization, and
PEM validation are not implemented in the current release; do not expose the
stdio process as a network service. Remote MCP and Agent-initiated mutation are
planned only after their authentication, PEM validation, authorization mapping,
and audit contracts are implemented.

The implemented Runa Flow source shape is:

```runa-flow
from users
| where id > 10
| emit { id, email }
| limit 100
```

## Durability and recovery

RunaDB writes changes to a write-ahead log before applying them to table state.
WAL synchronization is enabled by default. `--no-sync` relaxes this guarantee
and should only be used for development.

During recovery, RunaDB replays complete, supported, checksum-valid WAL frames.
An incomplete final frame is truncated and the logical end of the WAL is
persisted before accepting new writes. A corrupt complete frame, unknown WAL
format, or invalid middle section causes startup to fail rather than silently
discarding evidence.

## Architecture

RunaDB is designed around a single-node, single-writer commit path, WAL-first
durability, MVCC snapshots, and LSM-style ordered storage. The implementation
is being built in small modules with explicit ownership boundaries:

| Directory | Responsibility |
| --- | --- |
| `src/net/` | TCP connections and RunaDB Wire Protocol |
| `src/flow/` | Runa Flow parsing, Runa Query IR, binding, and execution |
| `src/storage/` | Tables, WAL, VFS, pager, values, and recovery |
| `src/util/` | Shared encoding and utility code |

Read [ARCHITECTURE.md](docs/ARCHITECTURE.md) for target boundaries and
invariants. It distinguishes the target LSM/MVCC architecture from the
currently implemented components.

## Documentation

- [Documentation standard](docs/DOCUMENTATION.md)
- [Runa Flow and Runa Query IR](docs/runa-flow.md)
- [RunaDB Wire Protocol v2.0](docs/wire-protocol.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Architecture decision records](docs/adr/)
- [Domain terminology and product constraints](CONTEXT.md)

## License

[MIT](LICENSE)
