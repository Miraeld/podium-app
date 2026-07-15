/**
 * @file test-setup.ts
 * @description Test setup file for the client-side unit tests using Vitest and React Testing Library. This file configures the testing environment, including importing necessary libraries and performing cleanup after each test to ensure isolation between tests. The cleanup function from React Testing Library is called after each test to unmount components and clean up the DOM, preventing side effects from affecting other tests.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, beforeEach } from "vitest";

// Node 26 ships an experimental `localStorage` global that evaluates to
// `undefined` unless node runs with --localstorage-file; it shadows jsdom's
// implementation when vitest populates the test global. Re-point the global
// at the real jsdom Storage (set up by the jsdom environment as
// `globalThis.jsdom`) so components/tests can use localStorage normally.
const jsdomWindow = (globalThis as { jsdom?: { window: Window } }).jsdom?.window;
if (jsdomWindow?.localStorage && typeof globalThis.localStorage === "undefined") {
  for (const key of ["localStorage", "sessionStorage"] as const) {
    Object.defineProperty(globalThis, key, {
      configurable: true,
      enumerable: true,
      value: jsdomWindow[key],
    });
  }
}
import "./i18n/index";
import i18n from "i18next";

// Force English locale for deterministic test assertions
// (LanguageDetector may pick up zh from the system environment)
beforeEach(() => {
  i18n.changeLanguage("en");
});

afterEach(() => {
  cleanup();
});
