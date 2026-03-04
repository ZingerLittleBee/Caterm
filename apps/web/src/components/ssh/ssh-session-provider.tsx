import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { ReactNode } from "react";
import {
	createContext,
	useCallback,
	useContext,
	useEffect,
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
	retry: (sessionId: string) => Promise<void>;
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

	// Keep a ref to the latest sessions map so removeSession can read it
	// without abusing setSessions as a state-reading mechanism.
	const sessionsRef = useRef(sessions);
	sessionsRef.current = sessions;

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

		// Find a fallback session before removing, using the ref for latest state.
		let fallback: string | null = null;
		for (const key of sessionsRef.current.keys()) {
			if (key !== sessionId) {
				fallback = key;
				break;
			}
		}

		setSessions((prev) => {
			const next = new Map(prev);
			next.delete(sessionId);
			return next;
		});

		// If the removed session was active, switch to the fallback.
		setActiveSessionId((current) =>
			current === sessionId ? fallback : current
		);
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

			// Listen for reconnecting events.
			const unlistenReconnecting = await listen(
				`ssh-reconnecting-${sessionId}`,
				() => {
					updateSessionStatus(sessionId, "reconnecting");
				}
			);

			// Listen for reconnected events.
			const unlistenReconnected = await listen(
				`ssh-reconnected-${sessionId}`,
				() => {
					updateSessionStatus(sessionId, "connected");
				}
			);

			// Listen for disconnect events.
			const unlistenDisconnect = await listen(
				`ssh-disconnect-${sessionId}`,
				() => {
					updateSessionStatus(sessionId, "disconnected");
				}
			);

			// Store a combined unlisten function.
			const unlisten = () => {
				unlistenReconnecting();
				unlistenReconnected();
				unlistenDisconnect();
			};
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

	const retry = useCallback(async (sessionId: string): Promise<void> => {
		await invoke("ssh_retry", { sessionId });
	}, []);

	const setActive = useCallback((sessionId: string | null) => {
		setActiveSessionId(sessionId);
	}, []);

	// Cleanup all sessions and listeners when the provider unmounts
	// (e.g., user navigates away from /ssh).
	useEffect(() => {
		return () => {
			for (const [, unlisten] of unlistenMap.current) {
				unlisten();
			}
			unlistenMap.current.clear();

			for (const sid of sessionsRef.current.keys()) {
				invoke("ssh_disconnect", { sessionId: sid }).catch(() => {
					// Session may already be closed
				});
			}
		};
	}, []);

	return (
		<SshSessionContext.Provider
			value={{
				sessions,
				activeSessionId,
				connect,
				disconnect,
				retry,
				setActive,
			}}
		>
			{children}
		</SshSessionContext.Provider>
	);
}
