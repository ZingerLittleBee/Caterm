# Swift 迁移进度跟踪

**项目**：Caterm 桌面端从 Tauri 重构为 Swift/SwiftUI + libghostty
**启动日期**：2026-04-27
**负责人**：@ZingerLittleBee

---

## 当前阶段

**Phase 0 — Spike COMPLETE (2026-04-27)**

S1-S6 全部通过；技术路径基本锁定但**有重大架构调整**：libghostty 的公开 C API 不接受外部字节注入（surface 自己 spawn 命令并拥有 PTY），所以原 spec §3-§4 设计的 "swift-nio-ssh → MainActor → ghostty.feed(data)" 通路在 v1 不可行。v1 改走 `command="/usr/bin/ssh user@host"` 由 libghostty 自己 spawn ssh 子进程。

详见 `docs/superpowers/specs/2026-04-27-spike-findings.md` 与 spec 修订列表。

下一步：基于 spike 发现重写 Phase 1 v1 设计章节（§3-§4、§7 凭据流、§6 测试），再写 Phase 1 实施计划。

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

---

## 产出物路径

- 设计文档：`docs/superpowers/specs/2026-04-27-tauri-to-swift-migration-design.md` ✅（三轮 review 通过）
- Phase 0 spike 计划：`docs/superpowers/plans/2026-04-27-phase-0-spike-plan.md` ✅
- Phase 1 v1 计划：待 spike 通过后写
- v1.1 同步计划：待 v1 ship 后写
- v2 SFTP 计划：待 v1.1 ship 后写
- 本进度文件：`docs/superpowers/plans/2026-04-27-swift-migration-progress.md`
