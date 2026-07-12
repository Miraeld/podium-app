/**
 * @file platform.ts
 * @description Small helpers for detecting the runtime shell (Tauri desktop
 * app vs. a plain browser tab) so UI can adapt copy/behavior accordingly.
 * @author Gael Robin <robin.gael@gmail.com>
 */

/** True when running inside the Tauri desktop shell (macOS/Linux app window). */
export function isTauriApp(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/**
 * True when the web Notification API is unusable — either not present at
 * all, or present-but-nonfunctional inside Tauri's WKWebView (which never
 * resolves `requestPermission()` to "granted"). The Tauri shell delivers
 * native OS notifications itself, so the in-app browser-notification toggle
 * should not be shown in that case.
 */
export function browserNotificationsUnavailable(): boolean {
  if (typeof window === "undefined") return true;
  if (isTauriApp()) return true;
  return typeof Notification === "undefined";
}
