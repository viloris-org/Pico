# SQL 子集支持矩阵

本矩阵是 ADR-0008 的可执行范围清单。只有“支持并验证”的语句可作为 Pico 的 SQL
子集承诺；“明确拒绝”表示 Pico 线协议返回错误，而不是接受后忽略效果。当前实现的
PostgreSQL 适配层只是迁移状态，不改变此契约。

| 类别 | 语句或能力 | 当前状态 | 回归位置 |
| --- | --- | --- | --- |
| DDL | `CREATE TABLE [IF NOT EXISTS]`，单列主键和列级唯一约束 | 支持并验证 | `sql/exec.zig` |
| DDL | `ALTER TABLE` 的 `ADD/DROP COLUMN`、`SET/DROP DEFAULT`、`SET/DROP NOT NULL` | 支持并验证 | `sql/exec.zig`、`storage/engine.zig` |
| DML | 多行 `INSERT`、`SELECT`、`UPDATE`、`DELETE` | 支持并验证 | `sql/exec.zig` |
| 查询 | `WHERE` 中 `=`、`!=`/`<>`、`<`、`>`、`<=`、`>=`、`AND`、`OR`（括号分组）、`IS [NOT] NULL`，单列 `ORDER BY [ASC|DESC]`，`LIMIT` / `OFFSET` | 支持并验证 | `sql/parse.zig`、`sql/exec.zig` |
| 事务 | 自动提交与 `BEGIN` / `COMMIT` / `ROLLBACK`（写集、失败态、WAL `txn_batch`） | 支持并验证 | `txn/session.zig`、`sql/exec.zig`、`storage/wal.zig` |
| 索引 | `CREATE [UNIQUE] INDEX` / `DROP INDEX` | 明确拒绝 | `sql/exec.zig` |
| 约束 | 外键、表级唯一约束、复合主键、`CHECK` | 明确拒绝 | `sql/parse.zig` |
| DML | `RETURNING`、`ON CONFLICT` | 明确拒绝 | `sql/parse.zig` |
| 查询 | 多列 `ORDER BY`、`NOT`、`IN`、`LIKE`、聚合和分组 | 明确拒绝 | `sql/parse.zig` |
| 迁移适配层 | PostgreSQL 扩展查询 `Parse` / `Bind` / `Describe` / `Execute` | 明确拒绝 | `net/pg.zig` |

每次状态从“明确拒绝”切换为“支持并验证”时，必须同时加入解析、执行、恢复和 Pico
官方客户端回归；涉及提交时还必须覆盖 WAL 先行与单写者发布。
