/**
 * @file Workflows.tsx
 * @description Accordion-first Workflows page. The two most actionable views —
 * Session Drilldown and Error Propagation — are featured and expanded by default.
 * The remaining historical/aggregate analytics live in a collapsed "Advanced
 * Analytics" group so engineers debugging a specific run aren't forced to scroll
 * past charts they didn't ask for. Heavy chart components are only mounted when
 * their section is expanded, and expand/collapse state persists in localStorage.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import {
  Workflow,
  RefreshCw,
  Download,
  AlertCircle,
  Info,
  Star,
  ChevronDown,
  Crosshair,
  GitBranch,
  Network,
  Share2,
  Cpu,
  Gauge,
  Wrench,
  ScatterChart,
  AlertTriangle,
  Clock,
  Layers,
} from "lucide-react";
import { api } from "../lib/api";
import { eventBus } from "../lib/eventBus";
import type { WorkflowData, WSMessage } from "../lib/types";

import { EmptyState } from "../components/EmptyState";
import { WorkflowStats } from "../components/workflows/WorkflowStats";
import { OrchestrationDAG } from "../components/workflows/OrchestrationDAG";
import { ToolExecutionFlow } from "../components/workflows/ToolExecutionFlow";
import { AgentCollaborationNetwork } from "../components/workflows/AgentCollaborationNetwork";
import { SubagentEffectiveness } from "../components/workflows/SubagentEffectiveness";
import { WorkflowPatterns } from "../components/workflows/WorkflowPatterns";
import { ModelDelegationFlow } from "../components/workflows/ModelDelegationFlow";
import { ErrorPropagationMap } from "../components/workflows/ErrorPropagationMap";
import { ConcurrencyTimeline } from "../components/workflows/ConcurrencyTimeline";
import { SessionComplexityScatter } from "../components/workflows/SessionComplexityScatter";
import { SessionDrillIn } from "../components/workflows/SessionDrillIn";
import { WorkflowRunsPanel } from "../components/workflows/WorkflowRunsPanel";

type StatusFilter = "all" | "active" | "completed";

// ── localStorage persistence for accordion sections ──

const SECTION_KEY_PREFIX = "podium-workflow-section-";

function loadSectionExpanded(sectionId: string, defaultValue: boolean): boolean {
  try {
    const raw = localStorage.getItem(`${SECTION_KEY_PREFIX}${sectionId}`);
    if (raw === null) return defaultValue;
    return raw === "true";
  } catch {
    return defaultValue;
  }
}

function saveSectionExpanded(sectionId: string, expanded: boolean) {
  try {
    localStorage.setItem(`${SECTION_KEY_PREFIX}${sectionId}`, String(expanded));
  } catch {
    /* localStorage unavailable — ignore */
  }
}

/** Section ids, in render order. Primary sections come first. */
const PRIMARY_SECTION_IDS = ["dynamicRuns", "drillIn", "errorPropagation"] as const;
const ADVANCED_SECTION_IDS = [
  "orchestration",
  "concurrency",
  "collaboration",
  "modelDelegation",
  "effectiveness",
  "toolFlow",
  "patterns",
  "complexity",
] as const;
const ALL_SECTION_IDS = [...PRIMARY_SECTION_IDS, ...ADVANCED_SECTION_IDS];

type SectionId = (typeof ALL_SECTION_IDS)[number];

function defaultExpandedFor(id: SectionId): boolean {
  return (PRIMARY_SECTION_IDS as readonly string[]).includes(id);
}

export function Workflows() {
  const { t } = useTranslation("workflows");
  const [data, setData] = useState<WorkflowData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedNode, setSelectedNode] = useState<string | null>(null);
  const [selectedSessionId, setSelectedSessionId] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);

  // Per-section expanded state, seeded from localStorage with primary sections
  // defaulting to expanded and advanced sections to collapsed.
  const [expanded, setExpanded] = useState<Record<SectionId, boolean>>(() => {
    const init = {} as Record<SectionId, boolean>;
    for (const id of ALL_SECTION_IDS) {
      init[id] = loadSectionExpanded(id, defaultExpandedFor(id));
    }
    return init;
  });

  const toggleSection = useCallback((id: SectionId) => {
    setExpanded((prev) => {
      const next = { ...prev, [id]: !prev[id] };
      saveSectionExpanded(id, next[id]);
      return next;
    });
  }, []);

  const setAllExpanded = useCallback((value: boolean) => {
    setExpanded(() => {
      const next = {} as Record<SectionId, boolean>;
      for (const id of ALL_SECTION_IDS) {
        next[id] = value;
        saveSectionExpanded(id, value);
      }
      return next;
    });
  }, []);

  const fetchData = useCallback(async () => {
    try {
      setError(null);
      const result = await api.workflows.get(statusFilter);
      setData(result);
      setLastUpdated(new Date());
    } catch (err) {
      setError(err instanceof Error ? err.message : t("failedLoad"));
    } finally {
      setLoading(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [statusFilter]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // Auto-refresh on WebSocket events
  useEffect(() => {
    let debounceTimer: ReturnType<typeof setTimeout>;
    const handler = (_msg: WSMessage) => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        fetchData();
      }, 3000);
    };
    const unsub = eventBus.subscribe(handler);
    return () => {
      unsub();
      clearTimeout(debounceTimer);
    };
  }, [fetchData]);

  const handleRefresh = () => {
    setLoading(true);
    fetchData();
  };

  const handleExport = () => {
    if (!data) return;
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `workflows-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    URL.revokeObjectURL(url);
  };

  if (loading && !data) {
    return (
      <div className="space-y-6">
        <PageHeader
          statusFilter={statusFilter}
          onStatusFilterChange={setStatusFilter}
          onRefresh={handleRefresh}
          onExport={handleExport}
          lastUpdated={null}
        />
        <div className="grid grid-cols-2 sm:grid-cols-3 xl:grid-cols-6 gap-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className="card h-24 animate-pulse bg-surface-2" />
          ))}
        </div>
        {Array.from({ length: 3 }).map((_, i) => (
          <div key={i} className="card h-24 animate-pulse bg-surface-2" />
        ))}
      </div>
    );
  }

  if (error && !data) {
    return (
      <div className="space-y-6">
        <PageHeader
          statusFilter={statusFilter}
          onStatusFilterChange={setStatusFilter}
          onRefresh={handleRefresh}
          onExport={handleExport}
          lastUpdated={null}
        />
        <div className="card flex flex-col items-center justify-center py-16 gap-4">
          <AlertCircle className="w-10 h-10 text-red-700 dark:text-red-400" />
          <p className="text-red-700 dark:text-red-400 text-sm">{error}</p>
          <button onClick={handleRefresh} className="btn-primary text-sm">
            {t("common:retry")}
          </button>
        </div>
      </div>
    );
  }

  if (!data) return null;

  if (data.stats.totalSessions === 0) {
    return (
      <div className="space-y-6">
        <PageHeader
          statusFilter={statusFilter}
          onStatusFilterChange={setStatusFilter}
          onRefresh={handleRefresh}
          onExport={handleExport}
          lastUpdated={lastUpdated}
        />
        <EmptyState
          icon={Workflow}
          title={t("noData")}
          description={t("noDataDesc")}
          action={
            <Link to="/settings#hooks" className="btn-primary text-xs">
              {t("installHooksCta")}
            </Link>
          }
        />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <PageHeader
        statusFilter={statusFilter}
        onStatusFilterChange={setStatusFilter}
        onRefresh={handleRefresh}
        onExport={handleExport}
        lastUpdated={lastUpdated}
      />

      {/* Stats Row */}
      <WorkflowStats stats={data.stats} />

      {/* ── Primary (featured) sections ── */}
      <div className="space-y-3">
        <AccordionSection
          variant="primary"
          icon={<Layers className="w-4 h-4" />}
          title={t("runs.title")}
          description={t("runs.subtitle")}
          infoKey="dynamicRuns"
          isExpanded={expanded.dynamicRuns}
          onToggle={() => toggleSection("dynamicRuns")}
        >
          <WorkflowRunsPanel statusFilter={statusFilter} />
        </AccordionSection>

        <AccordionSection
          variant="primary"
          icon={<Crosshair className="w-4 h-4" />}
          title="Session Drilldown"
          description="Drill into any session's agent tree, timeline, and tool sequence. Start here when debugging a specific run."
          infoKey="drillIn"
          isExpanded={expanded.drillIn}
          onToggle={() => toggleSection("drillIn")}
        >
          <SessionDrillIn
            sessionId={selectedSessionId}
            onClose={() => setSelectedSessionId(null)}
            onSelectSession={(id) => setSelectedSessionId(id)}
          />
        </AccordionSection>

        <AccordionSection
          variant="primary"
          icon={<AlertTriangle className="w-4 h-4" />}
          title="Error Propagation"
          description="See where errors originate and how they cascade across agents and tool calls."
          infoKey="errorPropagation"
          isExpanded={expanded.errorPropagation}
          onToggle={() => toggleSection("errorPropagation")}
        >
          <ErrorPropagationMap data={data.errorPropagation} />
        </AccordionSection>
      </div>

      {/* ── Advanced Analytics group ── */}
      <AdvancedGroupHeader
        onExpandAll={() => setAllExpanded(true)}
        onCollapseAll={() => setAllExpanded(false)}
      />

      <div className="space-y-3">
        <AccordionSection
          variant="advanced"
          icon={<GitBranch className="w-4 h-4" />}
          title="Orchestration Graph"
          description="Aggregate view of how agents delegate across all your sessions. Not per-run — shows historical patterns."
          infoKey="orchestration"
          isExpanded={expanded.orchestration}
          onToggle={() => toggleSection("orchestration")}
        >
          <OrchestrationDAG
            data={data.orchestration}
            onNodeClick={setSelectedNode}
            selectedNode={selectedNode}
          />
          {selectedNode && (
            <div className="mt-3 flex items-center gap-2">
              <span className="text-sm text-gray-600 dark:text-gray-500">{t("filteredBy")}</span>
              <span className="badge bg-accent/25 dark:bg-accent/15 text-gray-900 dark:text-accent border border-accent/20 text-xs">
                {selectedNode}
              </span>
              <button
                onClick={() => setSelectedNode(null)}
                className="text-sm text-gray-600 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300 underline"
              >
                {t("clearFilter")}
              </button>
            </div>
          )}
        </AccordionSection>

        <AccordionSection
          variant="advanced"
          icon={<Clock className="w-4 h-4" />}
          title="Concurrency Timeline"
          description="Average agent overlap across sessions. Shows typical parallelism patterns."
          infoKey="concurrency"
          isExpanded={expanded.concurrency}
          onToggle={() => toggleSection("concurrency")}
        >
          <ConcurrencyTimeline data={data.concurrency} />
        </AccordionSection>

        <AccordionSection
          variant="advanced"
          icon={<Network className="w-4 h-4" />}
          title="Agent Collaboration Network"
          description="Network graph of which agent types work together and how often."
          infoKey="pipeline"
          isExpanded={expanded.collaboration}
          onToggle={() => toggleSection("collaboration")}
        >
          <AgentCollaborationNetwork effectiveness={data.effectiveness} edges={data.cooccurrence} />
        </AccordionSection>

        <AccordionSection
          variant="advanced"
          icon={<Cpu className="w-4 h-4" />}
          title="Model Delegation Flow"
          description="How model choices flow through orchestrated pipelines."
          infoKey="modelDelegation"
          isExpanded={expanded.modelDelegation}
          onToggle={() => toggleSection("modelDelegation")}
        >
          <ModelDelegationFlow data={data.modelDelegation} />
        </AccordionSection>

        <AccordionSection
          variant="advanced"
          icon={<Gauge className="w-4 h-4" />}
          title="Subagent Effectiveness"
          description="Success rates and cost-efficiency per subagent type across all runs."
          infoKey="effectiveness"
          isExpanded={expanded.effectiveness}
          onToggle={() => toggleSection("effectiveness")}
        >
          <SubagentEffectiveness data={data.effectiveness} />
        </AccordionSection>

        <AccordionSection
          variant="advanced"
          icon={<Wrench className="w-4 h-4" />}
          title="Tool Execution Flow"
          description="Which tools get called in sequence across your agent runs."
          infoKey="toolFlow"
          isExpanded={expanded.toolFlow}
          onToggle={() => toggleSection("toolFlow")}
        >
          <ToolExecutionFlow data={data.toolFlow} filterAgentType={selectedNode} />
        </AccordionSection>

        <AccordionSection
          variant="advanced"
          icon={<Share2 className="w-4 h-4" />}
          title="Workflow Patterns"
          description="Common multi-agent workflow shapes found in your session history."
          infoKey="patterns"
          isExpanded={expanded.patterns}
          onToggle={() => toggleSection("patterns")}
        >
          <WorkflowPatterns data={data.patterns} onPatternClick={() => {}} />
        </AccordionSection>

        <AccordionSection
          variant="advanced"
          icon={<ScatterChart className="w-4 h-4" />}
          title="Session Complexity"
          description="Scatter plot of session complexity: agents × tool calls × cost."
          infoKey="complexity"
          isExpanded={expanded.complexity}
          onToggle={() => toggleSection("complexity")}
        >
          <SessionComplexityScatter
            data={data.complexity}
            onSessionClick={setSelectedSessionId}
          />
        </AccordionSection>
      </div>
    </div>
  );
}

// ── Accordion section ──

interface AccordionSectionProps {
  variant: "primary" | "advanced";
  icon: ReactNode;
  title: string;
  description: string;
  /** Key under workflows.chartInfo.* — drives the structured popover content. */
  infoKey: string;
  isExpanded: boolean;
  onToggle: () => void;
  children: ReactNode;
}

function AccordionSection({
  variant,
  icon,
  title,
  description,
  infoKey,
  isExpanded,
  onToggle,
  children,
}: AccordionSectionProps) {
  const isPrimary = variant === "primary";

  return (
    <div
      className={
        isPrimary ? "card border-l-2 border-accent shadow-sm" : "card bg-surface-2/40"
      }
    >
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={isExpanded}
        className="w-full flex items-center gap-3 px-4 py-3 text-left group"
      >
        <span
          className={`flex-shrink-0 w-8 h-8 rounded-lg flex items-center justify-center ${
            isPrimary
              ? "bg-accent/20 text-accent"
              : "bg-surface-3 text-gray-600 dark:text-gray-400"
          }`}
        >
          {icon}
        </span>

        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 flex-wrap">
            <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{title}</h2>
            {isPrimary ? (
              <span className="inline-flex items-center gap-1 text-[10px] font-bold uppercase tracking-wider text-accent bg-accent/15 border border-accent/25 px-1.5 py-0.5 rounded">
                <Star className="w-2.5 h-2.5 fill-current" />
                Featured
              </span>
            ) : (
              <span className="text-[10px] font-medium uppercase tracking-wider text-gray-500 dark:text-gray-500 bg-surface-3 border border-border px-1.5 py-0.5 rounded">
                Advanced
              </span>
            )}
            <span onClick={(e) => e.stopPropagation()} className="inline-flex">
              <ChartInfoPopover infoKey={infoKey} title={title} />
            </span>
          </div>
          <p className="text-xs text-gray-600 dark:text-gray-500 mt-0.5 truncate">{description}</p>
        </div>

        <ChevronDown
          className={`flex-shrink-0 w-4 h-4 text-gray-500 transition-transform duration-200 ${
            isExpanded ? "rotate-180" : ""
          }`}
        />
      </button>

      {/* Conditional render: heavy charts only mount when expanded. */}
      {isExpanded && (
        <div className="px-4 pb-4 pt-1 border-t border-border/50">{children}</div>
      )}
    </div>
  );
}

// ── Advanced Analytics group header ──

function AdvancedGroupHeader({
  onExpandAll,
  onCollapseAll,
}: {
  onExpandAll: () => void;
  onCollapseAll: () => void;
}) {
  return (
    <div className="pt-2">
      <div className="flex items-center gap-3">
        <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-700 dark:text-gray-400 whitespace-nowrap">
          Advanced Analytics
        </h2>
        <div className="flex-1 h-px bg-border" />
        <div className="flex items-center gap-3 flex-shrink-0">
          <button
            type="button"
            onClick={onExpandAll}
            className="text-xs font-medium text-accent hover:underline"
          >
            Expand all
          </button>
          <button
            type="button"
            onClick={onCollapseAll}
            className="text-xs font-medium text-gray-600 dark:text-gray-400 hover:underline"
          >
            Collapse all
          </button>
        </div>
      </div>
      <p className="text-[11px] text-gray-600 dark:text-gray-500 mt-1.5">
        These charts show historical patterns across all sessions, not individual run data.
      </p>
    </div>
  );
}

/**
 * Structured info popover for a Workflows chart section. Hover or focus the
 * `i` icon to read three short paragraphs sourced from i18n:
 *
 *   1. What this shows  — what data the chart visualizes
 *   2. How to read it   — visual encoding (axes, sizes, colors, etc.)
 *   3. Why it matters   — what insights the user can extract
 *
 * The popover uses fixed positioning and is clamped to the viewport so it
 * never gets clipped by the sidebar or screen edges. Auto-flips above the
 * trigger when there's no room below.
 */
function ChartInfoPopover({ infoKey, title }: { infoKey: string; title: string }) {
  const { t } = useTranslation("workflows");
  const [open, setOpen] = useState(false);
  const buttonRef = useRef<HTMLButtonElement>(null);
  const popoverRef = useRef<HTMLDivElement>(null);
  const [coords, setCoords] = useState<{ left: number; top: number }>({ left: 0, top: 0 });

  const POPOVER_W = 340;
  const MARGIN = 12;

  useLayoutEffect(() => {
    if (!open) return;
    const update = () => {
      const btn = buttonRef.current;
      const pop = popoverRef.current;
      if (!btn) return;
      const r = btn.getBoundingClientRect();
      const popH = pop?.offsetHeight ?? 280;

      // Center horizontally over the icon, clamp to viewport.
      let left = r.left + r.width / 2 - POPOVER_W / 2;
      if (left < MARGIN) left = MARGIN;
      if (left + POPOVER_W > window.innerWidth - MARGIN) {
        left = window.innerWidth - POPOVER_W - MARGIN;
      }
      // Default below the icon; flip above if not enough room.
      const spaceBelow = window.innerHeight - r.bottom;
      const placeAbove = spaceBelow < popH + MARGIN && r.top > popH + MARGIN;
      const top = placeAbove ? Math.max(MARGIN, r.top - popH - 8) : r.bottom + 8;

      setCoords({ left, top });
    };
    update();
    const raf = requestAnimationFrame(update);
    window.addEventListener("scroll", update, true);
    window.addEventListener("resize", update);
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("scroll", update, true);
      window.removeEventListener("resize", update);
    };
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  return (
    <>
      <button
        ref={buttonRef}
        type="button"
        aria-label={t("chartInfo.labels.what")}
        aria-expanded={open}
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={() => setOpen(false)}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        className="flex items-center justify-center rounded-full p-0.5 -m-0.5 text-gray-600 hover:text-gray-400 transition-colors focus:outline-none focus:ring-1 focus:ring-accent/40"
      >
        <Info className="w-3.5 h-3.5" />
      </button>
      {open && (
        <div
          ref={popoverRef}
          role="tooltip"
          className="fixed z-50 p-3.5 bg-white dark:bg-[#12121f] border border-gray-200 dark:border-[#2a2a4a] shadow-lg rounded-lg shadow-2xl text-[11px] text-gray-700 dark:text-gray-300 pointer-events-none"
          style={{ left: coords.left, top: coords.top, width: POPOVER_W }}
        >
          <p className="text-xs font-semibold text-gray-900 dark:text-gray-100 mb-2.5 pb-2 border-b border-[#2a2a4a]">
            {title}
          </p>

          <p className="font-semibold text-gray-800 dark:text-gray-200 uppercase tracking-wider text-[9px] mb-1">
            {t("chartInfo.labels.what")}
          </p>
          <p className="text-gray-600 dark:text-gray-400 leading-snug mb-2.5">{t(`chartInfo.${infoKey}.what`)}</p>

          <p className="font-semibold text-gray-800 dark:text-gray-200 uppercase tracking-wider text-[9px] mb-1">
            {t("chartInfo.labels.howToRead")}
          </p>
          <p className="text-gray-600 dark:text-gray-400 leading-snug mb-2.5">{t(`chartInfo.${infoKey}.howToRead`)}</p>

          <p className="font-semibold text-gray-800 dark:text-gray-200 uppercase tracking-wider text-[9px] mb-1">
            {t("chartInfo.labels.why")}
          </p>
          <p className="text-gray-600 dark:text-gray-400 leading-snug">{t(`chartInfo.${infoKey}.why`)}</p>
        </div>
      )}
    </>
  );
}

// ── Page Header ──
function PageHeader({
  statusFilter,
  onStatusFilterChange,
  onRefresh,
  onExport,
  lastUpdated,
}: {
  statusFilter: StatusFilter;
  onStatusFilterChange: (f: StatusFilter) => void;
  onRefresh: () => void;
  onExport: () => void;
  lastUpdated: Date | null;
}) {
  const { t } = useTranslation("workflows");
  const wsConnected = useSyncExternalStore(eventBus.onConnection, () => eventBus.connected);
  const filters: { value: StatusFilter; label: string }[] = [
    { value: "all", label: t("allSessions") },
    { value: "active", label: t("activeOnly") },
    { value: "completed", label: t("completed") },
  ];

  return (
    <div className="page-header flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
      <div className="flex items-center gap-3">
        <div className="w-9 h-9 rounded-xl bg-accent/15 flex items-center justify-center">
          <Workflow className="w-4.5 h-4.5 text-accent" />
        </div>
        <div>
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-bold text-gray-900 dark:text-gray-100">{t("title")}</h1>
            {wsConnected ? (
              <span className="flex items-center gap-1.5 text-[11px] text-emerald-700 dark:text-emerald-400 bg-emerald-50 dark:bg-emerald-500/10 border border-emerald-200 dark:border-emerald-500/20 px-2 py-0.5 rounded-full">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse-dot" />
                {t("common:live")}
              </span>
            ) : (
              <span className="flex items-center gap-1.5 text-[11px] text-gray-600 dark:text-gray-400 bg-gray-500/10 border border-gray-500/20 px-2 py-0.5 rounded-full">
                <span className="w-1.5 h-1.5 rounded-full bg-gray-400" />
                {t("common:offline")}
              </span>
            )}
          </div>
          <p className="text-sm text-gray-600 dark:text-gray-500">{t("subtitle")}</p>
        </div>
      </div>

      <div className="flex items-center gap-2 flex-wrap">
        {/* Status filter tabs — change which sessions feed the analytics. */}
        <div className="flex bg-surface-2 rounded-lg p-0.5 border border-border">
          {filters.map((f) => (
            <button
              key={f.value}
              onClick={() => onStatusFilterChange(f.value)}
              className={`px-3 py-1.5 rounded-md text-xs font-medium transition-colors ${
                statusFilter === f.value
                  ? "bg-accent/25 dark:bg-accent/15 text-gray-900 dark:text-accent"
                  : "text-gray-700 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300"
              }`}
            >
              {f.label}
            </button>
          ))}
        </div>

        {/* Actions */}
        <button
          onClick={onRefresh}
          className="p-2 rounded-lg text-gray-700 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300 hover:bg-surface-3 transition-colors"
          title={t("refreshData")}
        >
          <RefreshCw className="w-4 h-4" />
        </button>
        <button
          onClick={onExport}
          className="p-2 rounded-lg text-gray-700 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300 hover:bg-surface-3 transition-colors"
          title={t("exportJson")}
        >
          <Download className="w-4 h-4" />
        </button>

        {lastUpdated && (
          <span className="text-[10px] text-gray-600 ml-1">
            {t("common:updated")}
            {lastUpdated.toLocaleTimeString()}
          </span>
        )}
      </div>
    </div>
  );
}
