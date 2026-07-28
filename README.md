# Pico

[中文](README.zh-CN.md) | English

Pico is a lightweight, single-node OLTP database written in Zig. It runs as a
standalone network service and exposes the PostgreSQL Frontend/Backend wire
protocol so that existing PostgreSQL clients and drivers can connect without a
custom SDK.

Pico intentionally implements an OLTP SQL subset. It is not a full PostgreSQL
server, and SQL outside the supported subset is rejected with an explicit
error.

## Status

Pico is under active development. The current implementation provides:

- A TCP server using the PostgreSQL wire protocol
- Single-instance operation with a local data directory
- `CREATE TABLE`, `ALTER TABLE`, `INSERT`, `SELECT`, `UPDATE`, and `DELETE`
- Single-column primary keys, column-level unique constraints, defaults, and
  common PostgreSQL type aliases
- `WHERE` predicates using `=`, `AND`, and `IS [NOT] NULL`, plus `LIMIT` and
  `OFFSET`
- Autocommit and explicit `BEGIN` / `COMMIT` / `ROLLBACK` transactions
- WAL-backed persistence and crash recovery
- WAL frame versioning and CRC32 validation
- Text primary keys, multi-statement scripts, and serial-style generated IDs

The storage format and execution architecture are still evolving. Persistent
LSM tables, secondary indexes, MVCC isolation, group commit, and the extended
query protocol are planned parts of the architecture, not all current product
capabilities.

The following are currently rejected explicitly: `CREATE INDEX`, foreign keys,
table-level unique constraints, composite primary keys, `CHECK`, `RETURNING`,
multi-row `INSERT`, `ON CONFLICT`, `ORDER BY`, `OR`, `NOT`, comparisons other
than `=`, `IN`, `LIKE`, aggregation, grouping, and the extended query messages
`Parse`, `Bind`, `Describe`, and `Execute`.

See the [SQL subset support matrix](docs/sql-subset.md) for the authoritative
compatibility boundary.

## Build

Pico currently requires Zig 0.16 or newer.

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
  --port 5433 \
  --data-dir ./data
```

Available options:

| Option | Default | Description |
| --- | --- | --- |
| `--host <address>` | `127.0.0.1` | Listen address |
| `--port <port>` | `5433` | Listen port |
| `--data-dir <path>` | `./data` | Instance data directory |
| `--no-sync` | disabled | Disable WAL synchronization; development only |

Connect with `psql` or another PostgreSQL client:

```bash
psql -h 127.0.0.1 -p 5433 -U pico -d pico
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

Pico writes changes to a write-ahead log before applying them to table state.
WAL synchronization is enabled by default. `--no-sync` relaxes this guarantee
and should only be used for development.

During recovery, Pico replays complete, supported, checksum-valid WAL frames.
An incomplete final frame is truncated and the logical end of the WAL is
persisted before accepting new writes. A corrupt complete frame, unknown WAL
format, or invalid middle section causes startup to fail rather than silently
discarding evidence.

## Architecture

Pico is designed around a single-node, single-writer commit path, WAL-first
durability, MVCC snapshots, and LSM-style ordered storage. The implementation
is being built in small modules with explicit ownership boundaries:

| Directory | Responsibility |
| --- | --- |
| `src/net/` | TCP connections and PostgreSQL wire protocol |
| `src/sql/` | SQL subset tokenization, parsing, and execution |
| `src/storage/` | Tables, WAL, VFS, pager, values, and recovery |
| `src/txn/` | Transaction boundaries and session state |
| `src/util/` | Shared encoding and utility code |

Read [ARCHITECTURE.md](docs/ARCHITECTURE.md) for target boundaries and
invariants. It distinguishes the target LSM/MVCC architecture from the
currently implemented components.

## Documentation

- [SQL subset support matrix](docs/sql-subset.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Architecture decision records](docs/adr/)
- [Domain terminology and product constraints](CONTEXT.md)

## License

[MIT](LICENSE)
