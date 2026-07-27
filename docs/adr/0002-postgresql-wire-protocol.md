# 对外线协议采用 PostgreSQL Frontend/Backend Protocol

客户端接入使用 **PostgreSQL 线协议**（而非自研二进制协议或仅 HTTP），以便直接使用 `psql`、libpq 及各类语言的 PostgreSQL 驱动。

协议兼容是**接入层**目标；**不等于**完整 PostgreSQL SQL 或行为兼容（见 ADR-0003）。

## Considered Options

- **自研协议 + 官方 SDK**：实现面小，但生态从零冷启动，违反「协议友好」。
- **MySQL 协议**：驱动生态同样成熟，但与团队更熟悉的 PG 工具链及「加分项」偏好不一致。
- **PostgreSQL 线协议（采纳）**：工具与 ORM 覆盖广；可先实现简单查询协议，再扩展扩展查询/门户等。

## Consequences

- 认证、报文类型、错误码等优先对齐 PG 惯例，减少驱动怪异行为。
- 不支持的 SQL 必须返回清晰错误，避免「连得上但静默错结果」。
- 协议测试以真实客户端（至少 `psql` + 一种主流驱动）为回归基准，而不仅是单元级编解码。
