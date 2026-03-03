import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { ReactNode } from "react";
import {
	createContext,
	useCallback,
	useContext,
	useRef,
	useState,
} from "react";
import type { SshSessionInfo, SshSessionStatus } from "@/types/ssh";

interface ConnectParams {
	authType: "password" | "key";
	hostId: string;
	hostName: string;
	hostname: string;
	keyPassphrase?: string;
	password?: string;
	port?: number;
	privateKey?: string;
	username: string;
}

interface SshSessionContextValue {
	activeSessionId: string | null;
	connect: (params: ConnectParams) => Promise<string>;
	disconnect: (sessionId: string) => Promise<void>;
	sessions: Map<string, SshSessionInfo>;
	setActive: (sessionId: string | null) => void;
}

const SshSessionContext = createContext<SshSessionContextValue | null>(null);

export function useSshSessions(): SshSessionContextValue {
	const context = useContext(SshSessionContext);
	if (!context) {
		throw new Error("useSshSessions must be used within an SshSessionProvider");
	}
	return context;
}

export function SshSessionProvider({ children }: { children: ReactNode }) {
	const [sessions, setSessions] = useState<Map<string, SshSessionInfo>>(
		() => new Map()
	);
	const [activeSessionId, setActiveSessionId] = useState<string | null>(null);

	// Store unlisten functions keyed by session ID, using a ref to avoid
	// unnecessary re-renders when listeners change.
	const unlistenMap = useRef<Map<string, () => void>>(new Map());

	const updateSessionStatus = useCallback(
		(sessionId: string, status: SshSessionStatus) => {
			setSessions((prev) => {
				const session = prev.get(sessionId);
				if (!session) {
					return prev;
				}
				const next = new Map(prev);
				next.set(sessionId, { ...session, status });
				return next;
			});
		},
		[]
	);

	const removeSession = useCallback((sessionId: string) => {
		// Clean up the event listener.
		const unlisten = unlistenMap.current.get(sessionId);
		if (unlisten) {
			unlisten();
			unlistenMap.current.delete(sessionId);
		}

		setSessions((prev) => {
			const next = new Map(prev);
			next.delete(sessionId);
			return next;
		});

		// If the removed session was active, switch to another session or null.
		setActiveSessionId((current) => {
			if (current !== sessionId) {
				return current;
			}

			// Find another session to activate.
			// We read sessions from the closure, but the setSessions above
			// may not have taken effect yet, so we need to manually exclude
			// the removed session.
			let fallback: string | null = null;
			setSessions((latest) => {
				for (const key of latest.keys()) {
					if (key !== sessionId) {
						fallback = key;
						break;
					}
				}
				return latest;
			});
			return fallback;
		});
	}, []);

	const connect = useCallback(
		async (params: ConnectParams): Promise<string> => {
			const sessionInfo: SshSessionInfo = {
				id: "", // Will be set after invoke returns
				hostId: params.hostId,
				hostName: params.hostName,
				status: "connecting",
			};

			const sessionId = await invoke<string>("ssh_connect", {
				hostId: params.hostId,
				hostname: params.hostname,
				port: params.port ?? 22,
				username: params.username,
				authType: params.authType,
				password: params.password,
				privateKey: params.privateKey,
				keyPassphrase: params.keyPassphrase,
			});

			sessionInfo.id = sessionId;
			sessionInfo.status = "connected";

			// Listen for disconnect events from the backend.
			const unlisten = await listen(`ssh-disconnect-${sessionId}`, () => {
				updateSessionStatus(sessionId, "disconnected");
				// Clean up the listener since the session is done.
				const storedUnlisten = unlistenMap.current.get(sessionId);
				if (storedUnlisten) {
					storedUnlisten();
					unlistenMap.current.delete(sessionId);
				}
			});

			unlistenMap.current.set(sessionId, unlisten);

			setSessions((prev) => {
				const next = new Map(prev);
				next.set(sessionId, sessionInfo);
				return next;
			});

			setActiveSessionId(sessionId);

			return sessionId;
		},
		[updateSessionStatus]
	);

	const disconnect = useCallback(
		async (sessionId: string): Promise<void> => {
			try {
				await invoke("ssh_disconnect", { sessionId });
			} catch {
				// Session may already be disconnected on the backend side.
			}
			removeSession(sessionId);
		},
		[removeSession]
	);

	const setActive = useCallback((sessionId: string | null) => {
		setActiveSessionId(sessionId);
	}, []);

	return (
		<SshSessionContext.Provider
			value={{
				sessions,
				activeSessionId,
				connect,
				disconnect,
				setActive,
			}}
		>
			{children}
		</SshSessionContext.Provider>
	);
}
