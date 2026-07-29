# Product Positioning: Lightweight Single-Node Network OLTP, Not Embedded or Distributed

Pico is positioned as a **single-node server** database: a single-binary deployment with low resource usage, fast startup, network access for multiple clients, and predictable write-path behavior under high contention.

**Explicit non-goals (at least until a new ADR is introduced)**: a purely embedded library form, a multi-node consensus cluster, a full analytical (OLAP) engine, and feature breadth equivalent to the PostgreSQL server.

## Considered Options

- **Embedded-first (SQLite path)**: Extremely lightweight, but not a network service by default; its multiple-writer model conflicts with the network-accessible product story.
- **Distributed SQL**: A strong ecosystem story, but its deployment and operations complexity directly violates the lightweight goal.
- **Single-node network OLTP (adopted)**: Satisfies both lightweight operation and network access; replication and read-only replicas can be considered after the single-node engine is solid.

## Consequences

- All “cluster / sharding / automatic failover” requests are rejected by default or handled as separate initiatives; they must not enter the v1 storage or transaction semantics.
- If an embedded linking form is needed in the future, it should reuse the same engine rather than allowing a thin library wrapper around the server to drive the design.
