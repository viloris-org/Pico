# SQL Subset Support Matrix

This matrix is the executable scope list for ADR-0008. Only statements marked
“Supported and tested” are part of Pico's SQL subset commitment. “Explicitly
rejected” means that the Pico wire protocol returns an error instead of accepting
the statement and ignoring its effects. The current PostgreSQL adapter is only a
migration aid and does not change this contract.

| Category | Statement or capability | Current status | Regression location |
| --- | --- | --- | --- |
| DDL | `CREATE TABLE [IF NOT EXISTS]`, single-column primary keys, and column-level unique constraints | Supported and tested | `sql/exec.zig` |
| DDL | `ALTER TABLE` `ADD/DROP COLUMN`, `SET/DROP DEFAULT`, and `SET/DROP NOT NULL` | Supported and tested | `sql/exec.zig`, `storage/engine.zig` |
| DML | Multi-row `INSERT`, `SELECT`, `UPDATE`, and `DELETE` | Supported and tested | `sql/exec.zig` |
| Query | `=`, `!=`/`<>`, `<`, `>`, `<=`, `>=`, `AND`, `OR` (parenthesized), `NOT`, `IS [NOT] NULL`, `[NOT] IN` literal lists, and `[NOT] LIKE` (`%`, `_`, and `\\` escape) in `WHERE`; single-column `ORDER BY [ASC|DESC]`; `LIMIT` / `OFFSET` | Supported and tested | `sql/parse.zig`, `sql/exec.zig` |
| Transactions | Autocommit and `BEGIN` / `COMMIT` / `ROLLBACK` (write sets, failed state, WAL `txn_batch`) | Supported and tested | `txn/session.zig`, `sql/exec.zig`, `storage/wal.zig` |
| Indexes | `CREATE [UNIQUE] INDEX` / `DROP INDEX` | Explicitly rejected | `sql/exec.zig` |
| Constraints | Foreign keys, table-level unique constraints, composite primary keys, and `CHECK` | Explicitly rejected | `sql/parse.zig` |
| DML | `RETURNING`, `ON CONFLICT` | Explicitly rejected | `sql/parse.zig` |
| Query | Multi-column `ORDER BY`, aggregates, and grouping | Explicitly rejected | `sql/parse.zig` |
| Migration adapter | PostgreSQL extended-query messages `Parse` / `Bind` / `Describe` / `Execute` | Explicitly rejected | `net/pg.zig` |

Whenever a capability changes from “Explicitly rejected” to “Supported and tested,”
add parser, execution, recovery, and official Pico client regressions at the same time.
Changes involving commit must also cover WAL-first persistence and
single-writer publication.
