# 传输层：基于 zquic（纯 Zig QUIC）替代 TCP

## Status

Accepted

## Context

Pico 当前使用 TCP + 自定义二进制帧（[4 字节长度][1 字节类型][payload]）作为传输层。随着原生生态推进（ADR-0009），TCP 暴露出几个约束：

1. **请求串行**：单连接按序执行，无法 pipeline 查询
2. **无传输层加密**：依赖应用层自实现，容易缺前向安全性
3. **无流复用**：TCP 的 HoL 阻塞在流复用场景下是硬伤

PQUIC（本 ADR 初稿）尝试自实现一个为 OLTP 裁剪的类 QUIC 协议，但 review 暴露了几个不可忽视的工程代价：

| 问题 | 影响 |
|---|---|
| 无前向安全性（FS） | 长期私钥泄露 → 历史流量全解密，数据库协议不可接受 |
| 自实现拥塞控制 + 重传 | 需要完整 RTT 估计、选择重传，不低于 2000 行 C 级别的工程 |
| 自实现 TLS 替代 | 密码学工程的风险极高 |

**原始决策转向了 quiche**（Cloudflare 的 C 语言 QUIC 实现），但后续评估发现引入 C 依赖（quiche + BoringSSL）会破坏 Pico 当前的零外部依赖策略，增加构建复杂度和跨平台分发负担。

QUIC 生态中随后出现了成熟的 **纯 Zig QUIC 实现**——[zigstack/zquic](https://github.com/zigstack/zquic) 是 RFC 9000/9001/9002 的完整实现，MIT 许可，零外部依赖，与 Pico 一样使用 Zig 0.16.x 工具链。

**决策再次转向**：不自实现 QUIC 子集，也不引入 C 依赖，而是将 zquic（纯 Zig）vendored 到 `lib/zquic/`。QUIC 层负责传输安全、流复用和可靠性；应用协议和认证仍由 Pico 自己定义。

## Decision

**传输层从 TCP 切换到 zquic（QUIC）**。zquic 以 vendored 形式存放在 `lib/zquic/`（Git submodule），作为 Zig 模块引入构建系统。我们的 Pico 协议消息（SQL query、RowData、CommandComplete 等）运行在 QUIC Stream 之上。

---

### 1. 架构分层

```
┌────────────────────────────────────────────┐
│  Pico 应用协议                              │
│  ┌────────────────────────────────────────┐│
│  │  认证层（ADR-0014）                     ││
│  │  Ed25519 挑战-响应 + 权限位图检查        ││
│  └────────────────────────────────────────┘│
│  ┌────────────────────────────────────────┐│
│  │  消息层（clint/proto/def.zig）          ││
│  │  Query | RowDescription | RowData | ... ││
│  │  序列化为 QUIC Stream Data              ││
│  └────────────────────────────────────────┘│
├────────────────────────────────────────────┤
│  QUIC 传输层（zquic）                       │
│  ├─ 流复用（Stream ID 自动管理）             │
│  ├─ TLS 1.3 加密（前向安全性内置）            │
│  ├─ 拥塞控制（CUBIC / BBR v3）              │
│  ├─ 丢包重传 + ACK                         │
│  └─ UDP socket                             │
├────────────────────────────────────────────┤
│  UDP                                       │
└────────────────────────────────────────────┘
```

### 2. QUIC 承载的应用协议映射

QUIC Stream 对应一个「请求-响应」交互序列：

```
Stream ID 分配（由 zquic 管理）:
  0 = 控制流（认证握手 + 元数据交换）
  1+ = 查询流（一个查询 + 其完整结果序列）

每条新查询 open 一个新 stream：
  Stream 1: SQL "SELECT * FROM users" → results done → close
  Stream 3: SQL "INSERT INTO ..."     → complete  → close
  Stream 5: SQL "BEGIN"               → complete  → close
```

**Stream 0 控制流**：认证握手（HELLO → CHALLENGE → CHALLENGE_RESPONSE → HELLO_OK/ERROR）。认证通过后，后续查询使用 Stream 1+。

**Stream N 查询流**（应用层消息，复用现有 codec）：

```
客户端 → 服务端：
  [type=0x10] [SQL 文本]              // Query

服务端 → 客户端（按序）：
  [type=0x11] [columns...]            // RowDescription（仅 SELECT）
  [type=0x12] [values...]             // RowData（零行或多行）
  [type=0x13] [tag] [rows]            // CommandComplete
  [type=0x14] [code] [msg]            // ServerError（流终止）
```

消息类型和序列化方式 **不变**——完全复用 `clint/proto/def.zig` 的现有定义。

### 3. 认证与传输安全的分工

| 职责 | 谁负责 | 说明 |
|---|---|---|
| 传输加密 | zquic (TLS 1.3) | 所有 QUIC 数据包 AEAD 加密，内置前向安全性 |
| 服务器身份 | zquic (TLS 证书) | 服务端需要一张 TLS 证书（自签名或 CA 签发） |
| 用户认证 | Pico 应用层 | 通过 Stream 0 执行 Ed25519 挑战-响应（ADR-0014） |
| 权限检查 | Pico 应用层 | 每个语句执行前检查权限位图 |

**服务器 TLS 证书处理**：
- 开发/单机场景：`pico create instance` 自动生成自签名证书
- 生产场景：用户通过 `--tls-cert` 和 `--tls-key` 指定证书

**用户认证流程**（在 QUIC 连接建立后，Stream 0 上完成）：

```
客户端 → 服务端：QUIC Stream 0, Data = CLIENT_HELLO (key_fingerprint)
服务端 → 客户端：QUIC Stream 0, Data = SERVER_CHALLENGE (nonce)
客户端 → 服务端：QUIC Stream 0, Data = CLIENT_AUTH (signature)
服务端 → 客户端：QUIC Stream 0, Data = SERVER_OK (permissions)
                                  或 SERVER_ERROR
```

认证通过后，服务端记录 `(quic_connection, user, permissions)` 映射。
后续所有 Stream 上的查询直接关联该连接的认证上下文。

### 4. 构建集成

zquic 作为 vendored Zig 模块，通过 `build.zig.zon` 的本地路径依赖引入：

```
// build.zig.zon
// zquic 已克隆到 lib/zquic/，通过本地路径引用
```

```zig
// build.zig
const zquic_mod = b.addModule("zquic", .{
    .root_source_file = b.path("lib/zquic/src/zquic.zig"),
    .target = target,
    .optimize = optimize,
});

// Pico server 和 client 都导入 zquic 模块
exe.root_module.addImport("zquic", zquic_mod);
```

zquic 提供的 embedder API（纯 Zig 接口）：

```zig
// 服务端：创建 QUIC listener
var server = try zquic.Server.init(allocator, .{
    .cert_pem = cert_data,
    .key_pem = key_data,
    .alpn = &.{"pico"},
});

// 服务端：接收新连接（非阻塞）
var conn = try server.accept();
defer conn.deinit();

// 收发应用数据（对应我们的 Stream Data）
const written = try conn.sendStreamData(stream_id, buf, .fin);
const read = try conn.recvStreamData(stream_id, buf, &fin);
```

无需 C 绑定层，无需 BoringSSL，纯 Zig 编译。

### 5. 与现有 TCP 协议的兼容

```
Pico Server 默认监听两个端口：
  TCP  :5434    — 现有 Pico 线协议（逐步过渡期保留）
  UDP  :5435    — QUIC / zquic（新的主要协议）
```

CLI 通过 `--udp` 或自动探测选择：
```bash
pico-cli                        # 默认 QUIC（UDP 5435）
pico-cli --tcp                  # 降级到 TCP 5434
```

过渡期后移除 TCP 版本。

### 6. 连接生命周期

```
CLOSED
  │
  │  QUIC 连接建立（UDP + TLS 1.3 握手）
  ▼
QUIC_ESTABLISHED
  │
  │  Stream 0 认证握手（Ed25519 挑战-响应）
  ▼
AUTHENTICATED
  │
  │  Stream 1..N 正常查询交互
  │  Stream 可并发，互不阻塞
  ▼
  │  QUIC CLOSE 或 Idle Timeout
  ▼
CLOSED
```

---

## Drivers

1. **直接获得完整 QUIC 能力**：流复用、TLS 1.3 加密（含前向安全性）、拥塞控制、丢包恢复——零自实现成本
2. **纯 Zig，零 C 依赖**：zquic 是纯 Zig 实现，与 Pico 共享同一工具链，无需 BoringSSL 或任何 C 编译器依赖
3. **认证与传输分离**：Pico 的 Ed25519 密钥认证体系不变，zquic 只提供安全的传输管道
4. **现有 codec 零改动**：`clint/proto/def.zig` 的消息序列化完全复用，仅传输介质从 TCP socket 改为 QUIC stream
5. **可渐进过渡**：TCP 端口保留，客户端逐步迁移
6. **完全可控**：zquic 作为 vendored 代码存放在 `lib/zquic/`，可以精确锁定版本、本地 patch

## Consequences

- 引入 `lib/zquic/` 作为 vendored 依赖（Git submodule 管理），项目体积增加约 3MB
- 需要跟踪 zquic 的 upstream 更新，定期合并安全修复和功能改进
- 不再需要 C 绑定层——zquic 提供纯 Zig embedder API（`Server`, `Client`, `sendStreamData`, `recvStreamData`）
- `src/net/` 需要新增 QUIC listener 实现（替代或并行于 TCP listener）
- `clint/zig/connection.zig` 需要新增 QUIC 连接实现
- 需要为开发/测试环境准备自签名证书生成逻辑
- 测试覆盖：QUIC 握手、认证流（Stream 0）、并发查询流（Stream 1+）、优雅关闭、证书异常处理、跨实现互操作

## Delivery

1. ~集成 quiche 到构建系统~ → 集成 zquic 到构建系统（`build.zig` 模块导入）
2. ~实现 Zig 侧的 quiche C API 绑定层~ → **已消除**（zquic 原生为 Zig）
3. 在 `src/net/` 中新增 QUIC listener + zquic 连接管理器
4. 将 Stream 0 认证流程接入现有的 Ed25519 挑战-响应逻辑（ADR-0014）
5. 将消息层（`clint/proto/def.zig` codec）挂接到 QUIC Stream 的数据收发
6. 在 `clint/zig/connection.zig` 中新增 QUIC 连接实现
7. 为 `pico-cli` 增加 `--udp`（默认）和 `--tcp` 选项
8. 集成测试：QUIC 握手 + 认证 + 查询往返 + 并发流
9. 明确 TCP 过渡期结束条件和移除计划
