# Pico 产品边界

Pico 由独立发布的 Pico Server 与 Pico Client 组成。两者只通过版本化 Pico 线协议、
Pico SQL 和公开错误模型协作；不共享数据目录、存储实现或进程内 API。

| 产品 | 职责 | 持有的权威 | 不负责 |
| --- | --- | --- | --- |
| Pico Server | 接受连接、执行 Pico SQL、提交事务、维护数据目录并进行恢复 | 数据、目录、事务、WAL、耐久性、恢复、服务端配置 | CLI、语言驱动、ORM、交互式工具 |
| Pico Client | 提供 CLI、驱动和开发者工具，并将用户操作编码为 Pico 线协议 | 本地交互、连接配置、协议编解码、客户端错误呈现 | 数据目录、存储格式、事务提交、耐久性实现 |

## 兼容性

两个产品独立构建、版本化、发布和回滚。每个版本必须声明支持的 Pico 线协议版本和
Pico SQL 能力。兼容性由 `Pico Client version x Pico Server version` 契约测试验证，
不以相同版本号或同一代码仓库为前提。

本仓库当前只承载 Pico Server。尚未建立 Pico Client；当前 `psql` 连接仅用于验证临时
PostgreSQL 适配层，不能作为 Pico Client 支持承诺。

完整决策见 [ADR-0010](adr/0010-client-server-product-boundary.md)。
