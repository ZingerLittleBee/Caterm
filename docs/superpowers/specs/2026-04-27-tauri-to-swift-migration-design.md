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
| D7 | 终端配置模型 = **Ghostty 原生 schema** | 不做映射；server 端将来直接存 Ghostty config 文本 |
| D8 | 新代码位置 = **`apps/macos/`** | 与 `apps/web`（Tauri）和 `apps/server` 平级 |
| D9 | 旧 Tauri 客户端 = **立即冻结** | 不再维护（含 bug fix）；保留目录但 main 不再合并相关 PR |
| D10 | Server 端 = **完全不动** | 复用现有 oRPC API；v1.1 同步功能用 URLSession 调用 |
| D11 | 执行策略 = **Approach 1**（spike → 垂直切片） | 5 天 spike 验证后再投入 v1 |
| D12 | v1 凭据存储 = **仅本地 Keychain** | v1 无同步；server 端不参与凭据流 |
| D13 | v1 不做的功能（推后到 v1.1/v2） | 同步、SFTP、本地文件浏览器（永久砍掉）、拖拽上传、bookmarks |

### 砍掉的功能（不再纳入路线图）

- **本地文件浏览器**（Tauri 版的 11 个 `local_fs_*` 命令）—— 用户确认不再需要

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
| **UI 层** | SwiftUI 视图 + AppKit window/tab | TerminalEngine, SessionStore | 不测；后期 XCUITest |
| **TerminalEngine** | 包装 libghostty C API；PTY 数据进、渲染出；输入事件转发 | libghostty (C) | 烟雾测试，信任 libghostty |
| **SSHTransport** | NIOSSH 连接、channel、PTY 申请、reconnect 状态机 | swift-nio-ssh | **必须** 单元测试 + 可选集成（docker openssh-server）|
| **SessionStore** | 主机列表（持久化 JSON）、tab 状态、活跃连接登记 | KeychainStore | 单元测试 |
| **KeychainStore** | 凭据读写；key 命名 `caterm.host.<id>.<field>` | macOS Security framework | 单元测试 |
| **ConfigStore** | 加载/保存 Ghostty 配置文件 + 应用配置 | 文件系统 | 单元测试 |

### 3.3 关键边界

- **TerminalEngine 不知道 SSH** —— 只接受字节流和写回调；未来加本地 shell 零成本
- **SSHTransport 不知道终端** —— 产 `AsyncStream<Data>` 给上层；测试不依赖 libghostty
- **SessionStore 是 UI 唯一数据源** —— ObservableObject；UI 不绕过它直接调 SSHTransport

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
│   │   └── SSHConnection.swift        # NIOSSH 包装
│   ├── SessionStore/
│   ├── KeychainStore/
│   └── ConfigStore/
├── Tests/
│   ├── SSHTransportTests/
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

### 4.1 连接流

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
SSHTransport.connect(config) ──→ NIOSSH handshake + auth + open channel + request PTY
   │
   ├─ 成功: 返回 Connection { stdoutStream, stdinSink, resizeSink }
   │   │
   │   ▼
   │  TerminalEngine.attach(stream, sink) → libghostty surface 创建
   │   │
   │   ▼
   │  SessionStore.markConnected(sessionId)  → UI tab 状态变绿
   │
   └─ 失败: SessionStore.markFailed(sessionId, err) → 错误 toast
```

### 4.2 终端 I/O

```
[远端 stdout]
    │
    ▼
NIOSSH Channel inbound  ──→  AsyncStream<Data>
    │
    ▼
TerminalEngine.feed(bytes)  ──→  ghostty_surface_write_data (C call)
                                  └─ libghostty 内部解析 VT + GPU 渲染

[用户键盘输入]
    │
    ▼
NSResponder keyDown / keyUp
    │
    ▼
TerminalEngine.handleKey(event) ──→ ghostty_surface_key (translate)
    │
    ▼
ghostty 的 write callback(bytes) ──→ SSHTransport.stdinSink.write(bytes)
    │
    ▼
NIOSSH Channel outbound
```

**关键纪律**：libghostty 既是渲染器也是 VT 解析器；Swift 层不做 ANSI 解析，只搬字节。

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
| 硬编码一台机器（hostname/user/password 写代码里）| host CRUD UI / 持久化 |
| password auth | 私钥 auth |
| libghostty 嵌入一个 NSView 渲染 | 主题、字体配置 |
| 键盘输入 → SSH stdin | 鼠标、剪贴板 |
| stdout → 终端渲染 | 错误处理 / 重连 |
| 窗口 resize（验证全双工控制面）| Keychain / Sparkle / 任何打磨 |
| Bash 跑 `ls && top` 看效果 | 单元测试 |

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
| 1.1 | 单 tab + 硬编码主机 + 完整 connect 流（含 password & key auth）| 3-4 天 | 能连第一台机器 |
| 1.2 | NSWindow tab（多 tab）+ 切换 + 关闭 tab 优雅断开 | 3 天 | 多 tab |
| 1.3 | HostListSidebar UI + 添加/编辑/删除主机表单 + 本地 JSON 持久化 | 4-5 天 | 不再硬编码 |
| 1.4 | KeychainStore 接入（替代 1.1 的硬编码凭据）| 2 天 | 凭据安全 |
| 1.5 | 自动重连状态机 + UI 状态指示（绿/黄/红）| 3-4 天 | 网络抖动可恢复 |
| 1.6 | 应用配置：直接读写 Ghostty config 文件（`~/Library/Application Support/Caterm/config`）；最小 UI 暴露"打开配置文件" | 1 天 | 主题/字体走 Ghostty |
| 1.7 | 打磨：菜单栏、菜单项、快捷键（⌘T 新 tab / ⌘W 关 tab / ⌘N 新窗口）、关于面板 | 2-3 天 | 像个 Mac app |
| 1.8 | 内测分发：`Scripts/release.sh`（swift-bundler + codesign + notarytool + create-dmg）+ Sparkle | 3-4 天 | 可分发 |

**累计**：约 22-27 个工作日。业余 1 小时/天 → 4-7 周；业余 4 小时/周末 → 5-9 周。

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

### 6.3 测试策略

| 层 | 测什么 | 怎么测 |
|----|-------|--------|
| **SSHTransport** | connect / auth / channel / reconnect 状态机 | 单元测试，mock NIO event loop；可选：docker openssh-server 集成 |
| **SessionStore** | host CRUD、tab 状态、并发安全 | 单元测试，纯 Swift |
| **KeychainStore** | 读写 / 不存在 / 重复写 | 单元测试，target 单独 keychain access group |
| **TerminalEngine** | 不测内部（信任 libghostty） | 烟雾测试：能创建 surface 即可 |
| **UI** | 不测 | 手测；后期 XCUITest |
| **重连状态机** | 状态转换矩阵 | 单元测试，**硬要求** |

### 6.4 v1 完成标准（DoD）

- 5 项 MVP 功能可用（不是"通了"，是"日常用一周不痛"）
- DMG 签名 + notarized；Sparkle feed 能自动更新
- README 让新用户从下载到连上第一台机器
- 老 Tauri 版打 deprecation banner 引导迁移

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

### 7.1 v1.1 — 登录 + 跨端同步

| 模块 | 简述 |
|------|------|
| `ServerSyncClient` | 包装 oRPC HTTP（URLSession + Codable，或 swift-openapi-generator）|
| `AuthSession` | better-auth cookie/session（macOS 用 ASWebAuthenticationSession）|
| `HostSyncStore` | 在 SessionStore 上叠层：本地 JSON 主、server 同步副；冲突解决参考 `2026-03-05-ssh-host-cloud-migration-design.md` |
| `TerminalSettingsSync` | 上传/下载 Ghostty config 文本；server 端按字符串存 |

**v1.1 凭据同步策略**：留到该阶段动笔时再决（选项 A：Keychain 主 + server 存元信息；选项 B：照搬 Tauri 现状）。

**预估**：2-3 周业余时间。

### 7.2 v2 — SFTP 全套

| 模块 | 简述 |
|------|------|
| `SFTPTransport` | NIOSSH 的 SFTP 子协议；评估 Citadel 提供更高层 API |
| `SFTPSessionManager` | 复用现有 SSH 连接复用 SFTP channel |
| `TransferQueue` | 上传/下载队列、并发、断点续传；从 `apps/web/src-tauri/src/sftp/transfer.rs` 翻译 |
| `FileBrowser` UI | SwiftUI 双栏（本地 / 远端）|
| 拖拽上传 | NSDraggingDestination → 当前活跃 SFTP session 当前目录 |
| SFTP bookmarks | 复用 server `sftp_bookmark` schema |

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
| R8 | libghostty 版本升级 API breaks | 中 | 低-中 | git submodule 锁版本；遇到 break 再处理（v1 期间不主动升级）|

**最该盯死**：R1（spike 5 天内决断）、R7（纪律 + 增量 ship）。

---

## 9. 验证 & 验收

整个迁移不算"完成"，直到：

- [ ] Phase 0 spike 6 项 S1-S6 全部通过
- [ ] Phase 1 v1 全部 9 个 step（1.0-1.8）完成
- [ ] DoD（§6.4）逐条 ✅
- [ ] 老 Tauri 版引导迁移横幅上线
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
