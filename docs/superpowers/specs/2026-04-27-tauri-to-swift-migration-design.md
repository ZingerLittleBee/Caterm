# Tauri → Swift/SwiftUI + libghostty 迁移设计

**日期**：2026-04-27（含 Phase 0 spike 后修订）
**状态**：设计已批准；Phase 0 spike 已完成（详见 `2026-04-27-spike-findings.md`）；架构已根据 spike 调整为"libghostty + system /usr/bin/ssh subprocess + askpass-via-Keychain"；待写 Phase 1 实施计划
**进度跟踪**：`docs/superpowers/plans/2026-04-27-swift-migration-progress.md`

**关键修订记录**：

- v0（2026-04-27）：原始设计假设 swift-nio-ssh 喂字节给 libghostty
- v1（2026-04-27 spike 后）：libghostty 公开 C API 不接受外部字节注入，改成把 ssh 作为 libghostty 的 subprocess。删除 SSHTransport / KnownHostStore / BoundedByteChannel；新增 SSHCommandBuilder + AskpassHelper 二进制。凭据存储 = `CredentialSource` enum 三路（password / keyFile+passphrase / agent）。涉及 §3 / §4 / §6 / §7 重写，§D4 / D12 / D14 修订

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
| D4 | SSH 传输 = **系统 `/usr/bin/ssh` 子进程**（libghostty 自己 spawn）| Phase 0 spike 发现 libghostty 公开 C API 没有外部字节注入入口（surface 拥有 PTY 端到端），所以 swift-nio-ssh 在 v1 不可行；改成把 `ghostty_surface_config_s.command = "/usr/bin/ssh ..."` 直接交给 libghostty。**swift-nio-ssh 推迟到 v2 SFTP** —— 那时确实需要 Swift 侧 SSH 控制 |
| D5 | 构建系统 = **纯 SwiftPM** | 不引入 `.xcodeproj`；`.app` 用 swift-bundler 打包 |
| D6 | 最低 macOS 版本 = **14.0** | 不兼容 Ventura 及以下 |
| D7 | 终端配置模型 = **Ghostty 原生 schema** | 客户端本地直接读写 Ghostty config 文件，不做映射；**server 端跨端同步终端配置 = 推迟**（现有 `terminalSettingsRouter` 是结构化 Zod 白名单，无法承载任意 Ghostty config 文本，开放它需要单独 server schema 设计） |
| D8 | 新代码位置 = **`apps/macos/`** | 与 `apps/web`（Tauri）和 `apps/server` 平级 |
| D9 | 旧 Tauri 客户端 = **冻结**（一次性例外）| 不再维护（含 bug fix）；**唯一允许的变更**：在 v1 ship 前后，单次提交往 Tauri 版加 deprecation banner 引导迁移；之后彻底冻结 |
| D10 | Server 端 = **完全不动** | v1.1 复用现有 oRPC API（仅 `sshHost` + `auth`）；终端配置同步因 schema 限制推迟，不在 v1.1 |
| D11 | 执行策略 = **Approach 1**（spike → 垂直切片） | 5 天 spike 验证后再投入 v1 |
| D12 | v1 凭据 = **`CredentialSource` enum 三路并存** | (a) `.password(KeychainRef)` (b) `.keyFile(path, passphraseRef?)` (c) `.agent`。前两种共用一个 askpass 二进制（`SSH_ASKPASS=<bin> SSH_ASKPASS_REQUIRE=force`），从 macOS Keychain 读 secret 写 stdout；agent 路径不挂 askpass、不写 IdentityFile，纯 ssh-agent socket。v1 无同步；server 端不参与凭据流 |
| D13 | v1 不做的功能（推后到 v1.1/v2） | 跨端主机同步（v1.1）、终端配置同步（推迟）、SFTP（v2）、远端文件浏览器（v2）、拖拽上传（v2）、bookmarks（v2）；**永久砍掉：本地文件浏览器面板** |
| D14 | **SSH host key 校验**（v1 必须）= 委托给系统 ssh | 系统 `ssh` 自带 known_hosts + StrictHostKeyChecking。v1 用 `StrictHostKeyChecking=accept-new`（首次自动 TOFU + 后续 mismatch 阻断）+ `UserKnownHostsFile=~/Library/Application Support/Caterm/known_hosts`（与用户既有 `~/.ssh/known_hosts` 隔离，避免误污染）。Caterm 不实现 KnownHostStore actor、不实现 TOFU 弹窗 UI（v1）；mismatch 由 ssh 自己 abort 并把警告打到 surface，**绝不 accept-all**。v1.1+ 视情况加 Swift 侧 TOFU 对话框（用 askpass-style hook 拦截）|

### 砍掉的功能（不再纳入路线图）

- **本地文件浏览器面板**（Tauri 版的 11 个 `local_fs_*` 命令对应的双栏 UI）—— 用户确认不再需要
- 注意：v2 SFTP 仍需要本地文件**选取**（NSOpenPanel）和 **Finder 拖入**（NSDraggingDestination）作为上传源，但不再有常驻的"本地文件管理"面板

---

## 3. 架构

### 3.1 进程结构

单 Swift 主进程 + 每个 SSH session 一个 ssh 子进程（由 libghostty 自己 spawn 进 PTY）。askpass 是 Caterm 自己的小辅助二进制，按需 fork/exec（每次 ssh 启动时）。

```
┌─────────────────────────────────────────────────────────┐
│  Caterm.app  (Swift main process, macOS-only)           │
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
│  │  SSHCommandBuilder                              │    │
│  │  - Host + CredentialSource enum → argv string   │    │
│  │  - 设 SSH_ASKPASS / IdentityFile / 选项          │    │
│  │  - 命令最终交给 ghostty_surface_config_s.command│    │
│  └────┬────────────────┬────────────────┬─────────┘     │
│       │                │                │                │
│  ┌────▼────────┐ ┌─────▼─────────┐ ┌───▼───────────┐    │
│  │ Keychain    │ │ Askpass       │ │ ConfigStore   │    │
│  │ Store       │ │ Helper Binary │ │ (Ghostty cfg) │    │
│  │ (凭据)      │ │ (子目标产物)   │ │               │    │
│  └─────────────┘ └───────────────┘ └───────────────┘    │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │  libghostty.xcframework (vendor 自构建, Zig)     │    │
│  │  ─ 每个 surface 自己 fork-exec /usr/bin/ssh       │    │
│  │  ─ PTY、stdin、stdout、resize、host key 校验全包  │    │
│  │  ─ Swift 只负责 NSView 容器 + key event 转发     │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
                  │
                  │ (ssh 子进程，每个 surface 一个)
                  ▼
        /usr/bin/ssh ─ PTY ─ TCP ─ remote sshd
                  │
                  └─ 启动时若需要 secret，会 exec SSH_ASKPASS 指向的 askpass binary
                     askpass binary 用 SecKeychainFindGenericPassword 读 Keychain → 写 stdout

           [v1 不接 server；v1.1 起加 ServerSyncClient]
```

### 3.2 模块划分

| 模块 | 职责 | 依赖 | 测试 |
|------|------|------|------|
| **UI 层** | SwiftUI 视图 + AppKit window/tab；ConnectDialog 让用户选 `CredentialSource` | TerminalEngine, SessionStore | 不测；后期 XCUITest |
| **TerminalEngine** | 包装 libghostty C API；surface 创建/销毁、key 事件转发、resize；**libghostty 自己拥有 PTY**，Swift 不接触字节流 | libghostty (C) | 烟雾测试，信任 libghostty |
| **SSHCommandBuilder** | `Host + CredentialSource` → `[String]` argv → 单字符串 `command`（由 libghostty `posix_exec` 跑）；负责 `-p`、`-i`、`-o StrictHostKeyChecking=accept-new`、`-o UserKnownHostsFile=...`、`-o BatchMode=...` 等 ssh 选项；为非 agent 路径设置 `SSH_ASKPASS` / `SSH_ASKPASS_REQUIRE=force` 环境变量并把 host id 透传给 askpass（`CATERM_HOST_ID=<uuid>`）| 无（纯字符串构造）| **必须**单元测试：三种 enum 路径分别断言 argv 形态；含 shell quoting / 特殊字符 / 端口非 22 / IdentityFile 路径含空格等 |
| **AskpassHelper** | 独立 SwiftPM `executableTarget`，编译为 `caterm-askpass` 小二进制（约 200-400 行）；运行时由 ssh `exec`，从 env `CATERM_HOST_ID` + `SSH_ASKPASS_PROMPT` 选 Keychain key（`caterm.host.<id>.password` / `.keyPassphrase`），调 macOS Security framework 读 secret，写 stdout，退出码 0 | macOS Security framework | 单元测试：mock Keychain access；端到端集成留给 §6.3 Docker smoke |
| **SessionStore** | 主机列表（持久化 JSON）、tab 状态、活跃连接登记 | KeychainStore | 单元测试 |
| **KeychainStore** | 凭据读写；key 命名 `caterm.host.<id>.password` / `.keyPassphrase`；私钥**文件路径**不进 Keychain（敏感性属于文件本身权限） | macOS Security framework | 单元测试 |
| **ConfigStore** | 加载/保存 Ghostty 配置文件 + 应用配置 | 文件系统 | 单元测试 |

**v1 没有的东西**（spike 之前的 spec 写过，现在删掉）：

- ~~`SSHTransport` (swift-nio-ssh)~~ —— libghostty spawn ssh，Swift 不参与协议
- ~~`KnownHostStore`~~ —— 由系统 ssh 的 `~/Library/Application Support/Caterm/known_hosts` 接管
- ~~`BoundedByteChannel` 背压~~ —— libghostty 的 PTY 内部已经是有界的（kernel 自己背压），Swift 侧无字节流就没有这个问题
- ~~NIOSSH `EmbeddedChannel` 测试~~ —— 不再有 NIO 代码可测

### 3.3 关键边界 & 并发模型

**模块边界**
- **TerminalEngine 不知道 SSH** —— 只知道"创建一个 surface 并把这个 command 字符串扔给它跑"；未来加本地 shell 是把 `command = nil` 传过去（走默认 shell），改动几行
- **SSHCommandBuilder 是纯函数** —— 无状态、无 I/O，输入是 Host + CredentialSource，输出是字符串；测试零依赖
- **SessionStore 是 UI 唯一数据源** —— ObservableObject；UI 不绕过它直接 spawn surface

**线程模型**

| 层 | Executor | 备注 |
|----|----------|------|
| UI / SwiftUI 视图 / NSView 操作 | `@MainActor` | 强制约束 |
| `ghostty_surface_*` 调用（创建 / key / resize / focus） | `@MainActor` | libghostty surface 操作非线程安全，统一在主线程 |
| `TerminalEngine` 内部状态 | `@MainActor` | 简化模型 |
| `SessionStore` ObservableObject | `@MainActor`（发布 publish） | 后台事件用 `Task { @MainActor in ... }` 切回 |
| `KeychainStore` / `ConfigStore` 文件 I/O | 各自 `actor` 隔离 | 不阻塞 UI |
| `SSHCommandBuilder` | 纯同步函数，无 actor | 无 I/O |
| ssh 子进程 | 操作系统调度 | libghostty 的 PTY 线程负责读写；Swift 完全不参与 |

**关键纪律**：

- 不再有"NIO event loop"概念；Swift 进程内只有 MainActor + 几个文件 I/O actor
- libghostty 内部跑了什么线程是它的实现细节；只有 `ghostty_surface_*` 调用上 MainActor 这一条公开纪律
- ~~`AsyncThrowingStream<Data>` / `BoundedByteChannel`~~ —— 整套删除：v1 没有 Swift 侧字节流

### 3.4 工程脚手架

```
apps/macos/
├── Package.swift                      # SwiftPM 主入口；含 caterm + caterm-askpass 两个 executable
├── Sources/
│   ├── Caterm/                        # 主 app
│   │   ├── CatermApp.swift            # @main, WindowGroup
│   │   └── Views/...
│   ├── CatermAskpass/                 # askpass 二进制（独立 executableTarget）
│   │   └── main.swift                 # 200-400 行：env → Keychain key → 写 stdout
│   ├── TerminalEngine/                # libghostty bridge
│   │   ├── GhosttySurface.swift
│   │   └── module.modulemap
│   ├── SSHCommandBuilder/             # 纯函数：Host + CredentialSource → command string
│   │   └── SSHCommandBuilder.swift
│   ├── SessionStore/
│   ├── KeychainStore/
│   └── ConfigStore/
├── Tests/
│   ├── SSHCommandBuilderTests/        # 三种 enum 路径的 argv 断言
│   ├── KeychainStoreTests/
│   ├── SessionStoreTests/
│   └── ConfigStoreTests/
├── Vendor/
│   └── ghostty/                       # git submodule
├── Frameworks/
│   └── GhosttyKit.xcframework/        # build script 产物（gitignored）
└── Scripts/
    ├── build-libghostty.sh            # 调 zig build → .xcframework
    └── release.sh                     # swift-bundler + codesign + notarytool + create-dmg
                                       #   注意：askpass 也要 codesign + 跟主 app 同 team id，
                                       #   否则 macOS 不会让它读 Keychain（access group ACL）
```

---

## 4. 数据流 & 关键交互

### 4.1 连接流

```
User → ConnectDialog
   │  (host info + CredentialSource pick)
   ▼
SessionStore.openSession(hostId)
   │
   ▼
SSHCommandBuilder.build(host, credSource) → commandString
   │  (commandString 见下方三种形态)
   ▼
TerminalEngine.openSurface(command: commandString, env: extraEnv)
   │
   ▼
ghostty_surface_new(...) (libghostty 内部)
   │  posix_exec ─►  /usr/bin/ssh -p PORT -i KEYPATH … user@host
   │                  │
   │                  ├─ 启动时 ssh 读 ~/Library/Application Support/Caterm/known_hosts
   │                  │   ├─ host 已知 + key 匹配 → 继续
   │                  │   ├─ host 已知 + mismatch → ssh 自己 abort，错误打到 surface（红字）
   │                  │   └─ host 未知（accept-new）→ 自动接受并写入 known_hosts；首次有提示行
   │                  │
   │                  ├─ password / passphrase 路径：ssh exec $SSH_ASKPASS
   │                  │   askpass binary 用 CATERM_HOST_ID 查 Keychain 写 stdout → ssh 收到
   │                  │
   │                  └─ ssh-agent 路径：ssh 自己跟 agent socket 谈（无 askpass、无 IdentityFile）
   │
   ├─ surface 创建成功 → SessionStore.markConnected(sessionId) → UI tab 变绿
   │  (注：libghostty 创建 surface 是异步的——subprocess 还没握完手 surface 就返回了；
   │   "connected" 的判定其实是 surface 持续有 stdout 输出，不是 surface_new 成功；
   │   §4.3 状态机会再处理这个细分)
   │
   └─ surface 创建失败（极少；通常是参数错误）→ SessionStore.markFailed
```

**三种 commandString 形态**（SSHCommandBuilder 输出）。libghostty `surfaceConfig.command` 是 argv 字符串（不经 shell 解析），环境变量通过 `surfaceConfig.env_vars` 字段（一个 `(key, value)` 列表）独立传，**不**塞进 command。

```
# (a) password
command  = "/usr/bin/ssh -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/Users/.../Caterm/known_hosts \
            -o NumberOfPasswordPrompts=1 \
            -p 22 user@host"
env_vars = [
  "SSH_ASKPASS"        = "/path/to/Caterm.app/.../caterm-askpass",
  "SSH_ASKPASS_REQUIRE"= "force",
  "DISPLAY"            = ":0",          # ssh 触发 askpass 需要它非空
  "CATERM_HOST_ID"     = "<uuid>",
  "CATERM_ASKPASS_KIND"= "password",
  "LANG"               = "C",
]

# (b) keyFile + 可选 passphrase
command  = "/usr/bin/ssh -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/Users/.../Caterm/known_hosts \
            -o IdentitiesOnly=yes \
            -i '/Users/.../.ssh/id_ed25519' \
            -p 22 user@host"
env_vars = [
  "SSH_ASKPASS"        = "/path/to/Caterm.app/.../caterm-askpass",
  "SSH_ASKPASS_REQUIRE"= "force",
  "DISPLAY"            = ":0",
  "CATERM_HOST_ID"     = "<uuid>",
  "CATERM_ASKPASS_KIND"= "passphrase",
  "LANG"               = "C",
]
# (passphrase 为空时 ssh 不会调 askpass；env vars 留着无害)

# (c) ssh-agent
command  = "/usr/bin/ssh -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/Users/.../Caterm/known_hosts \
            -p 22 user@host"
env_vars = [
  "LANG" = "C",
]
# (无 SSH_ASKPASS / 无 -i / 不写 IdentitiesOnly；ssh-agent 走继承自父进程的 SSH_AUTH_SOCK)
```

**注意**：

- `SSH_AUTH_SOCK`（agent 路径用）由 macOS launchd 自动注入到所有用户进程；libghostty 把它继承下来给 ssh —— Caterm 不需要显式传
- `IdentitiesOnly=yes` + `-i` 的组合保证不误用 ssh-agent 里的别的 key（避免"agent 里有 5 把 key 但用户为这台机器明确选了 id_ed25519"导致试错失败被锁）
- keyPath 含空格时必须 quote（SSHCommandBuilder 用 `[String]` argv 列表 + 单引号 quote helper 拼回字符串）

**Host key 校验纪律**：

- v1 用 `StrictHostKeyChecking=accept-new`（OpenSSH 7.6+ 默认行为之一）：未知 host 自动接受 + 写 known_hosts；mismatch 阻断。**绝不**用 `accept-all` / `=no` —— 这两个等于关掉校验
- `UserKnownHostsFile` 指向 Caterm 自己的文件，与用户 `~/.ssh/known_hosts` 隔离 —— 用户用别的工具（iTerm / Ghostty / 命令行 ssh）连同一台机器不污染对方
- v1 不实现 Swift 侧 TOFU 弹窗（妥协：首次连接的接受是隐式的，体验比 ssh 命令行多不了多少；mismatch 场景由 ssh 自己把 `Host key verification failed` 打到 surface 红字告警）
- v1.1+ 如要做 Swift TOFU 弹窗：写一个 askpass-style 二进制（`KnownHostsCommand` / `UserKnownHostsFile=/dev/null` + 自定义 hook），把 fingerprint 弹给用户。**不在 v1**

**Connect 失败的"连不上"分类**（影响重连状态机）：

| 失败模式 | 触发条件 | UI 处理 |
|---------|---------|---------|
| auth 失败（密码错 / 私钥拒绝）| ssh 退出码 5 或 255 + stderr 含 `Permission denied` | tab 变红；提示重新填凭据；**不重连** |
| 网络不通（DNS / 拒连）| ssh 退出码 255 + stderr 含 `Could not resolve` / `Connection refused` | tab 变黄；进入 §4.3 重连状态机 |
| host key mismatch | stderr 含 `REMOTE HOST IDENTIFICATION HAS CHANGED` | tab 变红；停止重连；提示用户手动处理 known_hosts |
| 远端正常断开（`exit`）| ssh 退出码 0 | tab 变灰；提示"会话结束"；**不重连** |
| 网络中途断 | ssh 长跑后非 0 退出 | tab 变黄；进入 §4.3 重连状态机 |

**纪律**：失败模式判定由 SessionStore 监听 libghostty 的 child-exit callback 完成；ssh 退出码 + stderr 的最后几行写进 SessionStore，UI 据此分类。退出码不可靠时 fallback 到 stderr 文本匹配（English locale 强制 `LANG=C`）。

### 4.2 终端 I/O

由于 libghostty 拥有 PTY 端到端，**Swift 进程内不存在远端 stdout/stdin 字节流**。I/O 在 OS 层（PTY、TCP、ssh 子进程）完成，Swift 只负责窗口事件转发。

```
[远端 stdout]                          (ssh 子进程 ↔ libghostty PTY，OS 层)
    │
    ▼
libghostty 内部 PTY reader  →  VT 解析 → GPU 渲染（Metal layer 直绘到 NSView）
    │
    └─（Swift 看不到字节，也不需要看到）

[用户键盘 / paste]                                       (@MainActor)
    │
    ▼
NSResponder keyDown
    │
    ▼
TerminalEngine.handleKey(NSEvent)
    │  ├─ 构造 ghostty_input_key_s（keycode、mods、text、unshifted_codepoint）
    │  └─ ghostty_surface_key(surface, key)
    │
    ▼
libghostty 内部把按键序列化为字节 → 写 PTY master → ssh stdin → 远端

[用户 paste（⌘V）]                                       (@MainActor)
    │
    ▼
NSResponder paste(_:) 或 ghostty 自己的 binding
    │
    ▼
ghostty_surface_paste_text(...)  （libghostty 内部分块写 PTY，已自带防爆）
```

**关键纪律**：

1. **Swift 不接触 SSH 字节** —— v1 没有 `feed(bytes:)` 这种 API，未来也不打算加（除非 v2 SFTP 需要分离的传输层）。这是 spike 发现的 libghostty 1.3.x 公开 API 限制
2. libghostty 既是渲染器也是 VT 解析器
3. 高吞吐场景（`yes` / `cat huge.log`）的背压由 PTY → TCP socket → 远端的 OS-level 流量控制天然处理；libghostty 自己也有读取节流（实现细节不暴露）
4. paste 防爆由 libghostty 自己负责（`ghostty_surface_paste_text` 文档中提到）
5. **resize**：`NSView.setFrameSize` → `ghostty_surface_set_size(surface, w, h)` → libghostty 内部 `ioctl(TIOCSWINSZ)` 给 PTY → ssh 把 `window-change` 信号传给远端 sshd → 远端 `stty size` 同步。Swift 这一侧只调一次 set_size

**已删除的概念**（spike 之前的 spec 写过）：

- ~~`BoundedByteChannel`~~ —— 没有 Swift 字节流就没有背压队列
- ~~`AsyncThrowingStream<Data>`~~ —— 同上
- ~~NIOSSH `allowRemoteHalfClosure`~~ —— 这是 NIO 概念，v1 不存在 NIO
- ~~stdin 4 KB 分块 await flush~~ —— libghostty 内部已处理

### 4.3 自动重连状态机

由于"重连"在新架构下是"销毁旧 surface + 用同一 command 创建新 surface"，实际控制点在 SessionStore（不是 SSHTransport，那个不存在了）。

```
       ┌──────────┐
       │  Idle    │
       └─────┬────┘
             │ user connect
             ▼
       ┌──────────┐  surface stdout 收到字节  ┌──────────────┐
       │Connecting├──────────────────────────→│  Connected   │
       └─────┬────┘                           └──────┬───────┘
             │ ssh exit (auth fail / DNS / refused)  │ ssh exit (网络断 / EOF)
             │ host key mismatch / 用户 exit         │
             ▼                                       ▼
       ┌──────────┐                           ┌──────────────┐
       │  Failed  │←──────────────────────────│ Reconnecting │
       └──────────┘  退出码=auth/mismatch/0    └──────┬───────┘
       (终止；用户手动重连)                          │ exp backoff
                                                     │ 1s, 2s, 5s, 10s, 30s (cap)
                                                     │ 5 次后停止
                                                     ▼
                                          销毁旧 surface + 创建新 surface
                                          (同一 commandString)
                                          → 重新进入 Connecting
```

**Connected 判定**：libghostty `surface_new` 返回成功后实际 ssh 还在握手。"真正连上"的信号取自 surface 是否有过 stdout 输出（通常远端 shell 会打 prompt，几百 ms 内就有）。SessionStore 在 surface 创建后启动一个 5s 超时计时器：超时前看到字节 → Connected；超时前 ssh 退出 → 进 Failed/Reconnecting；超时还没字节也没退出 → 继续等（不强行切状态）。

**复用语义**：参照 `2026-03-04-ssh-auto-reconnect-design.md`，不重新设计交互。

**重连语义边界（重要）**：

- 重连 = **重启 ssh 子进程，建立新 SSH session**；不是恢复原远端进程
- 原远端 shell 上跑的 vim/tmux/long-running command **全部已死**（除非用户在 tmux/screen 里）
- UI 必须**显式提示新连接已建立**：销毁旧 surface 时 scrollback 写一行 `\r\n[Caterm: 连接断开 - 自动重连中]\r\n`，新 surface 创建后第一次 stdout 之前 surface 处于明显"loading"视觉状态（spinner overlay）。**不允许**让用户误以为是同一 session 延续
- scrollback 不跨 surface 转移（libghostty 也没这个 API），断了就断了
- 这条纪律的目的：**代码不能撒谎**。一旦 UI 暗示 "session resumed"，后续就要被迫层层补漏（"为啥我的 vim 没了"），技术债复利

### 4.4 Tab 生命周期

- **新 tab** = `SessionStore.openSession()` → SSHCommandBuilder 拼 command → libghostty surface 创建 → 立即出现 "Connecting…" tab；Connected 状态异步回填（见 §4.3）
- **关 tab** = `ghostty_surface_free(surface)` → libghostty 自己 SIGHUP/SIGTERM ssh 子进程 → 从 SessionStore 移除
- **窗口关闭** = 所有 tab 顺序关闭，KeychainStore/ConfigStore 各自 flush；app 退出时把 `ghostty_app_free` 调一次

---

## 5. Phase 0 — Spike 详细规格

> **状态：2026-04-27 已完成。S1-S6 全部通过。**详细发现与架构调整记在 `2026-04-27-spike-findings.md`。下面是 spike 启动前的原始规格，保留作为历史参考。

**目标**：3-5 天证明"libghostty + Swift 桌面端能跑 SSH 终端"链路可行；产出可丢弃。**实际过程中发现 NIOSSH 路线不可行**（libghostty 没有外部字节注入入口），spike S3-S6 改用 `command="/usr/bin/ssh ..."` 让 libghostty 自己 spawn ssh，路径成立。

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
| —— | **host key 校验** —— spike 阶段直接 accept-all，源码注明 `// TODO(step-1.2): 由 KnownHostStore 接管`（`step-1.2` 指 §6.1 的 Step 1.2，**不是版本号 v1.2**）；不算 S1-S6 验收项；**凭据写源码同样禁止** |

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
| 1.0 | 把 spike 代码全删了，重起干净项目（保留构建脚本、Vendor/ghostty submodule、Frameworks 目录的 .gitignore）| 0.5 天 | 干净 baseline |
| 1.1 | TerminalEngine：libghostty surface 包装（非 spike 版的整洁 Swift API）、NSView 容器、key event 转发、resize、close 处理 | 2-3 天 | 单 surface 干净跑起来 |
| 1.2 | SSHCommandBuilder：纯函数 + 单元测试覆盖三种 enum 路径（password / keyFile+passphrase / agent）；含 shell quoting / 端口非 22 / 路径含空格 / `IdentitiesOnly=yes` 等边界 | 1.5 天 | 拼 ssh 命令字符串 |
| 1.3 | **AskpassHelper 二进制**（独立 `executableTarget` `caterm-askpass`）：从 env `CATERM_HOST_ID` + `CATERM_ASKPASS_KIND` 选 Keychain key → 调 Security framework 读 secret → 写 stdout；含 codesign 配合 access group ACL；端到端跑通 `ssh + SSH_ASKPASS=/path/to/caterm-askpass` 拿到密码登录 | 2-3 天 | 凭据自动注入 |
| 1.4 | 单 tab 完整 connect 流：硬编码一台主机（仍读 `.spike.local.json` 风格）→ SSHCommandBuilder → libghostty surface → Connected/Failed 判定（§4.3） | 1.5 天 | 端到端 v0 |
| 1.5 | NSWindow tab（多 tab）+ ⌘T 新 / ⌘W 关 + 关闭 tab 触发 surface free（libghostty 自己 SIGHUP ssh）| 3 天 | 多 tab |
| 1.6 | HostListSidebar UI + 添加/编辑/删除主机表单 + ConnectDialog 让用户选 `CredentialSource`（密码 / 私钥 / agent）+ 本地 JSON 持久化 | 4-5 天 | 不再硬编码 |
| 1.7 | KeychainStore 接入（v1 凭据存储）：写入路径 = ConnectDialog 提交时；读路径 = AskpassHelper 二进制；删除 = 删主机时按 `caterm.host.<id>.*` 通配 | 2 天 | 凭据安全 |
| 1.8 | 自动重连状态机（§4.3）+ UI 状态指示（绿/黄/红/灰）+ "新连接已建立" 视觉提示 + 失败模式分类（§4.1）| 3-4 天 | 网络抖动可恢复 |
| 1.9 | 应用配置：直接读写 Ghostty config 文件（`~/Library/Application Support/Caterm/config`）；最小 UI 暴露"打开配置文件" | 1 天 | 主题/字体走 Ghostty |
| 1.10 | 打磨：菜单栏、菜单项、快捷键（⌘N 新窗口）、关于面板 | 2-3 天 | 像个 Mac app |
| 1.11 | 内测分发：`Scripts/release.sh`（swift-bundler + codesign 主 app + askpass + notarytool + create-dmg）+ Sparkle + Tauri 版 deprecation banner（D9 一次性例外）| 3-4 天 | 可分发 |

**累计**：约 25-31 个工作日。业余 1 小时/天 → 5-9 周；业余 4 小时/周末 → 6-11 周。

**与 spike 前估算的差异**：原 spec 1.1 (3-4 天 NIO 集成) + 1.2 (2-3 天 KnownHostStore) = 5-7 天，被替换为新 1.1-1.4（共 7-10 天）—— 多出来的 ≈2-3 天就是 D12 决策时说的"askpass 二进制 + Keychain 读取逻辑"成本。

### 6.2 数据模型（v1）

**Host**（本地 JSON，路径 `~/Library/Application Support/Caterm/hosts.json`）：

```swift
struct Host: Codable, Identifiable {
    let id: UUID
    var name: String
    var hostname: String
    var port: Int                       // default 22
    var username: String
    var credential: CredentialSource    // 见下
    var createdAt: Date
    var updatedAt: Date
}

enum CredentialSource: Codable {
    /// 用密码：Keychain 里有 caterm.host.<id>.password
    case password

    /// 用私钥文件 + 可选 passphrase
    /// keyPath 是绝对路径（用户在 ConnectDialog 里选）；
    /// hasPassphrase=true 时 Keychain 里有 caterm.host.<id>.keyPassphrase
    case keyFile(keyPath: String, hasPassphrase: Bool)

    /// 用现有 ssh-agent；不存任何凭据，也不指定 IdentityFile
    case agent
}
```

**Keychain key 命名规范**：

- `caterm.host.<id>.password` —— `.password` 路径用
- `caterm.host.<id>.keyPassphrase` —— `.keyFile` 路径且 `hasPassphrase=true` 用
- `.agent` 路径**不写**任何 Keychain 项

**Keychain access group**：单一 group `<TEAM_ID>.caterm.shared`，主 app 和 askpass 二进制都加这个 entitlement，确保 askpass 能读到主 app 写的 secret。

**TerminalSettings**：直接 Ghostty config 文件，不二次包装。

- 路径：`~/Library/Application Support/Caterm/config`（Caterm 独立维护，不读取也不写入 Ghostty 自己的 `~/.config/ghostty/config`，避免与用户已有 Ghostty 配置互相污染）
- 不存在时由 ConfigStore 写入一份默认值
- v1 不提供配置 UI，仅暴露"打开配置文件"菜单项；用户用文本编辑器改

**KnownHosts**（系统 ssh 自己维护，Caterm 不读不写）：

- 路径：`~/Library/Application Support/Caterm/known_hosts`（通过 ssh `-o UserKnownHostsFile=...` 指定）
- 格式：OpenSSH `known_hosts` 标准（不需要 Caterm 自己解析）
- 由系统 ssh 用 `StrictHostKeyChecking=accept-new` 模式自动维护
- v1 不提供 known_hosts 管理 UI；如需"忘记主机"，文档指引用户用 `ssh-keygen -R hostname -f <path>`

### 6.3 测试策略

| 层 | 测什么 | 怎么测 |
|----|-------|--------|
| **SSHCommandBuilder** | 三种 `CredentialSource` enum 路径分别拼对 argv；端口非 22 / 含空格的 key 路径 / IdentitiesOnly / StrictHostKeyChecking 选项；环境变量正确（`SSH_ASKPASS` / `CATERM_HOST_ID` / `CATERM_ASKPASS_KIND` / `LANG=C`）| 单元测试，纯 Swift，零依赖；**硬要求**（凭据流安全的核心防线）|
| **AskpassHelper** | 给定 env → 选对 Keychain key；命中/未命中分支；输出格式（密码末尾换行处理符合 ssh 行为）；非法/缺失 env 时退出码非 0 不挂 | 单元测试 + mock Keychain（用 ephemeral access group） |
| **端到端 SSH 集成** | 真实 auth 三路（password / keyFile / agent）、PTY、resize、EOF、host key accept-new、host key mismatch 行为 | **Docker `linuxserver/openssh-server` 容器**，本地（开发机/dogfood）手动测试脚本拉起；v1 不上 CI（与 R5 一致），ship 前手动跑完整 matrix；spike 已验证 password 路径可行，留下 `apps/macos/Tests/Manual/spike-smoke.md` 文档化步骤 |
| **SessionStore** | host CRUD、tab 状态、CredentialSource enum 持久化与往返、Connected/Failed/Reconnecting 状态机转换 | 单元测试，纯 Swift |
| **KeychainStore** | 读写 / 不存在 / 重复写 / 删除（按 host id 通配）| 单元测试，target 单独 keychain access group |
| **ConfigStore** | 默认 config 写入 / 读取已有 / 文件权限（0600）| 单元测试 |
| **TerminalEngine** | 不测内部（信任 libghostty） | 烟雾测试：能创建 surface 即可（spike 已验证）|
| **UI** | 不测 | 手测；后期 XCUITest |
| **重连状态机** | 状态转换矩阵（含 5s Connected 判定超时、"提示新连接已建立"事件、auth-fail/mismatch 不重连）| 单元测试，**硬要求** |
| **失败模式分类** | ssh 退出码 + stderr 文本匹配 → `FailureKind` enum；含 `LANG=C` 假设 | 单元测试，纯函数 |

**实现注意事项（写代码时盯死）**：

1. `ghostty_surface_*` 调用必须在 `@MainActor`
2. ssh 子进程的 stderr **必须以 `LANG=C` 启动**（SSHCommandBuilder 写到 env），否则非英语 locale 下 stderr 文本匹配会失效（`Permission denied` / `REMOTE HOST IDENTIFICATION HAS CHANGED` 是英文模式的固定字串）
3. AskpassHelper 二进制和主 app **必须用同一 Apple Team ID 签名 + 同一 Keychain access group entitlement**（`<TEAM_ID>.caterm.shared`），否则 Keychain ACL 拒绝 askpass 读
4. `command` 字符串传给 libghostty 时是 `posix_exec` 风格 —— shell metachar 不会展开。如果要传环境变量，要么 (a) 用 `surfaceConfig.env_vars` 字段（最干净），要么 (b) 把 `env KEY=val /usr/bin/ssh ...` 包一层。**不要**塞进 command 内部用 shell 拼，会让 quoting 复杂度爆炸
5. SessionStore 监听 surface child-exit 的回调路径需要在 1.4 step 内验证（libghostty runtime callback 里有 `close_surface_cb`，但 ssh 进程退出是否触发它要确认；如未触发，可能要轮询 surface state 查询 API）—— 这是 spike 没覆盖的"已知未知"
6. SSHCommandBuilder 拼路径含空格的 keyPath 时必须 quote 正确（用 `[String]` 形式构造 argv，最后一刻用 shell-quoting helper 拼回字符串；不要直接字符串插值）

### 6.4 v1 完成标准（DoD）

**6 项 MVP 功能可用**（不是"通了"，是"日常用一周不痛"）：

1. **SSH 连接**：三路 auth 全可用（密码 / 私钥+passphrase / ssh-agent 兜底），ConnectDialog 让用户选
2. **libghostty 渲染** + 多 tab 切换
3. **主机列表**（添加/编辑/删除 + 本地 JSON 持久化 + CredentialSource 持久化）
4. **Keychain 凭据存储**（密码 / passphrase；agent 路径不写 Keychain），由 AskpassHelper 二进制读取
5. **自动重连**（exp backoff + UI 状态指示 + 新连接提示 + 失败模式分类）
6. **SSH host key 校验**：用系统 ssh `accept-new` 模式 + Caterm 自己的 known_hosts 文件；mismatch 由 ssh 自己 abort

**附加交付**：

- DMG 签名 + notarized；**主 app + askpass 二进制都签名（同 Team ID + 同 access group entitlement）**；Sparkle feed 能自动更新
- README 让新用户从下载到连上第一台机器；含三种 auth 选择的截图说明
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

**v1.1 范围内（用 server 既有 API，不改 schema）**：登录、主机同步（`sshHost` router）。

**v1.1 不在范围**：

- **终端配置同步** —— 当前 `terminalSettingsRouter` 是 xterm-style 结构化白名单，与 D7 锁定的 Ghostty config 文本模型冲突。开放它需要 server schema 变更（新增字段或换语义），单独走一份 spec。本设计明确不在 v1.1。
- **SFTP bookmarks 同步** —— bookmarks 本身是 v2 SFTP 才用到的功能，v1.1 客户端不存在 SFTP UI，没意义提前同步。`sftpBookmark` router 在 server 端继续存在但 Swift v1.1 不调用；v2 实现 SFTP 时再接。
- **凭据同步** —— 策略待 server 端是否引入端到端加密决定；v1.1 仍只用本地 Keychain。

### 7.1.2 v1.1 主机同步与凭据的明确边界

`sshHost` 表结构（见 `packages/db/src/schema/ssh-host.ts`）含 `password` / `privateKey` / `keyPassphrase` 三个凭据列。**Swift v1.1 不使用这三列**，纪律如下：

| 操作 | 客户端行为 |
|------|----------|
| **从 server 拉主机列表** | 调用 **`sshHost.list`**（只返回 metadata，无凭据字段）；**禁止** 调用 `sshHost.getById`（它会解密返回凭据，等于走错门）|
| **拉到的主机本地无 Keychain 凭据** | 视 `CredentialSource` 而定（见下文 needsLocalCredential 判定）|
| **本地添加/修改凭据** | 仅写 Keychain，**绝不**通过 oRPC 上传到 server |
| **本地新建主机（同步开启时）** | 调用 **`sshHost.create`**（payload 中**不带** `password / privateKey / keyPassphrase`，即便 server schema 接受）；payload 包含 `CredentialSource` 选择本身（属于 metadata，不算 secret）—— 但 `keyFile.keyPath` 是设备本地路径，跨端无意义，详见下文路径漂移处理；server 返回的 `{ id }` 写入本地 `host.serverId`（详见 §7.1.3 id 映射）|
| **本地修改主机 metadata（已同步）** | 调用 **`sshHost.update`**，`id` 用本地 `host.serverId`，payload 不含凭据字段 |
| **本地删除主机** | 已同步：`sshHost.delete(id: serverId)` + Keychain 按本地 `host.id` 通配删除（`caterm.host.<localId>.password` / `.keyPassphrase`）；未同步：仅本地（Keychain + JSON）|

**`needsLocalCredential` 跨设备判定（按 `CredentialSource`）**：

- `.password` —— Keychain 命中检查 `caterm.host.<id>.password`；缺失 → 锁图标 + 添加凭据流
- `.keyFile(keyPath, hasPassphrase)` —— 检查 (a) keyPath 在本设备文件系统是否存在；(b) `hasPassphrase=true` 时 Keychain 是否有 `keyPassphrase`。**任一缺失** → 锁图标。**路径漂移**（device A `~/Alice/.ssh/id_ed25519` ≠ device B `~/Bob/.ssh/id_ed25519`）属于已知摩擦：v1.1 让用户在 device B 编辑主机时手动重选路径；不做"按文件名模糊匹配"自动恢复（一旦尝试 fallback 就背上"猜错私钥"的安全风险）
- `.agent` —— 永不需要本地配置凭据；不打 needsLocalCredential 标。如果用户的 agent 没装载对应私钥，连接失败由 ssh stderr 提示

**为什么这么严**：未来如果 server 决定加 E2E 加密层、或允许凭据上云的设计变更，是一个 conscious decision，应当走单独 spec；不该被实现层"既然 schema 有就顺手用了"误推进。

### 7.1.3 v1.1 本地 id ↔ server id 映射

v1 阶段 `Host.id` 是客户端生成的 UUID，**同时用作 Keychain 主键**（`caterm.host.<id>.password` / `.keyPassphrase`）。v1.1 同步开启后，server `sshHost.create` 会**返回服务端自己生成的 UUID**（见 `packages/api/src/routers/ssh-host.ts:68`），与本地 id 不同。

**采用方案 A：双 id，本地 id 永不变**

理由：Keychain key 迁移风险高（迁移中断 = 凭据丢失），而本地 id 已经被多处引用（Keychain key、JSON 持久化、UI 列表 selection）。代价是数据模型多一字段，但换来 Keychain 入口稳定。

`Host` 模型扩展（v1.1 时加，v1 不要提前）：

```swift
struct Host: Codable, Identifiable {
    let id: UUID                 // 本地 id，永远是 Keychain 主键，永不变
    var serverId: String?        // server 端 id；同步前为 nil
    // ... 其它字段同 v1
}
```

**同步流程**：

| 触发 | 行为 |
|------|------|
| 本地新建主机 → 上传 | `sshHost.create(...)` → 取 `{ id }` → 写入 `host.serverId`；本地 `host.id` **不动** |
| 拉取 server 列表 (`list`) → 与本地比对 | 按 `serverId` 匹配本地：match 则用 server metadata 更新本地（id/Keychain 不动）；no-match 则本地新建一条，本地 id 仍客户端生成，`serverId` 写为 server 返回值 |
| 本地修改 metadata | `sshHost.update(id: host.serverId!, ...)` |
| 本地删除 | `sshHost.delete(id: host.serverId!)` + Keychain 按 `host.id` 通配删除 |
| Server 端有但本地没有（其它设备新建的） | 本地新建 host：客户端生成新 local id 作为 Keychain key 入口；`serverId` 设为 server 返回的 id；按 `CredentialSource` 触发 `needsLocalCredential` 判定（见 §7.1.2 表）|
| Server 端没有但本地有（其它设备删了）| 本地也删除（按 `serverId` 失踪触发）；本地 Keychain 按 local id 清理 |

**冲突解决**：metadata 用 `updatedAt` last-write-wins，参照 `2026-03-05-ssh-host-cloud-migration-design.md` 已有方案。

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
| R1 | libghostty 公开 C API 表面太小 / 不稳定 | **高 → 已部分实现** | **高** | Spike 已证：libghostty 1.3.x 公开 API 不接受外部字节注入。**v1 已跳出这个 box** —— 把 SSH 控制完全让给 libghostty `command` 字段；备选 = SwiftTerm（如果 v1 实施期 libghostty 出新坑） |
| R2 | ~~NIOSSH PTY 申请姿势难调~~ —— v1 已不用 NIOSSH | —— | —— | spike 期间被 R1 顶替；已删除 |
| R2' | ssh 子进程 child-exit 信号传到 SessionStore 的可靠性 | 中 | 中 | libghostty `close_surface_cb` 是否在 ssh exit 时触发未验证；step 1.4 子任务里专门测；备选：轮询 `ghostty_surface_*` state API |
| R9 | askpass 二进制 codesign + Keychain access group ACL 配置错 | 中 | 高 | 主 app 和 askpass 同 Team ID + 同 access group entitlement；release.sh 里把签名步骤写明；step 1.3 完成时立刻端到端跑一遍密码 auth |
| R10 | OpenSSH 的英文 stderr 文本在不同 ssh 版本变形（影响失败模式分类）| 低 | 中 | 默认 `LANG=C`；分类逻辑只匹配关键词不匹配整句；新增 ssh 版本时手测一遍 |
| R3 | swift-bundler 不维护 / 兼容性炸 | 低 | 中 | 备选：手写 `.app` 组装脚本（约半天）|
| R4 | macOS 签名/notarization 卡 Apple | 中 | 中 | Apple Developer 账号提前申请；先跑通流程，签名最后接 |
| R5 | libghostty Zig 工具链对 CI 友好度 | 中 | 低 | v1 不上 CI；ship 前手工出 release |
| R6 | 现有 Tauri 用户数据迁移 | 低 | 低 | Tauri 版主机数据存在 server（oRPC `sshHost`），v1.1 登录上线后自动可见；v1 期间老用户继续用 Tauri 版无干扰 |
| R7 | 业余时间 4-6 周拖到 12 周 | **高** | 中 | 接受现实；按 step 增量 ship；progress 文件每周回顾 |
| R8 | libghostty 公开 API 不稳定（Ghostty 官方 docs 明确说尚未保证 standalone API 稳定）| 中 | **中-高** | （a）submodule 锁定 commit hash；（b）任何 vendor 期间打的 patch 写进 `Vendor/ghostty/PATCHES.md`；（c）每次升 Ghostty 前在 clean machine 上跑一遍 release.sh + S1-S6 等价 smoke test；（d）v1 期间不主动升级；（e）准备好"维持当前 commit 不升 Ghostty"作为长期备选 |

**最该盯死**：R7（纪律 + 增量 ship）、R8（升级有 ritual）、R9（askpass 签名配错凭据全瞎）。R1 已经在 spike 阶段以"绕过"形式解决；R2 已不存在。

---

## 9. 验证 & 验收

整个迁移不算"完成"，直到：

- [ ] Phase 0 spike 6 项 S1-S6 全部通过
- [ ] Phase 1 v1 全部 12 个 step（1.0-1.11）完成
- [ ] DoD（§6.4）6 项 MVP + 附加交付逐条 ✅
- [ ] 老 Tauri 版 deprecation banner 已合并（D9 一次性例外）
- [ ] 作者本人 dogfood v1 至少一周，无阻塞性 bug；公开内测在 v1 ship 后视情况扩大

---

## 10. 附录

### 10.1 相关历史文档

- `2026-04-27-spike-findings.md` —— Phase 0 spike 验证结果与架构调整
- `2026-03-04-ssh-auto-reconnect-design.md` —— 重连状态机参照
- `2026-03-05-ssh-host-cloud-migration-design.md` —— v1.1 同步冲突解决参照
- `2026-03-05-sftp-design.md` —— v2 SFTP 参照
- `2026-04-15-cross-device-restore-internal-beta.md` —— 当前同步 beta 状态

### 10.2 关键外部依赖

- [Ghostty](https://ghostty.org/) (MIT) —— 终端渲染（含 PTY 拥有权 + ssh 子进程 spawn）
- 系统 `/usr/bin/ssh` —— SSH 协议传输（macOS 14 自带 OpenSSH 9.x）；不打包，运行时找
- [swift-bundler](https://github.com/stackotter/swift-bundler) (MIT) —— SwiftPM `.app` 打包
- [Sparkle](https://sparkle-project.org/) (MIT) —— macOS 自动更新

**v1 不用**：~~swift-nio-ssh~~（spike 发现 libghostty 不接受外部字节，移到 v2 SFTP 评估）。
