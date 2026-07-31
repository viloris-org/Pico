# Use an OLTP SQL Subset; Do Not Promise the Full PostgreSQL Dialect

**Status: Superseded by ADR-0017.** The described parser, executor, protocol,
and support matrix have been removed.

RunaDB’s external offering is **the PostgreSQL wire protocol plus a common OLTP SQL subset**. The parser and executor implement only the promised statements and types; all others fail explicitly.

The intended v1 capabilities include multiple tables, primary and secondary indexes, `INSERT` / `UPDATE` / `DELETE` / `SELECT` (including basic `WHERE`), transaction blocks, and a limited type set. Stored procedures, triggers, extensions, a full optimizer, and analytical syntax are outside the initial scope.

## Considered Options

- **Full PostgreSQL compatibility**: Offers the largest ecosystem, but would consume years of engineering effort and conflict with the lightweight goal.
- **KV-only / non-SQL**: Fast to implement, but gives up many existing tools and mental models.
- **OLTP SQL subset (adopted)**: Preserves driver and `psql` workflows while keeping the scope bounded.

## Consequences

- A public “support matrix” (statements, types, and isolation levels) must be maintained and updated with each release.
- The catalog and type system are designed for the subset; heavy catalog shapes must not be introduced early for “possible future compatibility.”
- Product copy must not say “PostgreSQL compatible” without specifying “protocol” or “subset.”
