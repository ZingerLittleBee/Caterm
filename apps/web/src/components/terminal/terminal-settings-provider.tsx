import { useMutation, useQuery } from "@tanstack/react-query";
import {
	createContext,
	type ReactNode,
	useCallback,
	useContext,
	useEffect,
	useMemo,
} from "react";
import { client, queryClient } from "@/lib/orpc";
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

const SETTINGS_QUERY_KEY = ["terminalSettings", "get"] as const;

function normalizeApiData(raw: unknown): {
	global: TerminalSettings;
	hostOverrides: Record<string, Partial<TerminalSettings>>;
} {
	const rawData = raw as {
		global?: Record<string, unknown>;
		hostOverrides?: Record<string, Partial<TerminalSettings>>;
	};
	return {
		global: {
			...DEFAULT_TERMINAL_SETTINGS,
			...rawData.global,
		} as TerminalSettings,
		hostOverrides: (rawData.hostOverrides ?? {}) as Record<
			string,
			Partial<TerminalSettings>
		>,
	};
}

type SettingsData = ReturnType<typeof normalizeApiData>;

export function TerminalSettingsProvider({
	children,
}: {
	children: ReactNode;
}) {
	const { data, isLoading } = useQuery({
		queryKey: SETTINGS_QUERY_KEY,
		queryFn: async () => {
			const raw = await client.terminalSettings.get();
			return normalizeApiData(raw);
		},
		placeholderData: () => {
			const cached = readSettingsCache();
			return cached ? normalizeApiData(cached) : undefined;
		},
	});

	useEffect(() => {
		if (data) {
			writeSettingsCache(data);
		}
	}, [data]);

	const upsertMutation = useMutation({
		mutationFn: (input: {
			global?: Partial<TerminalSettings>;
			hostOverrides?: Record<string, Partial<TerminalSettings>>;
		}) => client.terminalSettings.upsert(input),
		onSuccess: () => {
			queryClient.invalidateQueries({ queryKey: SETTINGS_QUERY_KEY });
		},
	});

	const deleteHostOverrideMutation = useMutation({
		mutationFn: (input: { hostId: string }) =>
			client.terminalSettings.deleteHostOverride(input),
		onSuccess: () => {
			queryClient.invalidateQueries({ queryKey: SETTINGS_QUERY_KEY });
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

	const setOptimisticData = useCallback((newData: SettingsData) => {
		queryClient.setQueryData<SettingsData>(SETTINGS_QUERY_KEY, newData);
	}, []);

	const updateGlobal = useCallback(
		(partial: Partial<TerminalSettings>) => {
			const newGlobal = { ...globalSettings, ...partial };
			setOptimisticData({
				global: newGlobal,
				hostOverrides: hostOverridesRecord,
			});
			upsertMutation.mutate({ global: partial });
		},
		[globalSettings, hostOverridesRecord, upsertMutation, setOptimisticData]
	);

	const updateHostOverrides = useCallback(
		(hostId: string, partial: Partial<TerminalSettings>) => {
			const existing = hostOverridesRecord[hostId] ?? {};
			const merged = { ...existing, ...partial };
			const newOverrides = {
				...hostOverridesRecord,
				[hostId]: merged,
			};
			setOptimisticData({
				global: globalSettings,
				hostOverrides: newOverrides,
			});
			upsertMutation.mutate({
				hostOverrides: { [hostId]: merged },
			});
		},
		[globalSettings, hostOverridesRecord, upsertMutation, setOptimisticData]
	);

	const clearHostOverrides = useCallback(
		(hostId: string) => {
			const { [hostId]: _, ...rest } = hostOverridesRecord;
			setOptimisticData({
				global: globalSettings,
				hostOverrides: rest,
			});
			deleteHostOverrideMutation.mutate({ hostId });
		},
		[
			globalSettings,
			hostOverridesRecord,
			deleteHostOverrideMutation,
			setOptimisticData,
		]
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
