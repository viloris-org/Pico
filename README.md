# Pico

单机、轻量、可网络访问的 OLTP 数据库（Zig）。对外兼容 **PostgreSQL 线协议** + **OLTP SQL 子集**；对内是自研存储（LSM 路线，见 ADR）。

## 状态

**Phase 0（完成）**：TCP 服务 + PG 简单查询协议 + 内存表 + WAL 恢复。

**Phase 1（进行中）**：面向 sub2api 类 OLTP 负载扩展 SQL 子集。

持久化格式仍在 Phase 1 演进中。WAL 帧带格式版本与 CRC32 校验；遇到未知格式或完整帧校验失败时，实例会拒绝恢复，而不会猜测性重放数据。

已支持（子集，非完整 PG）：

- DDL：`CREATE TABLE IF NOT EXISTS`、PG 类型别名（`BIGSERIAL`/`VARCHAR`/`DECIMAL`/`TIMESTAMPTZ`/`JSONB`…）、`DEFAULT`/`NOW()`/`NOT NULL`/`UNIQUE`、列级 `REFERENCES`（解析忽略）
- `CREATE INDEX IF NOT EXISTS`（兼容接受，当前为扫描访问）
- DML：`INSERT`（缺省列 + SERIAL）、`SELECT`/`UPDATE`/`DELETE` 的 `WHERE`（`=` / `IS [NOT] NULL` / `AND`）、`LIMIT`/`OFFSET`
- 文本主键、多语句脚本、`BEGIN`/`COMMIT`/`ROLLBACK`（语句级自动提交下的兼容标签）

验收：

- `zig build test`（含 sub2api 风格 DDL/DML 单测）
- 可执行 `sub2api/backend/migrations/001_init.sql` 全量建表
- 核心表 `INSERT`/`SELECT`/`UPDATE`/`DELETE`（含 `AND` / `IS NULL` / 非主键 WHERE）

仍不支持（sub2api 完整跑通还需继续）：扩展查询协议（`$1` 参数）、JOIN、JSONB 算子、`ALTER TABLE`、事务隔离、部分唯一索引语义等。

## 构建与运行

需要 Zig **0.16+**。

```bash
zig build
zig build run -- --data-dir ./data --port 5433

# 另开终端
psql -h 127.0.0.1 -p 5433 -U pico -d pico
```

```sql
CREATE TABLE IF NOT EXISTS users (
  id BIGSERIAL PRIMARY KEY,
  email VARCHAR(255) NOT NULL UNIQUE,
  role VARCHAR(20) NOT NULL DEFAULT 'user',
  balance DECIMAL(20, 8) NOT NULL DEFAULT 0,
  deleted_at TIMESTAMPTZ
);
INSERT INTO users (email) VALUES ('alice@example.com');
SELECT id, email, role FROM users WHERE email = 'alice@example.com' AND deleted_at IS NULL;
UPDATE users SET role = 'admin' WHERE email = 'alice@example.com';
DELETE FROM users WHERE id = 1;
```

```bash
zig build test
```

## 文档

- [`CONTEXT.md`](CONTEXT.md) — 领域语言
- [`docs/adr/`](docs/adr/) — 架构决策
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — 目标架构、数据归属与验证契约

## 模块边界

| 目录 | 职责 |
|------|------|
| `net/` | TCP 接受、PostgreSQL 线协议 |
| `sql/` | SQL 子集词法/解析/执行 |
| `storage/` | WAL、内存表、引擎与恢复 |
| `txn/` | 事务边界（Phase 0 为自动提交） |
| `util/` | 编解码等通用工具 |
