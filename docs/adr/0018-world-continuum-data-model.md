# World Continuum: A Continuous, Verifiable Native Data Model

## Status

Accepted target design. This ADR changes target contracts only. It does not
describe an implemented capability of the current single-instance OLTP
baseline.

## Context

ADR-0016 sets a direction toward a unified, verifiable data system, and
ADR-0017 replaces RunaDB SQL with Runa Flow and Runa Query IR. Treating
relational, document, graph, vector, time-series, key-value, spatial, and
multimodal data as independent models would retain incompatible user concepts
and produce a "file + embedding + metadata" assembly. It cannot express a
world state that evolves through time, supports causal simulation, or allows
representations to evolve without silently changing the meaning of facts.

A learned representation alone is not a sufficient persistent truth. It is
lossy, model-dependent, and can be reinterpreted by a later model. RunaDB must
preserve enough attributed observation evidence to validate, re-project, audit,
and recover its state.

## Decision

The target logical data model is the **World Continuum**. It is the sole
top-level user-visible data abstraction. Relations, documents, key-value
entries, media items, vectors, sensor records, code, simulations, and agent
memory are views, observation forms, or physical bindings within this model;
they are not competing top-level data models.

A World Continuum contains these first-class forms:

| Form | Contract |
| --- | --- |
| Continuum Object | A stable logical identity with a declared kind, temporal extent, relationships, and state bindings. |
| Observation Evidence | Immutable attributed factual input, including its origin, time, coordinate reference, declared interpretation, and the information necessary for future validation or re-projection. |
| State Field | A versioned estimate over declared temporal, spatial, relational, or latent domains. It may be continuous, discretized, or multi-resolution. |
| Representation Chart | A versioned contract for coordinates, projections, decoders, input coverage, uncertainty, resource behavior, and compatibility. |
| Causal Dynamics | A declared state-transition or intervention contract that can produce predictions or simulations. |
| Counterfactual Branch | An isolated hypothetical state with explicit assumptions, interventions, model versions, uncertainty, and derivation. |

The World Continuum is a unified representation space, but it is not a promise
that every modality shares one opaque vector or one irreversible learned model.
A Representation Chart may map many forms into a common continuous domain and
may coexist with other charts. Its coordinate values are always interpreted
through their chart. Observation Evidence remains the factual anchor; a State
Field, learned output, simulation, or Counterfactual Branch must never silently
replace it.

Unification is a contract, not a physical requirement. A World Continuum form
is not required to share one engine or storage substrate with other forms:
each form may use the most suitable physical engine and storage for its data,
provided the World Continuum query, governance, history, provenance, and
recovery contracts are met at the boundary and no external store substitutes
for RunaDB durability. Large multimodal payloads, for example, may be held by
an object-storage payload backend (ADR-0025) without becoming external
references. The single request surface is Runa Flow and Runa Query IR; physical
bindings are versioned implementation details, never a second query language.

RunaDB supports representation evolution through immutable chart versions,
explicit validity and coverage ranges, and re-projection transitions. A new
chart may be populated incrementally or on demand. It must report its coverage
and version rather than present mixed or stale state as a completed upgrade. A
chart may only be retired after its retention and migration contract is met.
RunaDB does not promise that any future chart can be constructed without
re-reading applicable Observation Evidence or recomputing applicable state.

Runa Flow remains the formal request language and Runa Query IR remains the
canonical validated execution interchange. Their target algebra is centered on
`observe`, `locate`, `navigate`, `filter`, `project`, `evolve`, `simulate`,
`intervene`, `explain`, and `emit`. Operations bind Continuum Object kinds,
State Fields, Representation Charts, coordinate references, units, time
domains, uncertainty, authorization, ordering, cardinality, and resource
limits before execution. Existing relation, document path, graph, vector, and
temporal operations become views expressed through this algebra; they do not
create separate authorization, transaction, snapshot, or result semantics.

An Agent is a first-class Continuum Object. Its memories, goals, observations,
relationships, action proposals, and results may be recorded in the World
Continuum. An Agent can only affect factual state through a validated Runa Flow
Request, Runa Query IR, authorization policy, resource limits, transaction
rules, and the ordinary durability path. Generated actions, predictions, and
explanations remain attributed derivations unless an authorized Request accepts
them as Observation Evidence.

Spatiotemporal and embodied state is represented as State Fields bound to
declared coordinate references, units, sampling rules, interpolation rules,
uncertainty, and temporal domains. RunaDB must reject a request that combines
incompatible references, units, or time semantics rather than guessing a
conversion.

The World Continuum does not weaken current baseline invariants. RunaDB Server
remains single-instance; the single writer orders factual-state publication;
WAL evidence precedes durable commit; and reads use snapshots. Any persisted
Observation Evidence, State Field, chart, branch, or model contract requires a
versioned recovery format, explicit migration or refusal behavior, resource
limits, authorization semantics, observability, and deterministic recovery
tests before it is supported.

## Consequences

- The future table, document, key-value, media, and embedding concepts must be
  designed as World Continuum views or bindings. New top-level APIs that expose
  them as independent stores are rejected.
- A file upload endpoint, vector-index endpoint, model-inference endpoint, or
  agent action endpoint is not a valid public capability until it binds to the
  same World Continuum, Runa Flow, Runa Query IR, authorization, transaction,
  durability, and provenance contracts.
- Predictions, generated state, and counterfactual results must expose their
  assumptions, Representation Chart, Causal Dynamics version, evidence
  coverage, uncertainty, and derivation. They must not be returned as observed
  facts.
- The RunaDB Wire Protocol next major version must carry the typed Runa Query
  IR forms required by this model. It must not treat opaque model output or
  unvalidated natural-language requests as executable input.
- Physical bindings are free to use the best engine and storage per form; the
  World Continuum contracts (query, governance, history, provenance,
  recovery) are unified, not the physical implementation.
- ADR-0017 remains authoritative for Runa Flow, Runa Query IR, validated
  execution, and the RunaDB Client/RunaDB Server seam. This ADR supersedes its
  future model-specific operation framing and its semantic-model assumption
  that entities map primarily to physical tables.
- Focused ADRs are required before implementing persistent formats; chart and
  model lifecycle; Causal Dynamics and Counterfactual Branches; Agent action
  policy; or spatiotemporal State Fields.

## Delivery

1. Define a versioned, read-only Runa Query IR slice for Continuum Object,
   Observation Evidence, State Field, and Representation Chart inspection.
2. Deliver the matching RunaDB Wire Protocol major-version negotiation and
   official RunaDB Client round trips, including deterministic rejection
   coverage for incompatible charts, units, coordinate references, coverage,
   and policy.
3. Define persistent formats, WAL recovery, failure injection, and
   observability for one local State Field and one Representation Chart before
   enabling factual writes.
4. Add chart re-projection, Causal Dynamics, Counterfactual Branches, and
   Agent actions only through separate focused ADRs with their execution,
   authorization, resource, durability, recovery, and provenance contracts.
