# Pico CLI 交互式体验增强

## Status

Accepted

## Context

当前的 `pico-cli`（`clint/main.zig`，约 170 行）是一个功能极简的 REPL，且只有一个交互模式。

在新的设计中，`pico-cli` 将升级为**多命令二进制**，涵盖：

- **REPL 模式**（默认）：交互式数据库客户端
- **`pico create instance`**：离线初始化新实例（写入 admin 公钥等）
- **`pico rotate-key`**：在线轮换用户公钥

- 一次读取全部 stdin 输入，逐行处理
- 没有交互式行编辑（不能按上下箭头翻历史、Ctrl+A 到行首等）
- 没有 SQL 历史记录（跨会话持久化）
- 没有 Tab 补全
- 没有多行语句支持（一行一条 SQL，遇到分号不会续行）
- 输出为简单表格，无颜色
- 元命令只有 `\q` 和 `\h`

在 Pico 原生生态（ADR-0009）战略下，官方 CLI 是用户与 Pico 交互的首要入口。如果 CLI 体验低于用户对现代数据库工具的预期，这会成为 Pico 采用率的第一道障碍。

PostgreSQL 的 `psql` 功能虽然全面，但存在以下问题：

1. **行编辑体验原始**：readline 由 GNU 提供，在非 Linux 平台表现不一致；无内置多行编辑提示
2. **输出格式过时**：默认对齐方式在宽表时难以阅读；分页器（less）是外部依赖
3. **帮助系统薄弱**：`\h` 显示原始 SQL 语法，对新手不友好
4. **配置繁琐**：`.psqlrc`、`\set`、`\pset` 散布多处

Pico CLI 有机会从零设计一个现代化的数据库 CLI，在 Zig 中自包含实现，不依赖 readline 或 curses 等外部 C 库。

## Decision

对 `pico-cli` 进行重构，实现**中等深度**的交互式体验增强。具体能力如下：

### 1. 交互式行编辑（REPL 模式）

- 使用原始终端模式（raw mode）实现单行编辑，支持：
  - 左右箭头移动光标
  - Home / End 跳到行首/行尾
  - Backspace / Delete 删除字符
  - Ctrl+U 清空行、Ctrl+K 删到行尾等常用 Emacs 快捷键
- **不依赖 GNU readline、libedit 或 curses**，全部在 Zig 中通过 ioctl 和终端转义序列实现
- 启动时检测是否为交互式终端（isatty），非交互式（管道/重定向）按行读取模式退化

### 2. 命令历史（持久化）

- 上下箭头浏览历史
- 历史记录持久化到 `~/.pico_history`（或 `$PICO_HISTFILE`）
- 默认保留最近 1000 条，可配置
- 去重：连续重复的语句只保存一次
- 大小写按实际输入保留

### 3. Tab 补全

- SQL 关键字补全：`SEL<TAB>` → `SELECT`
- 表名补全：通过 `PICO TABLES` 或查询目录（未来）获取当前数据库的表列表
- `\` 元命令补全：`/q`、`/h`、`/set` 等
- 上下文敏感：在 `FROM` 之后补全表名，在 `WHERE` 之后补全列名（未来增强）

### 4. 彩色输出

- 默认启用，可通过 `--no-color` 或 `\set COLOR off` 关闭
- 配色方案：
  - 关键字 = 蓝色/青色
  - 表名/列名 = 默认
  - 字符串 = 绿色
  - 数字 = 黄色
  - NULL = 红色加粗
  - 错误消息 = 红色
  - 表头 = 加粗/下划线
- 行编辑时的语法高亮（在输入时实时着色）

### 5. 多行语句编辑

- 以分号 `;` 作为语句结束标志
- 输入未结束的语句（没有分号）时，按 Enter 自动续行
- 续行时提示符从 `pico>` 变为 `pico->`（缩进感知）
- 支持粘贴多行文本（以分号结束的整个块作为一条语句）
- Ctrl+C 取消当前输入

### 6. 元命令（`/` 命令）

当前仅有 `\q` 和 `\h`，扩展为：

| 元命令 | 功能 |
|---|---|
| `/q` / `/quit` | 退出 CLI（发送 `goodbye` 消息） |
| `/h` / `/help` [topic] | 显示帮助。不带 topic 时列出所有可用命令 |
| `/set [key [value]]` | 查看/设置客户端变量（见下文） |
| `/list` / `/l` | 列出数据库（通过查询目录） |
| `/dt` | 列出当前数据库的表 |
| `/timing` | 切换语句执行计时显示 |
| `/copy` | 导入/导出数据（预留，未来配合 PICO IMPORT/EXPORT） |
| `/!` <shell> | 执行 shell 命令并返回 |

### 7. `/set` 客户端变量系统

| 变量 | 默认值 | 说明 |
|---|---|---|
| `HISTFILE` | `~/.pico_history` | 历史文件路径 |
| `HISTSIZE` | `1000` | 历史保留条数 |
| `COLOR` | `on` | 彩色输出开关 |
| `PROMPT1` | `"pico> "` | 主提示符 |
| `PROMPT2` | `"pico-> "` | 续行提示符 |
| `NULL` | `"NULL"` | NULL 值的显示文本 |
| `TIMING` | `off` | 语句执行计时开关 |

### 8. 输出格式

- 默认：对齐表格（同当前实现，但增加边框线和列宽自适应）
- 展开模式（`/x` 切换）：每列一行，`name | value` 格式，适合宽表
- CSV 模式（`/format csv`）：逗号分隔，适合管道
- 空结果集显示 `(0 rows)` 或 `No rows`

### 9. 执行计时

- `/timing on` 后，每条语句执行完毕显示耗时
- 格式：`Time: 12.345 ms`
- 计时在客户端侧测量（从发送 query 到收到 command_complete）

### 10. `pico create instance` — 实例初始化

离线初始化一个新的 Pico 实例。在数据库引擎启动网络监听之前完成引导配置。

```bash
# 用户先自行生成 Ed25519 密钥对
ssh-keygen -t ed25519 -f ~/.pico/mydb1

# 初始化实例，写入 admin 公钥到系统表
pico create instance mydb1 \
  --data-dir ./data \
  --admin-public-key-file ~/.pico/mydb1.pub

# 开发模式：自动生成密钥对，私钥打印到 stdout
pico create instance mydb1 --dev
```

初始化流程：
1. 创建数据目录结构
2. 初始化 `pico_catalog.users` 系统表
3. 写入 admin 公钥（Ed25519，SSH 格式）
4. 提交引导事务到 WAL
5. 可选 `--start` 自动启动网络监听

设计灵感：类似 AWS EC2 Instance Connect + cloud-init 的模式——初始化时注入公钥，启动后即完成认证就绪。

### 11. `pico rotate-key` — 密钥轮换

零信任生产密钥轮换。不要求用户手动编辑配置或拷贝文件。

```bash
# 一键轮换（两步自动完成）
pico rotate-key alice \
  --instance mydb1 \
  --new-public-key-file ~/.pico/alice-new.pub
```

轮换流程（类似 SSH 安全轮换）：
1. 用旧密钥认证连接目标实例
2. 发送 `ALTER USER alice ADD PUBLIC KEY <new>;`
3. 确认新密钥已持久化
4. 等待确认窗口（或 `--force` 跳过）
5. 发送 `ALTER USER alice DROP PUBLIC KEY BY FINGERPRINT <old_fp>;`
6. 验证旧密钥已被移除

分步模式：
```bash
pico rotate-key begin alice --instance mydb1 --new-key new.pub
... 验证新密钥可用后 ...
pico rotate-key commit alice --instance mydb1 --old-fingerprint <fp>
```

### 12. 认证与密钥管理

CLI 需要内置对 Ed25519 密钥对的管理能力：

- **默认密钥路径**：`~/.pico/id_ed25519`（私钥）和 `~/.pico/id_ed25519.pub`（公钥）
- **密钥生成**：`pico create instance --dev` 可自动生成
- **CA 证书模式**：支持 `--ca-public-key-file ca.pub` 参数，使用 CA 签发的短期证书连接
- **连接时自动认证**：进入 REPL 时自动完成 challenge-response 握手
- **`/key` 元命令**：查看当前使用的密钥指纹

### 13. 认证握手（线协议）

HELLO 交换扩展为两步挑战-响应：

```
客户端 → 服务端：HELLO (key_fingerprint)
服务端 → 客户端：CHALLENGE (nonce, key_fingerprint 确认)
客户端 → 服务端：CHALLENGE_RESPONSE (nonce 签名)
服务端 → 客户端：HELLO_OK (session_id, permissions) 或 HELLO_ERROR
```

权限检查在每次执行前进行，无对应权限时返回 `PERMISSION_DENIED`。
详细设计见 ADR-0014。

### 架构设计

CLI 的代码结构改为：

```
clint/
├── main.zig              # 入口：命令分发（create instance / rotate-key / REPL 默认）
├── proto/                 # (已有) 协议定义
├── zig/
│   ├── lib.zig            # (已有) 库入口
│   ├── connection.zig     # (已有) 连接管理
│   ├── codec.zig          # (已有) 编解码
│   └── ...                 # 后续 SDK 扩展
└── cli/
    ├── repl.zig            # REPL 主循环（事件循环）
    ├── editor.zig          # 行编辑器（raw mode、光标移动、插入删除）
    ├── history.zig         # 历史管理（内存列表 + 文件持久化）
    ├── completer.zig       # Tab 补全（关键字、表名、元命令）
    ├── highlight.zig       # SQL 语法高亮（用于输出和输入时着色）
    ├── formatter.zig       # 结果格式化（表格、展开、CSV）
    ├── meta.zig            # 元命令处理器（`/q`、`/h`、`/set` 等）
    ├── terminal.zig        # 终端抽象（原始模式、尺寸查询、转义序列）
    ├── create.zig          # `pico create instance` 离线实例初始化
    ├── rotate.zig          # `pico rotate-key` 密钥轮换
    └── auth.zig            # 认证握手（challenge-response 签名验证）
```

### 非目标（当前阶段）

- 分页器（less-like 内置）：留到未来重型 TUI 阶段
- 图形化仪表盘：不在 CLI 范围内
- 交互式调试器（类似 PL/pgSQL 的 debugger）：不在范围内
- 远程连接管理（`/c` 切换连接）：可做但非初始范围

## Drivers

1. **首次体验即印象**：CLI 是用户接触 Pico 的第一个界面，必须传递「现代、精心设计」的信号。
2. **自包含不依赖**：在 Zig 中自实现终端控制，不依赖 readline/curses，保持跨平台一致性和零外部依赖。
3. **交互式与非交互式双模**：同个二进制在交互终端提供丰富体验，在管道/CI 中安静高效。
4. **从交互中学习**：`/h`、`TAB` 补全和报错信息本身就是教学工具，降低 Pico SQL 的学习曲线。
5. **产品独立演进**：CLI 增强不依赖服务端新功能（除表名列名补全需要轻量协议扩展外），可独立交付。

## Consequences

- 代码量从 ~170 行增长到预计 ~2000-3000 行（纯 Zig，无外部依赖）
- 需要在 `clint/cli/` 下创建新的模块目录
- `pico-cli` 的构建目标不变，但源文件增加
- 行编辑器需要处理 Unicode 字符（至少能正确跳过 UTF-8 序列）
- 行编辑器需要处理 Unicode 字符（至少能正确跳过 UTF-8 序列）
- Windows 兼容性：当前终端转义序列假设 ANSI/VT100 兼容；Windows 需要额外处理（通过 `SetConsoleMode` 启用虚拟终端），列为已知但非初始阻塞项
- 认证握手（challenge-response）需要 `clint/proto/` 中新增 CHALLENGE 和 CHALLENGE_RESPONSE 消息类型
- `pico create instance` 是离线操作，不依赖运行中的服务端
- `pico rotate-key` 需要在线连接服务端，复用认证握手流程
- `create.zig` 和 `rotate.zig` 需要 Ed25519 密钥解析（SSH 公钥格式）功能
- 现有非交互式行为需要保留且不受影响（管道输入、重定向输出）
- 需要增加 `pico-cli` 的测试覆盖，特别是非交互式模式和格式化输出
- 交互式模式测试可通过 PTY 或 mock stdin 进行

## Delivery

1. 创建 `clint/cli/` 目录结构
2. 实现 `terminal.zig`（raw mode、ANSI 转义封装）
3. 实现 `editor.zig`（单行编辑、光标移动）
4. 实现 `history.zig`（内存 + 文件持久化）
5. 实现 `repl.zig`（主循环、多行检测、Ctrl+C 取消）
6. 实现 `completer.zig`（关键字 + 表名 + 元命令补全）
7. 实现 `highlight.zig`（SQL 词法着色）
8. 实现 `formatter.zig`（表格展开切换、CSV）
9. 实现 `meta.zig`（全部 `/` 命令）
10. 重构 `main.zig` 为多命令入口（REPL / create instance / rotate-key）
11. 实现 `create.zig`（实例初始化 + 公钥写入系统表）
12. 实现 `auth.zig`（challenge-response 握手）
13. 实现 `rotate.zig`（密钥轮换流程）
14. 扩展 `clint/proto/def.zig` 增加 CHALLENGE / CHALLENGE_RESPONSE 消息类型
15. 添加测试（非交互式回归 + 格式化输出快照 + 交互式 mock + 认证握手测试）
