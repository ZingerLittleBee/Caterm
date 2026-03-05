import { index, pgTable, text, timestamp } from "drizzle-orm/pg-core";
import { user } from "./auth";
import { sshHost } from "./ssh-host";

export const sftpBookmark = pgTable(
	"sftp_bookmark",
	{
		id: text("id").primaryKey(),
		userId: text("user_id")
			.notNull()
			.references(() => user.id, { onDelete: "cascade" }),
		hostId: text("host_id")
			.notNull()
			.references(() => sshHost.id, { onDelete: "cascade" }),
		remotePath: text("remote_path").notNull(),
		label: text("label").notNull(),
		createdAt: timestamp("created_at").defaultNow().notNull(),
	},
	(table) => [index("sftp_bookmark_userId_idx").on(table.userId)]
);
