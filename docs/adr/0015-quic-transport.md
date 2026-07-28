# 传输层：基于 quiche（QUIC）替代 TCP

## Status

Accepted

## Context

Pico 当前使用 TCP + 自定义二进制帧（[4 字节长度][1 字节类型][payload]）作为传输层。随着原生生态推进（ADR-0009），TCP 暴露出几个约束：

1. **请求串行**：单连接按序执行，无法 pipeline 查询
2. **无传输层加密**：依赖应用层自实现，容易缺前向安全性
3. **无流复用**：TCP 的 HoL 阻塞在流复用场景下是硬伤

PQUIC（ADR-0015 初稿）尝试自实现一个为 OLTP 裁剪的类 QUIC 协议，但 review 暴露了几个不可忽视的工程代价：

| 问题 | 影响 |
|---|---|
| 无前向安全性（FS） | 长期私钥泄露 → 历史流量全解密，数据库协议不可接受 |
| 自实现拥塞控制 + 重传 | 需要完整 RTT 估计、选择重传，不低于 2000 行 C 级别的工程 |
| 自实现 TLS 替代 | 密码学工程的风险极高 |

同时，QUIC 生态已经成熟——Cloudflare 的 **quiche** 是 RFC 9000 完整实现，MIT 许可，C API，适合 Zig 绑定。

**决策转向**：不自实现 QUIC 子集，而是引入 quiche 作为外部依赖。QUIC 层负责传输安全、流复用和可靠性；应用协议和认证仍由 Pico 自己定义。

## Decision

**传输层从 TCP 切换到 quiche（QUIC）**。我们的 Pico 协议消息（SQL query、RowData、CommandComplete 等）运行在 QUIC Stream 之上。

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
│  QUIC 传输层（quiche）                      │
│  ├─ 流复用（Stream ID 自动管理）             │
│  ├─ TLS 1.3 加密（前向安全性内置）            │
│  ├─ 拥塞控制（BBR / NewReno）              │
│  ├─ 丢包重传 + ACK                         │
│  └─ UDP socket                             │
├────────────────────────────────────────────┤
│  UDP                                       │
└────────────────────────────────────────────┘
```

### 2. QUIC 承载的应用协议映射

QUIC Stream 对应一个「请求-响应」交互序列：

```
Stream ID 分配（由 quiche 管理）:
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
| 传输加密 | quiche (TLS 1.3) | 所有 QUIC 数据包 AEAD 加密，内置前向安全性 |
| 服务器身份 | quiche (TLS 证书) | 服务端需要一张 TLS 证书（自签名或 CA 签发） |
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

quiche 作为 C 依赖添加到 `build.zig.zon` 和 `build.zig`：

```
// build.zig.zon
// 依赖 quiche 的 C 库发布包
// 或通过 system-package 方式引入
```

```zig
// build.zig（示意）
const quiche = b.addStaticLibrary("quiche", null);
quiche.addCSourceFiles(.{
    .root = b.path("lib/quiche"),
    .files = quiche_srcs,
});
quiche.linkLibC();
exe.linkLibrary(quiche);
```

quiche 的 API 使用方式（C 绑定模式）：

```c
// 服务端：创建 QUIC 连接
quiche_conn *conn = quiche_accept(
    &server_scid, &peer_scid, local_addr, peer_addr,
    &config);

// 收发应用数据（对应我们的 Stream Data）
ssize_t written = quiche_stream_send(conn, stream_id, buf, len, fin);
ssize_t read = quiche_stream_recv(conn, stream_id, buf, len, &fin);
```

Zig 侧通过 `@cImport` 或手动声明 C 函数签名绑定。

### 5. 与现有 TCP 协议的兼容

```
Pico Server 默认监听两个端口：
  TCP  :5434    — 现有 Pico 线协议（逐步过渡期保留）
  UDP  :5435    — QUIC / quiche（新的主要协议）
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
2. **认证与传输分离**：Pico 的 Ed25519 密钥认证体系不变，quiche 只提供安全的传输管道
3. **现有 codec 零改动**：`clint/proto/def.zig` 的消息序列化完全复用，仅传输介质从 TCP socket 改为 QUIC stream
4. **生产验证**：quiche 支撑 Cloudflare 全球网络的 QUIC 流量
5. **可渐进过渡**：TCP 端口保留，客户端逐步迁移

## Consequences

- 引入外部 C 依赖（quiche），破坏当前零依赖策略——需要评估构建和分发的额外负担
- quiche 依赖 BoringSSL（TLS 1.3 实现），会引入较重的 C 构建依赖链
- Zig 侧需要编写 C 绑定层（将 quiche 的 C API 封装为 Zig 接口）
- `src/net/` 需要新增 QUIC listener 实现（替代或并行于 TCP listener）
- `clint/zig/connection.zig` 需要新增 QUIC 连接实现
- 需要为开发/测试环境准备自签名证书生成逻辑
- 测试覆盖：QUIC 握手、认证流（Stream 0）、并发查询流（Stream 1+）、优雅关闭、证书异常处理

## Delivery

1. 集成 quiche 到构建系统（`build.zig` + `build.zig.zon`）
2. 实现 Zig 侧的 quiche C API 绑定层
3. 在 `src/net/` 中新增 QUIC listener + quiche 连接管理器
4. 将 Stream 0 认证流程接入现有的 Ed25519 挑战-响应逻辑（ADR-0014）
5. 将消息层（`clint/proto/def.zig` codec）挂接到 QUIC Stream 的数据收发
6. 在 `clint/zig/connection.zig` 中新增 QUIC 连接实现
7. 为 `pico-cli` 增加 `--udp`（默认）和 `--tcp` 选项
8. 集成测试：QUIC 握手 + 认证 + 查询往返 + 并发流
9. 明确 TCP 过渡期结束条件和移除计划
