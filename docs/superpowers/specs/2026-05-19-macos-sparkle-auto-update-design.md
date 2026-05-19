# macOS 应用内自动更新（Sparkle）设计

- 日期：2026-05-19
- 状态：已批准设计，待写实现计划
- 范围：仅 macOS `Caterm` target；iOS 不涉及

## 目标

让已安装的 Caterm macOS 应用能自动检查、下载并安装新版本，无需用户手动去
GitHub 下载 dmg。采用 [Sparkle 2](https://sparkle-project.org/)——App Store
外分发 macOS 应用的事实标准。

## 关键约束（实地核验）

- 应用**未启用沙盒**（hardened runtime + Developer ID + 公证），Sparkle
  集成无需 XPC 服务相关 entitlements。
- 发布版本号 = `CHANGELOG.md` 中**第一个 `## [X.Y.Z]` release 条目**
  （顶部是 `## [Unreleased]`，必须跳过）。这与
  `publish-release.sh:53-55` 现有解析 `grep -m1 -E '^## \[[0-9]'` 一致。
- **发布包的 `Info.plist` 不是 `Resources/Info.plist`**：真实
  `.app/Contents/Info.plist` 由 `Scripts/dist-package.sh:135` 用 heredoc
  现场生成。给 `Resources/Info.plist` 加 Sparkle 键**不会**进发布包。
- **SwiftPM 外部打包不会自动 embed framework**：`dist-package.sh:121-122`
  只建 `Contents/MacOS` 和 `Contents/Resources`，没有 `Contents/Frameworks`。
  Sparkle 官方文档（sparkle-project.org/documentation/）要求外部构建系统
  自行 copy `Sparkle.framework`、保留 symlink、配置 rpath。
- 现有 `release.sh` **不读 CHANGELOG**：`CATERM_DIST_VERSION` 默认 `1.0.0`、
  `CFBundleVersion` 默认 `1`。Sparkle 主要靠 `CFBundleVersion` 比较版本——
  若恒为 `1`，自动更新永远检测不到新版。**修复版本注入是本设计的必需环节。**
- 首个集成 Sparkle 的版本必须手动分发（旧版本没有 updater）；从该版本起
  之后所有版本自动更新。

## 已定方向（brainstorming 收敛）

| 决策 | 选择 |
|---|---|
| 更新框架 | Sparkle 2（SPM） |
| Appcast 托管 | GitHub Releases 资产，稳定 URL `releases/latest/download/appcast.xml` |
| 更新 UX | 后台定时检查 + Sparkle 标准窗口提示安装（显示 CHANGELOG notes） |
| 下载产物 | zip 的 `.app`（复用 publish 已产出的 ditto-zip） |
| Appcast 生成 | 方案 A：Sparkle 官方 `generate_appcast`（自动签名 + 注入 notes，未来可支持 delta） |

## 架构与数据流

### 运行时（客户端）

```
App 启动 → SPUStandardUpdaterController 后台定时检查
  → GET https://github.com/ZingerLittleBee/Caterm/releases/latest/download/appcast.xml
  → 比对 appcast 的 CFBundleVersion vs 本地 CFBundleVersion
  → 有新版：弹 Sparkle 标准窗口（CHANGELOG HTML release notes）
  → 用户点"更新" → 下载 Caterm-<X.Y.Z>-app.zip → 校验 EdDSA 签名
  → 替换 .app → 重启
```

### 发布期（扩展现有 `make release` / `make publish`）

```
CHANGELOG 第一个 ## [X.Y.Z] release 条目（跳过 [Unreleased]）
  → release.sh 派生 CFBundleShortVersionString=X.Y.Z、CFBundleVersion=单调整数
  → 构建 .app（内嵌已 Developer-ID 深度签名 + 公证的 Sparkle.framework）
  → publish.sh 现有顺序：Gatekeeper gate → ditto-zip 出
      Caterm-<X.Y.Z>-app.zip（publish-release.sh:141，注意是 -app.zip）
  → 在 zip 同目录写同 basename 的 Caterm-<X.Y.Z>-app.html（CHANGELOG section）
  → generate_appcast <dir>：对 zip 算 enclosure EdDSA 签名（sparkle:edSignature
      + length + sparkle:version=CFBundleVersion），并把同名 .html 设为
      releaseNotesLink，产出 appcast.xml
  → gh release（非 draft / 非 prerelease）：
      上传 Caterm-<X.Y.Z>-app.zip + Caterm-<X.Y.Z>-app.html + appcast.xml + .dmg
```

## 组件设计

### 1. `Package.swift`

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
```

仅加入 `Caterm` target 的 dependencies
（`.product(name: "Sparkle", package: "Sparkle")`）。iOS target 及其它库
target 不引用——Sparkle 是 macOS-only，错误链接会破坏 iOS 构建。

### 2. Updater 集成（App 代码）

- 新建 `Sources/Caterm/Updates/UpdaterController.swift`，封装一个
  `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
  userDriverDelegate: nil)`。
- 单一职责：只暴露 `checkForUpdates()` 与 `canCheckForUpdates`，
  不持有任何业务逻辑。
- **为可测性，wrapper 依赖一个协议**（如 `UpdaterDriving`，对齐
  `SPUUpdater` 的相关方法），生产用 `SPUStandardUpdaterController`
  实现注入，单测注入 fake。**不要**在单测里真的
  `SPUStandardUpdaterController(startingUpdater: true)`——它会读测试
  bundle 的 Info.plist，缺 `SUFeedURL`/`SUPublicEDKey` 时触发 Sparkle
  misconfiguration 行为，测试不稳。
- SwiftUI 中以 `@StateObject` 持有；主菜单 `CommandGroup(after: .appInfo)`
  加"检查更新…"，绑定 `checkForUpdates()`。
- 后台自动检查由 Info.plist 键控制，无需额外代码。

### 3. Info.plist 新增键（改 dist-package.sh，不是 Resources/Info.plist）

发布包 Info.plist 在 `Scripts/dist-package.sh:135` 的 heredoc 里生成——
新键必须加在那个 heredoc 中。`Scripts/dev-run-app.sh:100` 的 dev 包也单独
生成 Info.plist；为保证开发期能测自动更新，同样补上这些键（dev/dist 两处
plist 内容抽成共享片段或共用变量，避免漂移）。`Resources/Info.plist` 仅
SwiftPM 资源用途，与发布包无关，保持原样。

| Key | 值 |
|---|---|
| `SUFeedURL` | `https://github.com/ZingerLittleBee/Caterm/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | EdDSA 公钥（base64，进仓库，安全且必须） |
| `SUEnableAutomaticChecks` | `true` |
| `SUScheduledCheckInterval` | `86400`（每天一次，可调） |

### 3b. Embed Sparkle.framework（dist-package.sh 缺失的关键步骤）

`dist-package.sh` 的 bundle 组装段（约 `:119-122`）必须新增：

- `mkdir -p "$APP/Contents/Frameworks"`
- 用 `ditto` 或 `cp -R`（保留 framework 内部 symlink 与
  `Versions/Current` 结构）拷入 `Sparkle.framework`。
  **路径不可硬猜**：Sparkle SPM 是 binary target，产物在
  `.build/artifacts/.../Sparkle/...` 这类非稳定路径，随 SwiftPM 版本/
  config 变化。实现须写 `find_sparkle_framework` helper：在 `.build`
  下定位，断言**唯一存在**、含目标架构（`lipo -info` 或 `file`）、
  结构完整，找不到/多个则报错退出，绝不取第一个猜。
- 校验主可执行文件含 `LC_RPATH = @executable_path/../Frameworks`
  （SwiftPM 链接 Sparkle 时通常已写入；用 `otool -l` 验证，缺则
  `install_name_tool -add_rpath` 补）。
- 这是新增逻辑，须配 `make doctor` 校验项：发布包内存在
  `Contents/Frameworks/Sparkle.framework` 且 rpath 正确。

### 4. EdDSA 密钥管理（最关键、最易错）

- 一次性用 Sparkle `generate_keys` 生成密钥对。
- **私钥**：存登录 Keychain（`generate_keys` 默认）；**绝不进 git**；加密
  备份一份至 `sign/`（已 gitignore）。丢私钥 = 永远无法再发自动更新。
- **公钥**：写进 `Info.plist` 的 `SUPublicEDKey`。
- publish 期 `generate_appcast` 自动从 Keychain 取私钥签名，脚本中不出现
  任何密钥材料。

**签名语义澄清**：本期只用 **enclosure archive 的 EdDSA 签名**
（appcast 里每个 item 的 `sparkle:edSignature`）——这是 Sparkle 校验
下载产物完整性的基线，由 `generate_appcast` + Keychain 私钥自动产生，
客户端用 `SUPublicEDKey` 验证。`SURequireSignedFeed`
（Sparkle 2.9+，对**整个 appcast/release notes**额外签名）是另一回事，
**本期不启用**（GitHub HTTPS 已保证 feed 传输完整性，启用它会引入
2.9+ 版本与额外签名步骤约束）。列入「不做」。

### 5. 内嵌 Sparkle 深度签名（发布陷阱）

**XPC 组件策略——明确选「保留全部，逐层签」**（非「删除不需要的 XPC
services 后 re-sign」）。理由：非沙盒 app 不需要 Sparkle 的
`Installer`/`Downloader` XPC services，删除是体积优化，但 re-sign 残缺
framework 易错；本期按 YAGNI 保留完整 framework 全部签名，删 XPC 留作
未来优化（写入「不做」段）。

`.app/Contents/Frameworks/Sparkle.framework` 内的每个嵌套可执行体
（`Autoupdate`、`Updater.app`、`XPCServices/*.xpc`、framework dylib）必须：

- 用 Developer ID **由内向外显式逐层**签名（不依赖 `codesign --deep`，
  它对嵌套 .app/.xpc 不可靠）
- 带 hardened runtime + secure timestamp
- 然后再签外层 `.app`，整个 `.app` 一起送公证

扩展 `release.sh` 签名段实现；`make doctor` 新增 Sparkle 内嵌组件签名
校验项（`codesign --verify --deep --strict` + `spctl`）。

## 版本号方案

`release.sh` 从 CHANGELOG **第一个 `## [X.Y.Z]` release 条目**
（跳过 `## [Unreleased]`，复用 `publish-release.sh:53-55` 的
`grep -m1 -E '^## \[[0-9]'`）解析语义版本，派生：

- `CFBundleShortVersionString = X.Y.Z`（显示用）
- `CFBundleVersion = X*10000 + Y*100 + Z`（如 `1.1.0`→`10100`，`1.2.3`→`10203`）

单调、纯函数、无状态、不依赖 git。约束：单段 < 100（合理范围）。

这同时修掉现有 `CATERM_DIST_VERSION` 默认 `1.0.0` 陷阱——版本统一从
CHANGELOG 派生。与 `publish-release.sh` 已有解析逻辑合并，抽成共享
`Scripts/lib-version.sh`。

## publish-release.sh 改动

更正：zip 由 **publish-release.sh 自己**在 `:141` 用
`ditto -c -k --keepParent` 生成，名为 `Caterm-${VERSION}-app.zip`
（变量 `APP_ZIP`，定义于 `:64`）；`release.sh` 不产 zip。release notes
当前写到 `mktemp` 临时文件（`NOTES_FILE`，`:89`）。

正确插入顺序——在现有 Gatekeeper gate + zip（`:141`）**之后**、
`gh release create`（`:160`）**之前**：

1. 建一个**专用 staging 目录**（如 `$BIN_DIR/appcast-stage/`），
   **只** `cp` 进 `Caterm-${VERSION}-app.zip`。`generate_appcast`
   接收的是「update archives folder」，绝不能直接喂 `$BIN_DIR`——
   那里还有 `.dmg`、`Caterm.app`、SwiftPM build 产物、临时 notarize
   zip，会让 appcast 混入 dmg / 重复版本 / 脏 artifact。
2. 生成 release notes 的 HTML：现有 `NOTES_FILE` 是从 CHANGELOG 抽出的
   **原始 markdown**（`### 小标题` + `- 列表`），不是 HTML。须经
   markdown→最小 HTML 文档转换（带 `<html><body>` 包裹），写到 staging
   里与 zip 同 basename 的 `Caterm-${VERSION}-app.html`。不转换直接塞
   markdown 进 `.html` → Sparkle 窗口能显示但样式塌掉。转换器选型在
   实现计划定（优先无新依赖的方案，否则退而用同名 `.md` 并接受
   Sparkle 2.9+/macOS 12 约束——二选一在计划里拍板）。`NOTES_FILE`
   仍用作 gh `--notes-file`。
3. 对 **staging 目录** 跑 `generate_appcast`，产出 `appcast.xml`
   （含 enclosure `sparkle:edSignature`、`length`、`sparkle:version`、
   同名 notes 文件自动成为 `sparkle:releaseNotesLink`）。
4. `gh release create` 资产列表在现有 `$DMG $APP_ZIP` 基础上追加
   staging 里的 `appcast.xml` 与 `Caterm-${VERSION}-app.html`。
5. 保留现有 Gatekeeper 硬门禁；新增门禁：发布前校验 `.app` 内
   `Contents/Frameworks/Sparkle.framework` 已正确逐层签名 + 公证。
6. 强制本次 release 非 draft / 非 prerelease（否则 `releases/latest`
   指针不指向它，feed 失效）；现有 `--draft` 标志与自动更新发布互斥，
   脚本在 `--draft` 时显式报错退出。

## 错误处理

- 私钥不在 Keychain → publish 立即失败，提示 `generate_keys` 步骤，绝不发
  无签名 appcast。
- `generate_appcast` 缺失 → 报错附安装指引，不静默跳过。
- feed 不可达 / 签名不匹配 → Sparkle 客户端静默失败、保持当前版本
  （Sparkle 内建行为，无需额外代码）。

## 测试策略

- **单元**：`lib-version.sh` 的 semver→build number 派生，边界
  `0.9.0`、`1.10.2`、单段 ≥100 应报错。Swift 侧测 wrapper **逻辑**
  （注入 fake `UpdaterDriving`，验证 `checkForUpdates()` 转发、
  `canCheckForUpdates` 透传），**不**真初始化 Sparkle。真实
  `SPUStandardUpdaterController` 启动放手动 smoke，或单独的
  `startingUpdater: false` + `@MainActor` 测试。
- **集成**：本地 `python -m http.server` 托管测试 appcast + 旧版本号 .app，
  验证 Sparkle 真能弹更新窗 → 写进 `Manual/` 冒烟清单（GUI + 重启，
  自动化成本过高）。
- **回归**：`make test` 保持全绿；`make doctor` 新增 Sparkle 签名校验。

## 文档

`README.md` Release 段 + `docs/macos-dev-signing.md` 补充：一次性
`generate_keys`、私钥备份、首个 Sparkle 版本需手动分发。

## 不做（YAGNI）

- 不引入 CI（当前是本地 `make publish` 流程）。
- 暂不实现 delta 增量更新（`generate_appcast` 已为未来留路）。
- 不做静默自动安装、不做 App 内 Settings 开关（用 Sparkle 默认 UX）。
- 不启用 `SURequireSignedFeed` / `SUVerifyUpdateBeforeExtraction`
  （仅用 enclosure EdDSA 签名 + GitHub HTTPS feed）。
- 不删除非沙盒下用不到的 Sparkle XPC services（保留完整 framework
  逐层签名；删除属未来体积优化）。
- iOS 自动更新（平台不支持，走 App Store / TestFlight）。
