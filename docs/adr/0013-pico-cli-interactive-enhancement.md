# Pico CLI Interactive Experience Enhancement

## Status

Accepted

## Context

The current `pico-cli` (`clint/main.zig`, about 170 lines) is a minimal REPL with one mode: it reads all stdin, has no line editor, persistent history, Tab completion, multiline statements, color, or useful meta-commands beyond `\q` and `\h`. Under ADR-0009, the official CLI is the primary user entry point, so it must meet modern database-tool expectations without depending on readline or curses.

## Decision

Refactor `pico-cli` into a multi-command binary with a feature-rich interactive experience.

### 1. Interactive Line Editing

Use terminal raw mode for left/right arrows, Home/End, Backspace/Delete, Ctrl+U, Ctrl+K, and Ctrl+C. Implement it in Zig with ioctl and terminal escape sequences. Detect `isatty`; pipes and redirects retain line-oriented input.

### 2. Persistent History

Use `~/.pico_history` or `$PICO_HISTFILE`, retain 1000 entries by default, deduplicate consecutive duplicates, and preserve input casing. Up/down arrows browse history.

### 3. Tab Completion

Complete SQL keywords, table names from `PICO TABLES` or a future catalog query, and `/` meta-commands. Context-sensitive column completion is a future enhancement.

### 4. Colored Output

Enable colors by default, with `--no-color` and `\set COLOR off`. Use blue/cyan keywords, green strings, yellow numbers, bold red NULLs and errors, and bold/underlined headers. Highlight SQL while editing.

### 5. Multiline Statements

Use `;` as the terminator. Enter continues incomplete statements with `pico->`; pasted blocks end at the semicolon. Ctrl+C cancels the current input.

### 6. Meta-Commands

| Meta-command | Function |
|---|---|
| `/q` / `/quit` | Exit the CLI and send `goodbye` |
| `/h` / `/help` [topic] | Show help |
| `/set [key [value]]` | Read or set client variables |
| `/list` / `/l` | List databases |
| `/dt` | List tables |
| `/timing` | Toggle execution timing |
| `/copy` | Reserved for import/export |
| `/!` <shell> | Run a shell command |

### 7. Client Variables

| Variable | Default | Meaning |
|---|---|---|
| `HISTFILE` | `~/.pico_history` | History path |
| `HISTSIZE` | `1000` | History length |
| `COLOR` | `on` | Colored output |
| `PROMPT1` | `"pico> "` | Primary prompt |
| `PROMPT2` | `"pico-> "` | Continuation prompt |
| `NULL` | `"NULL"` | NULL display text |
| `TIMING` | `off` | Execution timing |

### 8. Output and Timing

Keep aligned tables with adaptive widths as the default. Add `/x` expanded output, `/format csv`, and `(0 rows)` / `No rows` for empty results. `/timing on` prints `Time: 12.345 ms`, measured from query send to `command_complete`.

### 9. `pico create instance`

Offline initialization writes the admin public key before the server listens:

```bash
ssh-keygen -t ed25519 -f ~/.pico/mydb1
pico create instance mydb1 \
  --data-dir ./data \
  --admin-public-key-file ~/.pico/mydb1.pub
pico create instance mydb1 --dev
```

The flow creates the data directory, initializes `pico_catalog.users`, writes the SSH-format Ed25519 key, commits the bootstrap transaction to WAL, and optionally starts the listener with `--start`.

### 10. `pico rotate-key`

Online rotation authenticates with the old key, sends `ALTER USER alice ADD PUBLIC KEY <new>;`, confirms persistence, then removes the old fingerprint. It also supports `begin` and `commit` phases and `--force`.

### 11. Authentication

Use `~/.pico/id_ed25519` by default, support `--ca-public-key-file`, authenticate automatically on REPL entry, and expose the current fingerprint through `/key`. The handshake is:

```
Client -> Server: HELLO (key_fingerprint)
Server -> Client: CHALLENGE (nonce, key_fingerprint confirmation)
Client -> Server: CHALLENGE_RESPONSE (nonce signature)
Server -> Client: HELLO_OK (session_id, permissions) or HELLO_ERROR
```

### Architecture

```
clint/
├── main.zig
├── proto/
├── zig/
│   ├── lib.zig
│   ├── connection.zig
│   ├── codec.zig
│   └── ...
└── cli/
    ├── repl.zig
    ├── editor.zig
    ├── history.zig
    ├── completer.zig
    ├── highlight.zig
    ├── formatter.zig
    ├── meta.zig
    ├── terminal.zig
    ├── create.zig
    ├── rotate.zig
    └── auth.zig
```

### Non-Goals

- Built-in less-like pager: deferred to a future heavy TUI.
- Graphical dashboard: outside CLI scope.
- Interactive debugger: out of scope.
- Remote connection management: not an initial feature.

## Decision Drivers

1. The CLI must present a modern, carefully designed product from the first interaction.
2. Zig-native terminal control avoids external dependencies and preserves cross-platform consistency.
3. The same binary supports rich interactive use and quiet pipeline and CI workflows.
4. Help, completion, and errors teach Pico SQL during use.
5. The CLI can evolve independently except for lightweight catalog-completion protocol extensions.

## Consequences

- The implementation grows from about 170 to 2000–3000 lines of dependency-free Zig.
- Add modules under `clint/cli/`; preserve the `pico-cli` build target.
- Handle UTF-8 navigation and document known Windows ANSI/VT support work.
- Add CHALLENGE and CHALLENGE_RESPONSE in `clint/proto/`.
- Preserve non-interactive behavior and test it, including formatting and PTY/mock-stdin interactive cases.

## Delivery

1. Create `clint/cli/` and implement `terminal.zig`, `editor.zig`, `history.zig`, and `repl.zig`.
2. Implement completion, highlighting, formatting, and meta-commands.
3. Refactor `main.zig` for REPL, `create instance`, and `rotate-key`.
4. Implement `create.zig`, `auth.zig`, and `rotate.zig`.
5. Extend `clint/proto/def.zig` and add non-interactive, formatting, interactive, and handshake tests.
