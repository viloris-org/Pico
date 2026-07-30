# FoundationDB OCC 与写密集工作负载调研

## 范围

本文只记录在 FoundationDB 提交
[`5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d`](https://github.com/apple/foundationdb/tree/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d)
中核实的事实。它是调研输入，
不是架构决策，也不表示 Pico 当前已经实现这些能力。

## 已核实的 FoundationDB 模型

FoundationDB 文档声明其以乐观并发控制实现严格可串行化。事务从一个 MVCC
快照读取；提交时，若事务读过的对象在其读版本之后、提交版本之前已被提交事务
写入，读写事务会被拒绝。读和写互不等待；被拒绝的事务通常由客户端重试。

来源：[`developer-guide.rst`](https://github.com/apple/foundationdb/blob/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d/documentation/sphinx/source/developer-guide.rst#L339-L373) 第 339-373、833-848 行。

冲突的表示是键范围。普通读加入读冲突范围，写加入写冲突范围。快照读不加入读
冲突范围，关闭写冲突范围同样会降低隔离；显式范围可补充应用所需的依赖。客户端
代码中普通范围读、写及原子 mutation 的路径体现了这个划分。

来源：[`developer-guide.rst`](https://github.com/apple/foundationdb/blob/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d/documentation/sphinx/source/developer-guide.rst#L602-L673) 第 602-618、633-673 行；[`NativeAPI.actor.cpp`](https://github.com/apple/foundationdb/blob/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d/fdbclient/NativeAPI.actor.cpp#L3718-L3815) 第 3718-3723、3758、3779-3786、3811-3815 行。

在分布式提交路径中，Commit Proxy 聚合请求、取得提交版本、将冲突范围路由到相应
的 Resolver、保守地合并结果，并在事务日志持久化已接受的 mutation 后才返回成功。
Resolver 代码构造 `ConflictBatch`，将其与保留的写历史及同批事务比较，再记录已
接受的写范围供后续请求验证。

来源：[`developer-guide.rst`](https://github.com/apple/foundationdb/blob/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d/documentation/sphinx/source/developer-guide.rst#L853-L901) 第 853-901 行；[`kv-architecture.rst`](https://github.com/apple/foundationdb/blob/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d/documentation/sphinx/source/kv-architecture.rst#L18-L46) 第 18-46 行；[`CommitProxyServer.cpp`](https://github.com/apple/foundationdb/blob/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d/fdbserver/commitproxy/CommitProxyServer.cpp#L115-L1137) 第 115-182、880-898、921-964、1118-1137 行；[`Resolver.cpp`](https://github.com/apple/foundationdb/blob/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d/fdbserver/resolver/Resolver.cpp#L339-L371) 第 339-371 行；[`ConflictSet.cpp`](https://github.com/apple/foundationdb/blob/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d/fdbserver/resolver/ConflictSet.cpp#L799-L1033) 第 799-847、913-1033 行。

## 已核实的写密集指导

FoundationDB 将同一键的重复更新识别为冲突来源，并给出经验规则：超过每键每秒
10-100 次修改时应重新审视数据模型。其文档化的缓解手段包括：拆分可独立修改的
数据；对计数器使用无读的原子操作；对适用的结合、交换操作使用自适应分片；将
顺序相关操作追加到队列后再单独求值。它还建议将过载延迟集中在事务开始前，避免
扩展事务的冲突窗口。

来源：[`developer-guide.rst`](https://github.com/apple/foundationdb/blob/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d/documentation/sphinx/source/developer-guide.rst#L767-L803) 第 767-775、790-803 行；原子操作的冲突行为见第 537-562 行。

`HighContentionPrefixAllocator` 给出一个具体例子：它快照读取计数器元数据，
原子递增计数器，随机选择候选值，且只为选定候选值加入写冲突范围。

来源：[`HighContentionPrefixAllocator.h`](https://github.com/apple/foundationdb/blob/5e7e0c348b3fbd0fde93b9201ea8887e45bf5c2d/fdbclient/include/fdbclient/HighContentionPrefixAllocator.h#L54-L130) 第 54-130 行。

## Pico 的适用性与边界

对于未来 Pico 的严格可串行化模式，可迁移的机制应限于本地：

1. 固定事务读水位，并在保留私有写集时收集读/写范围。
2. 在 Pico 的单写者提交排序点，将每个读范围与该水位之后的已提交写范围验证，包含确定的批内顺序。
3. 对被接受的事务，将完整逻辑写集追加到 WAL，达到选定的 durability level，发布下一个 `commit_seq`，再向 Connection 确认。

这与 Pico 现有单写者和 WAL-first 约束相容，但不是采纳决定。在 Pico 声明
`SERIALIZABLE`、修改 Pico SQL 支持矩阵或向 Pico Wire Protocol 加入重试/错误
契约前，必须先有新的 ADR。

不应复制 FoundationDB 的 Master、GRV Proxy、Commit Proxy、Resolver 分片或多节点
事务日志拓扑：它们解决的是 Pico 单实例 v1 范围外的分布式协调和扩展问题。同样，
其五秒 Resolver/历史窗口是分布式保留策略，不是 Pico 常量；Pico 的写范围历史
保留必须由活跃快照及事务生命周期策略推导。

对于 Pico 写密集工作负载，原子/可交换的 SQL 操作、应用层分片聚合、追加后归并的
队列，以及快照分配前的接纳控制或背压都是可评估选项。快照读或省略冲突范围不得
静默成为热点键默认策略：引用的 FoundationDB 材料将其定义为隔离降级，因此 Pico
中的等价能力必须是显式、文档化的 opt-in，并经过不变量分析。
