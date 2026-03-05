import {
	Download,
	FolderPlus,
	RefreshCw,
	Search,
	Trash2,
	Upload,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
	Tooltip,
	TooltipContent,
	TooltipProvider,
	TooltipTrigger,
} from "@/components/ui/tooltip";

interface SftpToolbarProps {
	onDelete?: () => void;
	onDownload?: () => void;
	onNewFolder?: () => void;
	onRefresh?: () => void;
	onSearch?: () => void;
	onUpload?: () => void;
}

function ToolbarButton({
	icon,
	label,
	onClick,
	disabled,
}: {
	disabled?: boolean;
	icon: React.ReactNode;
	label: string;
	onClick?: () => void;
}) {
	return (
		<Tooltip>
			<TooltipTrigger
				render={
					<Button
						disabled={disabled || !onClick}
						onClick={onClick}
						size="icon"
						variant="ghost"
					>
						{icon}
						<span className="sr-only">{label}</span>
					</Button>
				}
			/>
			<TooltipContent>{label}</TooltipContent>
		</Tooltip>
	);
}

export function SftpToolbar({
	onUpload,
	onDownload,
	onNewFolder,
	onDelete,
	onRefresh,
	onSearch,
}: SftpToolbarProps) {
	return (
		<TooltipProvider>
			<div className="flex items-center gap-0.5">
				<ToolbarButton
					icon={<Upload className="h-4 w-4" />}
					label="Upload"
					onClick={onUpload}
				/>
				<ToolbarButton
					icon={<Download className="h-4 w-4" />}
					label="Download"
					onClick={onDownload}
				/>
				<ToolbarButton
					icon={<FolderPlus className="h-4 w-4" />}
					label="New Folder"
					onClick={onNewFolder}
				/>
				<ToolbarButton
					icon={<Trash2 className="h-4 w-4" />}
					label="Delete"
					onClick={onDelete}
				/>
				<div className="mx-1 h-4 w-px bg-border" />
				<ToolbarButton
					icon={<RefreshCw className="h-4 w-4" />}
					label="Refresh"
					onClick={onRefresh}
				/>
				<ToolbarButton
					icon={<Search className="h-4 w-4" />}
					label="Search"
					onClick={onSearch}
				/>
			</div>
		</TooltipProvider>
	);
}
