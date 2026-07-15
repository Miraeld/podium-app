import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
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
