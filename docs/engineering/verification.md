# Engineering Verification And Handoff

This reference defines evidence, status, documentation maintenance, and review
for the RunaDB build loop.

## Task Record

For nontrivial work, record this in the task or PR before production code:

```text
IMPLEMENTATION PLAN
  surface:       Runa Flow/IR | RunaDB Wire Protocol | server internal | RunaDB Client | RunaDB SDK
  user result:   <new behavior or explicit rejection>
  owner:         <module that owns new mutable state>
  invariants:    <success, failure, crash, contention behavior>
  dependencies:  <completed work, protocol version, format version, ADR; or none>
  evidence:      <tests, recovery cases, integration cases, benchmark>
  status:        Draft | Implemented | Verified | Blocked
```

Use `Connection`, transaction, snapshot, commit, durability level, WAL,
checkpoint, recovery, and contention precisely. Do not call a Connection a
Session where it can be confused with transaction state, or a checkpoint a
backup.

## Minimum Evidence

| Change class | Required evidence before `Verified` |
| --- | --- |
| Utility or data structure | Deterministic normal, error, and relevant resource-limit tests |
| Runa Flow/IR | Source parser, IR validation, binding/execution, rejection, stable error mapping, language reference |
| Wire Protocol | Codec, negotiation, malformed frame, server behavior, Client end-to-end |
| Client or SDK | Public lifecycle/result/error tests and Server compatibility suite over the protocol |
| Transaction or contention | Commit/rollback, failed state, visibility, conflict, cancellation, bounded queue as applicable |
| VFS, WAL, catalog, checkpoint, manifest, LSM | Format/version, corruption, I/O failure, truncated tail, restart recovery |
| Successful `COMMIT` path | WAL-first, durability, single-writer publication, interruption and confirmed-prefix restart |
| Compaction or reclamation | Snapshot visibility, manifest publication, validation, delayed reclamation, recovery under reads/writes |
| Performance or limit | Reproducible command, workload, optimization, machine context, durability level, recorded baseline |

Run focused tests during development. For every code change, also run:

```bash
zig build
zig build test
```

Benchmarks, a successful startup, or a Connection do not establish correctness.
Error tests assert the precise error and required post-error state; do not use
test-only success stubs, meaningless assertions, or `catch unreachable` in
place of expected-failure checks.

## Status And Handoff

| Status | Meaning | Supported? |
| --- | --- | --- |
| `Draft` | Incomplete or undecided interface, experiment, or test skeleton | No |
| `Implemented` | Expected path works locally but evidence is incomplete | No |
| `Verified` | Behavior and required failure evidence satisfy this reference | Yes, after public docs update |
| `Blocked` | Named dependency, decision, or external condition prevents progress | No |

Every material change ends with:

```text
IMPLEMENTATION STATUS
  surface:      <Runa Flow/IR / RunaDB Wire Protocol / internal / RunaDB Client / RunaDB SDK>
  state:        Draft | Implemented | Verified | Blocked
  owner:        <module that owns the state>
  evidence:     <test files and commands actually run>
  recovery:     n/a | <fault-injection and restart cases>
  observability:<metrics or logs changed; n/a if none>
  follow-ups:   <remaining TODO markers; none if empty>
```

## Documentation And Review

Update the owning reference with a behavior change: Flow/IR support updates
`docs/runa-flow.md`; Wire Protocol updates `clint/proto/`, compatibility
documentation, and examples; SDK work updates package documentation,
compatibility matrix, examples, and integration instructions; product language
or boundaries update `CONTEXT.md`, products documentation, and ADRs; storage or
recovery contracts update architecture references; build/CLI/benchmark changes
update README material and command help.

Before marking work `Verified`, confirm ADR and terminology compliance, module
ownership and dependency direction, public-boundary integrity, relevant error
and resource behaviors, WAL-first durable visibility, recovery distinction
between truncated tails and corruption, documentation status accuracy, actual
full-build results, and bounded TODO/PERF closure conditions.
