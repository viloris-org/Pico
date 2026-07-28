# 首批 OLTP SQL 子集

**状态：已接受**  
**日期：2026-07-28**  
**所有者与相关方：Pico 维护者**

## 背景与依据

ADR-0003 已决定 Pico 提供 PostgreSQL 线协议上的 OLTP SQL 子集，而不是完整
PostgreSQL 方言。当前实现已有基础建表、索引声明、单表 CRUD 和简单查询协议，但
`BEGIN` / `COMMIT` / `ROLLBACK` 仍只是兼容标签，`CREATE INDEX` 也尚未提供真实
访问路径或全部约束语义。

首批扩展必须服务于常见的迁移型 OLTP 应用：先建立表定义，再逐步增加列、约束和
索引，并通过 PostgreSQL 驱动的参数化 CRUD 在事务中读写。它不得以接受后忽略语义
的方式制造“成功”结果。

## 决策驱动因素

优先级如下：

1. 正确性：已报告成功的 DDL、约束、事务和 DML 必须有完整语义；不支持时明确失败。
2. 驱动兼容：常用 PostgreSQL 驱动可通过扩展查询协议绑定参数并获得正确结果。
3. 可恢复性：表定义及其每次变更与数据修改都遵循 WAL 先行和单写者提交顺序。
4. 范围纪律：不引入完整 PostgreSQL 目录、过程语言或分析型执行器。
5. 可演进性：SQL、目录、事务、索引和存储之间保持清晰的单向依赖。

## 备选方案

- 继续只支持建表和简单查询：实现成本低，但无法支撑典型迁移与驱动工作流。
- 接受更多语法但忽略其效果：表面兼容性高，实际会静默损坏数据或一致性；拒绝。
- 实现首批具备完整语义的 OLTP 子集：范围受控，能形成可验证的应用闭环；采纳。
- 实现 PostgreSQL 的通用 DDL、目录与 PL/pgSQL：功能最广，但违反 ADR-0001 与
  ADR-0003 的产品范围；拒绝。

## 决策

首批 SQL 子集按以下矩阵逐项实现；每一项在公开支持矩阵与真实客户端回归通过前，
均视为不支持。

| 范围 | 首批承诺 | 语义边界 |
| --- | --- | --- |
| 线协议 | Simple Query 与扩展查询的 `Parse` / `Bind` / `Describe` / `Execute` | 参数仅由绑定值提供，不做 SQL 文本插值；未支持的协议报文返回明确错误 |
| 类型 | `BIGINT` / `INTEGER` / `SMALLINT` / `BIGSERIAL`、`BOOLEAN`、`TEXT` / `VARCHAR`、`NUMERIC` / `DECIMAL`、`TIMESTAMPTZ`、`JSONB` | 类型转换、NULL 与范围检查在绑定时完成；JSONB 首批是可比较/可存储值，不承诺算子全集 |
| DDL | `CREATE TABLE [IF NOT EXISTS]`、`ALTER TABLE ADD COLUMN [IF NOT EXISTS]`、`ALTER TABLE DROP COLUMN [IF EXISTS]`、`ALTER TABLE ALTER COLUMN SET/DROP DEFAULT`、`SET/DROP NOT NULL`、`CREATE [UNIQUE] INDEX [IF NOT EXISTS]`、`DROP INDEX [IF EXISTS]` | 每项目录变更原子持久化；添加 `NOT NULL` 或唯一约束时必须验证既有行；不接受后忽略 |
| 约束 | 单列和复合 `PRIMARY KEY`、`UNIQUE`、`NOT NULL`、列级/表级 `CHECK`、外键 `REFERENCES ... ON DELETE CASCADE/SET NULL/RESTRICT` | 约束在写入与 DDL 时强制；外键动作与同一提交原子执行 |
| DML | 多行 `INSERT`、`INSERT ... ON CONFLICT DO NOTHING/DO UPDATE`、`UPDATE`、`DELETE`、`RETURNING` | 命令标签和返回行数准确；冲突目标必须可由主键或唯一索引解析 |
| 查询 | 单表 `SELECT`、投影/别名、`WHERE` 的 `AND` / `OR` / `NOT`、比较、`IN`、`IS [NOT] NULL`、`LIKE`、`ORDER BY`、`LIMIT` / `OFFSET`、`COUNT` / `SUM` / `MIN` / `MAX`、`GROUP BY` / `HAVING` | 不承诺 JOIN、子查询、窗口函数、CTE 或通用表达式优化器 |
| 事务 | 自动提交与 `BEGIN` / `COMMIT` / `ROLLBACK` | 一个事务的写集在提交前不可见；提交经单写者、WAL 先行与默认耐久级别发布；语句错误使事务进入 failed 状态，仅 `ROLLBACK` 可退出 |

以下能力不属于首批，必须明确报错，不得通过跳过或 no-op 模拟：`DO` / PL/pgSQL、函数、
触发器、`CREATE EXTENSION`、系统目录和 `information_schema` 查询、advisory lock、
表分区、`CREATE TYPE` / `ALTER TYPE`、并发建索引、角色/权限 DDL、JOIN、子查询、
CTE、窗口函数和全文检索。

目录模块拥有表、列、约束和索引定义；事务模块拥有事务状态、快照与写集；提交路径是
目录、索引和行数据的唯一写入方。`sql` 只产生已绑定的执行程序，不能直接改写 WAL 或
表存储；`storage` 不得解析 SQL 文本。

## 后果

正面后果：首批形成从迁移、驱动参数绑定到事务性 CRUD 的完整 OLTP 闭环；索引和约束
不再是仅为通过 DDL 的占位实现；支持范围能以测试而非口头承诺验证。

负面后果：需要在实现数据路径前引入目录变更的 WAL 表示、真实二级索引与最小事务
状态机；部分 PostgreSQL 应用语句仍会明确失败，不能将此子集宣传为完整 PostgreSQL。

## 适配性函数与证据

每次新增语义必须同时满足：

1. `zig build test` 覆盖解析、绑定、约束、事务提交/回滚及恢复回归。
2. `psql` 与至少一种主流 PostgreSQL 驱动对支持矩阵中的成功和拒绝用例运行通过。
3. 断电/进程终止注入覆盖 DDL、索引变更、冲突写入和事务提交；恢复后仅可见已提交前缀。
4. 一组可版本控制的 SQL 语料逐条标注为“支持并验证”或“明确拒绝”；CI 禁止未标注
   的成功路径。
5. 模块依赖维持 `net -> sql -> txn/catalog -> storage`；`sql` 不得直接导入 WAL，
   `storage` 不得依赖 SQL 或线协议。

## 演进与失效触发

1. 先建立 SQL 语料与真实客户端集成测试，使当前不支持项可重复地失败。
2. 实现持久目录变更和 `ALTER TABLE` 的最小切片，包含恢复测试。
3. 实现扩展查询绑定、参数类型与事务状态机。
4. 实现真实唯一/二级索引、冲突处理和 `RETURNING`。
5. 实现单表谓词、排序、聚合和分组，并以数据量门槛评估访问路径。

任何需要过程语言、触发器、系统目录兼容、分区、通用 JOIN/子查询，或改变首批事务
隔离承诺的需求，都必须通过新的 ADR 决定；不得作为解析器中的特殊例外加入。

**取代 / 被取代：** 不取代既有 ADR；未来范围扩展应由新的 ADR 取代本决策的相关部分。
