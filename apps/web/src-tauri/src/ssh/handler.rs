use async_trait::async_trait;
use russh::client::Handler;
use russh::keys::key::PublicKey;

/// SSH client handler that implements the russh Handler trait.
/// Currently accepts all server keys (TOFU - Trust On First Use).
pub struct SshClientHandler;

#[async_trait]
impl Handler for SshClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &PublicKey,
    ) -> Result<bool, Self::Error> {
        // SECURITY TODO(v2): Implement proper host key verification.
        //
        // Currently accepts ALL server keys without verification. This is a
        // known security risk that makes the application vulnerable to
        // man-in-the-middle attacks. Before shipping a production release:
        //
        // 1. Implement a known_hosts file (~/.ssh/known_hosts or app-specific).
        // 2. On first connection, prompt the user to accept the server's
        //    fingerprint (Trust On First Use / TOFU).
        // 3. On subsequent connections, verify the server key matches the
        //    stored fingerprint and warn/block on mismatch.
        // 4. Consider supporting key pinning and certificate-based verification.
        Ok(true)
    }
}
