/**
 * @file useTabbyPosition.ts
 * @description Free-positioning drag for the Tabby avatar. The avatar follows
 *   the pointer 1:1 while dragging (via Pointer Capture, so it keeps tracking
 *   even if the cursor outruns it) and, on release, simply stays wherever it
 *   was dropped — no edge snapping. The resting spot is persisted as x/y
 *   viewport fractions (of the draggable area, i.e. the viewport minus the
 *   avatar footprint and margin) so it survives window resizes, clamped back
 *   on-screen if the window shrinks. `side` (left/right half) and `openUp`
 *   are derived from the current position purely so flyouts (panel/speech
 *   bubble) know which direction to open — they carry no docking meaning of
 *   their own anymore. A small movement threshold tells a drag apart from a
 *   tap so dragging never opens the panel.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { tabbyPrefs, type TabbyPos } from "./prefs";
import type { PointerEvent as ReactPointerEvent } from "react";

// Avatar footprint + edge gap, in px. SIZE matches CatAvatar's default size.
export const TABBY_SIZE = 60;
export const TABBY_MARGIN = 16;
const DRAG_THRESHOLD = 5;

const vw = () => (typeof window !== "undefined" ? window.innerWidth : 1024);
const vh = () => (typeof window !== "undefined" ? window.innerHeight : 768);

function defaultPos(): TabbyPos {
  return { x: 1, y: 0.5 }; // near the right edge, vertically centered
}

/** Resting top-left screen coords for a free position (x/y fractions of the draggable area). */
function restingScreen(pos: TabbyPos) {
  const availX = Math.max(0, vw() - TABBY_SIZE - 2 * TABBY_MARGIN);
  const availY = Math.max(0, vh() - TABBY_SIZE - 2 * TABBY_MARGIN);
  const left = TABBY_MARGIN + pos.x * availX;
  const top = TABBY_MARGIN + pos.y * availY;
  return { left, top };
}

export interface TabbyPlacement {
  /** Avatar top-left, in screen px. */
  left: number;
  top: number;
  size: number;
  side: "left" | "right";
  /** True when the avatar sits in the lower half — flyouts open upward. */
  openUp: boolean;
  dragging: boolean;
  onPointerDown: (e: ReactPointerEvent) => void;
  onPointerMove: (e: ReactPointerEvent) => void;
  onPointerUp: (e: ReactPointerEvent) => void;
  /** Returns true (once) if a drag just ended, so the click handler can skip. */
  consumeDrag: () => boolean;
}

export function useTabbyPosition(): TabbyPlacement {
  const [pos, setPos] = useState<TabbyPos>(() => tabbyPrefs.getPos() ?? defaultPos());
  const [drag, setDrag] = useState<{ left: number; top: number } | null>(null);
  const [, force] = useState(0); // re-derive resting coords on resize

  const draggedRef = useRef(false);
  const startRef = useRef<{ px: number; py: number; left: number; top: number } | null>(null);
  const movedRef = useRef(false);
  // Latest dragged coords, mirrored in a ref so pointerup can read them
  // synchronously — the setDrag state may not have committed yet under React's
  // event batching, so we never rely on its functional-updater `cur`.
  const liveRef = useRef<{ left: number; top: number } | null>(null);

  useEffect(() => {
    const onResize = () => force((n) => n + 1);
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  const resting = restingScreen(pos);
  const screen = drag ?? resting;

  const onPointerDown = useCallback(
    (e: ReactPointerEvent) => {
      if (e.button !== undefined && e.button !== 0) return;
      // Capture so the avatar keeps receiving move/up events even when the
      // pointer leaves it — essential for a fast, 1:1 drag.
      try {
        (e.currentTarget as Element).setPointerCapture?.(e.pointerId);
      } catch {
        /* capture unsupported — window-free fallback still works via props */
      }
      startRef.current = { px: e.clientX, py: e.clientY, left: screen.left, top: screen.top };
      movedRef.current = false;
    },
    [screen.left, screen.top]
  );

  const onPointerMove = useCallback((e: ReactPointerEvent) => {
    const start = startRef.current;
    if (!start) return;
    const dx = e.clientX - start.px;
    const dy = e.clientY - start.py;
    if (!movedRef.current && Math.hypot(dx, dy) < DRAG_THRESHOLD) return;
    movedRef.current = true;
    const left = Math.min(
      vw() - TABBY_SIZE - TABBY_MARGIN,
      Math.max(TABBY_MARGIN, start.left + dx)
    );
    const top = Math.min(vh() - TABBY_SIZE - TABBY_MARGIN, Math.max(TABBY_MARGIN, start.top + dy));
    liveRef.current = { left, top };
    setDrag({ left, top });
  }, []);

  const onPointerUp = useCallback((e: ReactPointerEvent) => {
    try {
      (e.currentTarget as Element).releasePointerCapture?.(e.pointerId);
    } catch {
      /* ignore */
    }
    const live = liveRef.current;
    if (live) {
      draggedRef.current = true;
      const availX = Math.max(1, vw() - TABBY_SIZE - 2 * TABBY_MARGIN);
      const availY = Math.max(1, vh() - TABBY_SIZE - 2 * TABBY_MARGIN);
      const x = Math.min(1, Math.max(0, (live.left - TABBY_MARGIN) / availX));
      const y = Math.min(1, Math.max(0, (live.top - TABBY_MARGIN) / availY));
      const next: TabbyPos = { x, y };
      tabbyPrefs.setPos(next);
      setPos(next);
      setDrag(null); // leave drag mode; the avatar just stays where it was dropped
    }
    liveRef.current = null;
    startRef.current = null;
    movedRef.current = false;
  }, []);

  const consumeDrag = useCallback(() => {
    const was = draggedRef.current;
    draggedRef.current = false;
    return was;
  }, []);

  // Derived purely for flyout direction — which half of the screen the avatar
  // currently sits in, not a docking state.
  const side: "left" | "right" = screen.left + TABBY_SIZE / 2 < vw() / 2 ? "left" : "right";
  const openUp = screen.top + TABBY_SIZE / 2 > vh() / 2;

  return {
    left: screen.left,
    top: screen.top,
    size: TABBY_SIZE,
    side,
    openUp,
    dragging: drag !== null,
    onPointerDown,
    onPointerMove,
    onPointerUp,
    consumeDrag,
  };
}
