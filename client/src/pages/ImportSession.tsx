/**
 * @file ImportSession.tsx
 * @description Import / preview page for Podium session export bundles. Accepts
 * a `.json` export (drag-and-drop, file picker, or pasted JSON), validates the
 * `podium_export_version`, then offers two paths: import the bundle into Podium
 * (POST /api/import/session → navigate to the new session) or browse a
 * read-only preview of the session, its agents, and its event log without
 * importing.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useCallback, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  Upload,
  FileJson,
  ClipboardPaste,
  X,
  Eye,
  Download,
  AlertTriangle,
  FolderOpen,
  Bot,
  Zap,
  Loader2,
  CheckCircle2,
} from "lucide-react";
import { SessionStatusBadge } from "../components/StatusBadge";
import { formatDateTime, formatDuration, fmtCostFull, truncate } from "../lib/format";
import type { EffectiveSessionStatus, SessionStatus } from "../lib/types";

const EXPORT_VERSION = "1.0";

interface BundleSession {
  id: string;
  name?: string | null;
  status?: string | null;
  cwd?: string | null;
  model?: string | null;
  started_at?: string | null;
  ended_at?: string | null;
  cost?: number | null;
}

interface BundleAgent {
  id: string;
  name?: string | null;
  type?: string | null;
  subagent_type?: string | null;
  status?: string | null;
  started_at?: string | null;
  ended_at?: string | null;
}

interface BundleEvent {
  id?: number;
  event_type?: string | null;
  tool_name?: string | null;
  summary?: string | null;
  created_at?: string | null;
}

interface PodiumBundle {
  podium_export_version: string;
  session: BundleSession;
  agents?: BundleAgent[];
  events?: BundleEvent[];
  token_usage?: unknown;
}

const VALID_STATUSES: ReadonlySet<string> = new Set<SessionStatus | "waiting">([
  "active",
  "completed",
  "error",
  "abandoned",
  "waiting",
]);

function toEffectiveStatus(status: string | null | undefined): EffectiveSessionStatus {
  return status && VALID_STATUSES.has(status)
    ? (status as EffectiveSessionStatus)
    : "completed";
}

function isBundle(value: unknown): value is PodiumBundle {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as { session?: unknown }).session === "object" &&
    (value as { session: { id?: unknown } }).session !== null &&
    typeof (value as { session: { id?: unknown } }).session.id === "string"
  );
}

export function ImportSession() {
  const navigate = useNavigate();
  const fileInputRef = useRef<HTMLInputElement>(null);

  const [bundle, setBundle] = useState<PodiumBundle | null>(null);
  const [fileName, setFileName] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState(false);
  const [showPaste, setShowPaste] = useState(false);
  const [pasteValue, setPasteValue] = useState("");
  const [showPreview, setShowPreview] = useState(false);
  const [importing, setImporting] = useState(false);
  const [importError, setImportError] = useState<string | null>(null);

  const acceptBundle = useCallback((raw: string, sourceName: string | null) => {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      setError("Failed to parse JSON file");
      return;
    }
    if (
      typeof parsed !== "object" ||
      parsed === null ||
      (parsed as { podium_export_version?: unknown }).podium_export_version !== EXPORT_VERSION
    ) {
      setError("Invalid export file format");
      return;
    }
    if (!isBundle(parsed)) {
      setError("Export is missing session data");
      return;
    }
    setError(null);
    setImportError(null);
    setShowPreview(false);
    setBundle(parsed);
    setFileName(sourceName);
  }, []);

  const handleFile = useCallback(
    (file: File) => {
      const reader = new FileReader();
      reader.onload = (e) => acceptBundle((e.target?.result as string) ?? "", file.name);
      reader.onerror = () => setError("Failed to read file");
      reader.readAsText(file);
    },
    [acceptBundle]
  );

  const onDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault();
      setDragOver(false);
      const file = e.dataTransfer.files?.[0];
      if (file) handleFile(file);
    },
    [handleFile]
  );

  const reset = useCallback(() => {
    setBundle(null);
    setFileName(null);
    setError(null);
    setImportError(null);
    setShowPreview(false);
    setShowPaste(false);
    setPasteValue("");
  }, []);

  const doImport = useCallback(async () => {
    if (!bundle) return;
    setImporting(true);
    setImportError(null);
    try {
      const res = await fetch("/api/import/session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(bundle),
      });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body?.error?.message || `HTTP ${res.status}`);
      }
      const data: { ok?: boolean; session_id?: string } = await res.json();
      const id = data.session_id || bundle.session.id;
      navigate(`/sessions/${id}`);
    } catch (e) {
      setImportError(e instanceof Error ? e.message : "Import failed");
    } finally {
      setImporting(false);
    }
  }, [bundle, navigate]);

  const session = bundle?.session;
  const agents = bundle?.agents ?? [];
  const events = bundle?.events ?? [];

  const duration =
    session?.started_at && session?.ended_at
      ? formatDuration(session.started_at, session.ended_at)
      : null;

  return (
    <div className="animate-fade-in">
      {/* Header */}
      <div className="page-header flex items-center gap-3 mb-2">
        <div className="w-9 h-9 rounded-xl bg-accent/15 flex items-center justify-center">
          <Upload className="w-4.5 h-4.5 text-accent" />
        </div>
        <div>
          <h1 className="text-xl font-bold text-gray-900 dark:text-white">Import Session</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Load a Podium session export to view or import it.
          </p>
        </div>
      </div>

      {/* Upload area / paste */}
      {!bundle && (
        <div className="mt-6">
          {!showPaste ? (
            <>
              <div
                role="button"
                tabIndex={0}
                onClick={() => fileInputRef.current?.click()}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") fileInputRef.current?.click();
                }}
                onDragOver={(e) => {
                  e.preventDefault();
                  setDragOver(true);
                }}
                onDragLeave={() => setDragOver(false)}
                onDrop={onDrop}
                className={`flex flex-col items-center justify-center gap-3 rounded-2xl border-2 border-dashed px-6 py-16 text-center cursor-pointer transition-colors ${
                  dragOver
                    ? "border-accent bg-accent/10"
                    : "border-gray-300 dark:border-border hover:border-accent/60 hover:bg-accent/[0.04]"
                }`}
              >
                <div className="w-14 h-14 rounded-2xl bg-accent/10 flex items-center justify-center">
                  <Upload className="w-6 h-6 text-accent" />
                </div>
                <div>
                  <p className="text-sm font-medium text-gray-900 dark:text-gray-100">
                    Drop a .json file here, or click to browse
                  </p>
                  <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                    Accepts Podium session exports (export version {EXPORT_VERSION})
                  </p>
                </div>
              </div>
              <input
                ref={fileInputRef}
                type="file"
                accept=".json,application/json"
                className="hidden"
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  if (file) handleFile(file);
                  // Reset so re-picking the same file re-fires change.
                  e.target.value = "";
                }}
              />
              <div className="flex justify-center mt-4">
                <button
                  type="button"
                  onClick={() => setShowPaste(true)}
                  className="btn-ghost"
                >
                  <ClipboardPaste className="w-4 h-4" /> Or paste JSON
                </button>
              </div>
            </>
          ) : (
            <div className="card p-4">
              <div className="flex items-center justify-between mb-3">
                <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
                  Paste export JSON
                </h2>
                <button
                  type="button"
                  onClick={() => {
                    setShowPaste(false);
                    setPasteValue("");
                  }}
                  aria-label="Cancel paste"
                  className="p-1.5 rounded-lg text-fg-muted hover:text-accent hover:bg-white/[0.05] transition-colors"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>
              <textarea
                value={pasteValue}
                onChange={(e) => setPasteValue(e.target.value)}
                placeholder='{ "podium_export_version": "1.0", "session": { … } }'
                rows={12}
                className="input w-full font-mono text-xs resize-y"
              />
              <div className="flex justify-end gap-2 mt-3">
                <button
                  type="button"
                  onClick={() => acceptBundle(pasteValue, "pasted JSON")}
                  disabled={!pasteValue.trim()}
                  className="btn-primary disabled:opacity-40 disabled:cursor-not-allowed"
                >
                  Load
                </button>
              </div>
            </div>
          )}

          {error && (
            <div className="mt-4 flex items-start gap-2.5 rounded-xl border border-red-200 dark:border-red-500/20 bg-red-50 dark:bg-red-500/10 px-4 py-3">
              <AlertTriangle className="w-4 h-4 text-red-500 flex-shrink-0 mt-0.5" />
              <p className="text-sm text-red-700 dark:text-red-400">{error}</p>
            </div>
          )}
        </div>
      )}

      {/* Preview / actions */}
      {bundle && session && (
        <div className="mt-6 space-y-6">
          {/* Summary card */}
          <div className="card p-5">
            <div className="flex items-start justify-between gap-3 mb-4">
              <div className="flex items-center gap-3 min-w-0">
                <div className="w-10 h-10 rounded-xl bg-accent/10 flex items-center justify-center flex-shrink-0">
                  <FileJson className="w-5 h-5 text-accent" />
                </div>
                <div className="min-w-0">
                  <h2 className="text-base font-semibold text-gray-900 dark:text-white truncate">
                    {session.name || `Session ${session.id.slice(0, 8)}`}
                  </h2>
                  {fileName && (
                    <p className="text-[11px] text-gray-400 dark:text-gray-500 font-mono truncate">
                      {fileName}
                    </p>
                  )}
                </div>
              </div>
              <button
                type="button"
                onClick={reset}
                aria-label="Clear loaded export"
                className="p-1.5 rounded-lg text-fg-muted hover:text-accent hover:bg-white/[0.05] transition-colors flex-shrink-0"
              >
                <X className="w-4 h-4" />
              </button>
            </div>

            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
              <Stat label="Date" value={session.started_at ? formatDateTime(session.started_at) : "—"} />
              <Stat
                label="Cost"
                value={
                  session.cost != null && session.cost > 0 ? fmtCostFull(session.cost) : "—"
                }
              />
              <Stat label="Agents" value={String(agents.length)} />
              <Stat label="Events" value={String(events.length)} />
            </div>
          </div>

          {/* Action buttons */}
          <div className="flex flex-wrap items-center gap-3">
            <button
              type="button"
              onClick={() => void doImport()}
              disabled={importing}
              className="btn-primary disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {importing ? (
                <Loader2 className="w-4 h-4 animate-spin" />
              ) : (
                <Download className="w-4 h-4" />
              )}
              {importing ? "Importing…" : "Import into Podium"}
            </button>
            <button
              type="button"
              onClick={() => setShowPreview((v) => !v)}
              className="btn-ghost"
            >
              <Eye className="w-4 h-4" />
              {showPreview ? "Hide preview" : "View Read-Only"}
            </button>
          </div>

          {importError && (
            <div className="flex items-start gap-2.5 rounded-xl border border-red-200 dark:border-red-500/20 bg-red-50 dark:bg-red-500/10 px-4 py-3">
              <AlertTriangle className="w-4 h-4 text-red-500 flex-shrink-0 mt-0.5" />
              <p className="text-sm text-red-700 dark:text-red-400">{importError}</p>
            </div>
          )}

          {/* Read-only view */}
          {showPreview && (
            <div className="space-y-6">
              <div className="flex items-start gap-2.5 rounded-xl border border-accent/25 bg-accent/[0.06] px-4 py-3">
                <CheckCircle2 className="w-4 h-4 text-accent flex-shrink-0 mt-0.5" />
                <p className="text-xs text-gray-600 dark:text-gray-300">
                  This is a read-only preview. Import to get full session features.
                </p>
              </div>

              {/* Session info card */}
              <section>
                <h3 className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-accent/80 mb-3 px-1">
                  <FolderOpen className="w-4 h-4 text-accent/80" /> Session
                </h3>
                <div className="card p-4 space-y-2.5">
                  <InfoRow label="Name" value={session.name || "—"} />
                  <InfoRow
                    label="Status"
                    valueNode={<SessionStatusBadge status={toEffectiveStatus(session.status)} />}
                  />
                  <InfoRow label="Directory" value={session.cwd || "—"} mono title={session.cwd || undefined} />
                  <InfoRow label="Duration" value={duration ?? (session.ended_at ? "—" : "Running")} mono />
                  <InfoRow
                    label="Cost"
                    value={session.cost != null && session.cost > 0 ? fmtCostFull(session.cost) : "—"}
                    mono
                  />
                </div>
              </section>

              {/* Agents list */}
              <section>
                <h3 className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-accent/80 mb-3 px-1">
                  <Bot className="w-4 h-4 text-accent/80" /> Agents
                  <span className="font-mono text-gray-400 dark:text-gray-500">{agents.length}</span>
                </h3>
                {agents.length === 0 ? (
                  <p className="text-sm text-gray-400 dark:text-gray-500 italic px-1">No agents in export.</p>
                ) : (
                  <div className="card overflow-x-auto">
                    <table className="w-full min-w-[480px] text-sm">
                      <thead>
                        <tr className="border-b border-gray-100 dark:border-accent/20 text-left bg-gray-50/50 dark:bg-surface-2/60">
                          <Th>Name</Th>
                          <Th>Type</Th>
                          <Th>Status</Th>
                          <Th>Duration</Th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-gray-100 dark:divide-accent/20">
                        {agents.map((a, i) => (
                          <tr key={a.id || i}>
                            <td className="px-4 py-2.5 text-gray-900 dark:text-gray-100">
                              {a.name || `Agent ${i + 1}`}
                            </td>
                            <td className="px-4 py-2.5 text-gray-500 dark:text-gray-400 font-mono text-xs">
                              {a.subagent_type || a.type || "—"}
                            </td>
                            <td className="px-4 py-2.5 text-gray-500 dark:text-gray-400">
                              {a.status || "—"}
                            </td>
                            <td className="px-4 py-2.5 text-gray-500 dark:text-gray-400 font-mono text-xs">
                              {a.started_at && a.ended_at
                                ? formatDuration(a.started_at, a.ended_at)
                                : "—"}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </section>

              {/* Event log */}
              <section>
                <h3 className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-accent/80 mb-3 px-1">
                  <Zap className="w-4 h-4 text-accent/80" /> Event log
                  <span className="font-mono text-gray-400 dark:text-gray-500">{events.length}</span>
                </h3>
                {events.length === 0 ? (
                  <p className="text-sm text-gray-400 dark:text-gray-500 italic px-1">No events in export.</p>
                ) : (
                  <div className="card overflow-x-auto">
                    <table className="w-full min-w-[640px] text-sm">
                      <thead>
                        <tr className="border-b border-gray-100 dark:border-accent/20 text-left bg-gray-50/50 dark:bg-surface-2/60">
                          <Th>Timestamp</Th>
                          <Th>Type</Th>
                          <Th>Tool</Th>
                          <Th>Summary</Th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-gray-100 dark:divide-accent/20">
                        {events.map((ev, i) => (
                          <tr key={ev.id ?? i}>
                            <td className="px-4 py-2.5 text-gray-500 dark:text-gray-400 font-mono text-xs whitespace-nowrap">
                              {ev.created_at ? formatDateTime(ev.created_at) : "—"}
                            </td>
                            <td className="px-4 py-2.5 text-gray-900 dark:text-gray-100">
                              {ev.event_type || "—"}
                            </td>
                            <td className="px-4 py-2.5 text-gray-500 dark:text-gray-400 font-mono text-xs">
                              {ev.tool_name || "—"}
                            </td>
                            <td
                              className="px-4 py-2.5 text-gray-500 dark:text-gray-400 max-w-[280px] truncate"
                              title={ev.summary || undefined}
                            >
                              {ev.summary ? truncate(ev.summary, 80) : "—"}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </section>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg bg-gray-50 dark:bg-white/[0.03] border border-gray-100 dark:border-white/[0.05] px-3 py-2.5">
      <div className="text-[10px] font-semibold uppercase tracking-wider text-gray-400 dark:text-gray-500">
        {label}
      </div>
      <div className="mt-0.5 text-sm font-semibold text-gray-900 dark:text-gray-100 truncate">
        {value}
      </div>
    </div>
  );
}

function InfoRow({
  label,
  value,
  valueNode,
  mono,
  title,
}: {
  label: string;
  value?: string;
  valueNode?: React.ReactNode;
  mono?: boolean;
  title?: string;
}) {
  return (
    <div className="flex items-start justify-between gap-3 text-sm">
      <span className="text-[11px] font-semibold uppercase tracking-wider text-gray-400 dark:text-gray-500 pt-0.5 flex-shrink-0">
        {label}
      </span>
      {valueNode ?? (
        <span
          className={`text-gray-900 dark:text-gray-100 text-right break-all min-w-0 ${mono ? "font-mono text-xs" : ""}`}
          title={title}
        >
          {value}
        </span>
      )}
    </div>
  );
}

function Th({ children }: { children: React.ReactNode }) {
  return (
    <th className="px-4 py-2.5 text-xs font-semibold text-gray-500 dark:text-accent/80 uppercase tracking-wider">
      {children}
    </th>
  );
}
