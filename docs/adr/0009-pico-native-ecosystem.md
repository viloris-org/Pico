# 产品接口采用 Pico 原生协议与 Pico SQL，不承诺 PostgreSQL 兼容

Pico 是独立的单机、轻量、可网络访问的 OLTP 数据库。对外产品接口采用
**Pico 线协议**和 **Pico SQL**；它们的语义、版本与客户端生态由 Pico 自己定义。
Pico 不承诺 PostgreSQL 的线协议、SQL 方言、类型系统、错误码、驱动或工具兼容性。

本决策取代 ADR-0002 的“对外线协议采用 PostgreSQL Frontend/Backend Protocol”及
ADR-0003 中以 PostgreSQL 驱动兼容作为 SQL 子集范围依据的部分。ADR-0003 对于
“只承诺已发布 SQL 子集、未支持语法必须明确失败”的约束仍然有效。ADR-0007 中
“客户端走 PostgreSQL 协议”的后果，以及 ADR-0008 中 PostgreSQL 驱动和扩展查询
协议的验收要求，均由本 ADR 取代；其余 Zig 与 SQL 范围约束仍然有效。

## Drivers

1. 产品边界必须由 Pico 定义，不能被 PostgreSQL 的协议和行为兼容性牵引。
2. SQL、类型、错误和线协议可独立演进，同时维持单机 OLTP、低资源与可恢复性目标。
3. 接口破坏必须可被客户端、文档和测试明确发现，不能出现“表面可连、语义不一致”的
   伪兼容。

## Considered Options

- **继续 PostgreSQL 驱动兼容**：可立即复用成熟工具，但兼容预期持续扩大，限制接口与
  SQL 演进；不采纳。
- **保留 PostgreSQL 协议，建立双协议产品**：可平滑迁移，但长期要维护两套公开契约、
  驱动与测试矩阵；除非未来新 ADR 明确恢复兼容层，否则不采纳。
- **Pico 原生生态（采纳）**：以版本化 Pico 协议、Pico SQL、官方客户端工具及公开
  支持矩阵组成唯一产品契约。

## Consequences

- 新增和变更客户端能力时，必须先定义 Pico 协议版本、Pico SQL 支持矩阵、错误模型及
  官方客户端兼容范围；不以 PostgreSQL 行为为准则。
- 网络、SQL 和客户端工具的集成回归改为 Pico 官方 CLI/驱动；`psql` 与 PostgreSQL
  驱动不再是产品验收条件。
- PostgreSQL Frontend/Backend Protocol 仅可作为当前实现的迁移适配层，必须标示为
  非稳定、非兼容承诺，并在 Pico 原生协议可用后移除。适配层不得驱动 SQL、类型或事务
  语义设计。
- `src/net` 的目标边界是 Pico 线协议；`src/sql` 的目标边界是 Pico SQL。内部存储、
  事务、WAL 和 LSM 的正确性不依赖任何外部数据库协议。
- 对外文档禁止使用“兼容 PostgreSQL”“可使用 PostgreSQL 驱动”或等价表述。若必须说明
  迁移状态，须同时写明它不构成兼容性承诺。
- Pico Client 与 Pico Server 的独立发布、职责和兼容性边界由 ADR-0010 定义。

## Migration and Validation

1. 先发布 Pico 线协议、Pico SQL、错误模型与版本协商的规范，以及最小官方 CLI/驱动。
2. 在新协议上实现一个端到端语句与事务切片，并以协议一致性、SQL 支持矩阵、恢复及
   耐久回归作为验收门槛。
3. 将当前 PostgreSQL 适配层降为显式过渡模式；删除依赖其类型别名、错误码或真实客户
   端的产品测试。
4. 适配层移除后，删除其端口和连接示例。任何重新引入的兼容层都必须有新的 ADR，定义
   支持范围、版本策略、成本上限和退出条件。

在步骤 1--3 完成前，当前实现仍会接受 PostgreSQL Frontend/Backend Protocol；这是
实现状态，不是 Pico 的对外兼容承诺。发布版本不得把该过渡状态描述为 Pico 原生协议
已经可用。
