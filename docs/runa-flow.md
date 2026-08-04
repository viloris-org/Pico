# Runa Flow

Status: Partially implemented development contract. RunaDB Wire Protocol v3.0
accepts the read-only relation, document collection, graph, and KV collection
slices below as Runa Flow source or Runa Query IR. Canonical IR also implements
`observe` and `read_evidence_payload` for immutable Observation Evidence,
`document_insert` for document collection ingestion, `graph_add_node`/
`graph_add_edge` for graph ingestion, and `kv_put` for KV collection ingestion.
SQL text is not an accepted protocol request. All other operation families
remain target design.

## Purpose

Runa Flow is RunaDB's future formal data language. It presents requests as a
linear pipeline and binds them against a semantic model before any physical
planning occurs. It replaced RunaDB SQL in RunaDB Wire Protocol v1; protocol v2
added the first World Continuum persistence slice, and protocol v3 is the current
development contract.

## Pipeline Shape

Each line begins with `|` after the source. Names introduced by a stage are in
scope only for its following stages. The implemented read-only grammar is:

```text
from <relation>
| where <predicate>   (zero or more, AND-combined)
| emit { <field> [, <field> ...] }
| limit <non-negative integer>
```

A `where` stage filters rows before projection and `limit`; several `where`
stages are combined with AND. Each predicate names a column and one operator:

```text
column = literal | column != literal
column < literal | column <= literal | column > literal | column >= literal
column is null | column is not null
column [not] in ( literal [, literal ...] )
column [not] like 'pattern'
```

Literals are non-negative or negative integers, `true` or `false`, or a
single-quoted text value. The literal type must match the column's declared
type: ordering operators require an orderable column, `like` requires text, and
every member of an `in` list shares the same type. A mismatch is a static
binding failure, never a silent no-match.

`observation_evidence` is an implemented read-only World Continuum view with
these fields: `evidence_id`, `object_id`, `modality`, `media_type`,
`observed_at`, `origin`, `owner`, `payload_length`, and `payload_digest`.
Reading metadata does not load payload bytes. The view supports `where` on its
typed fields, including `evidence_id` and `payload_length` as integers.

```runa-flow
from observation_evidence
| where object_id = 'camera_1'
| emit { evidence_id, modality, media_type, payload_length }
```

`limit` is an optional final stage for relation projections, including the
`observation_evidence` view. It bounds the number of returned rows; `limit 0`
returns an empty result. Ordering is the relation's current read order because
no ordering stage is implemented yet.

## Document Collections

A **document collection** is a read-only vertical slice for variable-shape
objects. Each document has a text id and an ordered set of named fields; a
field is addressed by a dotted path such as `author.name`. `emit` fields and
`where` predicates accept dotted paths, so the relation grammar above reads
documents unchanged:

```runa-flow
from books
| where author.name = 'Herbert'
| emit { title, author.name, pages }
| limit 5
```

Semantics of the document slice:

- A document collection is populated through the official RunaDB Client's
  `insertDocument` operation (canonical IR `document_insert`), which creates
  the collection on its first insert and rejects a duplicate document id. The
  collection name is exclusive with table names.
- `emit` resolves each dotted path against the document; a path absent from a
  particular document reads as null. Paths are not type-checked statically
  because documents are variable-shape; a `where` predicate matches only a
  same-typed field value, and an absent or differently typed field does not
  match that document.
- Reads follow the collection's insertion order, matching the relation slice's
  read order. `limit` bounds the returned rows.
- This slice does not imply World Continuum State Field or Representation Chart
  support, arrays, schema evolution, or document mutation beyond insertion.

## Graph Collections

A **graph** is a read-only vertical slice for labeled directed edges between
nodes. A node is a document-like object (id plus named fields), so node reads
use the document semantics above. The `navigate` stage traverses one labeled
hop and names the destination node so the following `emit` can project it:

```runa-flow
from social
| where name = 'Ada'
| navigate mentors as mentee
| emit { name, mentee.name }
| limit 5
```

Semantics of the graph slice:

- Nodes and edges are ingested through the official RunaDB Client's `addNode`
  and `addEdge` operations (canonical IR `graph_add_node`/`graph_add_edge`).
  `addNode` creates the graph on its first node; `addEdge` requires both
  endpoints to exist and rejects a duplicate `(from, label, to)` triple.
- `navigate <edge> as <alias>` expands each surviving source node into one row
  per outgoing edge labeled `edge`. A node with no matching edge produces no
  row. In the `emit`, an unqualified path resolves against the source node and
  `alias.<path>` resolves against the destination node.
- Reads follow insertion order (nodes, then edges). `where` stages precede
  `navigate` and filter source nodes; `limit` bounds the returned rows.
- This slice does not imply multi-hop path queries, shortest paths, transitive
  closures, graph mutation beyond adding nodes and edges, or World Continuum
  State Field and Representation Chart support.

## KV Collections

A **KV collection** is a read-only vertical slice that maps a text **key** to a
scalar **value** (`int`, `text`, `bool`, or `null`). Each entry reads as a
two-field row through the relation grammar above, so no new source stages are
needed:

```runa-flow
from session
| where key = 'theme'
| emit { key, value }
| limit 5
```

Semantics of the KV slice:

- Entries are ingested through the official RunaDB Client's `putKv` operation
  (canonical IR `kv_put`), which creates the collection on its first put. A put
  is an **upsert**: it stores the value for a key, replacing the value of an
  existing key. Keys are arbitrary non-empty text; values are scalar-only, and
  a vector value is rejected rather than silently stored.
- `emit` resolves `key` to the entry's text key and `value` to its scalar;
  any other path reads as null, exactly like an absent document field. A
  `where` predicate on `key` or `value` filters entries; a type mismatch
  behaves like an absent value and never matches.
- Reads follow insertion order (a replaced key keeps its original position);
  `where` filters and `limit` bounds the returned rows.
- This slice does not imply delete, TTLs, range scans beyond the `where`/
  `limit` stages, or World Continuum State Field and Representation Chart
  support.

Other stages shown below are illustrative until their grammar and semantics are
published.

```runa-flow
from customer
| navigate orders as order
| where order.placed_at in last 30d
| group by customer.region
| aggregate { revenue: sum(order.total) }
| rank revenue descending
| emit { region: customer.region, revenue }
```

The same pipeline discipline applies to every supported model. For example,
`navigate` traverses declared relationships, whether their storage binding is a
foreign key, document edge, or graph edge. A vector search is a ranked source
or rank operation with declared distance semantics; it does not introduce a
second query language. A temporal operation identifies its declared time
domain, and a multimodal operation identifies the typed value and model result
it consumes.

## Semantic Binding

`from customer` ultimately names a semantic entity, not a physical table. The semantic
model owns the meanings of entities, relationships, attributes, measures,
constraints, policy references, and time domains. A versioned binding maps
those names to physical storage and indexes. The optimizer may change an
access path without changing the request's meaning.

An unresolved name, ambiguous relationship, invalid time domain, or operation
outside the caller's policy fails during binding. The request is not guessed or
rewritten to a similarly named physical field.

## Types

Every stage has an input row shape and output row shape. Scalar values have
declared types; paths over sparse or semi-structured values produce an optional
type. A stage requiring a present value must refine it or supply an explicit
fallback. Units, time domains, vector dimensions, and multimodal value kinds
participate in validation where applicable.

Static checking rejects invalid combinations before execution. In the initial
slice, `where` literals are checked against the bound column type, ordering
operators require an orderable column, and `like` requires a text column.
Runtime checks remain for data-dependent constraints, model results, and
bounded-resource conditions.

## Runa Query IR

Runa Flow source is parsed into a source AST, bound to a semantic model, and
validated into canonical Runa Query IR. The IR contains only executable,
versioned structure: operation graph, typed values, resolved semantic object
identities, result shape, policy requirements, and model revision. It does not
contain source formatting or natural-language text.

The official Zig RunaDB Client sends source or validated IR and implements
bounded Observation Evidence upload, payload retrieval, document collection
ingestion, graph ingestion, and KV collection ingestion. Canonical IR format 6
uses an explicit operation tag for relation `emit`, `observe`,
`read_evidence_payload`, `document_insert`, `graph_add_node`,
`graph_add_edge`, and `kv_put`; relation `emit` carries optional `where`
predicates and the optional `limit` stage. An older IR version is rejected
rather than reinterpreted.

`observe` binds a completed protocol attachment to an `object_id`, declared
modality, normalized media type, observation time, and origin. The Server sets
the owner from the Connection context; the development authentication context
currently records `development`. Evidence is immutable and append-only. The
Server validates declared metadata and payload integrity but does not infer the
media type, transcode content, extract features, create embeddings, or execute
models.

## Natural-Language Requests

A natural-language request produces a candidate Runa Flow request and an
explanation. Before execution, RunaDB validates the resulting IR exactly as it
does for hand-written Runa Flow, including authorization, types, resource
limits, transaction rules, and durability level. The explanation must identify
resolved names, assumptions, requested operation, and result shape. Ambiguous
or unverifiable requests fail explicitly.

Natural language is never an alternate execution semantics and does not grant
access beyond the Connection's policy. Generated mutations may require an
explicit approval policy; defining that policy is separate work.

## Compatibility

No SQL compatibility layer is part of Runa Flow. The retired SQL parser,
executor, and protocol endpoints are not built. The v3 protocol and IR format
remain development contracts until the formal grammar, semantic model, and
compatibility policy are published.

Until then, Runa Flow source, Runa Query IR, semantic-model layouts, and
development storage formats may change destructively. An incompatible input or
data directory must be rejected explicitly or migrated by a separately defined
tool; RunaDB must not silently reinterpret it under changed semantics.

The current implementation uses semantic-model revision `0`, an explicit
development-only binding from relation names to the existing table catalog. It
has no persisted semantic-model layout and must not be treated as a stable
World Continuum binding. An unknown relation or field fails explicitly.
Direct Runa Query IR input is also checked for the initial canonical shape: a
source-valid identifier is required for the relation, every `where` column, and
every emitted field; `emit` must contain at least one field; `in` lists must be
non-empty and homogeneous; and a `like` pattern must be text. Malformed IR
receives the Wire Protocol's `RF1003` rejection; it is never normalized into a
different request.

Observation Evidence payload files and WAL metadata use explicit development
format versions. Recovery validates every committed payload reference, length,
envelope checksum, and BLAKE3-256 digest. Missing, corrupt, or unsupported
payloads reject startup. A checkpoint preserves evidence metadata and is not a
user backup. Payload deletion, retention, encryption, deduplication, embedding
generation, similarity search as a Runa Flow operation, and model inference
are not supported. The embedding and RAG (vector retrieval) primitives are
deprecated and permanently frozen (see ADR-0020); the server library retains
internal `vector` table columns and bounded `runadb.vector` ranking as frozen
internal state only. Neither is available through the wire protocol. The
**MEMO (Memory as a Model)** design in ADR-0022 is likewise frozen; no memory
or retrieval capability is an active product target.
