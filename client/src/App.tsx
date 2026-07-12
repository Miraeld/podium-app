/**
 * @file App.tsx
 * @description Defines the main application component that sets up routing for different pages, manages WebSocket connections for real-time updates, and initializes notifications. It uses React Router for navigation and custom hooks for WebSocket and notification handling.
 * @author Son Nguyen <hoangson091104@gmail.com>
 */

import { BrowserRouter, Routes, Route, useNavigate } from "react-router-dom";
import { useCallback, useEffect } from "react";
import { Layout } from "./components/Layout";
import { Dashboard } from "./pages/Dashboard";
import { KanbanBoard } from "./pages/KanbanBoard";
import { Sessions } from "./pages/Sessions";
import { SessionDetail } from "./pages/SessionDetail";
import { ActivityFeed } from "./pages/ActivityFeed";
import { Analytics } from "./pages/Analytics";
import { Workflows } from "./pages/Workflows";
import { Settings } from "./pages/Settings";
import { CcConfig } from "./pages/CcConfig";
import { Run } from "./pages/Run";
import { Search } from "./pages/Search";
import { ImportSession } from "./pages/ImportSession";
import { NotFound } from "./pages/NotFound";
import { useWebSocket } from "./hooks/useWebSocket";
import { useNotifications } from "./hooks/useNotifications";
import { NativeFeel } from "./components/NativeFeel";
import { eventBus } from "./lib/eventBus";
import type { WSMessage } from "./lib/types";

export default function App() {
  const onMessage = useCallback((msg: WSMessage) => {
    eventBus.publish(msg);
  }, []);

  const { connected } = useWebSocket(onMessage);
  useNotifications();

  return (
    <BrowserRouter>
      <NativeFeel />
      <GlobalShortcuts />
      <Routes>
        <Route element={<Layout wsConnected={connected} />}>
          <Route index element={<Dashboard />} />
          <Route path="kanban" element={<KanbanBoard />} />
          <Route path="sessions" element={<Sessions />} />
          <Route path="sessions/:id" element={<SessionDetail />} />
          <Route path="activity" element={<ActivityFeed />} />
          <Route path="analytics" element={<Analytics />} />
          <Route path="workflows" element={<Workflows />} />
          <Route path="cc-config" element={<CcConfig />} />
          <Route path="run" element={<Run />} />
          <Route path="search" element={<Search />} />
          <Route path="import" element={<ImportSession />} />
          <Route path="settings" element={<Settings />} />
          <Route path="*" element={<NotFound />} />
        </Route>
      </Routes>
    </BrowserRouter>
  );
}

/**
 * Registers app-wide keyboard shortcuts. Rendered inside <BrowserRouter> so it
 * can use the router's navigate(). Cmd+K (macOS) / Ctrl+K (Windows/Linux) jumps
 * to the global search page.
 */
function GlobalShortcuts() {
  const navigate = useNavigate();

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        navigate("/search");
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [navigate]);

  return null;
}
