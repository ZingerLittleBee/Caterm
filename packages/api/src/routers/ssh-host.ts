import { db } from "@Caterm/db";
import { sshHost } from "@Caterm/db/schema/ssh-host";
import { ORPCError } from "@orpc/server";
import { and, eq } from "drizzle-orm";
import z from "zod";

import { protectedProcedure } from "../index";
import { decrypt, encrypt } from "../utils/crypto";

function encryptOptional(value: string | undefined): string | null {
	return value ? encrypt(value) : null;
}

function decryptOptional(value: string | null): string | undefined {
	return value ? decrypt(value) : undefined;
}

export const sshHostRouter = {
	list: protectedProcedure.handler(async ({ context }) => {
		const rows = await db
			.select({
				id: sshHost.id,
				name: sshHost.name,
				hostname: sshHost.hostname,
				port: sshHost.port,
				username: sshHost.username,
				authType: sshHost.authType,
				createdAt: sshHost.createdAt,
				updatedAt: sshHost.updatedAt,
			})
			.from(sshHost)
			.where(eq(sshHost.userId, context.session.user.id))
			.orderBy(sshHost.name);
		return rows;
	}),

	getById: protectedProcedure
		.input(z.object({ id: z.string() }))
		.handler(async ({ input, context }) => {
			const rows = await db
				.select()
				.from(sshHost)
				.where(
					and(
						eq(sshHost.id, input.id),
						eq(sshHost.userId, context.session.user.id)
					)
				);
			if (rows.length === 0) {
				throw new ORPCError("NOT_FOUND", { message: "Host not found" });
			}
			const row = rows[0];
			return {
				...row,
				password: decryptOptional(row.password),
				privateKey: decryptOptional(row.privateKey),
				keyPassphrase: decryptOptional(row.keyPassphrase),
			};
		}),

	create: protectedProcedure
		.input(
			z.object({
				name: z.string().min(1),
				hostname: z.string().min(1),
				port: z.number().int().min(1).max(65_535).default(22),
				username: z.string().min(1),
				authType: z.enum(["password", "key"]).default("password"),
				password: z.string().optional(),
				privateKey: z.string().optional(),
				keyPassphrase: z.string().optional(),
			})
		)
		.handler(async ({ input, context }) => {
			const id = crypto.randomUUID();
			await db.insert(sshHost).values({
				id,
				userId: context.session.user.id,
				name: input.name,
				hostname: input.hostname,
				port: input.port,
				username: input.username,
				authType: input.authType,
				password: encryptOptional(input.password),
				privateKey: encryptOptional(input.privateKey),
				keyPassphrase: encryptOptional(input.keyPassphrase),
			});
			return { id };
		}),

	update: protectedProcedure
		.input(
			z.object({
				id: z.string(),
				name: z.string().min(1).optional(),
				hostname: z.string().min(1).optional(),
				port: z.number().int().min(1).max(65_535).optional(),
				username: z.string().min(1).optional(),
				authType: z.enum(["password", "key"]).optional(),
				password: z.string().optional(),
				privateKey: z.string().optional(),
				keyPassphrase: z.string().optional(),
			})
		)
		.handler(async ({ input, context }) => {
			const { id, password, privateKey, keyPassphrase, ...rest } = input;
			const values: Record<string, unknown> = { ...rest };
			if (password !== undefined) {
				values.password = encryptOptional(password);
			}
			if (privateKey !== undefined) {
				values.privateKey = encryptOptional(privateKey);
			}
			if (keyPassphrase !== undefined) {
				values.keyPassphrase = encryptOptional(keyPassphrase);
			}
			await db
				.update(sshHost)
				.set(values)
				.where(
					and(eq(sshHost.id, id), eq(sshHost.userId, context.session.user.id))
				);
			return { id };
		}),

	delete: protectedProcedure
		.input(z.object({ id: z.string() }))
		.handler(async ({ input, context }) => {
			await db
				.delete(sshHost)
				.where(
					and(
						eq(sshHost.id, input.id),
						eq(sshHost.userId, context.session.user.id)
					)
				);
			return { success: true };
		}),
};
