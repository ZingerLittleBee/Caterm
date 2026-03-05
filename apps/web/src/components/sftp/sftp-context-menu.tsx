import {
	ClipboardCopy,
	Download,
	Eye,
	FileEdit,
	FolderOpen,
	KeyRound,
	Pencil,
	Trash2,
} from "lucide-react";
import type { ReactNode } from "react";
import { useCallback, useEffect, useRef } from "react";
import type { FileEntry } from "@/types/sftp";

interface SftpContextMenuProps {
	entry: FileEntry | null;
	onClose: () => void;
	onCopyPath?: (entry: FileEntry) => void;
	onDelete?: (entry: FileEntry) => void;
	onDownload?: (entry: FileEntry) => void;
	onEdit?: (entry: FileEntry) => void;
	onOpen?: (entry: FileEntry) => void;
	onPermissions?: (entry: FileEntry) => void;
	onPreview?: (entry: FileEntry) => void;
	onRename?: (entry: FileEntry) => void;
	position: { x: number; y: number } | null;
}

interface MenuItemProps {
	disabled?: boolean;
	icon: ReactNode;
	label: string;
	onClick: () => void;
	variant?: "default" | "destructive";
}

function getMenuItemClass(disabled?: boolean, variant?: string): string {
	if (disabled) {
		return "cursor-not-allowed opacity-50";
	}
	if (variant === "destructive") {
		return "hover:bg-destructive/10 hover:text-destructive";
	}
	return "hover:bg-accent hover:text-accent-foreground";
}

function MenuItem({
	disabled,
	icon,
	label,
	onClick,
	variant = "default",
}: MenuItemProps) {
	return (
		<button
			className={`flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-none transition-colors ${getMenuItemClass(disabled, variant)}`}
			disabled={disabled}
			onClick={onClick}
			type="button"
		>
			{icon}
			{label}
		</button>
	);
}

export function SftpContextMenu({
	entry,
	onClose,
	onCopyPath,
	onDelete,
	onDownload,
	onEdit,
	onOpen,
	onPermissions,
	onPreview,
	onRename,
	position,
}: SftpContextMenuProps) {
	const menuRef = useRef<HTMLDivElement>(null);

	useEffect(() => {
		if (!position) {
			return;
		}

		const handleClick = (e: MouseEvent) => {
			if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
				onClose();
			}
		};

		const handleEscape = (e: KeyboardEvent) => {
			if (e.key === "Escape") {
				onClose();
			}
		};

		document.addEventListener("mousedown", handleClick);
		document.addEventListener("keydown", handleEscape);
		return () => {
			document.removeEventListener("mousedown", handleClick);
			document.removeEventListener("keydown", handleEscape);
		};
	}, [position, onClose]);

	const handleAction = useCallback(
		(action?: (entry: FileEntry) => void) => {
			if (action && entry) {
				action(entry);
			}
			onClose();
		},
		[entry, onClose]
	);

	if (!(position && entry)) {
		return null;
	}

	return (
		<div
			className="fixed z-50 min-w-[180px] rounded-md border bg-popover p-1 text-popover-foreground shadow-md"
			ref={menuRef}
			style={{ left: position.x, top: position.y }}
		>
			<MenuItem
				icon={<FolderOpen className="h-4 w-4" />}
				label="Open"
				onClick={() => handleAction(onOpen)}
			/>
			{!entry.isDir && (
				<MenuItem
					icon={<Eye className="h-4 w-4" />}
					label="Preview"
					onClick={() => handleAction(onPreview)}
				/>
			)}
			{!entry.isDir && (
				<MenuItem
					icon={<FileEdit className="h-4 w-4" />}
					label="Edit"
					onClick={() => handleAction(onEdit)}
				/>
			)}
			<MenuItem
				disabled={entry.isDir}
				icon={<Download className="h-4 w-4" />}
				label={entry.isDir ? "Download as..." : "Download"}
				onClick={() => handleAction(onDownload)}
			/>
			<div className="my-1 h-px bg-border" />
			<MenuItem
				icon={<Pencil className="h-4 w-4" />}
				label="Rename"
				onClick={() => handleAction(onRename)}
			/>
			<MenuItem
				icon={<ClipboardCopy className="h-4 w-4" />}
				label="Copy Path"
				onClick={() => handleAction(onCopyPath)}
			/>
			<MenuItem
				icon={<KeyRound className="h-4 w-4" />}
				label="Permissions"
				onClick={() => handleAction(onPermissions)}
			/>
			<div className="my-1 h-px bg-border" />
			<MenuItem
				icon={<Trash2 className="h-4 w-4" />}
				label="Delete"
				onClick={() => handleAction(onDelete)}
				variant="destructive"
			/>
		</div>
	);
}
