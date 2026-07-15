/**
 * @file ConfirmModal.tsx
 * @description Reusable centered confirmation dialog used for destructive
 * actions (e.g. deleting an alert rule or a webhook target) in place of inline
 * confirms or the native window.confirm. Click-outside and Escape cancel; the
 * confirm button is styled destructive by default.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useEffect } from "react";
import { AlertTriangle, X } from "lucide-react";

export function ConfirmModal({
  open,
  title,
  message,
  confirmLabel,
  cancelLabel,
  destructive = true,
  busy = false,
  onConfirm,
  onCancel,
}: {
  open: boolean;
  title: string;
  message?: string;
  confirmLabel: string;
  cancelLabel: string;
  destructive?: boolean;
  busy?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onCancel();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open, onCancel]);

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-4"
      onClick={onCancel}
      role="dialog"
      aria-modal="true"
    >
      <div
        className="relative w-full max-w-md rounded-xl border border-border bg-surface-1 shadow-xl shadow-black/40"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start gap-3 p-5">
          {destructive && (
            <div className="w-9 h-9 rounded-lg bg-red-500/10 border border-red-500/20 flex items-center justify-center flex-shrink-0">
              <AlertTriangle className="w-4.5 h-4.5 text-red-400" />
            </div>
          )}
          <div className="min-w-0 flex-1">
            <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{title}</h3>
            {message && (
              <p className="text-xs text-gray-500 dark:text-gray-400 mt-1 leading-relaxed">
                {message}
              </p>
            )}
          </div>
          <button
            onClick={onCancel}
            className="text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 p-1 -mt-1 -mr-1"
            aria-label={cancelLabel}
          >
            <X className="w-4 h-4" />
          </button>
        </div>
        <div className="flex items-center justify-end gap-2 px-5 pb-5">
          <button onClick={onCancel} className="btn-ghost border border-border text-xs">
            {cancelLabel}
          </button>
          <button
            onClick={onConfirm}
            disabled={busy}
            className={`inline-flex items-center gap-1.5 text-xs px-3 py-1.5 rounded-md transition-colors disabled:opacity-50 ${
              destructive
                ? "text-red-700 dark:text-red-200 bg-red-500/15 border border-red-500/30 hover:bg-red-500/25"
                : "btn-primary"
            }`}
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
