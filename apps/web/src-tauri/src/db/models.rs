use serde::{Deserialize, Serialize};

/// Represents an SSH host configuration stored in the database.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshHost {
    pub id: String,
    pub name: String,
    pub hostname: String,
    pub port: i32,
    pub username: String,
    pub auth_type: String,
    pub created_at: String,
    pub updated_at: String,
}

/// Terminal display and behavior settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalSettings {
    pub id: i32,
    pub font_family: String,
    pub font_size: i32,
    pub cursor_style: String,
    pub cursor_blink: bool,
    pub scrollback: i32,
    pub theme: String,
}

impl Default for TerminalSettings {
    fn default() -> Self {
        Self {
            id: 1,
            font_family: "monospace".to_string(),
            font_size: 14,
            cursor_style: "block".to_string(),
            cursor_blink: true,
            scrollback: 1000,
            theme: "dark".to_string(),
        }
    }
}

/// Input for creating a new SSH host.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateHostInput {
    pub name: String,
    pub hostname: String,
    pub port: Option<i32>,
    pub username: String,
    pub auth_type: String,
}

/// Input for updating an existing SSH host.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateHostInput {
    pub id: String,
    pub name: Option<String>,
    pub hostname: Option<String>,
    pub port: Option<i32>,
    pub username: Option<String>,
    pub auth_type: Option<String>,
}
