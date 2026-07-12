/**
 * @file MessageList.tsx
 * @description Renders the chronological message stream of a Claude Code
 * transcript: alternating user / assistant rows with collapsible thinking
 * blocks, inline ToolCallBlocks for tool_use / tool_result pairs, and
 * MarkdownContent for prose. Used by ConversationView as the main body of
 * the Conversation tab on the Session detail page.
 * @author Gael Robin <robin.gael@gmail.com>
 */
import { useState, useMemo } from "react";
import {
  ChevronDown,
  ChevronRight,
  Bot,
  User,
  Brain,
  ScrollText,
  Terminal,
  Info,
  AlertTriangle,
} from "lucide-react";
import type { TranscriptMessage, TranscriptContent } from "../../lib/types";
import { ToolCallBlock } from "./ToolCallBlock";
import { MarkdownContent } from "./MarkdownContent";
import { fmt, formatModelName } from "../../lib/format";
import { parseTuiSegments, stripAnsi, hasTuiTags, type TuiSegment } from "./tuiSegments";

interface MessageListProps {
  messages: TranscriptMessage[];
  loading: boolean;
}

/** Build a map from tool_use id → tool_result for matching */
function buildToolResultMap(messages: TranscriptMessage[]): Map<string, TranscriptContent> {
  const map = new Map<string, TranscriptContent>();
  for (const msg of messages) {
    if (msg.type !== "user") continue;
    for (const c of msg.content) {
      if (c.type === "tool_result" && c.id) {
        map.set(c.id, c);
      }
    }
  }
  return map;
}

/** Detect if text is skill loading content (starts with "Base directory for this skill:") */
function isSkillContent(text: string): boolean {
  return text.startsWith("Base directory for this skill:");
}

/** Detect if text is a task notification (contains <task-notification> tag) */
function isTaskNotification(text: string): boolean {
  return text.includes("<task-notification>") || text.includes("<task-id>");
}

/** Format a timestamp as compact local time (e.g. "14:23:01"). */
function formatLocalTime(iso: string): string {
  try {
    return new Date(iso).toLocaleTimeString();
  } catch {
    return "";
  }
}

/** Compact pill for /command invocations parsed out of TUI markup. */
function CommandPill({ display }: { display: string }) {
  return (
    <div className="inline-flex items-center gap-2 text-sm text-emerald-700 dark:text-emerald-300 font-mono bg-emerald-50 dark:bg-emerald-500/10 border border-emerald-200 dark:border-emerald-500/20 rounded-md px-3 py-1.5 max-w-full">
      <span className="text-emerald-500/70">›</span>
      <span className="break-all">{display}</span>
    </div>
  );
}

/** Terminal-style fenced block for stdout/stderr captured from local commands. */
function TerminalBlock({ text, stream }: { text: string; stream: "stdout" | "stderr" }) {
  const cleaned = stripAnsi(text).replace(/^\n+|\n+$/g, "");
  const isErr = stream === "stderr";
  const accent = isErr
    ? "border-red-200 dark:border-red-500/30 bg-red-50 text-red-700 dark:bg-red-950/30 dark:text-red-200/90"
    : "border-surface-3 bg-surface-4/60 text-gray-700 dark:text-gray-200";
  const labelColor = isErr ? "text-red-700 dark:text-red-300/80" : "text-gray-600 dark:text-gray-400";
  return (
    <div className={`rounded-lg border ${accent} overflow-hidden`}>
      <div
        className={`flex items-center gap-1.5 px-3 py-1 text-[10px] uppercase tracking-wider border-b border-current/10 ${labelColor}`}
      >
        <Terminal className="w-3 h-3" />
        <span>{stream}</span>
      </div>
      <pre className="px-3 py-2 text-xs font-mono whitespace-pre-wrap break-words leading-relaxed max-h-96 overflow-y-auto">
        {cleaned}
      </pre>
    </div>
  );
}

/** Subtle inline note for the local-command-caveat banner. */
function CaveatBlock({ text }: { text: string }) {
  return (
    <div className="flex items-start gap-2 rounded-md border border-amber-500/15 bg-amber-500/[0.05] px-3 py-1.5 text-[11px] text-amber-800 dark:text-amber-200/70">
      <Info className="w-3.5 h-3.5 mt-px flex-shrink-0 opacity-60" />
      <span className="leading-relaxed italic">{stripAnsi(text).trim()}</span>
    </div>
  );
}

/** Render a single segment produced by parseTuiSegments. */
function renderSegment(seg: TuiSegment, key: number): React.ReactNode {
  switch (seg.kind) {
    case "command":
      return <CommandPill key={key} display={seg.display} />;
    case "stdout":
      return <TerminalBlock key={key} text={seg.text} stream="stdout" />;
    case "stderr":
      return <TerminalBlock key={key} text={seg.text} stream="stderr" />;
    case "caveat":
      return <CaveatBlock key={key} text={seg.text} />;
    case "system-reminder":
      return (
        <CollapsibleBlock
          key={key}
          text={seg.text}
          icon={<AlertTriangle className="w-3.5 h-3.5 text-amber-700 dark:text-amber-400/70 flex-shrink-0" />}
          title="System reminder"
          borderClass="border-amber-200 dark:border-amber-500/20"
          bgClass="bg-amber-500/5"
          textClass="text-amber-700 dark:text-amber-300/80"
        />
      );
    case "persisted-output":
      return (
        <CollapsibleBlock
          key={key}
          text={seg.text}
          icon={<ScrollText className="w-3.5 h-3.5 text-indigo-700 dark:text-indigo-400/60 flex-shrink-0" />}
          title="Persisted output"
          borderClass="border-indigo-200 dark:border-indigo-500/20"
          bgClass="bg-indigo-500/5"
          textClass="text-indigo-700 dark:text-indigo-300/80"
        />
      );
    case "text": {
      const cleaned = stripAnsi(seg.text);
      if (!cleaned.trim()) return null;
      return (
        <div key={key} className="min-w-0">
          <MarkdownContent text={cleaned} />
        </div>
      );
    }
  }
}

/** Generic collapsible content block */
function CollapsibleBlock({
  text,
  icon,
  title,
  borderClass,
  bgClass,
  textClass,
}: {
  text: string;
  icon: React.ReactNode;
  title: string;
  borderClass: string;
  bgClass: string;
  textClass: string;
}) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className={`rounded-lg border ${borderClass} ${bgClass} overflow-hidden`}>
      <button
        onClick={() => setExpanded(!expanded)}
        className="w-full flex items-center gap-2 px-3 py-1.5 text-left hover:opacity-80 transition-colors"
      >
        {expanded ? (
          <ChevronDown className="w-3.5 h-3.5 opacity-60 flex-shrink-0" />
        ) : (
          <ChevronRight className="w-3.5 h-3.5 opacity-60 flex-shrink-0" />
        )}
        {icon}
        <span className={`text-xs ${textClass} truncate`}>{title}</span>
      </button>
      {expanded && (
        <div className="border-t border-current/10 px-3 py-2">
          <pre className="text-xs opacity-60 whitespace-pre-wrap break-words leading-relaxed max-h-96 overflow-y-auto">
            {text}
          </pre>
        </div>
      )}
    </div>
  );
}

/** Default number of characters shown before the "Show more" cut-off. */
const THINKING_PREVIEW_CHARS = 500;

/**
 * Collapsible extended-thinking block. The full text is never truncated — the
 * collapsed state shows a preview slice and a "Show more" control, while the
 * expanded state renders the entire content inside a scrollable, height-capped
 * container so very long reasoning dumps stay on the page.
 */
export function ThinkingBlock({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  const isLong = text.length > THINKING_PREVIEW_CHARS;
  const preview = isLong ? text.slice(0, THINKING_PREVIEW_CHARS) : text;

  return (
    <div className="rounded-lg border border-indigo-200 dark:border-indigo-500/20 bg-indigo-50/50 dark:bg-indigo-500/[0.06] overflow-hidden">
      <button
        onClick={() => setOpen((v) => !v)}
        className="w-full flex items-center gap-2 px-3 py-1.5 text-left hover:bg-indigo-100/60 dark:hover:bg-indigo-500/10 transition-colors"
      >
        <ChevronRight
          className={`w-3.5 h-3.5 text-indigo-400 dark:text-indigo-400/70 transition-transform duration-150 ${
            open ? "rotate-90" : ""
          }`}
        />
        <Brain className="w-3.5 h-3.5 text-indigo-500 dark:text-indigo-400" />
        <span className="text-xs italic text-indigo-700 dark:text-indigo-300 font-medium">
          Thinking
        </span>
        <span className="text-[10px] text-indigo-500/70 dark:text-indigo-400/60 font-mono ml-auto">
          {text.length.toLocaleString()} chars
        </span>
      </button>
      <div className="border-t border-indigo-200 dark:border-indigo-500/20 px-3 py-2 italic text-indigo-900/80 dark:text-indigo-100/70">
        {open ? (
          <div className="overflow-y-auto max-h-[600px]">
            <div className="whitespace-pre-wrap break-words leading-relaxed">
              <MarkdownContent text={text} dense />
            </div>
          </div>
        ) : (
          <div className="whitespace-pre-wrap break-words leading-relaxed">
            <MarkdownContent text={preview} dense />
          </div>
        )}
        {isLong && (
          <button
            onClick={() => setOpen((v) => !v)}
            className="mt-1 text-[11px] not-italic font-medium text-indigo-600 dark:text-indigo-400 hover:text-indigo-700 dark:hover:text-indigo-300 transition-colors"
          >
            {open ? "Show less" : "Show more"}
          </button>
        )}
      </div>
    </div>
  );
}

export function MessageList({ messages, loading }: MessageListProps) {
  if (loading) {
    return (
      <div className="flex items-center justify-center py-12 text-gray-700 dark:text-gray-500 text-sm">
        Loading conversation...
      </div>
    );
  }

  if (messages.length === 0) {
    return (
      <div className="text-center py-12 text-gray-700 dark:text-gray-500 text-sm">No conversation records found.</div>
    );
  }

  const toolResultMap = buildToolResultMap(messages);

  // Track which user messages are pure tool_result (no text) — we merge those into the preceding assistant message
  const userMsgHasText = useMemo(() => {
    const map = new Map<number, boolean>();
    messages.forEach((msg, idx) => {
      if (msg.type !== "user") return;
      const hasText = msg.content.some((c) => c.type === "text");
      map.set(idx, hasText);
    });
    return map;
  }, [messages]);

  return (
    <div className="space-y-3">
      {messages.map((msg, idx) => {
        // Skip user messages that are purely tool_result — they're rendered inside ToolCallBlock
        if (msg.type === "user" && !userMsgHasText.get(idx)) {
          return null;
        }

        const isAssistant = msg.type === "assistant";
        const accentBar = isAssistant ? "before:bg-indigo-500/40" : "before:bg-amber-400/50";
        const avatarRing = isAssistant
          ? "bg-accent/25 text-gray-900 dark:bg-accent/20 dark:text-accent border border-accent/30"
          : "bg-accent/20 text-amber-800 dark:text-accent ring-1 ring-accent/30";
        // User turns read as a tinted bubble; assistant turns stay transparent so
        // prose flows naturally against the page surface.
        const bodyBubble = isAssistant
          ? "text-gray-800 dark:text-gray-200"
          : "bg-accent/15 dark:bg-accent/10 border border-amber-200/50 dark:border-accent/20 text-gray-900 dark:text-white rounded-2xl rounded-tr-sm px-3 py-2";

        return (
          <div
            key={idx}
            className={`relative flex gap-3 rounded-xl px-3 py-2.5 hover:bg-surface-2/30 transition-colors before:absolute before:left-0 before:top-3 before:bottom-3 before:w-0.5 before:rounded-full before:opacity-60 ${accentBar}`}
          >
            {/* Avatar */}
            <div
              className={`flex-shrink-0 w-8 h-8 rounded-full flex items-center justify-center mt-0.5 shadow-sm ${avatarRing}`}
            >
              {isAssistant ? <Bot className="w-4 h-4" /> : <User className="w-4 h-4" />}
            </div>

            {/* Message body */}
            <div className={`flex-1 min-w-0 space-y-2 ${bodyBubble}`}>
              {/* Header line */}
              <div className="flex items-center gap-2 flex-wrap">
                <span
                  className={`text-xs font-semibold tracking-wide ${
                    isAssistant
                      ? "text-amber-700 dark:text-accent"
                      : "text-blue-700 dark:text-blue-400"
                  }`}
                >
                  {isAssistant ? "Assistant" : "User"}
                </span>
                {msg.model && (
                  <span className="text-[10px] text-gray-600 dark:text-gray-400 font-mono bg-surface-3/60 border border-surface-3 rounded px-1.5 py-0.5">
                    {formatModelName(msg.model)}
                  </span>
                )}
                {msg.usage && (
                  <span className="text-[10px] text-gray-700 dark:text-gray-500 font-mono inline-flex items-center gap-1">
                    <span className="text-emerald-700 dark:text-emerald-300/70">↓ {fmt(msg.usage.input_tokens)}</span>
                    <span className="text-gray-700">·</span>
                    <span className="text-orange-700 dark:text-orange-300/70">↑ {fmt(msg.usage.output_tokens)}</span>
                  </span>
                )}
                {msg.timestamp && (
                  <span className="text-[10px] text-gray-600 ml-auto font-mono">
                    {formatLocalTime(msg.timestamp)}
                  </span>
                )}
              </div>

              {/* Content blocks */}
              {msg.content.map((block, bIdx) => {
                if (block.type === "text" && block.text) {
                  // Detect task notifications, collapsed by default
                  if (isTaskNotification(block.text)) {
                    return (
                      <CollapsibleBlock
                        key={bIdx}
                        text={block.text}
                        icon={<ScrollText className="w-3.5 h-3.5 text-cyan-700 dark:text-cyan-400/60 flex-shrink-0" />}
                        title="Task Notification"
                        borderClass="border-cyan-200 dark:border-cyan-500/20"
                        bgClass="bg-cyan-500/5"
                        textClass="text-cyan-700 dark:text-cyan-400/80"
                      />
                    );
                  }

                  // Detect skill content, collapsed by default
                  if (isSkillContent(block.text)) {
                    const pathMatch = block.text.match(/^Base directory for this skill:\s*(\S+)/);
                    const skillPath = pathMatch ? pathMatch[1]! : "Skill";
                    return (
                      <CollapsibleBlock
                        key={bIdx}
                        text={block.text}
                        icon={<ScrollText className="w-3.5 h-3.5 text-blue-700 dark:text-blue-400/60 flex-shrink-0" />}
                        title={skillPath}
                        borderClass="border-blue-200 dark:border-blue-500/20"
                        bgClass="bg-blue-500/5"
                        textClass="text-blue-700 dark:text-blue-400/80"
                      />
                    );
                  }

                  // Mixed TUI markup: caveat / command / stdout / stderr / system-reminder
                  // can appear inline (sometimes interleaved with prose). Parse the text
                  // into segments and render each with the appropriate visual treatment.
                  if (hasTuiTags(block.text)) {
                    const segments = parseTuiSegments(block.text);
                    return (
                      <div key={bIdx} className="space-y-2 min-w-0">
                        {segments.map((s, sIdx) => renderSegment(s, sIdx))}
                      </div>
                    );
                  }

                  return (
                    <div key={bIdx} className="min-w-0">
                      <MarkdownContent text={stripAnsi(block.text)} />
                    </div>
                  );
                }

                if (block.type === "thinking" && block.text) {
                  return <ThinkingBlock key={bIdx} text={block.text} />;
                }

                if (block.type === "tool_use") {
                  const matchedResult = block.id ? (toolResultMap.get(block.id) ?? null) : null;
                  return <ToolCallBlock key={bIdx} toolUse={block} toolResult={matchedResult} />;
                }

                // tool_result blocks rendered inside ToolCallBlock, skip standalone
                return null;
              })}
            </div>
          </div>
        );
      })}
    </div>
  );
}
