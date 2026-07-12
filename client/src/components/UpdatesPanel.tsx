/**
 * @file Updates panel — always-accessible Settings section showing current
 * version, latest release, and changelog for this app's own repo, with a
 * manual "check now" that re-hits GET /api/updates/status (and broadcasts
 * over the WS hub via POST /api/updates/check).
 *
 * Reuses the same data source as UpdateNotifier — this panel is the
 * "look it up whenever you want" counterpart to that launch-time popup, not
 * a separate feature. Update opens the GitHub release page; no auto-install.
 *
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { RefreshCw, ExternalLink, CheckCircle2, Sparkles } from "lucide-react";
import { api } from "../lib/api";
import { renderChangelog } from "../lib/changelog";
import { getCurrentLocale } from "../lib/format";
import type { RepoUpdatesStatusResponse } from "../lib/types";

function formatTimestamp(iso: string, locale: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString(locale, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function UpdatesPanel() {
  const { t } = useTranslation("updates");
  const [status, setStatus] = useState<RepoUpdatesStatusResponse | null>(null);
  const [checking, setChecking] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const res = await api.updates.status();
      setStatus(res);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : t("panel.checkError"));
    }
  }, [t]);

  useEffect(() => {
    load();
  }, [load]);

  const checkNow = async () => {
    setChecking(true);
    setError(null);
    try {
      const res = await api.updates.check();
      setStatus(res);
    } catch (err) {
      setError(err instanceof Error ? err.message : t("panel.checkError"));
    } finally {
      setChecking(false);
    }
  };

  const app = status?.app;
  const updateAvailable = app?.update_available ?? false;

  return (
    <section>
      <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100 flex items-center gap-2 mb-1 border-l-2 border-amber-400/60 dark:border-accent/60 pl-2.5">
        <Sparkles className="w-4 h-4 text-gray-700 dark:text-gray-500" />
        {t("panel.title")}
      </h3>
      <p className="text-sm text-gray-600 dark:text-gray-500 mb-4">{t("panel.description")}</p>

      <div className="card p-5 space-y-4">
        <div className="flex items-center justify-between flex-wrap gap-3">
          <div className="flex items-center gap-6">
            <div>
              <p className="text-[11px] text-gray-700 dark:text-gray-500 uppercase tracking-wider">
                {t("panel.current")}
              </p>
              <p className="text-sm font-mono font-semibold text-gray-800 dark:text-gray-100">
                {app?.current_version ?? "—"}
              </p>
            </div>
            <div>
              <p className="text-[11px] text-gray-700 dark:text-gray-500 uppercase tracking-wider">
                {t("panel.latest")}
              </p>
              <p className="text-sm font-mono font-semibold text-gray-800 dark:text-gray-100">
                {app?.latest_version ?? "—"}
              </p>
            </div>
            {updateAvailable ? (
              <span className="inline-flex items-center gap-1.5 text-xs font-medium text-amber-700 dark:text-amber-400 bg-amber-50 dark:bg-amber-500/10 border border-amber-200 dark:border-amber-500/20 px-2.5 py-1 rounded-full">
                <Sparkles className="w-3.5 h-3.5" /> {t("panel.available")}
              </span>
            ) : (
              status?.app.checked && (
                <span className="inline-flex items-center gap-1.5 text-xs font-medium text-emerald-700 dark:text-emerald-400 bg-emerald-50 dark:bg-emerald-500/10 border border-emerald-200 dark:border-emerald-500/20 px-2.5 py-1 rounded-full">
                  <CheckCircle2 className="w-3.5 h-3.5" /> {t("panel.upToDate")}
                </span>
              )
            )}
          </div>

          <div className="flex items-center gap-2">
            {updateAvailable && app?.release_url && (
              <a
                href={app.release_url}
                target="_blank"
                rel="noreferrer noopener"
                className="btn-primary text-xs"
              >
                <ExternalLink className="w-3.5 h-3.5" />
                {t("panel.viewRelease")}
              </a>
            )}
            <button onClick={checkNow} disabled={checking} className="btn-ghost text-xs disabled:opacity-50">
              <RefreshCw className={`w-3.5 h-3.5 ${checking ? "animate-spin" : ""}`} />
              {checking ? t("panel.checking") : t("panel.checkNow")}
            </button>
          </div>
        </div>

        {error && (
          <div className="px-3 py-2 rounded-lg text-xs bg-red-50 dark:bg-red-500/10 border border-red-200 dark:border-red-500/20 text-red-700 dark:text-red-400">
            {error}
          </div>
        )}

        {app?.release_notes ? (
          <div className="pt-3 border-t border-border">{renderChangelog(app.release_notes)}</div>
        ) : (
          status?.app.checked && (
            <p className="text-sm text-gray-600 dark:text-gray-500 pt-3 border-t border-border">
              {t("panel.noNotes")}
            </p>
          )
        )}

        {status?.checked_at && (
          <p className="text-[11px] text-gray-600 dark:text-gray-500">
            {t("panel.lastChecked", { time: formatTimestamp(status.checked_at, getCurrentLocale()) })}
          </p>
        )}
      </div>
    </section>
  );
}
