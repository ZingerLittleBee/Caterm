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
- 版本号来自 `CHANGELOG.md` 顶部 `## [X.Y.Z]` 条目。
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
  → 用户点"更新" → 下载 Caterm-<X.Y.Z>.app.zip → 校验 EdDSA 签名
  → 替换 .app → 重启
```

### 发布期（扩展现有 `make release` / `make publish`）

```
CHANGELOG 顶部 X.Y.Z
  → release.sh 派生 CFBundleShortVersionString=X.Y.Z、CFBundleVersion=单调整数
  → 构建 .app（内嵌已 Developer-ID 深度签名 + 公证的 Sparkle.framework）
  → publish.sh: generate_appcast 对 Caterm-<X.Y.Z>.app.zip 算 EdDSA 签名
      → 产出 appcast.xml（签名 + 长度 + 版本 + CHANGELOG HTML notes）
  → gh release（非 draft / 非 prerelease）：
      上传 Caterm-<X.Y.Z>.app.zip + appcast.xml + .dmg
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
- 单一职责：只暴露 `checkForUpdates()` 与 `canCheckForUpdates`（可独立测试），
  不持有任何业务逻辑。
- SwiftUI 中以 `@StateObject` 持有；主菜单 `CommandGroup(after: .appInfo)`
  加"检查更新…"，绑定 `checkForUpdates()`。
- 后台自动检查由 Info.plist 键控制，无需额外代码。

### 3. `Resources/Info.plist` 新增键

| Key | 值 |
|---|---|
| `SUFeedURL` | `https://github.com/ZingerLittleBee/Caterm/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | EdDSA 公钥（base64，进仓库，安全且必须） |
| `SUEnableAutomaticChecks` | `true` |
| `SUScheduledCheckInterval` | `86400`（每天一次，可调） |

### 4. EdDSA 密钥管理（最关键、最易错）

- 一次性用 Sparkle `generate_keys` 生成密钥对。
- **私钥**：存登录 Keychain（`generate_keys` 默认）；**绝不进 git**；加密
  备份一份至 `sign/`（已 gitignore）。丢私钥 = 永远无法再发自动更新。
- **公钥**：写进 `Info.plist` 的 `SUPublicEDKey`。
- publish 期 `generate_appcast` 自动从 Keychain 取私钥签名，脚本中不出现
  任何密钥材料。

### 5. 内嵌 Sparkle 深度签名（发布陷阱）

非沙盒 + hardened runtime 下，`.app` 内嵌的 `Sparkle.framework`（含
`Autoupdate`、`Updater.app`、XPC bundle）必须：

- 用 Developer ID 对内嵌组件**显式逐层**深度签名（不依赖 `codesign --deep`）
- 带 hardened runtime + secure timestamp
- 整个 `.app` 一起送公证

扩展 `release.sh` 签名段实现；`make doctor` 新增 Sparkle 内嵌组件签名校验项。

## 版本号方案

`release.sh` 从 CHANGELOG 顶部 `## [X.Y.Z]` 解析语义版本，派生：

- `CFBundleShortVersionString = X.Y.Z`（显示用）
- `CFBundleVersion = X*10000 + Y*100 + Z`（如 `1.1.0`→`10100`，`1.2.3`→`10203`）

单调、纯函数、无状态、不依赖 git。约束：单段 < 100（合理范围）。

这同时修掉现有 `CATERM_DIST_VERSION` 默认 `1.0.0` 陷阱——版本统一从
CHANGELOG 派生。与 `publish-release.sh` 已有解析逻辑合并，抽成共享
`Scripts/lib-version.sh`。

## publish-release.sh 改动

在现有「打 tag → gh release」之间插入：

1. 定位 `Caterm-<X.Y.Z>.app.zip`（release.sh 已产出）。
2. 取 Sparkle artifact bundle 的 `generate_appcast`，对该 zip 跑一遍，注入
   CHANGELOG section 为 HTML release notes，产出 `appcast.xml`。
3. `gh release create` 资产列表追加 `appcast.xml` 与 `.app.zip`。
4. 保留现有 Gatekeeper 硬门禁；新增门禁：发布前校验 `.app` 内 Sparkle 组件
   已正确签名 + 公证。
5. 强制本次 release 非 draft / 非 prerelease（否则 `releases/latest` 指针
   不指向它，feed 失效）；`--draft` 与自动更新发布互斥，脚本显式报错。

## 错误处理

- 私钥不在 Keychain → publish 立即失败，提示 `generate_keys` 步骤，绝不发
  无签名 appcast。
- `generate_appcast` 缺失 → 报错附安装指引，不静默跳过。
- feed 不可达 / 签名不匹配 → Sparkle 客户端静默失败、保持当前版本
  （Sparkle 内建行为，无需额外代码）。

## 测试策略

- **单元**：`lib-version.sh` 的 semver→build number 派生，边界
  `0.9.0`、`1.10.2`、单段 ≥100 应报错。Swift 侧 `UpdaterController` 加
  轻量 XCTest 验证可初始化、`canCheckForUpdates` 可读。
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
- iOS 自动更新（平台不支持，走 App Store / TestFlight）。
