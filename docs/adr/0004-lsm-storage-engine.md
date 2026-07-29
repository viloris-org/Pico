# Use an LSM-Style Write-Optimized Structure for Primary Storage

The primary persistence path for user table data uses an **LSM-style** structure (memtable → flushed sorted files → leveled compaction). The write path is primarily append-oriented rather than based on in-place B-Tree page updates.

The relational model remains the user-facing model (tables, rows, primary keys, and secondary indexes); LSM is the physical organization for tables and indexes.

## Considered Options

- **In-place B-Tree (the classic SQLite/PostgreSQL path)**: Friendly to point reads, but hot-page locks and random writes can deteriorate under high-contention workloads.
- **WAL + memory only (replay on restart)**: Simple to implement, but cannot support datasets larger than memory with an acceptable startup time.
- **LSM / write-optimized structure (adopted)**: Sequential writes and appended versions better support good write performance without collapsing under contention; block caches, Bloom filters, and similar techniques offset read amplification.
- **Hybrid structures such as Bε-trees**: More controllable read amplification, but heavier implementation and paper-specific details; retained as an evolution option if LSM proves insufficient.

## Consequences

- Observability for compaction, read amplification, and space amplification must be designed from day one, not treated as a later optimization.
- Secondary and primary indexes are independent LSM structures (or equivalent ordered sets); transaction commits must keep indexes and tables consistent.
- If the physical structure changes in the future, preserve the logical boundary of “ordered set + WAL + MVCC” so the execution layer does not become coupled to file-format details.
