# Pico Server

Pico Server is a lightweight, single-node OLTP database built in Zig. It runs as a standalone network service. Pico Client is a separate, independently released Pico product that provides the CLI, drivers, and developer tools.

Pico intentionally implements an OLTP-oriented SQL subset. It is not PostgreSQL-compatible: Pico defines the wire protocol, SQL dialect, types, errors, drivers, and tools as its own contracts. SQL outside the published support matrix fails with an explicit error.

Pico Server and Pico Client communicate only through the versioned Pico Wire Protocol, Pico SQL, and the public error model. See [product boundaries](docs/products.md).

## Current Status

Pico Server is still under active development. The current implementation provides:

- A native Pico Wire Protocol TCP listener and Pico Client CLI
- A temporary PostgreSQL Frontend/Backend Protocol adapter, which is not a product compatibility commitment
- Single-node, single-instance operation with a local data directory
- `CREATE TABLE`, `ALTER TABLE`, `INSERT`, `SELECT`, `UPDATE`, and `DELETE`
- Single-column primary keys, column-level unique constraints, defaults, and current SQL type aliases
- `WHERE` predicates using `=`, `!=`/`<>`, `<`, `>`, `<=`, `>=`, `AND`, parenthesized `OR` groups, and `IS [NOT] NULL`, as well as `LIMIT` and `OFFSET`
- Autocommit and explicit `BEGIN` / `COMMIT` / `ROLLBACK` transactions
- WAL-backed persistence and crash recovery
- WAL frame versioning and CRC32 validation
- Text primary keys, multi-statement scripts, and serial-style generated IDs

The persistence format and execution architecture are still evolving. Persistent LSM tables, secondary indexes, MVCC isolation, group commit, and the extended query protocol are part of the target architecture; this does not imply that all of them are currently implemented.

The following capabilities are currently rejected explicitly: `CREATE INDEX`, foreign keys, table-level unique constraints, composite primary keys, `CHECK`, `RETURNING`, `ON CONFLICT`, multi-column `ORDER BY`, aggregation, grouping, and the extended query messages `Parse`, `Bind`, `Describe`, and `Execute`.

See the [SQL subset support matrix](docs/sql-subset.md) for the complete Pico SQL boundary. The target protocol and ecosystem decision are recorded in [ADR-0009](docs/adr/0009-pico-native-ecosystem.md).

## Build

Pico currently requires Zig 0.16 or newer.

```bash
zig build
zig build test
```

## Benchmark

Run the SQL-path benchmark in an optimized build:

```bash
zig build bench -Doptimize=ReleaseFast -- --rows 100000
```

The command reports throughput for autocommit `INSERT`, primary-key `SELECT`, and `INSERT` followed by `COMMIT` within an explicit transaction. By default, it uses a temporary data directory and disables WAL synchronization to measure the current SQL, table, and WAL-append paths. Pass `--sync-wal` to include the durability cost of WAL synchronization in the measurement.

## Run

Start the server with the default loopback address, port, and data directory:

```bash
zig build run
```

You can also configure the server with command-line options:

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
| `--pico-port <port>` | `5434` | Native Pico Wire Protocol TCP port (`0` disables it) |
| `--data-dir <path>` | `./data` | Instance data directory |
| `--no-sync` | disabled | Disable WAL synchronization; development only |

You can test the current development adapter with `psql`, but this does not constitute a Pico client compatibility commitment. It will eventually be replaced by the Pico Wire Protocol:

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

## Durability and Recovery

Pico writes changes to a write-ahead log (WAL) before applying them to table state. WAL synchronization is enabled by default. `--no-sync` weakens this guarantee and should be used only in development environments.

During recovery, Pico replays only complete, supported, checksum-valid WAL frames. It truncates an incomplete final frame and persists the logical end of the WAL before accepting new writes. If a complete frame is corrupt, the WAL format is unknown, or a middle section is invalid, the instance refuses to start rather than silently discarding evidence.

## Architecture

Pico is designed around a single-node, single-writer commit path, WAL-first durability, MVCC snapshots, and LSM-style ordered storage. The implementation is divided into small modules with explicit ownership boundaries:

| Directory | Responsibility |
| --- | --- |
| `src/net/` | TCP connections and the Pico Wire Protocol (the current PG adapter is transitional) |
| `src/sql/` | Tokenization, parsing, and execution for the SQL subset |
| `src/storage/` | Tables, WAL, VFS, pager, value types, and recovery |
| `src/txn/` | Transaction boundaries and connection state |
| `src/util/` | Shared encoding and utility code |

See the [architecture document](docs/ARCHITECTURE.md) for the target boundaries and invariants. It distinguishes the target LSM/MVCC architecture from the components currently implemented.

## Documentation

- [文档规范](docs/DOCUMENTATION.md)
- [SQL subset support matrix](docs/sql-subset.md)
- [Pico Wire Protocol v0.1](docs/wire-protocol.md)
- [Architecture document](docs/ARCHITECTURE.md)
- [Architecture decision records](docs/adr/)
- [Domain terminology and product constraints](CONTEXT.md)

## License

[MIT](LICENSE)
