# RunaDB Server

RunaDB Server 是使用 Zig 实现的单实例网络数据服务，也是 RunaDB 当前的
OLTP 基础。RunaDB Client 作为独立产品提供 CLI、驱动和开发工具；两者只通过
版本化的 RunaDB Wire Protocol 通信。

Runa Flow 是当前原生请求语言。Wire Protocol v2.0 开发版本接受
`from <relation> | where <predicate> | emit { <field> }` 形式的 Runa Flow
source，或格式版本 `4` 的规范 Runa Query IR。它也支持不可变 Observation
Evidence 的写入、元数据查询和有界 payload 回读。SQL 文本、PostgreSQL 协议和
PostgreSQL 客户端均不受支持；旧 SQL parser、executor 和协议端点已经移除。

## 当前状态

- 原生 RunaDB Wire Protocol TCP listener 与官方 CLI
- 单实例、本地 data directory
- 只读 Runa Flow relation projection
- Observation Evidence 原生 payload 存储与恢复校验
- Runa Query IR format version `4`
- 面向 Agent 的 opt-in MCP stdio adapter，只提供只读 Runa Flow
- WAL 持久化、CRC32 校验、checkpoint 与崩溃恢复

通用 Mutation、transaction、document/graph operation、持久化 semantic model、
authorization 与 World Continuum binding 尚未实现。LSM、MVCC、group commit
等仍是目标架构，不是当前支持声明。

## 构建与运行

需要 Zig 0.16 或更新版本：

```bash
zig build
zig build test
zig build run
```

服务器默认监听 `127.0.0.1:5434`，data directory 为 `./data`：

```bash
zig build run -- \
  --host 127.0.0.1 \
  --runa-port 5434 \
  --data-dir ./data
```

`--no-sync` 仅用于开发，会关闭默认 WAL 同步并降低 durability level。

## MCP

RunaDB Server 提供 opt-in 的原生 MCP stdio adapter，可由 Agent 作为子进程启动：

```bash
zig build run -- --mcp-stdio --data-dir ./data
```

该 adapter 实现 MCP `2025-11-25` 生命周期和 `runadb_flow_emit` 工具。工具只接收
已实现的只读 Runa Flow `source`，返回有界结构化行。stdout 只会输出 MCP JSON-RPC；
日志写入 stderr。当前版本尚未实现 Streamable HTTP、远程访问、authorization 与 PEM
验证，不得把此 stdio 进程暴露为网络服务。远程 MCP 与 Agent 发起的修改是后续能力，
必须先实现 authentication、PEM 验证、权限映射与审计契约。

当前 Runa Flow source 示例：

```runa-flow
from users
| where id > 10
| emit { id, email }
| limit 100
```

## 文档

- [Runa Flow 与 Runa Query IR](docs/runa-flow.md)
- [RunaDB Wire Protocol v2.0](docs/wire-protocol.md)
- [架构](docs/ARCHITECTURE.md)
- [ADR](docs/adr/)
- [领域术语](CONTEXT.md)

## License

[MIT](LICENSE)
