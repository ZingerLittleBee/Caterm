import { boolean, integer, pgTable, serial, text } from "drizzle-orm/pg-core";
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
