import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // Mirror the `__APP_VERSION__` compile-time constant that vite.config.ts
  // injects via `define`. Without it the Sidebar (which renders
  // `v{__APP_VERSION__}`) throws "__APP_VERSION__ is not defined" under test.
  define: {
    __APP_VERSION__: JSON.stringify("1.0.0"),
  },
  test: {
    environment: "jsdom",
    // jsdom 27 defaults to an opaque origin (about:blank), where accessing
    // window.localStorage throws SecurityError — vitest then exposes it as
    // undefined. A real URL gives the page a non-opaque origin.
    environmentOptions: { jsdom: { url: "http://localhost:3000/" } },
    setupFiles: ["./src/test-setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
    css: false,
  },
});
