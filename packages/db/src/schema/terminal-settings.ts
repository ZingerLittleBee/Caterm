import { jsonb, pgTable, serial, text } from "drizzle-orm/pg-core";
import { user } from "./auth";

export const terminalSettings = pgTable("terminal_settings", {
	id: serial("id").primaryKey(),
	userId: text("user_id")
		.notNull()
		.references(() => user.id, { onDelete: "cascade" })
		.unique(),
	settingsJson: jsonb("settings_json").notNull().default({}),
	hostOverridesJson: jsonb("host_overrides_json").notNull().default({}),
});
