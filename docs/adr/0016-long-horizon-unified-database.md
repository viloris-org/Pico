# Long-Horizon Positioning: A Unified, Verifiable Data System

## Status

Accepted

## Context

ADR-0001 positioned RunaDB as a lightweight, single-node network OLTP database.
That remains an accurate description of the implemented baseline, but it is no
longer an adequate product direction. RunaDB is intended to become a
high-performance, general-purpose data system that can preserve and reason
over valuable data for decades.

The direction must not turn a list of future technologies into a current
support claim. Distributed operation, multiple data models, multimodal data,
HTAP, AI-assisted execution, post-quantum cryptography, and quantum-assisted
optimization all need separate designs with explicit semantics, failure modes,
format versions, and regression evidence.

## Decision

RunaDB's long-horizon product direction is a **unified, verifiable data system**:
one system for relational, document, graph, vector, time-series, key-value,
and spatial data, with extensible types for text, images, audio, video, and
sensor streams. These models must be able to participate in a common catalog,
authorization model, history, provenance model, and query plan. They are not a
commitment to expose loosely coupled databases behind one brand.

RunaDB will evolve toward the following enduring properties:

1. **Unified data and query model.** RunaDB SQL and the RunaDB Wire Protocol will
   gain explicit, versioned representations for additional data models and
   multimodal values. Flexible modeling must remain semantically explicit;
   automatic adaptation must not silently alter meaning or constraints.
2. **AI-native operation with verifiable boundaries.** Embedding, vector
   retrieval, and retrieval-augmented generation are permanently frozen and
   deprecated (see ADR-0020). Future memory and retrieval capabilities are
   designed as **MEMO (Memory as a Model)** per ADR-0022. Graph
   reasoning and in-database inference may
   run near governed data. Neural results may assist ranking or interpretation;
   symbolic predicates, authorization, transactions, provenance, and declared
   constraints remain authoritative. Natural-language interfaces are advisory
   until their generated plans are validated against the same permissions and
   semantics as RunaDB SQL.
3. **Continuum-scale execution.** RunaDB may evolve from one instance to
   multi-region and edge-to-cloud deployments, with transactional, analytical,
   and streaming workloads sharing governed data. Every consistency level,
   placement decision, replication rule, and distributed failure outcome must
   be declared rather than inferred from a topology.
4. **Long-lived correctness.** Durable commits, recoverable formats,
   configurable consistency, historical versions, time-travel queries, and
   cryptographically verifiable provenance are core product concerns. A
   checkpoint remains an internal recovery mechanism and is not a user backup
   or historical-retention promise.
5. **Privacy, security, and sustainability by design.** RunaDB will plan for
   cryptographic agility including post-quantum algorithms, encryption in
   transit and at rest, confidential-computing integrations where feasible,
   least-privilege authorization, audit, lineage, differential privacy, energy
   efficiency, and hardware diversity. No security property is supported until
   its threat model and operational behavior are published.
6. **Operable openness and evolution.** Declarative interfaces, conservative
   defaults, automation, observability, open formats where possible, portable
   export/import, extension points, versioned migrations, and compatibility
   policies are first-class. Autonomous optimization or repair may recommend
   or execute only actions whose safety, authority, and rollback boundaries are
   explicit.

The current implementation remains a single-instance, network-accessible OLTP
baseline. Its WAL-first durability, explicit unsupported-SQL failures,
single-writer commit ordering, MVCC/LSM target architecture, and RunaDB-native
client boundary remain valid local constraints until superseded by focused
ADRs. They are foundations for the long-horizon direction, not evidence that
future capabilities already exist.

## Consequences

- ADR-0001 is superseded as RunaDB's product positioning. Its implemented
  single-node deployment constraints remain applicable to the current baseline
  until a later ADR changes a specific subsystem.
- New public concepts require updates to `CONTEXT.md`, the RunaDB SQL support
  matrix or RunaDB Wire Protocol, compatibility/version policy, permissions,
  observability, and end-to-end regressions.
- A proposal for a new model, AI capability, distributed behavior, storage
  backend, accelerator, cryptographic algorithm, or historical guarantee must
  define: data and query semantics; consistency/durability; authorization and
  provenance; cost and energy behavior where material; format migration; and
  failure/recovery behavior.
- Plugin and extension mechanisms must preserve the server/client protocol
  boundary and may not bypass catalog, transaction, durability, or permission
  ownership.
- “Autonomous” never removes the requirement for observable policy, bounded
  resource use, operator control, and a clear audit trail.

## Delivery

1. Retain the current recoverable OLTP baseline and publish only verified
   capabilities as supported.
2. Establish versioned foundational contracts for extensible values, catalog
   metadata, provenance, historical retention, and portable export.
3. Add new models and AI execution through vertical slices with explicit query,
   transaction, authorization, and recovery semantics.
4. Introduce distributed, HTAP, streaming, edge, cryptographic, and hardware
   capabilities through separate ADRs after their local correctness contracts
   are testable.
5. Maintain upgrade, migration, integrity-verification, and energy metrics as
   capabilities grow; long-lived data must remain readable or fail with a
   documented migration path.
