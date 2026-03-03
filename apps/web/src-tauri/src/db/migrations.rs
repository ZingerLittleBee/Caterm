use tauri_plugin_sql::{Migration, MigrationKind};

/// Returns all database migrations for the application.
pub fn get_migrations() -> Vec<Migration> {
    vec![
        Migration {
            version: 1,
            description: "create ssh_hosts table",
            sql: "CREATE TABLE IF NOT EXISTS ssh_hosts (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                hostname TEXT NOT NULL,
                port INTEGER NOT NULL DEFAULT 22,
                username TEXT NOT NULL,
                auth_type TEXT NOT NULL DEFAULT 'password',
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );",
            kind: MigrationKind::Up,
        },
        Migration {
            version: 2,
            description: "create terminal_settings table",
            sql: "CREATE TABLE IF NOT EXISTS terminal_settings (
                id INTEGER PRIMARY KEY NOT NULL DEFAULT 1,
                font_family TEXT NOT NULL DEFAULT 'monospace',
                font_size INTEGER NOT NULL DEFAULT 14,
                cursor_style TEXT NOT NULL DEFAULT 'block',
                cursor_blink INTEGER NOT NULL DEFAULT 1,
                scrollback INTEGER NOT NULL DEFAULT 1000,
                theme TEXT NOT NULL DEFAULT 'dark'
            );
            INSERT OR IGNORE INTO terminal_settings (id) VALUES (1);",
            kind: MigrationKind::Up,
        },
    ]
}
