import { appDataDir } from "@tauri-apps/api/path";
import { type Client, Stronghold } from "@tauri-apps/plugin-stronghold";

const VAULT_PASSWORD = "caterm-stronghold-default";
const CLIENT_NAME = "caterm";

let cachedStronghold: Stronghold | null = null;

async function getStronghold(): Promise<Stronghold> {
	if (cachedStronghold) {
		return cachedStronghold;
	}
	const dir = await appDataDir();
	const vaultPath = `${dir}/vault.hold`;
	cachedStronghold = await Stronghold.load(vaultPath, VAULT_PASSWORD);
	return cachedStronghold;
}

async function getStore() {
	const stronghold = await getStronghold();
	let client: Client;
	try {
		client = await stronghold.loadClient(CLIENT_NAME);
	} catch {
		client = await stronghold.createClient(CLIENT_NAME);
	}
	return { store: client.getStore(), stronghold };
}

function encode(value: string): number[] {
	return Array.from(new TextEncoder().encode(value));
}

function decode(data: Uint8Array | null): string | null {
	if (!data) {
		return null;
	}
	return new TextDecoder().decode(data);
}

export async function saveCredential(
	hostId: string,
	authType: "password" | "key",
	password?: string,
	privateKey?: string,
	keyPassphrase?: string
): Promise<void> {
	const { store, stronghold } = await getStore();

	if (authType === "password" && password) {
		await store.insert(`ssh-password-${hostId}`, encode(password));
	} else if (authType === "key") {
		if (privateKey) {
			await store.insert(`ssh-private-key-${hostId}`, encode(privateKey));
		}
		if (keyPassphrase) {
			await store.insert(`ssh-key-passphrase-${hostId}`, encode(keyPassphrase));
		}
	}

	await stronghold.save();
}

export async function loadCredential(
	hostId: string,
	authType: string
): Promise<{
	keyPassphrase?: string;
	password?: string;
	privateKey?: string;
}> {
	const { store } = await getStore();

	if (authType === "password") {
		const data = await store.get(`ssh-password-${hostId}`);
		return { password: decode(data) ?? undefined };
	}

	const keyData = await store.get(`ssh-private-key-${hostId}`);
	const passphraseData = await store.get(`ssh-key-passphrase-${hostId}`);
	return {
		privateKey: decode(keyData) ?? undefined,
		keyPassphrase: decode(passphraseData) ?? undefined,
	};
}

export async function deleteCredential(hostId: string): Promise<void> {
	const { store, stronghold } = await getStore();

	for (const suffix of ["password", "private-key", "key-passphrase"]) {
		try {
			await store.remove(`ssh-${suffix}-${hostId}`);
		} catch {
			// Key may not exist
		}
	}

	await stronghold.save();
}
