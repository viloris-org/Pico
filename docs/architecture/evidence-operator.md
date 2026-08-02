# Evidence Operator Contract

Status: Implemented at the engine level as a protocol v3 development capability.
The metrics, quotas, and staged-upload accounting below are enforced and counted
by RunaDB Server. Exposing them through an operator request surface is
administration-request work (roadmap Phase 7); until then they are readable
through the server's internal engine API and are not a RunaDB Wire Protocol
value.

## Scope

ADR-0019 requires an operator contract before a production support claim for
Observation Evidence: instance-wide staging and retained-byte quotas, staged
upload accounting, and the listed metrics. This page records the implemented
boundaries and counters. Metrics never expose payload bytes, origin secrets, or
authorization tokens.

## Quotas

RunaDB Server enforces one staged attachment per Connection and the protocol
payload and chunk maxima at the wire boundary. On top of that per-Connection
rule, the engine enforces instance-wide limits (see `Engine.evidence_limits`):

| Limit | Default | Outcome when exceeded |
| --- | --- | --- |
| `max_concurrent_staging` | 8 | `EV1001` "staging quota exceeded" on `attachment_begin`; no evidence created |
| `max_staged_bytes` | 64 MiB | Same rejection on `attachment_begin` |
| `max_retained_bytes` | 512 MiB | `observe` rejects with `RetainedQuotaExceeded`; no evidence or WAL record created |

A staging reservation is held from `attachment_begin` until `attachment_finish`
or `attachment_abort`. A connection that drops mid-upload releases its
reservation through the connection cleanup path, so the quota cannot leak. A
rejected limit creates no visible evidence and no WAL record.

## Staged-Upload Accounting

`Engine.beginStage`, `finishStage`, and `abortStage` are the engine boundaries
for one attachment's lifetime. Their counters are:

- staged upload count and bytes: uploads begun instance-wide;
- aborted uploads: reservations released without a finished upload;
- staging rejections: quota-limited begins.

## Metrics

`Engine.evidenceStats()` returns `EvidenceStats`, which records:

- staged upload count and bytes;
- accepted (committed) evidence count, plus a per-modality breakdown;
- rejected evidence count, plus a per-reason breakdown (`PayloadTooLarge`,
  `InvalidMetadata`, `RetainedQuota`, `CorruptPayload`, `StorageFailure`);
- payload write and synchronization latency: total nanoseconds and a count;
- committed payload count and bytes;
- orphan count and bytes found or reclaimed during recovery;
- missing, corrupt, or unsupported payload file failures at read time.

A corrupt committed payload still rejects startup (see
[WAL and crash recovery](wal-and-recovery.md)); the read-time failure counter
tracks failures observed while serving `read_evidence_payload`.

## Verification

Deterministic engine tests cover the staging concurrency quota, the staged-byte
budget, the retained-byte quota with no visible evidence, the full upload
lifecycle accounting, oversized-payload rejection accounting, and the
corrupt-payload read failure counter. Regression location:
`src/storage/engine.zig` (evidence operator tests).
