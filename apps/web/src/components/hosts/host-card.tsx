import {
	MoreHorizontalIcon,
	PencilIcon,
	PlugIcon,
	Trash2Icon,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
	Card,
	CardAction,
	CardContent,
	CardDescription,
	CardHeader,
	CardTitle,
} from "@/components/ui/card";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuSeparator,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import type { SshHost } from "@/types/ssh";

interface HostCardProps {
	host: SshHost;
	onConnect: (host: SshHost) => void;
	onDelete: (host: SshHost) => void;
	onEdit: (host: SshHost) => void;
}

export function HostCard({ host, onConnect, onEdit, onDelete }: HostCardProps) {
	return (
		<Card size="sm">
			<CardHeader>
				<CardTitle>{host.name}</CardTitle>
				<CardDescription>
					{host.username}@{host.hostname}:{host.port}
				</CardDescription>
				<CardAction>
					<DropdownMenu>
						<DropdownMenuTrigger
							render={<Button size="icon-xs" variant="ghost" />}
						>
							<MoreHorizontalIcon />
							<span className="sr-only">Host actions</span>
						</DropdownMenuTrigger>
						<DropdownMenuContent align="end">
							<DropdownMenuItem onClick={() => onConnect(host)}>
								<PlugIcon />
								Connect
							</DropdownMenuItem>
							<DropdownMenuItem onClick={() => onEdit(host)}>
								<PencilIcon />
								Edit
							</DropdownMenuItem>
							<DropdownMenuSeparator />
							<DropdownMenuItem
								onClick={() => onDelete(host)}
								variant="destructive"
							>
								<Trash2Icon />
								Delete
							</DropdownMenuItem>
						</DropdownMenuContent>
					</DropdownMenu>
				</CardAction>
			</CardHeader>
			<CardContent>
				<div className="flex items-center gap-2 text-muted-foreground text-xs">
					<span className="rounded bg-muted px-1.5 py-0.5">
						{host.authType}
					</span>
				</div>
			</CardContent>
		</Card>
	);
}
