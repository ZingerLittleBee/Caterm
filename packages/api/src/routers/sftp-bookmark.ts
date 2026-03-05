import { db } from "@Caterm/db";
import { sftpBookmark } from "@Caterm/db/schema/sftp-bookmark";
import { ORPCError } from "@orpc/server";
import { and, eq } from "drizzle-orm";
import z from "zod";

import { protectedProcedure } from "../index";

export const sftpBookmarkRouter = {
	list: protectedProcedure
		.input(z.object({ hostId: z.string().optional() }))
		.handler(async ({ input, context }) => {
			const conditions = [eq(sftpBookmark.userId, context.session.user.id)];
			if (input.hostId) {
				conditions.push(eq(sftpBookmark.hostId, input.hostId));
			}
			const rows = await db
				.select()
				.from(sftpBookmark)
				.where(and(...conditions))
				.orderBy(sftpBookmark.label);
			return rows;
		}),

	create: protectedProcedure
		.input(
			z.object({
				hostId: z.string().min(1),
				label: z.string().min(1),
				remotePath: z.string().min(1),
			})
		)
		.handler(async ({ input, context }) => {
			const id = crypto.randomUUID();
			await db.insert(sftpBookmark).values({
				id,
				userId: context.session.user.id,
				hostId: input.hostId,
				label: input.label,
				remotePath: input.remotePath,
			});
			return { id };
		}),

	update: protectedProcedure
		.input(
			z.object({
				id: z.string(),
				label: z.string().min(1).optional(),
				remotePath: z.string().min(1).optional(),
			})
		)
		.handler(async ({ input, context }) => {
			const { id, ...rest } = input;
			const result = await db
				.update(sftpBookmark)
				.set(rest)
				.where(
					and(
						eq(sftpBookmark.id, id),
						eq(sftpBookmark.userId, context.session.user.id)
					)
				)
				.returning({ id: sftpBookmark.id });
			if (result.length === 0) {
				throw new ORPCError("NOT_FOUND", {
					message: "Bookmark not found",
				});
			}
			return { id };
		}),

	delete: protectedProcedure
		.input(z.object({ id: z.string() }))
		.handler(async ({ input, context }) => {
			const result = await db
				.delete(sftpBookmark)
				.where(
					and(
						eq(sftpBookmark.id, input.id),
						eq(sftpBookmark.userId, context.session.user.id)
					)
				)
				.returning({ id: sftpBookmark.id });
			if (result.length === 0) {
				throw new ORPCError("NOT_FOUND", {
					message: "Bookmark not found",
				});
			}
			return { success: true };
		}),
};
