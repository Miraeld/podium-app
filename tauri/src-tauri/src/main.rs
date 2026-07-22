// Podium Tauri shell — minimal Rust glue.
//
// Responsibilities (see tauri/README.md + repo ROADMAP.md T1.1/T1.4):
//   1. On launch: if something is already answering GET /api/health on the
//      target port, reuse it. Otherwise spawn the bundled `podium-server`
//      sidecar with --port + --data-dir (the same platform data dir
//      PodiumPaths.swift resolves, so it reads the user's existing DB).
//   2. Poll /api/health (timeout ~15s) until it returns 200, then navigate
//      the main window to http://localhost:<port> — podium-server serves
//      the whole web dashboard (WebClient/dist) itself, so the window just
//      points at it. No web assets are bundled by Tauri.
//   3. On window-close / app-exit: kill the sidecar IF we spawned it. Never
//      kill a pre-existing server we merely reused.
//   4. (T1.4) A system tray icon showing the live active-agent count, and
//      native OS notifications when a session finishes, errors, or goes
//      awaiting-input. Both are driven by a background thread that opens a
//      `/ws` connection to podium-server and reacts to its broadcast
//      envelopes — see `ws_watcher` below for the WS-vs-poll rationale.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod notify_settings;
mod ws_watcher;

use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU64, AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::webview::{NewWindowFeatures, NewWindowResponse};
use tauri::{Emitter, Manager, RunEvent, Url, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_opener::OpenerExt;
use tauri_plugin_shell::process::CommandChild;
use tauri_plugin_shell::ShellExt;
use tauri_plugin_updater::{Update, UpdaterExt};

const DEFAULT_PORT: u16 = 4820;
const HEALTH_TIMEOUT: Duration = Duration::from_secs(15);
const HEALTH_POLL_INTERVAL: Duration = Duration::from_millis(300);
/// A2/B1: how many ports above the target port podium-server itself will try
/// (mirrors `PodiumServerLifecycle.maxPortAttempts` in the Swift server) —
/// used as the health-poll fallback when the server-info file can't be read.
const MAX_PORT_FALLBACK_ATTEMPTS: u16 = 20;

/// Holds the sidecar's child handle IFF this app instance spawned it. `None`
/// means either "not started yet" or "we reused a server someone else is
/// running" — in both cases there is nothing for us to kill on exit.
struct SidecarState {
    child: Mutex<Option<CommandChild>>,
    spawned_by_us: AtomicBool,
}

/// The port the dashboard window is actually pointed at right now — set once
/// during `setup()` after port discovery (B1) resolves where podium-server
/// really ended up (it may not be `port()`'s target if that port was taken
/// and the server fell back). `reload_dashboard` and the WS watcher's
/// `/api/stats` poll both read this instead of re-deriving the target port,
/// so a Reload after a port-fallback still hits the right place.
struct ActivePort(AtomicU16);

/// Live active-agent count as last seen by the WS watcher, plus the tray's
/// status menu item so the background thread can update its label. Shared
/// with `ws_watcher` via `app.state()`.
pub struct TrayState {
    pub active_agents: AtomicUsize,
    pub status_item: Mutex<Option<MenuItem<tauri::Wry>>>,
}

/// An update the user hasn't decided on yet — stashed here between "the
/// background check found one" and "the updater window asks for it" /
/// "the user clicked Install Now". `update` is `None` in
/// `PODIUM_UPDATER_PREVIEW=1` mode, where there's no real
/// `tauri_plugin_updater::Update` to install (see `updater_install`).
struct PendingUpdate {
    version: String,
    notes_html: String,
    update: Option<Update>,
}

/// Shared home for the update the background check (or preview mode) has
/// stashed, read by the `updater_get_info`/`updater_install` commands.
struct PendingUpdateState(Mutex<Option<PendingUpdate>>);

/// Renders release-notes markdown (the updater manifest's `notes` field) to
/// HTML for display in the custom updater window. Uses pulldown-cmark's
/// default (CommonMark-ish) options — no raw-HTML passthrough beyond what
/// the parser itself escapes, since these notes are our own trusted release
/// text, not arbitrary user input.
fn render_markdown_to_html(md: &str) -> String {
    use pulldown_cmark::{html, Options, Parser};
    let options = Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES;
    let parser = Parser::new_ext(md, options);
    let mut html_out = String::new();
    html::push_html(&mut html_out, parser);
    html_out
}

/// Builds the custom "updater" window that replaces the old native dialog —
/// same external-link guards as `create_main_window` (`is_internal_url` /
/// `open_externally`), just pointed at the bundled `updater.html` asset
/// instead of `index.html`.
fn create_updater_window(app: &tauri::AppHandle) -> tauri::Result<tauri::WebviewWindow> {
    if let Some(existing) = app.get_webview_window("updater") {
        let _ = existing.show();
        let _ = existing.set_focus();
        return Ok(existing);
    }
    let nav_handle = app.clone();
    let new_window_handle = app.clone();
    WebviewWindowBuilder::new(app, "updater", WebviewUrl::App("updater.html".into()))
        .title("Podium Update")
        .inner_size(520.0, 640.0)
        .min_inner_size(460.0, 520.0)
        .resizable(true)
        .center()
        // A just-published update prompt must land in front, not behind the
        // dashboard window — otherwise the user never sees it.
        .always_on_top(true)
        .focused(true)
        .on_navigation(move |url| {
            if is_internal_url(url) {
                true
            } else {
                open_externally(&nav_handle, url);
                false
            }
        })
        .on_new_window(move |url, _features: NewWindowFeatures| {
            if is_internal_url(&url) {
                NewWindowResponse::Allow
            } else {
                open_externally(&new_window_handle, &url);
                NewWindowResponse::Deny
            }
        })
        .build()
}

/// The dashboard's light/dark choice lives in its own (remote loopback)
/// origin's localStorage, which the separate `tauri://` updater window can't
/// read, and Tauri commands can't be invoked cross-origin from that remote
/// page either (confirmed dead end — see git history for the abandoned
/// `report_ui_theme` approach). Instead the dashboard PUTs its theme to the
/// sidecar server (`ThemeToggle.tsx`), and this fetches it back over
/// loopback HTTP — no CORS involved since this is a plain Rust HTTP call,
/// not a browser fetch. Any failure (server not up yet, timeout, bad JSON)
/// falls back to `"light"`, matching the app's own default.
fn fetch_ui_prefs(port: u16) -> (String, serde_json::Map<String, serde_json::Value>) {
    let url = format!("http://127.0.0.1:{port}/api/settings/ui-theme");
    let fallback = || (String::from("light"), serde_json::Map::new());
    let Ok(resp) = ureq::get(&url).timeout(Duration::from_millis(500)).call() else {
        return fallback();
    };
    if resp.status() != 200 {
        return fallback();
    }
    let Ok(body) = resp.into_json::<serde_json::Value>() else {
        return fallback();
    };
    let theme = match body.get("theme").and_then(|v| v.as_str()) {
        Some("dark") => "dark".to_string(),
        _ => "light".to_string(),
    };
    let tokens = match body.get("tokens").and_then(|v| v.as_object()) {
        Some(map) => map.clone(),
        None => serde_json::Map::new(),
    };
    (theme, tokens)
}

/// `invoke('updater_get_info')` — returns `{version, notes_html, theme, tokens}`
/// for whatever update is currently stashed (real or preview). Empty/`None`
/// stash returns a benign placeholder rather than erroring, since the
/// window could in principle be reopened after a dismiss race. Theme +
/// tokens are re-fetched from the server on every call (not cached) so a
/// toggle or accent-preset change made while the updater window is open is
/// picked up by its poll (updater.html).
#[tauri::command]
fn updater_get_info(
    state: tauri::State<PendingUpdateState>,
    app: tauri::AppHandle,
) -> serde_json::Value {
    // PREVIEW override (see PODIUM_UPDATER_PREVIEW_THEME docs at its
    // declaration): only honored alongside PODIUM_UPDATER_PREVIEW=1, so it
    // can never affect a production build. Preview mode leaves tokens empty —
    // the window falls back to its own built-in light/dark defaults.
    let (theme, tokens) = if std::env::var("PODIUM_UPDATER_PREVIEW").as_deref() == Ok("1") {
        match std::env::var("PODIUM_UPDATER_PREVIEW_THEME").as_deref() {
            Ok("dark") => ("dark".to_string(), serde_json::Map::new()),
            Ok("light") => ("light".to_string(), serde_json::Map::new()),
            _ => fetch_ui_prefs(active_port(&app)),
        }
    } else {
        fetch_ui_prefs(active_port(&app))
    };
    let guard = state.0.lock().unwrap();
    match guard.as_ref() {
        Some(pending) => serde_json::json!({
            "version": pending.version,
            "notes_html": pending.notes_html,
            "theme": theme,
            "tokens": tokens,
        }),
        None => serde_json::json!({
            "version": "",
            "notes_html": "<p>No update details available.</p>",
            "theme": theme,
            "tokens": tokens,
        }),
    }
}

/// `invoke('updater_install')` — takes the stashed `Update` out of state and
/// runs the real download+install, emitting cumulative `updater://progress`
/// events as chunks arrive, then restarting the app on success. In preview
/// mode (`pending.update` is `None`) there's nothing real to install, so it
/// instead emits a few synthetic progress ticks and logs what it would have
/// done — see the `PODIUM_UPDATER_PREVIEW` gate in `setup`.
#[tauri::command]
fn updater_install(app: tauri::AppHandle) {
    let state = app.state::<PendingUpdateState>();
    let pending = state.0.lock().unwrap().take();
    let Some(pending) = pending else {
        eprintln!("updater_install: no pending update in state");
        return;
    };

    match pending.update {
        Some(update) => {
            tauri::async_runtime::spawn(async move {
                let downloaded = std::sync::Arc::new(AtomicU64::new(0));
                let emit_handle = app.clone();
                let downloaded_for_progress = downloaded.clone();
                let result = update
                    .download_and_install(
                        move |chunk_len, total| {
                            let sum = downloaded_for_progress
                                .fetch_add(chunk_len as u64, Ordering::SeqCst)
                                + chunk_len as u64;
                            let _ = emit_handle.emit(
                                "updater://progress",
                                serde_json::json!({ "downloaded": sum, "total": total }),
                            );
                        },
                        || {},
                    )
                    .await;
                match result {
                    Ok(()) => {
                        app.restart();
                    }
                    Err(err) => {
                        eprintln!("updater: download_and_install failed: {err}");
                        let _ = app.emit(
                            "updater://error",
                            serde_json::json!({ "message": err.to_string() }),
                        );
                    }
                }
            });
        }
        None => {
            // Preview mode: no real Update object to install — fake a
            // download (on a plain OS thread, not the async runtime, so a
            // blocking sleep here can't stall anything else) so the
            // window's progress bar can be exercised end to end.
            std::thread::spawn(move || {
                for pct in [0u64, 25, 50, 75, 100] {
                    let _ = app.emit(
                        "updater://progress",
                        serde_json::json!({ "downloaded": pct, "total": 100u64 }),
                    );
                    std::thread::sleep(Duration::from_millis(300));
                }
                println!("preview: would restart now");
            });
        }
    }
}

/// `invoke('updater_dismiss')` — "Later": close the window, nothing else.
/// The pending update (if any) is left in state so a fresh check next
/// launch (or, in a future enhancement, a "check again" tray item) can
/// still find it; the background check itself only runs once per launch.
#[tauri::command]
fn updater_dismiss(app: tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("updater") {
        let _ = window.close();
    }
}

pub fn port() -> u16 {
    std::env::var("PODIUM_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_PORT)
}

/// Public wrapper so `ws_watcher` can resolve the same data dir for its
/// notification-settings file without duplicating the platform logic.
pub fn default_data_dir_for_watcher() -> std::path::PathBuf {
    default_data_dir()
}

/// The port podium-server is actually listening on right now (B1) — set
/// once during `setup()` after port discovery, read by `ws_watcher`'s
/// `/api/stats` poll and by `reload_dashboard`.
pub fn active_port(app: &tauri::AppHandle) -> u16 {
    app.state::<ActivePort>().0.load(Ordering::SeqCst)
}

/// Platform default data dir, mirroring PodiumPaths.swift exactly:
///   macOS:  ~/Library/Application Support/Podium
///   Linux:  $XDG_DATA_HOME/podium, else ~/.local/share/podium
fn default_data_dir() -> std::path::PathBuf {
    let home = std::env::var("HOME").map(std::path::PathBuf::from).unwrap_or_default();
    #[cfg(target_os = "macos")]
    {
        home.join("Library").join("Application Support").join("Podium")
    }
    #[cfg(not(target_os = "macos"))]
    {
        if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
            if !xdg.is_empty() {
                return std::path::PathBuf::from(xdg).join("podium");
            }
        }
        home.join(".local").join("share").join("podium")
    }
}

fn health_url(port: u16) -> String {
    format!("http://127.0.0.1:{port}/api/health")
}

/// B2: `GET /api/health` on *any* process that happens to be listening on
/// the port would previously pass this check just by answering 200 — main.rs
/// then treated that unrelated process as "our" server and skipped spawning
/// the real sidecar. `podium-server`'s handler
/// (`Sources/PodiumServer/PodiumServerApp.swift`) always replies
/// `{"status":"ok","timestamp":"<ISO8601>"}` — no generic HTTP server (or a
/// stray dev server squatting on the port) is going to coincidentally return
/// exactly that shape, so require both fields rather than just the status
/// code. If the Swift server later grows a real `service`/`version` marker,
/// prefer checking that instead.
fn is_healthy(port: u16) -> bool {
    let Ok(resp) = ureq::get(&health_url(port)).timeout(Duration::from_millis(500)).call() else {
        return false;
    };
    if resp.status() != 200 {
        return false;
    }
    let Ok(body) = resp.into_json::<serde_json::Value>() else {
        return false;
    };
    body.get("status").and_then(|v| v.as_str()) == Some("ok") && body.get("timestamp").is_some()
}

/// `~/.claude/.agent-dashboard.json` — the multi-server discovery file
/// `ServerInfoWriter.swift`/`HookPortDiscovery` maintain. Read here (B1) to
/// find which port a just-spawned sidecar actually bound, since
/// `PodiumServerLifecycle` falls back to `port+1..+20` if our requested port
/// was taken by something else.
fn server_info_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").map(std::path::PathBuf::from).unwrap_or_default();
    home.join(".claude").join(".agent-dashboard.json")
}

/// Looks up the port a specific pid registered in the server-info file.
/// Returns `None` if the file is missing, unparsable, or has no entry for
/// that pid yet (the file is written from `onListening`, strictly after the
/// process starts, so a few misses right after spawn are expected).
fn port_for_pid(pid: u32) -> Option<u16> {
    let data = std::fs::read_to_string(server_info_path()).ok()?;
    let json: serde_json::Value = serde_json::from_str(&data).ok()?;
    let servers = json.get("servers").and_then(|v| v.as_array())?;
    servers.iter().find_map(|entry| {
        let entry_pid = entry.get("pid").and_then(|v| v.as_u64())?;
        if entry_pid as u32 != pid {
            return None;
        }
        entry.get("port").and_then(|v| v.as_u64()).map(|p| p as u16)
    })
}

/// B1: resolve the port a just-spawned sidecar is actually listening on.
/// Primary source is the server-info file keyed by pid (exact — works even
/// if some *other* unrelated process is also listening on a nearby port).
/// Falls back to health-polling `target_port..target_port + 20` (the same
/// range `PodiumServerLifecycle` tries) in case the discovery file is
/// unwritable/unreadable in this environment. Returns `None` if neither
/// source resolves a healthy port before `HEALTH_TIMEOUT`.
fn discover_spawned_port(target_port: u16, pid: u32) -> Option<u16> {
    let deadline = std::time::Instant::now() + HEALTH_TIMEOUT;
    loop {
        if let Some(port) = port_for_pid(pid) {
            if is_healthy(port) {
                return Some(port);
            }
        }
        for candidate in target_port..=target_port.saturating_add(MAX_PORT_FALLBACK_ATTEMPTS) {
            if is_healthy(candidate) {
                return Some(candidate);
            }
        }
        if std::time::Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(HEALTH_POLL_INTERVAL);
    }
}

/// A minimal `data:` URL page shown when the sidecar never became healthy
/// (B1) — better than the window silently staying on the "Starting Podium…"
/// placeholder forever with no indication anything went wrong.
fn error_page_url() -> Url {
    let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Podium</title>\
        <style>html,body{margin:0;height:100%;background:#0b0b0e;color:#ddd;\
        font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;\
        align-items:center;justify-content:center;text-align:center;padding:0 24px}\
        p{max-width:420px;line-height:1.5}</style></head><body>\
        <p>Podium's server didn't start. Check the app logs, or quit and \
        relaunch. If the problem persists, another process may be holding \
        the port range Podium needs.</p></body></html>";
    Url::parse(&format!("data:text/html,{}", urlencoding_escape(html)))
        .expect("static error page URL must parse")
}

/// Tiny percent-encoder for the characters that are meaningful in URL syntax
/// itself and would otherwise corrupt the `data:` URL below (`#` starts a
/// fragment, `%` starts a percent-escape) — no need to pull in a crate for
/// two characters in a static, ASCII-only string.
fn urlencoding_escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'#' => out.push_str("%23"),
            b'%' => out.push_str("%25"),
            b'"' => out.push_str("%22"),
            _ => out.push(byte as char),
        }
    }
    out
}

/// A2: only the podium-server dashboard (loopback, any port) and Tauri's own
/// internal asset/frontendDist protocol (used for the brief "Starting
/// Podium…" placeholder and the `data:` error page) are allowed to load
/// in-window. Everything else — the sidebar's GitHub link, any other
/// `target="_blank"` anchor, a stray `https://` redirect — is external and
/// must be handed to the OS browser instead of silently no-op'ing (or
/// worse, navigating the app's own window away from the dashboard).
fn is_internal_url(url: &Url) -> bool {
    match url.scheme() {
        "http" => matches!(url.host_str(), Some("127.0.0.1") | Some("localhost")),
        "tauri" => true,       // macOS/Linux custom-protocol asset loader
        "data" => true,        // our inline error page
        _ => url.host_str() == Some("tauri.localhost"), // Windows asset loader
    }
}

/// Opens a URL in the user's default OS browser via the shell plugin, best
/// effort — a failure here just means the click did nothing, same as the
/// pre-fix behavior, rather than crashing the shell.
fn open_externally(app: &tauri::AppHandle, url: &Url) {
    if let Err(err) = app.opener().open_url(url.as_str(), None::<String>) {
        eprintln!("failed to open external URL {url} in browser: {err}");
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(SidecarState {
            child: Mutex::new(None),
            spawned_by_us: AtomicBool::new(false),
        })
        .manage(TrayState {
            active_agents: AtomicUsize::new(0),
            status_item: Mutex::new(None),
        })
        .manage(ActivePort(AtomicU16::new(DEFAULT_PORT)))
        .manage(PendingUpdateState(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            updater_get_info,
            updater_install,
            updater_dismiss
        ])
        .setup(|app| {
            // T2.3: fire-and-forget update check. Spawned first and fully
            // async so it can never delay or block the synchronous sidecar
            // health-poll below — a network hiccup or a missing/unreachable
            // latest.json must never keep the app from launching. Never
            // `.expect()`/`.unwrap()` here: any failure is logged to stderr
            // and swallowed, mirroring the "never blocks the caller"
            // philosophy the rest of this file already follows (e.g.
            // `open_externally`, `apply_vibrancy`).
            // PREVIEW MODE: PODIUM_UPDATER_PREVIEW=1 skips the real update
            // check entirely (there's rarely a newer release to find in
            // dev) and stashes a synthetic update + opens the window
            // immediately, so the custom window/changelog/progress-bar can
            // be exercised locally without a real GitHub release. Never
            // installs anything for real — see `updater_install`'s `None`
            // branch. PODIUM_UPDATER_PREVIEW_THEME=light|dark additionally
            // forces `updater_get_info`'s theme (instead of fetching it from
            // the server) so the window's dark rendering can be verified
            // without the full server+dashboard stack running — only
            // honored alongside PODIUM_UPDATER_PREVIEW=1 (see
            // `updater_get_info`).
            if std::env::var("PODIUM_UPDATER_PREVIEW").as_deref() == Ok("1") {
                let sample_notes = "## Podium 9.9.9\n\n\
                    This is a **preview** of the custom updater window, not a real release.\n\n\
                    - Rendered changelog instead of a plain native dialog\n\
                    - Live download progress bar\n\
                    - Still dark/gold, still uncluttered\n\n\
                    See the [release notes](https://example.com) for more.";
                let notes_html = render_markdown_to_html(sample_notes);
                *app.state::<PendingUpdateState>().0.lock().unwrap() = Some(PendingUpdate {
                    version: "9.9.9".to_string(),
                    notes_html,
                    update: None,
                });
                let preview_handle = app.handle().clone();
                if let Err(err) = create_updater_window(&preview_handle) {
                    eprintln!("updater: failed to create preview updater window: {err}");
                }
            } else {
                let updater_handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    let update = match updater_handle.updater() {
                        Ok(updater) => updater.check().await,
                        Err(err) => {
                            eprintln!("updater: failed to construct updater instance: {err}");
                            return;
                        }
                    };
                    match update {
                        Ok(Some(update)) => {
                            // Render the changelog (update.body, from the
                            // updater manifest's `notes` field) to HTML and
                            // show it in our custom updater window instead
                            // of a plain native dialog — the user decides
                            // whether to update now or be asked again next
                            // launch.
                            let version = update.version.clone();
                            let notes_html = render_markdown_to_html(
                                update
                                    .body
                                    .as_deref()
                                    .unwrap_or("A new version of Podium is available."),
                            );
                            *updater_handle.state::<PendingUpdateState>().0.lock().unwrap() =
                                Some(PendingUpdate {
                                    version,
                                    notes_html,
                                    update: Some(update),
                                });
                            if let Err(err) = create_updater_window(&updater_handle) {
                                eprintln!(
                                    "updater: failed to create updater window: {err}"
                                );
                            }
                        }
                        Ok(None) => {
                            // Already up to date — nothing to do.
                        }
                        Err(err) => {
                            eprintln!("updater: check failed (non-fatal): {err}");
                        }
                    }
                });
            }

            let target_port = port();
            app.state::<ActivePort>().0.store(target_port, Ordering::SeqCst);
            let handle = app.handle().clone();

            // Reuse an already-running server (e.g. the SwiftUI app's
            // EmbeddedServer, or a manually-started podium-server) instead
            // of spawning a second one on the same port. B2: `is_healthy`
            // requires the podium-server response shape, not just a 200, so
            // an unrelated process squatting on the port is correctly
            // treated as "taken" rather than reused.
            let mut spawned_pid: Option<u32> = None;
            if is_healthy(target_port) {
                println!("podium-server already running on port {target_port}; reusing it.");
            } else {
                let data_dir = default_data_dir();
                let mut args: Vec<String> = vec![
                    "--port".into(),
                    target_port.to_string(),
                    "--data-dir".into(),
                    data_dir.to_string_lossy().into_owned(),
                ];

                // podium-server's static-file resolver (StaticFileHandler.swift)
                // only knows the OLD SwiftUI .app layout
                // (Contents/Resources/WebClient/dist) or $PODIUM_WEB_DIST — a
                // Tauri .app bundle has neither, so point it explicitly at the
                // WebClient/dist copy staged into the bundle's resource dir by
                // prepare-sidecar.sh (tauri.conf.json bundle.resources
                // "web-dist/*" -> "web-dist/"). Falls back gracefully (server
                // just 404s on '/' but the API still works) if resolution
                // fails, rather than panicking.
                match handle.path().resource_dir() {
                    Ok(resource_dir) => {
                        let web_dist = resource_dir.join("web-dist");
                        if web_dist.is_dir() {
                            args.push("--web-dist".into());
                            args.push(web_dist.to_string_lossy().into_owned());
                        } else {
                            eprintln!(
                                "web-dist resource not found at {web_dist:?}; \
                                 dashboard UI will 404 (API still works). \
                                 Did prepare-sidecar.sh run before this build?"
                            );
                        }
                    }
                    Err(err) => {
                        eprintln!("failed to resolve resource dir (non-fatal): {err}");
                    }
                }

                let sidecar = handle
                    .shell()
                    .sidecar("podium-server")
                    .expect("failed to resolve podium-server sidecar")
                    .args(args);

                let (mut _rx, child) = sidecar.spawn().expect("failed to spawn podium-server sidecar");
                spawned_pid = Some(child.pid());

                let state = handle.state::<SidecarState>();
                *state.child.lock().unwrap() = Some(child);
                state.spawned_by_us.store(true, Ordering::SeqCst);
                println!(
                    "Spawned podium-server sidecar (pid {}) targeting port {target_port} (data dir: {data_dir:?}).",
                    spawned_pid.unwrap()
                );
            }

            // B1: don't just assume the sidecar bound `target_port` —
            // podium-server falls back to target_port+1..+20 if that port
            // was already taken by something else (PodiumServerLifecycle.swift).
            // For a reused server we already confirmed `target_port` itself
            // is healthy above, so there's nothing to discover. For a
            // freshly-spawned one, resolve its real port via the
            // server-info file (falling back to a health-poll sweep of the
            // same range the server itself tries).
            let resolved_port = if let Some(pid) = spawned_pid {
                discover_spawned_port(target_port, pid)
            } else {
                Some(target_port)
            };
            let healthy = resolved_port.is_some();
            let active_port = resolved_port.unwrap_or(target_port);
            app.state::<ActivePort>().0.store(active_port, Ordering::SeqCst);
            if healthy {
                if active_port != target_port {
                    println!(
                        "podium-server bound port {active_port} instead of {target_port} (fallback); \
                         pointing the window at the real port."
                    );
                }
            } else {
                eprintln!("podium-server did not become healthy within {HEALTH_TIMEOUT:?}");
            }

            // A2: build the window here (rather than declaratively via
            // tauri.conf.json, which can no longer attach hooks after the
            // fact) so `on_navigation`/`on_new_window` can gate every load —
            // only the loopback dashboard and Tauri's own asset protocol are
            // allowed in-window; everything else (the sidebar's GitHub link,
            // any other `target="_blank"` anchor) is handed to the OS
            // browser instead of silently no-op'ing.
            let window = create_main_window(&handle)?;

            // Native glass: blur the desktop wallpaper behind the window
            // via NSVisualEffectView, matching the old SwiftUI app's
            // `.hudWindow` / `.behindWindow` combo (Sources/PodiumApp/
            // VisualEffect.swift). The webview itself is made transparent
            // via `.transparent(true)` on the window builder, so the web
            // dashboard's own CSS glass (backdrop-filter) composites on top
            // of this rather than an opaque white/black backing.
            #[cfg(target_os = "macos")]
            {
                use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial};
                if let Err(err) =
                    apply_vibrancy(&window, NSVisualEffectMaterial::HudWindow, None, None)
                {
                    eprintln!("failed to apply macOS vibrancy (non-fatal): {err}");
                }
            }

            // B1: navigate to wherever the server actually ended up, or to
            // an inline error page if it never became healthy at all —
            // rather than leaving the "Starting Podium…" placeholder up
            // forever with no indication anything went wrong.
            let target_url = if healthy {
                format!("http://127.0.0.1:{active_port}").parse().expect("invalid URL")
            } else {
                error_page_url()
            };
            window
                .navigate(target_url)
                .expect("failed to navigate main window");

            // --- T1.4: tray icon + menu ---------------------------------
            // Initial status reflects the health check we just did, so the
            // menu never shows a stale "starting…" once the server is up —
            // the ws_watcher then keeps it live ("N active" / "running") as
            // sessions come and go.
            let initial_status = if healthy { "Server: running" } else { "Server: starting…" };
            let open_item = MenuItem::with_id(app, "open", "Open Podium", true, None::<&str>)?;
            let status_item = MenuItem::with_id(app, "status", initial_status, false, None::<&str>)?;
            let reload_item =
                MenuItem::with_id(app, "reload", "Reload Dashboard", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let separator = PredefinedMenuItem::separator(app)?;
            let menu = Menu::with_items(
                app,
                &[&open_item, &status_item, &reload_item, &separator, &quit_item],
            )?;

            *handle.state::<TrayState>().status_item.lock().unwrap() = Some(status_item);

            let _tray = TrayIconBuilder::with_id("main-tray")
                .menu(&menu)
                .tooltip("Podium")
                .icon(app.default_window_icon().cloned().expect("no default window icon"))
                .on_menu_event(move |app, event| match event.id.as_ref() {
                    "open" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.unminimize();
                            let _ = window.set_focus();
                        }
                    }
                    "reload" => reload_dashboard(app),
                    "quit" => {
                        kill_sidecar_if_ours(app);
                        app.exit(0);
                    }
                    _ => {}
                })
                .build(app)?;

            // --- T1.4: background WS watcher for live count + notifications
            let watcher_handle = app.handle().clone();
            std::thread::spawn(move || {
                ws_watcher::run(watcher_handle, active_port);
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            // Close-to-tray: hitting the window's close button HIDES the
            // window and leaves the sidecar server RUNNING, so Podium keeps
            // ingesting Claude Code hook events in the background (that's the
            // whole point of a session observer — it has to be listening even
            // when you're not looking at it). The server is only torn down on
            // an explicit Quit (tray menu → RunEvent::Exit below). Reopen the
            // window from the tray's "Open Podium" item.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building the Tauri application")
        .run(|app_handle, event| {
            // Belt-and-suspenders: also clean up on the generic exit event,
            // in case the process quits via a path that skips
            // CloseRequested (e.g. Cmd+Q, SIGTERM).
            if let RunEvent::Exit = event {
                kill_sidecar_if_ours(app_handle);
            }
        });
}

/// Recovery for the "window goes dark" bug (user-reported: webview content
/// crashes/blanks, revealing the vibrancy background behind it, and the
/// window never repaints on its own). Re-navigates the main window's webview
/// to the dashboard URL natively (not a JS `eval`/`location.reload()`) so it
/// works even when the page's own JS is dead — `navigate()` drives WKWebView
/// from the Rust side, the same call used for the initial load in `setup`.
fn reload_dashboard(app: &tauri::AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    // B1: reload the port we actually resolved at startup (which may have
    // fallen back past `port()`'s target), not the target port itself.
    let active_port = app.state::<ActivePort>().0.load(Ordering::SeqCst);
    let url = format!("http://127.0.0.1:{active_port}");
    match url.parse() {
        Ok(url) => {
            if let Err(err) = window.navigate(url) {
                eprintln!("reload_dashboard: navigate failed: {err}");
            }
        }
        Err(err) => eprintln!("reload_dashboard: invalid URL: {err}"),
    }
}

/// A2: builds the "main" window in code (rather than declaratively via
/// `tauri.conf.json`, which offers no way to attach navigation hooks after
/// the window already exists) so we can gate every load through
/// `on_navigation`/`on_new_window`. Window chrome (size, transparency,
/// title-bar style) mirrors the config this replaces exactly.
fn create_main_window(app: &tauri::AppHandle) -> tauri::Result<tauri::WebviewWindow> {
    let nav_handle = app.clone();
    let new_window_handle = app.clone();

    let builder = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .title("Podium")
        .inner_size(1280.0, 800.0)
        .min_inner_size(900.0, 600.0)
        .transparent(true)
        .decorations(true);
    // Overlay title bar is a macOS-only WebviewWindowBuilder API (doesn't
    // exist on Linux/Windows builds of tauri — compile error, not a no-op).
    #[cfg(target_os = "macos")]
    let builder = builder
        .title_bar_style(tauri::TitleBarStyle::Overlay)
        .hidden_title(true);
    builder
        // Top-level navigations (location.href changes, plain <a> clicks
        // without target="_blank", redirects): allow the dashboard + our
        // own asset/error pages, hand everything else to the OS browser and
        // cancel the in-window navigation.
        .on_navigation(move |url| {
            if is_internal_url(url) {
                true
            } else {
                open_externally(&nav_handle, url);
                false
            }
        })
        // `target="_blank"` anchors and `window.open()` calls go through
        // this hook instead of `on_navigation` — the sidebar's GitHub link
        // is exactly this case.
        .on_new_window(move |url, _features: NewWindowFeatures| {
            if is_internal_url(&url) {
                NewWindowResponse::Allow
            } else {
                open_externally(&new_window_handle, &url);
                NewWindowResponse::Deny
            }
        })
        .build()
}

fn kill_sidecar_if_ours(app_handle: &tauri::AppHandle) {
    let state = app_handle.state::<SidecarState>();
    if !state.spawned_by_us.swap(false, Ordering::SeqCst) {
        return; // We reused an existing server — never kill it.
    }
    // Take the child out of the mutex into a local, releasing the guard
    // before calling kill() (avoids holding the MutexGuard across the call).
    let child = state.child.lock().unwrap().take();
    if let Some(child) = child {
        if let Err(err) = child.kill() {
            eprintln!("failed to kill podium-server sidecar: {err}");
        } else {
            println!("podium-server sidecar terminated.");
        }
    }
}
