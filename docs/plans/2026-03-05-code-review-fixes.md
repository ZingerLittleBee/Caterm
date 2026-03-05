# Code Review Fixes Plan

## Overview
Fix issues identified in the lima branch code review. 11 items, prioritized by severity.

## Tasks

### Group A: API 安全与正确性 (packages/api)

#### A1. ssh-host `getById` 排除 `userId` 字段
- File: `packages/api/src/routers/ssh-host.ts`
- 解构排除 `userId`，只返回客户端需要的字段

#### A2. ssh-host `update`/`delete` 验证行存在
- File: `packages/api/src/routers/ssh-host.ts`
- 使用 `.returning()` 检查影响行数，不存在时抛 NOT_FOUND

#### A3. ssh-host `update` 恢复类型安全
- File: `packages/api/src/routers/ssh-host.ts`
- 将 `Record<string, unknown>` 改为 `Partial<typeof sshHost.$inferInsert>`

#### A4. terminal-settings JSONB 数据加运行时验证
- File: `packages/api/src/routers/terminal-settings.ts`
- 对 `settingsJson` 和 `hostOverridesJson` 的 `as` 强转添加类型检查

#### A5. terminal-settings `hostOverrides` 深合并
- File: `packages/api/src/routers/terminal-settings.ts`
- 对每个 host key 做一层深合并，而非顶层浅合并

#### A6. crypto.ts 缓存 key + decrypt 错误处理
- File: `packages/api/src/utils/crypto.ts`
- 模块级缓存 KEY buffer；decrypt 添加长度校验

### Group B: 前端状态管理 (apps/web)

#### B1. TerminalSettingsProvider 乐观更新加 rollback
- File: `apps/web/src/components/terminal/terminal-settings-provider.tsx`
- 使用 onMutate/onError/onSettled 标准模式
- 添加 staleTime 减少不必要的 refetch

#### B2. TerminalSettingsForm toast 时机修正
- File: `apps/web/src/components/settings/terminal-settings-form.tsx`
- 移除提前触发的 toast，改为在 mutation 回调中通知

#### B3. host-list.tsx handleDelete useCallback 修正
- File: `apps/web/src/components/hosts/host-list.tsx`
- 依赖改为 `deleteMutation.mutateAsync`（稳定引用）

### Group C: 路由认证 (apps/web/routes)

#### C1. `/ssh` layout route 添加 auth guard
- File: `apps/web/src/routes/ssh/route.tsx`
- 添加 beforeLoad 认证检查
- 移除 `settings.tsx` 中的重复检查

#### C2. TerminalSettingsProvider 移出 root layout
- File: `apps/web/src/routes/__root.tsx` + `apps/web/src/routes/ssh/route.tsx`
- 将 provider 从 __root.tsx 移到 ssh/route.tsx，避免未登录时发 401 请求

## Execution Order
1. Group A (A1→A6) — API 层修复，互相独立
2. Group C (C1→C2) — 路由认证，C2 依赖 C1 的 route.tsx 修改
3. Group B (B1→B3) — 前端状态，B2 可能依赖 B1 的 mutation 回调变更
