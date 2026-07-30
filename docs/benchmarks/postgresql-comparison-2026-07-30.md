# Pico and PostgreSQL Baseline

Date: 2026-07-30

This is an internal baseline for product positioning. It is not a claim that
Pico is faster than PostgreSQL.

**Reporting rule for this note:** each cell is the **best single-run**
observation from the 2026-07-30 measurement series on this host (peak
cherry-pick, not median / multi-trial statistics). That is optimistic and
favors marketing copy; do not treat it as a rigorous capacity study.

## Environment

- Host: AMD Ryzen 5 5500 (6 cores / 12 threads), Linux 7.1.5-zen1-2-zen
- Storage for durable paths: NVMe btrfs (`/home`, `compress=zstd:3`)
- Pico: worktree at `c7af212` (+ local WAL worktree), Zig 0.16.0,
  `ReleaseFast`, data under `zig-cache/pico-bench` on the same NVMe volume
- PostgreSQL: 18.4, freshly `initdb`'d local cluster
- PostgreSQL data directory: `zig-cache/pg-bench-data` on NVMe (not `/tmp`)
- PostgreSQL durability: `fsync=on`, `synchronous_commit=on`,
  `full_page_writes=on`, `wal_sync_method=fdatasync`, `shared_buffers=128MB`
- PostgreSQL load generator: `pgbench`, one client, one thread, simple query
  protocol, Unix socket
- No competing workload was intentionally introduced

## Results (peak single-run)

| Workload | Pico (peak) | PostgreSQL (peak) | Positioning note |
| --- | ---: | ---: | --- |
| Autocommit `INSERT`, 50,000 ops | **140,029** ops/s, WAL sync **off** | **1,302** TPS, durable on NVMe | Not comparable: Pico is in-process and non-durable. |
| Primary-key `SELECT`, 50,000 ops | **1,308,215** ops/s | **28,360** TPS (index scan) | Not comparable: Pico bypasses network/protocol. |
| Autocommit `INSERT`, 10,000 ops | **1,785** ops/s, WAL sync **on** | **1,526** TPS, durable on NVMe | Same-host durable write signal only; still different API boundary. |
| Primary-key `SELECT`, 10,000 ops | **1,290,228** ops/s | **27,151** TPS | Pico remains in-process. |
| 10,000 individual `INSERT`s in one explicit transaction | **16,792** ops/s, WAL sync on | **33,468** ops/s, durable on NVMe | Same shape (N single-row inserts + one commit); different client path. |

Pico 50,000-operation transactional insert with WAL sync off (peak):
**3,583** ops/s. Regression signal only, not a cross-database comparison.

Observed run ranges on this host (for anyone who needs the non-peak view):

| Workload | Pico range | PostgreSQL range (NVMe) |
| --- | ---: | ---: |
| Autocommit `INSERT` 50k, WAL off | 129k–140k ops/s | 1.18k–1.30k TPS |
| PK `SELECT` 50k | 1.24M–1.31M ops/s | 27.4k–28.4k TPS |
| Autocommit `INSERT` 10k, durable | 0.88k–1.79k ops/s | 1.43k–1.53k TPS |
| Explicit txn `INSERT` 10k, durable | 16.2k–16.8k ops/s | 33.5k ops/s (one run) |

### Invalid first-pass PostgreSQL numbers (do not use)

An earlier draft reported PostgreSQL durable autocommit insert at ~28–30k TPS.
That figure is **not** a valid durable-disk result on this host:

| Setup | Autocommit insert ~TPS | Why |
| --- | ---: | --- |
| Cluster data on `/tmp` (tmpfs), `fsync=on` | ~30,329 (10k txns) | `fsync` hits RAM, not NVMe |
| Cluster data on NVMe btrfs, `fsync=on` | ~1.2–1.5k | Real durable commit path |

`/tmp` on this machine is tmpfs. Do not put marketing durable-write claims on
tmpfs numbers.

A second trap: scripting PK lookup as
`WHERE id = (random() * 49999 + 1)::int` forces a **sequential scan**
(~459 TPS here). Use pgbench variables so the planner sees a constant parameter:

```sql
\set id random(1, 50000)
SELECT name FROM bench_items WHERE id = :id;
```

## Method

### Pico

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/zig-cache-global" \
  zig build bench -Doptimize=ReleaseFast -- --rows 50000

ZIG_GLOBAL_CACHE_DIR="$PWD/zig-cache-global" \
  zig build bench -Doptimize=ReleaseFast -- --rows 10000 --sync-wal
```

Pico creates `bench_items (id INT PRIMARY KEY, name TEXT)`, runs an autocommit
insert loop, a primary-key select loop, then individual inserts inside one
explicit transaction. Peak cells above are the maximum over repeated runs of
these commands on 2026-07-30.

### PostgreSQL

Fresh cluster on **NVMe** (example):

```sh
PGDATA="$PWD/zig-cache/pg-bench-data"
PGSOCK="$PWD/zig-cache/pg-bench-run"
initdb -D "$PGDATA" --auth-local=trust -U pico
# postgresql.conf: port, unix_socket_directories=$PGSOCK,
# fsync=on, synchronous_commit=on, full_page_writes=on, listen_addresses=''
pg_ctl -D "$PGDATA" -l "$PGSOCK/pg.log" start -w
```

Logical tables:

```sql
CREATE TABLE bench_inserts (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE bench_items (id INT PRIMARY KEY, name TEXT NOT NULL);
INSERT INTO bench_items
SELECT value, 'item-' || value FROM generate_series(1, 50000) AS value;
```

Insert script:

```sql
INSERT INTO bench_inserts (name) VALUES ('item');
```

Select script (index-friendly):

```sql
\set id random(1, 50000)
SELECT name FROM bench_items WHERE id = :id;
```

```sh
export PGHOST="$PGSOCK" PGPORT=55432 PGUSER=pico PGDATABASE=postgres
pgbench -n -M simple -c 1 -j 1 -t 50000 -f insert.sql
pgbench -n -M simple -c 1 -j 1 -t 50000 -f select.sql
```

Explicit-transaction insert (10,000 single-row statements + one `COMMIT`) was
timed via `psql -f` over the same Unix socket.

## Positioning Decision

Safe external messages from the **peak** table (still disclose the caveats):

- In-process primary-key reads: **~1.3M ops/s** on this host.
- Non-durable autocommit insert path: **~140k ops/s** (SQL-path / WAL append
  signal, not a durable product claim).
- Durable autocommit insert peak on this host: Pico **~1.8k ops/s** vs
  PostgreSQL **~1.5k TPS** under the methods above — still **not** an
  apples-to-apples protocol comparison.

Do not promote Pico as a general PostgreSQL performance replacement. Pico
bypasses network and protocol in these benches; PostgreSQL includes them. Pico
also has a far smaller SQL and operational surface.

Do **not** publish the tmpfs ~30k PostgreSQL insert figure as durable
performance.

Before a public head-to-head, add a common external harness that drives both
servers through their public protocols, runs warm-up and multiple trials,
reports p50/p95/p99, pins durability and filesystem type, and separates
one-client from contention tests.
