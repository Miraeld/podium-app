/**
 * @file SessionOnboardingTour.tsx
 * @description Second, contextual driver.js tour — over the Session Detail
 * page instead of the sidebar nav (see OnboardingTour.tsx for that one).
 * Session Detail is the densest page in the app for a newcomer (agent tree,
 * four tabs, run summary, header actions), so this tour teaches how to READ
 * the page rather than just labeling controls.
 *
 * Follows the exact patterns established in OnboardingTour.tsx — read that
 * file's header comment for the reasoning; this one only calls out where it
 * differs:
 *
 * - Own seen-key / start-event pair (`lib/tour.ts`'s SESSION_TOUR_*), so
 *   replaying this tour never marks the nav tour "seen" or vice versa.
 * - Steps are built from `[data-tour="session-*"]` elements that exist in
 *   SessionDetail.tsx, but — unlike the nav tour, where every target is
 *   always in the DOM — several of these targets are conditionally rendered
 *   (the Run Summary card only exists for finished sessions) or conditionally
 *   *hidden* rather than unmounted (the Agents/Conversation tab panels use
 *   `hidden`, not unmount-on-switch, once visited — see SessionDetail's
 *   `visitedTabs` set). driver.js can't usefully highlight an element with
 *   `display: none`, so steps are filtered to elements that are both present
 *   AND actually laid out (`offsetParent !== null`) at drive time, rather
 *   than just present. This intentionally means the tour is a little
 *   different depending on which tab happens to be active on first visit
 *   and whether the session has finished — that's fine, it's still teaching
 *   whatever the user is actually looking at.
 * - Mounted from SessionDetail.tsx itself (not Layout.tsx) since its targets
 *   only exist on that page — effect re-runs on `id` change so navigating
 *   session-to-session re-evaluates which steps apply.
 *
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useEffect } from "react";
import { useTranslation } from "react-i18next";
import { driver, type DriveStep } from "driver.js";
import "driver.js/dist/driver.css";
import "./OnboardingTour.css";
import {
  hasSeenSessionTour,
  markSessionTourSeen,
  SESSION_TOUR_START_EVENT,
} from "../lib/tour";

/** An element is a usable tour target only if it's in the DOM AND actually
 * laid out — `hidden`/`display:none` tab panels are present but not usable. */
function isUsable(selector: string): boolean {
  const el = document.querySelector<HTMLElement>(selector);
  return !!el && el.offsetParent !== null;
}

interface StepSpec {
  key: "header" | "headerActions" | "tabs" | "agentTree" | "conversation" | "runSummary";
  selector: string;
  side: "top" | "bottom" | "left" | "right";
}

const STEP_SPECS: StepSpec[] = [
  { key: "header", selector: '[data-tour="session-header"]', side: "bottom" },
  { key: "headerActions", selector: '[data-tour="session-header-actions"]', side: "bottom" },
  { key: "runSummary", selector: '[data-tour="session-run-summary"]', side: "top" },
  { key: "tabs", selector: '[data-tour="session-tabs"]', side: "bottom" },
  { key: "agentTree", selector: '[data-tour="session-agent-tree"]', side: "top" },
  { key: "conversation", selector: '[data-tour="session-conversation"]', side: "top" },
];

export function SessionOnboardingTour({ sessionId }: { sessionId: string | undefined }) {
  const { t } = useTranslation("tour");

  useEffect(() => {
    if (!sessionId) return;

    const buildSteps = (): DriveStep[] =>
      STEP_SPECS.filter((spec) => isUsable(spec.selector)).map((spec) => ({
        element: spec.selector,
        popover: {
          title: t(`sessionSteps.${spec.key}.title`),
          description: t(`sessionSteps.${spec.key}.description`),
          side: spec.side,
          align: "start",
        },
      }));

    // Steps depend on live DOM layout, so the driver instance is built fresh
    // on every (re)start rather than once up front.
    let tourDriver: ReturnType<typeof driver> | null = null;

    const buildAndDrive = (markSeen: boolean) => {
      if (tourDriver?.isActive()) return;
      const steps = buildSteps();
      if (steps.length === 0) return; // nothing usable to show right now
      tourDriver = driver({
        showProgress: true,
        progressText: t("controls.progress", { current: "{{current}}", total: "{{total}}" }),
        nextBtnText: t("controls.next"),
        prevBtnText: t("controls.previous"),
        doneBtnText: t("controls.done"),
        allowClose: true,
        overlayOpacity: 0.65,
        popoverClass: "podium-tour-popover",
        steps,
      });
      if (markSeen) markSessionTourSeen();
      tourDriver.drive();
    };

    const startAuto = () => buildAndDrive(true);
    const startManual = () => buildAndDrive(false);

    const onStartRequest = () => startManual();
    window.addEventListener(SESSION_TOUR_START_EVENT, onStartRequest);

    // Auto-run once per browser, first visit to ANY session detail page only.
    // Same 400ms grace as the nav tour — let the page finish its first paint
    // (agent tree, tabs, etc.) so driver.js measures real element rects.
    let autoStartId: number | undefined;
    if (!hasSeenSessionTour()) {
      autoStartId = window.setTimeout(startAuto, 400);
    }

    return () => {
      window.removeEventListener(SESSION_TOUR_START_EVENT, onStartRequest);
      if (autoStartId !== undefined) window.clearTimeout(autoStartId);
      if (tourDriver && !tourDriver.isActive()) tourDriver.destroy();
    };
    // Re-evaluate on session change (different session = different agent
    // count/tabs visited) and on language change (step copy/count changes).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [t, sessionId]);

  return null;
}
