# Optional Object-Storage Payload Backend

## Status

Accepted target design. This ADR changes target contracts only: it extends the
physical-ownership scope of ADR-0019 with an optional object-storage payload
backend. No code exists against this design; the local payload slice of
ADR-0019 remains the default, the only shipped backend, and authoritative for
the implemented behavior. This ADR does not weaken the ADR-0019 logical,
recovery, or durability contracts.

## Context

ADR-0019 makes RunaDB Server the owner of Observation Evidence payload
durability: payload bytes live in versioned immutable files under the
instance's Data Directory, are validated through a versioned envelope, and are
checked again during recovery. It rejects external object-store references as
a substitute for RunaDB durability.

Large media — video and sensor captures above the 8 MiB payload limit — are
bounded per-byte by object storage cost and elasticity, while the current
baseline must hold every byte itself. ADR-0018 unifies World Continuum
contracts (Runa Flow, Runa Query IR, authorization, transaction, snapshot,
history, provenance, recovery), not physical engines: a form may use the most
suitable physical storage for its data, provided the contracts are met at the
boundary and no external store substitutes for RunaDB persistence.

This ADR therefore keeps local payload files as the default and defines an
optional object-storage backend that preserves the envelope, digest, recovery,
and durability contracts of ADR-0019.

## Decision

### 1. Default and only shipped backend: local payload files

ADR-0019 stands unchanged for the shipped product: payload bytes live in
immutable payload files under the Data Directory, and the WAL remains the
durability path. The object-storage backend is optional, explicit per
instance configuration, and non-default. It must never become a silent
durability downgrade: selecting it is an explicit operator decision, and its
durability-level semantics are documented per backend.

### 2. Backend, not reference

The object store holds the same ADR-0019 envelope as local payload files:

```text
magic | format_version | evidence_id | payload_length | digest_algorithm |
payload_digest | payload_bytes | frame_checksum
```

The catalog and WAL payload reference remains a RunaDB-internal value and is
never a public RunaDB Wire Protocol value. Reads validate length, digest, and
checksum exactly as for local files. The object key is derived from the
instance identity and the internal payload reference under a reserved path
prefix; it is never user-controlled.

Storing an external URL as the evidence value (a reference, not a backend)
remains rejected: no external reference substitutes for RunaDB persistence,
recovery, or authorization.

### 3. Scope of the minimal backend

- Single bucket, single region. Replication, versioning, lifecycle policies,
  and cross-region features are out of scope for the initial backend.
- Existing protocol limits hold: one staged attachment per Connection, a
  payload maximum of 8,388,608 bytes, and a chunk maximum of 262,144 bytes.
  Multipart and resumable upload are out of scope for the initial backend and
  require a protocol and resource-accounting revision.
- Credentials come from configuration (environment or configuration file),
  never from the data directory, logs, or the RunaDB Wire Protocol.
- Server-side encryption may be requested by configuration; it is not a
  RunaDB encryption, authenticity, or privacy contract.

### 4. Commit ordering

The object must be durably present and validated before the WAL append that
publishes the evidence: upload the envelope, verify the stored object (length
and digest), then append and synchronize the transaction WAL, then publish the
logical evidence to MVCC readers. This preserves the ADR-0019 invariant that
committed evidence is recoverable — there is no window in which a committed
reference exists without its payload. The upload is idempotent, keyed on
`evidence_id`; failed or interrupted uploads are retried or rejected before
the commit point and create no visible evidence. The backend's consistency
semantics (read-after-write visibility of the chosen object store) must be
declared in the implementing contract.

### 5. Recovery semantics

Recovery replays committed WAL records and produces the reference set, then
validates every referenced object against the backend (length, digest, and
envelope checksum), with bounded parallel verification. No full bucket listing
is required at startup. A missing or corrupt referenced object rejects startup
and preserves diagnostic evidence, matching the local rule: recovery must not
silently drop evidence or substitute an empty value. Uncommitted staging and
objects not referenced by committed records may be reclaimed only after
recovery establishes the committed reference set; cleanup is idempotent and
records counts and bytes.

### 6. Operator contract

Instance-wide staging and retained-byte quotas and the ADR-0019 metric
counters must account for remote bytes in addition to local bytes. Their
exposure remains Phase 7 administration work and is required before a
production support claim for the backend. Metrics must not expose credentials,
payload bytes, or origin secrets.

### 7. Unchanged logical contract

The World Continuum, Runa Flow, Runa Query IR, authorization, MVCC
visibility, provenance, and the logical evidence record are identical
regardless of backend. The backend is a physical placement behind the
ADR-0019 envelope; it does not change the evidence format version or the WAL
format.

## Consequences

- RunaDB Server keeps durability, recovery, and authorization ownership while
  gaining object-storage cost and elasticity for large payloads.
- A second payload backend doubles the payload-store format, corruption,
  interruption, and recovery test matrix; both backends must pass the same
  deterministic fault-injection and restart coverage before the backend can
  claim support.
- The object-storage backend is a physical placement, not a new data model or
  a bypass of the World Continuum boundary: it still binds to the same
  contracts and never becomes an external reference.
- ADR-0019's Non-Goals remain standing; in particular, an external reference
  as a substitute for RunaDB durability stays rejected.
- No generic multi-backend abstraction is added up front; a narrow payload
  backend seam is introduced only when the second backend is implemented.

## Delivery

1. Keep local payload files as the only shipped backend; do not build a
   generic payload-backend abstraction until a second backend is implemented.
2. Introduce a narrow payload-backend seam at the ADR-0019 payload-store
   boundary (put, get, delete, list-by-prefix, validate) with the local
   implementation as the only backend.
3. Before implementing the object-storage backend, publish a focused format
   and protocol revision defining the backend's consistency semantics,
   idempotent retry and verification, startup behavior for missing or corrupt
   remote objects, durability-level mapping, remote-byte resource accounting,
   metrics, and deterministic fault-injection and recovery tests.
4. Add official RunaDB Client end-to-end round trips and rejection coverage
   for the backend, and a public support entry, before marking it Verified.
