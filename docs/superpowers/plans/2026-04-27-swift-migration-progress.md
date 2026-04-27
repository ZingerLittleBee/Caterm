# Swift 迁移进度跟踪

**项目**：Caterm 桌面端从 Tauri 重构为 Swift/SwiftUI + libghostty
**启动日期**：2026-04-27
**负责人**：@ZingerLittleBee

---

## 当前阶段

**Phase 0 — Brainstorming**

正在使用 `superpowers:brainstorming` skill 收敛设计。

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

---

## 产出物路径

- 设计文档：`docs/superpowers/specs/2026-04-27-tauri-to-swift-migration-design.md`（pending）
- 实现计划：`docs/superpowers/plans/2026-04-27-tauri-to-swift-migration-plan.md`（pending）
- 本进度文件：`docs/superpowers/plans/2026-04-27-swift-migration-progress.md`
