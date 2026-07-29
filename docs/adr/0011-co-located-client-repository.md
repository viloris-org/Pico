# Co-Locate Pico Client and Pico Server in One Repository

## Status

Accepted (supersedes ADR-0010 §“Separate repositories” layout decision)

## Context

ADR-0010 establishes Pico Client and Pico Server as two **independent products** with versioned Pico protocol and Pico SQL contracts, separate build artifacts, versions, and release lifecycles. This ADR **retains that product-boundary principle**.

Separate repositories nevertheless create maintenance costs:

1. **Cross-repository protocol coordination**: wire definitions, codecs, and error codes are consumed by both sides and can diverge.
2. **High integration-test barrier**: end-to-end contract tests require checking out and coordinating two repositories.
3. **Slow early iteration**: rapid product and protocol evolution makes cross-repository PR chains expensive.

## Decision

Store Pico Client source **inside the Pico Server repository** under `clint/`, while retaining these boundaries:

- **Independent artifacts**: `pico` and `pico-cli` are separate binaries with no runtime-link dependency.
- **Independent versions**: server and client may declare separate versions in the same repository.
- **Protocol contract**: both sides interact only through shared messages defined in `clint/proto/`; neither side calls the other’s internal code.
- **Independent releases**: server and client can be chosen, released, and rolled back independently.
- **Independent evolution**: the client may expand language coverage without following server release cadence.

## Decision Drivers

1. ADR-0010’s drivers remain valid: server correctness must not follow client releases, and compatibility is a protocol contract.
2. Co-location provides a single source of truth for protocol definitions and simplifies end-to-end testing.
3. The clear physical `clint/` boundary supports future SDKs such as `clint/zig/` and `clint/go/`.

## Consequences

- The independent-product principle is unchanged; only the layout changes from separate repositories to separate directories.
- ADR-0010 Delivery step 2 becomes: implement the minimum CLI in `clint/` and use it for end-to-end protocol tests.
- Future language SDKs also live in subdirectories under `clint/`.
- `clint/proto/` is the only shared source dependency.
- Server entry points under `src/` and client entry points under `clint/` must not have non-protocol cross-directory references.

## Delivery

1. Create `clint/proto/`, `clint/zig/`, and `clint/main.zig`.
2. Use the minimum CLI for end-to-end tests covering connection, one statement, transactions, and errors.
3. Remove the PostgreSQL migration adapter and its documentation/test dependencies after core Pico Client workflows are covered.
