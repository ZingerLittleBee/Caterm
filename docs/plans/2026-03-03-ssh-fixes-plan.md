# SSH Feature Fixes & Completion Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all bugs, remove placeholders, and complete unimplemented features in the SSH module — including terminal_settings ID mismatch, Stronghold credential persistence from JS, config export/import, silent error handling, and Rust-side stub cleanup.

**Architecture:** Credential storage uses the Stronghold JS API (`@tauri-apps/plugin-stronghold`) since the Rust-side API is poorly documented. Host CRUD and settings use `@tauri-apps/plugin-sql` JS API. Unused Rust-side stubs for host/settings/stronghold are removed. Config export/import is deferred (stubs kept with clear "V1.1" marking).

**Tech Stack:** TypeScript (React 19, @tauri-apps/plugin-stronghold, @tauri-apps/plugin-sql), Rust (russh, tauri)

---

## Task 1: Fix terminal_settings ID mismatch

The migration inserts `id = 'default'` (text) but all frontend SQL queries use `WHERE id = 1` (integer). This means settings are never loaded or saved.

**Files:**
- Modify: `apps/web/src/routes/ssh/route.tsx`
- Modify: `apps/web/src/components/settings/terminal-settings-form.tsx`

**Step 1: Fix route.tsx settings query**

In `apps/web/src/routes/ssh/route.tsx`, change the SQL query from:
```
WHERE id = 1
```
to:
```
WHERE id = 'default'
```

**Step 2: Fix terminal-settings-form.tsx load query**

In `apps/web/src/components/settings/terminal-settings-form.tsx`, change the SELECT query from:
```
WHERE id = 1
```
to:
```
WHERE id = 'default'
```

**Step 3: Fix terminal-settings-form.tsx save query**

In the same file, change the UPDATE query from:
```
WHERE id = 1
```
to:
```
WHERE id = 'default'
```

**Step 4: Add toast feedback for save success/failure**

In `terminal-settings-form.tsx`:
- Import `toast` from `sonner`
- Add `toast.success('Settings saved')` after successful save
- Add `toast.error('Failed to save settings', { description: message })` in the catch block

**Step 5: Verify**

Run: `cd apps/web && bun run build`
Expected: Builds successfully

---

## Task 2: Implement Stronghold credential storage from frontend

Credentials (password, private key, passphrase) should be persisted in Stronghold when saving a host, and auto-loaded when connecting.

**Files:**
- Create: `apps/web/src/lib/stronghold.ts`
- Modify: `apps/web/src/routes/ssh/route.tsx`
- Modify: `apps/web/src/components/ssh/connect-dialog.tsx`

**Step 1: Create stronghold helper module**

File: `apps/web/src/lib/stronghold.ts`

```typescript
import { appDataDir } from "@tauri-apps/api/path";
import { Stronghold } from "@tauri-apps/plugin-stronghold";

const VAULT_PASSWORD = "caterm-stronghold-default";
const CLIENT_NAME = "caterm";

let cachedStronghold: Stronghold | null = null;

async function getStronghold(): Promise<Stronghold> {
	if (cachedStronghold) {
		return cachedStronghold;
	}
	const dir = await appDataDir();
	const vaultPath = `${dir}/vault.hold`;
	cachedStronghold = await Stronghold.load(vaultPath, VAULT_PASSWORD);
	return cachedStronghold;
}

async function getStore() {
	const stronghold = await getStronghold();
	let client;
	try {
		client = await stronghold.loadClient(CLIENT_NAME);
	} catch {
		client = await stronghold.createClient(CLIENT_NAME);
	}
	return { store: client.getStore(), stronghold };
}

function encode(value: string): number[] {
	return Array.from(new TextEncoder().encode(value));
}

function decode(data: Uint8Array | null): string | null {
	if (!data) {
		return null;
	}
	return new TextDecoder().decode(data);
}

export async function saveCredential(
	hostId: string,
	authType: "password" | "key",
	password?: string,
	privateKey?: string,
	keyPassphrase?: string,
): Promise<void> {
	const { store, stronghold } = await getStore();

	if (authType === "password" && password) {
		await store.insert(`ssh-password-${hostId}`, encode(password));
	} else if (authType === "key") {
		if (privateKey) {
			await store.insert(`ssh-private-key-${hostId}`, encode(privateKey));
		}
		if (keyPassphrase) {
			await store.insert(
				`ssh-key-passphrase-${hostId}`,
				encode(keyPassphrase),
			);
		}
	}

	await stronghold.save();
}

export async function loadCredential(
	hostId: string,
	authType: string,
): Promise<{
	password?: string;
	privateKey?: string;
	keyPassphrase?: string;
}> {
	const { store } = await getStore();

	if (authType === "password") {
		const data = await store.get(`ssh-password-${hostId}`);
		return { password: decode(data) ?? undefined };
	}

	const keyData = await store.get(`ssh-private-key-${hostId}`);
	const passphraseData = await store.get(`ssh-key-passphrase-${hostId}`);
	return {
		privateKey: decode(keyData) ?? undefined,
		keyPassphrase: decode(passphraseData) ?? undefined,
	};
}

export async function deleteCredential(hostId: string): Promise<void> {
	const { store, stronghold } = await getStore();

	for (const suffix of ["password", "private-key", "key-passphrase"]) {
		try {
			await store.remove(`ssh-${suffix}-${hostId}`);
		} catch {
			// Key may not exist
		}
	}

	await stronghold.save();
}
```

**Step 2: Wire credential saving into host form submission in route.tsx**

In `apps/web/src/routes/ssh/route.tsx`, import `saveCredential` from `@/lib/stronghold` and call it inside `handleFormSubmit` after the DB insert/update succeeds, passing the credential fields.

**Step 3: Wire credential loading into connect dialog**

In `apps/web/src/routes/ssh/route.tsx`, when `handleConnectRequest` is called:
1. Import `loadCredential` from `@/lib/stronghold`
2. Try to load stored credentials for the host
3. If credentials exist, auto-fill them in the ConnectDialog (or skip the dialog and connect directly for password auth)

**Step 4: Wire credential deletion into host delete**

In `apps/web/src/components/hosts/host-list.tsx`, import `deleteCredential` from `@/lib/stronghold` and call it inside `handleDelete` before or after the DB delete.

**Step 5: Add `@tauri-apps/api` dependency check**

Run: `cd apps/web && grep '@tauri-apps/api' package.json`
If not present: `bun add @tauri-apps/api`

**Step 6: Verify**

Run: `cd apps/web && bun run build`
Expected: Builds successfully

---

## Task 3: Remove Rust-side placeholder stubs

The Rust-side host CRUD, settings, and stronghold commands are placeholders since all operations are done from JS. Remove unused stubs and simplify.

**Files:**
- Modify: `apps/web/src-tauri/src/commands/host_commands.rs`
- Modify: `apps/web/src-tauri/src/commands/settings_commands.rs`
- Modify: `apps/web/src-tauri/src/commands/mod.rs`
- Modify: `apps/web/src-tauri/src/crypto/stronghold.rs`
- Modify: `apps/web/src-tauri/src/lib.rs`

**Step 1: Remove host_commands.rs**

Delete the file `apps/web/src-tauri/src/commands/host_commands.rs`. All host CRUD is done from frontend JS via `@tauri-apps/plugin-sql`.

**Step 2: Remove settings_commands.rs**

Delete the file `apps/web/src-tauri/src/commands/settings_commands.rs`. Settings are read/written from frontend JS.

**Step 3: Simplify crypto/stronghold.rs**

Remove the placeholder functions (`save_credential`, `get_credential`, `delete_credential`). Keep only the key-building utility functions in case they're needed later, or remove the entire module if unused.

**Step 4: Update commands/mod.rs**

Remove `pub mod host_commands;` and `pub mod settings_commands;` lines.

**Step 5: Update lib.rs invoke_handler**

Remove all references to `host_commands::*` and `settings_commands::*` from the `generate_handler!` macro. Keep only:
- `ssh_commands::ssh_connect`
- `ssh_commands::ssh_write`
- `ssh_commands::ssh_resize`
- `ssh_commands::ssh_disconnect`
- `config_commands::export_config`
- `config_commands::import_config`

Also remove the unused `use` imports.

**Step 6: Remove unused db/models.rs types**

Remove `CreateHostInput` and `UpdateHostInput` from `apps/web/src-tauri/src/db/models.rs` since they are not used by any Rust code anymore. Keep `SshHost` and `TerminalSettings` only if still referenced; otherwise remove them too.

**Step 7: Verify**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles successfully (warnings about unused models OK if you kept them)

---

## Task 4: Add error feedback to silent catch blocks

Several components silently swallow errors. Add user-facing toast notifications.

**Files:**
- Modify: `apps/web/src/components/hosts/host-list.tsx`

**Step 1: Add toast feedback to host delete failure**

In `host-list.tsx`, import `toast` from `sonner` and replace the empty `catch {}` block in `handleDelete` with:
```typescript
catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  toast.error("Failed to delete host", { description: message });
}
```

**Step 2: Add toast feedback to host load failure**

In the same file, replace the empty `catch {}` block in `loadHosts` with:
```typescript
catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  toast.error("Failed to load hosts", { description: message });
  setHosts([]);
}
```

**Step 3: Verify**

Run: `cd apps/web && bun run build`
Expected: Builds successfully

---

## Task 5: Lint and format

**Step 1: Run ultracite fix**

Run: `bun x ultracite fix`

**Step 2: Run ultracite check**

Run: `bun x ultracite check`
Expected: No errors

**Step 3: Run cargo check**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Clean compilation

---

## Summary

| # | Task | What it fixes |
|---|------|---------------|
| 1 | Fix terminal_settings ID | Settings never load/save due to `id = 1` vs `id = 'default'` |
| 2 | Stronghold credential storage | Credentials not persisted; user must re-enter every time |
| 3 | Remove Rust stubs | Dead placeholder code that returns empty/error |
| 4 | Error feedback | Silent `catch {}` blocks hide failures from user |
| 5 | Lint and format | Ensure code passes ultracite checks |
