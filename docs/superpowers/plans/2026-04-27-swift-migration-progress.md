# Swift 迁移进度跟踪

**项目**：Caterm 桌面端从 Tauri 重构为 Swift/SwiftUI + libghostty
**启动日期**：2026-04-27
**负责人**：@ZingerLittleBee

---

## 当前阶段

**Phase 1 v1: 10/12 + Phase 2 v1.1: 11/11 + Phase 2 v1.2: 6/6 COMPLETE (2026-04-28)**

分支：`feature/phase-1-v1`。最近 commit `89b140c feat(macos): wire SyncPreferences into CatermApp`。

**测试**：134 tests 全绿（1 Docker E2E skip without `CATERM_E2E_DOCKER=1`）。从 60 → 91 (Phase 2 v1.1 baseline) → 97 (2.9) → 117 (2.10) → 134 (v1.2 +17)。

**Phase 1 v1 完成**：1.0–1.10。**剩余 1.11**（Release packaging + Sparkle + provisioning profile + Tauri banner）卡 Apple Developer 后台拉证书。

**Phase 2 v1.1 完成**：2.0–2.10（云同步 baseline + 启动 sync + mutation-debounce sync + manual/auto 协调 + needsCredentialSetup UX）。

**Phase 2 v1.2 完成**：v1.2.1 SyncPreferences ObservableObject + persistence；v1.2.2 HostSyncStore lastSyncedAt @Published + scheduleAutoSync auth gate + FakeServerSyncClient per-method error flags；v1.2.3 周期 15-min Timer.publish；v1.2.4 NSWorkspace.didWakeNotification handler；v1.2.5 SyncSettingsView Background sync toggle + caption + TimelineView-wrapped Last sync row + formatLastSyncedAt；v1.2.6 CatermApp 接入 @StateObject SyncPreferences 替换 stub。

**关键技术状态（必读）**：
- AMFI 在 Apple Silicon 上拒绝无 provisioning profile 的 `keychain-access-groups` restricted entitlement → dev 路径走 `accessGroup: nil`（login keychain）；production .app 需在 1.11 加 provisioning profile 嵌入或 Developer ID + Notarization。
- 真实 TeamID 是 `9VM4RM39R3`（cert OU），不是 CN 后缀的 `4GH398M5WH`。dev-codesign.sh 自动从 cert 提取。
- `CATERM_ASKPASS_STUFF=1` dev-only bootstrap：同一签名 binary 写 + 读 Keychain item 走 partition list trust，免去 macOS "Always Allow" 对话框。每次 codesign 重做后需重跑。
- `SSHHost = Host` typealias 在 SSHCommandBuilder/Host.swift 里（解决 SessionStore 引入 Combine 后 Foundation `NSHost` 名称冲突）。
- v1.2 load-bearing invariants（详见 spec §5.5）：`scheduleAutoSync` 顶部的 `authSession.isSignedIn` gate 让 periodic / wake / mutation-debounce 三路 auto silent no-op；`performSync` 末尾 `lastSyncedAt = Date()` 必须在 op 循环 **全部成功后** 才执行（partial-apply 失败时不前进）；`SyncSettingsView` 的 Last sync 行必须包 `TimelineView(.periodic(by: 30))`，否则失败时 `lastSyncedAt` 不变 → 短语冻结 → 失败可见性丢失；`NSWorkspace.shared.notificationCenter`（不是 `NotificationCenter.default`）才接得到 wake 事件；UserDefaults 测试隔离 mandatory（`UserDefaults(suiteName: "caterm-test-\(UUID().uuidString)")!`）。

下一会话起点：1.11 Release（要 Apple Developer 证书）或 v1.3 follow-ups（refresh-token / lastSyncAttemptedAt failing 徽章 / configurable interval）。

---

## 锁定的关键决策

- **目标优先级**：A（终端体验） > B（原生质感） > D（性能） > C（维护成本）
- **MVP 范围（v1）**：SSH 连接、libghostty 渲染 + 多 tab、主机列表、Keychain 凭据、自动重连
- **v1 砍掉**：登录/跨端同步、SFTP、终端拖拽上传、本地文件浏览器、SFTP bookmarks、终端设置同步
- **v1.1**：登录 + 同步 + 终端设置同步
- **v2**：SFTP 全套（含 bookmarks 和拖拽上传）
- **本地文件浏览器**：砍掉，不再纳入路线图
- **配置模型**：直接采用 libghostty 原生 schema，server 端同步存 Ghostty config，不做映射
- **Server 端策略**：完全不动，复用现有 oRPC API
- **Tauri 客户端**：立即冻结，不再维护（含 bug fix）；保留 `apps/web` 目录但 main 分支不再合并相关 PR
- **新客户端目录**：`apps/macos`（待用户最终确认命名）
- **v1 凭据存储**：仅本地 Keychain（v1 无同步，server 端不参与凭据流）
- **构建系统**：纯 SwiftPM（`Package.swift`），不引入 `.xcodeproj`；`.app` 打包用 swift-bundler，签名/notarization 用脚本
- **最低 macOS 版本**：14.0
- **执行策略**：Approach 1（先 spike 后垂直切片）
- **Spike 验收**：S1-S6（编译/渲染/SSH 字节流/全链路/反向输入/resize）

## 待定决策（在 brainstorming 中收敛）

- [ ] 新目录最终命名（`apps/macos` 是当前提议）
- [ ] SSH 库选型（swift-nio-ssh vs libssh2 vs Citadel）— 倾向 swift-nio-ssh
- [ ] libghostty 集成方式（vendor 预编译 vs submodule 自构建）
- [ ] v1.1 同步开启时凭据源（Keychain 主 + server 同步元信息 vs server 主 + Keychain 缓存）
- [ ] 分发渠道（Sparkle 直发 / Mac App Store / Homebrew Cask）
- [ ] 时间预期（业余时间节奏 vs 集中冲刺）

---

## 进度日志

| 日期 | 事件 |
|------|------|
| 2026-04-27 | Brainstorming 启动；锁定优先级 A>B>D>C 与 MVP 范围；本地 FS 浏览器砍掉 |
| 2026-04-27 | Tauri 客户端冻结（不再维护）；新 Swift 客户端建议放 `apps/macos` |
| 2026-04-27 | 锁定 Approach 1（spike 先行）；Section 1-4 设计通过 |
| 2026-04-27 | 构建系统锁定 SwiftPM（不引入 xcodeproj）；最低 macOS 14；libghostty 用 .xcframework binaryTarget |
| 2026-04-27 | 用户 review 提出 10 处修订，全部接受并修复（host key 校验 / 背压 / 重连语义 / D7-D10 矛盾 / D9 例外 / v2 文件浏览器单栏 / spike 凭据 / DoD 列举 / EmbeddedChannel 测试 / R8 升级仪式）|
| 2026-04-27 | 第二轮 review 8 处二次细化全部接受：架构图加 KnownHostStore；统一 AsyncThrowingStream；NIO API 名修正（autoRead / ChannelOptions.allowRemoteHalfClosure）；stdin 加界限处理 paste；spike host key 移到排除列；known_hosts 非 22 端口格式修正；v1.1 移除 bookmarks；新增 §7.1.2 凭据/metadata 同步边界纪律 |
| 2026-04-27 | 第三轮 review 5 处接受：sshHost.upsert → create/update（router 没 upsert）；新增 §7.1.3 本地 id ↔ server id 映射（方案 A 双 id，Keychain 锚定本地 id）；§4.1 加 TOFU 异步纪律（NIO event loop 不阻塞等 UI）；TODO(v1.2) → TODO(step-1.2)；§6.3 集成测试改为本地 + ship 前手动跑（与 R5 一致）|
| 2026-04-27 | Phase 0 spike 实施计划写好（9 Tasks，bite-sized 步骤，每 Task 末尾 commit + progress log），等用户跑 spike |
| 2026-04-27 | Spike Task 1 通过：SwiftPM 项目壳起来，`swift build` + `swift run` 出空白 SwiftUI 窗口。Branch `spike/phase-0` |
| 2026-04-27 | Spike Task 2 通过 (S1)：libghostty.xcframework 链接成功；ghostty submodule pinned at `bc90a5128`（v1.3.1 之后，有 fat-static-archive 修复 — v1.3.1 自己漏掉 `libghostty_zcu.o` 导致 macOS slice 没导出 embedding API）。Build script 容忍 zig 在 xcframework 产出后 app-bundle 步骤失败 |
| 2026-04-27 | Spike Task 3 通过 (S2)：libghostty surface 渲染默认 shell。架构发现：libghostty 没有外部字节注入入口（详见 spike-findings.md），spec §3-§4 NIOSSH-feed 路线 v1 不可行 |
| 2026-04-27 | Spike Task 4-8 合并通过 (S3-S6)：用 `command="/usr/bin/ssh user@host"` 绕开外部字节问题。OpenSSH-server Docker 容器作 target，欢迎 banner / prompt / `echo PID=$$` (→ "PID=238") / 拖拽 resize 后 `stty size` 14 76 → 41 145 全部观测到 |
| 2026-04-27 | **Phase 0 spike COMPLETE — S1-S6 全部通过；技术路径锁定（libghostty + ssh-as-subprocess），swift-nio-ssh 暂不入 v1。Findings 写入 `2026-04-27-spike-findings.md`**|
| 2026-04-27 | v1 auth UX 决策：三路并存（密码/Keychain、SSH key + passphrase/Keychain、ssh-agent 兜底），凭据来源是 enum。代价 +2-3 天写 askpass 二进制；spec §7.1 待重写为 enum 起稿。spike-findings 决策门记录 |
| 2026-04-27 | **设计 spec 大改**（一口气 §3/§4/§6/§7）：架构图 + 模块表去掉 SSHTransport/KnownHostStore/BoundedByteChannel，加 SSHCommandBuilder + AskpassHelper；§4.1 重写连接流（含三种 commandString + env_vars）；§4.2 删除 NIO/字节流模型，I/O 由 libghostty PTY 包办；§4.3 重连改成"销毁旧 surface + 同 command 建新 surface"+ 5s Connected 判定；§6.1 step 列表改 12 步含 askpass 子任务；§6.2 Host 模型加 CredentialSource enum + Keychain access group 命名；§6.3 测试矩阵换成 SSHCommandBuilder/AskpassHelper/失败模式分类；§7.1.2 加跨设备 needsLocalCredential 三路判定；R1/R2 关闭，R9（askpass 签名）/R10（locale 文本匹配）补上 |
| 2026-04-27 | **Spec review 7 处修复（H1-H4 + M1-M3）**：(H1) 改正 command 经 macOS bash 解析事实，强制 shell-quote 所有用户输入；(H2) 失败分类降级到 exit code + Connected 历史粗分（stderr 拿不到，stderr 文本匹配方案删除）；Connected 判定从"首字节"改成 grace period 3s alive 检查；scrollback 字节注入改成 NSView overlay；(H3) child-exit 信号源切到 GHOSTTY_ACTION_SHOW_CHILD_EXITED action + ghostty_surface_process_exited，不依赖 close_surface_cb（wait-after-command 强制 true 已 verify）；(H4) v1.1 CredentialSource 改成 device-local overlay，server 不动 schema，sshHost.create payload 仅含 metadata，不含 CredentialSource 完整状态；(M1) known_hosts hybrid 双文件（Caterm 写 + ~/.ssh 读继承）；(M2) 三路认证选项隔离（password 禁 pubkey / keyFile 禁 password+kbd / agent BatchMode=yes）；(M3) Keychain API 改 SecItemAdd/CopyMatching/Delete + kSecAttrAccessGroup，弃用 SecKeychain* legacy；同时删除 LANG=C / DISPLAY=:0 env（前者污染远端 locale，后者 FORCE 模式用不上）；R11 加 shell injection 风险 |
| 2026-04-27 | **Phase 1 v1 实施计划写好**（12 Tasks，TDD 节奏；spec §6.1 step 1.0-1.11 一一对应）：1.0 Package.swift 改 9 targets + 删 spike；1.1 TerminalEngine；1.2 SSHCommandBuilder + 60+ 个 fuzz 注入用例；1.3 AskpassHelper + KeychainStore + dev-codesign 端到端；1.4 单 tab connect + 双信号 child-exit 验证；1.5 NSWindow 多 tab；1.6 HostListSidebar + 表单 + JSON 持久化；1.7 KeychainStore 接 UI；1.8 ReconnectScheduler + overlay；1.9 ConfigStore；1.10 菜单/快捷键/About；1.11 release.sh + 双 binary codesign + notarize + Sparkle + Tauri banner。等开 fresh 仓 / 进 1.0 实施 |
| 2026-04-27 | Task 1.0 通过：spike 代码删除；Package.swift 重写为 9 targets（5 lib + 2 exec + 4 test）；entitlements plist 落位；`swift build` + `swift test` 全绿。Phase 1 干净 baseline 起来 |
| 2026-04-27 | Task 1.1 通过：TerminalEngine module 起来；GhosttySurface + GhosttySurfaceNSView 包装 libghostty；默认 shell 在 NSView 内渲染；resize OK；键盘输入 OK |
| 2026-04-27 | Task 1.2 通过：SSHCommandBuilder 三路 enum 实现完毕；ShellQuote POSIX；FuzzInjectionTests 60+ 用例（含分号/反引号/$()/单双引号/unicode/换行）全绿。凭据安全防线立起来 |
| 2026-04-27 | Task 1.3 DONE_WITH_CONCERNS：KeychainStore（SecItem* + 可选 access group，6 个测试全绿）；caterm-askpass 二进制实现完毕（env 驱动 host_id/kind 读 secret）；dev-codesign.sh 自动从证书 OU 提取真实 TeamIdentifier (`9VM4RM39R3`，非 spec 误写的 `4GH398M5WH`) 并替换 `$(TeamIdentifierPrefix)`，两个 binary 同 TeamID 签名通过。**端到端 access group 验证 BLOCKED**：amfid 拒绝 `keychain-access-groups` 这个 restricted entitlement，要求 development provisioning profile（exit 137 / "No matching profile found"）。dev v1 路径走"login keychain + accessGroup=nil"（KeychainStore API 已支持双模式；签名 binary 读 login keychain 全绿，Step 7 验证）。production .app 路径需要嵌 provisioning profile 或 Developer ID + Notarization，留给后续打包 task。Manual/end-to-end-smoke.md 全文记录约束与 fallback |
| 2026-04-27 | Task 1.4 通过：单 tab 端到端 SSH 通了；FailureKind 分类单测 3 个；GHOSTTY_ACTION_SHOW_CHILD_EXITED action callback + ghostty_surface_process_exited 双信号验证；Docker linuxserver/openssh-server 容器作 target，端到端 password auth via askpass + 登录 Keychain 跑通（EndToEndSSHTests 全绿）。SessionStore 是 @MainActor ObservableObject + Tab/ConnectionState FSM；CatermApp.SmokeConnectView 点连接驱动 GhosttySurfaceNSView，3s grace period 后 markConnected。绕过 macOS "Always Allow" ACL dialog 的关键：dev-only `CATERM_ASKPASS_STUFF=1` 模式让 askpass 二进制自己写 Keychain item（同签名身份在 partition list），后续 ssh 调用同一 binary 读时不弹窗。dev-codesign.sh 加 `CATERM_DEV_LOGIN_KEYCHAIN=1` (默认) 剥离 `keychain-access-groups` entitlement 避开 AMFI block。`SSHHost` typealias 加在 SSHCommandBuilder 模块解决 Combine→Foundation→NSHost 冲突。36 tests 全绿（不带 docker env 时 1 个 skip）|
| 2026-04-27 | Task 1.5 通过：NSWindow.allowsAutomaticWindowTabbing；每 tab 独立 SwiftUI WindowGroup window，macOS 自动合成 native tab；⌘T 新 tab 走 openWindow(value:) + NotificationCenter 桥（OpenTabBridge 拿 @Environment(\.openWindow)）；⌘W 默认行为关闭当前 tab；MainWindow.onDisappear 同步 SessionStore.closeTab；TerminalContainerView 拆出 reusable surface 渲染。**关键发现**：SwiftUI WindowGroup 的 NSWindow 默认 tabbingMode=.automatic，只 follow 系统 "Prefer tabs" 偏好；改在 AppDelegate 监听 didBecomeKey 把每个 NSWindow 设为 .preferred 才能稳定 auto-tab，不依赖用户系统设置。NSWindow.userTabbingPreference 是 read-only。验证：osascript probe 证 ⌘T 后 AX window 仍只有 1 个（高度从 532→568，多出 ~36pt 即 native tab bar）；⌘W 后 app 仍 alive。closeTab 单测 4 个新增。40 tests 全绿（1 docker skip）|
| 2026-04-27 | Task 1.6 通过：HostListSidebar + HostFormView + ConnectSecretDialog；hosts.json 持久化 0600 权限；CredentialSource enum 三路 UI 全打通；不再硬编码主机；NavigationSplitView 接入 MainWindow + LandingView。SessionStore 新增 hosts/hostsURL/keychain + addHost/updateHost/deleteHost/setHostSecret(SecretKind enum)；HostPersistence enum 静态 load/save (chmod 0600 + sortedKeys 输出)；HostListSidebar 用 List+selection / overlay 空态 / contextMenu (Connect/Edit/Delete) / 双击 Connect / sheet 双 mode (.add/.edit) / .onReceive(.catermAddHost) 桥。HostFormView segmented Picker 三路 + NSOpenPanel 浏览 + SecureField 条件渲染。⌘T 改为 New Host…（不再硬编码 Docker smoke）；既有 .catermOpenTab 桥保留。HostPersistenceTests 5 个（roundtrip/missing/perm/overwrite/SessionStore CRUD）。45 tests 全绿（1 docker skip）。osascript probe：window=1000x652（NavigationSplitView 1000 min 生效）|
| 2026-04-27 | Task 1.7 通过（实际工作大部分被 1.6 一并消化）：KeychainIntegrationTests 4 个新增（password roundtrip / passphrase roundtrip / deleteHost wipes single / deleteHost wipes both kinds），覆盖 SessionStore.setHostSecret + deleteHost 的 keychain 通配清理路径。49 tests 全绿（1 docker skip） |
| 2026-04-28 | Task 2.10 通过 (Phase 2 v1.1 follow-up)：auto-sync triggers 落地。(a) 启动时 .task { syncStore.syncIfSignedIn() } 走 WindowGroup root；(b) post-mutation 通过 SessionStore.mutationsForSync (PassthroughSubject + 公开 AnyPublisher，addHost/updateHost/deleteHost 在 HostPersistence.save 后 send，setCredentialOnly + 远端 apply ops 不发) → HostSyncStore .debounce(.seconds(2), .main) → scheduleAutoSync。Manual/auto coexistence 三 flag：manualInProgress 闸门 / pendingAutoAfterManual defer 重放 / currentManualTask 锁让并发 sync() 共享同一 in-flight。Chained cancel-and-drain 串行化（prev?.cancel(); await prev?.result; checkCancellation; performSync）保证 cooperative-cancel 间隙不会让两轮 apply 同时跑；checkCancellation 关键约束：performSync 里 listHosts 之后 + op loop 顶部各一次，绝对不在 apply(.createRemote) 里 createHost 和 setServerId 之间（那段窗口 cancel 会造成 server 有 host / 本地无 serverId → 下次 sync 重复 create）。HostSyncStore 改 ObservableObject 由 CatermApp 持成 @StateObject — 长寿命是 inFlight chain / cancellables / debounce timer 全部 invariant 的 load-bearing 前提。AuthSessionProtocol（仅 isSignedIn）从 AuthSession 抽出来给测试注入，FakeAuthSession 没 URL 包袱。SyncSettingsView 错误类型 String? → ServerSyncError?，Account section 三态（signedOut / signedIn / sessionExpired）由 internal accountState(isSignedIn:lastSyncError:) 派生；isAuthFailure 同时匹配 .http(401) 和 .orpc(_, 401, _)（oRPC 路由 401 包在 envelope 不是 .http，pin by ServerSyncClientHTTPTests:58）。Session-expired 出 "Sign In Again…" 短路两步登出登入。+20 tests（5 SessionStoreMutationPublisher / 9 HostSyncStoreAutoSync / 6 SyncSettingsAccountState），suite 97 → 117 全绿。Spec: 2026-04-28-task-2.10-auto-sync-triggers-design.md；Plan: 2026-04-28-task-2.10-auto-sync-triggers.md。Commits: eaf8fdf / 888e58e / ca49bd8 / 1342dec / d0d6b7c / f76bac6 / 1c72b4d / 2b6383e |
| 2026-04-28 | **v1.2 Brainstorm + Spec：周期 sync (c) + freshness display**。两轮 review 修复（4+2 处）：(P1) `scheduleAutoSync` 顶部加 `authSession.isSignedIn` gate — periodic / wake / mutation-debounce 三路 auto 全部走 funnel，signed-out 时静默 no-op；manual 故意豁免（cookie-still-present-but-server-401 是 `.sessionExpired` 恢复路径）。(P2) "Background sync" toggle 同时管 timer **和** wake — wake handler 加 `guard preferences.periodicSyncEnabled` 让 metered-connection 用户的预期成立；caption 改 "Syncs every 15 minutes and on wake from sleep." 让 UI 文案与行为一致。(P3) `lastSyncedAt` 必须在 op 循环全部成功**后**写，partial-apply 失败（`listHosts` 成功但 `createHost` throw）不前进 freshness — 加 `testLastSyncedAtUnchangedOnPartialApplyFailure` 用 `FakeServerSyncClient.createHostError` per-method flag 钉死。(P4) 测试 UserDefaults 隔离从 "for hygiene, prefer" 改 mandatory：`UserDefaults(suiteName: "caterm-test-\(UUID().uuidString)")!` 强制写入，否则测试污染开发者 `~/Library/Preferences`。第二轮：(P3-1) Last sync 行包 `TimelineView(.periodic(from: .now, by: 30))` — `RelativeDateTimeFormatter` 在 body-eval 时 resolve `Date()`，没 timeline 时失败的 `lastSyncedAt` 不变 → 短语冻结 → 失败可见性丢失（load-bearing for failure visibility）。(P3-2) 措辞修正：`Sync Now` 按钮的 `.disabled(!authSession.isSignedIn || isSyncing)` 必须保留，manual sync 的 auth-exempt 只覆盖 *cookie 还在但 server 401* 场景，不是 fully signed out（fully signed out 用户根本到不了 SyncSettingsView，看到 SignInView 了）。Spec: `2026-04-28-task-v1.2-periodic-sync-and-freshness-design.md`，commit `060f4f3` + `179293a` |
| 2026-04-28 | **Phase 2 v1.2 6/6 通过**：(v1.2.1 `f5b0a28`) `SyncPreferences` ObservableObject — `@Published periodicSyncEnabled: Bool` 默认 true，`didSet` 写 UserDefaults `catermPeriodicSyncEnabled` key；`@MainActor public final class`；CatermApp 持成 `@StateObject`，注入 HostSyncStore + SyncSettingsView 共享一份。+3 tests。(v1.2.2 `eda9855`) HostSyncStore 加 `preferences/periodicInterval/userDefaults` init params；`@Published lastSyncedAt: Date?` hydrate from UserDefaults `catermLastSyncedAt`；`scheduleAutoSync` 加 `authSession.isSignedIn` 闸；`performSync` 末尾 `lastSyncedAt = Date()` 写在 op 循环之后；`FakeServerSyncClient` 加 per-method error flags（`listHostsError/createHostError/updateHostError/deleteHostError`）；测试 setUps 强制 `UserDefaults(suiteName: "caterm-test-\(UUID().uuidString)")!`。+6 tests。(v1.2.3 `bbadeab`) `preferences.$periodicSyncEnabled.sink → handlePeriodicEnabled` + `Timer.publish(every: periodicInterval, on: .main, in: .common).autoconnect()`；`@Published .sink` current-value 语义保证 default-true 在 init 同步 fire 启动 timer；`handlePeriodicEnabled` 幂等（cancel-and-recreate）让 wake re-arm 安全。+3 tests。(v1.2.4 `c5c2202`) `import AppKit` + `NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)`（**不是 NotificationCenter.default**，wake 走另一个 center） + `handleSystemWake` toggle-gated（`guard preferences.periodicSyncEnabled`）+ 调 `handlePeriodicEnabled(true)` 重新 arm 让下次 fire = wake + 15min。+3 tests。(v1.2.5 `ec2658d`) SyncSettingsView：`let syncStore` → `@ObservedObject var syncStore` + 加 `@ObservedObject var preferences`；Sync section 加 `Toggle("Background sync", isOn: $preferences.periodicSyncEnabled)` + caption "Syncs every 15 minutes and on wake from sleep." + `TimelineView(.periodic(from: .now, by: 30)) { _ in Text("Last sync: \(formatLastSyncedAt(syncStore.lastSyncedAt))") }`；`formatLastSyncedAt(_: Date?) -> String` free function 用 `RelativeDateTimeFormatter`（locale-tolerant）。Sync Now 按钮保留 `.disabled(!authSession.isSignedIn || isSyncing)`。+2 tests。(v1.2.6 `89b140c`) CatermApp 加 `@StateObject var preferences: SyncPreferences`，init 实例化一次串入 HostSyncStore.init 和 SyncSettingsView，替换 v1.2.2/v1.2.5 的 `TODO(v1.2.6)` stub。**Suite 117 → 134 全绿**（1 Docker skip）。Plan: `2026-04-28-task-v1.2-periodic-sync-and-freshness-implementation.md`（commit `458e0a2`）。subagent-driven-development 节奏：sonnet implementer + 每 task verbatim plan transcribe + 检查 diff，无 fixup（v1.2.2/v1.2.5 的 stub 不算）|

---

## 产出物路径

- 设计文档：`docs/superpowers/specs/2026-04-27-tauri-to-swift-migration-design.md` ✅（三轮 review 通过 + spike 后大改 + 7 处 review 修复）
- Phase 0 spike 计划：`docs/superpowers/plans/2026-04-27-phase-0-spike-plan.md` ✅
- Phase 1 v1 计划：`docs/superpowers/plans/2026-04-27-phase-1-v1-implementation.md` ✅（12 Tasks，TDD 节奏，bite-sized 步骤，每 Task 末尾 commit + 进度日志）
- Phase 2 v1.1 计划：`docs/superpowers/plans/2026-04-28-phase-2-v1.1-host-sync-implementation.md` ✅
- 2.10 设计 spec：`docs/superpowers/specs/2026-04-28-task-2.10-auto-sync-triggers-design.md` ✅
- 2.10 实施计划：`docs/superpowers/plans/2026-04-28-task-2.10-auto-sync-triggers.md` ✅
- v1.2 设计 spec：`docs/superpowers/specs/2026-04-28-task-v1.2-periodic-sync-and-freshness-design.md` ✅（两轮 review 通过，4+2 处修复）
- v1.2 实施计划：`docs/superpowers/plans/2026-04-28-task-v1.2-periodic-sync-and-freshness-implementation.md` ✅（6 Tasks）
- v2 SFTP 计划：待 v1 ship 后写
- 本进度文件：`docs/superpowers/plans/2026-04-27-swift-migration-progress.md`
