# Engineering Runtime Rules

This reference owns recurring implementation constraints for concurrency,
resource bounds, allocation, and observability.

## Concurrency And Resources

- Give each shared mutation one owner and one publication point.
- Lock acquisition order is Connection -> transaction state -> commit queue.
  A new coexisting lock must document its place in that order.
- Bound commit, network-output, compaction, and other producer-consumer queues;
  define their full-queue error or backpressure behavior.
- A slow Connection must not unboundedly buffer output or indefinitely block
  unrelated Connections. Reads use snapshots and do not observe partial writes.
- Compaction may prepare output concurrently, but publishes only through the
  manifest/commit owner path.
- A static page cache is a fixed budget. Exhaustion returns an explicit error,
  such as `CacheFull`; it must not allocate unboundedly.
- An allocating Zig function accepts its `std.mem.Allocator` explicitly,
  documents retained or returned ownership, and releases owned allocations on
  every path with `defer` or `errdefer`. Allocation tests use
  `std.testing.allocator`.

## Observability

Introduce metrics or logs with their paths for write latency, WAL sync latency,
commit-queue depth and batch size, recovery duration and replay count,
durability level, WAL size, checkpoint progress, compaction backlog, and
recovery-rejection reasons.

