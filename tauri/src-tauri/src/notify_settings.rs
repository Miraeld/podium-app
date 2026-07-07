// notify_settings.rs — per-event notification toggles, persisted as a flat
// JSON file next to podium-server's data dir (T1.4).
//
// No UI ships in this pass (Rust-only task per ROADMAP T1.4): the file is
// hand-editable. A future task can add a web-client settings panel that
// reads/writes the same file (or moves this into tauri-plugin-store proper
// if/when the webview needs to read it directly).
//
// Location: <data_dir>/tauri-notifications.json (sibling of the SQLite DB
// podium-server owns, so it's easy to find alongside the rest of Podium's
// on-disk state).

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct NotifySettings {
    /// Notify when a session (or its main agent) transitions to `completed`.
    pub on_completed: bool,
    /// Notify when a session (or agent) transitions to `error`.
    pub on_error: bool,
    /// Notify when a session starts waiting for user input
    /// (`awaiting_input_since` becomes non-null).
    pub on_awaiting_input: bool,
}

impl Default for NotifySettings {
    fn default() -> Self {
        Self {
            on_completed: true,
            on_error: true,
            on_awaiting_input: true,
        }
    }
}

impl NotifySettings {
    pub fn path(data_dir: &std::path::Path) -> PathBuf {
        data_dir.join("tauri-notifications.json")
    }

    /// Loads settings from disk, writing the default file if it doesn't
    /// exist yet (so the path is always hand-editable/discoverable after
    /// first launch).
    pub fn load_or_create(data_dir: &std::path::Path) -> Self {
        let path = Self::path(data_dir);
        match std::fs::read_to_string(&path) {
            Ok(contents) => serde_json::from_str(&contents).unwrap_or_default(),
            Err(_) => {
                let defaults = Self::default();
                if let Some(parent) = path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                if let Ok(json) = serde_json::to_string_pretty(&defaults) {
                    let _ = std::fs::write(&path, json);
                }
                defaults
            }
        }
    }
}
