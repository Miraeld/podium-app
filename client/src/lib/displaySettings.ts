/**
 * @file displaySettings.ts
 * @description Utility for managing dashboard display preferences (localStorage-backed)
 */

const ADVANCED_METRICS_KEY = "podium-advanced-metrics";
const PRESET_KEY = "podium-preset";

export type ThemePreset = "gold" | "sage";

const VALID_PRESETS: ThemePreset[] = ["gold", "sage"];

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

/** Loads the persisted theme preset, defaulting to "gold" when unset or invalid. */
export function loadPreset(): ThemePreset {
  try {
    const raw = localStorage.getItem(PRESET_KEY);
    return raw && (VALID_PRESETS as string[]).includes(raw) ? (raw as ThemePreset) : "gold";
  } catch {
    return "gold";
  }
}

/**
 * Persists the theme preset and applies it to <html> via `data-preset`
 * immediately (mirrors the anti-flicker script in index.html, which applies
 * the same attribute before React mounts on subsequent loads). "gold" is the
 * default and clears the attribute rather than setting `data-preset="gold"`.
 */
export function savePreset(preset: ThemePreset) {
  try {
    localStorage.setItem(PRESET_KEY, preset);
  } catch {
    /* ignore disabled storage */
  }
  const root = document.documentElement;
  if (preset === "gold") root.removeAttribute("data-preset");
  else root.setAttribute("data-preset", preset);
}
