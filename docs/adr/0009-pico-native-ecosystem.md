# Pico-Native Protocol and Pico SQL; No PostgreSQL Compatibility Promise

Pico is an independent, single-node, lightweight, network-accessible OLTP database. Its external interfaces are the **Pico wire protocol** and **Pico SQL**; Pico defines their semantics, versions, and client ecosystem. Pico makes no promise of PostgreSQL wire-protocol, dialect, type-system, error-code, driver, or tool compatibility.

This decision supersedes ADR-0002’s PostgreSQL Frontend/Backend protocol decision and the portion of ADR-0003 that uses PostgreSQL-driver compatibility to define the SQL subset. ADR-0003’s rule that only published SQL is promised and unsupported syntax must fail explicitly remains valid. It also supersedes ADR-0007’s PostgreSQL-client consequence and ADR-0008’s PostgreSQL-driver and extended-query acceptance requirements; the remaining Zig and SQL-scope constraints continue to apply.

## Decision Drivers

1. Pico must define its product boundary rather than being pulled toward PostgreSQL protocol and behavioral compatibility.
2. SQL, types, errors, and the wire protocol can evolve independently while retaining single-node OLTP, low-resource, and recoverability goals.
3. Breaking interface changes must be visible to clients, documentation, and tests; “apparently connectable but semantically inconsistent” compatibility is unacceptable.

## Considered Options

- **Continue PostgreSQL driver compatibility**: rejected because compatibility expectations would continually expand and constrain interface and SQL evolution.
- **Retain PostgreSQL protocol as a dual-protocol product**: rejected unless a future ADR explicitly restores a compatibility layer, because it requires two public contracts and test matrices.
- **Pico-native ecosystem (adopted)**: The sole product contract is the versioned Pico protocol, Pico SQL, official client tools, and a public support matrix.

## Consequences

- New or changed client capabilities must define a Pico protocol version, Pico SQL support matrix, error model, and official-client compatibility scope.
- Network, SQL, and client-tool regression tests use the official Pico CLI/driver; `psql` and PostgreSQL drivers are no longer product acceptance criteria.
- The PostgreSQL Frontend/Backend Protocol may remain only as an explicitly unstable migration adapter and must be removed after the Pico-native protocol is available.
- `src/net` targets the Pico wire protocol and `src/sql` targets Pico SQL. Storage, transactions, WAL, and LSM correctness must not depend on an external database protocol.
- External documentation must not say “PostgreSQL compatible” or “use PostgreSQL drivers” without clearly stating that this is not a compatibility promise.
- Independent Pico Client and Pico Server releases and boundaries are defined by ADR-0010.

## Migration and Validation

1. Publish the Pico protocol, Pico SQL, error model, and version-negotiation specifications with a minimal official CLI/driver.
2. Implement an end-to-end statement and transaction slice and gate it on protocol consistency, SQL support, recovery, and durability regressions.
3. Make the current PostgreSQL adapter an explicit transitional mode and remove product tests that depend on its aliases, error codes, or clients.
4. Remove the adapter, its port, and connection examples. Any reintroduced compatibility layer requires a new ADR with scope, version policy, cost ceiling, and exit conditions.

Until steps 1–3 finish, the current implementation may still accept the PostgreSQL Frontend/Backend Protocol. That is implementation status, not an external Pico compatibility promise.
