# Caterm

[English](README.md) | **简体中文**

原生 macOS SSH 终端管理器，支持 iCloud 同步，无需自建服务器。

[![Latest release](https://img.shields.io/github/v/release/ZingerLittleBee/Caterm)](https://github.com/ZingerLittleBee/Caterm/releases/latest)

Caterm 是一个 SwiftUI 应用，终端引擎基于 [libghostty](https://github.com/ghostty-org/ghostty)。
主机、凭据、设置和代码片段会通过 iCloud 在你的多台 Mac 之间同步——凭据端到端加密，
绝不会以明文形式离开你的设备。无需注册账号，也无需运行任何后端。

## 下载

[下载最新版本](https://github.com/ZingerLittleBee/Caterm/releases/latest)。
应用经过 Developer ID 签名、公证（notarized）并已 staple。下载
`Caterm-<version>.dmg`，打开后将 Caterm 拖入「应用程序」即可。

要求 **macOS 14.0 或更高版本**。

同步功能需要 Mac 已登录 iCloud——没有独立账号。未登录时，Caterm 仍可作为
纯本地终端管理器完整使用，只是不会同步。没有降级模式，也没有打扰式提示。

## 截图

![带标签页和主机侧边栏的 Caterm 终端](docs/images/hero.png)

| 主机链式跳转 | SFTP 抽屉 | 主题 |
|---|---|---|
| ![主机链式跳转](docs/images/host-chaining.png) | ![SFTP 抽屉](docs/images/sftp-drawer.png) | ![主题选择器](docs/images/theme-picker.png) |

| 终端设置 | iCloud 同步 |
|---|---|
| ![终端设置](docs/images/settings.png) | ![iCloud 同步设置](docs/images/sync.png) |

## 功能

### 终端

- 基于 Ghostty 的终端界面，支持标签页会话和可折叠的主机列表侧边栏
  （`⌘B` 切换）。
- 内置 `xterm-ghostty` terminfo，支持按主机选择性远程安装。
- 完整的终端设置 UI（字体、光标、配色、行为），由托管的 Ghostty
  配置快照支撑，并提供诊断信息展示。
- 从 Ghostty 提取的主题目录，配有可搜索的选择器、收藏网格，以及
  按主机覆盖主题的能力。

### SSH

- 主机增删改查，标签可选（缺省回退为 `user@host`）。
- 通过 `ProxyJump` 进行主机链式跳转，配有 Via 主机选择器、链路预览、
  环路检测，以及按会话生成的 `ssh_config`。
- 按主机配置端口转发（本地 / 远程 / 动态）。
- ControlMaster 连接复用，并具备确定性的拆除流程。
- 链路感知的 askpass，可在跨跳转的凭据提示中工作。

### SFTP

- 带传输队列的文件传输抽屉。
- 按主机持久化的远程路径书签。

### iCloud 同步（无服务器）

- 通过 CloudKit 私有数据库同步主机，使用增量变更令牌（change
  tokens）和一个强制全量的兜底机制。
- 端到端加密的凭据同步：使用 **AES-256-GCM** 密封的数据块，主密钥
  存放在可同步的 iCloud Keychain 中——对 Apple 仅暴露密文。
- 通过 `NSUbiquitousKeyValueStore` 同步设置，基于修订号的
  last-writer-wins 策略，对损坏或 schema 不兼容的数据块予以隔离。
- 代码片段（snippet）存储与同步。

## 安全

Caterm 会同步 SSH 凭据，因此加密模型经过刻意设计：

- **凭据端到端加密。** 每个凭据字段在离开设备前都用
  **AES-256-GCM** 密封（以关联数据进行认证，将其绑定到对应的
  主机、字段和修订号）。
- **主密钥只存在于你的 iCloud Keychain 中。** 它是一个 256 位
  对称密钥，作为*可同步的* Keychain 项存储，因此通过 Apple
  端到端加密的 iCloud Keychain 在你的多台 Mac 间传播——Apple
  无法读取它。
- **不同数据，不同路径。** 密封的凭据数据块随 CloudKit `Host`
  记录传输；主密钥随 iCloud Keychain 传输。Apple 在 CloudKit
  一侧只看到密文，且从不持有解密它的密钥。
- **设置**通过 `NSUbiquitousKeyValueStore` 同步，不属于敏感数据；
  损坏或 schema 不兼容的数据块会被隔离而非应用。
- **丢失设备**不会泄露凭据：没有主密钥，这些数据块毫无用处，而
  主密钥受你的 Apple ID 和 iCloud Keychain 安全码保护。一如往常，
  在 Apple ID 设备管理中吊销丢失的 Mac 即可。

没有 Caterm 服务器，也没有 Caterm 账号——我们这一侧没有任何东西可
被攻破，因为根本不存在「我们这一侧」。

## 从源码构建

### 前置条件

- macOS 14.0+，并安装 Xcode 命令行工具（Swift 5.10+）。
- Homebrew [`zig@0.15`](https://formulae.brew.sh/formula/zig@0.15)——构建
  libghostty 所需。预期位于 `/opt/homebrew/opt/zig@0.15/bin/zig`。

### 步骤

```bash
git clone https://github.com/ZingerLittleBee/Caterm.git
cd Caterm

# 初始化 Ghostty 子模块并构建 Frameworks/GhosttyKit.xcframework
make ghostty-kit

make run-app          # 构建 + 代码签名 + 封装为 Caterm.app + 启动
```

`make run-app` 是默认的开发循环——裸二进制启动会崩溃，因为应用会
注册 APS 推送，而这需要 bundle 身份（bundle identity）。

## 开发

```bash
make test             # swift test
make build            # swift build (debug)
make doctor           # 工具链 / 签名诊断
make help             # 列出所有 target
```

本地开发的代码签名会从 `CATERM_DEV_IDENTITY`、`.dev-identity` 或登录
keychain 解析签名身份。签名相关的坑及完整原理见
[`docs/macos-dev-signing.md`](docs/macos-dev-signing.md)。

### 调试

```bash
make run-app          # 构建 + 代码签名 + 封装为 Caterm.app + 启动（前台）
make run-bg           # 同上，但后台运行；stdout/stderr -> /tmp/caterm.log
make kill             # 杀掉正在运行的开发进程

tail -f /tmp/caterm.log               # 跟踪 `make run-bg` 的日志
log stream --predicate 'subsystem == "com.caterm.app"' --level debug  # os_log
```

始终使用 `make run-app` / `make run-bg`，不要用裸二进制（`make run`）：
应用在启动时会调用 `NSApp.registerForRemoteNotifications()`，这需要
bundle 身份——裸二进制会在此处崩溃。

要用调试器单步执行，可将 LLDB 附加到 debug 构建：

```bash
make build
lldb .build/debug/caterm           # (lldb) run
# 或附加到已运行的实例：
lldb -p "$(pgrep -nf .build/debug/caterm)"
```

运行时日志通过 `os_log` 输出，子系统为 `com.caterm.app`（在
Console.app 中按类别过滤——例如 `cloudkit-sync`、`snippet-sync`、
`signing-diag`）。

## 发布

### 一次性设置（维护者）

构建可分发的、经过公证的发布版本需要你自己的 Apple Developer
账号。所有身份和凭据都存放在 git 之外、被 gitignore 的 `sign/`
目录中——不会提交任何个人信息。

1. 登录 keychain 中拥有一个属于你团队的 **Developer ID
   Application** 证书。
2. 一份针对你 App ID 的 **Distribution 描述文件**（Developer ID
   类型），配置 `aps-environment=production` 和
   `icloud-container-environment=Production`。保存为
   `sign/Caterm_Developer_ID.provisionprofile`——`release.sh`
   会自动从该路径解析。
3. 一个名为 `caterm` 的 **notarytool keychain 配置**（应用专用
   密码会被安全地提示输入；切勿提交）：

   ```bash
   xcrun notarytool store-credentials caterm \
       --apple-id <your-apple-id> --team-id <your-team-id>
   ```

4. 通过 CloudKit Console 为你的 iCloud 容器将 **CloudKit schema
   部署到 Production** 一次（Schema → Deploy to Production）。

如有配置异常，`make doctor` 会打印解析出的签名诊断信息。

### 每次发布

```bash
# 1. 在 CHANGELOG 顶部新增一个带日期的版本小节。
$EDITOR CHANGELOG.md

# 2. 构建 + Developer ID 签名 + 公证 + staple + dmg。
make release
#    make release ARGS=--skip-notary   仅签名（在自己的 Mac 上冒烟测试）
#    make release ARGS=--skip-dmg      仅 .app，不生成磁盘镜像

# 3. 打 tag + GitHub release + 上传 .dmg 和打包的 .app。
make publish
#    make publish ARGS=--dry-run       打印每一步操作，不做任何改动
#    make publish ARGS=--draft         以草稿形式创建 release
```

`make release`（[`Scripts/release.sh`](Scripts/release.sh)）会自动解析
Developer ID 身份、描述文件和 notary 配置，然后依次执行 build →
distribution 代码签名（两遍 entitlement 重新密封 + askpass
entitlement 隔离）→ bundle 组装 → 公证 → staple → dmg →
Gatekeeper 评估。

`make publish`（[`Scripts/publish-release.sh`](Scripts/publish-release.sh)）
受 Gatekeeper 把关——它会拒绝发布未经公证和 staple 的构建——它会推送
一个带注解的 `v<version>` tag，并创建 GitHub release，发布说明取自
[`CHANGELOG.md`](CHANGELOG.md) 中匹配的小节。CHANGELOG 的版本驱动
tag，因此它必须指向你打算发布的提交（干净的工作树，且已推送到
`origin/main`）。

## 架构

一个 Swift Package Manager 项目（`Package.swift`），拆分为若干聚焦的
模块——终端引擎、SSH 命令构建器、会话存储、CloudKit / 凭据 / 设置
同步客户端、SFTP，以及 SwiftUI 应用 target。没有后端服务：所有同步
都流经用户的私有 CloudKit 数据库和 iCloud Keychain。

## 致谢

Caterm 的终端由 [Ghostty](https://github.com/ghostty-org/ghostty)
（libghostty）驱动，以子模块形式 vendored 并构建进
`GhosttyKit.xcframework`。Ghostty 采用 MIT 许可证；感谢 Mitchell
Hashimoto 和 Ghostty 的贡献者们。

## 许可证

[MIT](LICENSE) © ZingerLittleBee。捆绑的 libghostty 采用 MIT
许可证，并继续遵循其自身条款。
