# Embedding And Vector Retrieval Primitives

## Status

**Deprecated and permanently frozen.** The embedding and RAG (vector retrieval)
primitives in this ADR are explicitly rejected as a public product capability.
They are no longer a candidate surface for Runa Flow, Runa Query IR, or the
RunaDB Wire Protocol.

The internal/library slice remains implemented and tested with WAL v4
recovery, but only as frozen internal state: it is not extended, not exposed
through the wire protocol, and not documented as supported.

The **MEMO (Memory as a Model)** design in ADR-0022 is likewise frozen; no
memory or retrieval capability is currently an active product target. Any
future memory or retrieval capability must be introduced by a new ADR.

## Decision

RunaDB exposes `runadb.vector` for callers that already have an embedding. A
table may store an external embedding in a `vector` column. The module
validates non-empty, finite vectors, rejects dimension mismatches, and returns
deterministic Top-K candidates using one of three explicit score semantics:
cosine similarity, dot product, or negative squared Euclidean distance (higher
scores rank first). Ties are ordered by row index.

The server does not infer embeddings, execute a model, or build an on-disk
vector index in this slice. Observation Evidence remains
the factual input; an embedding is a derived representation supplied by an
external component. No future persisted representation, Flow/IR operation, or
wire-protocol surface will be built on these primitives. The **MEMO (Memory
as a Model)** design in ADR-0022 is likewise frozen; no memory or retrieval
capability is an active product target, and any future capability must be
introduced by a new ADR.

## Evidence

`src/vector.zig` contains deterministic normal and rejection tests for scoring,
dimension validation, non-finite values, limits, and tie ordering.
`src/storage/engine.zig` verifies vector-column WAL replay, checkpoint, restart,
and table-backed Top-K retrieval.

```text
FORMAT CHANGE
  owner:          WAL
  format version: 3 -> 4
  writer behavior: encodes vector values as a u16 dimension and little-endian f32 bits
  reader behavior: replays v1-v4; rejects empty, non-finite, or truncated vectors
  recovery rule:  validates every vector before the row becomes visible
  migration:      older binaries reject v4 WAL; no rewrite is provided
```
