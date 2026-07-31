# Engineering Change Protocols

This reference defines the work required for public and persistent contract
changes. Read it from [the build loop](../BUILDING.md) when the change touches
one of these surfaces.

## Runa Flow And Runa Query IR

For a new Runa Flow capability, specify source syntax, canonical IR, and the
semantic boundary; define parse, binding, type, unsupported, and malformed-IR
rejection; then implement validation, execution, and transaction behavior
together. No stage may report success while omitting effects. Add source, IR,
execution, rejection, recovery, and official RunaDB Client evidence where
applicable. Update `docs/runa-flow.md` only after verification. Changes
affecting catalog, indexes, constraints, visibility, or commit are persistence
changes too.

## RunaDB Wire Protocol

1. Change shared definitions only under `clint/proto/`.
2. Define old-peer compatibility, negotiation, or a stable rejection result.
3. Bound every frame, string, collection, and streamed result. Malformed or
   oversized input fails the responsible Connection without unbounded
   allocation or shared-state corruption.
4. Map errors at the network boundary; do not serialize server internals.
5. Test codecs, negotiation, malformed frames, server behavior, and an
   official RunaDB Client end-to-end path.

## SDKs

State the language, public package entry point, supported protocol and Server
versions, and compatibility command before implementation. Build shared
definitions and bounded framing first; then negotiation, Connection lifecycle,
and protocol errors; then public behavior the Server already supports; and
only then transactions whose begin, commit, rollback, errors, and
Connection-close behavior match Server semantics. Cover success, rejection,
malformed peer data, version mismatch, and Connection close against a launched
Server. Publish compatibility only after verification.

## Persistent State

Treat WAL, catalog, manifests, checkpoint metadata, and immutable tables as
recovery protocols. Before altering one, record:

```text
FORMAT CHANGE
  owner:          <wal / catalog / lsm / vfs>
  format version: <old -> new>
  writer behavior:<new bytes emitted>
  reader behavior:<old/new/unknown handling>
  recovery rule:  <validated prefix and rejection behavior>
  migration:      <none / explicit migration / explicit refusal>
  tests:          <encoding, corruption, truncation, restart>
```

- Validate lengths, version tags, boundaries, and checksums before bytes become
  state.
- Complete, synchronize when required, and validate an immutable artifact
  before atomically publishing a manifest or checkpoint that references it.
- Do not reclaim a file still visible to a snapshot.
- Recover to a verified prefix only where the WAL contract permits a truncated
  tail. Do not scan forward after a complete-record failure.
- Preserve diagnostic evidence when startup rejects a data directory.
- A checkpoint advances persistence and WAL reclamation; it is not backup.
