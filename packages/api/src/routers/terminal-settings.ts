import { db } from "@Caterm/db";
import { terminalSettings } from "@Caterm/db/schema/terminal-settings";
import { eq } from "drizzle-orm";
import z from "zod";

import { protectedProcedure } from "../index";

const DEFAULT_GLOBAL = {
	bellStyle: "none",
	cursorBlink: true,
	cursorInactiveStyle: "outline",
	cursorStyle: "block",
	fontFamily: "monospace",
	fontSize: 14,
	letterSpacing: 0,
	lineHeight: 1.0,
	scrollback: 1000,
	themeName: "default",
	themeOverrides: {},
};

const terminalSettingsInput = z.object({
	bellStyle: z.enum(["none", "sound", "visual", "both"]).optional(),
	cursorBlink: z.boolean().optional(),
	cursorInactiveStyle: z
		.enum(["outline", "block", "bar", "underline", "none"])
		.optional(),
	cursorStyle: z.enum(["block", "underline", "bar"]).optional(),
	fontFamily: z.string().optional(),
	fontSize: z.number().int().min(8).max(72).optional(),
	letterSpacing: z.number().min(-5).max(10).optional(),
	lineHeight: z.number().min(1.0).max(2.0).optional(),
	scrollback: z.number().int().min(100).max(100_000).optional(),
	themeName: z.string().optional(),
	themeOverrides: z.record(z.string(), z.string().optional()).optional(),
});

export const terminalSettingsRouter = {
	get: protectedProcedure.handler(async ({ context }) => {
		const rows = await db
			.select()
			.from(terminalSettings)
			.where(eq(terminalSettings.userId, context.session.user.id));
		if (rows.length === 0) {
			return { global: DEFAULT_GLOBAL, hostOverrides: {} };
		}
		const row = rows[0];
		return {
			global: {
				...DEFAULT_GLOBAL,
				...(row.settingsJson as Record<string, unknown>),
			},
			hostOverrides: (row.hostOverridesJson ?? {}) as Record<
				string,
				Record<string, unknown>
			>,
		};
	}),

	upsert: protectedProcedure
		.input(
			z.object({
				global: terminalSettingsInput.optional(),
				hostOverrides: z.record(z.string(), terminalSettingsInput).optional(),
			})
		)
		.handler(async ({ input, context }) => {
			const userId = context.session.user.id;

			const existing = await db
				.select()
				.from(terminalSettings)
				.where(eq(terminalSettings.userId, userId));

			const currentGlobal =
				existing.length > 0
					? (existing[0].settingsJson as Record<string, unknown>)
					: {};
			const currentOverrides =
				existing.length > 0
					? (existing[0].hostOverridesJson as Record<string, unknown>)
					: {};

			const mergedGlobal = input.global
				? { ...currentGlobal, ...input.global }
				: currentGlobal;
			const mergedOverrides = input.hostOverrides
				? { ...currentOverrides, ...input.hostOverrides }
				: currentOverrides;

			await db
				.insert(terminalSettings)
				.values({
					userId,
					settingsJson: mergedGlobal,
					hostOverridesJson: mergedOverrides,
				})
				.onConflictDoUpdate({
					target: terminalSettings.userId,
					set: {
						settingsJson: mergedGlobal,
						hostOverridesJson: mergedOverrides,
					},
				});

			return { success: true };
		}),
};
