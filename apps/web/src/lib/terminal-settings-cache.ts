import { DEFAULT_TERMINAL_SETTINGS } from "@/lib/terminal-themes";
import type { TerminalSettings } from "@/types/ssh";

const CACHE_KEY = "caterm-terminal-settings";

interface CachedData {
	global: TerminalSettings;
	hostOverrides: Record<string, Partial<TerminalSettings>>;
}

export function readSettingsCache(): CachedData | undefined {
	try {
		const raw = localStorage.getItem(CACHE_KEY);
		if (!raw) {
			return undefined;
		}
		const parsed = JSON.parse(raw) as CachedData;
		return {
			global: { ...DEFAULT_TERMINAL_SETTINGS, ...parsed.global },
			hostOverrides: parsed.hostOverrides ?? {},
		};
	} catch {
		return undefined;
	}
}

export function writeSettingsCache(data: CachedData): void {
	try {
		localStorage.setItem(CACHE_KEY, JSON.stringify(data));
	} catch {
		// localStorage full or unavailable — silently ignore
	}
}
