import "@xterm/xterm/css/xterm.css";

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { WebglAddon } from "@xterm/addon-webgl";
import { Terminal } from "@xterm/xterm";
import { useEffect, useRef } from "react";

interface SshTerminalProps {
	cursorBlink?: boolean;
	cursorStyle?: "block" | "underline" | "bar";
	fontFamily?: string;
	fontSize?: number;
	isActive: boolean;
	scrollback?: number;
	sessionId: string;
}

export function SshTerminal({
	sessionId,
	isActive,
	fontSize = 14,
	fontFamily = "monospace",
	cursorStyle = "block",
	cursorBlink = true,
	scrollback = 1000,
}: SshTerminalProps) {
	const containerRef = useRef<HTMLDivElement>(null);
	const terminalRef = useRef<Terminal | null>(null);
	const fitAddonRef = useRef<FitAddon | null>(null);
	const rafIdRef = useRef<number>(0);

	// Store terminal options in a ref so the initialization effect does not
	// need them in its dependency array. Re-creating the terminal on every
	// option change would be wasteful and disruptive.
	const optionsRef = useRef({
		cursorBlink,
		cursorStyle,
		fontFamily,
		fontSize,
		scrollback,
	});
	optionsRef.current = {
		cursorBlink,
		cursorStyle,
		fontFamily,
		fontSize,
		scrollback,
	};

	// Initialize terminal on mount and clean up on unmount.
	useEffect(() => {
		const container = containerRef.current;
		if (!container) {
			return;
		}

		const options = optionsRef.current;
		const terminal = new Terminal({
			allowProposedApi: true,
			cursorBlink: options.cursorBlink,
			cursorStyle: options.cursorStyle,
			fontFamily: options.fontFamily,
			fontSize: options.fontSize,
			scrollback: options.scrollback,
		});

		const fitAddon = new FitAddon();
		terminal.loadAddon(fitAddon);
		terminal.loadAddon(new WebLinksAddon());

		terminal.open(container);

		// Try to load the WebGL renderer for better performance.
		// Falls back to the default canvas renderer if WebGL is unavailable.
		try {
			terminal.loadAddon(new WebglAddon());
		} catch {
			// WebGL not available, canvas renderer is used automatically.
		}

		terminalRef.current = terminal;
		fitAddonRef.current = fitAddon;

		// Initial fit after the terminal is attached to the DOM.
		requestAnimationFrame(() => {
			fitAddon.fit();
		});

		// Forward user input to the SSH backend as base64-encoded data.
		const dataDisposable = terminal.onData((data: string) => {
			invoke("ssh_write", { sessionId, data: btoa(data) }).catch(() => {
				// Write failures are expected when the session disconnects.
			});
		});

		// Forward terminal resize events to the SSH backend.
		const resizeDisposable = terminal.onResize(
			({ cols, rows }: { cols: number; rows: number }) => {
				invoke("ssh_resize", { sessionId, cols, rows }).catch(() => {
					// Resize failures are expected when the session disconnects.
				});
			}
		);

		// Listen for SSH output from the backend.
		let outputUnlisten: (() => void) | null = null;
		const outputListenerPromise = listen<string>(
			`ssh-output-${sessionId}`,
			(event) => {
				terminal.write(atob(event.payload));
			}
		).then((unlisten) => {
			outputUnlisten = unlisten;
		});

		// Listen for disconnect events from the backend.
		let disconnectUnlisten: (() => void) | null = null;
		const disconnectListenerPromise = listen(
			`ssh-disconnect-${sessionId}`,
			() => {
				terminal.write("\r\n\x1b[31mDisconnected.\x1b[0m\r\n");
			}
		).then((unlisten) => {
			disconnectUnlisten = unlisten;
		});

		// Handle window resize by re-fitting the terminal.
		const handleWindowResize = () => {
			cancelAnimationFrame(rafIdRef.current);
			rafIdRef.current = requestAnimationFrame(() => {
				fitAddon.fit();
			});
		};

		window.addEventListener("resize", handleWindowResize);

		// Cleanup on unmount.
		return () => {
			window.removeEventListener("resize", handleWindowResize);
			cancelAnimationFrame(rafIdRef.current);

			dataDisposable.dispose();
			resizeDisposable.dispose();

			// Clean up async event listeners.
			outputListenerPromise.then(() => {
				outputUnlisten?.();
			});
			disconnectListenerPromise.then(() => {
				disconnectUnlisten?.();
			});

			terminal.dispose();
			terminalRef.current = null;
			fitAddonRef.current = null;
		};
	}, [sessionId]);

	// Re-fit terminal when it becomes the active tab.
	useEffect(() => {
		if (!isActive) {
			return;
		}

		const id = requestAnimationFrame(() => {
			const fitAddon = fitAddonRef.current;
			const terminal = terminalRef.current;
			if (fitAddon && terminal) {
				fitAddon.fit();
				terminal.focus();
			}
		});

		return () => {
			cancelAnimationFrame(id);
		};
	}, [isActive]);

	return (
		<div
			aria-label={`SSH terminal session ${sessionId}`}
			className="h-full w-full"
			ref={containerRef}
			role="application"
			style={{ display: isActive ? "block" : "none" }}
		/>
	);
}
