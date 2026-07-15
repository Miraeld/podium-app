/**
 * @file tour.ts
 * @description Shared state for the app's onboarding tours: localStorage
 * "seen" gating (same pattern as the dashboard's notification banner /
 * kanban-visibility flags) plus a tiny window-event bridge so any component
 * (Settings, a future Help menu) can trigger a re-run without prop drilling
 * the driver.js instance through the tree.
 *
 * Two independent tours share this module: the nav tour (main sidebar,
 * OnboardingTour.tsx) and the session-detail tour (SessionOnboardingTour.tsx).
 * Each has its own seen-key and start-event so replaying one never affects
 * the other's first-run state.
 * @author Gael Robin <robin.gael@gmail.com>
 */

export const TOUR_SEEN_KEY = "podium-tour-seen";
export const TOUR_START_EVENT = "podium-tour-start";

export function hasSeenTour(): boolean {
  try {
    return localStorage.getItem(TOUR_SEEN_KEY) === "1";
  } catch {
    // localStorage unavailable (private mode, etc.) — treat as unseen so the
    // tour can still run once per session rather than crashing.
    return false;
  }
}

export function markTourSeen(): void {
  try {
    localStorage.setItem(TOUR_SEEN_KEY, "1");
  } catch {
    // ignore — nothing to persist to, tour will just show again next visit
  }
}

/** Fired by Settings (or any future Help entry point) to request a re-run. */
export function requestTourStart(): void {
  window.dispatchEvent(new CustomEvent(TOUR_START_EVENT));
}

// ── Session detail tour ─────────────────────────────────────────────────────
// Same "seen once, replayable anytime" pattern as the nav tour above, kept as
// a distinct key/event pair so the two tours' first-run state never collide
// (e.g. a user who dismissed the nav tour months ago should still get the
// session tour the first time they open a session detail page).

export const SESSION_TOUR_SEEN_KEY = "podium-session-tour-seen";
export const SESSION_TOUR_START_EVENT = "podium-session-tour-start";

export function hasSeenSessionTour(): boolean {
  try {
    return localStorage.getItem(SESSION_TOUR_SEEN_KEY) === "1";
  } catch {
    return false;
  }
}

export function markSessionTourSeen(): void {
  try {
    localStorage.setItem(SESSION_TOUR_SEEN_KEY, "1");
  } catch {
    // ignore — nothing to persist to, tour will just show again next visit
  }
}

/** Fired by the SessionDetail "?" help button to request a re-run. */
export function requestSessionTourStart(): void {
  window.dispatchEvent(new CustomEvent(SESSION_TOUR_START_EVENT));
}
