# MEMO: Memory as a Model

## Status

**Frozen.** The MEMO (Memory as a Model) design in this ADR is frozen: it is
not an active target design and will not be implemented in the current
baseline. It is no longer a candidate surface for Runa Flow, Runa Query IR, or
the RunaDB Wire Protocol.

The remainder of this ADR is the historical record of the accepted proposal.
Reviving any part of the design requires a new ADR that redefines its
contracts, recovery, observability, compatibility, and tests. No code was
implemented against this design.

## Context

ADR-0020 permanently froze and deprecated the embedding and RAG (vector
retrieval) primitives and named **MEMO (Memory as a Model)** as the future
replacement. ADR-0016 requires AI capabilities to run with verifiable
boundaries, and ADR-0018 requires any learned representation to remain a
derived form governed by the World Continuum, never a silent replacement for
Observation Evidence.

The design in this ADR is based on *MeMo: Memory as a Model*
(Quek, Lee, Leong, Verma et al., arXiv:2605.15156v2, 2026). It addresses the
knowledge integration problem: a frozen model cannot recall knowledge that is
not in its parameters or context, while retraining is expensive, RAG is
sensitive to retrieval noise and weak at cross-document reasoning, and latent
memory methods are coupled to a specific model family. RunaDB adopts the
architecture, not the paper's training recipes or benchmark results as its
own.

MEMO's scope is deliberately narrow. It covers a **declared knowledge domain**
whose scope is stable but whose content updates frequently. The source
artifacts of that domain — business state, technical documentation, and other
works — remain in RunaDB's World Continuum as the factual anchor. Live,
queryable facts are answered from RunaDB through validated Runa Query IR, never
from the Memory model; the Memory model is a derived, versioned projection over
that domain. MEMO is not a distillation of the whole World Continuum, and it is
not an Agent's operational memory or a path to maintenance actions.

## Decision

This ADR recorded **MEMO** as RunaDB's proposed memory capability: knowledge
encoded into a dedicated, compact **Memory model**, with a reasoning model
retrieving from it through a structured query protocol. MEMO was proposed to
replace the frozen embedding and RAG primitives of ADR-0020 as the retrieval
and memory capability. The design is frozen (see Status) and is not an active
target.

### Roles

| Role | Contract |
| --- | --- |
| Generator model | An external LLM used offline to distill a target corpus into a reflection QA dataset. It may be smaller than the Executive model. |
| Memory model | A compact model trained on the reflection QA dataset to answer questions from its parameters alone. It is the retrievable memory artifact. |
| Executive model | A frozen reasoning model that answers user queries by querying the Memory model. It is treated as a black box; RunaDB never accesses its weights, gradients, or output logits. |

The core insight is the **reflection**: a self-contained, corpus-derived
question–answer pair whose construction needs no knowledge of future queries,
yet serves as the interface through which any query can reach corpus knowledge
without observing the corpus directly. A memory artifact must expose its
Representation Chart, model/provenance metadata, WAL and recovery format,
resource limits, and protocol version before it becomes a public query
capability.

### Training Phase

**Reflection synthesis.** A Generator model transforms the target corpus into a
reflection QA dataset through five steps:

1. **Fact extraction.** Each document is chunked; the Generator produces both
   direct facts (explicit statements) and indirect facts (inferred or
   synthesized information) per chunk.
2. **Consolidation.** QA pairs sharing a common underlying context (entity,
   time period, or relationship type) are merged into pairs that require
   integrating multiple facts.
3. **Verification and rewriting.** Each pair is checked for self-containment
   (understandable and answerable in isolation); ambiguous pairs are rewritten
   against the source chunk or discarded.
4. **Entity surfacing.** Entity-centric pairs encode an entity's attributes and
   relationships in the question and reveal its identity in the answer,
   mitigating the reversal curse and supporting later entity identification.
5. **Cross-document synthesis.** Within topically related document groups, the
   Generator identifies converging clues (complementary facts about one
   entity) and parallel properties (shared attributes across entities) to
   produce pairs with support across multiple documents.

No document identifiers or watermarks are embedded in the generated pairs, so
the Memory model cannot exploit shortcut signals.

**Memory model training.** The Memory model is initialized from a small
pretrained model, substantially smaller than the Executive model, and trained
by supervised fine-tuning with next-token prediction over answer tokens only.
It is conditioned only on the question and preceding answer tokens, never on
source documents, forcing parametric internalization rather than copying from
retrieved context.

**Continual integration.** New corpora are integrated incrementally by
training a Memory model per corpus from the same base and merging their task
vectors (`τ_i = φ_i − φ_0`) into one model, avoiding retraining on the union
of all observed corpora.

### Inference Phase

At inference, the Executive model retrieves from the Memory model through a
structured multi-turn protocol with three sequential stages, each with its own
prompts, sampling temperature, and interaction budget:

1. **Grounding.** The Executive model decomposes the query into atomic,
   clue-probing sub-questions; the Memory model answers each independently.
2. **Entity identification.** Using the grounding responses, the Executive
   model iteratively narrows candidate entities until it converges on one or
   the stage budget is exhausted.
3. **Answer seeking and synthesis.** Conditioned on the identified entity, the
   Executive model requests supporting facts and synthesizes the accumulated
   responses into a final answer.

Memory model responses are compact natural-language snippets whose length is
independent of corpus size, so retrieval cost is constant regardless of the
corpus. Because every interaction occurs through the input–output interface,
MEMO is plug-and-play with any Executive model, including closed-source models.

### World Continuum Binding

The Memory model is a learned **State Field** over a latent coordinate domain.
The reflection QA dataset and the trained model are derived representations
governed by a **Representation Chart** that declares the training corpus,
Generator model lineage, coverage, uncertainty, and compatibility rules.
Observation Evidence remains the factual anchor; reflections and memory model
outputs are attributed derivations and must never silently replace it.
Retrieval is an AI-Assisted Execution path subject to the same authorization,
resource, transaction, and validation boundaries as direct Runa Flow requests.

RunaDB Server does not host a heavy managed runtime on the critical path. The
Generator and Executive models are external components; RunaDB owns and
governs the corpus, the reflection dataset, and the versioned memory artifact,
and exposes the validated retrieval boundary. Model execution, training, and
inference may run out of process or through an external service behind that
boundary.

### Declared Knowledge Domain, Refresh, And Fallback

A memory artifact is bound to a declared **knowledge domain**: a versioned
subset of World Continuum state whose *scope is stable* but whose *content
updates frequently*. Business state, technical documentation, and other works
remain in RunaDB as the factual anchor. The Reflection dataset and Memory model
are derived projections over that domain, never a distillation of the entire
World Continuum and never a replacement for it.

The Representation Chart declares the domain as a set of **source bindings**
(stable references to the Continuum Objects, Observation Evidence, and payload
artifacts that feed the domain), the freshness interval the artifact claims,
and its update semantics. Retrieval is **query-first**: whenever a request can
be answered by validated Runa Query IR over live World Continuum state, that
path is authoritative and is used. The Memory model answers only requests that
target its declared domain and that the live path cannot satisfy within the
declared freshness and cost bounds.

Content updates drive a **refresh contract**, not a one-shot training run. On a
declared source change, the artifact is invalidated and re-projected: either a
full rebuild or an incremental integration within the declared cost limit. An
artifact version carries its snapshot time and coverage window; a request whose
freshness requirement exceeds the artifact's snapshot falls back to the live
Runa Query IR path. Artifacts are versioned and retained under the declared
retention policy; incompatible charts are rejected explicitly, and a stale
artifact never presents itself as current factual state.

## Non-Goals

- Running model training or inference inside the single-writer commit path.
- A retrieval index, vector index, or embedding store; ADR-0020's embedding
  and RAG primitives remain permanently frozen.
- Replacing Observation Evidence with memory model output, or treating
  reflections as facts.
- Replacing validated live queries over World Continuum state. A request
  answerable from live, sufficiently fresh World Continuum state is served
  from RunaDB, not from the Memory model; the Memory model answers only its
  declared domain and freshness window.
- Serving as an Agent's operational memory (goals, plans, action history) or
  as a path to maintenance and write actions. Operational memory is versioned
  World Continuum state; maintenance actions are validated Requests subject to
  ordinary authorization, transaction, and audit rules.
- Committing to a specific model family, training recipe, or benchmark as a
  product guarantee. The paper's empirical results are the paper's evidence,
  not RunaDB's.
- Production support before the memory artifact's Representation Chart,
  provenance, format migration, resource limits, authorization, observability,
  and deterministic recovery contracts are published and verified.

## Consequences

- MEMO is frozen (see Status). ADR-0020's embedding and RAG primitives and
  ADR-0022's MEMO design are both historical records; neither is an active
  retrieval or memory capability.
- A memory artifact is versioned World Continuum state: its reflection
  dataset, Representation Chart, and model/provenance metadata require
  explicit recovery and migration formats before persistence.
- The retrieval protocol is a public contract: sub-query decomposition,
  entity identification, and answer synthesis must be expressed in Runa Flow /
  Runa Query IR and exercised end to end through the official RunaDB Client.
- RunaDB must not silently reinterpret a reflection or memory model output
  under a changed Representation Chart; incompatible artifacts are rejected
  explicitly.
- A memory artifact is bound to a declared knowledge domain with source
  bindings, a freshness interval, and an update semantics; those declarations
  and the query-first fallback to live World Continuum state are part of the
  artifact contract.
- Unsupported or unbounded model interactions must fail clearly; budgets,
  limits, and failure behavior are part of the retrieval contract. A stale or
  out-of-domain artifact never presents itself as current factual state.

## Delivery

None. MEMO is frozen (see Status) and not scheduled for implementation. The
numbered steps below are retained as the historical record of what the
proposal required before it could become a public capability:

1. Define the versioned reflection dataset and memory artifact formats, their
   Representation Chart, provenance, recovery, and migration behavior, together
   with the declared knowledge-domain source bindings, freshness interval,
   refresh trigger, and retention policy.
2. Specify the retrieval boundary as Runa Flow / Runa Query IR forms and the
   matching RunaDB Wire Protocol negotiation, with explicit rejection of
   incompatible charts and unvalidated model output, and with the query-first
   fallback that routes a request to live World Continuum state whenever that
   path can satisfy it within the declared freshness and cost bounds.
3. Implement one out-of-process or external-model retrieval vertical slice
   with deterministic tests and official RunaDB Client round trips, including
   refresh invalidation, snapshot and coverage declaration, fallback routing,
   and version retention behavior.
4. Add continual-integration (model merging) and observability contracts only
   after the base retrieval slice is verified.
5. Publish a support entry only after recovery, authorization, resource
   limits, and end-to-end evidence are in place.
