// ws_watcher.rs — background thread that watches podium-server's live event
// stream and drives the tray count + native notifications (T1.4).
//
// WS vs. poll: podium-server already runs a Broadcaster actor
// (Sources/PodiumServer/WebSocket/Broadcaster.swift) that fans `{type, data,
// timestamp}` envelopes out over `/ws` — `session_updated`/`session_created`
// carry the full Session (status, awaiting_input_since, name) on every
// change. That's exactly the transition data a notification needs (which
// session, what it's called, what it became), and it's already there — no
// business logic to reinvent. Polling `/api/stats` would give a live
// `active_agents` *count* cheaply, but not *which* session flipped state or
// its display name, so a poll-only design would still need a second GET
// per tick to resolve that. A single WS connection gives us both count
// (recompute from the running session map) and per-event detail for free,
// so it's the simpler design here, not just the "more real-time" one.
//
// Reconnection: tungstenite's blocking client is used directly (no async
// runtime pulled in just for this) on its own std::thread, matching the
// existing sync style in main.rs (health poll also blocks a thread). On
// disconnect/error it backs off briefly and reconnects — the server may not
// be up yet at watcher-thread start, or may restart independently of the
// shell.

use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::time::Duration;

use serde::Deserialize;
use tauri::{AppHandle, Manager};
use tauri_plugin_notification::NotificationExt;
use tungstenite::client::connect;

use crate::notify_settings::NotifySettings;
use crate::TrayState;

const RECONNECT_DELAY: Duration = Duration::from_secs(3);

#[derive(Debug, Deserialize)]
struct Envelope {
    #[serde(rename = "type")]
    kind: String,
    data: serde_json::Value,
}

#[derive(Debug, Clone, Deserialize)]
struct SessionPayload {
    id: String,
    name: Option<String>,
    status: Option<String>,
    #[serde(rename = "awaiting_input_since")]
    awaiting_input_since: Option<String>,
}

/// Agent envelopes are only used as a "something changed" trigger to
/// re-poll `/api/stats` (see `refresh_active_count`) — we don't need any of
/// their fields, just confirmation the payload parses as an agent-shaped
/// object.
#[derive(Debug, Clone, Deserialize)]
struct AgentPayload {}

/// What we remember per session, just enough to detect a transition without
/// re-deriving business logic the server already owns.
#[derive(Debug, Clone, PartialEq)]
struct TrackedSession {
    status: String,
    awaiting_input: bool,
}

pub fn run(app: AppHandle, port: u16) {
    let data_dir = crate::default_data_dir_for_watcher();
    let mut settings = NotifySettings::load_or_create(&data_dir);
    let mut last_settings_check = std::time::Instant::now();

    let mut sessions: HashMap<String, TrackedSession> = HashMap::new();

    loop {
        let url = format!("ws://127.0.0.1:{port}/ws");
        match connect(&url) {
            Ok((mut socket, _response)) => {
                println!("ws_watcher: connected to {url}");
                // Seed the tray from /api/stats right away: WS only pushes on
                // *change*, so without this the count (and the "Server:
                // running" status line) wouldn't reflect reality until the
                // next session/agent transition — a quiet server would leave
                // the tray stuck on its initial "starting…" text.
                refresh_active_count(&app);
                loop {
                    // Re-read the toggle file occasionally so a hand-edit
                    // takes effect without restarting the app.
                    if last_settings_check.elapsed() > Duration::from_secs(10) {
                        settings = NotifySettings::load_or_create(&data_dir);
                        last_settings_check = std::time::Instant::now();
                    }

                    let msg = match socket.read() {
                        Ok(msg) => msg,
                        Err(err) => {
                            eprintln!("ws_watcher: read error, reconnecting: {err}");
                            break;
                        }
                    };

                    let text = match msg {
                        tungstenite::Message::Text(text) => text,
                        tungstenite::Message::Close(_) => {
                            eprintln!("ws_watcher: server closed connection, reconnecting");
                            break;
                        }
                        _ => continue,
                    };

                    let Ok(envelope) = serde_json::from_str::<Envelope>(&text) else {
                        continue;
                    };

                    handle_envelope(&app, &envelope, &mut sessions, &settings);
                }
            }
            Err(err) => {
                eprintln!("ws_watcher: connect failed ({err}), retrying in {RECONNECT_DELAY:?}");
            }
        }

        std::thread::sleep(RECONNECT_DELAY);
    }
}

fn handle_envelope(
    app: &AppHandle,
    envelope: &Envelope,
    sessions: &mut HashMap<String, TrackedSession>,
    settings: &NotifySettings,
) {
    match envelope.kind.as_str() {
        "session_created" | "session_updated" => {
            let Ok(session) = serde_json::from_value::<SessionPayload>(envelope.data.clone()) else {
                return;
            };
            apply_session(app, session, sessions, settings);
        }
        "agent_created" | "agent_updated" => {
            // Agents don't carry a display name we'd want in a notification
            // (that lives on the session), but a status flip on the lone
            // main agent of a session can occur before session_updated
            // arrives in some races; recompute the active-agent count
            // regardless so the tray stays live even if only agent events
            // are flowing.
            let _ = serde_json::from_value::<AgentPayload>(envelope.data.clone());
            refresh_active_count(app);
        }
        _ => {}
    }
}

fn apply_session(
    app: &AppHandle,
    session: SessionPayload,
    sessions: &mut HashMap<String, TrackedSession>,
    settings: &NotifySettings,
) {
    let status = session.status.clone().unwrap_or_default();
    let awaiting_input = session.awaiting_input_since.is_some();
    let next = TrackedSession {
        status: status.clone(),
        awaiting_input,
    };

    let previous = sessions.get(&session.id).cloned();
    sessions.insert(session.id.clone(), next.clone());

    let display_name = session.name.clone().unwrap_or_else(|| session.id.clone());

    let transitioned_to_awaiting = awaiting_input
        && previous.as_ref().map(|p| !p.awaiting_input).unwrap_or(true);
    let transitioned_to_completed =
        status == "completed" && previous.as_ref().map(|p| p.status != "completed").unwrap_or(true);
    let transitioned_to_error =
        status == "error" && previous.as_ref().map(|p| p.status != "error").unwrap_or(true);

    if transitioned_to_error && settings.on_error {
        notify(app, "Podium — session error", &format!("{display_name} hit an error."));
    } else if transitioned_to_completed && settings.on_completed {
        notify(app, "Podium — session finished", &format!("{display_name} completed."));
    } else if transitioned_to_awaiting && settings.on_awaiting_input {
        notify(app, "Podium — awaiting input", &format!("{display_name} is waiting for your input."));
    }

    refresh_active_count_from_map(app, sessions);
}

fn notify(app: &AppHandle, title: &str, body: &str) {
    if let Err(err) = app.notification().builder().title(title).body(body).show() {
        eprintln!("ws_watcher: failed to show notification: {err}");
    }
}

/// Recomputes the "active" count as sessions whose last-known status is
/// `active` (i.e. not completed/error/abandoned), and pushes it into the
/// tray tooltip + the disabled "N active" menu line.
fn refresh_active_count_from_map(app: &AppHandle, sessions: &HashMap<String, TrackedSession>) {
    let active = sessions.values().filter(|s| s.status == "active").count();
    update_tray(app, active);
}

/// Cheap fallback used for agent-only events: re-derive the count from
/// `/api/stats` (the server's own `active_agents` figure) rather than
/// maintaining a second shadow tally in Rust.
fn refresh_active_count(app: &AppHandle) {
    // B1: use the port the shell actually resolved at startup (`run`'s
    // `port` param, mirrored into `ActivePort` in main.rs) rather than the
    // configured target port, which may not be where podium-server ended
    // up after a fallback.
    let port = crate::active_port(app);
    let url = format!("http://127.0.0.1:{port}/api/stats");
    let Ok(resp) = ureq::get(&url).timeout(Duration::from_millis(1000)).call() else {
        return;
    };
    let Ok(json) = resp.into_json::<serde_json::Value>() else {
        return;
    };
    let Some(count) = json.get("active_agents").and_then(|v| v.as_u64()) else {
        return;
    };
    update_tray(app, count as usize);
}

fn update_tray(app: &AppHandle, active: usize) {
    let state = app.state::<TrayState>();
    state.active_agents.store(active, Ordering::SeqCst);

    if let Some(item) = state.status_item.lock().unwrap().as_ref() {
        let label = if active > 0 {
            format!("{active} active")
        } else {
            "Server: running".to_string()
        };
        let _ = item.set_text(label);
    }

    if let Some(tray) = app.tray_by_id("main-tray") {
        let tooltip = if active > 0 {
            format!("Podium — {active} active")
        } else {
            "Podium".to_string()
        };
        let _ = tray.set_tooltip(Some(&tooltip));
    }
}
