# Pico SQL Administrative Extensions: PICO STATUS / CONFIG / SHUTDOWN

## Status

Accepted

## Context

Pico does not target PostgreSQL compatibility (ADR-0009), so Pico SQL is free to provide a clearer, consistent administrative interface. PostgreSQL status views are fragmented, runtime configuration uses several unrelated forms, shutdown is normally a shell operation, and checkpoint/compaction operations are difficult to invoke from a client connection.

## Decision

Add **PICO-** prefixed administrative statements to Pico SQL. The first three statements are:

### `PICO STATUS`

Return a one-row standard result set with `uptime` (`INTERVAL`), `connections` (`INTEGER`), `wal_bytes` (`INTEGER`), `wal_frames` (`INTEGER`), `data_size` (`INTEGER`), `version` (`TEXT`), and `durability_level` (`TEXT`).

```picosql
PICO STATUS;
```

### `PICO CONFIG`

Read all configuration, read one setting, or change a runtime setting:

```picosql
PICO CONFIG;
PICO CONFIG durability_level;
PICO CONFIG durability_level = 'sync';
```

Configuration names use `snake_case` and match internal parameter names.

### `PICO SHUTDOWN`

Safely shut down the instance:

```picosql
PICO SHUTDOWN [mode];
```

`graceful` (the default) waits for active statements; `immediate` rolls back unfinished transactions. A checkpoint runs before shutdown.

### Protocol Behavior

All administrative statements use the existing Pico wire-protocol `query` message: the client sends `type=0x10 (query)` with SQL text, the server parses and executes it, and the server returns the standard `row_description` → `row_data*` → `command_complete` sequence or a direct `command_complete` for settings and shutdown.

Unknown statements, invalid values, and missing permissions return standard `server_error` messages; permission failures use `PERMISSION_DENIED` as defined by ADR-0014.

## Decision Drivers

1. A SQL client can administer the instance without shell access or a separate tool.
2. `PICO STATUS`, `PICO CONFIG`, and `PICO SHUTDOWN` are self-describing.
3. The syntax makes Pico’s distinction from PostgreSQL explicit.
4. Existing query messages are reused; no new handshake messages are needed.
5. The `PICO-` namespace leaves room for future administrative statements.

## Consequences

- Add `PICO` tokenization and parsing in `src/sql/parse.zig`.
- Add `Stmt.pico_stmt` (or an equivalent structure) in `src/sql/ast.zig`.
- Route execution through `src/sql/exec/pico.zig` from `src/sql/exec.zig`.
- Administrative statements do not write user data or pass through WAL. `PICO STATUS` uses the current snapshot; `PICO CONFIG` initially changes runtime state only.
- `PICO SHUTDOWN` performs the actual shutdown only after sending `command_complete`.
- `clint/zig/` requires no special handling; these statements are ordinary queries.
- Test parsing, execution, and wire-protocol round trips.

## Delivery

1. Define `PicoStmt` with `status`, `config`, and `shutdown` variants.
2. Parse the `PICO` keyword and statements.
3. Implement `src/sql/exec/pico.zig`.
4. Route `Stmt.pico_stmt` to the executor.
5. Collect status, read and write runtime configuration, and implement safe shutdown.
6. Add parser and end-to-end wire-protocol tests.
