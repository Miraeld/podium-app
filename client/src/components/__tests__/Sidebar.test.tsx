/**
 * @file Sidebar.test.tsx
 * @description Unit tests for the Sidebar component, which is responsible for rendering the application's sidebar navigation. The tests cover rendering of the brand name, subtitle, navigation links, WebSocket connection status, and version number. The tests use React Testing Library and Vitest for assertions and mocking.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { describe, it, expect, afterEach } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { Sidebar, KANBAN_VISIBLE_KEY } from "../Sidebar";

function renderSidebar(wsConnected: boolean, collapsed = false) {
  return render(
    <MemoryRouter>
      <Sidebar wsConnected={wsConnected} collapsed={collapsed} onToggle={() => {}} />
    </MemoryRouter>
  );
}

describe("Sidebar", () => {
  afterEach(() => {
    localStorage.clear();
  });

  it("should render the brand name", () => {
    renderSidebar(true);
    expect(screen.getByRole("heading", { name: "Podium" })).toBeInTheDocument();
  });

  it("should render the owner subtitle", () => {
    // The Podium client shows the owner label ("Gael R"), not the upstream
    // "{wpmedia}" brand tag.
    renderSidebar(true);
    expect(screen.getByText("Gael R")).toBeInTheDocument();
  });

  it("should render the default navigation links", () => {
    // Kanban and Run Claude are gated behind localStorage flags, so they are
    // absent from the default nav — assert only the always-visible items.
    renderSidebar(true);
    expect(screen.getByText("Dashboard")).toBeInTheDocument();
    expect(screen.getByText("Sessions")).toBeInTheDocument();
    expect(screen.getByText("Activity Feed")).toBeInTheDocument();
    expect(screen.getByText("Analytics")).toBeInTheDocument();
    expect(screen.getByText("Workflows")).toBeInTheDocument();
  });

  it("should hide the Kanban nav item by default", () => {
    renderSidebar(true);
    expect(screen.queryByText("Kanban Board")).not.toBeInTheDocument();
  });

  it("should show the Kanban nav item when enabled via localStorage", () => {
    localStorage.setItem(KANBAN_VISIBLE_KEY, "true");
    renderSidebar(true);
    expect(screen.getByText("Kanban Board")).toBeInTheDocument();
    const hrefs = screen.getAllByRole("link").map((l) => l.getAttribute("href"));
    expect(hrefs).toContain("/kanban");
  });

  it('should show "Live" when WebSocket is connected', () => {
    renderSidebar(true);
    expect(screen.getByText("Live")).toBeInTheDocument();
  });

  it('should show "Disconnected" when WebSocket is not connected', () => {
    renderSidebar(false);
    expect(screen.getByText("Disconnected")).toBeInTheDocument();
  });

  it("should show version number", () => {
    renderSidebar(true);
    expect(screen.getByText("v1.0.0")).toBeInTheDocument();
  });

  it("should have correct navigation hrefs", () => {
    renderSidebar(true);
    const links = screen.getAllByRole("link");
    const hrefs = links.map((link) => link.getAttribute("href"));
    expect(hrefs).toContain("/");
    expect(hrefs).toContain("/sessions");
    expect(hrefs).toContain("/activity");
    expect(hrefs).toContain("/analytics");
  });

  it("should not render a language switcher", () => {
    // The Podium client dropped the upstream 3-language switcher; the footer
    // control cluster is a theme toggle instead.
    renderSidebar(true);
    expect(screen.queryByRole("button", { name: "English" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Chinese" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Vietnamese" })).not.toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /switch to (dark|light) theme/i })
    ).toBeInTheDocument();
  });

  it("should hide brand subtitle and nav labels when collapsed", () => {
    // Collapsed mode renders icon-only nav (no text labels) and drops the
    // owner subtitle, keeping the nav links themselves reachable.
    renderSidebar(true, true);
    expect(screen.queryByText("Gael R")).not.toBeInTheDocument();
    expect(screen.queryByText("Dashboard")).not.toBeInTheDocument();
    const hrefs = screen.getAllByRole("link").map((l) => l.getAttribute("href"));
    expect(hrefs).toContain("/");
    expect(hrefs).toContain("/sessions");
  });
});
