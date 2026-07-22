/**
 * @file main.tsx
 * @description The entry point of the React application that renders the main App component into the root DOM element. It uses React's StrictMode for highlighting potential problems in the application and ensures that the app is rendered in a way that adheres to best practices.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { ErrorBoundary, installGlobalErrorTelemetry } from "./components/ErrorBoundary";
import { loadPreset } from "./lib/displaySettings";
import "./i18n";
import "./index.css";

installGlobalErrorTelemetry();

// The inline anti-flicker script in index.html already applies `data-preset`
// before React mounts (avoiding a preset flash); this re-applies it from the
// same localStorage key in case that script didn't run (SSR/dev edge cases),
// mirroring ThemeToggle's equivalent fallback for the `dark` class.
{
  const preset = loadPreset();
  if (preset === "gold") document.documentElement.removeAttribute("data-preset");
  else document.documentElement.setAttribute("data-preset", preset);
}

if ("serviceWorker" in navigator) {
  // Detect whether the page is already controlled by an SW *before* we
  // register. On a truly fresh install there is no controller yet, so the
  // first `controllerchange` should NOT reload (the user just opened the page
  // — nothing is stale). On every subsequent rebuild the page is controlled,
  // a new SW takes over, and a one-shot reload picks up the new bundle URLs
  // automatically — no hard refresh needed.
  const wasControlled = !!navigator.serviceWorker.controller;
  let reloaded = false;
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (!wasControlled || reloaded) return;
    reloaded = true;
    window.location.reload();
  });
  navigator.serviceWorker
    .register("/sw.js")
    .then((reg) => {
      // Poke the registration so a freshly-built SW activates promptly
      // instead of waiting for the browser's lazy update check.
      reg.update().catch(() => {});
    })
    .catch(() => {});
}

const root = document.getElementById("root");
if (!root) throw new Error("Root element not found");

createRoot(root).render(
  <StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </StrictMode>
);
