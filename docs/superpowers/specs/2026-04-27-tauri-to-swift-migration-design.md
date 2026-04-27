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
| D14 | **SSH host key 校验**（v1 必须）= 委托给系统 ssh，hybrid known_hosts | 系统 `ssh` 自带 known_hosts + StrictHostKeyChecking。v1 用 `StrictHostKeyChecking=accept-new` + `UserKnownHostsFile="<caterm-path> ~/.ssh/known_hosts"`（多文件，**前者写、两者读**）。这样 Caterm 写新 host 不污染用户 `~/.ssh/`，同时已被用户既有 ssh 工具接受过的主机不会被 Caterm 重复 TOFU（重复 TOFU 是 MITM 风险窗口）。Caterm 不实现 KnownHostStore actor、不实现 TOFU 弹窗 UI（v1）；mismatch 由 ssh 自己 abort，**绝不 accept-all**。v1.1+ 视情况加 Swift 侧 TOFU 对话框 |

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
                     askpass binary 用 SecItemCopyMatching + access group 读 Keychain → 写 stdout

           [v1 不接 server；v1.1 起加 ServerSyncClient]
```

### 3.2 模块划分

| 模块 | 职责 | 依赖 | 测试 |
|------|------|------|------|
| **UI 层** | SwiftUI 视图 + AppKit window/tab；ConnectDialog 让用户选 `CredentialSource` | TerminalEngine, SessionStore | 不测；后期 XCUITest |
| **TerminalEngine** | 包装 libghostty C API；surface 创建/销毁、key 事件转发、resize；**libghostty 自己拥有 PTY**，Swift 不接触字节流 | libghostty (C) | 烟雾测试，信任 libghostty |
| **SSHCommandBuilder** | `Host + CredentialSource` → 单字符串 `command`（由 libghostty 在 macOS 跑成 `/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l <command>"`，**经 bash 解析**）；所有用户输入（user/host/keyPath/known_hosts 路径/askpass 路径）必须 shell-quote；负责 `-p`、`-i`、`-o StrictHostKeyChecking=accept-new`、`-o UserKnownHostsFile=...`（hybrid 双文件）、`-o BatchMode=yes`（agent 路径）等 ssh 选项；为非 agent 路径设置 `SSH_ASKPASS` / `SSH_ASKPASS_REQUIRE=force` env 并把 host id 透传给 askpass（`CATERM_HOST_ID=<uuid>`）| 无（纯字符串构造）| **必须**单元测试：三种 enum 路径分别断言 argv 形态 + shell quoting fuzz（含分号、反引号、`$()`、单/双引号、空格、unicode）+ 端口非 22 + 路径含空格 |
| **AskpassHelper** | 独立 SwiftPM `executableTarget`，编译为 `caterm-askpass` 小二进制（约 200-400 行）；运行时由 ssh `exec`，从 env `CATERM_HOST_ID` + `CATERM_ASKPASS_KIND` 选 Keychain key（`caterm.host.<id>.password` / `.keyPassphrase`）；调 **`SecItemCopyMatching` + `kSecAttrAccessGroup`**（不是 `SecKeychainFindGenericPassword` legacy API；后者在 macOS Data Protection Keychain 下不支持 access group 跨进程共享）读 secret，写 stdout，退出码 0；非法/缺失 env 退出码非 0；**signed with same Team ID + entitlement `keychain-access-groups: $(TeamIdentifierPrefix)caterm.shared` 与主 app 相同**，否则 ACL 拒绝 | macOS Security framework | 单元测试：mock Keychain access（用 ephemeral 测试 access group）；端到端集成留给 §6.3 Docker smoke |
| **SessionStore** | 主机列表（持久化 JSON）、tab 状态、活跃连接登记；监听 libghostty `GHOSTTY_ACTION_SHOW_CHILD_EXITED` action 拿 ssh exit_code | KeychainStore | 单元测试 |
| **KeychainStore** | 凭据读写；key 命名 `caterm.host.<id>.password` / `.keyPassphrase`；私钥**文件路径**不进 Keychain（敏感性属于文件本身权限）；用 `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` API（**不**用 `SecKeychain*` legacy）；查询条件含 `kSecAttrService = "com.caterm.host"` + `kSecAttrAccount = "<id>.<kind>"` + `kSecAttrAccessGroup = "$(TeamIdentifierPrefix)caterm.shared"` | macOS Security framework | 单元测试 |
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
   │  macOS: /usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l <commandString>"
   │  (commandString 经 bash 解析；见 Vendor/ghostty/src/termio/Exec.zig:1423)
   │   │
   │   └─►  /usr/bin/ssh -p PORT -i KEYPATH … user@host
   │           │
   │           ├─ 启动时 ssh 读 hybrid known_hosts（Caterm 文件 + ~/.ssh/known_hosts）
   │           │   ├─ host 已知 + key 匹配 → 继续
   │           │   ├─ host 已知 + mismatch → ssh 自己 abort，子进程退出
   │           │   └─ host 未知（accept-new）→ 自动接受并写入 Caterm 文件
   │           │
   │           ├─ password / passphrase 路径：ssh fork+exec $SSH_ASKPASS
   │           │   askpass binary 用 CATERM_HOST_ID + CATERM_ASKPASS_KIND 查 Keychain，写 stdout → ssh 收到
   │           │
   │           └─ ssh-agent 路径：ssh 跟继承的 SSH_AUTH_SOCK 谈（无 askpass、无 -i、BatchMode=yes）
   │
   ├─ surface 创建成功 → SessionStore 进 Connecting；§4.3 grace period (3s) 后看 process_exited
   │  → 仍存活 → Connected；已退出 → 用 exit_code 分类成 Failed / Reconnecting
   │
   └─ surface 创建失败（极少；通常是 command 字符串无效）→ SessionStore.markFailed
```

**三种 commandString 形态**（SSHCommandBuilder 输出）。⚠️ **重要**：libghostty 在 macOS 上把 `command` 跑在 `/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l <command>"` 里（见 `Vendor/ghostty/src/termio/Exec.zig:1423`），**所以 command 字符串经 bash 解析**。所有含空格、引号、`$`、反引号、`;` 的成分（user/host/keyPath、known_hosts 路径、askpass 路径）都必须 shell-quote。环境变量走 `surfaceConfig.env_vars`（独立列表，**不**塞进 command 字符串）。

下面示例的所有 path 用单引号包裹（POSIX shell 单引号内除单引号外所有字符字面）。SSHCommandBuilder 的 quote helper 必须按 POSIX `'$str'` → `'\''` 替换处理嵌入单引号。

```
# (a) password
command  = "/usr/bin/ssh \
  -o StrictHostKeyChecking=accept-new \
  -o 'UserKnownHostsFile=/Users/x/Library/Application Support/Caterm/known_hosts /Users/x/.ssh/known_hosts' \
  -o NumberOfPasswordPrompts=1 \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -p 22 'user'@'host.example.com'"
env_vars = [
  "SSH_ASKPASS"        = "<askpass binary 绝对路径>",
  "SSH_ASKPASS_REQUIRE"= "force",
  "CATERM_HOST_ID"     = "<uuid>",
  "CATERM_ASKPASS_KIND"= "password",
]

# (b) keyFile + 可选 passphrase
command  = "/usr/bin/ssh \
  -o StrictHostKeyChecking=accept-new \
  -o 'UserKnownHostsFile=/Users/.../Caterm/known_hosts /Users/x/.ssh/known_hosts' \
  -o IdentitiesOnly=yes \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -i '/Users/x/.ssh/id_ed25519' \
  -p 22 'user'@'host.example.com'"
env_vars = [
  "SSH_ASKPASS"        = "<askpass binary 绝对路径>",
  "SSH_ASKPASS_REQUIRE"= "force",
  "CATERM_HOST_ID"     = "<uuid>",
  "CATERM_ASKPASS_KIND"= "passphrase",
]
# (passphrase 为空时 ssh 不调 askpass；env vars 留着无害)

# (c) ssh-agent
command  = "/usr/bin/ssh \
  -o StrictHostKeyChecking=accept-new \
  -o 'UserKnownHostsFile=/Users/.../Caterm/known_hosts /Users/x/.ssh/known_hosts' \
  -o BatchMode=yes \
  -p 22 'user'@'host.example.com'"
env_vars = []
# (无 SSH_ASKPASS / 无 -i；ssh-agent 走继承自父进程的 SSH_AUTH_SOCK；
#  BatchMode=yes 关掉所有交互 prompt — agent 就该是非交互的，不能 fallback 进密码 prompt)
```

**关键纪律**：

- **shell-quoting 是凭据安全防线**：用户输入的 hostname/username 含分号、反引号、`$()` 都不能逃逸到 bash。SSHCommandBuilder 必须用白名单字符 validate + 强制单引号 quote 兜底，两道关卡。`apps/macos/Tests/SSHCommandBuilderTests/` 里要有 fuzz 风格 quote-escape 用例
- **`SSH_AUTH_SOCK`**（agent 路径用）由 macOS launchd 自动注入到所有用户进程；libghostty 继承下来给 ssh —— Caterm 不需要显式传
- **`IdentitiesOnly=yes` + `-i`** 保证不误用 ssh-agent 里别的 key（避免"agent 里有 5 把 key，用户为这台机器明确选了 id_ed25519，但 agent 在 ssh 把 -i 当成首选 key 之前先试别的把服务器 MaxAuthTries 打爆"）。注意它不等于"绝对只用这一把"——用户在 `~/.ssh/config` 里加的 IdentityFile 仍会被追加；这是已知限制
- **三路认证选项隔离**（防止凭据走错门）：
  - password 路径：禁 pubkey + kbd-interactive。否则 ssh-agent 抢先把服务端 MaxAuthTries 打爆，用户输完密码也连不上
  - keyFile 路径：禁 password + kbd-interactive。否则用户的 keyFile passphrase 错了 ssh 会回落到密码 prompt，askpass 把 keyPassphrase 当密码送给 server，弱 server 端日志可能记下泄漏
  - agent 路径：`BatchMode=yes` 禁所有 prompt。否则 agent 没装载对应 key 时 ssh 会问密码，但 askpass 没配置，体验更差还诱骗用户混淆"无凭据"和"输入密码"

**Host key 校验纪律**（hybrid known_hosts）：

- `UserKnownHostsFile` 接两个文件（OpenSSH 支持空格分隔多文件，第一个是默认写入目标，所有文件都参与读匹配）：
  1. **`~/Library/Application Support/Caterm/known_hosts`** —— Caterm 写的，accept-new 时新增 host key 落这里
  2. **`~/.ssh/known_hosts`** —— 用户既有信任，**只读**继承
- 这样首次连接已被用户用 iTerm/系统 ssh 接受过的主机不会再次 TOFU；同时 Caterm 写新 host 也不污染用户 `~/.ssh/`
- `StrictHostKeyChecking=accept-new`：未知 host 自动接受 + 写第一个文件；mismatch 阻断。**绝不**用 `accept-all` / `=no` —— 这两个等于关掉校验
- v1 不实现 Swift 侧 TOFU 弹窗（妥协：首次接受是隐式的；mismatch 由 ssh 把 `Host key verification failed` 打到 surface）
- v1.1+ 视情况加 Swift TOFU 弹窗（用 askpass-style hook 拦截）。**不在 v1**
- Docker smoke matrix 必须含「~/.ssh 已记录但 Caterm 文件为空」「Caterm 已记录但 ~/.ssh 为空」「两边都有且匹配」「两边都有且 mismatch」四个 case

**Connect 失败的"连不上"分类**（影响重连状态机）：

| 失败模式 | 信号 | UI 处理 |
|---------|------|---------|
| auth 失败 | ssh exit code = 255 **且** 短时（<3s）退出 **且** 之前没有过任何 stdout | tab 变红；提示重新填凭据；**不重连** |
| host key mismatch | ssh exit code = 255 **且** 极短时（<1s）退出 **且** 之前没有过任何 stdout（accept-new 模式下 mismatch 立即 abort）| 经验上与 auth 失败难以仅通过 exit code 区分。**v1 合并到"auth/setup 阶段失败"**，UI 提示"无法建立连接，请检查凭据或 host key"；用户视情况手动处理 known_hosts |
| 远端正常断开（`exit`）| ssh exit code = 0 | tab 变灰；提示"会话结束"；**不重连** |
| 网络中途断 | ssh exit code != 0 **且** 已 Connected 过（详见 §4.3）| tab 变黄；进入 §4.3 重连状态机 |
| 启动期网络不通 | ssh exit code = 255 **且** 短时退出（与 auth 失败同信号）| 当作 auth/setup 阶段失败处理；不自动重连 |

**纪律**：

- 失败分类**只用 exit code + 「Connected 过没有」两个信号**做粗分。stderr **不可读**（libghostty 不暴露字节流给 Swift），原 spec 写的"stderr 文本匹配"是错的，已删除
- 想要更细分类，需要写一个 `caterm-ssh-launcher` wrapper：libghostty 跑 launcher，launcher fork-exec ssh 同时把 ssh 的 stderr 复制到 sidecar JSON 文件（`~/Library/Caches/Caterm/<sessionId>.status.json`），Swift 在 child exit 后读这个 sidecar。**v1 不做**——粗分类够 ship；细分类是 v1.1 候选改进
- exit code 信号源 = `GHOSTTY_ACTION_SHOW_CHILD_EXITED` action callback（携带 `ghostty_surface_message_childexited_s.exit_code`）+ `ghostty_surface_process_exited(surface)` 查询 API；**不**依赖 `close_surface_cb`（libghostty 强制 `wait-after-command=true`，child 退出后 surface 不会自动关 → close 回调不会触发，详见 §6.3 #5）

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

**Connected 判定**：Swift 看不到 libghostty 内部 PTY 的字节流，**不能**用"首次 stdout 出现"做判据。改成 **grace period alive 检查**：

- surface 创建后启动 3s 计时器
- 期间任意时刻收到 `GHOSTTY_ACTION_SHOW_CHILD_EXITED` action（child 已退出）→ 进 Failed / Reconnecting
- 计时器到期，`ghostty_surface_process_exited(surface) == false`（child 还活着）→ Connected
- 选 3s 因为：本地网 ssh 握手通常 200-800ms；同城 1-3s；跨洲 2-5s。3s 截断会把跨洲连接误判 ConnectingTooSlow，但允许 UI 仍维持"Connecting…"灰态而不是切红，等真退出信号来才切；这套语义更稳

**Connecting 阶段也允许保持等待**：3s 没结论时不强切状态，UI 显示 "Connecting…"；只在拿到 child exit 信号后做最终决定。

**复用语义**：参照 `2026-03-04-ssh-auto-reconnect-design.md`，不重新设计交互。

**重连语义边界（重要）**：

- 重连 = **重启 ssh 子进程，建立新 SSH session**；不是恢复原远端进程
- 原远端 shell 上跑的 vim/tmux/long-running command **全部已死**（除非用户在 tmux/screen 里）
- UI 必须**显式提示新连接已建立**，但**不能**靠"往 scrollback 注入字节"——Swift 无字节注入入口（§4.2）。改用：
  - 旧 surface 销毁前不动它（保留断线那一刻的字符画面，作为视觉锚点）
  - 在 surface 之上叠加一个 NSView **overlay**（半透明黑底 + "连接断开 — 正在重连 (1/5)"），重连状态机驱动文案
  - 新 surface 替换 NSView 时附 200ms 淡入动画 + 一次明显的 tab 状态闪动 → 视觉上必然让用户感知"换了一次"
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
| 1.2 | SSHCommandBuilder：纯函数 + 单元测试覆盖三种 enum 路径（password / keyFile+passphrase / agent）；**含 shell-quoting fuzz**（分号、反引号、`$()`、单/双引号、unicode、空格）；端口非 22；hybrid `UserKnownHostsFile` 双文件；三路 ssh 选项隔离（password 禁 pubkey；keyFile 禁 password+kbd；agent BatchMode=yes）| 2 天 | 拼 ssh 命令字符串（凭据流安全防线）|
| 1.3 | **AskpassHelper 二进制**（独立 `executableTarget` `caterm-askpass`）：从 env `CATERM_HOST_ID` + `CATERM_ASKPASS_KIND` 选 Keychain key → 调 `SecItemCopyMatching` + `kSecAttrAccessGroup`（**不**用 `SecKeychain*` legacy API）读 secret → 写 stdout；含 dev codesign 配置 + access group entitlement plist；**1.3 完成时立即跑端到端密码 auth**（必须先解决签名才能验证 access group ACL —— 不能等到 1.11 release.sh）| 2-3 天 | 凭据自动注入 |
| 1.4 | 单 tab 完整 connect 流：硬编码一台主机 → SSHCommandBuilder → libghostty surface → **child-exit 信号路径验证**（监听 `GHOSTTY_ACTION_SHOW_CHILD_EXITED` action callback + 轮询 `ghostty_surface_process_exited`，**不**依赖 `close_surface_cb`，因 libghostty 强制 `wait-after-command=true`）→ Connected/Failed 判定（§4.3 grace period 模型）| 2 天 | 端到端 v0 |
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

**Keychain access group**：单一 group `$(TeamIdentifierPrefix)caterm.shared`（在 entitlements plist 里以 macro 写法），主 app 和 askpass 二进制都加这个 entitlement，确保 askpass 能读到主 app 写的 secret。

**Keychain API 选择**：用 `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`（Data Protection Keychain），查询字典含：

```swift
[
  kSecClass:           kSecClassGenericPassword,
  kSecAttrService:     "com.caterm.host",
  kSecAttrAccount:     "<host-uuid>.<password|keyPassphrase>",
  kSecAttrAccessGroup: "<TEAM_ID>.caterm.shared",
  kSecAttrAccessible:  kSecAttrAccessibleWhenUnlocked,   // 不要 ThisDeviceOnly：未来若做 iCloud Keychain 扩展会卡
]
```

**不**用 `SecKeychainFindGenericPassword` / `SecKeychainAddGenericPassword` legacy API：macOS 对它们的 access group 跨进程支持有限，且 Apple 推荐的 codepath 是 `SecItem*`。

**TerminalSettings**：直接 Ghostty config 文件，不二次包装。

- 路径：`~/Library/Application Support/Caterm/config`（Caterm 独立维护，不读取也不写入 Ghostty 自己的 `~/.config/ghostty/config`，避免与用户已有 Ghostty 配置互相污染）
- 不存在时由 ConfigStore 写入一份默认值
- v1 不提供配置 UI，仅暴露"打开配置文件"菜单项；用户用文本编辑器改

**KnownHosts**（系统 ssh 自己维护，Caterm 不读不写）：

- ssh 选项：`-o "UserKnownHostsFile=<path1> <path2>"`（OpenSSH 支持多文件，空格分隔，第一个是 accept-new 默认写入目标，所有文件都参与读匹配）
  - `<path1>` = `~/Library/Application Support/Caterm/known_hosts` —— Caterm 写入目标（accept-new 时新增 host key 落这里）
  - `<path2>` = `~/.ssh/known_hosts` —— 用户既有信任，**只读继承**（避免用户用过 iTerm/系统 ssh 接受过的主机在 Caterm 里被重复 TOFU，那本身是 MITM 风险窗口）
- 格式：OpenSSH `known_hosts` 标准（Caterm 不解析）
- 由系统 ssh 用 `StrictHostKeyChecking=accept-new` 模式自动维护
- v1 不提供 known_hosts 管理 UI；如需"忘记主机"，文档指引用户用 `ssh-keygen -R <hostname> -f <path>`

### 6.3 测试策略

| 层 | 测什么 | 怎么测 |
|----|-------|--------|
| **SSHCommandBuilder** | 三种 `CredentialSource` enum 路径分别拼对 argv；端口非 22 / 含空格 key 路径 / hybrid known_hosts 双文件；三路选项隔离（password 禁 pubkey / keyFile 禁 password+kbd / agent BatchMode=yes）；环境变量正确（`SSH_ASKPASS` / `CATERM_HOST_ID` / `CATERM_ASKPASS_KIND`）；**shell-quoting fuzz 用例集**（分号、反引号、`$()`、单/双引号、空格、非 ASCII）—— 任意 quote 漏出都意味着 user/host/keyPath 可注入 bash | 单元测试，纯 Swift，零依赖；**硬要求**（凭据流安全的核心防线）|
| **AskpassHelper** | 给定 env → 选对 Keychain key；命中/未命中分支；输出格式（密码末尾换行符合 ssh 行为）；非法/缺失 env 退出码非 0 | 单元测试 + mock Keychain（ephemeral access group） |
| **端到端 SSH 集成** | 真实 auth 三路（password / keyFile / agent）、PTY、resize、EOF；**hybrid known_hosts 4 case**（仅 Caterm 有记录 / 仅 ~/.ssh 有 / 两边匹配 / 两边 mismatch）| **Docker `linuxserver/openssh-server` 容器**，本地（开发机/dogfood）手动测试脚本拉起；v1 不上 CI（与 R5 一致），ship 前手动跑完整 matrix；spike 已验证 password 路径，留下 `apps/macos/Tests/Manual/spike-smoke.md` 文档化步骤 |
| **SessionStore** | host CRUD、tab 状态、CredentialSource enum 持久化与往返、Connected/Failed/Reconnecting 状态机转换 | 单元测试，纯 Swift |
| **KeychainStore** | `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` 三路；不存在 / 重复写 / 按 host id 通配删；access group `$(TeamIdentifierPrefix)caterm.shared` 命中 | 单元测试用 ephemeral keychain access group；**真实 codesign 验证延后到 1.3 step 端到端跑** |
| **ConfigStore** | 默认 config 写入 / 读取已有 / 文件权限（0600）| 单元测试 |
| **TerminalEngine** | 不测内部（信任 libghostty） | 烟雾测试：能创建 surface 即可（spike 已验证）|
| **UI** | 不测 | 手测；后期 XCUITest |
| **重连状态机** | 状态转换矩阵（含 grace period 3s alive 判定、auth/setup-fail 不重连、Connected 后断网才重连、5 次后停止）| 单元测试，**硬要求** |
| **失败模式分类** | exit code + Connected 历史标志 → `FailureKind` enum 粗分类（authOrSetupFail / cleanExit / connectionDropped）| 单元测试，纯函数。**不**含 stderr 文本匹配 —— Swift 拿不到 stderr |

**实现注意事项（写代码时盯死）**：

1. `ghostty_surface_*` 调用必须在 `@MainActor`
2. **child-exit 信号源**：监听 runtime config `action_cb`（dispatch on `GHOSTTY_ACTION_SHOW_CHILD_EXITED`，载荷 `ghostty_surface_message_childexited_s.exit_code`）+ 必要时调 `ghostty_surface_process_exited(surface)` 查询。**不**依赖 `close_surface_cb`：libghostty 把 `command != null` 的 surface 强制 `wait-after-command = true`（见 `Vendor/ghostty/src/apprt/embedded.zig:533-534`），child 退出后 surface 不会自动关，close 回调不会触发
3. **stderr 拿不到**：libghostty 不暴露 ssh 子进程 stderr 给 Swift。失败分类只能基于 exit code + Connected 历史。如果将来要细分（"密码错" vs "网不通" vs "host key 变"），需要写 `caterm-ssh-launcher` wrapper 把 stderr 复制到 sidecar JSON 文件 —— v1.1 候选改进，**v1 不做**
4. AskpassHelper 二进制和主 app **必须用同一 Apple Team ID 签名 + 同一 Keychain access group entitlement**（`$(TeamIdentifierPrefix)caterm.shared`），否则 Keychain ACL 拒绝 askpass 读。**直接 `swift run` 因为没签名所以读不到 Keychain** —— 1.3 step 必须先建 dev signing 流程，后续 step 都依赖它
5. `surfaceConfig.command` **经 macOS bash 解析**（`/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l <command>"`，见 `Vendor/ghostty/src/termio/Exec.zig:1423`）。所有用户输入必须 shell-quote。环境变量用独立的 `surfaceConfig.env_vars` 字段，**不**塞进 command 字符串
6. SSHCommandBuilder 不要直接字符串插值。先用 `[String]` argv 列表，最后一刻用 quote helper（POSIX `'$str'` + 内嵌单引号转 `'\''`）拼回字符串
7. **Keychain API 选择**：用 `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` 走 Data Protection Keychain（含 access group）；**不**用 `SecKeychain*` legacy API（macOS 对 access group 跨进程支持有限）

### 6.4 v1 完成标准（DoD）

**6 项 MVP 功能可用**（不是"通了"，是"日常用一周不痛"）：

1. **SSH 连接**：三路 auth 全可用（密码 / 私钥+passphrase / ssh-agent 兜底），ConnectDialog 让用户选
2. **libghostty 渲染** + 多 tab 切换
3. **主机列表**（添加/编辑/删除 + 本地 JSON 持久化 + CredentialSource 持久化）
4. **Keychain 凭据存储**（密码 / passphrase；agent 路径不写 Keychain），由 AskpassHelper 二进制读取
5. **自动重连**（exp backoff + UI 状态指示 + 新连接提示 + 失败模式分类）
6. **SSH host key 校验**：用系统 ssh `accept-new` 模式 + hybrid `UserKnownHostsFile`（Caterm 文件写、`~/.ssh/known_hosts` 读继承）；mismatch 由 ssh 自己 abort

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

**核心纪律**：Swift v1 引入的 `CredentialSource` enum（`.password / .keyFile / .agent`）是 **device-local overlay**；server schema（`packages/db/src/schema/ssh-host.ts` + router `authType: 'password' | 'key'`）不动，在 D10 边界内。

为什么 device-local：

1. server `authType` 只有 `password` / `key` 两个值，没有 `agent`，也没有 `keyPath`。改它就破 D10
2. `keyFile.keyPath` 是设备本地路径，跨端无意义（device A `/Users/alice/...` ≠ device B `/Users/bob/...`）
3. 同一台主机用户在 device A 想用密码、在 device B 想用 ssh-agent，是合理使用模式 —— 跨端同步 `CredentialSource` 反而错

**同步的字段**（与 v1 server schema 一致）：

| 同步 | 不同步（device-local） |
|------|----------------------|
| `name` / `hostname` / `port` / `username` | `CredentialSource`（完整 enum 状态）|
| `authType: 'password' \| 'key'` —— 给 Tauri 兼容用，**v1.1 Swift 不读它**，固定写 `'key'`（占位）| `keyFile.keyPath`（绝对路径）|
| 不同步 `password` / `privateKey` / `keyPassphrase` 三列 | `keyFile.hasPassphrase` 标志位 |

`sshHost` 表结构含 `password` / `privateKey` / `keyPassphrase` 三个凭据列。**Swift v1.1 不使用这三列**，纪律如下：

| 操作 | 客户端行为 |
|------|----------|
| **从 server 拉主机列表** | 调用 **`sshHost.list`**（只返回 metadata，无凭据字段）；**禁止** 调用 `sshHost.getById`（它会解密返回凭据，等于走错门）；server 返回的 `authType` 字段只作 Tauri 客户端兼容用，Swift 客户端**忽略** |
| **拉到的主机本地没有 CredentialSource overlay** | 在 SessionStore 给 host 打标 `needsCredentialSetup = true`；UI 列表显示锁图标；用户首次连接时弹"该主机尚未在本机配置认证方式"提示，进入"选凭据"流程（密码 / 私钥+passphrase / agent 三选一） |
| **本地添加/修改凭据** | 写 Keychain（password 或 keyPassphrase）+ 写本地 JSON 的 `CredentialSource`；**绝不**通过 oRPC 上传 secret 到 server |
| **本地新建主机（同步开启时）** | 调用 **`sshHost.create`**：payload 含 `name/hostname/port/username/authType='key'`（占位常量），**不带** `password / privateKey / keyPassphrase`；server 返回的 `{ id }` 写入本地 `host.serverId`（详见 §7.1.3 id 映射）；本地额外把 `CredentialSource` 写到 device-local JSON |
| **本地修改主机 metadata（已同步）** | 调用 **`sshHost.update`**，`id` 用本地 `host.serverId`，payload 仅 `name/hostname/port/username`，不含凭据字段也不含 `CredentialSource`；本地 JSON 单独维护 `CredentialSource` |
| **本地删除主机** | 已同步：`sshHost.delete(id: serverId)` + Keychain 按本地 `host.id` 通配删除（`caterm.host.<localId>.password` / `.keyPassphrase`）+ 删本地 JSON 条目；未同步：仅本地（Keychain + JSON）|

**`needsCredentialSetup` 跨设备判定**：

- 本地 JSON 没有该 host 的 `CredentialSource` overlay → `needsCredentialSetup = true`（首次设备 / 新 device 拉到的主机都属于这种）
- 有 overlay 但具体凭据缺失：
  - `.password` —— Keychain 没 `caterm.host.<id>.password` → `needsCredentialSetup`
  - `.keyFile(keyPath, hasPassphrase)` —— keyPath 文件不存在 / `hasPassphrase=true` 但 Keychain 没 keyPassphrase → `needsCredentialSetup`
  - `.agent` —— 永远不需要本地凭据；不打标
- 关键差异：**有 overlay 但凭据缺**（视 source 而定） vs **完全没 overlay**（device 第一次见这台主机）

**keyPath 漂移处理**（已确认）：v1.1 让用户在新 device 上手动重选路径；**不**做"按文件名模糊匹配"自动恢复（猜私钥背上"用错 key"风险，把 server MaxAuthTries 打爆 / 万一路径同名指向不同 key 就泄漏）。

**为什么这么严**：未来如果 server 决定加 E2E 加密层、或允许凭据上云、或扩 `authType` 加 agent，是 conscious decision，走单独 spec；不该被实现层"既然 schema 有就顺手用了"误推进。

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
| R2' | ssh 子进程 child-exit 信号传到 SessionStore 的可靠性 | 中 | 中 | 已查代码：`close_surface_cb` 不会在 child exit 时触发（libghostty 强制 `wait-after-command=true`，见 embedded.zig:533）。**采用** `GHOSTTY_ACTION_SHOW_CHILD_EXITED` action callback + `ghostty_surface_process_exited` 查询 API 这两路；step 1.4 端到端跑过验证 |
| R9 | askpass 二进制 codesign + Keychain access group ACL 配置错 | 中 | 高 | 主 app 和 askpass 同 Team ID + 同 access group entitlement；release.sh 里把签名步骤写明；**step 1.3 完成时立刻端到端跑一遍密码 auth** —— 不能等到 1.11；这是把"签名 +ACL 验证"前置到最早的合理位置 |
| R10 | 失败模式分类粒度不够（只能凭 exit code 粗分） | 中 | 中 | Swift 拿不到 ssh stderr，v1 接受"auth/setup 失败合并到一类，UI 提示用户检查凭据或 host key"；细分留给 v1.1 caterm-ssh-launcher wrapper（写 sidecar JSON 暴露 stderr） |
| R11 | command 字符串经 macOS bash 解析 — quote 漏出导致 shell injection | **中** | **高** | SSHCommandBuilder 双重防线：(a) 用户输入字符白名单 validate；(b) 强制 POSIX 单引号 quote（嵌入单引号转 `'\''`）；fuzz 测试用例集（分号 / 反引号 / `$()` / unicode / 空格）；任何 quote 漏出视为 P0 bug |
| R3 | swift-bundler 不维护 / 兼容性炸 | 低 | 中 | 备选：手写 `.app` 组装脚本（约半天）|
| R4 | macOS 签名/notarization 卡 Apple | 中 | 中 | Apple Developer 账号提前申请；先跑通流程，签名最后接 |
| R5 | libghostty Zig 工具链对 CI 友好度 | 中 | 低 | v1 不上 CI；ship 前手工出 release |
| R6 | 现有 Tauri 用户数据迁移 | 低 | 低 | Tauri 版主机数据存在 server（oRPC `sshHost`），v1.1 登录上线后自动可见；v1 期间老用户继续用 Tauri 版无干扰 |
| R7 | 业余时间 4-6 周拖到 12 周 | **高** | 中 | 接受现实；按 step 增量 ship；progress 文件每周回顾 |
| R8 | libghostty 公开 API 不稳定（Ghostty 官方 docs 明确说尚未保证 standalone API 稳定）| 中 | **中-高** | （a）submodule 锁定 commit hash；（b）任何 vendor 期间打的 patch 写进 `Vendor/ghostty/PATCHES.md`；（c）每次升 Ghostty 前在 clean machine 上跑一遍 release.sh + S1-S6 等价 smoke test；（d）v1 期间不主动升级；（e）准备好"维持当前 commit 不升 Ghostty"作为长期备选 |

**最该盯死**：R7（纪律 + 增量 ship）、R8（升级有 ritual）、R9（askpass 签名配错凭据全瞎）、R11（quote 漏出 = shell injection）。R1 已经在 spike 阶段以"绕过"形式解决；R2 已不存在；R2' 已查代码确定路径。

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
