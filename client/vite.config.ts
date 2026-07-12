import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Version shown in the sidebar. For the standalone Podium app the source of
// truth is the Tauri app version (tauri.conf.json / run.sh), passed in via
// PODIUM_APP_VERSION.
//
// PRE-1.0 audit D1: this used to silently fall back to the legacy
// `.claude-plugin/plugin.json` version (plugin-era leftover) when the env
// var was unset, which shipped a stale sidebar version TWICE (the vendored
// dist quietly re-vendored an old plugin.json version instead of failing
// loudly). There is no safe fallback anymore: a real `npm run build` MUST
// set `PODIUM_APP_VERSION` or the build fails outright. `npm run dev` (this
// repo only, never vendored) still works unset, using a visible "dev" tag.
const envVersion = process.env.PODIUM_APP_VERSION ?? "";
const isBuild = process.argv.includes("build") || process.env.npm_lifecycle_event === "build";
if (!envVersion && isBuild) {
  throw new Error(
    "[vite] PODIUM_APP_VERSION is not set. `npm run build` requires it " +
      "(e.g. `PODIUM_APP_VERSION=0.5.3 npm run build`) — there is no version " +
      "fallback; a stale/guessed version has shipped to users twice already."
  );
}
const APP_VERSION = envVersion || "dev";

// Honour DASHBOARD_PORT so the proxy follows when `npm run dev:server` is
// moved off the default 4820 (e.g. when an SSH `LocalForward` already holds
// 4820 on `127.0.0.1` and `::1`). The dev server reads the same env var from
// `server/index.js`, so a single `DASHBOARD_PORT=4821 npm run dev` keeps
// both sides in lockstep.
//
// We also target `127.0.0.1` rather than `localhost`: when several listeners
// exist on the same port across IP families (loopback-specific SSH binds vs.
// Node's wildcard listen), macOS routes connections by socket specificity,
// so `localhost` can resolve into the wrong process. An explicit IPv4 loopback
// is what the embedded server in production binds to anyway.
const DASHBOARD_PORT = parseInt(process.env.DASHBOARD_PORT || "4820", 10);

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: `http://127.0.0.1:${DASHBOARD_PORT}`,
        changeOrigin: true,
      },
      "/ws": {
        target: `ws://127.0.0.1:${DASHBOARD_PORT}`,
        ws: true,
      },
    },
  },
  define: {
    __APP_VERSION__: JSON.stringify(APP_VERSION),
  },
  build: {
    outDir: "dist",
    sourcemap: true,
  },
});
