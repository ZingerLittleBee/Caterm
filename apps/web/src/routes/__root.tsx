import {
	createRootRouteWithContext,
	HeadContent,
	Outlet,
} from "@tanstack/react-router";
import { TanStackRouterDevtools } from "@tanstack/react-router-devtools";
import { TerminalSettingsProvider } from "@/components/terminal/terminal-settings-provider";
import { ThemeProvider } from "@/components/theme-provider";
import { Toaster } from "@/components/ui/sonner";

import "../index.css";

export type RouterAppContext = {};

export const Route = createRootRouteWithContext<RouterAppContext>()({
	component: RootComponent,
	head: () => ({
		meta: [
			{
				title: "Caterm",
			},
			{
				name: "description",
				content: "Caterm is a web application",
			},
		],
		links: [
			{
				rel: "icon",
				href: "/favicon.ico",
			},
		],
	}),
});

function RootComponent() {
	return (
		<>
			<HeadContent />
			<ThemeProvider
				attribute="class"
				defaultTheme="dark"
				disableTransitionOnChange
				storageKey="vite-ui-theme"
			>
				<TerminalSettingsProvider>
					<div className="grid h-svh grid-rows-[auto_1fr] overflow-hidden">
						<Outlet />
					</div>
					<Toaster richColors />
				</TerminalSettingsProvider>
			</ThemeProvider>
			<TanStackRouterDevtools position="bottom-left" />
		</>
	);
}
