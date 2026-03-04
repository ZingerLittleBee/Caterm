# SSH Host 数据云端迁移设计

## 目标

将 `apps/web` 中存储在本地 SQLite + Stronghold 的 SSH Host 数据（元数据 + 凭据）和终端设置迁移到 `apps/server` 的 PostgreSQL 云端数据库，通过 oRPC API 提供 CRUD 接口。

## 决策

- **凭据存储**：全部迁移到云端，服务端 AES-256-GCM 加密
- **终端设置**：一并迁移到云端
- **认证方式**：复用 better-auth
- **离线支持**：无，完全依赖云端

---

## 数据模型

### `ssh_host` 表（新建，`packages/db`）

| 列名 | 类型 | 说明 |
|---|---|---|
| id | text PK | UUID，客户端生成 |
| userId | text FK → user.id | 所属用户，cascade 删除 |
| name | text | 显示名称 |
| hostname | text | 主机地址 |
| port | integer, default 22 | 端口 |
| username | text | SSH 用户名 |
| authType | text | "password" 或 "key" |
| password | text, nullable | AES-256-GCM 加密后的密码 |
| privateKey | text, nullable | 加密后的私钥 |
| keyPassphrase | text, nullable | 加密后的 passphrase |
| createdAt | timestamp | 创建时间 |
| updatedAt | timestamp | 更新时间 |

### `terminal_settings` 表（新建）

| 列名 | 类型 | 说明 |
|---|---|---|
| id | serial PK | 自增 |
| userId | text FK → user.id, unique | 每用户一条 |
| fontFamily | text, default "monospace" | 字体 |
| fontSize | integer, default 14 | 字号 |
| cursorStyle | text, default "block" | 光标样式 |
| cursorBlink | boolean, default true | 光标闪烁 |
| scrollback | integer, default 1000 | 滚动行数 |
| theme | text, default "dark" | 主题 |

### 加密方案

- 算法：AES-256-GCM（Node.js `crypto` 模块）
- 密钥：环境变量 `ENCRYPTION_KEY`（32 字节 hex 字符串）
- 存储格式：`iv:authTag:ciphertext`（base64 编码）
- 加密字段：password、privateKey、keyPassphrase

---

## API 层（`packages/api`）

所有接口使用 `protectedProcedure`，需要用户登录。

### `sshHostRouter`

| Procedure | 输入 | 操作 |
|---|---|---|
| `sshHost.list` | 无 | 查询当前用户所有 host（不返回凭据字段） |
| `sshHost.getById` | `{ id }` | 按 ID 查询（返回解密后的凭据），校验 userId |
| `sshHost.create` | `{ name, hostname, port, username, authType, password?, privateKey?, keyPassphrase? }` | 插入并加密凭据 |
| `sshHost.update` | `{ id, ...fields }` | 更新，凭据字段有值时重新加密 |
| `sshHost.delete` | `{ id }` | 删除，校验 userId |

### `terminalSettingsRouter`

| Procedure | 输入 | 操作 |
|---|---|---|
| `terminalSettings.get` | 无 | 获取当前用户设置（无则返回默认值） |
| `terminalSettings.upsert` | `{ fontFamily?, fontSize?, ... }` | 创建或更新设置 |

### 加密工具

新建 `packages/api/src/utils/crypto.ts`：
- `encrypt(plaintext: string): string`
- `decrypt(encrypted: string): string`

---

## Web 端改造（`apps/web`）

### 认证

1. 引入 `better-auth` 客户端，配置指向 server 端 URL
2. 新增 `/login` 路由，sign-in / sign-up 表单
3. `/ssh` 路由 `beforeLoad` 检查 session，未登录重定向

### 数据层替换

**移除**：
- `@tauri-apps/plugin-sql` 的 SQLite 调用
- `@tauri-apps/plugin-stronghold` 的凭据存储
- `lib/stronghold.ts`、`lib/config-sync.ts`

**替换为**：
- `@orpc/client` + `@orpc/tanstack-query` 调用 server 端 API

### 组件变更

| 组件 | 变更 |
|---|---|
| `host-list.tsx` | SQLite → `orpc.sshHost.list` + TanStack Query |
| `host-form.tsx` | SQLite → `orpc.sshHost.create/update` mutation |
| `host-delete-dialog.tsx` | SQLite → `orpc.sshHost.delete` mutation |
| `connect-dialog.tsx` | Stronghold → `orpc.sshHost.getById`（解密凭据） |
| `terminal-settings-form.tsx` | SQLite → `orpc.terminalSettings.get/upsert` |
| `ssh-session-provider.tsx` | 凭据来源改为 API |
| `__root.tsx` | 添加 QueryClientProvider |

### SSH 连接流程

1. 调用 `orpc.sshHost.getById` 获取 host + 解密凭据
2. 传给 Tauri `invoke("ssh_connect", ...)` — Rust SSH 逻辑不变

---

## 环境变量

`apps/server/.env` 新增：
```
ENCRYPTION_KEY=<64 字符 hex 字符串>
```

`apps/web` 新增配置：
```
VITE_SERVER_URL=http://localhost:3001  # server 端地址
```
