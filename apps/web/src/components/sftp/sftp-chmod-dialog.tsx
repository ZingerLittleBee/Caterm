import { Dialog } from "@base-ui/react/dialog";
import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { useSftp } from "./sftp-provider";

interface SftpChmodDialogProps {
	currentPermissions: number;
	onClose: () => void;
	open: boolean;
	path: string;
	sessionId: string;
}

const PERMISSION_BITS = [
	{ bit: 0o400, group: "Owner", label: "Read" },
	{ bit: 0o200, group: "Owner", label: "Write" },
	{ bit: 0o100, group: "Owner", label: "Execute" },
	{ bit: 0o040, group: "Group", label: "Read" },
	{ bit: 0o020, group: "Group", label: "Write" },
	{ bit: 0o010, group: "Group", label: "Execute" },
	{ bit: 0o004, group: "Others", label: "Read" },
	{ bit: 0o002, group: "Others", label: "Write" },
	{ bit: 0o001, group: "Others", label: "Execute" },
] as const;

function hasBit(mode: number, bit: number): boolean {
	// biome-ignore lint/suspicious/noBitwiseOperators: bitwise operations are intentional for permission masks
	return (mode & bit) !== 0;
}

function modeToOctal(mode: number): string {
	// biome-ignore lint/suspicious/noBitwiseOperators: bitwise operations are intentional for permission masks
	return (mode & 0o777).toString(8).padStart(3, "0");
}

function octalToMode(octal: string): number {
	const parsed = Number.parseInt(octal, 8);
	if (Number.isNaN(parsed) || parsed < 0 || parsed > 0o777) {
		return -1;
	}
	return parsed;
}

export function SftpChmodDialog({
	currentPermissions,
	onClose,
	open,
	path,
	sessionId,
}: SftpChmodDialogProps) {
	const { chmod } = useSftp();
	// biome-ignore lint/suspicious/noBitwiseOperators: bitwise operations are intentional for permission masks
	const [mode, setMode] = useState(currentPermissions & 0o777);
	const [octalInput, setOctalInput] = useState(modeToOctal(currentPermissions));
	const [applying, setApplying] = useState(false);

	useEffect(() => {
		if (open) {
			// biome-ignore lint/suspicious/noBitwiseOperators: bitwise operations are intentional for permission masks
			const m = currentPermissions & 0o777;
			setMode(m);
			setOctalInput(modeToOctal(m));
		}
	}, [open, currentPermissions]);

	const handleBitToggle = useCallback(
		(bit: number, checked: boolean) => {
			// biome-ignore lint/suspicious/noBitwiseOperators: bitwise operations are intentional for permission masks
			const next = checked ? mode | bit : mode & ~bit;
			setMode(next);
			setOctalInput(modeToOctal(next));
		},
		[mode]
	);

	const handleOctalChange = useCallback(
		(e: React.ChangeEvent<HTMLInputElement>) => {
			const value = e.target.value;
			setOctalInput(value);
			const parsed = octalToMode(value);
			if (parsed >= 0) {
				setMode(parsed);
			}
		},
		[]
	);

	const handleApply = useCallback(async () => {
		setApplying(true);
		try {
			await chmod(sessionId, path, mode);
			toast.success("Permissions updated");
			onClose();
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			toast.error("Failed to update permissions", { description: message });
		} finally {
			setApplying(false);
		}
	}, [chmod, sessionId, path, mode, onClose]);

	const groups = ["Owner", "Group", "Others"] as const;

	return (
		<Dialog.Root onOpenChange={(isOpen) => !isOpen && onClose()} open={open}>
			<Dialog.Portal>
				<Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
				<Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-sm -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
					<Dialog.Title className="font-medium text-base">
						Permissions
					</Dialog.Title>
					<Dialog.Description className="mt-1 text-muted-foreground text-sm">
						{path}
					</Dialog.Description>

					<div className="mt-4 space-y-3">
						{groups.map((group) => (
							<div key={group}>
								<span className="font-medium text-sm">{group}</span>
								<div className="mt-1 flex items-center gap-4">
									{PERMISSION_BITS.filter((p) => p.group === group).map(
										(perm) => (
											<span
												className="flex items-center gap-1.5 text-sm"
												key={perm.bit}
											>
												<Checkbox
													checked={hasBit(mode, perm.bit)}
													onCheckedChange={(checked) =>
														handleBitToggle(perm.bit, checked === true)
													}
												/>
												{perm.label}
											</span>
										)
									)}
								</div>
							</div>
						))}
					</div>

					<div className="mt-4">
						<label className="text-sm" htmlFor="octal-input">
							Octal
						</label>
						<Input
							className="mt-1 w-24 font-mono"
							id="octal-input"
							maxLength={3}
							onChange={handleOctalChange}
							value={octalInput}
						/>
					</div>

					<div className="mt-4 flex justify-end gap-2">
						<Dialog.Close
							render={
								<Button onClick={onClose} variant="outline">
									Cancel
								</Button>
							}
						/>
						<Button disabled={applying} onClick={handleApply}>
							{applying ? "Applying..." : "Apply"}
						</Button>
					</div>
				</Dialog.Popup>
			</Dialog.Portal>
		</Dialog.Root>
	);
}
