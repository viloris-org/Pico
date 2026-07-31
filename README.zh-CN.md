# RunaDB Server

RunaDB Server 是 RunaDB 当前的 OLTP 基础；RunaDB 的长期方向是一个使用 Zig 构建的高性能通用统一数据系统。它将把关系、文档、图、向量、时序、键值、空间和多模态数据纳入共同的查询、治理、历史与完整性契约。RunaDB Server 当前以独立的单实例网络服务运行。RunaDB Client 是独立发布的 RunaDB 产品，提供 CLI、驱动和开发者工具。

Runa Flow 是 RunaDB 目标中的公共请求语言。它是一种带类型、面向管道的语言，通过 semantic model 绑定名称，并生成规范化、可版本化的 Runa Query IR。下一代不兼容的 RunaDB Wire Protocol major version 将承载这一契约。Runa Flow、Runa Query IR、semantic model 和该协议版本均为目标设计，尚不是已支持的产品能力。

当前实现通过现行 RunaDB Wire Protocol 接受面向 OLTP 的遗留 RunaDB SQL 子集。RunaDB 不承诺 PostgreSQL 兼容性：Wire Protocol、SQL 方言、类型、错误、驱动和工具均由 RunaDB 定义。未支持的遗留 SQL 会返回明确错误。RunaDB 不会增加新的 SQL 语法；SQL 仅保留到 Runa Flow 为所需基线工作流提供经过测试的替代方案为止。

RunaDB Server 和 RunaDB Client 仅通过版本化的协议定义和公共错误模型通信。参见 [产品边界](docs/products.md) 与 [ADR-0017](docs/adr/0017-runa-flow-language-and-semantic-model.md)。

## Current Status

RunaDB Server is still under active development. The current implementation provides:

- A native RunaDB Wire Protocol TCP listener and RunaDB Client CLI
- A temporary PostgreSQL Frontend/Backend Protocol adapter, which is not a product compatibility commitment
- Single-node, single-instance operation with a local data directory
- `CREATE TABLE`, `ALTER TABLE`, `INSERT`, `SELECT`, `UPDATE`, and `DELETE`
- Single-column primary keys, column-level unique constraints, defaults, and current SQL type aliases
- `WHERE` predicates using `=`, `!=`/`<>`, `<`, `>`, `<=`, `>=`, `AND`, parenthesized `OR` groups, and `IS [NOT] NULL`, as well as `LIMIT` and `OFFSET`
- Autocommit and explicit `BEGIN` / `COMMIT` / `ROLLBACK` transactions
- WAL-backed persistence and crash recovery
- WAL frame versioning and CRC32 validation
- Text primary keys, multi-statement scripts, and serial-style generated IDs

持久化格式和执行架构仍在演进。持久 LSM 表、二级索引、MVCC 隔离、组提交和扩展查询协议属于目标架构；这不代表它们都已经实现。Runa Flow、Runa Query IR 与 semantic model 是下一阶段的公共契约工作；关系、文档和图能力仅会在完整语义与证据公布后成为支持承诺。多模型和多模态数据、AI 辅助执行、分布式部署、HTAP、流处理、历史查询、后量子密码学和自主运维仍属于长期目标设计。参见 [ADR-0016](docs/adr/0016-long-horizon-unified-database.md) 与 [ADR-0017](docs/adr/0017-runa-flow-language-and-semantic-model.md)。

The following capabilities are currently rejected explicitly: `CREATE INDEX`, foreign keys, table-level unique constraints, composite primary keys, `CHECK`, `RETURNING`, `ON CONFLICT`, multi-column `ORDER BY`, aggregation, grouping, and the extended query messages `Parse`, `Bind`, `Describe`, and `Execute`.

参见 [遗留 SQL 支持矩阵](docs/sql-subset.md) 以了解当前完整 SQL 边界。目标公共语言与协议方向记录于 [ADR-0017](docs/adr/0017-runa-flow-language-and-semantic-model.md)。

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
| `--runadb-port <port>` | `5434` | Native RunaDB Wire Protocol TCP port (`0` disables it) |
| `--data-dir <path>` | `./data` | Instance data directory |
| `--no-sync` | disabled | Disable WAL synchronization; development only |

You can test the current development adapter with `psql`, but this does not constitute a RunaDB client compatibility commitment. It will eventually be replaced by the RunaDB Wire Protocol:

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

## Durability and Recovery

RunaDB writes changes to a write-ahead log (WAL) before applying them to table state. WAL synchronization is enabled by default. `--no-sync` weakens this guarantee and should be used only in development environments.

During recovery, RunaDB replays only complete, supported, checksum-valid WAL frames. It truncates an incomplete final frame and persists the logical end of the WAL before accepting new writes. If a complete frame is corrupt, the WAL format is unknown, or a middle section is invalid, the instance refuses to start rather than silently discarding evidence.

## Architecture

RunaDB is designed around a single-node, single-writer commit path, WAL-first durability, MVCC snapshots, and LSM-style ordered storage. The implementation is divided into small modules with explicit ownership boundaries:

| Directory | Responsibility |
| --- | --- |
| `src/net/` | TCP connections and the RunaDB Wire Protocol (the current PG adapter is transitional) |
| `src/sql/` | Tokenization, parsing, and execution for the SQL subset |
| `src/storage/` | Tables, WAL, VFS, pager, value types, and recovery |
| `src/txn/` | Transaction boundaries and connection state |
| `src/util/` | Shared encoding and utility code |

See the [architecture document](docs/ARCHITECTURE.md) for the target boundaries and invariants. It distinguishes the target LSM/MVCC architecture from the components currently implemented.

## Documentation

- [文档规范](docs/DOCUMENTATION.md)
- [遗留 SQL 支持矩阵](docs/sql-subset.md)
- [Runa Flow 目标设计](docs/runa-flow.md)
- [遗留 RunaDB Wire Protocol v0.1](docs/wire-protocol.md)
- [Architecture document](docs/ARCHITECTURE.md)
- [Architecture decision records](docs/adr/)
- [Domain terminology and product constraints](CONTEXT.md)

## License

[MIT](LICENSE)
