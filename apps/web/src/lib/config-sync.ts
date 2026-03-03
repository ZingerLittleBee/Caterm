import Database from "@tauri-apps/plugin-sql";
import { deleteCredential, loadCredential, saveCredential } from "./stronghold";

interface ExportHost {
	authType: string;
	hostname: string;
	id: string;
	name: string;
	port: number;
	username: string;
}

interface ExportCredential {
	authType: string;
	hostId: string;
	keyPassphrase?: string;
	password?: string;
	privateKey?: string;
}

interface ExportSettings {
	cursorBlink: boolean;
	cursorStyle: string;
	fontFamily: string;
	fontSize: number;
	scrollback: number;
	theme: string;
}

interface ExportData {
	credentials: ExportCredential[];
	hosts: ExportHost[];
	settings: ExportSettings | null;
	version: number;
}

export async function exportConfig(): Promise<string> {
	const db = await Database.load("sqlite:caterm.db");

	const hosts = await db.select<ExportHost[]>(
		"SELECT id, name, hostname, port, username, auth_type as authType FROM ssh_hosts ORDER BY name"
	);

	const credentials: ExportCredential[] = [];
	for (const host of hosts) {
		const cred = await loadCredential(host.id, host.authType);
		if (cred.password ?? cred.privateKey) {
			credentials.push({
				hostId: host.id,
				authType: host.authType,
				...cred,
			});
		}
	}

	const settingsRows = await db.select<ExportSettings[]>(
		"SELECT font_family as fontFamily, font_size as fontSize, cursor_style as cursorStyle, cursor_blink as cursorBlink, scrollback, theme FROM terminal_settings WHERE id = 'default'"
	);

	const data: ExportData = {
		version: 1,
		hosts,
		credentials,
		settings: settingsRows.length > 0 ? settingsRows[0] : null,
	};

	return JSON.stringify(data, null, 2);
}

export async function importConfig(jsonString: string): Promise<{
	hostsImported: number;
	credentialsImported: number;
}> {
	const data: ExportData = JSON.parse(jsonString);

	if (data.version !== 1) {
		throw new Error(`Unsupported config version: ${data.version}`);
	}

	const db = await Database.load("sqlite:caterm.db");

	let hostsImported = 0;
	for (const host of data.hosts) {
		const existing = await db.select<{ id: string }[]>(
			"SELECT id FROM ssh_hosts WHERE id = ?",
			[host.id]
		);

		if (existing.length > 0) {
			await db.execute(
				"UPDATE ssh_hosts SET name = ?, hostname = ?, port = ?, username = ?, auth_type = ?, updated_at = datetime('now') WHERE id = ?",
				[
					host.name,
					host.hostname,
					host.port,
					host.username,
					host.authType,
					host.id,
				]
			);
		} else {
			await db.execute(
				"INSERT INTO ssh_hosts (id, name, hostname, port, username, auth_type, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))",
				[
					host.id,
					host.name,
					host.hostname,
					host.port,
					host.username,
					host.authType,
				]
			);
		}
		hostsImported++;
	}

	let credentialsImported = 0;
	for (const cred of data.credentials) {
		await deleteCredential(cred.hostId);
		await saveCredential(
			cred.hostId,
			cred.authType as "password" | "key",
			cred.password,
			cred.privateKey,
			cred.keyPassphrase
		);
		credentialsImported++;
	}

	if (data.settings) {
		const s = data.settings;
		await db.execute(
			"UPDATE terminal_settings SET font_family = ?, font_size = ?, cursor_style = ?, cursor_blink = ?, scrollback = ?, theme = ? WHERE id = 'default'",
			[
				s.fontFamily,
				s.fontSize,
				s.cursorStyle,
				s.cursorBlink ? 1 : 0,
				s.scrollback,
				s.theme,
			]
		);
	}

	return { hostsImported, credentialsImported };
}

export function downloadJson(content: string, filename: string): void {
	const blob = new Blob([content], { type: "application/json" });
	const url = URL.createObjectURL(blob);
	const a = document.createElement("a");
	a.href = url;
	a.download = filename;
	a.click();
	URL.revokeObjectURL(url);
}
