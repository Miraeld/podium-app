/**
 * @file Search.tsx
 * @description Global search page. Queries /api/search across sessions, tool
 * calls, and conversations, rendering grouped results (sessions first, then
 * events). Debounces input by 300ms, requires a 2-char minimum, and falls back
 * to showing recent sessions when the query is empty. Reachable from the
 * sidebar and via the global Cmd/Ctrl+K shortcut wired in App.tsx.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useEffect, useRef, useState, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { Search as SearchIcon, FolderOpen, Zap, ChevronRight, X } from "lucide-react";
import { SessionStatusBadge } from "../components/StatusBadge";
import { EmptyState } from "../components/EmptyState";
import { Skeleton } from "../components/Skeleton";
import { timeAgo, formatDateTime, truncate } from "../lib/format";
import type { EffectiveSessionStatus, SessionStatus } from "../lib/types";

const MIN_QUERY = 2;
const RESULT_LIMIT = 20;

interface SessionSearchResult {
  type: "session";
  session_id: string;
  session_name: string | null;
  cwd: string | null;
  status: string | null;
  started_at: string | null;
  highlight?: string | null;
}

interface EventSearchResult {
  type: "event";
  session_id: string;
  session_name: string | null;
  event_id: number;
  event_type: string | null;
  tool_name: string | null;
  summary: string | null;
  created_at: string | null;
}

type SearchResult = SessionSearchResult | EventSearchResult;

interface SearchResponse {
  results: SearchResult[];
  total: number;
}

const VALID_STATUSES: ReadonlySet<string> = new Set<SessionStatus | "waiting">([
  "active",
  "completed",
  "error",
  "abandoned",
  "waiting",
]);

function toEffectiveStatus(status: string | null): EffectiveSessionStatus {
  return status && VALID_STATUSES.has(status)
    ? (status as EffectiveSessionStatus)
    : "completed";
}

function sessionDisplayName(r: SessionSearchResult): string {
  if (r.session_name) return r.session_name;
  return `Session ${r.session_id.slice(0, 8)}`;
}

/**
 * Render a highlight snippet. The server may wrap matches in <mark> tags; we
 * split on them and emphasize the marked spans rather than dangerously setting
 * raw HTML.
 */
function Highlight({ text }: { text: string }) {
  const parts = text.split(/(<mark>.*?<\/mark>)/g);
  return (
    <>
      {parts.map((part, i) => {
        const m = part.match(/^<mark>(.*?)<\/mark>$/);
        if (m) {
          return (
            <mark
              key={i}
              className="bg-accent/25 text-amber-800 dark:text-accent rounded px-0.5"
            >
              {m[1]}
            </mark>
          );
        }
        return <span key={i}>{part}</span>;
      })}
    </>
  );
}

export function Search() {
  const navigate = useNavigate();
  const inputRef = useRef<HTMLInputElement>(null);

  const [input, setInput] = useState("");
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResult[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // True when results come from the recent-sessions fallback (no active query).
  const [isRecent, setIsRecent] = useState(false);

  // Autofocus on mount.
  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  // Debounce the input → committed query (300ms after the user stops typing).
  useEffect(() => {
    const id = window.setTimeout(() => setQuery(input.trim()), 300);
    return () => window.clearTimeout(id);
  }, [input]);

  const runSearch = useCallback(async (q: string) => {
    setLoading(true);
    setError(null);
    try {
      const qs = new URLSearchParams({
        q,
        limit: String(RESULT_LIMIT),
        offset: "0",
      });
      const res = await fetch(`/api/search?${qs.toString()}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data: SearchResponse = await res.json();
      setResults(Array.isArray(data.results) ? data.results : []);
      setTotal(typeof data.total === "number" ? data.total : 0);
      setIsRecent(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Search failed");
      setResults([]);
      setTotal(0);
    } finally {
      setLoading(false);
    }
  }, []);

  const loadRecent = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch("/api/sessions?limit=10&sort_by=time&sort_desc=true");
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const sessions: Array<{
        id: string;
        name: string | null;
        cwd: string | null;
        status: string | null;
        started_at: string | null;
      }> = Array.isArray(data.sessions) ? data.sessions : [];
      setResults(
        sessions.map((s) => ({
          type: "session" as const,
          session_id: s.id,
          session_name: s.name,
          cwd: s.cwd,
          status: s.status,
          started_at: s.started_at,
        }))
      );
      setTotal(sessions.length);
      setIsRecent(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load recent sessions");
      setResults([]);
      setTotal(0);
    } finally {
      setLoading(false);
    }
  }, []);

  // Drive fetching off the committed query. Below the minimum length we show
  // recent sessions instead of hitting /api/search with a too-short term.
  useEffect(() => {
    if (query.length >= MIN_QUERY) {
      void runSearch(query);
    } else {
      void loadRecent();
    }
  }, [query, runSearch, loadRecent]);

  const sessions = results.filter((r): r is SessionSearchResult => r.type === "session");
  const events = results.filter((r): r is EventSearchResult => r.type === "event");

  const hasQuery = query.length >= MIN_QUERY;

  return (
    <div className="animate-fade-in">
      {/* Header */}
      <div className="page-header flex items-center gap-3 mb-8">
        <div className="w-9 h-9 rounded-xl bg-accent/15 flex items-center justify-center">
          <SearchIcon className="w-4.5 h-4.5 text-accent" />
        </div>
        <div>
          <h1 className="text-xl font-bold text-gray-900 dark:text-white">Search</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            {hasQuery
              ? `${total} result${total === 1 ? "" : "s"} for "${query}"`
              : "Across all sessions, tool calls, and conversations"}
          </p>
        </div>
      </div>

      {/* Search input */}
      <div className="relative mb-6">
        <SearchIcon className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-500 dark:text-gray-400 pointer-events-none" />
        <input
          ref={inputRef}
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") setInput("");
          }}
          placeholder="Search sessions, tool calls, and conversations…"
          className="input w-full pl-12 pr-12 py-3 text-base"
          aria-label="Search"
        />
        {input && (
          <button
            type="button"
            onClick={() => {
              setInput("");
              inputRef.current?.focus();
            }}
            aria-label="Clear search"
            className="absolute right-3 top-1/2 -translate-y-1/2 p-1.5 rounded-lg text-fg-muted hover:text-accent hover:bg-white/[0.05] transition-colors"
          >
            <X className="w-4 h-4" />
          </button>
        )}
      </div>

      {/* Results */}
      {error ? (
        <EmptyState
          icon={SearchIcon}
          title="Search unavailable"
          description={error}
        />
      ) : loading ? (
        <div className="space-y-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className="card p-4 flex items-center gap-4">
              <Skeleton className="h-9 w-9" rounded="lg" />
              <div className="flex-1 space-y-2">
                <Skeleton className="h-4 w-1/3" />
                <Skeleton className="h-3 w-1/2" />
              </div>
            </div>
          ))}
        </div>
      ) : results.length === 0 ? (
        hasQuery ? (
          <EmptyState
            icon={SearchIcon}
            title="No results"
            description={`Nothing matched "${query}". Try a different term.`}
          />
        ) : (
          <EmptyState
            icon={SearchIcon}
            title="Search Podium"
            description="Search across all sessions, tool calls, and conversations. Start typing to find what you're looking for."
          />
        )
      ) : (
        <div className="space-y-8">
          {/* Sessions section */}
          {sessions.length > 0 && (
            <section>
              <div className="flex items-center gap-2 mb-3 px-1">
                <FolderOpen className="w-4 h-4 text-accent/80" />
                <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-accent/80">
                  {isRecent ? "Recent sessions" : "Sessions"}
                </h2>
                <span className="text-xs text-gray-400 dark:text-gray-500 font-mono">
                  {sessions.length}
                </span>
              </div>
              <div className="space-y-2">
                {sessions.map((s) => (
                  <button
                    key={`session-${s.session_id}`}
                    type="button"
                    onClick={() => navigate(`/sessions/${s.session_id}`)}
                    className="card card-hover w-full text-left p-4 flex items-center gap-4 group"
                  >
                    <div className="w-9 h-9 rounded-lg bg-accent/10 flex items-center justify-center flex-shrink-0">
                      <FolderOpen className="w-4 h-4 text-accent" />
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <p className="text-sm font-medium text-gray-900 dark:text-gray-100 truncate">
                          {sessionDisplayName(s)}
                        </p>
                        <SessionStatusBadge status={toEffectiveStatus(s.status)} />
                      </div>
                      {s.cwd && (
                        <p
                          className="text-[11px] text-gray-400 dark:text-gray-500 font-mono truncate"
                          title={s.cwd}
                        >
                          {truncate(s.cwd, 60)}
                        </p>
                      )}
                      {s.highlight && (
                        <p className="text-xs text-gray-600 dark:text-gray-300 mt-1 line-clamp-2">
                          <Highlight text={s.highlight} />
                        </p>
                      )}
                    </div>
                    {s.started_at && (
                      <span
                        className="text-[11px] text-gray-400 dark:text-gray-500 flex-shrink-0 whitespace-nowrap"
                        title={formatDateTime(s.started_at)}
                      >
                        {timeAgo(s.started_at)}
                      </span>
                    )}
                    <ChevronRight className="w-4 h-4 text-gray-300 dark:text-gray-600 group-hover:text-amber-500 dark:group-hover:text-accent transition-colors flex-shrink-0" />
                  </button>
                ))}
              </div>
            </section>
          )}

          {/* Events section */}
          {events.length > 0 && (
            <section>
              <div className="flex items-center gap-2 mb-3 px-1">
                <Zap className="w-4 h-4 text-accent/80" />
                <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-accent/80">
                  Events
                </h2>
                <span className="text-xs text-gray-400 dark:text-gray-500 font-mono">
                  {events.length}
                </span>
              </div>
              <div className="space-y-2">
                {events.map((ev) => (
                  <button
                    key={`event-${ev.event_id}`}
                    type="button"
                    onClick={() => navigate(`/sessions/${ev.session_id}?tab=timeline`)}
                    className="card card-hover w-full text-left p-4 flex items-center gap-4 group"
                  >
                    <div className="w-9 h-9 rounded-lg bg-accent/10 flex items-center justify-center flex-shrink-0">
                      <Zap className="w-4 h-4 text-accent" />
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="text-sm font-medium text-gray-900 dark:text-gray-100">
                          {ev.event_type || "Event"}
                        </span>
                        {ev.tool_name && (
                          <span className="inline-flex items-center px-1.5 py-0.5 rounded-md text-[10px] font-semibold font-mono bg-accent/15 text-amber-700 dark:text-accent border border-accent/25">
                            {ev.tool_name}
                          </span>
                        )}
                        {ev.session_name && (
                          <span
                            role="link"
                            tabIndex={0}
                            onClick={(e) => {
                              e.stopPropagation();
                              navigate(`/sessions/${ev.session_id}`);
                            }}
                            onKeyDown={(e) => {
                              if (e.key === "Enter") {
                                e.stopPropagation();
                                navigate(`/sessions/${ev.session_id}`);
                              }
                            }}
                            className="text-[11px] text-gray-400 dark:text-gray-500 hover:text-accent dark:hover:text-accent transition-colors truncate cursor-pointer"
                          >
                            in {ev.session_name}
                          </span>
                        )}
                      </div>
                      {ev.summary && (
                        <p className="text-xs text-gray-600 dark:text-gray-300 mt-1 line-clamp-2">
                          <Highlight text={ev.summary} />
                        </p>
                      )}
                    </div>
                    {ev.created_at && (
                      <span
                        className="text-[11px] text-gray-400 dark:text-gray-500 flex-shrink-0 whitespace-nowrap"
                        title={formatDateTime(ev.created_at)}
                      >
                        {timeAgo(ev.created_at)}
                      </span>
                    )}
                    <ChevronRight className="w-4 h-4 text-gray-300 dark:text-gray-600 group-hover:text-amber-500 dark:group-hover:text-accent transition-colors flex-shrink-0" />
                  </button>
                ))}
              </div>
            </section>
          )}
        </div>
      )}
    </div>
  );
}
