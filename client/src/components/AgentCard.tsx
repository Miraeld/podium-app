/**
 * @file AgentCard.tsx
 * @description Defines the AgentCard component that displays a summary of an agent's information, including its name, status, task, current tool, and timestamps. The card is clickable and navigates to the agent's session details when clicked. It also visually distinguishes active agents with a border highlight.
 * @author Gael Robin <robin.gael@gmail.com>
 */
import { useTranslation } from "react-i18next";
import { Bot, GitBranch, Clock, Wrench, Cpu, Coins, MessageSquare } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { AgentStatusBadge } from "./StatusBadge";
import { effectiveAgentStatus, isAgentAwaitingInput } from "../lib/types";
import type { Agent, Session } from "../lib/types";
import { formatDuration, timeAgo, formatModelName, pathBasename, fmtCost } from "../lib/format";

interface AgentCardProps {
  agent: Agent;
  /** Optional session data for richer main-agent rendering (model, cwd,
   *  cost). Subagent display ignores this. When omitted, the card falls
   *  back to the original minimal layout. */
  session?: Session;
  label?: string;
  onClick?: () => void;
  /** When true, the card is a leaf agent (no children). On hover a
   *  MessageSquare icon appears to hint that clicking navigates to the transcript. */
  isLeaf?: boolean;
}

export function AgentCard({ agent, session, label, onClick, isLeaf }: AgentCardProps) {
  const navigate = useNavigate();
  const { t } = useTranslation("kanban");
  const isWaiting = agent.status === "waiting" || isAgentAwaitingInput(agent);
  const status = effectiveAgentStatus(agent);
  const isActive = agent.status === "working";
  const isMain = agent.type === "main";

  // Session-level metadata applies to every card in the session — main and
  // subagents alike. Subtitle differs by type: main uses model+cwd (its
  // auto-generated name carries no info), subagents stick with their
  // subagent_type label (more useful than repeating the session model).
  //
  // For subagents, prefer the model stored in agent.metadata (set at spawn
  // time from the Agent tool's `model` parameter, or from the JSONL transcript).
  // This avoids showing the parent session's model on every subagent card.
  const agentMetadataModel = (() => {
    if (isMain || !agent.metadata) return null;
    try {
      const m = typeof agent.metadata === "string" ? JSON.parse(agent.metadata) : agent.metadata;
      return m?.model ? formatModelName(m.model) : null;
    } catch {
      return null;
    }
  })();
  const model = agentMetadataModel || formatModelName(session?.model);
  const cwdBase = pathBasename(session?.cwd);
  const cost = typeof session?.cost === "number" ? session.cost : 0;

  // Derive the project name. Prefer the session cwd basename; fall back to
  // parsing the auto-generated agent name ("Main Agent — maestro - 4c8d8efd"),
  // pulling the segment between "— " and the final " - {id}".
  const nameProject = (() => {
    const m = agent.name.match(/—\s*(.+?)\s*-\s*[0-9a-f]{6,}\s*$/i);
    return m?.[1] ? m[1].trim() : null;
  })();
  const projectName = cwdBase || nameProject;

  // Primary headline: when the main agent has captured the first user prompt
  // as its task, show that as the readable label. Otherwise fall back to the
  // agent's (auto-generated) name. Subagents keep their existing name display.
  const useTaskAsHeadline = isMain && !!agent.task;
  const headline = useTaskAsHeadline ? (agent.task as string) : agent.name;

  // Subtitle differs by type and headline mode:
  //  - main + task headline: project name only (time/model live in the meta row).
  //  - main + name headline: model · cwd (original behavior).
  //  - subagent: subagent_type label.
  const subtitle = isMain
    ? useTaskAsHeadline
      ? projectName
      : [model, cwdBase].filter(Boolean).join(" · ") || null
    : label || agent.subagent_type;

  function handleClick() {
    if (onClick) {
      onClick();
    } else {
      navigate(`/sessions/${agent.session_id}`);
    }
  }

  return (
    <div
      onClick={handleClick}
      className={`group relative p-4 cursor-pointer overflow-hidden card transition-all duration-200 ${
        isActive
          ? "card-active"
          : isWaiting
            ? "overflow-hidden card-waiting card-hover"
            : "overflow-hidden card-hover"
      }`}
    >
      <div className="flex items-start justify-between gap-2 mb-3 min-w-0">
        <div className="flex items-center gap-2.5 min-w-0 overflow-hidden">
          <div
            className={`w-7 h-7 rounded-md flex items-center justify-center flex-shrink-0 transition-shadow duration-300 ${
              isMain
                ? isActive
                  ? "bg-accent/30 dark:bg-accent/20 text-amber-700 dark:text-accent"
                  : "bg-accent/20 dark:bg-accent/12 text-amber-700 dark:text-accent"
                : "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-700 dark:text-indigo-400"
            } ${isActive && isMain ? "shadow-[0_0_14px_-2px_rgb(var(--accent)/0.6)]" : ""}`}
          >
            {isMain ? <Bot className="w-3.5 h-3.5" /> : <GitBranch className="w-3.5 h-3.5" />}
          </div>
          <div className="min-w-0 overflow-hidden">
            <p
              className={`text-sm truncate ${
                useTaskAsHeadline
                  ? "font-semibold text-gray-900 dark:text-white"
                  : "font-medium text-gray-900 dark:text-gray-100"
              }`}
              title={headline}
            >
              {headline}
            </p>
            {subtitle && (
              <p className="text-[11px] text-gray-500 dark:text-gray-400 truncate">{subtitle}</p>
            )}
          </div>
        </div>
        <AgentStatusBadge status={status} />
      </div>

      {/* When the task is already promoted to the headline (main agent), don't
          repeat it here. Subagents — and main agents without a captured prompt —
          still render the task as a secondary descriptive block. */}
      {agent.task && !useTaskAsHeadline && (
        <p className="text-xs text-gray-600 dark:text-gray-400 mb-3 line-clamp-2 leading-relaxed">{agent.task}</p>
      )}

      <div className="flex items-center gap-3 text-[11px] text-gray-500 dark:text-gray-400 min-w-0 overflow-hidden flex-wrap">
        {isActive && (
          <span
            className="flex items-center gap-1.5 flex-shrink-0 font-semibold text-accent"
            title={t("working", "Working")}
          >
            <span className="relative flex h-2 w-2">
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-accent opacity-60" />
              <span
                className="relative inline-flex rounded-full h-2 w-2 bg-accent"
                style={{ boxShadow: "0 0 6px 1px rgb(var(--accent) / 0.7)" }}
              />
            </span>
            {t("live", "Live")}
          </span>
        )}
        {agent.current_tool && (
          <span className="flex items-center gap-1 flex-shrink-0">
            <Wrench className="w-3 h-3" />
            {agent.current_tool}
          </span>
        )}
        {/* Model badge — shown on every card when no tool is currently
            running (avoids clutter on actively-running agents that already
            display the running tool name). */}
        {model && !agent.current_tool && (
          <span className="flex items-center gap-1 flex-shrink-0">
            <Cpu className="w-3 h-3" />
            {model}
          </span>
        )}
        {cost > 0 && (
          <span className="flex items-center gap-1 flex-shrink-0">
            <Coins className="w-3 h-3" />
            {fmtCost(cost)}
          </span>
        )}
        {agent.ended_at ? (
          <>
            <span className="flex items-center gap-1 flex-shrink-0">
              <Clock className="w-3 h-3" />
              {t("ran")}
              {formatDuration(agent.started_at, agent.ended_at)}
            </span>
            <span className="text-gray-400 dark:text-gray-500 flex-shrink-0">
              {timeAgo(agent.ended_at)}
            </span>
          </>
        ) : (
          <span className="flex items-center gap-1 flex-shrink-0">
            <Clock className="w-3 h-3" />
            {timeAgo(agent.updated_at || agent.started_at)}
          </span>
        )}
        <span className="ml-auto font-mono text-gray-400 dark:text-gray-600 flex-shrink-0">
          {agent.session_id.slice(0, 8)}
        </span>
      </div>

      {/* Leaf-agent affordance: subtle icon visible on hover to signal
          the card navigates to the conversation transcript. */}
      {isLeaf && (
        <span
          className="absolute top-3 right-10 opacity-0 group-hover:opacity-100 transition-opacity duration-150 text-gray-400 dark:text-gray-500"
          title="View conversation"
          aria-hidden="true"
        >
          <MessageSquare className="w-3.5 h-3.5" />
        </span>
      )}
    </div>
  );
}
