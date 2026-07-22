/**
 * @file ThemeToggle.tsx
 * @description Light/dark theme switch for the sidebar. Reads the persisted
 * preference from localStorage on mount (defaulting to light when unset),
 * toggles the `dark` class on <html>, and persists the choice under the
 * `podium-theme` key. Styled to match the sidebar's collapse toggle so it
 * reads as part of the same control cluster in both collapsed and expanded
 * states.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useCallback, useEffect, useState } from "react";
import { Sun, Moon } from "lucide-react";

const THEME_STORAGE_KEY = "podium-theme";

// Fixed list of computed CSS custom properties that already reflect BOTH the
// light/dark theme and the active accent preset (data-preset on <html>) —
// see client/src/index.css. Reported to the server so the Tauri updater
// window (a separate origin, can't read our localStorage/DOM) can mirror the
// current look without duplicating every preset's palette itself.
const REPORTED_TOKEN_NAMES = [
  "--accent",
  "--accent-hover",
  "--surface-0",
  "--surface-1",
  "--surface-2",
  "--surface-3",
  "--text-primary",
  "--text-muted",
  "--border",
  "--glass-card",
  "--glass-border",
] as const;

function readInitialDark(): boolean {
  try {
    return localStorage.getItem(THEME_STORAGE_KEY) === "dark";
  } catch {
    return false;
  }
}

function readComputedTokens(): Record<string, string> {
  const styles = getComputedStyle(document.documentElement);
  const tokens: Record<string, string> = {};
  for (const name of REPORTED_TOKEN_NAMES) {
    tokens[name] = styles.getPropertyValue(name).trim();
  }
  return tokens;
}

// Mirrors the theme + computed tokens to the server so the Tauri shell's
// custom updater window (a separate `tauri://` origin that can't read this
// page's localStorage or invoke app commands cross-origin) can match it —
// see server/routes/settings.js's GET/PUT /api/settings/ui-theme. Best-effort:
// a failed write must never break the toggle itself.
function reportThemeToServer(isDark: boolean) {
  fetch("/api/settings/ui-theme", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ theme: isDark ? "dark" : "light", tokens: readComputedTokens() }),
  }).catch(() => {});
}

interface ThemeToggleProps {
  /** When true, render icon-only (sidebar collapsed). */
  collapsed: boolean;
}

export function ThemeToggle({ collapsed }: ThemeToggleProps) {
  // The anti-flicker script in index.html has already applied the class before
  // React mounts; sync our state from the DOM/localStorage so the icon matches.
  const [isDark, setIsDark] = useState<boolean>(() => readInitialDark());

  // Keep the <html> class authoritative on mount in case the inline script
  // didn't run (e.g. SSR/dev edge cases).
  useEffect(() => {
    const root = document.documentElement;
    if (isDark) root.classList.add("dark");
    else root.classList.remove("dark");
    reportThemeToServer(isDark);
  }, [isDark]);

  // Also re-report whenever <html>'s class or data-preset attribute changes
  // for any other reason (e.g. an accent-preset picker elsewhere in the app),
  // so the updater window's computed tokens never go stale. The `isDark`
  // effect above already covers this component's own toggles; this observer
  // is the fallback for everything else that touches those attributes.
  useEffect(() => {
    const root = document.documentElement;
    const observer = new MutationObserver(() => {
      reportThemeToServer(root.classList.contains("dark"));
    });
    observer.observe(root, { attributes: true, attributeFilter: ["class", "data-preset"] });
    return () => observer.disconnect();
  }, []);

  const toggle = useCallback(() => {
    setIsDark((prev) => {
      const next = !prev;
      try {
        localStorage.setItem(THEME_STORAGE_KEY, next ? "dark" : "light");
      } catch {
        /* ignore disabled storage */
      }
      return next;
    });
  }, []);

  const label = isDark ? "Switch to light theme" : "Switch to dark theme";

  return (
    <button
      onClick={toggle}
      className={`w-full h-10 rounded-lg bg-white/[0.04] border border-white/[0.06] transition-colors duration-150 text-gray-600 hover:text-accent dark:text-gray-300 dark:hover:text-accent hover:border-accent/30 ${
        collapsed
          ? "flex items-center justify-center"
          : "flex items-center gap-2.5 px-3"
      }`}
      title={label}
      aria-label={label}
    >
      {isDark ? (
        <Sun className="w-4 h-4 flex-shrink-0" />
      ) : (
        <Moon className="w-4 h-4 flex-shrink-0" />
      )}
      {!collapsed && (
        <span className="text-[11px] font-semibold uppercase tracking-wide">Theme</span>
      )}
    </button>
  );
}
