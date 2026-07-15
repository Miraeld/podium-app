/**
 * @file FieldHelp.tsx
 * @description A small "(?)" info trigger that reveals a rich popover explaining
 * how to fill in a form field - description, optional copy-able examples, and an
 * optional note. Hover/focus/click to open; the popover is portal'd to <body>
 * and clamped to the viewport so it never clips inside scrolling cards.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useTranslation } from "react-i18next";
import { HelpCircle } from "lucide-react";

export function FieldHelp({
  title,
  description,
  examples,
  note,
}: {
  title?: string;
  description: string;
  examples?: string[];
  note?: string;
}) {
  const { t } = useTranslation("common");
  const [open, setOpen] = useState(false);
  const btnRef = useRef<HTMLButtonElement>(null);
  const popRef = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number }>({ left: 0, top: 0 });

  const place = useCallback(() => {
    const btn = btnRef.current;
    const pop = popRef.current;
    if (!btn) return;
    const r = btn.getBoundingClientRect();
    const w = pop?.offsetWidth ?? 300;
    const h = pop?.offsetHeight ?? 120;
    const pad = 10;
    let left = r.left + r.width / 2 - w / 2;
    if (left < pad) left = pad;
    if (left + w > window.innerWidth - pad) left = window.innerWidth - w - pad;
    let top = r.bottom + 8;
    if (top + h > window.innerHeight - pad) top = r.top - h - 8; // flip up
    setPos({ left, top });
  }, []);

  useEffect(() => {
    if (!open) return;
    place();
    const onScroll = () => place();
    window.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", onScroll);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", onScroll);
      document.removeEventListener("keydown", onKey);
    };
  }, [open, place]);

  return (
    <span className="relative inline-flex">
      <button
        ref={btnRef}
        type="button"
        aria-label={title || t("help")}
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={() => setOpen(false)}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        onClick={(e) => {
          e.preventDefault();
          setOpen((v) => !v);
        }}
        className="text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 transition-colors"
      >
        <HelpCircle className="w-3.5 h-3.5" />
      </button>
      {open &&
        createPortal(
          <div
            ref={popRef}
            role="tooltip"
            style={{
              position: "fixed",
              left: pos.left,
              top: pos.top,
              zIndex: 99999,
              maxWidth: 320,
            }}
            className="rounded-lg border border-border bg-surface-1 shadow-xl shadow-black/40 p-3 w-[300px] pointer-events-none"
          >
            {title && (
              <p className="text-xs font-semibold text-gray-900 dark:text-gray-200 mb-1">{title}</p>
            )}
            <p className="text-[11px] leading-relaxed text-gray-600 dark:text-gray-400">
              {description}
            </p>
            {examples && examples.length > 0 && (
              <div className="mt-2">
                <p className="text-[10px] uppercase tracking-wider text-gray-500 dark:text-gray-600 mb-1">
                  {t("examples")}
                </p>
                <div className="flex flex-wrap gap-1">
                  {examples.map((ex) => (
                    <code
                      key={ex}
                      className="text-[10px] font-mono text-accent bg-accent/10 border border-accent/20 rounded px-1.5 py-0.5"
                    >
                      {ex}
                    </code>
                  ))}
                </div>
              </div>
            )}
            {note && (
              <p className="text-[10px] text-gray-500 mt-2 leading-relaxed">{note}</p>
            )}
          </div>,
          document.body
        )}
    </span>
  );
}
