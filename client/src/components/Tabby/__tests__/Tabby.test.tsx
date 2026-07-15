import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, fireEvent, act, cleanup, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { Tabby } from "../Tabby";
import { eventBus } from "../../../lib/eventBus";
import type { WSMessage, Session } from "../../../lib/types";

function renderTabby() {
  return render(
    <MemoryRouter>
      <Tabby />
    </MemoryRouter>
  );
}

const sessionMsg = (id: string, status: Session["status"]): WSMessage => ({
  type: "session_updated",
  data: { id, status } as Session,
  timestamp: "t",
});

beforeEach(() => {
  localStorage.clear();
  eventBus.setConnected(true);
  // Freeze timers so the brain's 1s heartbeat tick can't fire a state update
  // outside act() mid-assertion. We never advance them in these tests.
  vi.useFakeTimers();
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe("Tabby widget", () => {
  it("renders the avatar button by default", () => {
    renderTabby();
    expect(screen.getByRole("button", { name: /open tabby companion/i })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /tabby/i })).toBeInTheDocument();
  });

  it("opens the panel on click and answers a local status question", () => {
    renderTabby();
    fireEvent.click(screen.getByRole("button", { name: /open tabby companion/i }));
    const panel = screen.getByRole("dialog", { name: /tabby companion/i });
    expect(panel).toBeInTheDocument();

    const input = within(panel).getByLabelText(/ask tabby/i);
    fireEvent.change(input, { target: { value: "status" } });
    fireEvent.submit(input.closest("form")!);
    expect(within(panel).getByText(/live ·/i)).toBeInTheDocument();
  });

  it("toggles open/closed with Cmd/Ctrl+B and closes with Esc", () => {
    renderTabby();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    act(() => {
      fireEvent.keyDown(window, { key: "b", metaKey: true });
    });
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    act(() => {
      fireEvent.keyDown(window, { key: "Escape" });
    });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("shows an error badge when a session errors", () => {
    renderTabby();
    act(() => {
      eventBus.publish(sessionMsg("a", "error"));
    });
    const btn = screen.getByRole("button", { name: /open tabby companion/i });
    expect(within(btn).getByText("1")).toBeInTheDocument();
  });

  it("reflects the live count in the panel status", () => {
    renderTabby();
    act(() => {
      eventBus.publish(sessionMsg("a", "active"));
      eventBus.publish(sessionMsg("b", "active"));
    });
    fireEvent.click(screen.getByRole("button", { name: /open tabby companion/i }));
    const panel = screen.getByRole("dialog", { name: /tabby companion/i });
    // The "live" stat chip shows value 2 next to its label.
    const liveChip = within(panel).getByText("live").closest("div")!;
    expect(within(liveChip).getByText("2")).toBeInTheDocument();
  });

  it("respects the enabled preference", () => {
    localStorage.setItem("agent-dashboard-tabby-enabled", "false");
    renderTabby();
    expect(screen.queryByRole("button", { name: /open tabby companion/i })).not.toBeInTheDocument();
  });

  it("a tap (no movement) still opens the panel", () => {
    renderTabby();
    const btn = screen.getByRole("button", { name: /open tabby companion/i });
    act(() => {
      fireEvent.pointerDown(btn, { clientX: 990, clientY: 700, button: 0 });
      fireEvent.pointerUp(btn, { clientX: 990, clientY: 700 });
    });
    fireEvent.click(btn);
    expect(screen.getByRole("dialog", { name: /tabby companion/i })).toBeInTheDocument();
  });

  it("dragging leaves the avatar exactly where it was dropped, persists the free position, and does not open the panel", () => {
    renderTabby();
    const btn = screen.getByRole("button", { name: /open tabby companion/i });
    // Default rest spot is near the right edge. Drag to an arbitrary mid-screen spot.
    act(() => {
      fireEvent.pointerDown(btn, { clientX: 990, clientY: 700, button: 0 });
      fireEvent.pointerMove(btn, { clientX: 500, clientY: 300 });
      fireEvent.pointerUp(btn, { clientX: 500, clientY: 300 });
    });
    // The synthetic click that follows a drag must be swallowed.
    fireEvent.click(btn);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    // No snapping — position is persisted as free x/y fractions, not a docked edge.
    const saved = JSON.parse(localStorage.getItem("agent-dashboard-tabby-pos") || "{}");
    expect(typeof saved.x).toBe("number");
    expect(typeof saved.y).toBe("number");
    expect(saved.x).toBeGreaterThanOrEqual(0);
    expect(saved.x).toBeLessThanOrEqual(1);
    expect(saved.side).toBeUndefined();
  });

  it("a sub-threshold pointer move is treated as a tap, not a drag", () => {
    renderTabby();
    const btn = screen.getByRole("button", { name: /open tabby companion/i });
    act(() => {
      fireEvent.pointerDown(btn, { clientX: 990, clientY: 700, button: 0 });
      fireEvent.pointerMove(btn, { clientX: 992, clientY: 701 }); // < 5px threshold
      fireEvent.pointerUp(btn, { clientX: 992, clientY: 701 });
    });
    fireEvent.click(btn);
    expect(screen.getByRole("dialog", { name: /tabby companion/i })).toBeInTheDocument();
    // No position was persisted because no real drag happened.
    expect(localStorage.getItem("agent-dashboard-tabby-pos")).toBeNull();
  });

  it("restores a persisted free position on mount", () => {
    localStorage.setItem("agent-dashboard-tabby-pos", JSON.stringify({ x: 0.25, y: 0.2 }));
    renderTabby();
    const btn = screen.getByRole("button", { name: /open tabby companion/i }) as HTMLElement;
    const availX = window.innerWidth - 60 - 2 * 16;
    const expectedLeft = Math.round(16 + 0.25 * availX);
    expect(btn.style.left).toBe(`${expectedLeft}px`);
  });

  it("migrates a legacy docked { side, y } position to a free x/y position without crashing", () => {
    localStorage.setItem("agent-dashboard-tabby-pos", JSON.stringify({ side: "left", y: 0.2 }));
    renderTabby();
    const btn = screen.getByRole("button", { name: /open tabby companion/i }) as HTMLElement;
    // Legacy left-docked → x near 0 → inline left equals the margin (16px).
    expect(btn.style.left).toBe("16px");
  });

  it("never crashes on garbage persisted position data", () => {
    localStorage.setItem("agent-dashboard-tabby-pos", "not json");
    expect(() => renderTabby()).not.toThrow();
    expect(screen.getByRole("button", { name: /open tabby companion/i })).toBeInTheDocument();
  });
});
