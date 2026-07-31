# Runa Flow

Status: Partially implemented development contract. RunaDB Wire Protocol v2.0
accepts the read-only relation slice below as Runa Flow source or Runa Query IR.
Canonical IR also implements `observe` and `read_evidence_payload` for immutable
Observation Evidence. SQL text is not an accepted protocol request. All other
operation families remain target design.

## Purpose

Runa Flow is RunaDB's future formal data language. It presents requests as a
linear pipeline and binds them against a semantic model before any physical
planning occurs. It replaced RunaDB SQL in RunaDB Wire Protocol v1; protocol v2
adds the first World Continuum persistence slice.

## Pipeline Shape

Each line begins with `|` after the source. Names introduced by a stage are in
scope only for its following stages. The implemented read-only grammar is:

```text
from <relation>
| emit { <field> [, <field> ...] }
```

`observation_evidence` is an implemented read-only World Continuum view with
these fields: `evidence_id`, `object_id`, `modality`, `media_type`,
`observed_at`, `origin`, `owner`, `payload_length`, and `payload_digest`.
Reading metadata does not load payload bytes.

```runa-flow
from observation_evidence
| emit { evidence_id, object_id, modality, media_type, payload_length }
```

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

Static checking rejects invalid combinations before execution. Runtime checks
remain for data-dependent constraints, model results, and bounded-resource
conditions.

## Runa Query IR

Runa Flow source is parsed into a source AST, bound to a semantic model, and
validated into canonical Runa Query IR. The IR contains only executable,
versioned structure: operation graph, typed values, resolved semantic object
identities, result shape, policy requirements, and model revision. It does not
contain source formatting or natural-language text.

The official Zig RunaDB Client sends source or validated IR and implements
bounded Observation Evidence upload and payload retrieval. Canonical IR format
2 uses an explicit operation tag for relation `emit`, `observe`, and
`read_evidence_payload`; an older IR version is rejected rather than
reinterpreted.

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
executor, and protocol endpoints are not built. The v2 protocol and IR format
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
source-valid identifier is required for the relation and every emitted field,
and `emit` must contain at least one field. Malformed IR receives the Wire
Protocol's `RF1003` rejection; it is never normalized into a different request.

Observation Evidence payload files and WAL metadata use explicit development
format versions. Recovery validates every committed payload reference, length,
envelope checksum, and BLAKE3-256 digest. Missing, corrupt, or unsupported
payloads reject startup. A checkpoint preserves evidence metadata and is not a
user backup. Payload deletion, retention, encryption, deduplication, embedding,
similarity search, and model inference are not supported.
