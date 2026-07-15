/**
 * @file Import History panel — step-by-step instructions and three import modes
 * (rescan default folder, scan any path, upload files/archives). Renders inside
 * the Settings page and keeps all I/O isolated behind the api.import.* client.
 *
 * Robustness notes:
 *   • Every mode funnels through the same server-side parser used for live
 *     ingestion, so token counts and per-model cost are computed identically.
 *   • Re-imports are idempotent: sessions are deduplicated by session ID and
 *     compaction baselines prevent token double-counting.
 *   • Archive extraction is guarded against path traversal on the server.
 *
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { useEffect, useRef, useState, useCallback } from "react";
import { useTranslation } from "react-i18next";
import {
  FolderOpen,
  RefreshCw,
  UploadCloud,
  FileArchive,
  FolderInput,
  CheckCircle2,
  AlertTriangle,
  Loader2,
  HardDrive,
  ListChecks,
  Info,
  XCircle,
  History,
  ChevronDown,
  ChevronRight,
} from "lucide-react";
import { api, type ImportResult } from "../lib/api";
import { eventBus } from "../lib/eventBus";
import type { WSMessage, ImportProgressMessage } from "../lib/types";

type Mode = "rescan" | "path" | "upload";

// Collapsed by default (rc-2: this block used to hog the top of Settings),
// persisted the same way Workflows.tsx persists its accordion sections.
const SECTION_OPEN_KEY = "podium-import-history-open";

function loadSectionOpen(): boolean {
  try {
    return localStorage.getItem(SECTION_OPEN_KEY) === "true";
  } catch {
    return false;
  }
}

function saveSectionOpen(open: boolean) {
  try {
    localStorage.setItem(SECTION_OPEN_KEY, String(open));
  } catch {
    // ignore — persistence is a nicety, not required for correctness
  }
}

type GuideResponse = Awaited<ReturnType<typeof api.import.guide>>;
type Progress = ImportProgressMessage;

export function ImportHistory() {
  const { t } = useTranslation("settings");
  const [mode, setMode] = useState<Mode>("rescan");
  const [guide, setGuide] = useState<GuideResponse | null>(null);
  const [folderPath, setFolderPath] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<Progress | null>(null);
  const [result, setResult] = useState<ImportResult | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [instructionsOpen, setInstructionsOpen] = useState(true);
  const [dragging, setDragging] = useState(false);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [sectionOpen, setSectionOpen] = useState(loadSectionOpen);
  const toggleSection = useCallback(() => {
    setSectionOpen((prev) => {
      const next = !prev;
      saveSectionOpen(next);
      return next;
    });
  }, []);

  // Load the guide once. If the API isn't reachable, fall back to sensible
  // defaults so the UI still explains what to do.
  useEffect(() => {
    api.import
      .guide()
      .then(setGuide)
      .catch(() => {
        setGuide({
          platform: "unknown",
          default_projects_dir: "~/.claude/projects",
          default_projects_dir_display: "~/.claude/projects",
          default_projects_dir_exists: false,
          default_projects_dir_stats: { projects: 0, jsonl_files: 0 },
          archive_command: "tar -czf claude-history.tar.gz -C ~/.claude projects",
          supported_extensions: [".jsonl", ".meta.json"],
          max_upload_bytes: 1024 * 1024 * 1024,
          max_upload_files: 2000,
          steps: [],
        });
      });
  }, []);

  // Stream import progress from the websocket so long-running imports stay
  // responsive. We only render the latest snapshot.
  useEffect(() => {
    return eventBus.subscribe((msg: WSMessage) => {
      if (msg.type !== "import.progress") return;
      setProgress(msg.data as Progress);
    });
  }, []);

  const reset = useCallback(() => {
    setErrorMsg(null);
    setResult(null);
    setProgress(null);
  }, []);

  const handleRescan = async () => {
    reset();
    setRunning(true);
    try {
      const res = await api.import.rescan();
      setResult(res);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
    } finally {
      setRunning(false);
      setProgress(null);
    }
  };

  const handleScanPath = async () => {
    reset();
    const trimmed = folderPath.trim();
    if (!trimmed) {
      setErrorMsg(t("import.errors.pathRequired"));
      return;
    }
    setRunning(true);
    try {
      const res = await api.import.scanPath(trimmed);
      setResult(res);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
    } finally {
      setRunning(false);
      setProgress(null);
    }
  };

  const handleUpload = async () => {
    reset();
    if (files.length === 0) {
      setErrorMsg(t("import.errors.noFiles"));
      return;
    }
    setRunning(true);
    try {
      const res = await api.import.upload(files);
      setResult(res);
      setFiles([]);
      if (fileInputRef.current) fileInputRef.current.value = "";
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
    } finally {
      setRunning(false);
      setProgress(null);
    }
  };

  const onSelectFiles = (list: FileList | null) => {
    if (!list) return;
    const arr = Array.from(list).filter((f) => {
      const lower = f.name.toLowerCase();
      return lower.endsWith(".jsonl") || lower.endsWith(".meta.json");
    });
    setFiles((prev) => {
      const seen = new Set(prev.map((f) => `${f.name}:${f.size}`));
      const next = [...prev];
      for (const f of arr) {
        const key = `${f.name}:${f.size}`;
        if (!seen.has(key)) next.push(f);
      }
      return next;
    });
  };

  // The server only ever reports a "complete" or "error" phase (no granular
  // scan/extract/parse progress), so during a run we show one honest,
  // static message rather than theater copy the server never sends.
  const progressText = running
    ? t("import.progress.running")
    : progress?.phase === "error"
      ? t("import.progress.error")
      : null;

  const totalSize = files.reduce((s, f) => s + f.size, 0);

  return (
    <section>
      <button
        type="button"
        onClick={toggleSection}
        aria-expanded={sectionOpen}
        className="w-full flex items-center justify-between gap-2 mb-1 text-left group"
      >
        <span className="text-sm font-medium text-gray-700 dark:text-gray-300 flex items-center gap-2">
          <History className="w-4 h-4 text-gray-700 dark:text-gray-500" />
          {t("import.title")}
        </span>
        {sectionOpen ? (
          <ChevronDown className="w-4 h-4 text-gray-500 flex-shrink-0" />
        ) : (
          <ChevronRight className="w-4 h-4 text-gray-500 flex-shrink-0" />
        )}
      </button>

      {!sectionOpen && (
        <p className="text-sm text-gray-600 dark:text-gray-500">{t("import.description")}</p>
      )}

      {sectionOpen && (
        <>
      <p className="text-sm text-gray-600 dark:text-gray-500 mb-4">{t("import.description")}</p>

      <div className="card p-5 space-y-5">
        {/* Step-by-step instructions */}
        <div className="border border-border rounded-lg overflow-hidden">
          <button
            onClick={() => setInstructionsOpen((v) => !v)}
            className="w-full flex items-center justify-between px-4 py-3 bg-surface-2 hover:bg-surface-3 transition-colors"
          >
            <span className="flex items-center gap-2 text-xs font-semibold text-gray-700 dark:text-gray-300 uppercase tracking-wider">
              <ListChecks className="w-3.5 h-3.5 text-blue-700 dark:text-blue-400" />
              {t("import.instructions")}
            </span>
            <span className="text-[11px] text-gray-700 dark:text-gray-500">{instructionsOpen ? "▾" : "▸"}</span>
          </button>
          {instructionsOpen && (
            <div className="px-4 py-4 space-y-4 text-sm text-gray-700 dark:text-gray-300 bg-surface-1">
              {/* Default location card */}
              {guide && (
                <div className="flex flex-wrap items-center gap-2 text-xs bg-surface-2 border border-border rounded-md px-3 py-2">
                  <HardDrive className="w-3.5 h-3.5 text-gray-700 dark:text-gray-500 flex-shrink-0" />
                  <span className="text-gray-600 dark:text-gray-400">{t("import.defaultLocation")}:</span>
                  <code className="font-mono text-gray-800 dark:text-gray-200 truncate">
                    {guide.default_projects_dir_display}
                  </code>
                  {guide.default_projects_dir_exists ? (
                    <span className="inline-flex items-center gap-1 text-emerald-700 dark:text-emerald-400 bg-emerald-50 dark:bg-emerald-500/10 border border-emerald-200 dark:border-emerald-500/20 px-2 py-0.5 rounded-full">
                      <CheckCircle2 className="w-3 h-3" />
                      {t("import.locationFound")}
                      <span className="text-gray-700 dark:text-gray-500 ml-1">
                        · {guide.default_projects_dir_stats.projects} {t("import.projectsLabel")},{" "}
                        {guide.default_projects_dir_stats.jsonl_files} {t("import.jsonlLabel")}
                      </span>
                    </span>
                  ) : (
                    <span className="inline-flex items-center gap-1 text-amber-700 dark:text-amber-400 bg-amber-50 dark:bg-amber-500/10 border border-amber-200 dark:border-amber-500/20 px-2 py-0.5 rounded-full">
                      <AlertTriangle className="w-3 h-3" />
                      {t("import.locationMissing")}
                    </span>
                  )}
                </div>
              )}

              {/* Steps */}
              <div className="space-y-3">
                <Step title={t("import.stepLocate")} body={t("import.stepLocateBody")} />
                <Step title={t("import.stepArchive")} body={t("import.stepArchiveBody")} />
                <Step title={t("import.stepChoose")} body={t("import.stepChooseBody")} />
                <Step title={t("import.stepVerify")} body={t("import.stepVerifyBody")} />
              </div>

              <div className="text-[11px] text-gray-700 dark:text-gray-500 flex items-start gap-2 pt-2 border-t border-border">
                <Info className="w-3 h-3 mt-0.5 flex-shrink-0" />
                <span>{t("import.accuracyNote")}</span>
              </div>
            </div>
          )}
        </div>

        {/* Mode switcher */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
          <ModeButton
            active={mode === "rescan"}
            icon={<RefreshCw className="w-3.5 h-3.5" />}
            title={t("import.modeRescan")}
            desc={t("import.modeRescanDesc")}
            onClick={() => setMode("rescan")}
          />
          <ModeButton
            active={mode === "path"}
            icon={<FolderInput className="w-3.5 h-3.5" />}
            title={t("import.modeFolder")}
            desc={t("import.modeFolderDesc")}
            onClick={() => setMode("path")}
          />
          <ModeButton
            active={mode === "upload"}
            icon={<UploadCloud className="w-3.5 h-3.5" />}
            title={t("import.modeUpload")}
            desc={t("import.modeUploadDesc")}
            onClick={() => setMode("upload")}
          />
        </div>

        {/* Mode panel */}
        <div className="bg-surface-2 border border-border rounded-lg p-4">
          {mode === "rescan" && (
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="flex items-center gap-3 min-w-0">
                <FolderOpen className="w-4 h-4 text-gray-700 dark:text-gray-500 flex-shrink-0" />
                <code className="font-mono text-xs text-gray-700 dark:text-gray-300 truncate">
                  {guide?.default_projects_dir_display || "~/.claude/projects"}
                </code>
              </div>
              <button
                onClick={handleRescan}
                disabled={running}
                className="btn-primary text-xs disabled:opacity-50"
              >
                {running ? (
                  <Loader2 className="w-3.5 h-3.5 animate-spin" />
                ) : (
                  <RefreshCw className="w-3.5 h-3.5" />
                )}
                {t("import.runRescan")}
              </button>
            </div>
          )}

          {mode === "path" && (
            <div className="space-y-3">
              <div>
                <input
                  type="text"
                  value={folderPath}
                  onChange={(e) => setFolderPath(e.target.value)}
                  placeholder={t("import.folderPlaceholder")}
                  className="input w-full text-sm font-mono"
                  spellCheck={false}
                />
                <p className="text-[11px] text-gray-700 dark:text-gray-500 mt-1.5">{t("import.folderHelper")}</p>
              </div>
              <div className="flex justify-end">
                <button
                  onClick={handleScanPath}
                  disabled={running}
                  className="btn-primary text-xs disabled:opacity-50"
                >
                  {running ? (
                    <Loader2 className="w-3.5 h-3.5 animate-spin" />
                  ) : (
                    <FolderInput className="w-3.5 h-3.5" />
                  )}
                  {t("import.runScan")}
                </button>
              </div>
            </div>
          )}

          {mode === "upload" && (
            <div className="space-y-3">
              <div
                onClick={() => fileInputRef.current?.click()}
                onDragOver={(e) => {
                  e.preventDefault();
                  setDragging(true);
                }}
                onDragLeave={() => setDragging(false)}
                onDrop={(e) => {
                  e.preventDefault();
                  setDragging(false);
                  onSelectFiles(e.dataTransfer.files);
                }}
                className={`border-2 border-dashed rounded-lg px-4 py-8 text-center cursor-pointer transition-colors ${
                  dragging
                    ? "border-blue-400 bg-blue-500/5"
                    : "border-border hover:border-gray-500 bg-surface-1"
                }`}
              >
                <UploadCloud className="w-6 h-6 text-gray-700 dark:text-gray-500 mx-auto mb-2" />
                <p className="text-sm text-gray-700 dark:text-gray-300">{t("import.dropzoneHint")}</p>
                <p className="text-[11px] text-gray-700 dark:text-gray-500 mt-1">{t("import.dropzoneSub")}</p>
                <input
                  ref={fileInputRef}
                  type="file"
                  multiple
                  accept=".jsonl,.meta.json"
                  onChange={(e) => onSelectFiles(e.target.files)}
                  className="hidden"
                />
              </div>
              {files.length > 0 && (
                <div className="flex flex-wrap items-center justify-between gap-2 text-xs bg-surface-3 rounded-md px-3 py-2">
                  <span className="text-gray-600 dark:text-gray-400">
                    <FileArchive className="w-3.5 h-3.5 inline mr-1.5 text-gray-700 dark:text-gray-500" />
                    {t("import.filesSelected", { count: files.length })}
                    <span className="text-gray-600 ml-2">({formatBytes(totalSize)})</span>
                  </span>
                  <button
                    onClick={() => {
                      setFiles([]);
                      if (fileInputRef.current) fileInputRef.current.value = "";
                    }}
                    className="text-gray-700 dark:text-gray-500 hover:text-gray-300 text-[11px]"
                  >
                    {t("import.clearSelection")}
                  </button>
                </div>
              )}
              <div className="flex justify-end">
                <button
                  onClick={handleUpload}
                  disabled={running || files.length === 0}
                  className="btn-primary text-xs disabled:opacity-50"
                >
                  {running ? (
                    <Loader2 className="w-3.5 h-3.5 animate-spin" />
                  ) : (
                    <UploadCloud className="w-3.5 h-3.5" />
                  )}
                  {t("import.runUpload")}
                </button>
              </div>
            </div>
          )}
        </div>

        {/* In-flight progress */}
        {progressText && (
          <div className="flex items-center gap-2 text-xs text-gray-600 dark:text-gray-400 bg-surface-2 border border-border rounded-md px-3 py-2">
            <Loader2 className="w-3.5 h-3.5 animate-spin text-blue-700 dark:text-blue-400 flex-shrink-0" />
            <span className="truncate">{progressText}</span>
          </div>
        )}

        {/* Errors */}
        {errorMsg && (
          <div className="flex items-start gap-2 text-xs text-red-700 dark:text-red-400 bg-red-50 dark:bg-red-500/10 border border-red-200 dark:border-red-500/20 rounded-md px-3 py-2">
            <XCircle className="w-3.5 h-3.5 mt-0.5 flex-shrink-0" />
            <span>{errorMsg}</span>
          </div>
        )}

        {/* Result summary */}
        {result && !running && (
          <div className="border border-emerald-200 dark:border-emerald-500/20 bg-emerald-500/5 rounded-lg px-4 py-3 space-y-2">
            <div className="flex items-center gap-2 text-xs font-semibold text-emerald-700 dark:text-emerald-400 uppercase tracking-wider">
              <CheckCircle2 className="w-3.5 h-3.5" />
              {t("import.result.title")}
            </div>
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs">
              <ResultStat
                label={t("import.result.imported", { count: result.imported })}
                value={result.imported}
                color="text-emerald-700 dark:text-emerald-300"
              />
              <ResultStat
                label={t("import.result.backfilled", { count: result.backfilled ?? 0 })}
                value={result.backfilled ?? 0}
                color="text-blue-700 dark:text-blue-300"
              />
              <ResultStat
                label={t("import.result.skipped", { count: result.skipped })}
                value={result.skipped}
                color="text-gray-600 dark:text-gray-400"
              />
              <ResultStat
                label={t("import.result.errors", { count: result.errors })}
                value={result.errors}
                color={result.errors > 0 ? "text-red-700 dark:text-red-300" : "text-gray-700 dark:text-gray-500"}
              />
            </div>
            {typeof result.files_scanned === "number" && (
              <p className="text-[11px] text-gray-700 dark:text-gray-500">
                {t("import.result.filesScanned", { count: result.files_scanned })}
                {result.path ? ` · ${result.path}` : ""}
              </p>
            )}
          </div>
        )}
      </div>
        </>
      )}
    </section>
  );
}

function Step({
  title,
  body,
  children,
}: {
  title: string;
  body: string;
  children?: React.ReactNode;
}) {
  return (
    <div>
      <p className="text-sm font-medium text-gray-800 dark:text-gray-200">{title}</p>
      <p className="text-xs text-gray-600 dark:text-gray-400 mt-1 whitespace-pre-line">{body}</p>
      {children}
    </div>
  );
}

function ModeButton({
  active,
  icon,
  title,
  desc,
  onClick,
}: {
  active: boolean;
  icon: React.ReactNode;
  title: string;
  desc: string;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className={`text-left p-3 rounded-lg border transition-colors ${
        active
          ? "border-blue-500/40 bg-blue-50 dark:bg-blue-500/10"
          : "border-border bg-surface-2 hover:bg-surface-3"
      }`}
    >
      <div
        className={`flex items-center gap-1.5 text-xs font-medium mb-1 ${
          active ? "text-blue-700 dark:text-blue-300" : "text-gray-700 dark:text-gray-300"
        }`}
      >
        {icon}
        {title}
      </div>
      <p className="text-[11px] text-gray-700 dark:text-gray-500 leading-snug">{desc}</p>
    </button>
  );
}

function ResultStat({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <div className="bg-surface-2 rounded-md px-2.5 py-2">
      <p className={`text-sm font-semibold ${color}`}>{value.toLocaleString()}</p>
      <p className="text-[10px] text-gray-700 dark:text-gray-500 uppercase tracking-wider mt-0.5">{label}</p>
    </div>
  );
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}
