# Runa Flow

Status: Partially implemented development contract. RunaDB Wire Protocol v1.0
accepts the read-only relation slice below as Runa Flow source or Runa Query IR.
SQL text is not an accepted protocol request. All other operation families
remain target design until their semantic, policy, transaction, durability, and
recovery contracts are delivered.

## Purpose

Runa Flow is RunaDB's future formal data language. It presents requests as a
linear pipeline and binds them against a semantic model before any physical
planning occurs. It replaces RunaDB SQL in the next incompatible RunaDB Wire
Protocol major version.

## Pipeline Shape

Each line begins with `|` after the source. Names introduced by a stage are in
scope only for its following stages. The implemented read-only grammar is:

```text
from <relation>
| emit { <field> [, <field> ...] }
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

The official RunaDB Client and SDKs will support sending source for compilation,
sending validated IR where the protocol permits it, receiving a canonical
explanation, and receiving explicit validation errors. Cache keys, query
versioning, and provenance references use the IR plus model revision rather
than source text.

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

No SQL compatibility layer is part of Runa Flow. The current SQL support
matrix remains a record of the legacy implementation only. The new protocol
major, IR versioning rules, migration policy, and formal grammar must be
published before Runa Flow becomes a supported public capability.

Until then, Runa Flow source, Runa Query IR, semantic-model layouts, and
development storage formats may change destructively. An incompatible input or
data directory must be rejected explicitly or migrated by a separately defined
tool; RunaDB must not silently reinterpret it under changed semantics.

The current implementation uses semantic-model revision `0`, an explicit
development-only binding from relation names to the existing table catalog. It
has no persisted semantic-model layout and must not be treated as a stable
World Continuum binding. An unknown relation or field fails explicitly.
