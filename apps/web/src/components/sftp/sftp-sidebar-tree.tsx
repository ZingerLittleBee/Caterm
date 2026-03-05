import {
	ChevronRight,
	File,
	Folder,
	FolderOpen,
	Loader2,
	RefreshCw,
} from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { useSftp } from "@/components/sftp/sftp-provider";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import type { FileEntry } from "@/types/sftp";

interface TreeNode {
	children: TreeNode[] | null;
	entry: FileEntry;
	expanded: boolean;
	loading: boolean;
}

function sortEntries(entries: FileEntry[]): FileEntry[] {
	return [...entries].sort((a, b) => {
		if (a.isDir !== b.isDir) {
			return a.isDir ? -1 : 1;
		}
		return a.name.localeCompare(b.name);
	});
}

function buildNodes(entries: FileEntry[]): TreeNode[] {
	return sortEntries(entries).map((entry) => ({
		children: null,
		entry,
		expanded: false,
		loading: false,
	}));
}

function updateNodeAtPath(
	nodes: TreeNode[],
	path: string,
	updater: (node: TreeNode) => TreeNode
): TreeNode[] {
	return nodes.map((node) => {
		if (node.entry.path === path) {
			return updater(node);
		}
		if (node.children) {
			return {
				...node,
				children: updateNodeAtPath(node.children, path, updater),
			};
		}
		return node;
	});
}

interface SftpSidebarTreeProps {
	sftpSessionId: string;
}

export function SftpSidebarTree({ sftpSessionId }: SftpSidebarTreeProps) {
	const { listDir } = useSftp();
	const [nodes, setNodes] = useState<TreeNode[]>([]);
	const [rootLoading, setRootLoading] = useState(true);

	const loadRoot = useCallback(async () => {
		setRootLoading(true);
		try {
			const entries = await listDir(sftpSessionId, "/");
			setNodes(buildNodes(entries));
		} catch {
			// Failed to load root directory.
		} finally {
			setRootLoading(false);
		}
	}, [listDir, sftpSessionId]);

	useEffect(() => {
		loadRoot();
	}, [loadRoot]);

	const handleToggle = useCallback(
		async (node: TreeNode) => {
			if (!node.entry.isDir) {
				return;
			}

			if (node.expanded) {
				setNodes((prev) =>
					updateNodeAtPath(prev, node.entry.path, (n) => ({
						...n,
						expanded: false,
					}))
				);
				return;
			}

			if (node.children !== null) {
				setNodes((prev) =>
					updateNodeAtPath(prev, node.entry.path, (n) => ({
						...n,
						expanded: true,
					}))
				);
				return;
			}

			setNodes((prev) =>
				updateNodeAtPath(prev, node.entry.path, (n) => ({
					...n,
					loading: true,
				}))
			);

			try {
				const entries = await listDir(sftpSessionId, node.entry.path);
				setNodes((prev) =>
					updateNodeAtPath(prev, node.entry.path, (n) => ({
						...n,
						children: buildNodes(entries),
						expanded: true,
						loading: false,
					}))
				);
			} catch {
				setNodes((prev) =>
					updateNodeAtPath(prev, node.entry.path, (n) => ({
						...n,
						loading: false,
					}))
				);
			}
		},
		[listDir, sftpSessionId]
	);

	return (
		<div className="flex h-full flex-col border-l">
			<div className="flex items-center justify-between border-b px-3 py-2">
				<span className="font-medium text-sm">Files</span>
				<Button
					disabled={rootLoading}
					onClick={loadRoot}
					size="icon"
					variant="ghost"
				>
					<RefreshCw
						className={rootLoading ? "h-4 w-4 animate-spin" : "h-4 w-4"}
					/>
				</Button>
			</div>
			<ScrollArea className="flex-1">
				{rootLoading && nodes.length === 0 ? (
					<div className="flex items-center justify-center py-8">
						<Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
					</div>
				) : (
					<div className="py-1">
						{nodes.map((node) => (
							<TreeNodeRow
								depth={0}
								key={node.entry.path}
								node={node}
								onToggle={handleToggle}
							/>
						))}
					</div>
				)}
			</ScrollArea>
		</div>
	);
}

interface TreeNodeRowProps {
	depth: number;
	node: TreeNode;
	onToggle: (node: TreeNode) => void;
}

function TreeNodeRow({ depth, node, onToggle }: TreeNodeRowProps) {
	const isDir = node.entry.isDir;
	const paddingLeft = depth * 16 + 4;

	return (
		<>
			<button
				className="flex w-full items-center gap-1 px-1 py-0.5 text-left text-sm hover:bg-accent"
				onClick={() => onToggle(node)}
				style={{ paddingLeft }}
				type="button"
			>
				{isDir ? (
					<>
						{node.loading ? (
							<Loader2 className="h-4 w-4 shrink-0 animate-spin text-muted-foreground" />
						) : (
							<ChevronRight
								className={`h-4 w-4 shrink-0 transition-transform ${node.expanded ? "rotate-90" : ""}`}
							/>
						)}
						{node.expanded ? (
							<FolderOpen className="h-4 w-4 shrink-0 text-muted-foreground" />
						) : (
							<Folder className="h-4 w-4 shrink-0 text-muted-foreground" />
						)}
					</>
				) : (
					<>
						<span className="h-4 w-4 shrink-0" />
						<File className="h-4 w-4 shrink-0 text-muted-foreground" />
					</>
				)}
				<span className="truncate">{node.entry.name}</span>
			</button>
			{isDir && node.expanded && node.children && (
				<div>
					{node.children.map((child) => (
						<TreeNodeRow
							depth={depth + 1}
							key={child.entry.path}
							node={child}
							onToggle={onToggle}
						/>
					))}
				</div>
			)}
		</>
	);
}
