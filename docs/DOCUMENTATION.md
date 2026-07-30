# Pico Documentation Standard

This standard applies to Markdown that describes Pico's public contracts,
operation, implementation design, or contributor workflow. It keeps technical
documentation concise, factual, and easy to scan. Material Design informs only
the use of clear hierarchy, related-content grouping, and explicit states; it
does not prescribe Pico's technical content.

## Source Of Truth

- Read `CONTEXT.md` before naming a public API, error, configuration option, or
  product concept. Use its preferred terms and respect its `_Avoid_` notes.
- Accepted product and architecture decisions live in `docs/adr/`. Do not
  reverse an ADR in prose alone; add a new ADR.
- Link to the document that owns a contract instead of copying it. In
  particular, Pico SQL support belongs in `docs/sql-subset.md`, Pico Wire
  Protocol definitions in `clint/proto/` and `docs/wire-protocol.md`, and
  architecture invariants in `docs/ARCHITECTURE.md` and its linked pages.

## Write Facts, Not Intentions

State whether a behavior is **Implemented**, **Supported and tested**,
**Draft**, **Target design**, or **Explicitly rejected**. Do not present a
planned capability as current behavior. A public support claim should identify
its version, condition, or regression location when practical.

Use Pico terminology precisely. In particular, write **Pico Server**, **Pico
Client**, **Pico Wire Protocol**, **Pico SQL**, **Connection**, **durability
level**, and **checkpoint** as defined in `CONTEXT.md`. Do not imply
PostgreSQL compatibility, cluster semantics, or that a checkpoint is a backup.

Be specific about boundaries and failures. State the triggering condition, the
observable outcome, and any safety consequence. Avoid unqualified claims such
as "safe", "fast", or "compatible".

## Structure

Use one H1 and descriptive H2 sections. Put the normal contract or procedure
before exhaustive encoding, rationale, and edge cases. Keep prerequisites,
constraints, errors, and verification close to the operation they qualify.

Choose the document shape that matches the content:

| Content | Minimum structure |
| --- | --- |
| Task or runbook | Preconditions, ordered actions, expected result, failure or recovery action |
| Reference | Status, definitions or syntax, constraints, errors, compatibility |
| Architecture | Current status, boundaries, invariants, key flows, non-goals |
| Support matrix | Capability, status, conditions or version, regression location |

Use a table only for stable comparisons or field definitions. Use a diagram
only when it clarifies a relationship that prose or a short sequence cannot;
explain its conclusion in nearby text.

## Examples And Language

Examples must be valid for the stated status, fenced with the correct language,
and complete enough to demonstrate their claimed result. Label terminal output
and wire frames as `text`. Do not use ellipses in commands a reader is expected
to run. Place the consequence of a risky option, such as a weaker durability
level, beside that option.

Write direct, compact English. Use one term for one concept, define uncommon
abbreviations at first use, and use `must` for requirements, `should` for
recommendations, and `may` for permission. User-facing Chinese material must
preserve the technical facts, commands, limits, and status of its English
counterpart.

## Change Review

When behavior changes, update the owning reference, relevant examples, and
regressions in the same change. Before merging, check that:

- Terms comply with `CONTEXT.md` and accepted ADRs.
- Commands, limits, protocol values, SQL syntax, and status claims match the
  implementation or are marked as draft or target design.
- Errors and safety implications are explicit where relevant.
- Links and code fences are correct, and the page does not duplicate another
  authoritative contract.
