import { useMutation, useQuery } from "@tanstack/react-query";
import {
	createContext,
	type ReactNode,
	useCallback,
	useContext,
	useMemo,
} from "react";
import { client, orpc, queryClient } from "@/lib/orpc";
import {
	readSettingsCache,
	writeSettingsCache,
} from "@/lib/terminal-settings-cache";
import {
	DEFAULT_TERMINAL_SETTINGS,
	resolveSettings,
} from "@/lib/terminal-themes";
import type { TerminalSettings, TerminalSettingsState } from "@/types/ssh";

interface TerminalSettingsContextValue {
	clearHostOverrides: (hostId: string) => void;
	getSettingsForHost: (hostId: string) => TerminalSettings;
	isLoading: boolean;
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

interface ApiData {
	global: TerminalSettings;
	hostOverrides: Record<string, Partial<TerminalSettings>>;
}

export function TerminalSettingsProvider({
	children,
}: {
	children: ReactNode;
}) {
	const { data, isLoading } = useQuery({
		...orpc.terminalSettings.get.queryOptions(),
		placeholderData: () => readSettingsCache(),
		select: (raw: ApiData): ApiData => {
			const result = {
				global: { ...DEFAULT_TERMINAL_SETTINGS, ...raw.global },
				hostOverrides: raw.hostOverrides ?? {},
			};
			writeSettingsCache(result);
			return result;
		},
	});

	const upsertMutation = useMutation({
		mutationFn: (input: {
			global?: Partial<TerminalSettings>;
			hostOverrides?: Record<string, Partial<TerminalSettings>>;
		}) => client.terminalSettings.upsert(input),
		onSuccess: () => {
			queryClient.invalidateQueries({
				queryKey: orpc.terminalSettings.get.queryOptions().queryKey,
			});
		},
	});

	const globalSettings = data?.global ?? DEFAULT_TERMINAL_SETTINGS;
	const hostOverridesRecord = data?.hostOverrides ?? {};

	const state: TerminalSettingsState = useMemo(
		() => ({
			global: globalSettings,
			hostOverrides: new Map(Object.entries(hostOverridesRecord)),
		}),
		[globalSettings, hostOverridesRecord]
	);

	const getSettingsForHost = useCallback(
		(hostId: string): TerminalSettings => resolveSettings(state, hostId),
		[state]
	);

	const updateGlobal = useCallback(
		(partial: Partial<TerminalSettings>) => {
			const newGlobal = { ...globalSettings, ...partial };
			writeSettingsCache({
				global: newGlobal,
				hostOverrides: hostOverridesRecord,
			});
			queryClient.setQueryData(
				orpc.terminalSettings.get.queryOptions().queryKey,
				{ global: newGlobal, hostOverrides: hostOverridesRecord }
			);
			upsertMutation.mutate({ global: partial });
		},
		[globalSettings, hostOverridesRecord, upsertMutation]
	);

	const updateHostOverrides = useCallback(
		(hostId: string, partial: Partial<TerminalSettings>) => {
			const existing = hostOverridesRecord[hostId] ?? {};
			const newOverrides = {
				...hostOverridesRecord,
				[hostId]: { ...existing, ...partial },
			};
			writeSettingsCache({
				global: globalSettings,
				hostOverrides: newOverrides,
			});
			queryClient.setQueryData(
				orpc.terminalSettings.get.queryOptions().queryKey,
				{ global: globalSettings, hostOverrides: newOverrides }
			);
			upsertMutation.mutate({
				hostOverrides: { [hostId]: { ...existing, ...partial } },
			});
		},
		[globalSettings, hostOverridesRecord, upsertMutation]
	);

	const clearHostOverrides = useCallback(
		(hostId: string) => {
			const { [hostId]: _, ...rest } = hostOverridesRecord;
			writeSettingsCache({ global: globalSettings, hostOverrides: rest });
			queryClient.setQueryData(
				orpc.terminalSettings.get.queryOptions().queryKey,
				{ global: globalSettings, hostOverrides: rest }
			);
			upsertMutation.mutate({ hostOverrides: rest });
		},
		[globalSettings, hostOverridesRecord, upsertMutation]
	);

	return (
		<TerminalSettingsContext.Provider
			value={{
				settings: globalSettings,
				isLoading,
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
