# Concurrency Model: Single-Writer Commit Ordering + MVCC Reads

Changes are **ordered and applied** through a **single-writer** path (internal batching and queue merging are allowed); reads may run in parallel against **MVCC snapshots**, so they do not block writes by default.

The v1 isolation targets are primarily **Read Committed** and optional snapshot reads; full serializability, gap locks, and similar features are deferred.

## Considered Options

- **Coarse-grained database/table write locks (the default SQLite model)**: Simple to implement, but concurrent writes readily block one another and undermine the contention goal.
- **Fine-grained page/row-locked B-Tree (classic RDBMS)**: Mature, but expensive to implement and handle deadlocks, and mismatched with the LSM primary path.
- **shard-per-core**: Scales writes well across cores, but cross-shard transactions and the initial complexity are not worthwhile for a lightweight product.
- **Single writer + MVCC + batched commits (adopted)**: Eliminates write contention; at high QPS, group commit amortizes `fsync`. The single-writer path imposes a write ceiling, an explicit and acceptable v1 tradeoff.

## Consequences

- Tail write latency is dominated by the batching window and `fsync` policy, which must be configurable and observable.
- Single-writer is a **semantic and scheduling** constraint; it does not prohibit multiple threads from handling networking, compaction, or disk I/O. It does prohibit multiple paths from concurrently committing write sets out of order.
- If multi-core write scaling becomes a bottleneck, evaluate sharding in a separate ADR rather than adding complex fine-grained locks to the single-writer path.
