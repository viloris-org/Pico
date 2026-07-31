# First-Batch OLTP SQL Subset

**Status: Accepted**
**Date: 2026-07-28**
**Owners and stakeholders: RunaDB maintainers**

## Context and Rationale

ADR-0003 decided that RunaDB provides an OLTP SQL subset over the PostgreSQL wire protocol rather than the full PostgreSQL dialect. The current implementation has basic table creation, index declarations, single-table CRUD, and a simple query protocol, but `BEGIN` / `COMMIT` / `ROLLBACK` remain compatibility placeholders and `CREATE INDEX` has no real access path or complete constraint semantics.

The first extensions must serve common migration-driven OLTP applications: establish table definitions, add columns, constraints, and indexes incrementally, and read and write transactionally through parameterized CRUD. They must not manufacture “success” by accepting syntax while ignoring its semantics.

## Decision Drivers

1. Correctness: successful DDL, constraints, transactions, and DML must have complete semantics; unsupported features must fail explicitly.
2. Driver compatibility: common clients can bind parameters through the extended query protocol and receive correct results.
3. Recoverability: catalog changes and data modifications follow WAL-first and single-writer commit ordering.
4. Scope discipline: do not introduce the full PostgreSQL catalog, procedural languages, or an analytical executor.
5. Evolvability: keep clear one-way dependencies among SQL, catalog, transactions, indexes, and storage.

## Alternatives

- Continue supporting only table creation and simple queries: low implementation cost, but insufficient for typical migrations and driver workflows.
- Accept more syntax while ignoring its effects: rejected because it silently damages data or consistency.
- Implement a first batch of OLTP features with complete semantics: adopted because the scope is bounded and verifiable.
- Implement PostgreSQL’s general DDL, catalog, and PL/pgSQL: rejected because it violates ADR-0001 and ADR-0003.

## Decision

Implement the initial SQL subset item by item according to this matrix. Each item remains unsupported until it passes the public support matrix and real-client regression tests.

| Scope | First-batch commitment | Semantic boundary |
| --- | --- | --- |
| Wire protocol | Simple Query and extended-query `Parse` / `Bind` / `Describe` / `Execute` | Parameters come only from bound values; no SQL text interpolation; unsupported messages return explicit errors |
| Types | `BIGINT` / `INTEGER` / `SMALLINT` / `BIGSERIAL`, `BOOLEAN`, `TEXT` / `VARCHAR`, `NUMERIC` / `DECIMAL`, `TIMESTAMPTZ`, `JSONB` | Conversion, NULL, and range checks occur during binding; initial JSONB support is comparable and storable, but does not promise every operator |
| DDL | `CREATE TABLE [IF NOT EXISTS]`, `ALTER TABLE ADD COLUMN [IF NOT EXISTS]`, `ALTER TABLE DROP COLUMN [IF EXISTS]`, `ALTER TABLE ALTER COLUMN SET/DROP DEFAULT`, `SET/DROP NOT NULL`, `CREATE [UNIQUE] INDEX [IF NOT EXISTS]`, `DROP INDEX [IF EXISTS]` | Each catalog change is atomically persisted; existing rows are validated when adding `NOT NULL` or unique constraints; nothing is accepted and ignored |
| Constraints | Single-column and composite `PRIMARY KEY`, `UNIQUE`, `NOT NULL`, column/table `CHECK`, foreign keys `REFERENCES ... ON DELETE CASCADE/SET NULL/RESTRICT` | Constraints are enforced on writes and DDL; foreign-key actions are atomic with the same commit |
| DML | Multi-row `INSERT`, `INSERT ... ON CONFLICT DO NOTHING/DO UPDATE`, `UPDATE`, `DELETE`, `RETURNING` | Command tags and row counts are accurate; conflict targets resolve through a primary key or unique index |
| Queries | Single-table `SELECT`, projections/aliases, `WHERE` `AND` / `OR` / `NOT`, comparisons, `IN`, `IS [NOT] NULL`, `LIKE`, `ORDER BY`, `LIMIT` / `OFFSET`, `COUNT` / `SUM` / `MIN` / `MAX`, `GROUP BY` / `HAVING` | No promise of JOINs, subqueries, window functions, CTEs, or a general expression optimizer |
| Transactions | Autocommit and `BEGIN` / `COMMIT` / `ROLLBACK` | A transaction’s write set is invisible before commit; commit is published by the single writer with WAL first and default durability; a statement error puts the transaction in failed state, and only `ROLLBACK` exits it |

The following are outside the first batch and must fail explicitly: `DO` / PL/pgSQL, functions, triggers, `CREATE EXTENSION`, system catalog and `information_schema` queries, advisory locks, table partitioning, `CREATE TYPE` / `ALTER TYPE`, concurrent index creation, role/permission DDL, JOINs, subqueries, CTEs, window functions, and full-text search.

The catalog module owns table, column, constraint, and index definitions. The transaction module owns transaction state, snapshots, and write sets. The commit path is the sole writer of catalog, indexes, and row data. `sql` only produces bound execution programs and cannot rewrite WAL or table storage; `storage` must not parse SQL text.

## Consequences

Positive: The initial batch forms a complete OLTP loop from migrations and parameter binding through transactional CRUD. Indexes and constraints have real semantics rather than serving as DDL placeholders, and the support scope is testable.

Negative: WAL representations for catalog changes, real secondary indexes, and a minimal transaction state machine are required. Some PostgreSQL application statements still fail explicitly, so this subset cannot be advertised as full PostgreSQL compatibility.

## Compatibility Requirements and Evidence

Each new semantic feature must satisfy all of the following:

1. `zig build test` covers parsing, binding, constraints, commit/rollback, and recovery.
2. `psql` and at least one mainstream PostgreSQL driver pass supported and rejected cases in the support matrix.
3. Power-loss/process-termination injection covers DDL, index changes, conflict writes, and commits; recovery exposes only the committed prefix.
4. Versioned SQL corpus entries are marked “supported and verified” or “explicitly rejected”; CI forbids unmarked success paths.
5. Dependencies remain `net -> sql -> txn/catalog -> storage`; `sql` must not import WAL directly, and `storage` must not depend on SQL or the wire protocol.

## Evolution and Failure Triggers

1. Establish the SQL corpus and real-client integration tests so unsupported cases fail reproducibly.
2. Implement the smallest persistent-catalog and `ALTER TABLE` slice, including recovery tests.
3. Implement extended-query binding, parameter types, and the transaction state machine.
4. Implement real unique/secondary indexes, conflict handling, and `RETURNING`.
5. Implement single-table predicates, ordering, aggregation, and grouping, evaluating access paths at data-volume thresholds.

Any request for procedural languages, triggers, system-catalog compatibility, partitioning, general JOINs/subqueries, or changed transaction-isolation promises requires a new ADR and must not be added as a parser exception.

**Supersedes / superseded by:** Supersedes no existing ADR; future scope expansion should supersede the relevant part of this decision through a new ADR.
