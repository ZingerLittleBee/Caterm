import { createAuthClient } from "better-auth/react";

const serverUrl = import.meta.env.VITE_SERVER_URL || "http://localhost:3001";

export const authClient = createAuthClient({
	baseURL: serverUrl,
});
