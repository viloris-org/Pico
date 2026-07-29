# Implementation Language: Zig

The Pico server and storage engine are implemented in **Zig** and delivered as a single static (or minimally dependent) binary. This provides control over memory, I/O, and startup, matching the goals of a lightweight product with a self-managed runtime.

## Considered Options

- **Rust**: Strong ecosystem and safety model, but this project has already selected the Zig toolchain and style preferences.
- **C/C++**: Sufficient control, with greater historical baggage and build complexity.
- **Zig (adopted)**: Explicit allocation, cross-compilation, and suitability for building storage and network runtimes from scratch; the cost of a younger ecosystem is addressed with in-house tests and fault injection.

## Consequences

- Avoid heavy managed runtimes on critical paths; integrate required C libraries through explicit FFI.
- Correctness relies more on deterministic tests, fault injection, and fuzzing than on “the language guarantees everything.”
- The external driver ecosystem is not tied to Zig: clients can use the PostgreSQL protocol.
