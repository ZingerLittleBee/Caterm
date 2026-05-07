# SSH 连接进度展示 — Design

**Date:** 2026-05-07
**Scope:** `apps/macos` — Caterm 桌面端 SSH 连接生命周期的可视化反馈
**Status:** Draft, awaiting plan

---

## 1. Background

Caterm 当前的 SSH 连接流程没有任何可视化反馈。用户在 `HostListSidebar` 双击或在 sidebar 选中 host 后,`SessionStore.openTab` 立刻把 tab 加入列表,`TerminalContainerView` 渲染出 `GhosttySurfaceNSView`,libghostty 在内部 fork 出 `ssh user@host` 子进程。在 ssh 完成 DNS 解析、TCP 连接、SSH 握手、认证之前,**用户看到的是空白的深色终端**;如果连接失败,用户能看到的只有 ssh 自己输出的英文错误,且这段错误马上随子进程退出而被 `markChildExited` 后的状态接管。

体验问题:

- 慢连接(VPN、跨地域、移动网络)期间用户不知道是否还在工作中,常误以为应用卡死
- DNS 错误、host 不可达、端口拒绝等网络类错误,需要用户阅读 ssh 的英文 stderr 才能定位
- 认证失败后,只看到一闪而过的 stderr 然后是 `failed` 状态(目前没有 `failed` 的 UI 蒙层)
- 没有 retry 入口,用户必须手动关掉 tab 再重新打开

业内成熟实现(Termius)在终端区中央显示蒙层,带 spinner、主机名、阶段文案、失败时的 Retry / Edit Host 按钮。本设计采用同款交互。

## 2. Goals & Non-Goals

**Goals**

- 连接过程中可视化两个阶段:`Connecting…`(网络可达性)和 `Authenticating…`(认证及之后)
- 网络类错误使用具体的中文/英文文案,而不是裸露的 ssh stderr
- 失败状态保留蒙层,提供 `Retry` 和 `Edit Host` 操作
- 连接成功时蒙层平滑淡出(~150ms),不打断用户输入第一行命令

**Non-Goals**

- 不做 SSH 协议级 4 阶段细分(DNS / TCP / handshake / auth)— 解析 `ssh -v` 的 stderr 脆弱,且 4 阶段对用户的修复路径区分意义低
- 不重新设计 `ReconnectOverlay` — 它的语义(倒计时重试)与初次连接不同,保留独立组件
- 不做 settings 暴露的超时配置 — 先固定 5s,等用户反馈再加
- 不做 snapshot 测试框架引入 — 视觉验证走 `apps/macos/Manual` 手动 checklist

## 3. Architecture

### 3.1 连接检测策略

通过 **TCP 预连接探测**(`Network.framework` 的 `NWConnection`)在启动 ssh 子进程之前判定网络可达性。这个决策的关键理由:

- DNS 失败、`ECONNREFUSED`、`ETIMEDOUT`、`ENETUNREACH` 在 `NWConnection` 启动状态机中都映射成具体的 `NWError` 类型,文案可控且语言中立
- libghostty 子进程模式下,我们 `exec ssh` 后 stderr 不被分流,无法在不侵入 ghostty 的前提下解析其内部输出
- 5s 内的 TCP 探测不会显著拉长成功路径(SSH 握手本来就需要 TCP 连接,提前做一次相当于把诊断窗口前移)

被拒绝的备选:

- **解析 `ssh -v` stderr** — 需要给 libghostty 的 ssh 子进程加 `-v` 标志、分流 stderr、按行匹配英文模式。脆弱(ssh 版本差异、多语言)、侵入(改 ghostty 分流)、且 ROI 低
- **时间启发式**(当前的 3s 计时器)— 不可靠,慢网络上 3s 时仍在认证

### 3.2 连接流程(新)

```
用户触发 connect(SessionStore.openTab)
  ↓
state = .preflight(startedAt:)
  ↓
NWConnection.probe(host, port, timeout=5s)
  ├─ 失败 → state = .failed(.networkUnreachable(reason))    ← UI 显示 FailureOverlay
  └─ 成功 → 关闭探测连接
  ↓
state = .authenticating(startedAt:)                          ← UI 显示 ConnectingOverlay,
                                                                此刻才创建 GhosttySurfaceNSView
  ↓
3s grace 后进程仍存活 → state = .connected                  ← UI 移除 overlay,淡出 150ms
  ↓
ssh 子进程退出 → markChildExited → FailureKind.classify
  ├─ exit 0   → .cleanExit         (无 overlay,session 自然结束)
  ├─ 未连过   → .authOrSetupFail   (UI 显示 FailureOverlay)
  └─ 已连过   → .connectionDropped (UI 显示 ReconnectOverlay,既有逻辑)
```

### 3.3 模块边界

```
SessionStore (module)
├── ConnectionState.swift          ← 扩展 enum
├── FailureKind.swift              ← 扩展 enum + NetworkErrorReason
├── Preflight.swift                ← 新: NWConnection 封装
├── PreflightProbing.swift         ← 新: 协议(测试替身)
└── SessionStore.swift             ← 新: startConnection / retryTab

Caterm/Views (executable target)
├── ConnectingOverlay.swift        ← 新: 成功路径蒙层
├── FailureOverlay.swift           ← 新: 失败路径蒙层
├── FailurePresentation.swift      ← 新: FailureKind → 文案/图标 helper
└── TerminalContainerView.swift    ← 修改: ZStack 分支根据 state 显示对应 overlay
```

`Preflight` 不依赖 `SwiftUI/AppKit`,纯 `Foundation + Network`。`PreflightProbing` 协议让 `SessionStoreConnectionFlowTests` 注入替身,不依赖真实网络。

## 4. Detailed Design

### 4.1 `ConnectionState`(扩展)

```swift
public enum ConnectionState: Equatable {
    case idle
    case preflight(startedAt: Date)        // 新
    case authenticating(startedAt: Date)   // 重命名自 .connecting,语义为"ssh 子进程已启动"
    case connected(connectedAt: Date)
    case reconnecting(attempt: Int, nextRetryAt: Date)
    case failed(FailureKind)
}
```

`.connecting` 废弃。所有调用点(目前仅 `TerminalSurfaceRepresentable`、`SessionStore` 内部、相关测试)迁移到 `.authenticating` 或 `.preflight`。

### 4.2 `FailureKind`(扩展)

```swift
public enum FailureKind: Equatable {
    case authOrSetupFail
    case cleanExit
    case connectionDropped
    case networkUnreachable(NetworkErrorReason)   // 新

    public static func classify(exitCode: Int32, hadConnected: Bool) -> FailureKind {
        // 不变 — TCP 预连接失败由 SessionStore.startConnection 直接构造
        // .networkUnreachable,不会进入 classify 路径
        if exitCode == 0 { return .cleanExit }
        if hadConnected { return .connectionDropped }
        return .authOrSetupFail
    }
}

public enum NetworkErrorReason: Equatable {
    case dnsFailed
    case connectionRefused
    case timedOut
    case networkDown
    case other(code: Int, message: String)
}
```

**Reconnect 策略**:`.networkUnreachable` 不进入 `ReconnectScheduler.shouldReconnect`(初次连接的网络问题不自动重试,用户需主动 Retry — 防止用户在错配置下持续敲服务器)。`.connectionDropped` 行为不变。

### 4.3 `Preflight`

```swift
import Network

public protocol PreflightProbing: Sendable {
    func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome
}

public enum PreflightOutcome: Equatable {
    case ok
    case failed(NetworkErrorReason)
}

public struct Preflight: PreflightProbing {
    public init() {}
    public func probe(host: String, port: UInt16, timeout: TimeInterval = 5) async -> PreflightOutcome {
        // 1. 构造 NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        //    使用 .tcp + parameters: .tcp(以确保 NWConnection 走 TCP)
        // 2. stateUpdateHandler:
        //    .ready                       → continuation.resume(.ok); cancel
        //    .failed(let err)             → map(err) → continuation.resume(.failed(reason)); cancel
        //    .waiting(let err) ≥ timeout  → 同上(本地无网络等长时挂起情况)
        // 3. asyncStream + DispatchQueue.global timeout 触发器,超时返回 .failed(.timedOut)
    }
}
```

**NWError 映射规则**:

| NWError | NetworkErrorReason |
|---|---|
| `.dns(_)` | `.dnsFailed` |
| `.posix(.ECONNREFUSED)` | `.connectionRefused` |
| `.posix(.ETIMEDOUT)` 或 timeout 触发 | `.timedOut` |
| `.posix(.ENETUNREACH)` / `.ENETDOWN` / `.EHOSTUNREACH` | `.networkDown` |
| 其它 | `.other(code: posixCode.rawValue, message: err.localizedDescription)` |

### 4.4 `SessionStore` 新增方法

```swift
private let preflight: PreflightProbing  // injected via init, default Preflight()

public func startConnection(tabId: UUID) async {
    guard let host = tabs.first(where: { $0.id == tabId })?.host else { return }
    update(tabId) { $0.state = .preflight(startedAt: Date()) }
    let outcome = await preflight.probe(host: host.hostname,
                                        port: UInt16(host.port),
                                        timeout: 5)
    switch outcome {
    case .ok:
        update(tabId) { $0.state = .authenticating(startedAt: Date()) }
    case .failed(let reason):
        update(tabId) { $0.state = .failed(.networkUnreachable(reason)) }
    }
}

public func markAuthenticating(tabId: UUID) {
    // Kept for the rare case that callers want to manually transition; main
    // entry remains startConnection. Replaces the old markConnecting.
    update(tabId) { $0.state = .authenticating(startedAt: Date()) }
}

public func retryTab(tabId: UUID) {
    update(tabId) {
        $0.surfaceGeneration += 1
        $0.lastFailure = nil
        $0.state = .idle
    }
    Task { await startConnection(tabId: tabId) }
}
```

`markConnecting` 删除(项目内调用点只有 `TerminalSurfaceRepresentable.makeNSView`,该处会在重写中调用 `startConnection`)。

### 4.5 `TerminalSurfaceRepresentable` 重写

关键变化:**只有 `state == .authenticating`(或之后)时才创建真正的 ssh-driving `GhosttySurfaceNSView`**。`.preflight` / `.failed` 阶段返回空占位。

```swift
struct TerminalSurfaceRepresentable: NSViewRepresentable {
    @EnvironmentObject var store: SessionStore
    let tabId: UUID
    let backgroundTransparencyEnabled: Bool

    func makeNSView(context _: Context) -> GhosttySurfaceNSView {
        guard let tab = store.tabs.first(where: { $0.id == tabId }) else {
            return GhosttySurfaceNSView(command: nil)
        }

        switch tab.state {
        case .idle, .preflight, .failed:
            // Placeholder — once startConnection completes successfully and
            // surfaceGeneration increments, SwiftUI will recreate this view.
            let view = GhosttySurfaceNSView(command: nil)
            view.setBackgroundTransparencyEnabled(backgroundTransparencyEnabled)
            // Kick off the preflight + auth on first appearance:
            if case .idle = tab.state {
                Task { @MainActor in await store.startConnection(tabId: tabId) }
            }
            return view

        case .authenticating, .connected, .reconnecting:
            // Build the real surface. Reuses the current implementation
            // body (config lookup, GhosttySurfaceNSView construction, the
            // `view.surface` polling Task that wires `onChildExit` and
            // schedules `markConnected` after the 3s grace period). The
            // ONLY change vs current code: the existing `store.markConnecting`
            // call at the top is removed — by this point state is already
            // `.authenticating`, set by `startConnection` before the
            // surfaceGeneration bump caused us to enter this branch.
            return makeRealSurface(...)
        }
    }

    func updateNSView(_ nsView: GhosttySurfaceNSView, context: Context) {
        // When state transitions to .authenticating, we rely on
        // surfaceGeneration to trigger SwiftUI to call makeNSView again with
        // the new state. updateNSView itself remains a no-op.
    }
}
```

**`surfaceGeneration` 在哪里 +1**:`startConnection` 进入 `.authenticating` 时,view 当前是 placeholder,我们需要 SwiftUI 重建 — 因此在 `startConnection` 内部把状态切换到 `.authenticating` 时同步执行 `update(tabId) { $0.surfaceGeneration += 1; $0.state = .authenticating(...) }`。`.id("\(tabId)-\(surfaceGeneration)")` 触发 SwiftUI 卸载 placeholder、重建真 surface。

**为什么 placeholder 也用 `GhosttySurfaceNSView(command: nil)`**:复用同一类型简化 `NSViewRepresentable` 的类型签名;`command: nil` 时 `GhosttySurfaceNSView` 不 fork 任何子进程,只是个深色 NSView,正好用作 overlay 后面的背景。

### 4.6 `TerminalContainerView` 蒙层路由

```swift
ZStack {
    TerminalSurfaceRepresentable(
        tabId: tabId,
        backgroundTransparencyEnabled: backgroundTransparencyEnabled
    )
    .id("\(tabId)-\(tab.surfaceGeneration)")

    overlay(for: tab.state, host: tab.host)
}
.animation(.easeOut(duration: 0.15), value: tab.state)

@ViewBuilder
private func overlay(for state: ConnectionState, host: SSHHost) -> some View {
    switch state {
    case .preflight(let startedAt):
        ConnectingOverlay(stage: .preflight, host: host, startedAt: startedAt)
    case .authenticating(let startedAt):
        ConnectingOverlay(stage: .authenticating, host: host, startedAt: startedAt)
    case .reconnecting(let attempt, let nextRetryAt):
        ReconnectOverlay(attempt: attempt, nextRetryAt: nextRetryAt)
    case .failed(let kind) where shouldShowFailureOverlay(kind):
        FailureOverlay(
            failure: kind, host: host,
            onRetry: { store.retryTab(tabId: tabId) },
            onEditHost: { /* navigate to host form */ }
        )
    case .idle, .connected, .failed(.cleanExit):
        EmptyView()
    }
}

private func shouldShowFailureOverlay(_ kind: FailureKind) -> Bool {
    switch kind {
    case .cleanExit, .connectionDropped: return false  // 前者无蒙层,后者由 ReconnectOverlay 接管
    case .authOrSetupFail, .networkUnreachable: return true
    }
}
```

### 4.7 `ConnectingOverlay`

输入:`stage: ConnectingStage(.preflight | .authenticating)`、`host: SSHHost`、`startedAt: Date`。

视觉:
- 背景:`Color.black.opacity(0.78)` 覆盖 `.ultraThinMaterial`
- 居中卡片:`VStack(spacing: 10)`,内含 `ProgressView` 旋转 spinner、阶段文案 (`Text("Connecting…")` 或 `Text("Authenticating…")`,字号 14, weight `.medium`)、`user@host:port` 行(等宽字体,字号 13,带颜色区分:user=蓝、@=灰、host=紫)
- elapsed 计时:`Timer.publish(every: 0.5)`,只在 `Date().timeIntervalSince(startedAt) >= 2` 后渲染,格式 `"elapsed %.0fs"`,字号 11,灰色

### 4.8 `FailureOverlay`

输入:`failure: FailureKind`、`host: SSHHost`、`onRetry: () -> Void`、`onEditHost: () -> Void`。

视觉:
- 同蒙层背景
- 卡片:图标(红圈 `!` for `.authOrSetupFail`、橙圈 `!` for `.networkUnreachable`)+ 标题文案 + `user@host` 行 + 错误详情(等宽小字,行高 1.4,最多 2 行,自动换行)+ 操作行 `[Retry] [Edit Host]`(主按钮 + 次按钮)

`FailurePresentation.swift`(helper):

```swift
struct FailurePresentation {
    var icon: FailureIcon         // .red / .orange
    var title: String
    var detail: String?
}

func presentation(for failure: FailureKind, host: SSHHost) -> FailurePresentation {
    switch failure {
    case .networkUnreachable(.dnsFailed):
        return .init(icon: .orange, title: "Host not found",
                     detail: "Could not resolve hostname \(host.hostname)")
    case .networkUnreachable(.connectionRefused):
        return .init(icon: .orange, title: "Connection refused",
                     detail: "Port \(host.port) is not accepting connections")
    case .networkUnreachable(.timedOut):
        return .init(icon: .orange, title: "Connection timed out",
                     detail: "No response from \(host.hostname):\(host.port) after 5 seconds")
    case .networkUnreachable(.networkDown):
        return .init(icon: .orange, title: "No network",
                     detail: "Check your internet connection")
    case .networkUnreachable(.other(_, let msg)):
        return .init(icon: .orange, title: "Connection failed", detail: msg)
    case .authOrSetupFail:
        return .init(icon: .red, title: "Authentication failed",
                     detail: "Permission denied — check credentials")
    case .cleanExit, .connectionDropped:
        // Should not be presented via FailureOverlay; caller filters them out.
        return .init(icon: .orange, title: "", detail: nil)
    }
}
```

### 4.9 Edit Host 跳转

`MainWindow` 已有 host 编辑入口(`HostFormView`)。`onEditHost` 通过现有的 sheet 触发机制弹出当前 host 的编辑表单。具体路径在 plan 阶段确认 `MainWindow` 的 host-form-presentation 状态变量,通过 `EnvironmentObject` 或 `NotificationCenter` 触发。

## 5. Testing

### 5.1 单元测试

`apps/macos/Tests/SessionStoreTests/PreflightTests.swift`(新)

- `127.0.0.1` 的随机未监听端口 → `.connectionRefused`
- `*.invalid` 域名 → `.dnsFailed`
- 测试中起一个临时 `NWListener` 监听 → 探测成功 `.ok`
- 注入 `timeout=0.1s` 探测一个 black-hole IP(如 `10.255.255.1`)→ `.timedOut`

`apps/macos/Tests/SessionStoreTests/SessionStoreConnectionFlowTests.swift`(新)

- `startConnection` + 替身返回 `.ok` → state 序列 `[.idle, .preflight, .authenticating]`
- `startConnection` + 替身返回 `.failed(.dnsFailed)` → state 序列 `[.idle, .preflight, .failed(.networkUnreachable(.dnsFailed))]`
- `retryTab` from `.failed` → `surfaceGeneration` +1, `lastFailure == nil`,后续 state 序列同上
- `markChildExited` 路径不变(已有测试覆盖)

替身实现:
```swift
final class FakePreflight: PreflightProbing {
    var outcome: PreflightOutcome = .ok
    func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome {
        outcome
    }
}
```

`SessionStore` init 增加 `preflight: PreflightProbing = Preflight()` 参数,生产代码不变,测试注入 fake。

### 5.2 手动验证

新增 `apps/macos/Manual/connection-progress-checklist.md`:

- ✅ 正常 host(2 阶段蒙层 → 淡出 → shell)
- ✅ 不存在的 hostname(显示 "Host not found")
- ✅ 错误端口如 22222(显示 "Connection refused")
- ✅ 黑洞 IP 如 `10.255.255.1`(5s 后显示 "Connection timed out")
- ✅ 错密码 host(2 阶段蒙层 → ssh 退出 → "Authentication failed" + Retry/Edit Host)
- ✅ 点击 Retry 重新走完整流程
- ✅ 点击 Edit Host 弹出 HostFormView 当前 host
- ✅ 已连接成功后断开网络(连接掉线)→ ReconnectOverlay(已有逻辑,验证未被破坏)

## 6. Migration & Rollout

- 单 PR 可完成:`SessionStore` 内部变更 + 新组件 + `TerminalContainerView` 切换 + 测试
- 不需要 feature flag — UX 改进对所有用户立刻生效
- 数据兼容:`ConnectionState` 是内存态,不持久化,枚举变更无迁移成本
- 现有 `markConnecting` 调用点全部更新到 `markAuthenticating` 或 `startConnection`(项目内调用点少,grep 一遍替换)

## 7. Open Questions(留给 plan 阶段)

- `Edit Host` 的精确 UI 跳转路径(读 `MainWindow` 现有 host-form 触发机制后定)
- `Preflight` 在测试中如何起 mock TCP listener:用 `NWListener` 直接起一个 TCP server,选随机端口 → 已知方案,plan 时确认 macOS sandbox/entitlements 限制
- `Edit Host` 触发后,如果 `MainWindow` 当前没有合适的 sheet 通道,是用 `NotificationCenter.post` 通知 `HostListSidebar`/`MainWindow` 弹 form 的方式,还是把 host-form-presentation state 提升到 `SessionStore`?plan 阶段读现有 `MainWindow.swift` 后定
