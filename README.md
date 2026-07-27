# Pico

单机、轻量、可网络访问的 OLTP 数据库（Zig）。对外兼容 **PostgreSQL 线协议** + **OLTP SQL 子集**；对内是自研存储（LSM 路线，见 ADR）。

## 状态

**Phase 0（进行中）**：TCP 服务 + PG 简单查询协议 + 内存表 + WAL 恢复。

验收目标：`psql` 连上，`CREATE` / `INSERT` / `SELECT`，杀进程再启动后数据仍在。

## 构建与运行

需要 Zig **0.16+**。

```bash
zig build
zig build run -- --data-dir ./data --port 5433

# 另开终端
psql -h 127.0.0.1 -p 5433 -U pico -d pico
```

```sql
CREATE TABLE users (id INT PRIMARY KEY, name TEXT);
INSERT INTO users (id, name) VALUES (1, 'alice');
SELECT id, name FROM users;
SELECT id, name FROM users WHERE id = 1;
```

```bash
zig build test
```

## 文档

- [`CONTEXT.md`](CONTEXT.md) — 领域语言
- [`docs/adr/`](docs/adr/) — 架构决策

## 模块边界

| 目录 | 职责 |
|------|------|
| `net/` | TCP 接受、PostgreSQL 线协议 |
| `sql/` | SQL 子集词法/解析/执行 |
| `storage/` | WAL、内存表、引擎与恢复 |
| `txn/` | 事务边界（Phase 0 为自动提交） |
| `util/` | 编解码等通用工具 |
