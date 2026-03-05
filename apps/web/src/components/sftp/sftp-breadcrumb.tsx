import { ChevronRight } from "lucide-react";

interface SftpBreadcrumbProps {
	onNavigate: (path: string) => void;
	path: string;
}

export function SftpBreadcrumb({ path, onNavigate }: SftpBreadcrumbProps) {
	const segments = path.split("/").filter(Boolean);

	return (
		<nav className="flex items-center gap-0.5 overflow-x-auto text-sm">
			<button
				className="shrink-0 rounded px-1.5 py-0.5 text-muted-foreground hover:bg-muted hover:text-foreground"
				onClick={() => onNavigate("/")}
				type="button"
			>
				/
			</button>
			{segments.map((segment, index) => {
				const segmentPath = `/${segments.slice(0, index + 1).join("/")}`;
				const isLast = index === segments.length - 1;
				return (
					<span className="flex items-center gap-0.5" key={segmentPath}>
						<ChevronRight className="h-3 w-3 shrink-0 text-muted-foreground" />
						<button
							className={`shrink-0 truncate rounded px-1.5 py-0.5 ${
								isLast
									? "font-medium text-foreground"
									: "text-muted-foreground hover:bg-muted hover:text-foreground"
							}`}
							disabled={isLast}
							onClick={() => onNavigate(segmentPath)}
							type="button"
						>
							{segment}
						</button>
					</span>
				);
			})}
		</nav>
	);
}
