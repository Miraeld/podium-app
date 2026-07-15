/**
 * @file tour.test.ts
 * @description Unit tests for the onboarding tour "seen" gating and
 * window-event bridge helpers — both the nav tour and the session-detail
 * tour, which deliberately use separate keys/events so replaying one never
 * marks the other "seen".
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { describe, it, expect, beforeEach } from "vitest";
import {
  TOUR_SEEN_KEY,
  TOUR_START_EVENT,
  hasSeenTour,
  markTourSeen,
  requestTourStart,
  SESSION_TOUR_SEEN_KEY,
  SESSION_TOUR_START_EVENT,
  hasSeenSessionTour,
  markSessionTourSeen,
  requestSessionTourStart,
} from "../tour";

beforeEach(() => {
  localStorage.clear();
});

describe("nav tour", () => {
  it("is unseen by default", () => {
    expect(hasSeenTour()).toBe(false);
  });

  it("is seen after markTourSeen", () => {
    markTourSeen();
    expect(hasSeenTour()).toBe(true);
    expect(localStorage.getItem(TOUR_SEEN_KEY)).toBe("1");
  });

  it("requestTourStart dispatches the nav start event", () => {
    let fired = 0;
    const handler = () => fired++;
    window.addEventListener(TOUR_START_EVENT, handler);
    requestTourStart();
    window.removeEventListener(TOUR_START_EVENT, handler);
    expect(fired).toBe(1);
  });
});

describe("session tour", () => {
  it("is unseen by default", () => {
    expect(hasSeenSessionTour()).toBe(false);
  });

  it("is seen after markSessionTourSeen", () => {
    markSessionTourSeen();
    expect(hasSeenSessionTour()).toBe(true);
    expect(localStorage.getItem(SESSION_TOUR_SEEN_KEY)).toBe("1");
  });

  it("requestSessionTourStart dispatches the session start event", () => {
    let fired = 0;
    const handler = () => fired++;
    window.addEventListener(SESSION_TOUR_START_EVENT, handler);
    requestSessionTourStart();
    window.removeEventListener(SESSION_TOUR_START_EVENT, handler);
    expect(fired).toBe(1);
  });

  it("uses a distinct key/event pair from the nav tour", () => {
    expect(SESSION_TOUR_SEEN_KEY).not.toBe(TOUR_SEEN_KEY);
    expect(SESSION_TOUR_START_EVENT).not.toBe(TOUR_START_EVENT);
  });

  it("marking the session tour seen does not mark the nav tour seen", () => {
    markSessionTourSeen();
    expect(hasSeenTour()).toBe(false);
    expect(hasSeenSessionTour()).toBe(true);
  });
});
