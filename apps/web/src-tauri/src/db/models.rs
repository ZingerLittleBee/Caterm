use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[allow(dead_code)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[allow(dead_code)]
pub struct TerminalSettings {
    pub id: String,
    pub font_family: String,
    pub font_size: i32,
    pub cursor_style: String,
    pub cursor_blink: bool,
    pub scrollback: i32,
    pub theme: String,
}
