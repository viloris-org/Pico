# Durability: WAL First, Durable Commits by Default, with Explicit Relaxation

All committed changes first enter the **WAL**; under the default **durability level**, committed transactions become visible again through **recovery** after a process crash (and under the agreed power-loss model for the platform). Less durable levels may be configured for development or explicitly accepted-risk scenarios, but a less durable level **must not** be the production default.

Use **group commit**: multiple transactions share a flush round to amortize synchronous I/O costs under high contention. Data files advance through **checkpoints**; block checksums detect silent corruption.

## Considered Options

- **Unsynchronized by default (memory/asynchronous flushes)**: Looks good in benchmarks, but a public product could easily lose committed data; unacceptable as the default.
- **Independent `fsync` per transaction**: Intuitive semantics, but `fsync` becomes the bottleneck under high contention.
- **WAL + group commit + synchronous by default (adopted)**: Provides a clear balance between “safe enough” and write throughput; durability levels leave the risk decision to the deployer.

## Consequences

- The guarantees and limitations of every level must be documented, including test scope for process termination, power loss, and `kill -9`.
- Startup **recovery** is part of functional correctness and requires fixed regression tests, not merely “it starts.”
- Backups and PITR are outside this ADR; a checkpoint must not masquerade as user-backup semantics (see `CONTEXT.md`).
