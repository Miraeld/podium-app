/**
 * @file toolStyle.ts
 * @description Per-tool visual styling — icon component, accent colour, and tinted
 * surface classes. Keeps the conversation viewer's tool blocks visually distinct so
 * users can scan a long transcript quickly.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import {
  Wrench,
  Terminal,
  FileText,
  FilePlus2,
  FilePen,
  Search,
  Globe,
  Bot,
  ListTodo,
  Clock,
  Sparkles,
  FolderTree,
  type LucideIcon,
} from "lucide-react";

export interface ToolStyle {
  Icon: LucideIcon;
  /** Tailwind text colour for the icon and tool name. */
  text: string;
  /** Tailwind tinted background for the icon chip (15% opacity — sits behind
   *  the icon glyph; staying low-saturation keeps the icon legible). */
  chip: string;
  /** Tailwind background for solid fills like progress bars (60% opacity —
   *  high enough to read at a glance against the dark surface, distinct
   *  from the chip used for the icon backdrop). */
  bar: string;
  /** Tailwind border colour for the tool block when not in error state. */
  border: string;
}

const VIOLET: ToolStyle = {
  Icon: Wrench,
  text: "text-indigo-700 dark:text-indigo-300",
  chip: "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-700 dark:text-indigo-300",
  bar: "bg-indigo-500/60",
  border: "border-indigo-200 dark:border-indigo-500/20",
};

const STYLES: Record<string, ToolStyle> = {
  bash: {
    Icon: Terminal,
    text: "text-emerald-700 dark:text-emerald-300",
    chip: "bg-emerald-50 dark:bg-emerald-500/15 text-emerald-700 dark:text-emerald-300",
    bar: "bg-emerald-500/60",
    border: "border-emerald-200 dark:border-emerald-500/20",
  },
  read: {
    Icon: FileText,
    text: "text-sky-700 dark:text-sky-300",
    chip: "bg-sky-50 dark:bg-sky-500/15 text-sky-700 dark:text-sky-300",
    bar: "bg-sky-500/60",
    border: "border-sky-200 dark:border-sky-500/20",
  },
  write: {
    Icon: FilePlus2,
    text: "text-indigo-700 dark:text-indigo-300",
    chip: "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-700 dark:text-indigo-300",
    bar: "bg-indigo-500/60",
    border: "border-indigo-200 dark:border-indigo-500/20",
  },
  edit: {
    Icon: FilePen,
    text: "text-amber-700 dark:text-amber-300",
    chip: "bg-amber-50 dark:bg-amber-500/15 text-amber-700 dark:text-amber-300",
    bar: "bg-amber-500/60",
    border: "border-amber-200 dark:border-amber-500/20",
  },
  multiedit: {
    Icon: FilePen,
    text: "text-amber-700 dark:text-amber-300",
    chip: "bg-amber-50 dark:bg-amber-500/15 text-amber-700 dark:text-amber-300",
    bar: "bg-amber-500/60",
    border: "border-amber-200 dark:border-amber-500/20",
  },
  grep: {
    Icon: Search,
    text: "text-cyan-700 dark:text-cyan-300",
    chip: "bg-cyan-50 dark:bg-cyan-500/15 text-cyan-700 dark:text-cyan-300",
    bar: "bg-cyan-500/60",
    border: "border-cyan-200 dark:border-cyan-500/20",
  },
  glob: {
    Icon: FolderTree,
    text: "text-cyan-700 dark:text-cyan-300",
    chip: "bg-cyan-50 dark:bg-cyan-500/15 text-cyan-700 dark:text-cyan-300",
    bar: "bg-cyan-500/60",
    border: "border-cyan-200 dark:border-cyan-500/20",
  },
  webfetch: {
    Icon: Globe,
    text: "text-blue-700 dark:text-blue-300",
    chip: "bg-blue-50 dark:bg-blue-500/15 text-blue-700 dark:text-blue-300",
    bar: "bg-blue-500/60",
    border: "border-blue-200 dark:border-blue-500/20",
  },
  websearch: {
    Icon: Globe,
    text: "text-blue-700 dark:text-blue-300",
    chip: "bg-blue-50 dark:bg-blue-500/15 text-blue-700 dark:text-blue-300",
    bar: "bg-blue-500/60",
    border: "border-blue-200 dark:border-blue-500/20",
  },
  task: {
    Icon: Bot,
    text: "text-amber-700 dark:text-accent",
    chip: "bg-accent/25 dark:bg-accent/10 text-amber-700 dark:text-accent",
    bar: "bg-accent/60",
    border: "border-accent/30 dark:border-accent/20",
  },
  agent: {
    Icon: Bot,
    text: "text-amber-700 dark:text-accent",
    chip: "bg-accent/25 dark:bg-accent/10 text-amber-700 dark:text-accent",
    bar: "bg-accent/60",
    border: "border-accent/30 dark:border-accent/20",
  },
  todowrite: {
    Icon: ListTodo,
    text: "text-rose-700 dark:text-rose-300",
    chip: "bg-rose-50 dark:bg-rose-500/15 text-rose-700 dark:text-rose-300",
    bar: "bg-rose-500/60",
    border: "border-rose-200 dark:border-rose-500/20",
  },
  schedulewakeup: {
    Icon: Clock,
    text: "text-orange-700 dark:text-orange-300",
    chip: "bg-orange-50 dark:bg-orange-500/15 text-orange-700 dark:text-orange-300",
    bar: "bg-orange-500/60",
    border: "border-orange-200 dark:border-orange-500/20",
  },
  skill: {
    Icon: Sparkles,
    text: "text-fuchsia-700 dark:text-fuchsia-300",
    chip: "bg-fuchsia-500/15 text-fuchsia-700 dark:text-fuchsia-300",
    bar: "bg-fuchsia-500/60",
    border: "border-fuchsia-500/20",
  },
};

export function styleForTool(toolName: string | undefined | null): ToolStyle {
  if (!toolName) return VIOLET;
  const key = toolName.toLowerCase().replace(/[^a-z0-9]/g, "");
  return STYLES[key] ?? VIOLET;
}
