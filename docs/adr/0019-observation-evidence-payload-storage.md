# Observation Evidence Payload Storage

## Status

Accepted. This ADR defines the first persistent multimodal slice of the World
Continuum. Acceptance authorizes implementation; support still requires the
verification and public documentation in the Delivery section.

## Implementation Status

Implemented and tested as a protocol v2 development capability. The verified
slice includes immutable evidence ingestion through the official Zig RunaDB
Client, metadata inspection, bounded payload retrieval, checkpoint retention,
restart recovery, orphan reclamation, and startup rejection for corrupt
committed payloads. The Non-Goals remain unsupported.

The engine records committed payload count and bytes plus recovery orphan count
and bytes. Rejection counters and latency histograms are not yet exposed through
an operator surface; they remain required before a production support claim.

```text
FORMAT CHANGE
  owner:          wal
  format version: 2 -> 3
  writer behavior: emits observe metadata and payload references
  reader behavior: replays versions 1-3; older readers reject version 3
  recovery rule:  validates each committed payload before visibility
  migration:      explicit refusal by older binaries; no rewrite required here
  tests:          WAL decode, checkpoint, restart, corruption, Client round trip

FORMAT CHANGE
  owner:          payload store
  format version: none -> 1
  writer behavior: writes immutable envelope, BLAKE3-256 digest, and CRC32
  reader behavior: rejects unknown versions, algorithms, lengths, or trailing bytes
  recovery rule:  missing or corrupt committed payload rejects startup
  migration:      none from the pre-evidence baseline
  tests:          round trip, digest mismatch, orphan cleanup, restart, corruption
```

## Context

ADR-0018 makes Observation Evidence the factual anchor for multimodal data and
rejects independent file, vector, and model-inference stores. RunaDB therefore
needs to own multimodal payloads through the same catalog, authorization,
transaction, durability, recovery, provenance, and query contracts as other
World Continuum state.

Storing every payload inline in a row or WAL record would make large images,
audio, video, and sensor captures amplify WAL rewrites, checkpoints, and LSM
compaction. Treating a file path or object-store URL as the value would instead
move durability and recovery outside RunaDB Server. The first implementation
needs a bounded native payload format without claiming media interpretation,
embedding, similarity search, or model execution.

ADR-0018 requires a read-only Continuum inspection slice before factual writes.
This design therefore follows, and does not bypass, the Runa Query IR and
RunaDB Wire Protocol work required by ADR-0018 delivery steps 1 and 2.

## Decision

### Logical Contract

The first writable multimodal form is immutable **Observation Evidence**. Each
accepted item contains:

| Field | Contract |
| --- | --- |
| `evidence_id` | Server-assigned stable identity; never derived solely from payload bytes. |
| `object_id` | Continuum Object to which the evidence is bound. |
| `modality` | Declared `text`, `image`, `audio`, `video`, `sensor`, or `other`. |
| `media_type` | Required normalized IANA media type. The server does not infer it from bytes. |
| `observed_at` | Required observation time with an explicit UTC offset. |
| `origin` | Required attributed source identity or source reference. |
| `owner` | Authorization principal that owns the evidence. |
| `payload` | Immutable byte sequence stored by RunaDB Server. |
| `payload_length` | Validated byte length. |
| `payload_digest` | Versioned BLAKE3-256 digest used for corruption detection, not authenticity. |

`modality`, `media_type`, and origin are declarations, not proof that the bytes
have a particular meaning. RunaDB Server rejects missing or malformed metadata
but does not guess metadata, transcode media, extract features, or generate an
embedding during ingestion.

Observation Evidence is append-only in this slice. Updating payload bytes or
metadata under an existing `evidence_id` is rejected. User deletion, retention,
legal hold, and redaction remain unsupported until a focused lifecycle ADR
defines their authorization, snapshot, recovery, and reclamation behavior.

### Physical Ownership

Payload bytes live in versioned immutable payload files under the instance's
Data Directory. Catalog and LSM records contain the logical metadata plus a
versioned payload reference; they do not contain an external filesystem path
or URL. The payload reference is an internal format and is never a public
RunaDB Wire Protocol value.

Payload files use this validated envelope:

```text
magic | format_version | evidence_id | payload_length | digest_algorithm |
payload_digest | payload_bytes | frame_checksum
```

The initial payload format version is `1`; the digest algorithm is explicitly
tagged as BLAKE3-256. The frame checksum protects envelope parsing, while the
payload digest validates the complete payload. Neither is an authentication or
privacy guarantee. Unknown versions, algorithms, invalid lengths, checksum
failures, digest mismatches, and trailing bytes reject the file.

Protocol v2 enforces one staged attachment per Connection, a payload maximum of
8,388,608 bytes, and a chunk maximum of 262,144 bytes. Instance-wide concurrent
staging and retained-byte quotas are not implemented; they must be specified in
the operator contract before a production support claim. Limit failures do not
create visible evidence.

### Ingestion And Commit

RunaDB Wire Protocol v2 carries bounded attachment frames
associated with one validated Runa Query IR `observe` request. The protocol
defines begin, chunk, finish, abort, and Connection-close behavior. It does not
yet define a resumable upload or a protocol timeout.
Chunks are transport framing only; they are not independently visible values.
The official RunaDB Client must exercise the same path used by other clients.

Protocol v2 stages at most one bounded attachment in Connection-owned memory;
the stage is not a durable or resumable upload. Before the single-writer commit
point, RunaDB Server validates the declared length and digest, writes the
complete immutable payload file in the Data Directory, synchronizes it at the
active durability level, atomically publishes its final internal name, and
synchronizes the containing directory when required by the platform contract.
It then appends the transaction's WAL evidence, including the logical metadata
and payload reference. At the default durability level, it synchronizes the WAL
before publishing the Observation Evidence to readers. A future disk-backed or
resumable stage requires a protocol and resource-accounting revision.

The ordering is:

```text
stage and validate payload
-> synchronize immutable payload file
-> publish payload file name
-> append and synchronize transaction WAL
-> publish logical evidence to MVCC readers
```

A transaction may bind several completed staged attachments. All corresponding
logical evidence records commit atomically in one WAL transaction batch. A
payload file published before a failed or uncommitted WAL append is an orphan,
not visible evidence.

### Recovery And Reclamation

Recovery first validates committed WAL records and their payload references.
Every referenced payload file must exist and pass envelope, length, checksum,
and digest validation before the corresponding evidence becomes visible. A
missing or corrupt referenced payload rejects startup and preserves diagnostic
evidence; recovery must not silently drop the evidence or substitute an empty
value.

Uncommitted staging files and final payload files not referenced by any
committed logical record may be reclaimed only after recovery establishes the
committed reference set. Cleanup is idempotent and records counts and bytes.
It must not remove a file still reachable from an MVCC snapshot, checkpoint,
or supported migration. A checkpoint may compact metadata and establish a WAL
reclamation point, but it is not a user backup and does not independently
authorize payload deletion.

The persistent-format implementation must record the format change required by
`docs/engineering/change-protocols.md`. Tests must cover encoding, unknown
versions, oversized lengths, truncation at every boundary, checksum and digest
corruption, failed file and directory synchronization, failed WAL append and
synchronization, crash at every commit boundary, orphan cleanup, restart, and
checkpoint interaction.

### Reads And Observability

Runa Query IR may inspect evidence metadata without loading payload bytes. A
separate bounded payload projection streams bytes and reports the declared
length and digest. Query planning and result framing must not allocate the full
payload unless the declared resource contract permits it.

RunaDB Server exposes at least these metrics:

- staged upload count and bytes;
- accepted and rejected evidence count by modality and reason;
- payload write and synchronization latency;
- committed payload count and bytes;
- orphan count and bytes found or reclaimed during recovery;
- missing, corrupt, or unsupported payload file failures.

Metrics must not expose payload bytes, origin secrets, or authorization tokens.

## Non-Goals

- Vector embeddings, similarity indexes, multimodal predicates, feature
  extraction, transcoding, previews, or model inference.
- External object-store references as a substitute for RunaDB durability.
- Deduplication or using the payload digest as logical identity.
- Compression, encryption, authenticity, privacy, retention, deletion,
  redaction, backup, or point-in-time recovery guarantees.
- Causal Dynamics, Counterfactual Branches, Representation Chart lifecycle, or
  distributed payload placement.

Each item requires its own contract and evidence before it is supported.

## Consequences

- Native multimodal storage means RunaDB Server transactionally owns both the
  typed evidence metadata and payload durability; it does not mean that the
  server understands or embeds every media format.
- Large payloads avoid WAL and LSM rewrite amplification, at the cost of a
  second immutable persistent format and explicit orphan reclamation.
- The first slice is useful for factual ingestion and retrieval but deliberately
  excludes derived representations and semantic search.
- Protocol, catalog, WAL, checkpoint, payload-file, recovery, authorization,
  resource-limit, and official-client changes must land as one verified
  vertical capability before documentation calls it supported.

## Delivery

1. Complete ADR-0018's read-only Continuum Object and Observation Evidence
   inspection IR, protocol negotiation, rejection behavior, and official
   RunaDB Client round trips.
2. Specify the versioned evidence catalog record, payload reference, payload
   file envelope, WAL record, error codes, limits, and attachment frames.
3. Implement staging and immutable payload persistence behind an internal API,
   with format, corruption, interruption, recovery, and orphan tests.
4. Implement the validated Runa Query IR `observe` mutation through the
   single-writer commit path and add official RunaDB Client end-to-end recovery
   tests.
5. Add bounded metadata and payload reads, metrics, operator documentation, and
   the public support entry; only then mark the capability Verified.
