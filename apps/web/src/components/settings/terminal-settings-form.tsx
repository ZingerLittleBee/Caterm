import Database from "@tauri-apps/plugin-sql";
import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
	Select,
	SelectContent,
	SelectItem,
	SelectTrigger,
	SelectValue,
} from "@/components/ui/select";

interface TerminalSettings {
	cursorBlink: boolean;
	cursorStyle: "block" | "underline" | "bar";
	fontFamily: string;
	fontSize: number;
	scrollback: number;
	theme: string;
}

const DEFAULT_SETTINGS: TerminalSettings = {
	fontFamily: "monospace",
	fontSize: 14,
	cursorStyle: "block",
	cursorBlink: true,
	scrollback: 1000,
	theme: "default",
};

const CURSOR_STYLE_ITEMS = {
	block: "Block",
	underline: "Underline",
	bar: "Bar",
} as const;

const THEME_ITEMS = {
	default: "Default",
	dark: "Dark",
	light: "Light",
} as const;

export function TerminalSettingsForm() {
	const [settings, setSettings] = useState<TerminalSettings>(DEFAULT_SETTINGS);
	const [saving, setSaving] = useState(false);

	const loadSettings = useCallback(async () => {
		try {
			const db = await Database.load("sqlite:caterm.db");
			const rows = await db.select<TerminalSettings[]>(
				"SELECT font_family as fontFamily, font_size as fontSize, cursor_style as cursorStyle, cursor_blink as cursorBlink, scrollback, theme FROM terminal_settings WHERE id = 'default'"
			);
			if (rows.length > 0) {
				const row = rows[0];
				setSettings({
					fontFamily: row.fontFamily,
					fontSize: row.fontSize,
					cursorStyle: row.cursorStyle,
					cursorBlink: Boolean(row.cursorBlink),
					scrollback: row.scrollback,
					theme: row.theme,
				});
			}
		} catch {
			// Table may not exist yet, use defaults
		}
	}, []);

	useEffect(() => {
		loadSettings();
	}, [loadSettings]);

	const handleSave = useCallback(async () => {
		setSaving(true);
		try {
			const db = await Database.load("sqlite:caterm.db");
			await db.execute(
				"UPDATE terminal_settings SET font_family = ?, font_size = ?, cursor_style = ?, cursor_blink = ?, scrollback = ?, theme = ? WHERE id = 'default'",
				[
					settings.fontFamily,
					settings.fontSize,
					settings.cursorStyle,
					settings.cursorBlink ? 1 : 0,
					settings.scrollback,
					settings.theme,
				]
			);
			toast.success("Settings saved");
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			toast.error("Failed to save settings", { description: message });
		} finally {
			setSaving(false);
		}
	}, [settings]);

	return (
		<div className="flex max-w-lg flex-col gap-6">
			<div className="flex flex-col gap-2">
				<Label htmlFor="settings-font-family">Font Family</Label>
				<Input
					id="settings-font-family"
					onChange={(e) =>
						setSettings((prev) => ({ ...prev, fontFamily: e.target.value }))
					}
					placeholder="monospace"
					value={settings.fontFamily}
				/>
			</div>

			<div className="flex flex-col gap-2">
				<Label htmlFor="settings-font-size">Font Size</Label>
				<Input
					id="settings-font-size"
					max={32}
					min={8}
					onChange={(e) =>
						setSettings((prev) => ({
							...prev,
							fontSize: Number.parseInt(e.target.value, 10) || 14,
						}))
					}
					type="number"
					value={String(settings.fontSize)}
				/>
			</div>

			<div className="flex flex-col gap-2">
				<Label>Cursor Style</Label>
				<Select
					items={CURSOR_STYLE_ITEMS}
					onValueChange={(value) =>
						setSettings((prev) => ({
							...prev,
							cursorStyle: value as TerminalSettings["cursorStyle"],
						}))
					}
					value={settings.cursorStyle}
				>
					<SelectTrigger className="w-full">
						<SelectValue placeholder="Select cursor style" />
					</SelectTrigger>
					<SelectContent>
						<SelectItem value="block">Block</SelectItem>
						<SelectItem value="underline">Underline</SelectItem>
						<SelectItem value="bar">Bar</SelectItem>
					</SelectContent>
				</Select>
			</div>

			<div className="flex items-center gap-2">
				<Checkbox
					checked={settings.cursorBlink}
					id="settings-cursor-blink"
					onCheckedChange={(checked) =>
						setSettings((prev) => ({
							...prev,
							cursorBlink: Boolean(checked),
						}))
					}
				/>
				<Label htmlFor="settings-cursor-blink">Cursor Blink</Label>
			</div>

			<div className="flex flex-col gap-2">
				<Label htmlFor="settings-scrollback">Scrollback Lines</Label>
				<Input
					id="settings-scrollback"
					max={100_000}
					min={100}
					onChange={(e) =>
						setSettings((prev) => ({
							...prev,
							scrollback: Number.parseInt(e.target.value, 10) || 1000,
						}))
					}
					type="number"
					value={String(settings.scrollback)}
				/>
			</div>

			<div className="flex flex-col gap-2">
				<Label>Theme</Label>
				<Select
					items={THEME_ITEMS}
					onValueChange={(value) =>
						setSettings((prev) => ({
							...prev,
							theme: value as string,
						}))
					}
					value={settings.theme}
				>
					<SelectTrigger className="w-full">
						<SelectValue placeholder="Select theme" />
					</SelectTrigger>
					<SelectContent>
						<SelectItem value="default">Default</SelectItem>
						<SelectItem value="dark">Dark</SelectItem>
						<SelectItem value="light">Light</SelectItem>
					</SelectContent>
				</Select>
			</div>

			<div className="pt-2">
				<Button disabled={saving} onClick={handleSave}>
					{saving ? "Saving..." : "Save Settings"}
				</Button>
			</div>
		</div>
	);
}
