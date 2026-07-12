/**
 * @file OnboardingTour.tsx
 * @description First-run guided tour over the main navigation, built on
 * driver.js. Chosen over shepherd.js because the tour here is a short,
 * linear spotlight sequence with no branching or multi-target steps —
 * driver.js's minimal footprint (~5kb) and built-in element-highlighting
 * cover that exactly, without shepherd's heavier step-modal machinery we
 * wouldn't use.
 *
 * Mounted once near the app root (see Dashboard.tsx). Auto-runs on first
 * visit (gated via `hasSeenTour()` / `markTourSeen()` in lib/tour.ts — same
 * "seen" localStorage pattern as the notification banner and kanban-visible
 * flag elsewhere in this app) and can be re-triggered from Settings via the
 * `podium-tour-start` window event (`requestTourStart()`).
 *
 * Each step spotlights a sidebar nav item (`[data-tour="nav-<key>"]`,
 * applied in Sidebar.tsx) with one concrete "try this" action. Steps only
 * include nav items that are actually visible (e.g. "Run Claude" is gated
 * behind the advancedMetrics flag, same as the sidebar itself).
 *
 * NOTE: when Recommendations ships as a real nav section, add a step here
 * targeting `[data-tour="nav-recommendations"]` (and add the matching
 * `data-tour` attribute in Sidebar.tsx) — skipped for now per T2.2 scope
 * since the feature doesn't exist yet.
 *
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useEffect } from "react";
import { useTranslation } from "react-i18next";
import { driver, type DriveStep } from "driver.js";
import "driver.js/dist/driver.css";
import "./OnboardingTour.css";
import { hasSeenTour, markTourSeen, TOUR_START_EVENT } from "../lib/tour";
import { loadAdvancedMetrics } from "../lib/displaySettings";

interface OnboardingTourProps {
  /** Whether the "Run Claude" nav item is currently visible in the sidebar. */
  runVisible?: boolean;
}

export function OnboardingTour({ runVisible }: OnboardingTourProps = {}) {
  const { t } = useTranslation("tour");

  useEffect(() => {
    const showRun = runVisible ?? loadAdvancedMetrics();

    const steps: DriveStep[] = [
      {
        element: '[data-tour="nav-sessions"]',
        popover: {
          title: t("steps.sessions.title"),
          description: t("steps.sessions.description"),
          side: "right",
          align: "start",
        },
      },
      {
        element: '[data-tour="nav-workflows"]',
        popover: {
          title: t("steps.workflows.title"),
          description: t("steps.workflows.description"),
          side: "right",
          align: "start",
        },
      },
      ...(showRun
        ? ([
            {
              element: '[data-tour="nav-run"]',
              popover: {
                title: t("steps.run.title"),
                description: t("steps.run.description"),
                side: "right",
                align: "start",
              },
            },
          ] as DriveStep[])
        : []),
      {
        element: '[data-tour="nav-cc-config"]',
        popover: {
          title: t("steps.ccConfig.title"),
          description: t("steps.ccConfig.description"),
          side: "right",
          align: "start",
        },
      },
      {
        element: '[data-tour="nav-settings"]',
        popover: {
          title: t("steps.settings.title"),
          description: t("steps.settings.description"),
          side: "right",
          align: "start",
        },
      },
    ];

    const tourDriver = driver({
      showProgress: true,
      // driver.js substitutes its own {{current}}/{{total}} tokens into the
      // string it's given — feed those same token names back as the
      // i18next interpolation values so the translated template resolves to
      // the literal tokens driver.js expects, in the right word order per
      // locale (e.g. "{{current}} / {{total}}" for zh/vi vs "... of ..." en).
      progressText: t("controls.progress", { current: "{{current}}", total: "{{total}}" }),
      nextBtnText: t("controls.next"),
      prevBtnText: t("controls.previous"),
      doneBtnText: t("controls.done"),
      allowClose: true,
      overlayOpacity: 0.65,
      popoverClass: "podium-tour-popover",
      steps,
      // NOTE: deliberately NOT marking "seen" in onDestroyed. onDestroyed
      // fires on ANY teardown, including this effect's cleanup destroy() —
      // which runs whenever `t`'s identity changes (react-i18next swaps it
      // once the "tour" namespace loads, right after mount). Marking there
      // set "seen" before the tour ever showed. "Seen" is instead set the
      // moment an auto-run actually launches (see startAuto), so it shows
      // exactly once ever, regardless of whether the user finishes it.
    });

    // Auto-run launch: mark seen as we drive, so it never repeats even if the
    // user abandons it. Re-runs from Settings use startManual (no marking).
    const startAuto = () => {
      if (tourDriver.isActive()) return;
      markTourSeen();
      tourDriver.drive();
    };
    const startManual = () => {
      if (tourDriver.isActive()) return;
      tourDriver.drive();
    };

    // Re-run entry point (Settings "Replay tour" button, future Help menu)
    // is always live, regardless of whether this is the first-ever visit.
    const onStartRequest = () => startManual();
    window.addEventListener(TOUR_START_EVENT, onStartRequest);

    // Auto-run once per browser, first visit only. Gated purely on
    // hasSeenTour() (no extra ref guard) so that if the early `t`-change
    // re-render cancels this pending timer in cleanup, the re-created effect
    // reschedules it — the tour still launches exactly once.
    let autoStartId: number | undefined;
    if (!hasSeenTour()) {
      // Let the sidebar/page finish its first paint so the nav DOM nodes
      // driver.js measures for highlighting are actually in the tree.
      autoStartId = window.setTimeout(startAuto, 400);
    }

    return () => {
      window.removeEventListener(TOUR_START_EVENT, onStartRequest);
      if (autoStartId !== undefined) window.clearTimeout(autoStartId);
      // Don't tear down a tour the user is actively viewing just because a
      // dependency (e.g. `t`) changed identity — only destroy when idle.
      if (!tourDriver.isActive()) tourDriver.destroy();
    };
    // Re-create the driver only when the language or run-visibility changes —
    // both affect step copy/count, so a stale driver instance would show
    // wrong text or the wrong step total.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [t, runVisible]);

  return null;
}
