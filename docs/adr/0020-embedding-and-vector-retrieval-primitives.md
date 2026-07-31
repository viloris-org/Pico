# Embedding And Vector Retrieval Primitives

## Status

Implemented and tested as an internal/library capability with WAL v4 recovery.
This does not add a Runa Flow or RunaDB Wire Protocol operation.

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
external component. A future persisted representation and Flow/IR operation
must define its Representation Chart, model/provenance metadata, WAL and
recovery format, resource limits, and protocol version before becoming a public
query capability.

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
