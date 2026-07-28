# Pico SQL 管理扩展：PICO STATUS / CONFIG / SHUTDOWN

## Status

Accepted

## Context

Pico 已决定不兼容 PostgreSQL（ADR-0009），这意味着 Pico SQL 不再受 PostgreSQL SQL 方言约束。这是一个关键的差异化机会：我们可以设计更清晰、更统一的 SQL 语法来替代 PostgreSQL 中那些历史遗留的、命名不一致的管理操作。

PostgreSQL 的管理接口存在以下痛点：

1. **状态查看碎片化**：`pg_stat_activity`、`pg_stat_bgwriter`、`pg_stat_database` 等系统视图各自为政，需要用户知道查看哪个视图。没有统一的 `SHOW STATUS` 或类似语法。
2. **运行时配置语法不一致**：`SHOW xxx`、`SET xxx TO yyy`、`pg_settings` 视图，三种机制做同一件事。
3. **关机操作不是 SQL**：`pg_ctl stop`、`pg_ctl restart` 是 shell 命令，无法从客户端连接中完成。
4. **检查点和合并不可从 SQL 触发**：`CHECKPOINT` 虽然存在，但很少有人知道；`VACUUM` 参数复杂且与 MVCC 历史纠缠在一起。

Pico 作为全新的轻量 OLTP 数据库，有机会用 **一组自洽的 PICO- 前缀管理 SQL** 统一覆盖这些场景，让用户只通过客户端连接就能完成全部管理操作。

## Decision

在 Pico SQL 中引入 **PICO- 前缀的管理语句**，作为 Pico SQL 的扩展子集。初始覆盖三个核心场景：

### `PICO STATUS`

查看实例的当前运行状态。返回一张单行表，包含以下字段（按需扩展）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `uptime` | `INTERVAL` | 实例启动以来的时间 |
| `connections` | `INTEGER` | 当前活跃连接数 |
| `wal_bytes` | `INTEGER` | 当前 WAL 文件总字节数 |
| `wal_frames` | `INTEGER` | 已写入的 WAL 帧数 |
| `data_size` | `INTEGER` | 数据目录估算占用（字节） |
| `version` | `TEXT` | Pico Server 版本号 |
| `durability_level` | `TEXT` | 当前耐久级别 |

语法：
```picosql
PICO STATUS;
```

输出为标准结果集格式（RowDescription + RowData），与普通 SELECT 走相同的线协议路径。

### `PICO CONFIG`

运行时查看和修改配置。

**查看所有配置**：
```picosql
PICO CONFIG;
```
返回两列表：`name` | `value`，每行一个配置项。

**查看单个配置**：
```picosql
PICO CONFIG durability_level;
```
返回单行。

**修改配置**（持久化或运行时）：
```picosql
PICO CONFIG durability_level = 'sync';
```
配置项名称采用蛇形命名（snake_case），与内部参数名一致。

### `PICO SHUTDOWN`

安全关闭实例。

语法：
```picosql
PICO SHUTDOWN [mode];
```

mode 可选（默认 `graceful`）：
- `graceful` — 等待当前正在执行的语句完成，然后关闭
- `immediate` — 立即关闭，未完成的事务回滚

关闭前自动执行一次检查点（checkpoint），确保 WAL 进度推进到数据文件。

### 协议行为

所有 PICO 管理语句走现有的 Pico 线协议 `query` 消息通道：

1. 客户端发送 `type=0x10 (query)`，payload 为 SQL 文本
2. 服务端解析、执行
3. 返回标准的 `row_description` → `row_data*` → `command_complete` 序列（`PICO STATUS` 有行数据）
4. 或直接返回 `command_complete`（`PICO CONFIG` 设置、`PICO SHUTDOWN`）

### 错误处理

- 未知的 PICO 语句（如 `PICO FOO`）返回标准的 `server_error` 消息
- 参数值非法（如 `PICO CONFIG foo_bar = 123` 中 `foo_bar` 不存在）返回明确的错误消息
- 权限检查由认证与权限系统（见 ADR-0014）执行，当前连接用户无对应权限时返回 `PERMISSION_DENIED` 错误

## Drivers

1. **统一管理入口**：用户只需 SQL 客户端即可完成全部管理操作，不需要 shell 访问或独立管理工具。
2. **降低学习成本**：`PICO STATUS` / `PICO CONFIG` / `PICO SHUTDOWN` 命名自解释，对比 PostgreSQL 的碎片化管理接口有明显优势。
3. **产品差异化**：这是 Pico 与 PostgreSQL 在 SQL 层面的第一个可见差异，传递「不兼容但更好用」的信号。
4. **协议一致性**：复用已有的 query 消息类型，不需要新增协议消息或握手。
5. **可扩展性**：PICO- 前缀为未来增加更多管理语句预留了清晰的命名空间。

## Consequences

- 必须在 `src/sql/parse.zig` 的词法分析和解析器中增加对 `PICO` 关键字和 PICO 语句的支持
- 必须在 `src/sql/ast.zig` 中新增 `Stmt.pico_stmt` 变体（或类似结构）
- 必须在 `src/sql/exec.zig` 中新增 PICO 语句的执行分支
- 管理语句的实现代码应放在 `src/sql/exec/pico.zig` 中，保持模块边界
- PICO 语句**不经过 WAL**（不修改持久化用户数据），`PICO STATUS` 等只读操作使用当前快照，`PICO CONFIG` 设置值直接修改运行时状态（持久化配置未来再考虑）
- 当前实现阶段，`PICO CONFIG` 的修改仅影响运行时，不持久化到磁盘；持久化配置是一个后续可选的增强
- `PICO SHUTDOWN` 必须在发送 `command_complete` 之后才执行实际关闭，确保客户端收到确认
- 客户端库（`clint/zig/`）不需要特殊处理，PICO 语句以普通 query 发送即可
- 测试覆盖：解析、执行、线协议往返

## Delivery

1. 在 `src/sql/ast.zig` 中定义 `PicoStmt` 联合体（初始含 `status`、`config`、`shutdown` 三个变体）
2. 在 `src/sql/parse.zig` 中添加 `PICO` 关键字的词法识别和解析逻辑
3. 新建 `src/sql/exec/pico.zig`，实现各 PICO 语句的执行逻辑
4. 在 `src/sql/exec.zig` 中路由 `Stmt.pico_stmt` 到 `exec/pico.zig`
5. 为 `PICO STATUS` 实现实例状态收集（连接数、WAL 信息、版本等）
6. 为 `PICO CONFIG` 实现运行时配置的读取和修改
7. 为 `PICO SHUTDOWN` 实现安全关闭流程
8. 添加解析测试和端到端线协议测试
