# Runa Flow

Status: Target design. Runa Flow is defined by ADR-0017 and is not implemented
by the checked-out RunaDB Server. The current `v0.1` RunaDB Wire Protocol still
accepts RunaDB SQL text as a legacy implementation surface.

## Purpose

Runa Flow is RunaDB's future formal data language. It presents requests as a
linear pipeline and binds them against a semantic model before any physical
planning occurs. It replaces RunaDB SQL in the next incompatible RunaDB Wire
Protocol major version.

## Pipeline Shape

Each line begins with `|` after the source. Names introduced by a stage are in
scope only for its following stages. The syntax below is illustrative until the
grammar is published; it specifies the intended reading order, not supported
syntax.

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

`from customer` names a semantic entity, not a physical table. The semantic
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
