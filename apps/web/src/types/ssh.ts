export interface SshHost {
	authType: string;
	createdAt: Date;
	hostname: string;
	id: string;
	name: string;
	port: number;
	updatedAt: Date;
	username: string;
}

export type SshSessionStatus =
	| "connecting"
	| "connected"
	| "reconnecting"
	| "disconnected"
	| "error";

export interface SshSessionInfo {
	hostId: string;
	hostName: string;
	id: string;
	status: SshSessionStatus;
}
