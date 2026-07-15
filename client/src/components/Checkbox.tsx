/**
 * @file Checkbox.tsx
 * @description Custom styled checkbox replacing the browser-default control for
 * a consistent look (accent fill + check when on). Self-contained with an
 * optional label; keyboard-operable (Space/Enter toggles).
 * @author Gael Robin <robin.gael@gmail.com>
 */

import type { ReactNode } from "react";
import { Check } from "lucide-react";

export function Checkbox({
  checked,
  onChange,
  label,
  className,
  labelClassName,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  label?: ReactNode;
  className?: string;
  labelClassName?: string;
}) {
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
      className={`group inline-flex items-center gap-2 text-left ${className ?? ""}`}
    >
      <span
        className={`flex h-4 w-4 flex-shrink-0 items-center justify-center rounded-[5px] border transition-colors ${
          checked
            ? "bg-accent border-accent"
            : "bg-surface-2 border-border group-hover:border-gray-400"
        }`}
      >
        {checked && <Check className="h-3 w-3 text-white" strokeWidth={3} />}
      </span>
      {label != null && (
        <span
          className={
            labelClassName ??
            "text-xs text-gray-600 dark:text-gray-400 group-hover:text-gray-900 dark:group-hover:text-gray-300"
          }
        >
          {label}
        </span>
      )}
    </button>
  );
}
