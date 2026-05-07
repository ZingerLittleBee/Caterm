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

**端口校验顺手收紧**:`HostFormView.isValid`(`HostFormView.swift:144`)当前仅 `Int(port) != nil`,允许 `-1` / `99999` 之类越界值进入数据层。本 spec 顺带改成 `Int(port).map { (1...65535).contains($0) } ?? false`,从入口处堵住非法端口,避免 `UInt16(host.port)` 在 `Preflight` 里崩溃。已存在的旧数据由 `startConnection` 内部的 `(1...65535).contains(host.port)` 检查兜底,转 `.invalidPort` 失败态(详见 §4.4),不会进入 `NWConnection` 路径。

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
    case invalidPort(Int)                          // 新: host.port ∉ 1...65535
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

/// Per-tab attempt token. Bumped by every `startConnection` invocation so
/// stale probe results from a cancelled attempt cannot mutate state.
private var connectionAttempts: [UUID: UInt64] = [:]

/// Single entry point for "kick off connection for this tab". Idempotent:
/// callers (`openTab` follow-up, `retryTab`) can both call it; the attempt
/// token guards against stale async results.
///
/// Validates `host.port` ∈ 1...65535 before launching the probe. Out-of-range
/// ports return `.networkUnreachable(.invalidPort)` directly without touching
/// NWConnection (whose `NWEndpoint.Port` initializer would trap on UInt16
/// overflow).
public func startConnection(tabId: UUID) async {
    guard let host = tabs.first(where: { $0.id == tabId })?.host else { return }
    let token = (connectionAttempts[tabId] ?? 0) &+ 1
    connectionAttempts[tabId] = token

    guard (1...65535).contains(host.port) else {
        applyIfCurrent(tabId: tabId, token: token) {
            $0.state = .failed(.networkUnreachable(.invalidPort(host.port)))
        }
        return
    }

    applyIfCurrent(tabId: tabId, token: token) {
        $0.state = .preflight(startedAt: Date())
    }

    let outcome = await preflight.probe(
        host: host.hostname,
        port: UInt16(host.port),
        timeout: 5
    )

    applyIfCurrent(tabId: tabId, token: token) { tab in
        switch outcome {
        case .ok:
            tab.surfaceGeneration += 1               // ← forces SwiftUI to
            tab.state = .authenticating(startedAt: Date())  //   recreate the surface
        case .failed(let reason):
            tab.state = .failed(.networkUnreachable(reason))
        }
    }
}

/// Apply a tab mutation only if the recorded attempt token still matches
/// — i.e., a newer `startConnection` hasn't superseded this one.
private func applyIfCurrent(tabId: UUID, token: UInt64,
                             _ mutate: (inout Tab) -> Void) {
    guard connectionAttempts[tabId] == token else { return }
    update(tabId, mutate)
}

public func retryTab(tabId: UUID) {
    update(tabId) {
        $0.lastFailure = nil
        $0.state = .idle
    }
    Task { await startConnection(tabId: tabId) }
}
```

`markConnecting` 删除。新的连接触发**仅**由两处发起,`makeNSView` 不再有任何 `startConnection` 副作用(避免与 retry 路径并发):

- `openTab(host:)` 返回前增加 `Task { await startConnection(tabId: id) }`
- `retryTab(tabId:)` 内部启动

`startConnection` 的 attempt token 保证哪怕真的因为视图生命周期被叫两次,后到的 outcome 也只能写到当前 token 对应的 tab 上,陈旧的探测结果会被静默丢弃。

### 4.5 `TerminalContainerView` 占位 / 真 surface 切换

⚠️ **关键约束**:`GhosttySurfaceNSView.viewDidMoveToWindow` 在 `command == nil` 时会让 `GhosttySurface` 回退到 `$SHELL`,**会真的 fork 一个本地 shell**。所以 placeholder 绝不能用 `GhosttySurfaceNSView`。

正确做法:**在 `TerminalContainerView` 内根据 state 二选一渲染**,让 `TerminalSurfaceRepresentable`(及它内部的 `GhosttySurfaceNSView`)**只在 `.authenticating | .connected | .reconnecting` 时存在于视图树**。`.idle | .preflight | .failed` 时渲染纯 SwiftUI 占位(深色 `Color`,带 ssh 终端默认背景的色调),没有任何 NSView 被创建。

```swift
struct TerminalContainerView: View {
    @EnvironmentObject var store: SessionStore
    let tabId: UUID

    var body: some View {
        ZStack {
            if let tab = store.tabs.first(where: { $0.id == tabId }) {
                surfaceOrPlaceholder(for: tab)
                overlay(for: tab.state, host: tab.host)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.tabs.first(where: { $0.id == tabId })?.state)
    }

    @ViewBuilder
    private func surfaceOrPlaceholder(for tab: SessionStore.Tab) -> some View {
        switch tab.state {
        case .authenticating, .connected, .reconnecting:
            TerminalSurfaceRepresentable(
                tabId: tabId,
                backgroundTransparencyEnabled: backgroundTransparencyEnabled
            )
            .id("\(tabId)-\(tab.surfaceGeneration)")

        case .idle, .preflight, .failed:
            // Inert SwiftUI background — no NSView, no $SHELL fork.
            Color.black.opacity(0.95).ignoresSafeArea()
        }
    }

    // overlay(for:host:) — see §4.6
}
```

`TerminalSurfaceRepresentable` 本体几乎不用改:

- 删除现有的 `store.markConnecting(tabId: tabId)` 调用 — 进入这个分支时 state 已经是 `.authenticating`,由 `startConnection` 推过来
- 删除 3s grace + `markConnected` 的 `Task.sleep(3_000_000_000)` 部分 — 由 `startConnection` 的语义接管:authenticating 进来意味着 TCP 已通,3s grace 改成"surface 创建后 3s 内进程未退出 → markConnected"的现有逻辑可以保留(避免破坏现有测试,且 ssh 子进程刚 fork 出来仍可能瞬间失败)

**`startConnection` 在何时 bump `surfaceGeneration`**:见 §4.4 代码块 — 与 `.authenticating` 状态切换在同一 `update` 闭包里原子完成,SwiftUI 看到 id 变化就会卸载占位、装入真 surface。

**Retry 不会有 race**:retry 路径是 `state = .idle → startConnection → .preflight → .authenticating(+gen)`。中间 `.idle / .preflight` 阶段 surface 不存在(被 `Color` 占位替换),不存在两个并发 ssh 子进程的可能。

### 4.6 蒙层路由(`overlay(for:host:)` 实现)

承接 §4.5 的 `TerminalContainerView.body` 结构,`overlay(for:host:)` 函数:

```swift
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
    case .networkUnreachable(.invalidPort(let p)):
        return .init(icon: .red, title: "Invalid port",
                     detail: "Port \(p) is out of range (1–65535) — edit host to fix")
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

### 4.9 Edit Host 跳转(NotificationCenter 桥接)

实际调研:edit sheet state 不在 `MainWindow`,而是 `HostListSidebar` 的 `@State var editingHost: SSHHost?`(`HostListSidebar.swift:24`),sheet 绑定在 `HostListSidebar.swift:94` 的 `.sheet(item: $editingHost)`。

把这个状态提到全局(EnvironmentObject 或 SessionStore)会牵动 sidebar 的责任边界,且 `editingHost` 是临时 UI 状态、不应进数据层。**采用 NotificationCenter 桥接** — 改动最小:

```swift
// 新增 in apps/macos/Sources/Caterm/Views/HostListSidebar.swift 同文件
extension Notification.Name {
    static let catermEditHostRequested = Notification.Name("catermEditHostRequested")
}
struct CatermEditHostRequestedKeys {
    static let hostId = "hostId"
}
```

`FailureOverlay.onEditHost`:
```swift
NotificationCenter.default.post(
    name: .catermEditHostRequested,
    object: nil,
    userInfo: [CatermEditHostRequestedKeys.hostId: host.id]
)
```

`HostListSidebar.body` 加 `.onReceive(NotificationCenter.default.publisher(for: .catermEditHostRequested))`,从 userInfo 取出 hostId,在 `store.hosts` 里找到 host,设 `editingHost = host` 触发 sheet。如果 host 已被删除则忽略。

为什么这条路径合理:与项目里已有的 `catermHostCredentialMaterialChanged`(`SessionStore.swift`)是同种模式,保持一致。

## 5. Testing

### 5.1 单元测试

`apps/macos/Tests/SessionStoreTests/PreflightTests.swift`(新)

- `127.0.0.1` + 随机未监听端口 → `.connectionRefused`(快速、确定性)
- 测试中起一个临时 `NWListener` 监听随机端口 → 探测成功 `.ok`
- ❌ 不再放黑洞 IP 超时测试 — 跨 VPN/路由会非确定性返回 unreachable 而不是 timed out;同时 `*.invalid` DNS 测试也移除(各 macOS 版本 / DNSSEC 行为不一)。这两类语义改成由 SessionStore 测试覆盖(注入 `FakePreflight` 直接返回对应 outcome)。
- 真实 timeout 路径:用 `NWListener` 起一个 accept-then-stall 的服务(接受 TCP 但不发 SYN-ACK 之外的字节;实际更简单:用 firewall rule 不可行,改成纯计时验证 — 在 `Preflight` 内部抽出一个 `internal func makeTimeoutTask(_:)`,单独测它能在 timeout 时 cancel connection 并返回 `.timedOut`)。
- DNS / networkDown 等 reason 的映射验证:抽出 `internal func mapNWError(_ err: NWError) -> NetworkErrorReason`,直接喂构造好的 `NWError` 值进去断言映射,不依赖真实网络。

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

- `Preflight` 在测试中起 `NWListener` 监听随机端口 — plan 时确认 macOS sandbox / SPM test target entitlements 是否允许(预期允许,因为绑 `127.0.0.1` 的 loopback listener 在 sandbox 下通常是 OK 的;如果不允许,fallback 是把 `Preflight` 的 connection 部分接口化,纯单元测打 mock)
- `openTab` 触发 `startConnection` 的具体方式:`openTab` 当前是同步 `-> UUID`,`Task { @MainActor in await store.startConnection(tabId: id) }` 在返回前 fire-and-forget。需要在 plan 时确认,把异步 fire 放在 `openTab` 内部(对所有调用点透明),还是在每个 caller 处显式触发。前者更不容易漏,选前者。
