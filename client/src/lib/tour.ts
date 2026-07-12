/**
 * @file tour.ts
 * @description Shared state for the first-run onboarding tour: localStorage
 * "seen" gating (same pattern as the dashboard's notification banner /
 * kanban-visibility flags) plus a tiny window-event bridge so any component
 * (Settings, a future Help menu) can trigger a re-run without prop drilling
 * the driver.js instance through the tree.
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
