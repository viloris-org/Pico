# Pico

中文 | [English](README.md)

Pico 是一个使用 Zig 编写的轻量级单节点 OLTP 数据库。它以独立网络服务
运行，并提供 PostgreSQL Frontend/Backend 线协议，因此现有 PostgreSQL 客户端
和驱动无需专用 SDK 即可连接。

Pico 有意实现面向 OLTP 的 SQL 子集。它不是完整的 PostgreSQL 服务端，超出
支持范围的 SQL 会返回明确错误。

## 当前状态

Pico 仍在积极开发中。目前已提供：

- 使用 PostgreSQL 线协议的 TCP 服务
- 带本地数据目录的单机单实例运行模式
- `CREATE TABLE`、`ALTER TABLE`、`INSERT`、`SELECT`、`UPDATE` 和 `DELETE`
- 单列主键、列级唯一约束、默认值和常用 PostgreSQL 类型别名
- 支持 `=`、`AND` 和 `IS [NOT] NULL` 的 `WHERE` 条件，以及 `LIMIT` 和 `OFFSET`
- 自动提交以及显式 `BEGIN` / `COMMIT` / `ROLLBACK` 事务
- 基于 WAL 的持久化与崩溃恢复
- WAL 帧版本控制与 CRC32 校验
- 文本主键、多语句脚本和类似 serial 的自动生成 ID

持久化格式和执行架构仍在演进。持久化 LSM 表、二级索引、MVCC 隔离、
group commit 和扩展查询协议属于目标架构，并不代表当前都已经实现。

以下能力当前会被明确拒绝：`CREATE INDEX`、外键、表级唯一约束、复合主键、
`CHECK`、`RETURNING`、多行 `INSERT`、`ON CONFLICT`、`ORDER BY`、`OR`、`NOT`、
除 `=` 以外的比较运算、`IN`、`LIKE`、聚合、分组，以及扩展查询消息
`Parse`、`Bind`、`Describe` 和 `Execute`。

完整的兼容边界请参阅 [SQL 子集支持矩阵](docs/sql-subset.md)。

## 构建

Pico 当前需要 Zig 0.16 或更高版本。

```bash
zig build
zig build test
```

## 运行

使用默认回环地址、端口和数据目录启动服务：

```bash
zig build run
```

也可以通过命令行参数配置服务：

```bash
zig build run -- \
  --host 127.0.0.1 \
  --port 5433 \
  --data-dir ./data
```

可用参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--host <address>` | `127.0.0.1` | 监听地址 |
| `--port <port>` | `5433` | 监听端口 |
| `--data-dir <path>` | `./data` | 实例数据目录 |
| `--no-sync` | 禁用 | 禁止 WAL 同步，仅用于开发 |

使用 `psql` 或其他 PostgreSQL 客户端连接：

```bash
psql -h 127.0.0.1 -p 5433 -U pico -d pico
```

SQL 示例：

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

## 耐久性与恢复

Pico 会先将变更写入预写式日志（WAL），再应用到表状态。默认启用 WAL
同步；`--no-sync` 会降低这一保证，仅应在开发环境使用。

恢复过程中，Pico 只重放完整、受支持且校验通过的 WAL 帧。不完整的末尾帧
会被截断，并在接受新写入前持久化 WAL 的逻辑末尾。完整帧损坏、未知 WAL
格式或中间部分无效时，实例会拒绝启动，而不是静默丢弃证据。

## 架构

Pico 的设计基于单节点、单写者提交路径、WAL 优先的耐久性、MVCC 快照和
LSM 风格有序存储。实现按明确的所有权边界拆分为小模块：

| 目录 | 职责 |
| --- | --- |
| `src/net/` | TCP 连接与 PostgreSQL 线协议 |
| `src/sql/` | SQL 子集的词法分析、解析和执行 |
| `src/storage/` | 表、WAL、VFS、页管理器、值类型和恢复 |
| `src/txn/` | 事务边界与连接状态 |
| `src/util/` | 通用编码和工具代码 |

目标边界和不变量请参阅 [架构文档](docs/ARCHITECTURE.md)。该文档区分了
目标中的 LSM/MVCC 架构与当前已经实现的组件。

## 文档

- [SQL 子集支持矩阵](docs/sql-subset.md)
- [架构文档](docs/ARCHITECTURE.md)
- [架构决策记录](docs/adr/)
- [领域术语与产品约束](CONTEXT.md)

## 许可证

[MIT](LICENSE)
