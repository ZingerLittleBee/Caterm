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
				scrollback: z.number().int().min(100).max(100_000).optional(),
				theme: z.string().optional(),
			})
		)
		.handler(async ({ input, context }) => {
			const userId = context.session.user.id;
			await db
				.insert(terminalSettings)
				.values({
					userId,
					...DEFAULT_SETTINGS,
					...input,
				})
				.onConflictDoUpdate({
					target: terminalSettings.userId,
					set: input,
				});
			return { success: true };
		}),
};
