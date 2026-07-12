/**
 * @file displaySettings.ts
 * @description Utility for managing dashboard display preferences (localStorage-backed)
 */

const ADVANCED_METRICS_KEY = "podium-advanced-metrics";

export function loadAdvancedMetrics(): boolean {
  try {
    const raw = localStorage.getItem(ADVANCED_METRICS_KEY);
    return raw ? JSON.parse(raw) : false;
  } catch {
    return false;
  }
}

export function saveAdvancedMetrics(enabled: boolean) {
  localStorage.setItem(ADVANCED_METRICS_KEY, JSON.stringify(enabled));
}
