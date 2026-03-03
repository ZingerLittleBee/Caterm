export interface SshHost {
	authType: string;
	createdAt: string;
	hostname: string;
	id: string;
	name: string;
	port: number;
	updatedAt: string;
	username: string;
}

export interface CreateHostInput {
	authType: "password" | "key";
	hostname: string;
	name: string;
	port?: number;
	username: string;
}

export interface UpdateHostInput {
	authType?: string;
	hostname?: string;
	id: string;
	name?: string;
	port?: number;
	username?: string;
}

export type SshSessionStatus =
	| "connecting"
	| "connected"
	| "disconnected"
	| "error";

export interface SshSessionInfo {
	hostId: string;
	hostName: string;
	id: string;
	status: SshSessionStatus;
}
