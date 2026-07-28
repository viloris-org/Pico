# 认证与权限控制：Ed25519 密钥认证 + 操作级权限位图

## Status

Accepted

## Context

Pico 需要一套轻量但安全的认证和授权体系，替代传统数据库的用户/密码模式。

### 设计目标

1. **零密码**：不存在可被泄露、暴力破解或社工的密码字符串
2. **密钥即身份**：Ed25519 公私钥对既是认证凭证也是身份标识
3. **密钥轮换无痛**：支持多公钥和 CA 模式，轮换不中断服务
4. **权限可审计**：每个语句执行前检查权限，拒绝明确
5. **SSH 生态兼容**：公钥格式与 OpenSSH 兼容，用户可复用已有密钥
6. **操作级粒度**：每种 SQL 操作有独立权限位，不做粗粒度角色

### PostgreSQL 的痛点

- 密码认证：存在泄露、爆破风险；轮换需要改配置并重启/重载
- pg_hba.conf：基于 IP 的访问控制，粒度粗糙
- 权限体系层次深（role + inheritance + grant option），学习和排错成本高
- 密钥认证仅限 SSH 通道，数据库层面不支持

## Decision

采用 **Ed25519 公钥认证 + 操作级权限位图** 体系，所有数据存储在 `pico_catalog.users` 系统表中。

---

### 1. 认证协议

#### 1.1 密钥格式

使用 Ed25519 密钥对。公钥采用 SSH 格式存储，与 OpenSSH 兼容：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKG...  alice@laptop
```

指纹算法：`SHA256`（Base64 编码，与 SSH 的 `SHA256:` 格式一致）。

私钥格式：OpenSSH 私钥格式（`-----BEGIN OPENSSH PRIVATE KEY-----`），PEM 编码。
客户端 CLI 读取 `~/.pico/id_ed25519` 作为默认私钥。

#### 1.2 线协议握手

HELLO 消息交换扩展为三步挑战-响应：

```
步骤 1: 客户端 → 服务端
  消息类型: HELLO (0x01)
  Payload:
    protocol_version: [MAJOR, MINOR]
    key_fingerprint: [32 字节]  // SHA256(公钥原文)
    capabilities: [位图]        // 客户端能力声明

步骤 2: 服务端 → 客户端
  消息类型: CHALLENGE (0x04)  // 新增消息类型
  Payload:
    nonce: [32 字节]           // 随机挑战
    key_fingerprint: [32 字节]  // 服务端确认的公钥指纹

步骤 3: 客户端 → 服务端
  消息类型: CHALLENGE_RESPONSE (0x05)  // 新增消息类型
  Payload:
    signature: [64 字节]       // Ed25519.Sign(nonce, 私钥)
    key_fingerprint: [32 字节]  // 明确指定使用的密钥

步骤 4: 服务端 → 客户端
  消息类型: HELLO_OK (0x02)
  Payload:
    server_version: [...]
    session_id: [8 字节]
    permissions: [4 字节位图]

  或:

  消息类型: HELLO_ERROR (0x03)
  Payload:
    code: "AUTH_DENIED" | "KEY_UNKNOWN" | "SIGNATURE_MISMATCH"
    message: "..."
```

服务端状态：每个连接维护 `current_user` 和 `permissions`。认证失败则断开连接。

#### 1.3 CA 证书模式

高级用户可使用 CA 签发的短期证书，完全避免密钥分发和轮换操作。

**引导配置**：
```bash
# 初始化时指定 CA 公钥
pico create instance mydb1 --ca-public-key-file ~/pico-ca.pub
```

**客户端连接**：
```
证书格式：
  {
    public_key: [Ed25519 公钥],
    principal: "alice",            // 对应 pico_catalog.users.name
    valid_after:  <timestamp>,
    valid_before: <timestamp>,
    extensions:  [],               // 可选扩展
  }
  签名 = CA 私钥对上述字段的 Ed25519 签名
```

客户端发送 HELLO 时，将整个证书（含签名）随 `key_fingerprint` 一起发送。
服务端验证流程：
1. 用 CA 公钥验证证书签名
2. 检查 `valid_before` 未过期
3. 检查 `principal` 存在于 `pico_catalog.users`
4. 执行标准 nonce 挑战-响应（使用证书内嵌的公钥）

CA 模式和自管理密钥模式可共存——同一个服务端同时支持两种接入方式。

---

### 2. 系统表

认证和权限数据存储在系统表 `pico_catalog.users` 中：

```sql
-- 概念结构（用户不可直接 DML，通过 CREATE/ALTER/DROP USER 和 GRANT/REVOKE 操作）
pico_catalog.users (
  id            INTEGER PRIMARY KEY AUTO_INCREMENT,
  name          TEXT NOT NULL UNIQUE,
  -- 密钥（一个用户可有多把公钥）
  keys          TEXT[] NOT NULL,         -- SSH 格式公钥字符串数组
  -- 权限位图
  permissions   INTEGER NOT NULL DEFAULT 0,
  -- CA 证书模式
  ca_fingerprint TEXT,                   -- 允许签发该用户的 CA 公钥指纹（NULL = 仅自管理密钥）
  -- 元信息
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

权限位图定义（每个位对应一种操作）：

| 位 | 权限 | 覆盖操作 |
|---|---|---|
| 0 | `CONNECT` | 允许连接实例（基本准入） |
| 1 | `SELECT` | `SELECT` 语句 |
| 2 | `INSERT` | `INSERT` 语句 |
| 3 | `UPDATE` | `UPDATE` 语句 |
| 4 | `DELETE` | `DELETE` 语句 |
| 5 | `CREATE` | `CREATE TABLE`、`CREATE DATABASE`、`CREATE USER` |
| 6 | `DROP` | `DROP TABLE`、`DROP DATABASE`、`DROP USER` |
| 7 | `ALTER` | `ALTER TABLE`、`ALTER USER` |
| 8 | `PICO_STATUS` | `PICO STATUS` |
| 9 | `PICO_CONFIG_READ` | `PICO CONFIG` 读取 |
| 10 | `PICO_CONFIG_WRITE` | `PICO CONFIG` 设置 |
| 11 | `PICO_SHUTDOWN` | `PICO SHUTDOWN` |

示例：

| 用户 | 位图值 | 效果 |
|---|---|---|
| admin | `0xFFF` (4095) | 全部权限 |
| readonly | `0x003` (3) | CONNECT + SELECT |
| dml_user | `0x01F` (31) | CONNECT + SELECT + INSERT + UPDATE + DELETE |

位图在握手阶段（HELLO_OK）随 session 信息返回给客户端，也在每个语句执行前由服务端校验。

---

### 3. SQL 管理接口

#### 3.1 用户管理

```picosql
-- 创建用户（不带密钥——后续 ADD）
CREATE USER alice;

-- 创建用户并附加公钥
CREATE USER alice WITH KEY 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...';

-- 删除用户（同时移除所有关联密钥）
DROP USER alice;
```

#### 3.2 密钥管理

```picosql
-- 添加公钥（支持多公钥过渡期）
ALTER USER alice ADD PUBLIC KEY 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...';

-- 按指纹删除公钥
ALTER USER alice DROP PUBLIC KEY BY FINGERPRINT 'SHA256:abc123...';

-- 列出用户的全部公钥
LIST PUBLIC KEYS FOR alice;
-- 返回：fingerprint | key_type | key_preview | added_at
```

#### 3.3 CA 证书管理

```picosql
-- 为指定用户绑定 CA 签发者
ALTER USER alice SET CA FINGERPRINT 'SHA256:ca_fingerprint...';

-- 解除 CA 绑定（恢复为仅自管理密钥）
ALTER USER alice DROP CA;

-- 查看 CA 信息
LIST CAS;
-- 返回：fingerprint | name | added_at
```

#### 3.4 权限管理

```picosql
-- 授权
GRANT SELECT, INSERT TO alice;
GRANT ALL TO admin;

-- 撤销
REVOKE INSERT FROM alice;

-- 查看
SHOW GRANTS FOR alice;
-- 返回：user_name | permission | granted_at

SHOW GRANTS FOR CURRENT_USER;
```

#### 3.5 引导用户（Bootstrap）

首次初始化时通过离线 CLI 注入第一个 admin 用户：

```bash
pico create instance mydb1 --admin-public-key-file ~/.pico/admin.pub
```

此流程在数据库引擎启动网络监听前完成：
1. 创建数据目录
2. 初始化 `pico_catalog.users` 系统表
3. 写入 admin 公钥并赋予全部权限（`permissions = 0xFFF`）
4. WAL commit 引导事务
5. 启动网络监听

开发模式（`--dev`）自动生成 Ed25519 密钥对，私钥打印到 stdout。

**安全约束**：一旦 `pico_catalog.users` 中存在用户，所有未认证连接将被拒绝。
除非使用 `--insecure` 标志启动（只能在开发环境使用）。

---

### 4. 执行时权限检查

权限检查在 SQL 执行路径的以下位置插入：

```
解析 AST → 确定语句类型 → 权限检查 → 实际执行
                              ↓
                     无权限 → PERMISSION_DENIED
```

检查器输入：
- `current_user.permissions`（从连接 session 中获取）
- 语句类型对应的权限位

检查器行为：
- `(current_user.permissions & required_bit) != 0` → 通过
- 否则 → 返回 `server_error(code="PERMISSION_DENIED", message="permission 'SELECT' required, but not granted to 'alice'")`

权限位到语句类型的映射表：

| AST 节点 | 所需权限位 | 说明 |
|---|---|---|
| `Stmt.select` | `SELECT` | |
| `Stmt.insert` | `INSERT` | |
| `Stmt.update` | `UPDATE` | |
| `Stmt.delete` | `DELETE` | |
| `Stmt.create_table` | `CREATE` | |
| `Stmt.alter_table` | `ALTER` | |
| `Stmt.drop_table` | `DROP` | |
| `Stmt.create_user` | `CREATE` | |
| `Stmt.drop_user` | `DROP` | |
| `Stmt.grant` | `ALTER` | 修改权限需要 ALTER |
| `Stmt.pico_status` | `PICO_STATUS` | |
| `Stmt.pico_config_read` | `PICO_CONFIG_READ` | |
| `Stmt.pico_config_write` | `PICO_CONFIG_WRITE` | |
| `Stmt.pico_shutdown` | `PICO_SHUTDOWN` | |
| `Stmt.begin_tx` / `commit_tx` / `rollback_tx` | `CONNECT` | 事务管理跟随连接权限 |

---

### 5. 安全模型要点

| 场景 | 行为 |
|---|---|
| 未知公钥连接 | 拒绝连接，返回 HELLO_ERROR(KEY_UNKNOWN) |
| 已知公钥但签名错误 | 拒绝连接，返回 HELLO_ERROR(SIGNATURE_MISMATCH) |
| 已认证但权限不足 | 返回 PERMISSION_DENIED，连接保持 |
| 私钥泄露 | 管理员删除泄露公钥，用户换新公钥 |
| CA 证书过期 | 连接被拒绝，客户端需申请新证书 |
| 轮换过渡期 | 新旧公钥同时有效，删除旧密钥后仅新密钥可用 |
| 系统表损坏 | 实例拒绝启动，要求从备份恢复 |

---

## Drivers

1. **零密码**：消除密码泄露、爆破、钓鱼攻击面；密钥认证是 SSH 已验证几十年的成熟模式。
2. **系统表存储**：认证数据与用户数据享受相同的耐久性保证（WAL + 恢复）。
3. **SSH 格式兼容**：用户可直接 `cat ~/.ssh/id_ed25519.pub` 注册，无需额外工具。
4. **多公钥 + CA 双模式**：小团队用多公钥直接管理，大规模部署用 CA 短期证书。
5. **操作级权限位图**：检查路径是 O(1) 位运算，无层级递归查询，适合单写者执行路径。
6. **CLI 支持轮换**：`pico rotate-key` 一条命令完成，无需手动改配置。

## Consequences

- `clint/proto/def.zig` 中需要新增 `CHALLENGE` (0x04) 和 `CHALLENGE_RESPONSE` (0x05) 消息类型
- `src/net/pico.zig` 中 HELLO 处理逻辑需要扩展为三步握手
- `pico_catalog.users` 系统表需要在引擎初始化阶段创建，早于用户连接接受
- 所有 `src/sql/exec/` 中的执行器需要新增权限检查入口
- 权限检查在单写者路径上执行，位运算开销可忽略
- bootstrap 流程（`pico create instance`）是 CLI 的离线命令，不依赖网络监听
- 引导后如系统表非空，所有连接必须通过认证；`--insecure` 标志提供逃生口（仅开发环境）
- CA 证书解析需要 Ed25519 签名验证（Zig `std.crypto.sign.Ed25519` 原生支持）
- SSH 公钥解析需要处理 `ssh-ed25519` 格式的 Base64 编码（Zig std 有 Base64 解码）
- 测试覆盖：认证握手（mock 公私钥对）、权限检查（每个权限位的正反测试）、轮换流程、CA 路径

## Delivery

1. 在 `clint/proto/def.zig` 中新增 CHALLENGE / CHALLENGE_RESPONSE 消息类型
2. 在 `src/net/pico.zig` 中实现三步认证握手
3. 初始化时创建 `pico_catalog.users` 系统表（在 engine.open 路径中）
4. 在 `src/sql/ast.zig` 中新增 CREATE USER / DROP USER / ALTER USER / GRANT / REVOKE 语句类型
5. 在 `src/sql/parse.zig` 中添加对应解析逻辑
6. 新建 `src/sql/exec/auth.zig`，实现用户管理、密钥管理和权限管理的执行器
7. 在所有现有执行器中插入权限检查点
8. 实现 `pico create instance` CLI 命令（离线 bootstrap）
9. 实现 `pico rotate-key` CLI 命令
10. 实现 CA 证书模式的签发验证逻辑
11. 添加认证握手和权限检查的端到端测试
