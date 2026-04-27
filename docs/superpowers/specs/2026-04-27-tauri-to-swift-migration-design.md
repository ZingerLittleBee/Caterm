# Tauri → Swift/SwiftUI + libghostty 迁移设计

**日期**：2026-04-27
**状态**：设计已批准；待写实现计划
**进度跟踪**：`docs/superpowers/plans/2026-04-27-swift-migration-progress.md`

---

## 1. 背景

Caterm 当前桌面端基于 Tauri：

- **前端**：React 19 + Vite + xterm.js
- **后端**：Rust（`russh` SSH，`russh-sftp` SFTP，~1100 行）
- **路径**：`apps/web/`（前端 + `src-tauri/`）

已实现的 Tauri 命令面：SSH 5 个、SFTP 18 个、本地 FS 11 个；server 端 oRPC routers（`sshHost` / `terminalSettings` / `sftpBookmark` / `todo`）已稳定。

### 重构动机

按重要性排序：

1. **A — 终端体验**（GPU 渲染、ligatures、IME、字体渲染）—— xterm.js 在 macOS 上的渲染、IME、高吞吐丢帧问题已成痛点
2. **B — macOS 原生质感**（Keychain、Touch ID、NSWindow tab、Finder 集成、菜单栏）
3. **D — 性能 / 资源**（包体积、内存、冷启动）—— 作为 A+B 的副产品自然到位
4. **C — 维护成本** —— 不主动追求；指向"server 端不动，只重写客户端"的策略

### 不在范围内

- 跨平台（明确放弃 Windows / Linux 桌面端）
- Server 端任何修改（包括 schema、API、auth）
- 任何"趁机优化"——只做迁移本身

---

## 2. 锁定的关键决策

| # | 决策 | 含义 |
|---|------|------|
| D1 | 桌面端目标平台 = **macOS only** | 不再追求 Tauri 的跨平台能力 |
| D2 | UI 技术栈 = **SwiftUI + AppKit 混用** | SwiftUI 主，AppKit 处理 tab/复杂键盘/拖拽 |
| D3 | 终端渲染 = **libghostty**（Ghostty 的 C API） | Swift 不做 ANSI 解析，libghostty 全包 |
| D4 | SSH 库 = **swift-nio-ssh** | Apple 官方维护、纯 Swift；备选 libssh2/Citadel |
| D5 | 构建系统 = **纯 SwiftPM** | 不引入 `.xcodeproj`；`.app` 用 swift-bundler 打包 |
| D6 | 最低 macOS 版本 = **14.0** | 不兼容 Ventura 及以下 |
| D7 | 终端配置模型 = **Ghostty 原生 schema** | 客户端本地直接读写 Ghostty config 文件，不做映射；**server 端跨端同步终端配置 = 推迟**（现有 `terminalSettingsRouter` 是结构化 Zod 白名单，无法承载任意 Ghostty config 文本，开放它需要单独 server schema 设计） |
| D8 | 新代码位置 = **`apps/macos/`** | 与 `apps/web`（Tauri）和 `apps/server` 平级 |
| D9 | 旧 Tauri 客户端 = **冻结**（一次性例外）| 不再维护（含 bug fix）；**唯一允许的变更**：在 v1 ship 前后，单次提交往 Tauri 版加 deprecation banner 引导迁移；之后彻底冻结 |
| D10 | Server 端 = **完全不动** | v1.1 复用现有 oRPC API（仅 `sshHost` + `auth`）；终端配置同步因 schema 限制推迟，不在 v1.1 |
| D11 | 执行策略 = **Approach 1**（spike → 垂直切片） | 5 天 spike 验证后再投入 v1 |
| D12 | v1 凭据存储 = **仅本地 Keychain** | v1 无同步；server 端不参与凭据流 |
| D13 | v1 不做的功能（推后到 v1.1/v2） | 跨端主机同步（v1.1）、终端配置同步（推迟）、SFTP（v2）、远端文件浏览器（v2）、拖拽上传（v2）、bookmarks（v2）；**永久砍掉：本地文件浏览器面板** |
| D14 | **SSH host key 校验**（v1 必须） | 实现 KnownHostStore：首次连接 TOFU 弹窗确认指纹 → 写入；后续 mismatch 阻断连接。**绝不 accept-all**（Tauri 版当前是 `accept-all`，v2 SECURITY TODO，但 Swift v1 不能继承这个 bug） |

### 砍掉的功能（不再纳入路线图）

- **本地文件浏览器面板**（Tauri 版的 11 个 `local_fs_*` 命令对应的双栏 UI）—— 用户确认不再需要
- 注意：v2 SFTP 仍需要本地文件**选取**（NSOpenPanel）和 **Finder 拖入**（NSDraggingDestination）作为上传源，但不再有常驻的"本地文件管理"面板

---

## 3. 架构

### 3.1 进程结构

单 Swift 进程，所有终端会话共享一个进程。libghostty 以 `.dylib` 链接（包成 `.xcframework` 给 SwiftPM `binaryTarget` 用）。

```
┌─────────────────────────────────────────────────────────┐
│  Caterm.app  (single Swift process, macOS-only)         │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │  UI 层 (SwiftUI + AppKit)                       │    │
│  │  - WindowChrome (NSWindow + tab bar)            │    │
│  │  - HostListSidebar / ConnectDialog              │    │
│  │  - TerminalContainer (NSViewRepresentable)      │    │
│  └────────┬─────────────────────┬──────────────────┘    │
│           │                     │                        │
│  ┌────────▼─────────┐  ┌────────▼──────────────────┐   │
│  │ TerminalEngine   │  │ SessionStore               │   │
│  │ (Ghostty bridge) │  │ (host list, tab state)     │   │
│  └────────┬─────────┘  └────────┬──────────────────┘   │
│           │                     │                        │
│  ┌────────▼─────────────────────▼──────────────────┐    │
│  │  SSHTransport  (swift-nio-ssh)                  │    │
│  │  - Connection / Channel / PTY                   │    │
│  │  - Auto-reconnect 状态机                        │    │
│  └────────┬────────────────────────────────────────┘    │
│           │                                              │
│  ┌────────▼─────────┐  ┌──────────────────────────┐     │
│  │ KeychainStore    │  │ ConfigStore              │     │
│  │ (凭据)           │  │ (Ghostty config + paths) │     │
│  └──────────────────┘  └──────────────────────────┘     │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │  libghostty.dylib  (vendor 自构建，Zig 工具链)   │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘

           [v1 不接 server；v1.1 起加 ServerSyncClient]
```

### 3.2 模块划分

| 模块 | 职责 | 依赖 | 测试 |
|------|------|------|------|
| **UI 层** | SwiftUI 视图 + AppKit window/tab；TOFU 弹窗 | TerminalEngine, SessionStore, KnownHostStore | 不测；后期 XCUITest |
| **TerminalEngine** | 包装 libghostty C API；PTY 数据进、渲染出；输入事件转发 | libghostty (C) | 烟雾测试，信任 libghostty |
| **SSHTransport** | NIOSSH 连接、channel、PTY 申请、reconnect 状态机；**调用 KnownHostStore 做 host key 校验** | swift-nio-ssh, KnownHostStore | **必须** 单元测试（EmbeddedChannel）+ Docker openssh-server 集成 |
| **KnownHostStore** | host key 持久化（OpenSSH `known_hosts` 兼容格式）；查询/插入；mismatch 报错；TOFU 由 UI 层触发 | 文件系统 | 单元测试（含 mismatch 场景）|
| **SessionStore** | 主机列表（持久化 JSON）、tab 状态、活跃连接登记 | KeychainStore | 单元测试 |
| **KeychainStore** | 凭据读写；key 命名 `caterm.host.<id>.<field>` | macOS Security framework | 单元测试 |
| **ConfigStore** | 加载/保存 Ghostty 配置文件 + 应用配置 | 文件系统 | 单元测试 |

### 3.3 关键边界 & 并发模型

**模块边界**
- **TerminalEngine 不知道 SSH** —— 只接受字节流和写回调；未来加本地 shell 零成本
- **SSHTransport 不知道终端** —— 产 `AsyncThrowingStream<Data, Error>` 给上层（**带界容量**，下文 §4.2 详述）；测试不依赖 libghostty
- **SessionStore 是 UI 唯一数据源** —— ObservableObject；UI 不绕过它直接调 SSHTransport

**线程模型**

| 层 | Executor | 备注 |
|----|----------|------|
| UI / SwiftUI 视图 / NSView 操作 | `@MainActor` | 强制约束 |
| `TerminalEngine.feed(_:)` 触发的 `ghostty_surface_write_data` | `@MainActor` | libghostty surface 操作非线程安全，统一在主线程 |
| `TerminalEngine` 内部状态 | `@MainActor` | 简化模型 |
| `SSHTransport`（NIO event loop）| NIO 自己的 `EventLoopGroup`（`MultiThreadedEventLoopGroup`，1 线程）| 永远不在 main thread 跑 |
| `SessionStore` ObservableObject | `@MainActor`（发布 publish） | 后台来的事件用 `Task { @MainActor in ... }` 切回 |
| `KeychainStore` / `KnownHostStore` / `ConfigStore` 文件 I/O | 各自 `actor` 隔离 | 不阻塞 UI |

**关键纪律**：跨边界传字节用 `AsyncStream`，`@MainActor` 与 NIO 之间通过 `Task` + `MainActor.run` 显式切换；不允许 NIO callback 直接 touch SwiftUI state。

### 3.4 工程脚手架

```
apps/macos/
├── Package.swift                      # SwiftPM 主入口
├── Caterm/
│   ├── CatermApp.swift                # @main, WindowGroup
│   └── Views/...
├── Sources/
│   ├── TerminalEngine/                # libghostty bridge
│   │   ├── GhosttySurface.swift
│   │   └── module.modulemap
│   ├── SSHTransport/
│   │   ├── SSHConnection.swift        # NIOSSH 包装
│   │   └── BoundedByteChannel.swift   # 背压队列
│   ├── KnownHostStore/                # host key TOFU 持久化
│   ├── SessionStore/
│   ├── KeychainStore/
│   └── ConfigStore/
├── Tests/
│   ├── SSHTransportTests/
│   ├── KnownHostStoreTests/
│   ├── SessionStoreTests/
│   └── KeychainStoreTests/
├── Vendor/
│   └── ghostty/                       # git submodule
└── Scripts/
    ├── build-libghostty.sh            # 调 zig build → .xcframework
    └── release.sh                     # swift-bundler + codesign + notarytool + create-dmg
```

---

## 4. 数据流 & 关键交互

### 4.1 连接流（含 host key 校验）

```
User → ConnectDialog
   │  (host info + 密码或私钥)
   ▼
SessionStore.openSession(hostId)
   │
   ▼
KeychainStore.read(hostId) ──→ 取出凭据
   │
   ▼
SSHTransport.connect(config)
   │
   │  NIOSSH handshake →  hostKeyValidator(serverKey, host:port)
   │                        │
   │                        ▼
   │                      KnownHostStore.lookup(host:port)
   │                        ├─ 存在 + match  → 通过
   │                        ├─ 存在 + mismatch → 抛 HostKeyMismatchError
   │                        │                    UI 显示警告，连接终止（必须用户手动解决）
   │                        └─ 不存在  → suspend，UI 弹 TOFU 对话框
   │                                       ├─ 用户 Trust  → KnownHostStore.insert → 通过
   │                                       └─ 用户 Reject → 抛 HostKeyUnknownError，断开
   │
   │  → auth (password / publickey) → open session channel → request PTY
   │
   ├─ 成功: 返回 Connection { stdoutStream, stdinSink, resizeSink, closeSink }
   │   │
   │   ▼
   │  TerminalEngine.attach(stream, sink) → libghostty surface 创建
   │   │
   │   ▼
   │  SessionStore.markConnected(sessionId)  → UI tab 状态变绿
   │
   └─ 失败: SessionStore.markFailed(sessionId, err) → 错误 toast / TOFU UI
```

### 4.2 终端 I/O（含背压）

```
[远端 stdout]                                       (NIO event loop)
    │
    ▼
NIOSSH Channel inbound  ──→  BoundedByteChannel  (cap = 256 KB)
    │                            │
    │                            │  缓冲水位
    │                            ├─ < HIGH (192 KB)  → 正常读
    │                            ├─ ≥ HIGH           → channel.read = false (暂停 NIO 读)
    │                            └─ < LOW  (64 KB)   → channel.read = true  (恢复读)
    │
    ▼  (Task: NIO loop → @MainActor)
TerminalEngine.feed(bytes)  ──→  ghostty_surface_write_data (C call, MainActor)
                                  └─ libghostty 内部解析 VT + GPU 渲染

[用户键盘输入]                                       (@MainActor)
    │
    ▼
NSResponder keyDown / keyUp
    │
    ▼
TerminalEngine.handleKey(event) ──→ ghostty_surface_key (translate)
    │
    ▼
ghostty write callback(bytes) ──→ SSHTransport.stdinSink.write(bytes)
                                  (Task → NIO loop;无界，但键盘速率极低，不需限流)
    │
    ▼
NIOSSH Channel outbound
```

**关键纪律**：

1. libghostty 既是渲染器也是 VT 解析器；Swift 层不做 ANSI 解析，只搬字节
2. `BoundedByteChannel` 是有界队列；`cat huge.log` / `yes` 这类高吞吐场景，水位高时显式暂停 NIO 读，由 TCP 窗口反向限速远端 —— 不允许 unbounded `AsyncStream` 把内存炸穿
3. 数值（256K/192K/64K）是初始猜测，spike 之后基于实测调整；写进配置常量便于后期改
4. NIOSSH child channel 创建时**必须启用 remote half-closure**（`SSHChildChannelOptions.allowRemoteHalfClosure = true`），否则 EOF 处理不正确

### 4.3 自动重连状态机

```
       ┌──────────┐
       │  Idle    │
       └─────┬────┘
             │ user connect
             ▼
       ┌──────────┐  network up   ┌──────────────┐
       │Connecting├──────────────→│  Connected   │
       └─────┬────┘               └──────┬───────┘
             │ fail (timeout/auth)      │ EOF / network drop
             │                          │
             ▼                          ▼
       ┌──────────┐                ┌──────────────┐
       │  Failed  │                │ Reconnecting │
       └──────────┘                └──────┬───────┘
       (终止；用户手动重连)               │ exp backoff
                                          │ 1s, 2s, 5s, 10s, 30s (cap)
                                          │ 5 次后停止
                                          ▼
                                    重新 Connecting
```

**复用语义**：参照 `2026-03-04-ssh-auto-reconnect-design.md`，不重新设计交互。

**重连语义边界（重要）**：

- 重连 = **建立新 SSH session**，不是恢复原远端进程
- 原远端 shell 上跑的 vim/tmux/long-running command **全部已死**；连接断的瞬间它们就被 SSH server kill 了（除非用户在 tmux/screen 里）
- UI 必须**显式提示新连接已建立**（例如往新 surface 写入 `\r\n[Caterm: 新连接已建立]\r\n`），不能让 surface 看上去像"自动延续"
- scrollback 可以保留（让用户回看断开前的输出），但视觉上要有分隔线 —— 不能给用户造成"vim 还在那"的错觉
- 这条纪律的目的：**代码不能撒谎**。一旦 UI 暗示 "session resumed"，后续就要被迫层层补漏（"为啥我的 vim 没了"），技术债复利

### 4.4 Tab 生命周期

- **新 tab** = `SessionStore.openSession()` → 立即出现 "Connecting…" tab；连接结果异步回填
- **关 tab** = 优雅关闭 NIOSSH channel → 从 SessionStore 移除 → libghostty surface destroy
- **窗口关闭** = 所有 tab 顺序关闭，KeychainStore/ConfigStore 各自 flush

---

## 5. Phase 0 — Spike 详细规格

**目标**：3-5 天证明"libghostty + NIOSSH + Swift"链路可行；产出可丢弃。

### 5.1 范围

| 包含 | 排除 |
|------|------|
| 单窗口 SwiftUI app | 多 tab |
| 一台机器，参数从 **`.spike.local.json`（gitignored）或环境变量** 读 | host CRUD UI / 持久化 |
| password auth | 私钥 auth |
| libghostty 嵌入一个 NSView 渲染 | 主题、字体配置 |
| 键盘输入 → SSH stdin | 鼠标、剪贴板 |
| stdout → 终端渲染 | 错误处理 / 重连 |
| 窗口 resize（验证全双工控制面）| Keychain / Sparkle / 任何打磨 |
| Bash 跑 `ls && top` 看效果 | 单元测试 |
| **host key 校验**（spike 阶段允许 accept-all，但要打 TODO 注释）| **凭据写源码**（绝对禁止）|

**Spike 凭据 / 配置加载**：

```
1. 优先读环境变量 CATERM_SPIKE_HOST / _USER / _PASSWORD / _PORT
2. 否则读 apps/macos/.spike.local.json （加进 .gitignore）
3. 都没有 → fail with 明确错误信息
```

`.gitignore` 必须包含 `.spike.local.json` —— 启动 step 1.0 之前先验证。

### 5.2 验收清单（6 项 yes/no）

- [ ] **S1 编译通过** — Swift 项目链接 libghostty.xcframework 并跑起来
- [ ] **S2 渲染** — 把硬编码的 `"Hello\r\n"` 字节喂进 ghostty surface，能在窗口看到
- [ ] **S3 SSH 字节流** — NIOSSH 连机器，能从 channel 读到 stdout 字节
- [ ] **S4 全链路** — NIOSSH 输出接到 ghostty surface，远端命令输出实时显示
- [ ] **S5 反向输入** — 在窗口按键，远端 shell 收到（`echo $$` 能跑）
- [ ] **S6 Resize** — 拖拽窗口尺寸，libghostty 重新布局 + NIOSSH 发 `window-change`，远端 `stty size` 反映新值

6 项全过 → 进 Phase 1。任何一项卡死 → 立即决策：放弃 libghostty 改 SwiftTerm / 换 libssh2 / 延期。

### 5.3 Spike 纪律

- **不写 UI 抽象**（不要 ViewModel、不要 protocol、不要 DI）
- **不写测试**
- **每天 1 行 log 进 progress 文件**（卡在哪 / 解了什么）

### 5.4 已知未知

1. libghostty 公开 API 表面有多大（文档少；可能要读 GhosttyKit 源码）
2. libghostty 渲染层是 Metal layer 还是 NSView 直绘（决定 host 进 SwiftUI 的方式）
3. NIOSSH 的 PTY 申请姿势（`ChildChannelInitializer` + `SSHChannelRequestEvent.PseudoTerminalRequest`）
4. 键盘事件 → libghostty key code 映射

---

## 6. Phase 1 — v1 实施计划

### 6.1 任务拆解

| Step | 增量 | 估时（业余）| 关键产出 |
|------|------|------------|---------|
| 1.0 | 把 spike 代码全删了，重起干净项目（保留构建脚本和 module.modulemap）| 0.5 天 | 干净 baseline |
| 1.1 | 单 tab + 临时主机配置 + 完整 connect 流（含 password & key auth）+ **BoundedByteChannel 背压**+ **NIOSSH half-closure 启用** | 3-4 天 | 能连第一台机器 |
| 1.2 | **KnownHostStore + TOFU 弹窗 + mismatch 阻断 UI**（v1 强制要求，不能延后）| 2-3 天 | host key 校验 |
| 1.3 | NSWindow tab（多 tab）+ 切换 + 关闭 tab 优雅断开 | 3 天 | 多 tab |
| 1.4 | HostListSidebar UI + 添加/编辑/删除主机表单 + 本地 JSON 持久化 | 4-5 天 | 不再硬编码 |
| 1.5 | KeychainStore 接入（替代 1.1 的临时凭据存储）| 2 天 | 凭据安全 |
| 1.6 | 自动重连状态机 + UI 状态指示（绿/黄/红）+ **新连接已建立提示**（§4.3 纪律）| 3-4 天 | 网络抖动可恢复 |
| 1.7 | 应用配置：直接读写 Ghostty config 文件（`~/Library/Application Support/Caterm/config`）；最小 UI 暴露"打开配置文件" | 1 天 | 主题/字体走 Ghostty |
| 1.8 | 打磨：菜单栏、菜单项、快捷键（⌘T 新 tab / ⌘W 关 tab / ⌘N 新窗口）、关于面板 | 2-3 天 | 像个 Mac app |
| 1.9 | 内测分发：`Scripts/release.sh`（swift-bundler + codesign + notarytool + create-dmg）+ Sparkle + Tauri 版 deprecation banner（D9 一次性例外）| 3-4 天 | 可分发 |

**累计**：约 24-29 个工作日。业余 1 小时/天 → 5-8 周；业余 4 小时/周末 → 6-10 周。

### 6.2 数据模型（v1）

**Host**（本地 JSON，路径 `~/Library/Application Support/Caterm/hosts.json`）：

```swift
struct Host: Codable, Identifiable {
    let id: UUID
    var name: String
    var hostname: String
    var port: Int                    // default 22
    var username: String
    var authType: AuthType           // .password | .privateKey
    // 凭据本身不在 JSON 里，只存 Keychain 引用
    // Keychain key: "caterm.host.<id>.password" / ".privateKey" / ".keyPassphrase"
    var createdAt: Date
    var updatedAt: Date
}
```

**TerminalSettings**：直接 Ghostty config 文件，不二次包装。

- 路径：`~/Library/Application Support/Caterm/config`（Caterm 独立维护，不读取也不写入 Ghostty 自己的 `~/.config/ghostty/config`，避免与用户已有 Ghostty 配置互相污染）
- 不存在时由 ConfigStore 写入一份默认值
- v1 不提供配置 UI，仅暴露"打开配置文件"菜单项；用户用文本编辑器改

**KnownHosts**（host key 持久化）：

- 路径：`~/Library/Application Support/Caterm/known_hosts`
- 格式：与 OpenSSH `known_hosts` 兼容（`hostname[:port] keytype base64key`），便于人工核对和未来导出
- 由 KnownHostStore actor 串行化读写

### 6.3 测试策略

| 层 | 测什么 | 怎么测 |
|----|-------|--------|
| **SSHTransport — 协议层** | handshake / channel 生命周期 / window-change / half-closure | 用 NIO 自带的 `EmbeddedChannel` + `EmbeddedEventLoop` 状态机测试，不起真实 socket |
| **SSHTransport — 集成** | 真实 auth（password & publickey）、PTY、stdin/stdout、resize、EOF | **Docker `linuxserver/openssh-server` 容器**，CI 拉起后跑 happy path + 异常 |
| **BoundedByteChannel** | 高水位暂停 / 低水位恢复 / 跨 actor 安全 | 单元测试 + 压力测试（喂 10 MB 看内存峰值）|
| **KnownHostStore** | TOFU 写入 / mismatch 检测 / 兼容 OpenSSH 格式 / 并发读写 | 单元测试，**mismatch 场景必测** |
| **SessionStore** | host CRUD、tab 状态、并发安全 | 单元测试，纯 Swift |
| **KeychainStore** | 读写 / 不存在 / 重复写 | 单元测试，target 单独 keychain access group |
| **TerminalEngine** | 不测内部（信任 libghostty） | 烟雾测试：能创建 surface 即可 |
| **UI** | 不测 | 手测；后期 XCUITest |
| **重连状态机** | 状态转换矩阵（含"提示新连接已建立"事件） | 单元测试，**硬要求** |

**实现注意事项（写代码时盯死）**：

1. NIOSSH child channel 必须 `allowRemoteHalfClosure = true`，否则 EOF 不正确
2. `ChildChannelInitializer` 中要按 NIOSSH 文档加 `SSHChannelRequestEvent.PseudoTerminalRequest` + `SSHChannelRequestEvent.ShellRequest`，顺序敏感
3. `ghostty_surface_*` 调用必须在 `@MainActor`
4. NIOSSH event loop 的 `EventLoopGroup` 在 SSHTransport 单例里持有；`shutdownGracefully` 在 app 退出时调一次

### 6.4 v1 完成标准（DoD）

**6 项 MVP 功能可用**（不是"通了"，是"日常用一周不痛"）：

1. **SSH 连接**（密码 + 私钥两种 auth）
2. **libghostty 渲染** + 多 tab 切换
3. **主机列表**（添加/编辑/删除 + 本地 JSON 持久化）
4. **Keychain 凭据存储**（密码 / 私钥 / passphrase）
5. **自动重连**（exp backoff + UI 状态指示 + 新连接提示）
6. **SSH host key 校验**（KnownHostStore + TOFU + mismatch 阻断）

**附加交付**：

- DMG 签名 + notarized；Sparkle feed 能自动更新
- README 让新用户从下载到连上第一台机器
- 老 Tauri 版打 deprecation banner 引导迁移（D9 一次性例外）

### 6.5 SwiftPM 路线的工程细节

| 事项 | 处理 |
|------|------|
| `@main` SwiftUI App | SwiftPM `executableTarget` 原生支持 |
| C 互操作（libghostty） | 包成 `.xcframework`，用 `binaryTarget` |
| 资源 | `resources: [.process(...)]` |
| `.app` bundle | swift-bundler |
| 签名 + notarization | `Scripts/release.sh`：`codesign` + `xcrun notarytool` |
| DMG | `create-dmg`（Homebrew）|
| SwiftUI Preview | 可用，VS Code + Sourcekit-LSP 体验过得去 |

**工具链**：

```
- Swift 5.10+         (Xcode 15.4 toolchain；不强制装 Xcode IDE)
- Zig 0.13+           (libghostty 构建)
- swift-bundler       (brew or build from source)
- create-dmg          (brew install create-dmg)
- Apple Developer ID  (签名；notarization 需要 App Store Connect API key)
```

Apple Developer 账号 ($99/年) 是 ship DMG 给别人的硬要求；只给自己用可暂时跳过签名（用户每次右键打开）。

---

## 7. 未来阶段

### 7.1 v1.1 — 登录 + 主机跨端同步

| 模块 | 简述 |
|------|------|
| `ServerSyncClient` | 包装 oRPC HTTP（URLSession + Codable，或 swift-openapi-generator）|
| `AuthSession` | better-auth cookie/session（macOS 用 ASWebAuthenticationSession）|
| `HostSyncStore` | 在 SessionStore 上叠层：本地 JSON 主、server 同步副；冲突解决参考 `2026-03-05-ssh-host-cloud-migration-design.md` |

**v1.1 范围内（用 server 既有 API，不改 schema）**：登录、主机同步（`sshHost` router）、SFTP bookmarks 同步（`sftpBookmark` router，预留）。

**v1.1 不在范围**：

- **终端配置同步** —— 当前 `terminalSettingsRouter` 是 xterm-style 结构化白名单，与 D7 锁定的 Ghostty config 文本模型冲突。开放它需要 server schema 变更（新增字段或换语义），单独走一份 spec。本设计明确不在 v1.1。
- **凭据同步** —— 策略待 server 端是否引入端到端加密决定；v1.1 仍只用本地 Keychain。

**预估**：2-3 周业余时间。

### 7.1.1 终端配置同步（推迟，待单独设计）

触发条件：用户在多设备间需要共享 Ghostty config。

需要的工作：

1. Server schema 变更：`terminalSettings` 表新增 `ghosttyConfigText: text` 列，或将 `settingsJson` 重新解释为透明字符串载体
2. `terminalSettingsRouter` 新增 `getRawConfig` / `setRawConfig` procedure
3. 客户端 `TerminalSettingsSync` 模块上传/下载 Ghostty config 文本
4. 兼容老 Tauri 客户端（结构化字段）的过渡策略

不在本迁移设计范围内。

### 7.2 v2 — SFTP 全套

| 模块 | 简述 |
|------|------|
| `SFTPTransport` | NIOSSH 的 SFTP 子协议；评估 Citadel 提供更高层 API |
| `SFTPSessionManager` | 复用现有 SSH 连接复用 SFTP channel |
| `TransferQueue` | 上传/下载队列、并发、断点续传；从 `apps/web/src-tauri/src/sftp/transfer.rs` 翻译 |
| `RemoteFileBrowser` UI | **单栏（远端）** SwiftUI；不是双栏，没有常驻本地文件管理 |
| 上传源 | （a）`NSOpenPanel` 文件选取；（b）`NSDraggingDestination` 接 Finder 拖入；落到当前活跃 SFTP session 当前目录 |
| 下载目标 | `NSSavePanel` 选目录；或拖出到 Finder（`NSFilePromiseProvider`，可选）|
| SFTP bookmarks | 复用 server `sftp_bookmark` schema |

**关键纪律**：v2 不复活已砍掉的"本地文件浏览器面板"。本地侧只在上传/下载时短暂调用系统文件选择器，不做常驻的本地目录树。

**预估**：4-6 周业余时间。

### 7.3 v3+（探索）

- tmux 接管模式（libghostty 天然支持）
- 分屏（⌘D），libghostty 多 surface
- Quick Look 集成（远端文件预览）
- Spotlight 索引主机列表

---

## 8. 风险登记

| # | 风险 | 概率 | 影响 | 缓解 |
|---|------|------|------|------|
| R1 | libghostty 公开 C API 表面太小 / 不稳定 | **高** | **高** | Spike 头 5 天证伪；备选 = SwiftTerm |
| R2 | NIOSSH PTY 申请姿势难调（文档少）| 中 | 高 | Spike S3+S4 必须当天通过；备选 Citadel |
| R3 | swift-bundler 不维护 / 兼容性炸 | 低 | 中 | 备选：手写 `.app` 组装脚本（约半天）|
| R4 | macOS 签名/notarization 卡 Apple | 中 | 中 | Apple Developer 账号提前申请；先跑通流程，签名最后接 |
| R5 | libghostty Zig 工具链对 CI 友好度 | 中 | 低 | v1 不上 CI；ship 前手工出 release |
| R6 | 现有 Tauri 用户数据迁移 | 低 | 低 | Tauri 版主机数据存在 server（oRPC `sshHost`），v1.1 登录上线后自动可见；v1 期间老用户继续用 Tauri 版无干扰 |
| R7 | 业余时间 4-6 周拖到 12 周 | **高** | 中 | 接受现实；按 step 增量 ship；progress 文件每周回顾 |
| R8 | libghostty 公开 API 不稳定（Ghostty 官方 docs 明确说尚未保证 standalone API 稳定）| 中 | **中-高** | （a）submodule 锁定 commit hash；（b）任何 vendor 期间打的 patch 写进 `Vendor/ghostty/PATCHES.md`；（c）每次升 Ghostty 前在 clean machine 上跑一遍 release.sh + S1-S6 等价 smoke test；（d）v1 期间不主动升级；（e）准备好"维持当前 commit 不升 Ghostty"作为长期备选 |

**最该盯死**：R1（spike 5 天内决断）、R7（纪律 + 增量 ship）、R8（升级有 ritual）。

---

## 9. 验证 & 验收

整个迁移不算"完成"，直到：

- [ ] Phase 0 spike 6 项 S1-S6 全部通过
- [ ] Phase 1 v1 全部 10 个 step（1.0-1.9）完成
- [ ] DoD（§6.4）6 项 MVP + 附加交付逐条 ✅
- [ ] 老 Tauri 版 deprecation banner 已合并（D9 一次性例外）
- [ ] 作者本人 dogfood v1 至少一周，无阻塞性 bug；公开内测在 v1 ship 后视情况扩大

---

## 10. 附录

### 10.1 相关历史文档

- `2026-03-04-ssh-auto-reconnect-design.md` —— 重连状态机参照
- `2026-03-05-ssh-host-cloud-migration-design.md` —— v1.1 同步冲突解决参照
- `2026-03-05-sftp-design.md` —— v2 SFTP 参照
- `2026-04-15-cross-device-restore-internal-beta.md` —— 当前同步 beta 状态

### 10.2 关键外部依赖

- [Ghostty](https://ghostty.org/) (MIT) —— 终端渲染
- [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) (Apache 2.0) —— SSH 协议
- [swift-bundler](https://github.com/stackotter/swift-bundler) (MIT) —— SwiftPM `.app` 打包
- [Sparkle](https://sparkle-project.org/) (MIT) —— macOS 自动更新
