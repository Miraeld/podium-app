/**
 * @file Update notifier — "New update available" popup.
 *
 * Consumes GET /api/updates/status (RepoUpdatesStatusResponse — see
 * lib/types.ts and Sources/PodiumCore/Discovery/UpdateCheck.swift). Checks
 * once per app launch; if an update is available for this app's own repo
 * and the version hasn't been dismissed, shows a bottom-right toast with the
 * release notes.
 *
 * Semantics (mirrors the retired native UpdatesView.swift):
 *  - Dismiss suppresses that specific version via localStorage — it won't
 *    reappear until a newer version ships.
 *  - Update opens the GitHub release page in a new tab WITHOUT suppressing,
 *    so the popup reappears next launch if the user didn't actually update.
 *
 * This is notify + changelog + "open release page" only — no auto-download.
 * In-app self-update (Tauri's built-in updater) is a separate, later task.
 *
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { Sparkles, X, ExternalLink } from "lucide-react";
import { api } from "../lib/api";
import { renderChangelog } from "../lib/changelog";
import type { RepoUpdateStatus } from "../lib/types";

const DISMISSED_KEY = "podium-update-dismissed-version";

function loadDismissedVersion(): string | null {
  try {
    return localStorage.getItem(DISMISSED_KEY);
  } catch {
    return null;
  }
}

function saveDismissedVersion(version: string) {
  try {
    localStorage.setItem(DISMISSED_KEY, version);
  } catch {}
}

/** Picks the update to surface: this app's own repo release, if any. */
function pickRelevantUpdate(app: RepoUpdateStatus): RepoUpdateStatus | null {
  if (app.update_available) return app;
  return null;
}

export function UpdateNotifier() {
  const { t } = useTranslation("updates");
  const [pending, setPending] = useState<RepoUpdateStatus | null>(null);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    let cancelled = false;
    api.updates
      .status()
      .then((res) => {
        if (cancelled) return;
        const relevant = pickRelevantUpdate(res.app);
        if (!relevant || !relevant.latest_version) return;
        if (loadDismissedVersion() === relevant.latest_version) return;
        setPending(relevant);
        setVisible(true);
      })
      .catch(() => {
        // Never blocks the app on a failed update check.
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (!pending || !visible) return null;

  const handleDismiss = () => {
    if (pending.latest_version) saveDismissedVersion(pending.latest_version);
    setVisible(false);
  };

  const handleUpdate = () => {
    if (pending.release_url) {
      window.open(pending.release_url, "_blank", "noopener,noreferrer");
    }
    // Intentionally does NOT call saveDismissedVersion — re-prompts next
    // launch if the user didn't actually install the update.
    setVisible(false);
  };

  return (
    <div
      role="dialog"
      aria-modal="false"
      aria-labelledby="update-notifier-title"
      className="fixed bottom-5 right-5 z-[90] w-full max-w-sm animate-slide-up"
    >
      <div className="card shadow-2xl border border-accent/20 overflow-hidden flex flex-col max-h-[70vh]">
        <div className="flex items-start justify-between gap-3 px-4 py-3 border-b border-border bg-accent/[0.06]">
          <div className="flex items-center gap-2.5 min-w-0">
            <div className="w-8 h-8 rounded-lg bg-accent/15 flex items-center justify-center flex-shrink-0">
              <Sparkles className="w-4 h-4 text-accent" />
            </div>
            <div className="min-w-0">
              <h2
                id="update-notifier-title"
                className="text-sm font-semibold text-gray-900 dark:text-gray-100 truncate"
              >
                {t("popup.title")}
              </h2>
              <p className="text-xs text-gray-600 dark:text-gray-400 truncate">
                {t("popup.lead", { version: pending.latest_version })}
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={handleDismiss}
            aria-label={t("popup.dismiss")}
            className="p-1 -m-1 rounded-md text-gray-600 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-200 hover:bg-surface-4 transition-colors flex-shrink-0"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        <div className="px-4 py-3 overflow-y-auto">
          {pending.release_notes ? (
            renderChangelog(pending.release_notes)
          ) : (
            <p className="text-sm text-gray-600 dark:text-gray-400">{t("popup.noNotes")}</p>
          )}
        </div>

        <div className="flex items-center justify-end gap-2 px-4 py-3 border-t border-border">
          <button type="button" onClick={handleDismiss} className="btn-ghost text-xs">
            {t("popup.dismiss")}
          </button>
          <button type="button" onClick={handleUpdate} className="btn-primary text-xs">
            <ExternalLink className="w-3.5 h-3.5" />
            {t("popup.update")}
          </button>
        </div>
      </div>
    </div>
  );
}
