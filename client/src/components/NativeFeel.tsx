/**
 * @file NativeFeel.tsx
 * @description App-wide behaviors that make the Tauri-wrapped dashboard feel
 * like a native desktop app instead of a browser tab: no default right-click
 * context menu over UI chrome, and no accidental navigation when a file is
 * dragged over the window. Both are scoped so real content usage (text
 * selection, inputs, components with their own drop handling) is unaffected.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useEffect } from "react";

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false;
  return !!target.closest('input, textarea, [contenteditable="true"], [contenteditable=""]');
}

function hasActiveSelection(): boolean {
  const sel = window.getSelection();
  return !!sel && sel.type === "Range" && sel.toString().length > 0;
}

export function NativeFeel() {
  useEffect(() => {
    const onContextMenu = (e: MouseEvent) => {
      if (isEditableTarget(e.target)) return;
      if (hasActiveSelection()) return;
      e.preventDefault();
    };

    // Prevent the browser's default "navigate to dropped file" behavior
    // app-wide. Components that implement their own drop zones call
    // `stopPropagation()` in their own handlers, so this only catches drops
    // that nothing else handled.
    const onDragOver = (e: DragEvent) => {
      e.preventDefault();
    };
    const onDrop = (e: DragEvent) => {
      e.preventDefault();
    };

    document.addEventListener("contextmenu", onContextMenu);
    document.addEventListener("dragover", onDragOver);
    document.addEventListener("drop", onDrop);
    return () => {
      document.removeEventListener("contextmenu", onContextMenu);
      document.removeEventListener("dragover", onDragOver);
      document.removeEventListener("drop", onDrop);
    };
  }, []);

  return null;
}
