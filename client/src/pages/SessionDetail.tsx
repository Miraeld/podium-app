/**
 * @file SessionDetail.tsx
 * @description Displays detailed information about a specific session, including its agents, events, and cost breakdown, with real-time updates and an expandable agent hierarchy view.
 * @author Son Nguyen <hoangson091104@gmail.com>
 */
import { useEffect, useState, useCallback, useMemo, useRef } from "react";
import type { ReactNode } from "react";
import { Link, useParams, useNavigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import {
  ArrowLeft,
  Bot,
  Clock,
  FolderOpen,
  Cpu,
  RefreshCw,
  DollarSign,
  ChevronDown,
  ChevronRight,
  GitBranch,
  MessageSquare,
  List,
  AlertCircle,
  Play,
  ExternalLink,
  AlertTriangle,
  Brain,
  StickyNote,
  Share2,
  Download,
  Link2,
  Check,
  Wrench,
  FileEdit,
} from "lucide-react";
import { api } from "../lib/api";
import { loadAdvancedMetrics } from "../lib/displaySettings";
import { eventBus } from "../lib/eventBus";
import { AgentCard } from "../components/AgentCard";
import { SessionOverview } from "../components/SessionOverview";
import { ConversationView } from "../components/conversation/ConversationView";
import { SessionStatusBadge, AgentStatusBadge } from "../components/StatusBadge";
import { effectiveSessionStatus } from "../lib/types";
import { EventDetail } from "../components/EventDetail";
import {
  EventFilters,
  EMPTY_FILTERS,
  isEmptyFilters,
  expandStatusToEventTypes,
} from "../components/EventFilters";
import type { EventFiltersValue } from "../components/EventFilters";
import { EventFiltersInfo } from "../components/EventFiltersInfo";
import { EventGroupRow } from "../components/EventGroupRow";
import { Skeleton } from "../components/Skeleton";
import {
  agentOriginLabel,
  buildEventTitle,
  buildOriginLabel,
  groupEvents,
  projectFromEvent,
  statusFromEventType,
} from "../lib/event-grouping";
import type { AgentInfo } from "../lib/event-grouping";
import {
  formatDateTime,
  formatDuration,
  fmtCostFull,
  timeAgo,
  formatModelName,
} from "../lib/format";
import type {
  Session,
  Agent,
  DashboardEvent,
  CostResult,
  TranscriptInfo,
} from "../lib/types";

type DetailTab = "agents" | "conversation" | "timeline" | "thinking";

/** A single extended-thinking block extracted from a transcript, with the
 * agent context and timestamp needed to render the Decision-log timeline. */
interface ThinkingEntry {
  transcriptId: string;
  agentLabel: string;
  text: string;
  timestamp: string | null;
}

const EVENTS_INITIAL_BATCH = 50;
const EVENTS_MORE_BATCH = 500;
// Live-refresh bounds — see ActivityFeed for rationale.
const EVENTS_MAX_REFRESH = 500;
const EVENTS_REFRESH_DEBOUNCE_MS = 500;

export function SessionDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { t } = useTranslation("sessions");
  const [session, setSession] = useState<Session | null>(null);
  const [agents, setAgents] = useState<Agent[]>([]);
  const [events, setEvents] = useState<DashboardEvent[]>([]);
  const [eventsTotal, setEventsTotal] = useState(0);
  const [eventsLoadingMore, setEventsLoadingMore] = useState(false);
  const [filters, setFilters] = useState<EventFiltersValue>(EMPTY_FILTERS);
  const [grouped, setGrouped] = useState(true);
  const [cost, setCost] = useState<CostResult | null>(null);
  const [advancedMetrics, setAdvancedMetrics] = useState(loadAdvancedMetrics);

  // Keep advancedMetrics in sync if the user toggles it in Settings while this page is open.
  // 'storage' fires for cross-tab changes; 'podium-settings-changed' fires in the same tab.
  useEffect(() => {
    const handler = () => setAdvancedMetrics(loadAdvancedMetrics());
    window.addEventListener("storage", handler);
    window.addEventListener("podium-settings-changed", handler);
    return () => {
      window.removeEventListener("storage", handler);
      window.removeEventListener("podium-settings-changed", handler);
    };
  }, []);
  const [loading, setLoading] = useState(true);
  // True when this session is currently being driven by an in-flight Run
  // handle on /run. Drives the "Open in Run page" banner up top.
  const [isDashboardRun, setIsDashboardRun] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [expandedAgents, setExpandedAgents] = useState<Set<string>>(() => {
    return new Set<string>();
  });
  const [activeTab, setActiveTab] = useState<DetailTab>("agents");
  // Tracks whether the user has manually picked a tab. Until they do, the smart
  // default below may auto-switch to "conversation" for single-agent sessions.
  const userChangedTab = useRef(false);
  // One-shot guard so the smart default only fires the first time agents load.
  const smartDefaultApplied = useRef(false);
  // Keep tabs mounted once visited so switching between them doesn't unmount/
  // remount their subtrees (which causes a perceptible flash on click).
  const [visitedTabs, setVisitedTabs] = useState<Set<DetailTab>>(() => new Set(["agents"]));
  useEffect(() => {
    setVisitedTabs((prev) => (prev.has(activeTab) ? prev : new Set(prev).add(activeTab)));
  }, [activeTab]);
  const [transcripts, setTranscripts] = useState<TranscriptInfo[]>([]);
  const [pendingTranscriptId, setPendingTranscriptId] = useState<string | null>(null);
  const [transcriptNotFound, setTranscriptNotFound] = useState(false);
  const notFoundTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [expandedEvents, setExpandedEvents] = useState<Set<number>>(() => new Set());

  // Note-taking (localStorage) + share popover UI state.
  const [annotation, setAnnotation] = useState("");
  const [annotationOpen, setAnnotationOpen] = useState(false);
  const annotationTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [shareOpen, setShareOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const [showSummary, setShowSummary] = useState(false);
  const sharePopoverRef = useRef<HTMLDivElement>(null);

  // Wrap setActiveTab so any explicit tab click records intent and clears the
  // transcript-not-found banner consistently across all tab buttons.
  const selectTab = useCallback((tab: DetailTab) => {
    userChangedTab.current = true;
    setTranscriptNotFound(false);
    setActiveTab(tab);
  }, []);

  function toggleEvent(id: number) {
    setExpandedEvents((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  // Refs let the websocket handler access latest state without re-subscribing.
  const eventApiParamsRef = useRef<Record<string, unknown> | null>(null);
  const eventsLoadedCountRef = useRef(0);
  const eventsRefreshTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  eventsLoadedCountRef.current = events.length;
  const goBack = useCallback(() => {
    const historyState =
      typeof window !== "undefined" ? (window.history.state as { idx?: number } | null) : null;
    if ((historyState?.idx ?? 0) > 0) {
      navigate(-1);
      return;
    }
    navigate("/sessions");
  }, [navigate]);

  // Auto-dismiss not-found warning after 8 seconds
  useEffect(() => {
    if (transcriptNotFound) {
      notFoundTimerRef.current = setTimeout(() => setTranscriptNotFound(false), 8000);
      return () => {
        if (notFoundTimerRef.current) clearTimeout(notFoundTimerRef.current);
      };
    }
  }, [transcriptNotFound]);

  // Probe /api/run to see whether THIS session is currently being driven by
  // an in-flight Run handle. If so, surface a banner so the user can hop
  // back to /run instead of viewing this as a passive transcript.
  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    const probe = () => {
      // Defensive: tests mock the api module without a `run` namespace.
      if (!api.run || typeof api.run.list !== "function") return;
      api.run
        .list()
        .then((r) => {
          if (cancelled) return;
          const live = r.items.some(
            (h) => h.sessionId === id && (h.status === "running" || h.status === "spawning")
          );
          setIsDashboardRun(live);
        })
        .catch(() => undefined);
    };
    probe();
    const t = setInterval(probe, 10000);
    const unsub = eventBus.subscribe((msg) => {
      if (msg.type === "run_status") probe();
    });
    return () => {
      cancelled = true;
      clearInterval(t);
      unsub();
    };
  }, [id]);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const [data, costData] = await Promise.all([
        api.sessions.get(id),
        api.pricing.sessionCost(id).catch(() => null),
      ]);
      setSession(data.session);
      setAgents(data.agents);
      setCost(costData);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : t("detail.failedLoad"));
    } finally {
      setLoading(false);
    }
  }, [id, t]);

  useEffect(() => {
    load();
  }, [load]);

  // Smart default tab (Task 1): once agents first resolve, if this session has
  // no subagents (only the main agent, or none), jump to the Conversation tab —
  // but only when the user hasn't already picked a tab, and only once.
  useEffect(() => {
    if (loading || smartDefaultApplied.current) return;
    smartDefaultApplied.current = true;
    if (!userChangedTab.current && agents.length <= 1) {
      setActiveTab("conversation");
    }
  }, [loading, agents.length]);

  // Annotation: load any saved note for this session on mount / id change.
  useEffect(() => {
    if (!id) return;
    try {
      const saved = localStorage.getItem(`podium-annotation-${id}`);
      setAnnotation(saved ?? "");
      setAnnotationOpen(false);
    } catch {
      setAnnotation("");
    }
  }, [id]);

  // Annotation: debounced persist (800ms) to localStorage.
  const onAnnotationChange = useCallback(
    (value: string) => {
      setAnnotation(value);
      if (annotationTimerRef.current) clearTimeout(annotationTimerRef.current);
      annotationTimerRef.current = setTimeout(() => {
        try {
          if (id) localStorage.setItem(`podium-annotation-${id}`, value);
        } catch {
          // Non-fatal: storage may be full or disabled.
        }
      }, 800);
    },
    [id]
  );

  useEffect(() => {
    return () => {
      if (annotationTimerRef.current) clearTimeout(annotationTimerRef.current);
    };
  }, []);

  // Share popover: dismiss on outside click.
  useEffect(() => {
    if (!shareOpen) return;
    const handler = (e: MouseEvent) => {
      if (sharePopoverRef.current && !sharePopoverRef.current.contains(e.target as Node)) {
        setShareOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [shareOpen]);

  // Download the full session export as a JSON attachment.
  const downloadSessionJson = useCallback(async () => {
    if (!session) return;
    try {
      const response = await fetch(`/api/export/session/${session.id}`);
      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `podium-session-${session.id.slice(0, 8)}.json`;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      console.error("Failed to export session:", err);
    } finally {
      setShareOpen(false);
    }
  }, [session]);

  // Copy the current page URL and flash a transient "Copied!" confirmation.
  const copySessionUrl = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(window.location.href);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Clipboard may be blocked (insecure context); fail silently.
    } finally {
      setShareOpen(false);
    }
  }, []);

  // Load transcripts list (for Agent → Conversation navigation ID mapping)
  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    api.sessions
      .transcripts(id)
      .then((result) => {
        if (!cancelled) setTranscripts(result.transcripts);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [id]);

  // Navigate to Conversation tab and select the matching transcript when clicking an agent
  const navigateToAgentConversation = useCallback(
    (agent: Agent) => {
      // Clear any previous not-found warning
      setTranscriptNotFound(false);

      const findTranscriptId = (ts: TranscriptInfo[]): string | null => {
        // 1. Exact match via db_agent_id (most reliable)
        const exactMatch = ts.find((t) => t.db_agent_id === agent.id);
        if (exactMatch) return exactMatch.id;

        // 2. Main agent fallback
        if (agent.type === "main") return "main";

        // 3. Fallback: match by subagent_type or type, then narrow by name
        let candidates = ts.filter((t) => t.type !== "main");
        if (agent.subagent_type) {
          const byType = candidates.filter(
            (t) => t.subagent_type === agent.subagent_type || t.type === agent.subagent_type
          );
          if (byType.length > 0) candidates = byType;
        }
        if (agent.name && candidates.length > 1) {
          const byName = candidates.filter((t) => t.name === agent.name);
          if (byName.length > 0) candidates = byName;
        }
        if (candidates.length === 1) return candidates[0]!.id;

        return null;
      };

      // Always switch to the conversation tab — the user clicked a leaf agent
      // and expects to see its conversation. If no exact transcript match is
      // found, the tab still opens and the not-found banner explains why.
      setActiveTab("conversation");

      const transcriptId = findTranscriptId(transcripts);

      if (transcriptId) {
        setPendingTranscriptId(transcriptId);
      } else if (transcripts.length === 0 && id) {
        // Transcripts not loaded yet — fetch them and retry. The tab is
        // already showing; this just selects the right transcript when ready.
        api.sessions
          .transcripts(id)
          .then((result) => {
            setTranscripts(result.transcripts);
            const freshId = findTranscriptId(result.transcripts);
            if (freshId) {
              setPendingTranscriptId(freshId);
            } else {
              setTranscriptNotFound(true);
            }
          })
          .catch(() => {
            setTranscriptNotFound(true);
          });
      } else {
        // Transcripts are loaded but no specific match for this agent.
        setTranscriptNotFound(true);
      }
    },
    [transcripts, id]
  );

  // Compute compaction labels: "#1", "#2", etc. based on started_at order
  const compactionLabels = useMemo(() => {
    const map = new Map<string, string>();
    const compactions = agents
      .filter((a) => a.subagent_type === "compaction")
      .sort((a, b) => (a.started_at || "").localeCompare(b.started_at || ""));
    compactions.forEach((a, i) => {
      const time = a.started_at
        ? new Date(a.started_at).toLocaleTimeString(undefined, {
            hour: "2-digit",
            minute: "2-digit",
          })
        : "";
      map.set(a.id, `#${i + 1}${time ? ` · ${time}` : ""}`);
    });
    return map;
  }, [agents]);

  // Event list is fetched separately from the session metadata so it can
  // respect the user's filters and use the server-driven pagination. Status
  // presets expand into event_type values and merge with any explicit
  // event_type selection.
  const eventApiParams = useMemo(() => {
    if (!id) return null;
    const statusExpanded = expandStatusToEventTypes(filters.status);
    const eventTypeMerged = Array.from(new Set<string>([...filters.event_type, ...statusExpanded]));
    return {
      session_id: [id],
      event_type: eventTypeMerged.length > 0 ? eventTypeMerged : undefined,
      tool_name: filters.tool_name.length > 0 ? filters.tool_name : undefined,
      agent_id: filters.agent_id.length > 0 ? filters.agent_id : undefined,
      q: filters.q || undefined,
      from: filters.from ? new Date(filters.from).toISOString() : undefined,
      to: filters.to ? new Date(filters.to).toISOString() : undefined,
    };
  }, [id, filters]);

  eventApiParamsRef.current = eventApiParams;

  const eventGroups = useMemo(() => groupEvents(events), [events]);

  // Build an AgentInfo map from the already-fetched agents list so rows can
  // render the subagent pill (subagent_type) without an extra fetch.
  const agentInfoById = useMemo(() => {
    const map = new Map<string, AgentInfo>();
    for (const a of agents) {
      map.set(a.id, {
        type: a.type,
        subagent_type: a.subagent_type,
        name: a.name,
        parent_agent_id: a.parent_agent_id,
      });
    }
    return map;
  }, [agents]);

  // Single-entry session-name lookup so EventDetail can surface the session
  // label above the raw id, mirroring the agentInfoById pattern. Falls back
  // to "Session abcdefgh" when session.name is null/empty so the row always
  // shows *something* identifiable — matches the header's display logic.
  const sessionNameById = useMemo(() => {
    const map = new Map<string, string>();
    if (session?.id) {
      const label = session.name?.trim() || `Session ${session.id.slice(0, 8)}`;
      map.set(session.id, label);
    }
    return map;
  }, [session?.id, session?.name]);

  // Precompute project per event so flat-row rendering doesn't re-parse JSON.
  const projectByEventId = useMemo(() => {
    const map = new Map<number, string | null>();
    for (const e of events) map.set(e.id, projectFromEvent(e));
    return map;
  }, [events]);

  // Error count for the header chip + run summary. Mirrors the timeline's
  // status mapping (statusFromEventType → "error" for error/APIError) and also
  // catches PostToolUse events whose payload reports an error status.
  const errorCount = useMemo(() => {
    let n = 0;
    for (const e of events) {
      if (statusFromEventType(e.event_type) === "error") {
        n++;
        continue;
      }
      // PostToolUse can still represent a failed tool call — detect an error
      // status embedded in the raw payload without a brittle full parse.
      if (e.event_type === "PostToolUse" && e.data && /"is_error"\s*:\s*true/.test(e.data)) {
        n++;
      }
    }
    return n;
  }, [events]);

  // Run-summary stats (only meaningful once the session has finished).
  const toolCallCount = useMemo(
    () => events.filter((e) => e.event_type === "PreToolUse").length,
    [events]
  );

  // Unique files touched by Edit / Write tool calls. The file path usually
  // lives in the event summary (e.g. "Write path/to/file"); we pull the first
  // path-like token out of it as a best-effort.
  const filesChangedCount = useMemo(() => {
    const files = new Set<string>();
    for (const e of events) {
      if (e.event_type !== "PreToolUse") continue;
      const tool = e.tool_name || "";
      if (tool !== "Edit" && tool !== "Write" && tool !== "MultiEdit") continue;
      const summary = e.summary || "";
      const match = summary.match(/(\/[^\s"]+|[\w.-]+\/[^\s"]+|[\w.-]+\.[A-Za-z0-9]+)/);
      if (match) files.add(match[0]!);
    }
    return files.size;
  }, [events]);

  const loadEvents = useCallback(async () => {
    if (!eventApiParams) return;
    try {
      const { events: data, total } = await api.events.list({
        ...eventApiParams,
        limit: EVENTS_INITIAL_BATCH,
        offset: 0,
      });
      setEvents(data);
      setEventsTotal(total);
    } catch (err) {
      console.error("Failed to load session events:", err);
    }
  }, [eventApiParams]);

  useEffect(() => {
    loadEvents();
  }, [loadEvents]);

  const loadMoreEvents = useCallback(async () => {
    if (!eventApiParams) return;
    setEventsLoadingMore(true);
    try {
      const { events: data, total } = await api.events.list({
        ...eventApiParams,
        limit: EVENTS_MORE_BATCH,
        offset: events.length,
      });
      setEvents((prev) => [...prev, ...data]);
      setEventsTotal(total);
    } catch (err) {
      console.error("Failed to load more session events:", err);
    } finally {
      setEventsLoadingMore(false);
    }
  }, [eventApiParams, events.length]);
  // Auto-expand agents that have working subagents (at any depth)
  useEffect(() => {
    const parentsWithActiveChildren = new Set<string>();
    for (const a of agents) {
      if (a.parent_agent_id && a.status === "working") {
        parentsWithActiveChildren.add(a.parent_agent_id);
      }
    }
    if (parentsWithActiveChildren.size > 0) {
      const agentMap = new Map(agents.map((a) => [a.id, a]));
      const toExpand = new Set<string>();
      for (const pid of parentsWithActiveChildren) {
        let cur = pid;
        while (cur) {
          toExpand.add(cur);
          const parent = agentMap.get(cur);
          cur = parent?.parent_agent_id ?? "";
        }
      }
      setExpandedAgents((prev) => new Set([...prev, ...toExpand]));
    }
  }, [agents]);

  // Pagination-preserving filtered refresh, mirrors ActivityFeed's behavior.
  const refreshEventsWithPagination = useCallback(async () => {
    const params = eventApiParamsRef.current;
    if (!params) return;
    const target = Math.max(
      eventsLoadedCountRef.current || EVENTS_INITIAL_BATCH,
      EVENTS_INITIAL_BATCH
    );
    const size = Math.min(target, EVENTS_MAX_REFRESH);
    try {
      const { events: data, total } = await api.events.list({
        ...params,
        limit: size,
        offset: 0,
      });
      setEvents(data);
      setEventsTotal(total);
    } catch (err) {
      console.error("Failed to refresh session events:", err);
    }
  }, []);

  useEffect(() => {
    const unsubscribe = eventBus.subscribe((msg) => {
      if (
        msg.type === "agent_created" ||
        msg.type === "agent_updated" ||
        msg.type === "session_updated"
      ) {
        load();
      }
      if (msg.type === "new_event") {
        // Debounce bursts into one filter-aware refetch that preserves the
        // current "Load more" pagination size.
        if (eventsRefreshTimerRef.current) clearTimeout(eventsRefreshTimerRef.current);
        eventsRefreshTimerRef.current = setTimeout(() => {
          eventsRefreshTimerRef.current = null;
          refreshEventsWithPagination();
        }, EVENTS_REFRESH_DEBOUNCE_MS);
      }
    });
    return () => {
      unsubscribe();
      if (eventsRefreshTimerRef.current) {
        clearTimeout(eventsRefreshTimerRef.current);
        eventsRefreshTimerRef.current = null;
      }
    };
  }, [load, refreshEventsWithPagination]);

  if (loading) {
    return (
      <div className="animate-fade-in space-y-8" aria-busy="true">
        <div className="flex items-start gap-4">
          <Skeleton className="w-8 h-8" rounded="md" />
          <div className="flex-1 space-y-3">
            <div className="flex items-center gap-3">
              <Skeleton className="h-6 w-64" />
              <Skeleton className="h-5 w-16" rounded="full" />
            </div>
            <div className="flex flex-wrap gap-3">
              <Skeleton className="h-5 w-40" />
              <Skeleton className="h-5 w-32" />
              <Skeleton className="h-5 w-24" />
            </div>
          </div>
        </div>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {Array.from({ length: 4 }).map((_, i) => (
            <div key={i} className="card p-5 space-y-2">
              <Skeleton className="h-3 w-20" />
              <Skeleton className="h-7 w-24" />
            </div>
          ))}
        </div>
        {Array.from({ length: 2 }).map((_, i) => (
          <div key={i} className="card p-5 space-y-3">
            <Skeleton className="h-4 w-40" />
            <Skeleton className="h-3 w-full" />
            <Skeleton className="h-3 w-11/12" />
            <Skeleton className="h-3 w-5/6" />
          </div>
        ))}
      </div>
    );
  }

  if (error || !session) {
    return (
      <div className="text-center py-20">
        <p className="text-red-700 dark:text-red-400 mb-2">{error || t("detail.notFound")}</p>
        <button onClick={goBack} className="btn-ghost mt-4">
          <ArrowLeft className="w-4 h-4" /> {t("detail.backToSessions")}
        </button>
      </div>
    );
  }

  return (
    <div className="animate-fade-in space-y-8">
      {/* Header */}
      <div className="flex items-start gap-4">
        <button onClick={goBack} className="btn-ghost mt-1">
          <ArrowLeft className="w-4 h-4" />
        </button>
        <div className="flex-1">
          <div className="flex items-center gap-3 mb-2">
            <h2 className="text-xl font-bold text-gray-900 dark:text-white">
              {session.name || `${t("defaultName")}${session.id.slice(0, 8)}`}
            </h2>
            <SessionStatusBadge status={effectiveSessionStatus(session)} />
            {errorCount > 0 && (
              <button
                type="button"
                onClick={() => {
                  selectTab("timeline");
                  setFilters({ ...EMPTY_FILTERS, status: ["error", "failed"] });
                }}
                title="Jump to the timeline filtered to errors"
                className="inline-flex items-center gap-1 bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400 border border-red-200 dark:border-red-800 px-2 py-0.5 rounded-full text-xs font-medium hover:bg-red-200 dark:hover:bg-red-900/50 transition-colors cursor-pointer"
              >
                <AlertTriangle className="w-3 h-3" />
                {errorCount} {errorCount === 1 ? "error" : "errors"}
              </button>
            )}
          </div>
          <div className="flex flex-wrap items-center gap-x-4 gap-y-1 mt-1">
            <span className="inline-flex items-center gap-1.5 text-sm text-gray-600 dark:text-gray-500 font-mono bg-surface-2 px-2 py-1 rounded">
              {session.id.slice(0, 16)}
            </span>
            {session.model && (
              <span className="inline-flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-400 bg-surface-2 px-2 py-1 rounded">
                <Cpu className="w-3 h-3 text-gray-700 dark:text-gray-500" />
                {formatModelName(session.model)}
              </span>
            )}
            <span className="inline-flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-400 bg-surface-2 px-2 py-1 rounded">
              <Clock className="w-3 h-3 text-gray-700 dark:text-gray-500" />
              {formatDateTime(session.started_at)}
              {session.ended_at && (
                <span className="text-gray-700 dark:text-gray-500 ml-1">
                  ({formatDuration(session.started_at, session.ended_at)})
                </span>
              )}
            </span>
            {advancedMetrics && cost && cost.total_cost > 0 && (
              <span className="inline-flex items-center gap-1.5 text-xs font-medium text-emerald-700 dark:text-emerald-400 bg-emerald-50 dark:bg-emerald-500/10 px-2 py-1 rounded">
                <DollarSign className="w-3 h-3" />
                {fmtCostFull(cost.total_cost).slice(1)}
              </span>
            )}
          </div>
          {session.cwd && (
            <div className="flex items-center gap-1.5 text-sm text-gray-600 dark:text-gray-500 mt-2">
              <FolderOpen className="w-3 h-3 flex-shrink-0" />
              <span className="font-mono truncate">{session.cwd}</span>
            </div>
          )}

          {/* Collapsed annotation preview — one click reopens the editor. */}
          {!annotationOpen && annotation.trim() && (
            <button
              type="button"
              onClick={() => setAnnotationOpen(true)}
              className="flex items-start gap-1.5 text-sm text-amber-800 dark:text-amber-200/80 mt-2 text-left hover:text-amber-900 dark:hover:text-amber-100 transition-colors"
              title="Edit note"
            >
              <StickyNote className="w-3.5 h-3.5 flex-shrink-0 mt-0.5 text-amber-500" />
              <span className="italic truncate">{annotation.trim().slice(0, 80)}</span>
            </button>
          )}

          {/* Expanded annotation editor — warm sticky-note tint. */}
          {annotationOpen && (
            <div className="mt-3 rounded-lg border border-amber-200 dark:border-amber-500/30 bg-amber-50 dark:bg-amber-500/10 p-2.5">
              <div className="flex items-center gap-1.5 mb-1.5 text-[11px] font-medium uppercase tracking-wider text-amber-700 dark:text-amber-300/80">
                <StickyNote className="w-3.5 h-3.5" />
                Note
                <button
                  type="button"
                  onClick={() => setAnnotationOpen(false)}
                  className="ml-auto text-amber-600 dark:text-amber-400/70 hover:text-amber-800 dark:hover:text-amber-200 transition-colors normal-case font-normal"
                >
                  Hide
                </button>
              </div>
              <textarea
                rows={2}
                value={annotation}
                onChange={(e) => onAnnotationChange(e.target.value)}
                placeholder="Add a note about this session..."
                className="w-full resize-y bg-transparent text-sm text-amber-900 dark:text-amber-100 placeholder-amber-500/60 dark:placeholder-amber-300/40 focus:outline-none"
              />
            </div>
          )}
        </div>

        {/* Header actions: note · share · refresh */}
        <div className="flex items-center gap-1 flex-shrink-0">
          <button
            onClick={() => setAnnotationOpen((v) => !v)}
            className="btn-ghost"
            title={annotationOpen ? "Hide note" : "Add a note"}
            aria-label="Toggle session note"
          >
            <StickyNote className="w-4 h-4" />
          </button>

          <div className="relative" ref={sharePopoverRef}>
            <button
              onClick={() => setShareOpen((v) => !v)}
              className="btn-ghost"
              title="Share or export"
              aria-haspopup="menu"
              aria-expanded={shareOpen}
            >
              <Share2 className="w-4 h-4" />
            </button>
            {shareOpen && (
              <div
                role="menu"
                className="absolute right-0 mt-1 z-30 min-w-[220px] bg-white dark:bg-surface-1 border border-gray-200 dark:border-border rounded-lg shadow-xl p-1.5"
              >
                <button
                  type="button"
                  role="menuitem"
                  onClick={downloadSessionJson}
                  className="w-full flex items-center gap-2 px-2.5 py-1.5 text-sm text-gray-700 dark:text-gray-300 rounded-md hover:bg-gray-100 dark:hover:bg-surface-3 transition-colors text-left"
                >
                  <Download className="w-3.5 h-3.5 flex-shrink-0" />
                  Download session JSON
                </button>
                <button
                  type="button"
                  role="menuitem"
                  onClick={copySessionUrl}
                  className="w-full flex items-center gap-2 px-2.5 py-1.5 text-sm text-gray-700 dark:text-gray-300 rounded-md hover:bg-gray-100 dark:hover:bg-surface-3 transition-colors text-left"
                >
                  {copied ? (
                    <Check className="w-3.5 h-3.5 flex-shrink-0 text-emerald-500" />
                  ) : (
                    <Link2 className="w-3.5 h-3.5 flex-shrink-0" />
                  )}
                  {copied ? "Copied!" : "Copy session URL"}
                </button>
              </div>
            )}
          </div>

          <button onClick={load} className="btn-ghost" title="Refresh">
            <RefreshCw className="w-4 h-4" />
          </button>
        </div>
      </div>

      {isDashboardRun && (
        <Link
          to={`/run?session=${encodeURIComponent(id || "")}`}
          className="flex items-center gap-3 rounded-lg border border-emerald-200 dark:border-emerald-500/30 bg-emerald-500/[0.06] hover:bg-emerald-500/[0.12] hover:border-emerald-500/50 px-4 py-2.5 transition-colors group"
        >
          <span className="w-7 h-7 rounded-md bg-emerald-50 dark:bg-emerald-500/15 border border-emerald-200 dark:border-emerald-500/30 inline-flex items-center justify-center flex-shrink-0">
            <Play className="w-3.5 h-3.5 text-emerald-700 dark:text-emerald-300" />
          </span>
          <div className="flex-1 min-w-0">
            <div className="text-sm font-medium text-emerald-800 dark:text-emerald-200">
              {t("detail.dashboardRun.title", "This session is being driven from the Run page")}
            </div>
            <div className="text-[11px] text-emerald-700 dark:text-emerald-400/70">
              {t(
                "detail.dashboardRun.body",
                "Send follow-ups, watch streaming output, or stop the run from there."
              )}
            </div>
          </div>
          <ExternalLink className="w-4 h-4 text-emerald-700 dark:text-emerald-300/70 group-hover:text-emerald-200 flex-shrink-0" />
        </Link>
      )}

      {/* Run Summary card (Task 4) — only for finished sessions, collapsed by default. */}
      {(session.status === "completed" || session.status === "error") && (
        <div className="card p-4">
          <button
            type="button"
            onClick={() => setShowSummary((v) => !v)}
            className="w-full flex items-center gap-2 text-sm font-medium text-gray-700 dark:text-gray-200"
            aria-expanded={showSummary}
          >
            {showSummary ? (
              <ChevronDown className="w-4 h-4 text-gray-500" />
            ) : (
              <ChevronRight className="w-4 h-4 text-gray-500" />
            )}
            <span>Run summary</span>
            <span className="ml-auto text-[11px] font-normal text-gray-500 dark:text-gray-400">
              {showSummary ? "Hide" : "View summary"}
            </span>
          </button>
          {showSummary && (
            <div className="mt-4 grid grid-cols-2 sm:grid-cols-3 gap-3">
              <SummaryPill
                icon={<DollarSign className="w-4 h-4 text-emerald-500" />}
                label="Cost"
                value={cost && cost.total_cost > 0 ? fmtCostFull(cost.total_cost) : "—"}
              />
              <SummaryPill
                icon={<Clock className="w-4 h-4 text-sky-500" />}
                label="Duration"
                value={
                  session.ended_at
                    ? formatDuration(session.started_at, session.ended_at)
                    : "—"
                }
              />
              <SummaryPill
                icon={<Bot className="w-4 h-4 text-accent" />}
                label="Agents"
                value={`${agents.length} ${agents.length === 1 ? "agent" : "agents"}`}
              />
              <SummaryPill
                icon={<Wrench className="w-4 h-4 text-indigo-500" />}
                label="Tool calls"
                value={toolCallCount.toLocaleString()}
              />
              <SummaryPill
                icon={
                  <AlertTriangle
                    className={`w-4 h-4 ${errorCount > 0 ? "text-red-500" : "text-gray-400"}`}
                  />
                }
                label="Errors"
                value={errorCount.toLocaleString()}
              />
              <SummaryPill
                icon={<FileEdit className="w-4 h-4 text-amber-500" />}
                label="Files changed"
                value={filesChangedCount.toLocaleString()}
              />
            </div>
          )}
        </div>
      )}

      {/* Tab Navigation */}
      <div className="flex items-center gap-1 border-b border-border">
        <button
          onClick={() => selectTab("agents")}
          className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
            activeTab === "agents"
              ? "border-accent text-gray-900 dark:text-accent font-semibold"
              : "border-transparent text-gray-700 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300"
          }`}
        >
          <Bot className="w-4 h-4" />
          {t("detail.agents")} ({agents.length})
        </button>
        <button
          onClick={() => selectTab("conversation")}
          className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
            activeTab === "conversation"
              ? "border-accent text-gray-900 dark:text-accent font-semibold"
              : "border-transparent text-gray-700 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300"
          }`}
        >
          <MessageSquare className="w-4 h-4" />
          Conversation
        </button>
        <button
          onClick={() => selectTab("thinking")}
          className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
            activeTab === "thinking"
              ? "border-accent text-gray-900 dark:text-accent font-semibold"
              : "border-transparent text-gray-700 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300"
          }`}
        >
          <Brain className="w-4 h-4" />
          Thinking
        </button>
        <button
          onClick={() => selectTab("timeline")}
          className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
            activeTab === "timeline"
              ? "border-accent text-gray-900 dark:text-accent font-semibold"
              : "border-transparent text-gray-700 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300"
          }`}
        >
          <List className="w-4 h-4" />
          Timeline ({events.length}/{eventsTotal})
        </button>
      </div>

      {/* Tab Content */}
      {transcriptNotFound && (
        <div className="flex items-center gap-2 px-4 py-2.5 mb-3 text-sm text-amber-700 dark:text-amber-400 bg-amber-50 dark:bg-amber-500/10 border border-amber-200 dark:border-amber-500/20 rounded-lg">
          <AlertCircle className="w-4 h-4 flex-shrink-0" />
          <span>
            Conversation transcript not found for this agent. The transcript file may be missing or
            not yet linked.
          </span>
          <button
            onClick={() => setTranscriptNotFound(false)}
            className="ml-auto text-amber-700 dark:text-amber-400/60 hover:text-amber-400 transition-colors"
          >
            <List className="w-3.5 h-3.5" />
          </button>
        </div>
      )}

      {visitedTabs.has("agents") && (
        <div hidden={activeTab !== "agents"}>
          <SessionOverview session={session} agents={agents}>
            {agents.length === 0 ? (
              <p className="text-sm text-gray-700 dark:text-gray-500">{t("detail.noAgents")}</p>
            ) : (
              <>
                <h3 className="text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400 border-l-2 border-amber-400/60 dark:border-accent/60 pl-2.5 mb-3 flex items-center gap-1.5">
                  <Bot className="w-3.5 h-3.5 text-amber-700 dark:text-accent" />
                  {t("detail.agents")}
                  <span className="text-gray-400 dark:text-gray-500 font-mono">· {agents.length}</span>
                </h3>
                <div className="space-y-2" data-testid="agent-tree">
                {(() => {
                  // Build parent→children map for the full tree (works at any depth)
                  const agentMap = new Map(agents.map((a) => [a.id, a]));
                  const childrenByParent = new Map<string, Agent[]>();
                  const rootAgents: Agent[] = [];
                  for (const a of agents) {
                    if (a.parent_agent_id && agentMap.has(a.parent_agent_id)) {
                      const list = childrenByParent.get(a.parent_agent_id) || [];
                      list.push(a);
                      childrenByParent.set(a.parent_agent_id, list);
                    } else if (!a.parent_agent_id || !agentMap.has(a.parent_agent_id)) {
                      rootAgents.push(a);
                    }
                  }
                  // Sort roots and children by started_at ascending (chronological order)
                  rootAgents.sort((a, b) => (a.started_at || "").localeCompare(b.started_at || ""));
                  for (const key of childrenByParent.keys()) {
                    childrenByParent
                      .get(key)!
                      .sort((a, b) => (a.started_at || "").localeCompare(b.started_at || ""));
                  }

                  // Count all descendants (recursive) for collapsed badge
                  function countDescendants(id: string): number {
                    const kids = childrenByParent.get(id) || [];
                    return kids.reduce((sum, k) => sum + 1 + countDescendants(k.id), 0);
                  }

                  // Recursive agent node renderer
                  function renderAgentNode(agent: Agent, depth: number) {
                    const children = childrenByParent.get(agent.id) || [];
                    const isExpanded = expandedAgents.has(agent.id);
                    const hasChildren = children.length > 0;
                    const isSubagent = depth > 0;
                    const totalDesc = hasChildren ? countDescendants(agent.id) : 0;
                    const toggleExpanded = () =>
                      setExpandedAgents((prev) => {
                        const next = new Set(prev);
                        if (next.has(agent.id)) next.delete(agent.id);
                        else next.add(agent.id);
                        return next;
                      });

                    return (
                      <div key={agent.id}>
                        <div className="flex items-center gap-1 min-w-0">
                          {hasChildren && (
                            <button
                              onClick={toggleExpanded}
                              className="p-1 text-gray-700 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300 transition-colors flex-shrink-0"
                              aria-label={isExpanded ? "Collapse subagents" : "Expand subagents"}
                              aria-expanded={isExpanded}
                            >
                              {isExpanded ? (
                                <ChevronDown className="w-4 h-4" />
                              ) : (
                                <ChevronRight className="w-4 h-4" />
                              )}
                            </button>
                          )}
                          {isSubagent && !hasChildren && <span className="w-6 flex-shrink-0" />}
                          {isSubagent && (
                            <GitBranch className="w-3 h-3 text-accent flex-shrink-0" />
                          )}
                          <div className="flex-1 min-w-0">
                            <AgentCard
                              agent={agent}
                              session={session ?? undefined}
                              label={compactionLabels.get(agent.id)}
                              isLeaf={!hasChildren}
                              onClick={
                                hasChildren
                                  ? toggleExpanded
                                  : () => navigateToAgentConversation(agent)
                              }
                            />
                          </div>
                        </div>

                        {/* Recursive children (collapsible) */}
                        {hasChildren && isExpanded && (
                          <div className="ml-6 mt-1 space-y-1 border-l-2 border-accent/30 dark:border-accent/20 pl-3">
                            {children.map((child) => renderAgentNode(child, depth + 1))}
                          </div>
                        )}

                        {/* Descendant count badge when collapsed */}
                        {hasChildren && !isExpanded && (
                          <button
                            onClick={() =>
                              setExpandedAgents((prev) => new Set([...prev, agent.id]))
                            }
                            className="ml-7 mt-1 text-[11px] font-medium text-amber-700 dark:text-accent hover:text-amber-800 dark:hover:text-accent-hover transition-colors"
                          >
                            {t("common:subagent_label", { count: totalDesc })}
                          </button>
                        )}
                      </div>
                    );
                  }

                  // Separate true orphans (subagent whose parent_agent_id references a missing agent)
                  const orphans = rootAgents.filter(
                    (a) =>
                      a.type === "subagent" && a.parent_agent_id && !agentMap.has(a.parent_agent_id)
                  );
                  const roots = rootAgents.filter(
                    (a) =>
                      !(
                        a.type === "subagent" &&
                        a.parent_agent_id &&
                        !agentMap.has(a.parent_agent_id)
                      )
                  );

                  return (
                    <>
                      {roots.map((agent) => renderAgentNode(agent, 0))}

                      {/* Orphaned subagents */}
                      {orphans.length > 0 && (
                        <div className="mt-4">
                          <p className="text-[11px] text-gray-700 dark:text-gray-500 mb-2 uppercase tracking-wider">
                            {t("detail.unparented")}
                          </p>
                          <div className="space-y-1">
                            {orphans.map((agent) => renderAgentNode(agent, 1))}
                          </div>
                        </div>
                      )}
                    </>
                  );
                })()}
                </div>
              </>
            )}
          </SessionOverview>

          {/* Cost Breakdown — shown under Agents tab, hidden without advanced metrics */}
          {advancedMetrics && cost && cost.breakdown.length > 0 && cost.total_cost > 0 && (
            <div className="mt-8">
              <h3 className="text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400 border-l-2 border-amber-400/60 dark:border-accent/60 pl-2.5 mb-4 flex items-center gap-1.5">
                <DollarSign className="w-3.5 h-3.5 text-emerald-700 dark:text-emerald-400" />
                {t("detail.costBreakdown")}
              </h3>
              <div className="card overflow-x-auto">
                <table className="w-full min-w-[600px]">
                  <thead>
                    <tr className="border-b border-gray-100 dark:border-border text-left bg-gray-50/50 dark:bg-transparent">
                      <th className="px-5 py-2.5 text-[11px] font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                        {t("common:cost.model")}
                      </th>
                      <th className="px-5 py-2.5 text-[11px] font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider text-right">
                        {t("common:token.input")}
                      </th>
                      <th className="px-5 py-2.5 text-[11px] font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider text-right">
                        {t("common:token.output")}
                      </th>
                      <th className="px-5 py-2.5 text-[11px] font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider text-right">
                        {t("common:token.cacheRead")}
                      </th>
                      <th className="px-5 py-2.5 text-[11px] font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider text-right">
                        {t("common:token.cacheWrite")}
                      </th>
                      <th className="px-5 py-2.5 text-[11px] font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider text-right">
                        {t("common:cost.cost")}
                      </th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-100 dark:divide-border">
                    {cost.breakdown.map((row) => (
                      <tr key={row.model} className="hover:bg-gray-50 dark:hover:bg-surface-3 transition-colors">
                        <td className="px-5 py-2.5 text-sm font-mono text-gray-600 dark:text-gray-300">
                          {formatModelName(row.model)}
                        </td>
                        <td className="px-5 py-2.5 text-sm text-gray-600 dark:text-gray-400 text-right font-mono">
                          {row.input_tokens.toLocaleString()}
                        </td>
                        <td className="px-5 py-2.5 text-sm text-gray-600 dark:text-gray-400 text-right font-mono">
                          {row.output_tokens.toLocaleString()}
                        </td>
                        <td className="px-5 py-2.5 text-sm text-gray-600 dark:text-gray-400 text-right font-mono">
                          {row.cache_read_tokens.toLocaleString()}
                        </td>
                        <td className="px-5 py-2.5 text-sm text-gray-600 dark:text-gray-400 text-right font-mono">
                          {row.cache_write_tokens.toLocaleString()}
                        </td>
                        <td className="px-5 py-2.5 text-sm text-emerald-700 dark:text-emerald-400 text-right font-mono font-medium">
                          {fmtCostFull(row.cost, 4)}
                        </td>
                      </tr>
                    ))}
                    <tr className="bg-surface-2">
                      <td className="px-5 py-2.5 text-sm font-medium text-gray-700 dark:text-gray-200" colSpan={5}>
                        {t("common:total")}
                      </td>
                      <td className="px-5 py-2.5 text-sm text-emerald-700 dark:text-emerald-400 text-right font-mono font-semibold">
                        {fmtCostFull(cost.total_cost, 4)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>
      )}

      {visitedTabs.has("conversation") && (
        <div hidden={activeTab !== "conversation"}>
          <ConversationView sessionId={session.id} initialTranscriptId={pendingTranscriptId} />
        </div>
      )}

      {visitedTabs.has("thinking") && (
        <div hidden={activeTab !== "thinking"}>
          <ThinkingTab sessionId={session.id} onSeeContext={() => selectTab("conversation")} />
        </div>
      )}

      {visitedTabs.has("timeline") && (
        <div hidden={activeTab !== "timeline"}>
          <div className="mb-3">
            <EventFiltersInfo />
          </div>
          <div className="mb-3">
            <EventFilters
              value={filters}
              onChange={setFilters}
              hideSessionFilter
              agentOptions={agents.map((a) => ({ id: a.id, label: a.name || a.id }))}
            />
          </div>
          <div className="flex items-center gap-2 mb-3 px-1">
            <div
              role="group"
              aria-label="view mode"
              className="inline-flex rounded-md border border-border overflow-hidden"
            >
              <button
                type="button"
                onClick={() => setGrouped(true)}
                aria-pressed={grouped}
                className={`text-[11px] px-3 py-1 cursor-pointer transition-colors ${
                  grouped
                    ? "bg-accent/20 text-amber-700 dark:bg-accent/20 dark:text-accent font-medium"
                    : "bg-surface-2 text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-gray-200"
                }`}
              >
                {t("common:eventFilters.grouped")}
              </button>
              <button
                type="button"
                onClick={() => setGrouped(false)}
                aria-pressed={!grouped}
                className={`text-[11px] px-3 py-1 border-l border-border cursor-pointer transition-colors ${
                  !grouped
                    ? "bg-accent/20 text-amber-700 dark:bg-accent/20 dark:text-accent font-medium"
                    : "bg-surface-2 text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-gray-200"
                }`}
              >
                {t("common:eventFilters.flat")}
              </button>
            </div>
          </div>
          {events.length === 0 ? (
            <p className="text-sm text-gray-700 dark:text-gray-500">
              {isEmptyFilters(filters) ? t("detail.noEvents") : t("common:eventFilters.noResults")}
            </p>
          ) : (
            <div className="card overflow-hidden">
              <div className="divide-y divide-border max-h-[600px] overflow-y-auto overflow-x-auto">
                {grouped
                  ? eventGroups.map((group) => (
                      <EventGroupRow
                        key={group.key}
                        group={group}
                        agentInfoById={agentInfoById}
                        sessionNameById={sessionNameById}
                      />
                    ))
                  : events.map((event, i) => {
                      const key = event.id ?? i;
                      const isOpen = event.id != null && expandedEvents.has(event.id);
                      return (
                        <div key={key}>
                          <button
                            type="button"
                            onClick={() => event.id != null && toggleEvent(event.id)}
                            aria-expanded={isOpen}
                            aria-label={
                              isOpen
                                ? t("common:eventDetail.collapse")
                                : t("common:eventDetail.expand")
                            }
                            className="w-full text-left px-5 py-3 flex items-center gap-4 hover:bg-gray-50 dark:hover:bg-surface-3 transition-colors min-w-0 cursor-pointer"
                          >
                            <span
                              className={`text-gray-700 dark:text-gray-500 text-[10px] w-3 flex-shrink-0 transition-transform ${isOpen ? "rotate-90" : ""}`}
                              aria-hidden="true"
                            >
                              ▶
                            </span>
                            <div className="w-16 text-[11px] text-gray-600 font-mono flex-shrink-0">
                              {timeAgo(event.created_at)}
                            </div>
                            <AgentStatusBadge status={statusFromEventType(event.event_type)} />
                            {(() => {
                              // Session is implicit on this page — project is
                              // still shown so the row identifies the working
                              // directory when you share / search.
                              const project = projectByEventId.get(event.id) ?? null;
                              const origin = buildOriginLabel(
                                project,
                                null,
                                agentOriginLabel(event.agent_id, agentInfoById)
                              );
                              return (
                                <span className="text-sm text-gray-600 dark:text-gray-300 flex-1 truncate">
                                  {origin && (
                                    <span
                                      className="text-gray-700 dark:text-gray-500 mr-1"
                                      title={event.agent_id ?? undefined}
                                    >
                                      {origin} ·
                                    </span>
                                  )}
                                  {buildEventTitle(event)}
                                </span>
                              );
                            })()}
                            {event.tool_name && (
                              <span className="text-[11px] px-2 py-0.5 bg-surface-2 rounded text-gray-700 dark:text-gray-500 font-mono">
                                {event.tool_name}
                              </span>
                            )}
                          </button>
                          {isOpen && (
                            <EventDetail
                              event={event}
                              agentInfoById={agentInfoById}
                              sessionNameById={sessionNameById}
                            />
                          )}
                        </div>
                      );
                    })}
              </div>
            </div>
          )}
          {events.length < eventsTotal && (
            <div className="flex items-center justify-between mt-3 px-1">
              <span className="text-sm text-gray-600 dark:text-gray-500">
                {t("common:eventFilters.showing", { shown: events.length, total: eventsTotal })}
              </span>
              <button
                type="button"
                onClick={loadMoreEvents}
                disabled={eventsLoadingMore}
                className="px-3 py-1.5 text-xs font-medium rounded-md bg-accent/20 dark:bg-accent/15 text-amber-700 dark:text-accent hover:bg-accent/30 dark:hover:bg-accent/25 disabled:opacity-40 disabled:cursor-not-allowed transition-colors cursor-pointer"
              >
                {eventsLoadingMore
                  ? t("common:eventFilters.loading")
                  : t("common:eventFilters.loadMore")}
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

/** Compact stat pill used inside the Run Summary card. */
function SummaryPill({
  icon,
  label,
  value,
}: {
  icon: ReactNode;
  label: string;
  value: string;
}) {
  return (
    <div className="flex items-center gap-2.5 rounded-lg border border-border bg-surface-2 px-3 py-2">
      <span className="flex-shrink-0">{icon}</span>
      <div className="min-w-0">
        <div className="text-[10px] uppercase tracking-wider text-gray-500 dark:text-gray-400">
          {label}
        </div>
        <div className="text-sm font-semibold text-gray-900 dark:text-white truncate">{value}</div>
      </div>
    </div>
  );
}

/**
 * Thinking / Decision-log tab. Fetches every transcript for the session and
 * extracts the extended-thinking blocks into a chronological, agent-grouped
 * timeline. Independent from the Conversation tab's incremental loader — it
 * pulls a bounded batch per transcript on first mount.
 */
const THINKING_PREVIEW_CHARS = 300;
const THINKING_FETCH_LIMIT = 500;

function ThinkingTab({
  sessionId,
  onSeeContext,
}: {
  sessionId: string;
  onSeeContext: () => void;
}) {
  const [entries, setEntries] = useState<ThinkingEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [agentFilter, setAgentFilter] = useState<string>("all");

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setLoading(true);
      try {
        const { transcripts } = await api.sessions.transcripts(sessionId);
        const withTranscript = transcripts.filter((t) => t.has_transcript);
        const results = await Promise.all(
          withTranscript.map(async (info) => {
            try {
              const res = await api.sessions.transcript(sessionId, {
                agent_id: info.id === "main" ? undefined : info.id,
                limit: THINKING_FETCH_LIMIT,
              });
              const out: ThinkingEntry[] = [];
              for (const msg of res.messages) {
                for (const block of msg.content) {
                  if (block.type === "thinking" && block.text) {
                    out.push({
                      transcriptId: info.id,
                      agentLabel: info.name,
                      text: block.text,
                      timestamp: msg.timestamp,
                    });
                  }
                }
              }
              return out;
            } catch {
              return [] as ThinkingEntry[];
            }
          })
        );
        if (cancelled) return;
        const flat = results.flat();
        // Chronological order, undated entries last.
        flat.sort((a, b) => {
          if (!a.timestamp) return 1;
          if (!b.timestamp) return -1;
          return a.timestamp.localeCompare(b.timestamp);
        });
        setEntries(flat);
      } catch {
        if (!cancelled) setEntries([]);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [sessionId]);

  const agentLabels = useMemo(() => {
    const seen = new Set<string>();
    const labels: string[] = [];
    for (const e of entries) {
      if (!seen.has(e.agentLabel)) {
        seen.add(e.agentLabel);
        labels.push(e.agentLabel);
      }
    }
    return labels;
  }, [entries]);

  const visible = useMemo(
    () => (agentFilter === "all" ? entries : entries.filter((e) => e.agentLabel === agentFilter)),
    [entries, agentFilter]
  );

  if (loading) {
    return (
      <div className="flex items-center justify-center py-12 text-gray-700 dark:text-gray-500 text-sm">
        Loading thinking blocks...
      </div>
    );
  }

  if (entries.length === 0) {
    return (
      <div className="mx-auto max-w-md py-12 text-center">
        <Brain className="w-8 h-8 mx-auto text-gray-300 dark:text-gray-600 mb-3" />
        <p className="text-sm text-gray-600 dark:text-gray-400">
          No thinking blocks found in this session. Extended thinking must be enabled when running
          Claude.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      {agentLabels.length > 1 && (
        <div className="flex items-center gap-2">
          <span className="text-[11px] uppercase tracking-wider text-gray-500 dark:text-gray-400">
            Agent
          </span>
          <div className="relative">
            <select
              value={agentFilter}
              onChange={(e) => setAgentFilter(e.target.value)}
              className="appearance-none bg-surface-2 border border-surface-3 rounded-lg px-3 py-1.5 pr-8 text-sm text-gray-700 dark:text-gray-300 focus:outline-none focus:border-accent/50 hover:border-accent/30 cursor-pointer transition-colors"
            >
              <option value="all">All agents ({entries.length})</option>
              {agentLabels.map((label) => (
                <option key={label} value={label}>
                  {label}
                </option>
              ))}
            </select>
            <ChevronDown className="w-3.5 h-3.5 text-gray-500 absolute right-2.5 top-1/2 -translate-y-1/2 pointer-events-none" />
          </div>
        </div>
      )}

      <div className="space-y-3 border-l-2 border-indigo-200 dark:border-indigo-500/20 pl-4">
        {visible.map((entry, i) => (
          <ThinkingEntryRow key={i} entry={entry} onSeeContext={onSeeContext} />
        ))}
      </div>
    </div>
  );
}

/** One entry in the Thinking timeline: agent + time header, preview, expand. */
function ThinkingEntryRow({
  entry,
  onSeeContext,
}: {
  entry: ThinkingEntry;
  onSeeContext: () => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const isLong = entry.text.length > THINKING_PREVIEW_CHARS;
  const preview = isLong ? entry.text.slice(0, THINKING_PREVIEW_CHARS) : entry.text;

  return (
    <div className="relative rounded-lg border border-indigo-200 dark:border-indigo-500/20 bg-indigo-50/50 dark:bg-indigo-500/[0.06] p-3">
      <div className="absolute -left-[1.32rem] top-4 w-2.5 h-2.5 rounded-full bg-indigo-400 dark:bg-indigo-500 ring-2 ring-white dark:ring-surface-1" />
      <div className="flex items-center gap-2 mb-1.5 flex-wrap">
        <Brain className="w-3.5 h-3.5 text-indigo-500 dark:text-indigo-400 flex-shrink-0" />
        <span className="text-xs font-semibold text-indigo-700 dark:text-indigo-300">
          {entry.agentLabel}
        </span>
        {entry.timestamp && (
          <span className="text-[10px] text-gray-500 dark:text-gray-400 font-mono">
            {timeAgo(entry.timestamp)}
          </span>
        )}
        <button
          type="button"
          onClick={onSeeContext}
          className="ml-auto text-[11px] text-indigo-600 dark:text-indigo-400 hover:text-indigo-700 dark:hover:text-indigo-300 transition-colors"
        >
          → See context
        </button>
      </div>
      {expanded ? (
        <div className="overflow-y-auto max-h-[600px]">
          <pre className="whitespace-pre-wrap break-words leading-relaxed text-xs text-indigo-900/80 dark:text-indigo-100/70 font-sans">
            {entry.text}
          </pre>
        </div>
      ) : (
        <p className="whitespace-pre-wrap break-words leading-relaxed text-xs text-indigo-900/80 dark:text-indigo-100/70">
          {preview}
          {isLong && "…"}
        </p>
      )}
      {isLong && (
        <button
          type="button"
          onClick={() => setExpanded((v) => !v)}
          className="mt-1.5 text-[11px] font-medium text-indigo-600 dark:text-indigo-400 hover:text-indigo-700 dark:hover:text-indigo-300 transition-colors"
        >
          {expanded ? "Show less" : "Expand"}
        </button>
      )}
    </div>
  );
}
