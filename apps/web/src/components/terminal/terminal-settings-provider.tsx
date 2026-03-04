import type { ReactNode } from "react";
import { createContext, useCallback, useContext, useReducer } from "react";
import {
	DEFAULT_TERMINAL_SETTINGS,
	resolveSettings,
} from "@/lib/terminal-themes";
import type {
	HostTerminalOverrides,
	TerminalSettings,
	TerminalSettingsState,
} from "@/types/ssh";

// --- Reducer ---

type TerminalSettingsAction =
	| { type: "UPDATE_GLOBAL"; payload: Partial<TerminalSettings> }
	| {
			type: "UPDATE_HOST_OVERRIDES";
			hostId: string;
			payload: Partial<TerminalSettings>;
	  }
	| { type: "CLEAR_HOST_OVERRIDES"; hostId: string };

function terminalSettingsReducer(
	state: TerminalSettingsState,
	action: TerminalSettingsAction
): TerminalSettingsState {
	switch (action.type) {
		case "UPDATE_GLOBAL":
			return {
				...state,
				global: { ...state.global, ...action.payload },
			};
		case "UPDATE_HOST_OVERRIDES": {
			const next = new Map(state.hostOverrides);
			const existing = next.get(action.hostId) ?? {};
			next.set(action.hostId, { ...existing, ...action.payload });
			return { ...state, hostOverrides: next };
		}
		case "CLEAR_HOST_OVERRIDES": {
			const next = new Map(state.hostOverrides);
			next.delete(action.hostId);
			return { ...state, hostOverrides: next };
		}
		default:
			return state;
	}
}

// --- Context ---

interface TerminalSettingsContextValue {
	clearHostOverrides: (hostId: string) => void;
	getSettingsForHost: (hostId: string) => TerminalSettings;
	settings: TerminalSettings;
	updateGlobal: (partial: Partial<TerminalSettings>) => void;
	updateHostOverrides: (
		hostId: string,
		partial: Partial<TerminalSettings>
	) => void;
}

const TerminalSettingsContext =
	createContext<TerminalSettingsContextValue | null>(null);

export function useTerminalSettings(): TerminalSettingsContextValue {
	const context = useContext(TerminalSettingsContext);
	if (!context) {
		throw new Error(
			"useTerminalSettings must be used within a TerminalSettingsProvider"
		);
	}
	return context;
}

// --- Provider ---

export function TerminalSettingsProvider({
	children,
}: {
	children: ReactNode;
}) {
	const [state, dispatch] = useReducer(terminalSettingsReducer, {
		global: DEFAULT_TERMINAL_SETTINGS,
		hostOverrides: new Map<string, HostTerminalOverrides>(),
	});

	const updateGlobal = useCallback((partial: Partial<TerminalSettings>) => {
		dispatch({ type: "UPDATE_GLOBAL", payload: partial });
	}, []);

	const updateHostOverrides = useCallback(
		(hostId: string, partial: Partial<TerminalSettings>) => {
			dispatch({ type: "UPDATE_HOST_OVERRIDES", hostId, payload: partial });
		},
		[]
	);

	const clearHostOverrides = useCallback((hostId: string) => {
		dispatch({ type: "CLEAR_HOST_OVERRIDES", hostId });
	}, []);

	const getSettingsForHost = useCallback(
		(hostId: string): TerminalSettings => resolveSettings(state, hostId),
		[state.global, state.hostOverrides]
	);

	return (
		<TerminalSettingsContext.Provider
			value={{
				settings: state.global,
				getSettingsForHost,
				updateGlobal,
				updateHostOverrides,
				clearHostOverrides,
			}}
		>
			{children}
		</TerminalSettingsContext.Provider>
	);
}
