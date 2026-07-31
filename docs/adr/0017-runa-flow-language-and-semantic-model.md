# Runa Flow: A Native Pipeline Language and Semantic Model

## Status

Accepted. This is the target public query contract for the next incompatible
RunaDB Wire Protocol major version. The currently implemented RunaDB SQL path is a
legacy implementation surface until that version is delivered; it is not a
claim that Runa Flow is already supported.

## Context

RunaDB SQL deliberately avoided PostgreSQL compatibility, but its SQL-shaped
syntax, table-first modeling, and statement-oriented protocol still constrain
the product to relational habits. Adding document, graph, vector, time, and
multimodal behavior as SQL extensions would create competing semantics and a
language that neither people nor agents can reliably transform.

RunaDB needs one formal query language that is readable in data-flow order,
expresses every supported data model through common operations, and has a
canonical structured representation. Natural-language interaction is valuable,
but it must not form a second, ambiguous execution language or bypass the same
semantic, authorization, resource, transaction, durability, and recovery
boundaries as a formal request.

## Decision

The next public language is **Runa Flow**. Runa Flow is a native, typed,
pipeline-oriented formal language and replaces RunaDB SQL as the future public
query contract. RunaDB Server will not add SQL compatibility or new SQL syntax.
A future compatibility adapter, if one is ever justified, is a separate
product decision and must not define Runa Flow semantics.

A query reads from top to bottom as a sequence of named transformations. The
initial operation families are source, match, navigate, filter, project,
group, aggregate, window, rank, limit, mutate, and emit. Relation scans,
document paths, graph traversal, vector similarity, temporal windows, and
multimodal predicates are operations in this one algebra. They are not syntax
extensions with independent authorization, type, snapshot, or result rules.
Each operation specifies its input and output shape, cardinality effect,
ordering requirement, nullability behavior, authorization requirements, and
resource accounting. A capability is unsupported until all of those semantics
are defined and tested.

Every executable request has three representations:

1. Runa Flow source text for people and text-oriented tools.
2. A source AST that preserves source locations and comments where required
   for diagnostics and editing.
3. Canonical, versioned **Runa Query IR**, a serializable typed representation
   produced only after binding against a semantic model and validating policy.

Runa Query IR is the execution, cache, provenance, SDK, and wire-level
interchange boundary. Its canonical encoding includes an IR format version and
semantic-model revision. It excludes incidental source formatting and
natural-language prose. Equivalent source requests must produce equivalent IR
after binding; a stable semantic explanation is generated from the validated
IR, not from the original prose.

The catalog gains a semantic-model layer before physical-storage choices. A
semantic model declares entities, relationships, attributes, measures,
constraints, policy references, and temporal meanings. A model binding maps
those declared meanings to physical tables, indexes, and value representations.
Runa Flow resolves user-facing names through this layer; execution planning
may choose physical access paths without exposing them as language semantics.
Physical tables remain a supported storage implementation detail until a later
model contract changes that boundary.

Natural-language requests are advisory compilation input. An AI-assisted
request may produce candidate Runa Flow and Runa Query IR only after it states
the resolved semantic names, assumptions, requested operation, and expected
result shape. The server then performs ordinary parse, binding, type, policy,
resource, transaction, and durability validation. It executes only the
validated IR. Ambiguity, missing semantic bindings, unauthorized access, or a
non-representable request fails explicitly; it never causes guessed execution.
The client or agent can obtain the explanation and validation result before
execution, and policy may require explicit human approval for generated
mutations.

Runa Flow has strong static types for declared values, result shapes, units,
time domains, and operation inputs. Semi-structured values are typed values,
not untyped escape hatches: a possibly absent path produces an explicit
optional value, and refinement or a declared fallback is required before an
operation that needs a present value. Runtime validation remains responsible
for data-dependent constraints, external model outputs, resource limits, and
values whose declared type cannot establish a property statically.

RunaDB deliberately permits destructive evolution while Runa Flow, RunaDB Query
IR, the semantic-model schema, and the next protocol major are being designed.
That permission is not a license for accidental semantics. Before Runa Flow is
declared supported, source syntax, IR fields, protocol messages, catalog
layouts, and storage formats may break without a compatibility adapter. Each
such break must have an explicit version boundary: an older client, IR, or
data directory is rejected with a clear incompatibility error, or a separately
specified migration transforms it. RunaDB must never silently reinterpret an old
request, IR, model binding, or persisted value under new semantics.

The criterion for stabilizing a boundary is not how much code has accumulated
behind it. A boundary becomes compatible only when its meaning, authorization,
transaction and durability behavior, resource limits, recovery behavior,
versioning, and regression evidence are explicit. This preserves the freedom
to replace provisional design while protecting committed data from ambiguous
interpretation.

## Consequences

- `RunaDB SQL`, SQL support matrices, SQL statement terminology, and SQL-specific
  client APIs are legacy-only after the new protocol major version ships.
- The next incompatible RunaDB Wire Protocol major version must accept canonical
  Runa Query IR and may accept Runa Flow source as a convenience encoding. It
  must return protocol-version, IR-format-version, parse, binding, type,
  policy, resource, and execution errors distinctly. It must not send raw SQL
  text as its public query payload.
- SQL parser and executor removal may be destructive once Runa Flow provides a
  tested replacement for the required current baseline workflows. No silent
  SQL-to-Flow translation is permitted.
- Before Runa Flow is supported, compatibility is opt-in and narrowly scoped;
  no source, IR, wire, catalog, or storage compatibility is inferred from a
  version number, test fixture, or previous development build. A rejected old
  format must leave the data directory unchanged and preserve the evidence
  required for an explicit migration.
- Semantic-model edits, Query IR format changes, and model bindings are
  versioned catalog data. Their WAL representation, recovery validation,
  migration behavior, and rollback/failure behavior require focused designs
  before persistence support lands.
- AI-generated requests are recorded as provenance only when the provenance
  contract, retention policy, and trust boundary are explicitly implemented.
  Until then, explanations and validation output are diagnostic material, not
  a verifiable historical record.
- RunaDB Client and RunaDB Server retain their independent-product boundary. Their
  shared implementation definitions remain exclusively under `clint/proto/`.

This ADR supersedes the future-language portions of ADR-0003, ADR-0008,
ADR-0009, ADR-0010, ADR-0011, ADR-0012, ADR-0013, and ADR-0016 that name RunaDB
SQL as a lasting public contract. It does not change their current
single-instance, WAL-first, single-writer, MVCC, recovery, or client/server
boundary constraints. ADR-0016's natural-language rule is refined: natural
language is advisory until converted into validated Runa Query IR.

## Delivery

1. Publish the Runa Flow grammar, canonical Runa Query IR schema, static type
   rules, semantic-model schema, error model, and protocol-major negotiation.
2. Build read-only relation, document, and graph vertical slices through the
   official RunaDB Client, including round-trip source-to-IR explanation and
   deterministic rejection coverage.
3. Add mutations, transactions, authorization, and durability semantics only
   after their IR forms, WAL recovery behavior, and failure-injection coverage
   are specified.
4. Release a new protocol major with no RunaDB SQL execution endpoint; remove
   the legacy SQL implementation and its support matrix only after the new
   supported baseline is verified end to end.
