# WAL and Crash Recovery

> **Key files:** `src/storage/wal.zig` (WAL format and I/O), `src/storage/engine.zig` (recovery scheduling and application)

## Overview

The WAL (Write-Ahead Log) is Pico's source of truth for crash recovery. **WAL before
MemTable** is an invariant: every write must be fully persisted to WAL before it is applied
to memory state. Recovery replays confirmed writes from WAL to rebuild the in-memory tables.

At the default durability level, the complete commit record is synced to WAL before a
successful `COMMIT` response. Lower durability levels are available for development or
explicitly accepted risk (see ADR-0006).

## Design Goals

- **Crash consistency**: confirmed commits are not lost; only incomplete tail writes are discarded.
- **Versioned format**: the file identifies itself with `magic + version`, so frames from different formats are not misinterpreted.
- **CRC validation**: each frame covers its payload and length field with CRC32 to detect silent corruption.
- **Atomic batch commit**: all operations in an explicit transaction form one WAL frame and are either all applied or all discarded during recovery.
- **Sequential single-file append**: the current implementation uses one WAL file and append-only writes; it does not perform random writes.

## WAL File Format

### File Header

```
Offset  Size  Field
──────────────────────────────
0       7     Magic: "PICO_WAL"
7       4     Format version: u32 LE
──────────────────────────────
        11    Total header size = file_header_len
```

- `PICO_WAL` identifies a Pico WAL file quickly.
- `format_version` is currently **1**. Breaking changes to frame layout, record-type encoding, or checksum algorithm increment it.
- Open validates magic + version; mismatch returns `error.UnsupportedWalFormat` and preserves the file as evidence.

### Frame Layout

WAL consists of variable-length frames immediately after the file header:

```
Offset  Size  Field      Description
──────────────────────────────────────
0       4     len        Payload bytes (u32 LE)
4       4     crc32      CRC32(len_bytes ‖ payload)
8       len   payload    Record type + record data
──────────────────────────────────────
        8+len            Total frame size = frame_header_len + payload_len
```

- **CRC coverage**: `crc32c` computes the four-byte LE representation of `payload_len` concatenated with `payload`. Covering the length prevents a flipped length from being accepted as a different complete frame.
- **One positioned write**: header and payload are written in one `writeAtAll` call. A crash therefore produces either a complete frame or an incomplete tail, not a header-only intermediate state.
- **Maximum payload**: `8 MiB` (`frame_payload_len_max`) prevents a single frame from causing excessive recovery memory use.

### Record Types

| Type | Value | Description |
|------|-----:|-------------|
| `create_table` | 1 | Create a table (table name + column-definition list) |
| `insert` | 2 | Insert one row (table name + value list) |
| `update` | 3 | Update one row (table name + primary-key value + new value list) |
| `delete` | 4 | Delete one row (table name + primary-key value) |
| `add_column` | 5 | Add a column (table name + column definition) |
| `drop_column` | 6 | Drop a column (table name + column name) |
| `set_default` | 7 | Set a DEFAULT expression (table name + column name + expression) |
| `set_not_null` | 8 | Set NOT NULL (table name + column name + enable/disable) |
| `txn_batch` | 9 | Transaction batch commit: an atomic frame containing nested operations |

### Record Encoding Details

**Primitive encoding:**

| Type | Encoding |
|------|----------|
| `u16` | 2-byte LE |
| `u32` | 4-byte LE |
| `i64` | 8-byte LE |
| String | `u16(len) + len bytes` (maximum length 65535) |
| Value (null) | `0x00` |
| Value (int) | `0x01 + i64(8 bytes LE)` |
| Value (text) | `0x02 + u16(len) + len bytes` |
| Value (bool) | `0x03 + 0x00/0x01` |
| DefaultExpr | `0x00` (none) / `0x01` (now) / `0x02 + Value` (literal) |
| Column | `str(name) + u8(type_tag) + u8(flags) + DefaultExpr` |
| Column flags | `bit0: pk, bit1: not_null, bit2: unique, bit3: serial` |

**`create_table` payload encoding:**

```
type_byte: u8 = 1
str(table_name)
u16(n_columns)
repeated(n_columns):
  Column
```

**`insert` payload encoding:**

```
type_byte: u8 = 2
str(table_name)
u16(n_values)
repeated(n_values):
  Value
```

**`update` payload encoding:**

```
type_byte: u8 = 3
str(table_name)
Value(pk)  — primary-key value used to locate the row
u16(n_values)
repeated(n_values):
  Value
```

**`delete` payload encoding:**

```
type_byte: u8 = 4
str(table_name)
Value(pk)
```

**`txn_batch` payload encoding:**

```
type_byte: u8 = 9
u16(n_ops)
repeated(n_ops):
  u32(op_payload_len)
  op_payload: [type_byte + encoded_op_data]
```

Nested operations in a `txn_batch` frame may use the `insert`, `update`, and `delete`
encodings without the outer frame header. The entire batch shares one CRC: a frame is either
complete and valid or the entire batch is discarded.

## WAL Lifecycle

### Creation

1. `Engine.open()` -> `Wal.open()` opens the `wal` file in `CREATE` mode.
2. If the file is empty, write and sync the header (`magic + version`).
3. Otherwise validate the header.

### Writing

1. `Engine` calls `wal.appendInsert()`, `wal.appendUpdate()`, `wal.appendTxnBatch()`, and so on.
2. `appendPayload()` constructs header + payload and writes them at the current offset with one `writeAtAll`.
3. If `sync_on_append == true` (the default durability level), immediately `fsync` to confirm persistence.

### Recovery

See the next section.

### Reclamation (Target)

- After a checkpoint advances, covered WAL portions may be reclaimed.
- In Phase 0, WAL is one unbounded file. WAL replacement/reclamation will be added with checkpoints.

## Crash Recovery

### Recovery Flow

```mermaid
flowchart TD
    A["Open data directory"] --> B["Open WAL\nand validate header"]
    B --> C{"file size > header?"}
    C -->|no| D["No WAL replay\nempty database"]
    C -->|yes| E["Scan frames\noff = file_header_len"]
    E --> F{"remaining bytes\n< frame_header_len?"}
    F -->|yes| G["Truncate tail\npersistEnd()"]
    F -->|no| H["Read frame header\n(payload_len + crc32)"]
    H --> I{"payload_len == 0\nor > max or\nframe past file?"}
    I -->|yes| J["Truncate tail\npersistEnd()"]
    I -->|no| K["Read payload\nvalidate CRC32"]
    K --> L{"CRC matches?"}
    L -->|no| M["Return CorruptWal\npreserve evidence"]
    L -->|yes| N["Parse RecordView\napply(ctx, view)"]
    N --> O["off += frame_len\ncontinue"]
    O --> E
    J --> P["Recovery complete"]
    D --> P
    G --> P
    M --> Q["Reject recovery"]
```

### Recovery Invariants

1. **Confirmed commits are not lost**: every complete, validated frame represents a confirmed operation and must be replayed exactly.
2. **Unknown or corrupt frames reject recovery**: CRC failure, an unknown record type, or an unparseable format returns `error.CorruptWal`; recovery does not guess at a repair.
3. **Incomplete tails are tolerated**: an incomplete final frame (missing header or payload) is silently truncated while the confirmed prefix remains intact.
4. **Truncation is persisted**: `persistEnd()` (`fsync`) persists the new EOF so later appends do not encounter the garbage tail.

### Why CRC Matters

Pico's WAL CRC covers both `payload_len` and `payload`. A payload-only CRC would allow damage,
or an attacker, to change the length and reinterpret a valid payload as a different record size
or type. Covering the length detects this corruption immediately.

### Recovery Modes

| Mode (planned) | Behavior | Use case |
|-----------------|----------|----------|
| Strict (default) | Stop at the first corrupt frame and reject recovery | Production, integrity first |
| Tolerate truncation | Truncate an incomplete final frame (current behavior) | Standard crash recovery |
| Skip corruption | Skip corrupt frames and continue | Emergency data salvage |

The current implementation tolerates truncation; strict mode will be added as an option.

### `txn_batch` Recovery

An explicit transaction's write set is stored in a `txn_batch` frame:

- `replayWal` reads the frame; `applyRecord()` identifies `txn_batch`; `forEachTxnBatchOp()` iterates its nested operations.
- The entire batch is applied only when the frame is complete and its CRC is valid; a corrupt or truncated frame is discarded in full.
- This preserves transaction atomicity: recovery cannot expose a partially committed transaction.

### Failure Model

| Failure | Recovery behavior | Guarantee |
|---------|-------------------|-----------|
| Process crashes during WAL write | Truncate the tail and discard the incomplete frame | Complete confirmed frames are not lost |
| Crash during WAL `fsync` | Same | Same |
| WAL header corruption | `UnsupportedWalFormat`, reject recovery | No guessed repair |
| CRC corruption in the middle of WAL | `CorruptWal`, preserve evidence | Recovery rejected |
| Silent filesystem corruption (bit flip) | CRC detects it -> `CorruptWal` | Recovery rejected |
| Complete frame length flips | CRC detects it -> `CorruptWal` | Recovery rejected |

## Current Implementation vs Target

| Feature | Current (Phase 0) | Target |
|------|----------------|------|
| File layout | Single WAL file | WAL replacement/rotation + checkpoints |
| Group Commit | One frame per `appendPayload` + optional sync | Bounded queue + batched writes + shared `fsync` |
| Recovery modes | Tolerate truncation (implicit) | Strict + tolerant + skip-corruption (configurable) |
| CRC algorithm | CRC32 | Upgradeable to CRC32C |
| WAL compression | None | Optional compression (zstd) |
| WAL tracking | None | Manifest records size and position of closed WALs |
| WAL checksum chain | None | Each new WAL record includes the previous WAL checksum |

## References

- RocksDB [Write-Ahead Log](https://github.com/facebook/rocksdb/blob/main/docs/components/write_flow/03_wal.md): 32 KB blocks, fragmentation, CRC optimization, and WAL reclamation.
- RocksDB [Crash Recovery](https://github.com/facebook/rocksdb/blob/main/docs/components/write_flow/09_crash_recovery.md): recovery flow, WAL recovery modes, and truncation.
- [ADR-0006 WAL durability defaults](../adr/0006-wal-durability-defaults.md): sync policy and durability-level selection.
- [Write path and WriteBatch](write-path.md): `txn_batch` and write-set commit path.
- [VFS design](vfs.md): data-directory fencing and positioned I/O, the lower-level abstraction used by WAL.
