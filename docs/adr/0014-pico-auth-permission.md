# Authentication and Permission Control: Ed25519 Key Authentication + Operation-Level Permission Bitmap

## Status

Accepted

## Context

Pico needs a lightweight but secure authentication and authorization system instead of traditional database passwords.

### Goals

1. **Passwordless**: no passwords to leak, brute-force, or use in social-engineering attacks.
2. **Key as identity**: an Ed25519 key pair is both credential and identity.
3. **Seamless rotation**: support multiple public keys and CA mode without service interruption.
4. **Auditable permissions**: check every statement before execution and reject clearly.
5. **SSH compatibility**: use the OpenSSH public-key format.
6. **Operation-level granularity**: one permission bit per SQL operation, not coarse roles.

## Decision

Adopt **Ed25519 public-key authentication + an operation-level permission bitmap**, storing all data in `pico_catalog.users`.

### 1. Authentication Protocol

Store OpenSSH-compatible Ed25519 public keys and SHA256 Base64 fingerprints. Clients read `~/.pico/id_ed25519` by default.

The HELLO exchange uses a four-message challenge-response:

```
1. Client -> Server: HELLO (protocol_version, key_fingerprint, capabilities)
2. Server -> Client: CHALLENGE (nonce, key_fingerprint)
3. Client -> Server: CHALLENGE_RESPONSE (signature, key_fingerprint)
4. Server -> Client: HELLO_OK (server_version, session_id, permissions)
   or HELLO_ERROR (code, message)
```

Each connection stores `current_user` and `permissions`; authentication failure closes the connection.

#### 1.1 CA Certificate Mode

Short-lived CA-signed certificates may coexist with self-managed keys. The certificate contains an Ed25519 public key, `principal`, `valid_after`, `valid_before`, and optional `extensions`; the CA signs these fields. The server verifies the CA signature, expiry, principal in `pico_catalog.users`, and then performs the nonce challenge.

### 2. System Table

```sql
-- Conceptual schema; users manage it through CREATE/ALTER/DROP USER and GRANT/REVOKE.
pico_catalog.users (
  id            INTEGER PRIMARY KEY AUTO_INCREMENT,
  name          TEXT NOT NULL UNIQUE,
  keys          TEXT[] NOT NULL,
  permissions   INTEGER NOT NULL DEFAULT 0,
  ca_fingerprint TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

| Bit | Permission | Covers |
|---|---|---|
| 0 | `CONNECT` | Connect to the instance |
| 1 | `SELECT` | `SELECT` |
| 2 | `INSERT` | `INSERT` |
| 3 | `UPDATE` | `UPDATE` |
| 4 | `DELETE` | `DELETE` |
| 5 | `CREATE` | `CREATE TABLE`, `CREATE DATABASE`, `CREATE USER` |
| 6 | `DROP` | `DROP TABLE`, `DROP DATABASE`, `DROP USER` |
| 7 | `ALTER` | `ALTER TABLE`, `ALTER USER` |
| 8 | `PICO_STATUS` | `PICO STATUS` |
| 9 | `PICO_CONFIG_READ` | Read `PICO CONFIG` |
| 10 | `PICO_CONFIG_WRITE` | Set `PICO CONFIG` |
| 11 | `PICO_SHUTDOWN` | `PICO SHUTDOWN` |

`admin` uses `0xFFF` (4095), `readonly` uses `0x003`, and `dml_user` uses `0x01F`. The bitmap is returned in HELLO_OK and checked before every statement.

### 3. SQL Administration

```picosql
CREATE USER alice;
CREATE USER alice WITH KEY 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...';
DROP USER alice;
ALTER USER alice ADD PUBLIC KEY 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...';
ALTER USER alice DROP PUBLIC KEY BY FINGERPRINT 'SHA256:abc123...';
LIST PUBLIC KEYS FOR alice;
ALTER USER alice SET CA FINGERPRINT 'SHA256:ca_fingerprint...';
ALTER USER alice DROP CA;
LIST CAS;
GRANT SELECT, INSERT TO alice;
GRANT ALL TO admin;
REVOKE INSERT FROM alice;
SHOW GRANTS FOR alice;
```

Offline bootstrap creates `pico_catalog.users`, inserts the first admin key, grants `permissions = 0xFFF`, commits through WAL, and only then starts the listener. `--dev` generates a key pair and prints the private key. Once the system table is non-empty, unauthenticated connections are rejected unless `--insecure` is used for development.

### 4. Execution-Time Permission Checks

```
Parse AST -> Determine statement type -> Check permission -> Execute
                                      |
                            missing -> PERMISSION_DENIED
```

The checker passes when `(current_user.permissions & required_bit) != 0`; otherwise it returns `server_error(code="PERMISSION_DENIED", message="permission 'SELECT' required, but not granted to 'alice'")`. `Stmt.select`, `Stmt.insert`, `Stmt.update`, `Stmt.delete`, `Stmt.create_table`, `Stmt.alter_table`, `Stmt.drop_table`, user administration, PICO statements, and transaction statements map to the corresponding bits.

### 5. Security Model

| Scenario | Behavior |
|---|---|
| Unknown public key | Reject with `HELLO_ERROR(KEY_UNKNOWN)` |
| Known key with bad signature | Reject with `HELLO_ERROR(SIGNATURE_MISMATCH)` |
| Authenticated but unauthorized | Return `PERMISSION_DENIED`; keep connection |
| Leaked private key | Remove the public key and issue a replacement |
| Expired CA certificate | Reject connection; request a new certificate |
| Rotation window | Both old and new keys work until the old key is removed |
| Corrupt system table | Refuse startup and require backup recovery |

## Decision Drivers

1. Eliminating passwords removes the risks of password leakage, brute-force attacks, and phishing.
2. System-table data receives WAL and recovery durability.
3. SSH-format keys can be registered directly from `~/.ssh/id_ed25519.pub`.
4. Multiple keys and CA mode support small teams and larger deployments.
5. Permission-bit checks are O(1) and fit the single-writer execution path.
6. `pico rotate-key` makes rotation operationally simple.

## Consequences

- Add `CHALLENGE` (0x04) and `CHALLENGE_RESPONSE` (0x05) to `clint/proto/def.zig`.
- Extend HELLO handling in `src/net/pico.zig` and add permission checks to `src/sql/exec/`.
- Create `pico_catalog.users` during engine initialization before accepting users.
- Add Ed25519 certificate and SSH public-key parsing.
- Test handshake, every permission bit, rotation, CA mode, and bootstrap.

## Delivery

1. Add protocol messages and implement the challenge handshake.
2. Initialize the system table and add CREATE/DROP/ALTER USER, GRANT, and REVOKE parsing/execution.
3. Add `src/sql/exec/auth.zig` and permission checks.
4. Implement offline `pico create instance`, `pico rotate-key`, and CA validation.
5. Add end-to-end authentication and authorization tests.
