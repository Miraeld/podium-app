/**
 * @file Layout.tsx
 * @description Defines the Layout component that serves as the main structure for the application, including a collapsible sidebar and a main content area. The sidebar's collapsed state is stored in localStorage to persist user preferences across sessions. The component uses React Router's Outlet to render nested routes within the main content area and adjusts its layout based on the sidebar's state.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useState, useCallback } from "react";
import { Outlet } from "react-router-dom";
import { Sidebar, SIDEBAR_STORAGE_KEY, loadCollapsed } from "./Sidebar";
import { UpdateNotifier } from "./UpdateNotifier";
import { OnboardingTour } from "./OnboardingTour";
import { Tabby } from "./Tabby/Tabby";

interface LayoutProps {
  wsConnected: boolean;
}

export function Layout({ wsConnected }: LayoutProps) {
  const [collapsed, setCollapsed] = useState(loadCollapsed);

  const toggle = useCallback(() => {
    setCollapsed((prev) => {
      const next = !prev;
      try {
        localStorage.setItem(SIDEBAR_STORAGE_KEY, String(next));
      } catch {}
      return next;
    });
  }, []);

  return (
    <div className="min-h-screen bg-surface-0 transition-colors duration-200">
      {/* Aurora background — slow-drifting gradient orbs that bleed through frosted glass */}
      <div className="fixed inset-0 pointer-events-none overflow-hidden" style={{ zIndex: 0 }}>
        <div
          className="aurora-orb absolute rounded-full"
          style={{
            width: "70vw",
            height: "70vw",
            top: "-20%",
            right: "-10%",
            background: "radial-gradient(circle at center, var(--orb-gold) 0%, transparent 65%)",
            filter: "blur(45px)",
            animation: "orb-float-1 42s ease-in-out infinite",
            willChange: "transform",
          }}
        />
        <div
          className="aurora-orb absolute rounded-full"
          style={{
            width: "62vw",
            height: "62vw",
            bottom: "-18%",
            left: "-8%",
            background: "radial-gradient(circle at center, var(--orb-indigo) 0%, transparent 65%)",
            filter: "blur(55px)",
            animation: "orb-float-2 54s ease-in-out infinite",
            willChange: "transform",
          }}
        />
        <div
          className="aurora-orb absolute rounded-full"
          style={{
            width: "48vw",
            height: "48vw",
            top: "30%",
            left: "26%",
            background: "radial-gradient(circle at center, var(--orb-amber) 0%, transparent 65%)",
            filter: "blur(70px)",
            animation: "orb-float-3 66s ease-in-out infinite",
            willChange: "transform",
          }}
        />
      </div>
      {/* Invisible drag strip — native overlay titlebar (Tauri) draws real
          traffic lights at top-left; this thin transparent band lets the
          window be dragged from the top edge without covering any UI. */}
      <div
        data-tauri-drag-region
        className="fixed top-0 left-0 right-0 h-7 z-40"
        style={{ WebkitAppRegion: "drag" } as React.CSSProperties}
      />
      <UpdateNotifier />
      <OnboardingTour />
      <Tabby />
      <Sidebar wsConnected={wsConnected} collapsed={collapsed} onToggle={toggle} />
      <main
        className="relative min-h-screen min-w-0 transition-[margin-left,width] duration-200"
        style={{
          marginLeft: collapsed ? "4.25rem" : "15rem",
          width: collapsed ? "calc(100% - 4.25rem)" : "calc(100% - 15rem)",
          zIndex: 1,
        }}
      >
        <div className="p-5 lg:p-6 max-w-full overflow-x-hidden">
          <Outlet />
        </div>
      </main>
    </div>
  );
}
