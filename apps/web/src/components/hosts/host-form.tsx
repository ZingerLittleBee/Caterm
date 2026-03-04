import { useForm } from "@tanstack/react-form";
import { useCallback } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
	Select,
	SelectContent,
	SelectItem,
	SelectTrigger,
	SelectValue,
} from "@/components/ui/select";
import type { SshHost } from "@/types/ssh";

interface HostFormValues {
	authType: "password" | "key";
	hostname: string;
	keyPassphrase: string;
	name: string;
	password: string;
	port: number;
	privateKey: string;
	username: string;
}

interface HostFormProps {
	host?: SshHost;
	onCancel: () => void;
	onSubmit: (values: HostFormValues) => void;
}

const AUTH_TYPE_ITEMS = {
	password: "Password",
	key: "SSH Key",
} as const;

export function HostForm({ host, onSubmit, onCancel }: HostFormProps) {
	const form = useForm({
		defaultValues: {
			name: host?.name ?? "",
			hostname: host?.hostname ?? "",
			port: host?.port ?? 22,
			username: host?.username ?? "",
			authType: (host?.authType as "password" | "key") ?? "password",
			password: "",
			privateKey: "",
			keyPassphrase: "",
		},
		onSubmit: ({ value }) => {
			onSubmit(value);
		},
	});

	const handleFormSubmit = useCallback(
		(e: React.FormEvent) => {
			e.preventDefault();
			e.stopPropagation();
			form.handleSubmit();
		},
		[form]
	);

	return (
		<form className="flex flex-col gap-4" onSubmit={handleFormSubmit}>
			<div className="flex flex-col gap-2">
				<Label htmlFor="host-name">Name</Label>
				<form.Field name="name">
					{(field) => (
						<Input
							id="host-name"
							onBlur={field.handleBlur}
							onChange={(e) => field.handleChange(e.target.value)}
							placeholder="My Server"
							value={field.state.value}
						/>
					)}
				</form.Field>
			</div>

			<div className="flex flex-col gap-2">
				<Label htmlFor="host-hostname">Hostname</Label>
				<form.Field name="hostname">
					{(field) => (
						<Input
							id="host-hostname"
							onBlur={field.handleBlur}
							onChange={(e) => field.handleChange(e.target.value)}
							placeholder="192.168.1.1 or example.com"
							value={field.state.value}
						/>
					)}
				</form.Field>
			</div>

			<div className="grid grid-cols-2 gap-4">
				<div className="flex flex-col gap-2">
					<Label htmlFor="host-port">Port</Label>
					<form.Field name="port">
						{(field) => (
							<Input
								id="host-port"
								max={65_535}
								min={1}
								onBlur={field.handleBlur}
								onChange={(e) =>
									field.handleChange(Number.parseInt(e.target.value, 10) || 22)
								}
								type="number"
								value={String(field.state.value)}
							/>
						)}
					</form.Field>
				</div>

				<div className="flex flex-col gap-2">
					<Label htmlFor="host-username">Username</Label>
					<form.Field name="username">
						{(field) => (
							<Input
								id="host-username"
								onBlur={field.handleBlur}
								onChange={(e) => field.handleChange(e.target.value)}
								placeholder="root"
								value={field.state.value}
							/>
						)}
					</form.Field>
				</div>
			</div>

			<div className="flex flex-col gap-2">
				<Label>Authentication Type</Label>
				<form.Field name="authType">
					{(field) => (
						<Select
							items={AUTH_TYPE_ITEMS}
							onValueChange={(value) => {
								field.handleChange(value as "password" | "key");
							}}
							value={field.state.value}
						>
							<SelectTrigger className="w-full">
								<SelectValue placeholder="Select auth type" />
							</SelectTrigger>
							<SelectContent>
								<SelectItem value="password">Password</SelectItem>
								<SelectItem value="key">SSH Key</SelectItem>
							</SelectContent>
						</Select>
					)}
				</form.Field>
			</div>

			<form.Subscribe selector={(state) => state.values.authType}>
				{(authType) =>
					authType === "password" ? (
						<div className="flex flex-col gap-2">
							<Label htmlFor="host-password">Password</Label>
							<form.Field name="password">
								{(field) => (
									<Input
										id="host-password"
										onBlur={field.handleBlur}
										onChange={(e) => field.handleChange(e.target.value)}
										placeholder="Enter password"
										type="password"
										value={field.state.value}
									/>
								)}
							</form.Field>
						</div>
					) : (
						<>
							<div className="flex flex-col gap-2">
								<Label htmlFor="host-private-key">Private Key</Label>
								<form.Field name="privateKey">
									{(field) => (
										<textarea
											className="min-h-24 w-full rounded-lg border border-input bg-transparent px-2.5 py-2 font-mono text-sm outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
											id="host-private-key"
											onBlur={field.handleBlur}
											onChange={(e) => field.handleChange(e.target.value)}
											placeholder="Paste your private key here..."
											value={field.state.value}
										/>
									)}
								</form.Field>
							</div>
							<div className="flex flex-col gap-2">
								<Label htmlFor="host-key-passphrase">
									Key Passphrase (optional)
								</Label>
								<form.Field name="keyPassphrase">
									{(field) => (
										<Input
											id="host-key-passphrase"
											onBlur={field.handleBlur}
											onChange={(e) => field.handleChange(e.target.value)}
											placeholder="Passphrase for private key"
											type="password"
											value={field.state.value}
										/>
									)}
								</form.Field>
							</div>
						</>
					)
				}
			</form.Subscribe>

			<div className="flex justify-end gap-2 pt-2">
				<Button onClick={onCancel} type="button" variant="outline">
					Cancel
				</Button>
				<Button type="submit">{host ? "Update" : "Create"}</Button>
			</div>
		</form>
	);
}
