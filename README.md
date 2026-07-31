# RunaDB Server

English

RunaDB Server is the current OLTP foundation of RunaDB, a long-horizon,
high-performance unified data system written in Zig. RunaDB's direction is to
bring relational, document, graph, vector, time-series, key-value, spatial,
and multimodal data under common query, governance, history, and integrity
contracts. RunaDB Server currently runs as a standalone, single-instance network
service. It is one of two independently released RunaDB products; RunaDB Client
provides the CLI, drivers, and developer tools.

RunaDB intentionally implements an OLTP SQL subset. It is not PostgreSQL
compatible: its protocol, SQL dialect, types, errors, drivers, and tools are
RunaDB-owned contracts. SQL outside the published support matrix is rejected with
an explicit error.

RunaDB Server and RunaDB Client communicate only through the versioned RunaDB Wire
Protocol, RunaDB SQL, and the public error model. See [product
boundaries](docs/products.md).

## Status

RunaDB Server is under active development. The current implementation provides:

- A native RunaDB Wire Protocol TCP listener and RunaDB Client CLI
- A temporary PostgreSQL Frontend/Backend Protocol adapter, which is not a
  product compatibility commitment
- Single-instance operation with a local data directory
- `CREATE TABLE`, `ALTER TABLE`, `INSERT`, `SELECT`, `UPDATE`, and `DELETE`
- Single-column primary keys, column-level unique constraints, defaults, and
  current SQL type aliases
- `WHERE` predicates using `=`, `!=`/`<>`, `<`, `>`, `<=`, `>=`, `AND`, parenthesized `OR` groups, and `IS [NOT] NULL`; single-column
  `ORDER BY [ASC|DESC]`; `LIMIT` and `OFFSET`
- Autocommit and explicit `BEGIN` / `COMMIT` / `ROLLBACK` transactions
- WAL-backed persistence and crash recovery
- WAL frame versioning and CRC32 validation
- WAL checkpoint (compaction): bounded WAL size and bounded recovery time
- Text primary keys, multi-statement scripts, and serial-style generated IDs

The storage format and execution architecture are still evolving. Persistent
LSM tables, secondary indexes, MVCC isolation, group commit, and the extended
query protocol are planned parts of the architecture, not all current product
capabilities. Multi-model and multimodal data, AI-assisted execution,
distributed deployments, HTAP, streaming, historical queries, post-quantum
cryptography, and autonomous operations are long-horizon target designs; none
is a current support claim. See [ADR-0016](docs/adr/0016-long-horizon-unified-database.md).

The following are currently rejected explicitly: `CREATE INDEX`, foreign keys,
table-level unique constraints, composite primary keys, `CHECK`, `RETURNING`,
`ON CONFLICT`, multi-column `ORDER BY`, aggregation, grouping, and the extended query messages
`Parse`, `Bind`, `Describe`, and `Execute`.

See the [SQL subset support matrix](docs/sql-subset.md) for the authoritative
RunaDB SQL boundary. The target protocol and ecosystem decision is recorded in
[ADR-0009](docs/adr/0009-runadb-native-ecosystem.md).

## Build

RunaDB currently requires Zig 0.16 or newer.

```bash
zig build
zig build test
```

## Benchmark

Run the SQL-path benchmark in an optimized build:

```bash
zig build bench -Doptimize=ReleaseFast -- --rows 100000
```

It reports autocommit `INSERT`, primary-key `SELECT`, and explicit-transaction
`INSERT` plus `COMMIT` throughput. The default uses a temporary data directory
and disables WAL synchronization so results emphasize the current SQL, table,
and WAL append path. Add `--sync-wal` to include durable WAL synchronization in
the measurement.

## Run

Start a server with the default loopback address, port, and data directory:

```bash
zig build run
```

Configure the server with command-line options:

```bash
zig build run -- \
  --host 127.0.0.1 \
  --port 5433 \
  --data-dir ./data
```

Available options:

| Option | Default | Description |
| --- | --- | --- |
| `--host <address>` | `127.0.0.1` | Listen address |
| `--port <port>` | `5433` | Listen port |
| `--runadb-port <port>` | `5434` | Native RunaDB Wire Protocol TCP port (`0` disables it) |
| `--data-dir <path>` | `./data` | Instance data directory |
| `--no-sync` | disabled | Disable WAL synchronization; development only |

The current development adapter can be exercised with `psql`, but this is not
supported RunaDB client compatibility and will be replaced by the RunaDB protocol:

```bash
psql -h 127.0.0.1 -p 5433 -U runadb -d runadb
```

Example SQL:

```sql
CREATE TABLE IF NOT EXISTS users (
  id BIGSERIAL PRIMARY KEY,
  email VARCHAR(255) NOT NULL UNIQUE,
  role VARCHAR(20) NOT NULL DEFAULT 'user',
  balance DECIMAL(20, 8) NOT NULL DEFAULT 0,
  deleted_at TIMESTAMPTZ
);

INSERT INTO users (email) VALUES ('alice@example.com');

SELECT id, email, role
FROM users
WHERE email = 'alice@example.com' AND deleted_at IS NULL;

UPDATE users SET role = 'admin' WHERE email = 'alice@example.com';
DELETE FROM users WHERE id = 1;
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
| `src/net/` | TCP connections and RunaDB wire protocol (the current PG adapter is transitional) |
| `src/sql/` | SQL subset tokenization, parsing, and execution |
| `src/storage/` | Tables, WAL, VFS, pager, values, and recovery |
| `src/txn/` | Transaction boundaries and session state |
| `src/util/` | Shared encoding and utility code |

Read [ARCHITECTURE.md](docs/ARCHITECTURE.md) for target boundaries and
invariants. It distinguishes the target LSM/MVCC architecture from the
currently implemented components.

## Documentation

- [Documentation standard](docs/DOCUMENTATION.md)
- [SQL subset support matrix](docs/sql-subset.md)
- [RunaDB Wire Protocol v0.1](docs/wire-protocol.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Architecture decision records](docs/adr/)
- [Domain terminology and product constraints](CONTEXT.md)

## License

[MIT](LICENSE)
