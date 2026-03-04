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
			.$onUpdate(() => /* @__PURE__ */ new Date())
			.notNull(),
	},
	(table) => [index("ssh_host_userId_idx").on(table.userId)]
);
