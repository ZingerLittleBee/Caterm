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
        // Accept all server keys for now (Trust On First Use).
        // TODO: Implement known_hosts verification for production use.
        Ok(true)
    }
}
