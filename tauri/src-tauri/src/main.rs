// Podium Tauri shell — minimal Rust glue.
//
// Responsibilities (see tauri/README.md + repo ROADMAP.md T1.1):
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
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use tauri::{Manager, RunEvent, WindowEvent};
use tauri_plugin_shell::process::CommandChild;
use tauri_plugin_shell::ShellExt;

const DEFAULT_PORT: u16 = 4820;
const HEALTH_TIMEOUT: Duration = Duration::from_secs(15);
const HEALTH_POLL_INTERVAL: Duration = Duration::from_millis(300);

/// Holds the sidecar's child handle IFF this app instance spawned it. `None`
/// means either "not started yet" or "we reused a server someone else is
/// running" — in both cases there is nothing for us to kill on exit.
struct SidecarState {
    child: Mutex<Option<CommandChild>>,
    spawned_by_us: AtomicBool,
}

fn port() -> u16 {
    std::env::var("PODIUM_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_PORT)
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

fn is_healthy(port: u16) -> bool {
    ureq::get(&health_url(port))
        .timeout(Duration::from_millis(500))
        .call()
        .map(|resp| resp.status() == 200)
        .unwrap_or(false)
}

/// Blocks until /api/health returns 200 or the timeout elapses.
fn wait_for_health(port: u16) -> bool {
    let deadline = std::time::Instant::now() + HEALTH_TIMEOUT;
    while std::time::Instant::now() < deadline {
        if is_healthy(port) {
            return true;
        }
        std::thread::sleep(HEALTH_POLL_INTERVAL);
    }
    is_healthy(port)
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(SidecarState {
            child: Mutex::new(None),
            spawned_by_us: AtomicBool::new(false),
        })
        .setup(|app| {
            let port = port();
            let handle = app.handle().clone();

            // Reuse an already-running server (e.g. the SwiftUI app's
            // EmbeddedServer, or a manually-started podium-server) instead
            // of spawning a second one on the same port.
            if is_healthy(port) {
                println!("podium-server already running on port {port}; reusing it.");
            } else {
                let data_dir = default_data_dir();
                let mut args: Vec<String> = vec![
                    "--port".into(),
                    port.to_string(),
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

                let state = handle.state::<SidecarState>();
                *state.child.lock().unwrap() = Some(child);
                state.spawned_by_us.store(true, Ordering::SeqCst);
                println!("Spawned podium-server sidecar on port {port} (data dir: {data_dir:?}).");
            }

            // Wait for health (blocking the setup hook is fine here — this
            // runs once, before any window is shown to the user).
            if !wait_for_health(port) {
                eprintln!("podium-server did not become healthy within {HEALTH_TIMEOUT:?}");
            }

            if let Some(window) = app.get_webview_window("main") {
                // Native glass: blur the desktop wallpaper behind the window
                // via NSVisualEffectView, matching the old SwiftUI app's
                // `.hudWindow` / `.behindWindow` combo (Sources/PodiumApp/
                // VisualEffect.swift). The webview itself is made transparent
                // via tauri.conf.json's window `transparent: true`, so the
                // web dashboard's own CSS glass (backdrop-filter) composites
                // on top of this rather than an opaque white/black backing.
                #[cfg(target_os = "macos")]
                {
                    use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial};
                    if let Err(err) =
                        apply_vibrancy(&window, NSVisualEffectMaterial::HudWindow, None, None)
                    {
                        eprintln!("failed to apply macOS vibrancy (non-fatal): {err}");
                    }
                }

                let url = format!("http://127.0.0.1:{port}").parse().expect("invalid URL");
                window
                    .navigate(url)
                    .expect("failed to navigate main window to podium-server");
            }

            Ok(())
        })
        .on_window_event(|window, event| {
            // Kill the sidecar (if we spawned it) when the last window
            // closes, so no orphaned podium-server process survives the app.
            if let WindowEvent::CloseRequested { .. } = event {
                kill_sidecar_if_ours(window.app_handle());
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
