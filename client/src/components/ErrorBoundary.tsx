/**
 * @file ErrorBoundary.tsx
 * @description Top-level React error boundary shown when a render error would
 * otherwise leave the app on a dark/blank screen. Also wires up window-level
 * `error` and `unhandledrejection` handlers so errors thrown outside React's
 * render cycle are captured too. There is no server endpoint for client
 * telemetry today, so all of this only logs to the console — see
 * Sources/PodiumServer/Routes/DiagnosticsRouter.swift, which is read-only.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { Component, type ErrorInfo, type ReactNode } from "react";

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false };

  static getDerivedStateFromError(): State {
    return { hasError: true };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // eslint-disable-next-line no-console
    console.error("[Podium] Unhandled render error:", error, info.componentStack);
  }

  render() {
    if (this.state.hasError) {
      return (
        <div
          style={{
            minHeight: "100vh",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            justifyContent: "center",
            gap: "1rem",
            fontFamily: "Inter, system-ui, sans-serif",
            background: "#0A0C14",
            color: "#E5E7EB",
            textAlign: "center",
            padding: "2rem",
          }}
        >
          <p style={{ fontSize: "1rem", fontWeight: 600 }}>Something went wrong</p>
          <p style={{ fontSize: "0.875rem", color: "#9CA3AF", maxWidth: 360 }}>
            Podium hit an unexpected error. Reloading the dashboard usually fixes it.
          </p>
          <button
            onClick={() => window.location.reload()}
            style={{
              padding: "0.5rem 1.25rem",
              borderRadius: "0.5rem",
              border: "1px solid rgba(254, 210, 58, 0.4)",
              background: "rgba(254, 210, 58, 0.12)",
              color: "#FED23A",
              fontSize: "0.875rem",
              fontWeight: 600,
              cursor: "pointer",
            }}
          >
            Reload
          </button>
        </div>
      );
    }

    return this.props.children;
  }
}

/**
 * Installs `window.onerror` / `unhandledrejection` handlers that log
 * uncaught errors outside React's render cycle (async callbacks, event
 * handlers, etc.). Call once at app startup.
 */
export function installGlobalErrorTelemetry() {
  window.addEventListener("error", (event) => {
    // eslint-disable-next-line no-console
    console.error("[Podium] window.onerror:", event.error ?? event.message, {
      filename: event.filename,
      lineno: event.lineno,
      colno: event.colno,
    });
  });

  window.addEventListener("unhandledrejection", (event) => {
    // eslint-disable-next-line no-console
    console.error("[Podium] Unhandled promise rejection:", event.reason);
  });
}
