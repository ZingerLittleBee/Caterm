# SSH Host 云端迁移实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 SSH Host 数据、凭据和终端设置从本地 SQLite/Stronghold 迁移到云端 PostgreSQL，通过 oRPC API 提供 CRUD 接口，web 端通过 better-auth 认证后访问。

**Architecture:** Server 端（`packages/db` + `packages/api`）新增 `ssh_host` 和 `terminal_settings` 表及对应 oRPC router，凭据使用 AES-256-GCM 服务端加密。Web 端移除本地 SQLite/Stronghold 依赖，改用 `@orpc/client` + TanStack Query 通过 HTTP 调用 server API。认证复用已有的 better-auth 体系。

**Tech Stack:** Drizzle ORM, oRPC, Zod, AES-256-GCM (Node.js crypto), better-auth, TanStack Query, TanStack Router

---

## Task 1: 添加 ENCRYPTION_KEY 环境变量

**Files:**
- Modify: `packages/env/src/server.ts`

**Step 1: 在 env schema 中添加 ENCRYPTION_KEY**

在 `packages/env/src/server.ts` 的 `server` 对象中新增：

```typescript
ENCRYPTION_KEY: z.string().length(64),
```

这是一个 64 字符的 hex 字符串（32 字节 AES-256 密钥）。

**Step 2: 在 .env 中添加 ENCRYPTION_KEY**

在 `apps/server/.env` 中添加（生成一个随机密钥）：

```
ENCRYPTION_KEY=<运行 node -e "console.log(require('crypto').randomBytes(32).toString('hex'))" 生成>
```

**Step 3: 验证**

运行 `bun run dev:server`，确认无环境变量校验错误。

**Step 4: Commit**

```bash
git add packages/env/src/server.ts
git commit -m "feat: add ENCRYPTION_KEY to env schema"
```

---

## Task 2: 创建加密工具模块

**Files:**
- Create: `packages/api/src/utils/crypto.ts`

**Step 1: 实现加密/解密函数**

```typescript
import { env } from "@Caterm/env/server";
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

const ALGORITHM = "aes-256-gcm";
const IV_LENGTH = 16;
const AUTH_TAG_LENGTH = 16;

function getKey(): Buffer {
  return Buffer.from(env.ENCRYPTION_KEY, "hex");
}

export function encrypt(plaintext: string): string {
  const iv = randomBytes(IV_LENGTH);
  const cipher = createCipheriv(ALGORITHM, getKey(), iv);
  const encrypted = Buffer.concat([
    cipher.update(plaintext, "utf8"),
    cipher.final(),
  ]);
  const authTag = cipher.getAuthTag();
  const combined = Buffer.concat([iv, authTag, encrypted]);
  return combined.toString("base64");
}

export function decrypt(encrypted: string): string {
  const combined = Buffer.from(encrypted, "base64");
  const iv = combined.subarray(0, IV_LENGTH);
  const authTag = combined.subarray(IV_LENGTH, IV_LENGTH + AUTH_TAG_LENGTH);
  const ciphertext = combined.subarray(IV_LENGTH + AUTH_TAG_LENGTH);
  const decipher = createDecipheriv(ALGORITHM, getKey(), iv);
  decipher.setAuthTag(authTag);
  return decipher.update(ciphertext) + decipher.final("utf8");
}
```

**Step 2: Commit**

```bash
git add packages/api/src/utils/crypto.ts
git commit -m "feat: add AES-256-GCM encryption utility"
```

---

## Task 3: 创建 ssh_host 数据库 Schema

**Files:**
- Create: `packages/db/src/schema/ssh-host.ts`
- Modify: `packages/db/src/schema/index.ts`

**Step 1: 创建 ssh_host Schema**

```typescript
import { index, integer, pgTable, text, timestamp } from "drizzle-orm/pg-core";
import { user } from "./auth";

export const sshHost = pgTable(
  "ssh_host",
  {
    id: text("id").primaryKey(),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    hostname: text("hostname").notNull(),
    port: integer("port").notNull().default(22),
    username: text("username").notNull(),
    authType: text("auth_type").notNull().default("password"),
    password: text("password"),
    privateKey: text("private_key"),
    keyPassphrase: text("key_passphrase"),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [index("ssh_host_userId_idx").on(table.userId)]
);
```

**Step 2: 导出 Schema**

在 `packages/db/src/schema/index.ts` 中添加：

```typescript
export * from "./ssh-host";
```

**Step 3: 生成并推送迁移**

```bash
bun run db:generate
bun run db:push
```

**Step 4: Commit**

```bash
git add packages/db/src/schema/ssh-host.ts packages/db/src/schema/index.ts
git commit -m "feat: add ssh_host table schema"
```

---

## Task 4: 创建 terminal_settings 数据库 Schema

**Files:**
- Create: `packages/db/src/schema/terminal-settings.ts`
- Modify: `packages/db/src/schema/index.ts`

**Step 1: 创建 terminal_settings Schema**

```typescript
import {
  boolean,
  integer,
  pgTable,
  serial,
  text,
  timestamp,
} from "drizzle-orm/pg-core";
import { user } from "./auth";

export const terminalSettings = pgTable("terminal_settings", {
  id: serial("id").primaryKey(),
  userId: text("user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" })
    .unique(),
  fontFamily: text("font_family").notNull().default("monospace"),
  fontSize: integer("font_size").notNull().default(14),
  cursorStyle: text("cursor_style").notNull().default("block"),
  cursorBlink: boolean("cursor_blink").notNull().default(true),
  scrollback: integer("scrollback").notNull().default(1000),
  theme: text("theme").notNull().default("dark"),
});
```

**Step 2: 导出 Schema**

在 `packages/db/src/schema/index.ts` 中添加：

```typescript
export * from "./terminal-settings";
```

**Step 3: 生成并推送迁移**

```bash
bun run db:generate
bun run db:push
```

**Step 4: Commit**

```bash
git add packages/db/src/schema/terminal-settings.ts packages/db/src/schema/index.ts
git commit -m "feat: add terminal_settings table schema"
```

---

## Task 5: 创建 sshHost oRPC Router

**Files:**
- Create: `packages/api/src/routers/ssh-host.ts`
- Modify: `packages/api/src/routers/index.ts`

**Step 1: 实现 sshHostRouter**

```typescript
import { db } from "@Caterm/db";
import { sshHost } from "@Caterm/db/schema/ssh-host";
import { and, eq } from "drizzle-orm";
import z from "zod";

import { protectedProcedure } from "../index";
import { decrypt, encrypt } from "../utils/crypto";

function encryptOptional(value: string | undefined): string | null {
  return value ? encrypt(value) : null;
}

function decryptOptional(value: string | null): string | undefined {
  return value ? decrypt(value) : undefined;
}

export const sshHostRouter = {
  list: protectedProcedure.handler(async ({ context }) => {
    const rows = await db
      .select({
        id: sshHost.id,
        name: sshHost.name,
        hostname: sshHost.hostname,
        port: sshHost.port,
        username: sshHost.username,
        authType: sshHost.authType,
        createdAt: sshHost.createdAt,
        updatedAt: sshHost.updatedAt,
      })
      .from(sshHost)
      .where(eq(sshHost.userId, context.session.user.id))
      .orderBy(sshHost.name);
    return rows;
  }),

  getById: protectedProcedure
    .input(z.object({ id: z.string() }))
    .handler(async ({ input, context }) => {
      const rows = await db
        .select()
        .from(sshHost)
        .where(
          and(
            eq(sshHost.id, input.id),
            eq(sshHost.userId, context.session.user.id)
          )
        );
      if (rows.length === 0) {
        throw new Error("Host not found");
      }
      const row = rows[0];
      return {
        ...row,
        password: decryptOptional(row.password),
        privateKey: decryptOptional(row.privateKey),
        keyPassphrase: decryptOptional(row.keyPassphrase),
      };
    }),

  create: protectedProcedure
    .input(
      z.object({
        name: z.string().min(1),
        hostname: z.string().min(1),
        port: z.number().int().min(1).max(65535).default(22),
        username: z.string().min(1),
        authType: z.enum(["password", "key"]).default("password"),
        password: z.string().optional(),
        privateKey: z.string().optional(),
        keyPassphrase: z.string().optional(),
      })
    )
    .handler(async ({ input, context }) => {
      const id = crypto.randomUUID();
      await db.insert(sshHost).values({
        id,
        userId: context.session.user.id,
        name: input.name,
        hostname: input.hostname,
        port: input.port,
        username: input.username,
        authType: input.authType,
        password: encryptOptional(input.password),
        privateKey: encryptOptional(input.privateKey),
        keyPassphrase: encryptOptional(input.keyPassphrase),
      });
      return { id };
    }),

  update: protectedProcedure
    .input(
      z.object({
        id: z.string(),
        name: z.string().min(1).optional(),
        hostname: z.string().min(1).optional(),
        port: z.number().int().min(1).max(65535).optional(),
        username: z.string().min(1).optional(),
        authType: z.enum(["password", "key"]).optional(),
        password: z.string().optional(),
        privateKey: z.string().optional(),
        keyPassphrase: z.string().optional(),
      })
    )
    .handler(async ({ input, context }) => {
      const { id, password, privateKey, keyPassphrase, ...rest } = input;
      const values: Record<string, unknown> = { ...rest };
      if (password !== undefined) {
        values.password = encryptOptional(password);
      }
      if (privateKey !== undefined) {
        values.privateKey = encryptOptional(privateKey);
      }
      if (keyPassphrase !== undefined) {
        values.keyPassphrase = encryptOptional(keyPassphrase);
      }
      await db
        .update(sshHost)
        .set(values)
        .where(
          and(eq(sshHost.id, id), eq(sshHost.userId, context.session.user.id))
        );
      return { id };
    }),

  delete: protectedProcedure
    .input(z.object({ id: z.string() }))
    .handler(async ({ input, context }) => {
      await db
        .delete(sshHost)
        .where(
          and(
            eq(sshHost.id, input.id),
            eq(sshHost.userId, context.session.user.id)
          )
        );
      return { success: true };
    }),
};
```

**Step 2: 注册到 appRouter**

在 `packages/api/src/routers/index.ts` 中导入并注册：

```typescript
import { sshHostRouter } from "./ssh-host";

export const appRouter = {
  // ... 现有 routes
  sshHost: sshHostRouter,
};
```

**Step 3: 验证编译**

```bash
bun run check-types
```

**Step 4: Commit**

```bash
git add packages/api/src/routers/ssh-host.ts packages/api/src/routers/index.ts
git commit -m "feat: add sshHost oRPC router with encrypted credential storage"
```

---

## Task 6: 创建 terminalSettings oRPC Router

**Files:**
- Create: `packages/api/src/routers/terminal-settings.ts`
- Modify: `packages/api/src/routers/index.ts`

**Step 1: 实现 terminalSettingsRouter**

```typescript
import { db } from "@Caterm/db";
import { terminalSettings } from "@Caterm/db/schema/terminal-settings";
import { eq } from "drizzle-orm";
import z from "zod";

import { protectedProcedure } from "../index";

const DEFAULT_SETTINGS = {
  fontFamily: "monospace",
  fontSize: 14,
  cursorStyle: "block" as const,
  cursorBlink: true,
  scrollback: 1000,
  theme: "dark",
};

export const terminalSettingsRouter = {
  get: protectedProcedure.handler(async ({ context }) => {
    const rows = await db
      .select()
      .from(terminalSettings)
      .where(eq(terminalSettings.userId, context.session.user.id));
    if (rows.length === 0) {
      return DEFAULT_SETTINGS;
    }
    const { id, userId, ...settings } = rows[0];
    return settings;
  }),

  upsert: protectedProcedure
    .input(
      z.object({
        fontFamily: z.string().optional(),
        fontSize: z.number().int().min(8).max(72).optional(),
        cursorStyle: z.enum(["block", "underline", "bar"]).optional(),
        cursorBlink: z.boolean().optional(),
        scrollback: z.number().int().min(100).max(100000).optional(),
        theme: z.string().optional(),
      })
    )
    .handler(async ({ input, context }) => {
      const userId = context.session.user.id;
      const existing = await db
        .select({ id: terminalSettings.id })
        .from(terminalSettings)
        .where(eq(terminalSettings.userId, userId));

      if (existing.length > 0) {
        await db
          .update(terminalSettings)
          .set(input)
          .where(eq(terminalSettings.userId, userId));
      } else {
        await db.insert(terminalSettings).values({
          userId,
          ...DEFAULT_SETTINGS,
          ...input,
        });
      }
      return { success: true };
    }),
};
```

**Step 2: 注册到 appRouter**

在 `packages/api/src/routers/index.ts` 中添加：

```typescript
import { terminalSettingsRouter } from "./terminal-settings";

export const appRouter = {
  // ... 现有 routes
  terminalSettings: terminalSettingsRouter,
};
```

**Step 3: 验证编译**

```bash
bun run check-types
```

**Step 4: Commit**

```bash
git add packages/api/src/routers/terminal-settings.ts packages/api/src/routers/index.ts
git commit -m "feat: add terminalSettings oRPC router"
```

---

## Task 7: Web 端 — 添加 oRPC 客户端和认证

**Files:**
- Create: `apps/web/src/lib/orpc.ts`
- Create: `apps/web/src/lib/auth-client.ts`
- Modify: `apps/web/package.json` — 添加依赖

**Step 1: 安装依赖**

```bash
cd apps/web && bun add @orpc/client @orpc/tanstack-query @tanstack/react-query @Caterm/api better-auth
```

**Step 2: 创建 auth 客户端**

`apps/web/src/lib/auth-client.ts`:

```typescript
import { createAuthClient } from "better-auth/react";

const serverUrl = import.meta.env.VITE_SERVER_URL || "http://localhost:3001";

export const authClient = createAuthClient({
  baseURL: serverUrl,
});
```

**Step 3: 创建 oRPC 客户端**

`apps/web/src/lib/orpc.ts`:

```typescript
import type { AppRouter } from "@Caterm/api/routers/index";
import { createORPCClient } from "@orpc/client";
import { RPCLink } from "@orpc/client/fetch";
import type { RouterClient } from "@orpc/server";
import { createTanstackQueryUtils } from "@orpc/tanstack-query";
import { QueryCache, QueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

const serverUrl = import.meta.env.VITE_SERVER_URL || "http://localhost:3001";

export const queryClient = new QueryClient({
  queryCache: new QueryCache({
    onError: (error, query) => {
      toast.error(`Error: ${error.message}`, {
        action: {
          label: "retry",
          onClick: query.invalidate,
        },
      });
    },
  }),
});

const link = new RPCLink({
  url: `${serverUrl}/api/rpc`,
  fetch(url, options) {
    return fetch(url, {
      ...options,
      credentials: "include",
    });
  },
});

export const client: RouterClient<AppRouter> = createORPCClient(link);

export const orpc = createTanstackQueryUtils(client);
```

**Step 4: 添加 VITE_SERVER_URL 到 .env**

创建 `apps/web/.env`（如果不存在）：

```
VITE_SERVER_URL=http://localhost:3001
```

**Step 5: Commit**

```bash
git add apps/web/src/lib/orpc.ts apps/web/src/lib/auth-client.ts apps/web/package.json
git commit -m "feat(web): add oRPC client and better-auth client"
```

---

## Task 8: Web 端 — 添加 QueryClientProvider 和登录路由

**Files:**
- Modify: `apps/web/src/routes/__root.tsx` — 包裹 QueryClientProvider
- Create: `apps/web/src/routes/login.tsx` — 登录页

**Step 1: 修改 __root.tsx**

在 `__root.tsx` 中导入 `QueryClientProvider` 和 `queryClient`，包裹在 `<Outlet />` 外层：

```typescript
import { QueryClientProvider } from "@tanstack/react-query";
import { queryClient } from "@/lib/orpc";
```

在 JSX 中用 `<QueryClientProvider client={queryClient}>` 包裹内容。

**Step 2: 创建登录路由**

`apps/web/src/routes/login.tsx`:

简单的登录/注册表单，使用 `authClient.signIn.email()` 和 `authClient.signUp.email()`。登录成功后 `navigate({ to: "/ssh" })`。

参考 `apps/server/src/components/sign-in-form.tsx` 和 `sign-up-form.tsx` 的模式。

**Step 3: 在 SSH 路由添加 auth guard**

修改 `apps/web/src/routes/ssh/route.tsx` 的 `Route` 定义，添加 `beforeLoad` 检查 session：

```typescript
export const Route = createFileRoute("/ssh")({
  beforeLoad: async () => {
    const session = await authClient.getSession();
    if (!session.data) {
      throw redirect({ to: "/login" });
    }
  },
  component: SshRouteWrapper,
});
```

**Step 4: Commit**

```bash
git add apps/web/src/routes/__root.tsx apps/web/src/routes/login.tsx apps/web/src/routes/ssh/route.tsx
git commit -m "feat(web): add QueryClientProvider, login route, and auth guard"
```

---

## Task 9: Web 端 — 改造 HostList 使用 oRPC

**Files:**
- Modify: `apps/web/src/components/hosts/host-list.tsx`

**Step 1: 替换 SQLite 查询为 oRPC**

移除 `Database` import 和 SQLite 调用。改用 TanStack Query：

```typescript
import { useQuery } from "@tanstack/react-query";
import { orpc } from "@/lib/orpc";

// 在组件内：
const { data: hosts = [], refetch } = useQuery(orpc.sshHost.list.queryOptions());
```

移除 `loadHosts` callback、`useState` for hosts、`useEffect` 加载逻辑。

删除中的 `handleDelete` 也改用 oRPC：

```typescript
import { useMutation } from "@tanstack/react-query";

const deleteMutation = useMutation({
  ...orpc.sshHost.delete.mutationOptions(),
  onSuccess: () => refetch(),
});

// handleDelete 中：
await deleteMutation.mutateAsync({ id: host.id });
```

移除 `deleteCredential` import（不再需要本地凭据删除）。

**Step 2: Commit**

```bash
git add apps/web/src/components/hosts/host-list.tsx
git commit -m "feat(web): migrate HostList from SQLite to oRPC"
```

---

## Task 10: Web 端 — 改造 SSH Route 使用 oRPC

**Files:**
- Modify: `apps/web/src/routes/ssh/route.tsx`

**Step 1: 移除 SQLite 和 Stronghold 引用**

移除以下 import：
- `Database from "@tauri-apps/plugin-sql"`
- `loadCredential, saveCredential from "@/lib/stronghold"`

**Step 2: 改造 handleFormSubmit**

使用 oRPC mutation 替代 SQLite 操作：

```typescript
import { useMutation } from "@tanstack/react-query";
import { orpc, queryClient } from "@/lib/orpc";

// 在 SshLayout 内：
const createMutation = useMutation(orpc.sshHost.create.mutationOptions());
const updateMutation = useMutation(orpc.sshHost.update.mutationOptions());

const handleFormSubmit = useCallback(async (values) => {
  try {
    if (editingHost) {
      await updateMutation.mutateAsync({
        id: editingHost.id,
        name: values.name,
        hostname: values.hostname,
        port: values.port,
        username: values.username,
        authType: values.authType,
        password: values.password || undefined,
        privateKey: values.privateKey || undefined,
        keyPassphrase: values.keyPassphrase || undefined,
      });
    } else {
      await createMutation.mutateAsync({
        name: values.name,
        hostname: values.hostname,
        port: values.port,
        username: values.username,
        authType: values.authType,
        password: values.password || undefined,
        privateKey: values.privateKey || undefined,
        keyPassphrase: values.keyPassphrase || undefined,
      });
    }
    setFormOpen(false);
    setEditingHost(undefined);
    queryClient.invalidateQueries({ queryKey: orpc.sshHost.list.queryOptions().queryKey });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    toast.error("Failed to save host", { description: message });
  }
}, [editingHost, createMutation, updateMutation]);
```

**Step 3: 改造 handleConnectRequest**

凭据从 API 获取而非 Stronghold：

```typescript
const handleConnectRequest = useCallback(async (host: SshHost) => {
  try {
    const fullHost = await client.sshHost.getById({ id: host.id });
    await connect({
      hostId: fullHost.id,
      hostName: fullHost.name,
      hostname: fullHost.hostname,
      port: fullHost.port,
      username: fullHost.username,
      authType: fullHost.authType as "password" | "key",
      password: fullHost.password,
      privateKey: fullHost.privateKey,
      keyPassphrase: fullHost.keyPassphrase,
    });
  } catch {
    // 如果凭据不存在，显示连接对话框
    setConnectTarget(host);
  }
}, [connect]);
```

**Step 4: 改造 terminal settings 加载**

```typescript
import { useQuery } from "@tanstack/react-query";

const { data: terminalSettings } = useQuery({
  ...orpc.terminalSettings.get.queryOptions(),
  initialData: DEFAULT_TERMINAL_SETTINGS,
});
```

移除 `useState` 和 `useEffect` 加载 SQLite 设置的代码。移除 `refreshKey` state（TanStack Query 自动处理缓存失效）。

**Step 5: Commit**

```bash
git add apps/web/src/routes/ssh/route.tsx
git commit -m "feat(web): migrate SSH route from SQLite/Stronghold to oRPC"
```

---

## Task 11: Web 端 — 改造 Terminal Settings 页面

**Files:**
- Modify: `apps/web/src/components/settings/terminal-settings-form.tsx`
- Modify: `apps/web/src/routes/ssh/settings.tsx`

**Step 1: 改造 terminal-settings-form.tsx**

移除 SQLite 调用，使用 oRPC query/mutation：

```typescript
import { useMutation, useQuery } from "@tanstack/react-query";
import { orpc, queryClient } from "@/lib/orpc";

const { data: settings } = useQuery(orpc.terminalSettings.get.queryOptions());

const upsertMutation = useMutation({
  ...orpc.terminalSettings.upsert.mutationOptions(),
  onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: orpc.terminalSettings.get.queryOptions().queryKey });
    toast.success("Settings saved");
  },
});
```

**Step 2: Commit**

```bash
git add apps/web/src/components/settings/terminal-settings-form.tsx apps/web/src/routes/ssh/settings.tsx
git commit -m "feat(web): migrate terminal settings form to oRPC"
```

---

## Task 12: Web 端 — 清理移除的文件和依赖

**Files:**
- Delete: `apps/web/src/lib/stronghold.ts`
- Delete: `apps/web/src/lib/config-sync.ts`
- Modify: `apps/web/package.json` — 移除 `@tauri-apps/plugin-sql`、`@tauri-apps/plugin-stronghold`

**Step 1: 删除不再需要的文件**

```bash
rm apps/web/src/lib/stronghold.ts apps/web/src/lib/config-sync.ts
```

**Step 2: 移除 Tauri 插件依赖**

```bash
cd apps/web && bun remove @tauri-apps/plugin-sql @tauri-apps/plugin-stronghold
```

**Step 3: 搜索并清理残留引用**

```bash
grep -r "plugin-sql\|plugin-stronghold\|stronghold\|config-sync" apps/web/src/
```

确保无残留 import。如果有，修复它们。

**Step 4: 验证编译**

```bash
bun run check-types
```

**Step 5: Commit**

```bash
git add -A
git commit -m "chore(web): remove SQLite and Stronghold dependencies"
```

---

## Task 13: Server 端 — 添加 CORS 配置（如需要）

**Files:**
- 可能需要修改 `apps/server/` 的 Vite/TanStack Start 配置

**Step 1: 确认跨域需求**

web 端（Tauri，origin 为 `tauri://localhost` 或 `https://tauri.localhost`）调用 server 端 API 需要 CORS。

检查 `apps/server/` 现有的 CORS 配置。better-auth 已经有 `trustedOrigins: [env.CORS_ORIGIN]`。

确保 oRPC 的 RPC handler 也正确处理 CORS headers。可能需要在 `apps/server/src/routes/api/rpc/$.ts` 的 `handle` 函数中添加 CORS headers，或在 Vite dev server 中配置 proxy。

**Step 2: 在 .env 中更新 CORS_ORIGIN**

```
CORS_ORIGIN=https://tauri.localhost
```

**Step 3: Commit**

```bash
git add -A
git commit -m "feat(server): configure CORS for Tauri desktop client"
```

---

## Task 14: 端到端验证

**Step 1: 启动 server**

```bash
bun run dev:server
```

**Step 2: 启动 web（Tauri dev）**

```bash
bun run tauri:dev
```

**Step 3: 验证流程**

1. 打开应用 → 应重定向到登录页
2. 注册新用户 → 注册成功后跳转到 /ssh
3. 添加新 Host → 应通过 API 创建
4. 编辑 Host → 应通过 API 更新
5. 删除 Host → 应通过 API 删除
6. 连接 Host → 应从 API 获取凭据后连接
7. 修改终端设置 → 应通过 API 保存
8. 退出登录 → 应回到登录页

**Step 4: Final Commit**

```bash
git add -A
git commit -m "feat: complete SSH host cloud migration"
```
