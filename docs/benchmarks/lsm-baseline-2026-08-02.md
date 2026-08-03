# RunaDB LSM Baseline

Date: 2026-08-02

This is an internal baseline for the durable LSM slice (roadmap Phase 5). It is
not a product claim and is not compared against any other database.

**Reporting rule for this note:** each cell is a **single-run** observation
from the 2026-08-02 measurement series on this host (optimistic, not
median/multi-trial statistics). The harness is `zig build lsm-bench`; run it on
the same host to reproduce.

## Environment

- Host: AMD Ryzen 5 5500 (6 cores / 12 threads), Linux 7.1.5-zen1-2-zen
- Storage for durable paths: NVMe btrfs (`/home`, `compress=zstd:3`)
- RunaDB: worktree at `89ba624`, Zig 0.16.0,
  `ReleaseFast`, data under `zig-cache/runadb-lsm-bench` on the same NVMe volume
- Durability level: default (WAL sync on, durable commit)
- Optimization level: `ReleaseFast`
- Workload: one table `t (id int primary key, v int)`; 4 batches of 10,000
  autocommit inserts, each followed by a manual flush; then one compaction;
  then point lookups; then restart recovery. 200,000 probes per lookup phase.

## Results (single run)

| Workload | Result |
| --- | ---: |
| Autocommit `INSERT` (WAL sync on) | 1,668 inserts/s (600 µs/insert, group commit) |
| Flush to L0 per batch | 22 ms per 10,000 rows (avg) |
| Point lookup, L0, present key | 5,028 lookups/s (199 µs/lookup) |
| Point lookup, L0, absent key | 2,257 lookups/s (443 µs/lookup) |
| Compaction L0+L1 → L1 | 4 files in (100,000 entries, 4.6 MB) → 1 file out (40,000 entries, 1.8 MB); 60,000 superseded versions dropped; 161 ms; 618 k entries/s |
| Point lookup, L1, present key | 4,986 lookups/s (201 µs/lookup) |
| Restart recovery | 79 ms: 1 manifest + 1 L0...L1 SSTable loaded, 40,000 rows rebuilt, WAL tail skipped |

## Reading The Numbers

- Inserts are dominated by the durable single-writer commit round (group
  commit, WAL sync on); each insert is one committed transaction. This matches
  the write-side signal in
  [postgresql-comparison-2026-07-30](postgresql-comparison-2026-07-30.md).
- Present-key lookups on L0 and L1 cost the same: the L0 newest-file probe and
  the L1 binary-searched file both read the file's footer, index block, full-key
  Bloom filter block, and one data block. The full-key Bloom filter rejects
  absent keys before any data-block read; absent probes still pay the footer,
  filter, and index reads per file.
- A store-level pre-probe that skipped the index read entirely was measured and
  dropped: it read the filter block twice per lookup and made present-key
  lookups 1.75x slower, while the filter-inside-`find` check already skips the
  dominant data-block I/O. The planned fix for per-probe metadata reads is the
  Pager/static page cache and a table cache (`docs/architecture/lsm-storage.md`).
- Compaction shows write amplification 1.25x here because each flush
  materializes the full live row set (the table grows monotonically in this
  workload); tombstone-resolved keys are dropped during the merge.

## How To Reproduce

```bash
zig build lsm-bench -Doptimize=ReleaseFast
```
