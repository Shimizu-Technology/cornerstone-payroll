import { Component, lazy, Suspense, useCallback, useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { Download, Loader2, PanelRightClose, PanelRightOpen } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { SheetPreview } from '@/components/documents/SheetPreview';
import { importSourceFiles } from '@/lib/importSources';
import { isJsonBlob, readSheetPreview, type SheetPreviewData } from '@/lib/sheetPreview';
import { cn } from '@/lib/utils';
import { payrollIntakeImportsApi, type ImportSourceDocument } from '@/services/api';

function createPdfPreview(chunk?: URL) {
  return lazy(async () => {
    const module: typeof import('@/components/documents/PdfPreview') = chunk
      ? await import(/* @vite-ignore */ chunk.href)
      : await import('@/components/documents/PdfPreview');
    return { default: module.PdfDocumentView };
  });
}

function retryChunk(error: unknown, attempt: number): URL | undefined {
  if (!(error instanceof TypeError)) return;
  const match = error.message.match(/(?:Failed to fetch dynamically imported module|error loading dynamically imported module): (https?:\/\/\S+)$/i);
  if (!match) return;

  try {
    const chunk = new URL(match[1]);
    const expectedPath = /^\/(?:assets\/PdfPreview-[\w-]+\.js|src\/components\/documents\/PdfPreview\.tsx)$/;
    if (chunk.origin !== window.location.origin || !expectedPath.test(chunk.pathname)) return;

    // The browser remembers failed module fetches by URL within this page.
    chunk.searchParams.set('previewRetry', `${Date.now()}-${attempt}`);
    return chunk;
  } catch {
    return undefined;
  }
}

class PdfPreviewBoundary extends Component<{ children: ReactNode; fallback: (error: unknown) => ReactNode }, { failure: { error: unknown } | null }> {
  state: { failure: { error: unknown } | null } = { failure: null };

  static getDerivedStateFromError(error: unknown) {
    return { failure: { error } };
  }

  render() {
    return this.state.failure ? this.props.fallback(this.state.failure.error) : this.props.children;
  }
}

type TabKey = 'pdf' | 'workbook';
type Loaded =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'unavailable'; message: string }
  | { status: 'pdf'; blob: Blob }
  | { status: 'sheet'; data: SheetPreviewData };

// Matches the xl breakpoint where the panel sits beside the review. Narrower
// screens keep the review table readable and open the files as a toggle.
const SIDE_BY_SIDE_QUERY = '(min-width: 1280px)';

function startsOpen() {
  try {
    return typeof window !== 'undefined' && typeof window.matchMedia === 'function' && window.matchMedia(SIDE_BY_SIDE_QUERY).matches;
  } catch {
    return false;
  }
}

// The retained Revel PDF and change workbook beside import review. Both
// routes (portal submission and local Import MoSa) read the same verified
// files the review was built from, so staff see exactly what was imported.
export function ImportSourcePanel({ payPeriodId, importId, documents, className }: {
  payPeriodId: number;
  importId: number;
  documents?: ImportSourceDocument[];
  className?: string;
}) {
  const { pdf, workbook } = importSourceFiles(documents);
  const tabs = [
    pdf ? { key: 'pdf' as const, label: 'Revel PDF', file: pdf } : null,
    workbook ? { key: 'workbook' as const, label: 'Workbook', file: workbook } : null,
  ].filter((tab): tab is { key: TabKey; label: string; file: ImportSourceDocument } => Boolean(tab));
  const [open, setOpen] = useState(startsOpen);
  const [selected, setSelected] = useState<TabKey>(tabs[0]?.key || 'pdf');
  const [loaded, setLoaded] = useState<Record<number, Loaded>>({});
  // Mirrors `loaded` so the loader can skip files it already has without re-running on every update.
  const loadedRef = useRef<Record<number, Loaded>>({});
  const [attempt, setAttempt] = useState(0);
  const [downloadError, setDownloadError] = useState<string | null>(null);
  const [preview, setPreview] = useState(() => ({ View: createPdfPreview(), attempt: 0 }));
  const baseId = useId();
  const active = tabs.find((tab) => tab.key === selected) || tabs[0];
  const activeId = active?.file.id;
  const state = activeId === undefined ? undefined : loaded[activeId];

  const setEntry = useCallback((id: number, entry: Loaded | null) => {
    const next = { ...loadedRef.current };
    if (entry) next[id] = entry;
    else delete next[id];
    loadedRef.current = next;
    setLoaded(next);
  }, []);

  useEffect(() => {
    if (!open || activeId === undefined || loadedRef.current[activeId]) return;
    let current = true;
    setEntry(activeId, { status: 'loading' });
    payrollIntakeImportsApi.previewSource(payPeriodId, importId, activeId).then(async ({ blob }) => {
      const result = await readSheetPreview(blob);
      const next: Loaded = result ? ('sheet' in result ? { status: 'sheet', data: result.sheet } : { status: 'unavailable', message: result.unavailable })
        : isJsonBlob(blob) ? { status: 'unavailable', message: 'This file could not be shown here. Download it to open it.' }
          : { status: 'pdf', blob };
      if (current) setEntry(activeId, next);
    }).catch((error: unknown) => {
      if (current) setEntry(activeId, { status: 'error', message: error instanceof Error ? error.message : 'This file could not be shown here.' });
    });
    return () => {
      current = false;
      // Let a later visit retry a request that was still running.
      if (loadedRef.current[activeId]?.status === 'loading') setEntry(activeId, null);
    };
  }, [open, activeId, payPeriodId, importId, attempt, setEntry]);

  if (!active) return null;

  const download = async () => {
    setDownloadError(null);
    try {
      const { blob, filename } = await payrollIntakeImportsApi.downloadSource(payPeriodId, importId, active.file.id);
      const url = URL.createObjectURL(blob);
      const link = window.document.createElement('a');
      link.href = url;
      link.download = filename || active.file.filename;
      window.document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
    } catch (error) {
      setDownloadError(error instanceof Error ? error.message : 'Download failed');
    }
  };

  const contentId = `${baseId}-content`;
  const summary = tabs.map((tab) => tab.label).join(' · ');

  if (!open) {
    return (
      <aside aria-label="Source files" className={cn('min-w-0 rounded-2xl border border-neutral-200 bg-white xl:sticky xl:top-0 xl:shrink-0', className)}>
        <button
          type="button"
          aria-expanded={false}
          aria-controls={contentId}
          onClick={() => setOpen(true)}
          className="flex min-h-11 w-full items-center justify-center gap-2 rounded-2xl px-3 py-2 text-sm font-medium text-primary-700 hover:bg-primary-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 xl:w-11 xl:px-0 xl:py-4 xl:[writing-mode:vertical-rl]"
        >
          <PanelRightOpen className="h-4 w-4 shrink-0 xl:rotate-90" aria-hidden="true" />
          <span>Show source files</span>{' '}
          <span className="font-normal text-neutral-600">({summary})</span>
        </button>
      </aside>
    );
  }

  return (
    <aside
      aria-label="Source files"
      className={cn(
        'flex h-[min(75vh,75dvh)] min-w-0 flex-col overflow-hidden rounded-2xl border border-neutral-200 bg-white',
        'xl:sticky xl:top-0 xl:h-[calc(100vh-17rem)] xl:min-h-[28rem] xl:w-[40%] xl:shrink-0',
        className
      )}
    >
      <div className="flex shrink-0 flex-wrap items-center gap-2 border-b border-neutral-200 px-3 py-2">
        <h3 className="text-sm font-semibold text-neutral-900">Source files</h3>
        {tabs.length > 0 && (
          <div role="tablist" aria-label="Source file" className="flex gap-1">
            {tabs.map((tab) => (
              <button
                key={tab.key}
                id={`${baseId}-tab-${tab.key}`}
                type="button"
                role="tab"
                aria-selected={tab.key === active.key}
                aria-controls={contentId}
                onClick={() => setSelected(tab.key)}
                className={cn(
                  'min-h-11 rounded-lg px-3 text-sm font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 sm:min-h-9',
                  tab.key === active.key ? 'bg-primary-50 text-primary-800' : 'text-neutral-600 hover:bg-neutral-100'
                )}
              >
                {tab.label}
              </button>
            ))}
          </div>
        )}
        <div className="ml-auto flex items-center gap-1">
          <Button type="button" variant="ghost" size="sm" className="max-sm:min-h-11" onClick={() => void download()} aria-label={`Download ${active.file.filename}`}>
            <Download className="h-4 w-4" aria-hidden="true" />
          </Button>
          <Button type="button" variant="ghost" size="sm" className="max-sm:min-h-11" aria-expanded={true} aria-controls={contentId} onClick={() => setOpen(false)}>
            <PanelRightClose className="mr-1 h-4 w-4" aria-hidden="true" />Hide
          </Button>
        </div>
      </div>
      <p className="shrink-0 truncate border-b border-neutral-100 px-3 py-1 text-xs text-neutral-600" title={active.file.filename}>{active.file.filename}</p>
      {downloadError && <p role="alert" className="shrink-0 px-3 py-1 text-xs text-danger-700">{downloadError}</p>}
      <div id={contentId} role="tabpanel" aria-labelledby={`${baseId}-tab-${active.key}`} className="flex min-h-0 flex-1 flex-col">
        {!state || state.status === 'loading' ? (
          <p role="status" className="flex flex-1 items-center justify-center gap-2 text-sm text-neutral-600">
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />Loading {active.label}…
          </p>
        ) : state.status === 'error' ? (
          <div className="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
            <p role="alert" className="max-w-sm text-sm text-neutral-700">{state.message}</p>
            <Button type="button" variant="outline" size="sm" onClick={() => { setEntry(active.file.id, null); setAttempt((count) => count + 1); }}>Try again</Button>
          </div>
        ) : state.status === 'unavailable' ? (
          <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
            <p className="font-medium text-neutral-900">Preview not available</p>
            <p className="max-w-sm text-sm text-neutral-700">{state.message}</p>
          </div>
        ) : state.status === 'pdf' ? (
          <PdfPreviewBoundary key={preview.attempt} fallback={error => (
            <div className="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
              <p role="alert" className="text-sm text-neutral-700">The PDF preview could not load.</p>
              {preview.attempt >= 1 && (
                <p className="max-w-sm text-sm text-neutral-600">Reload the page to try again.</p>
              )}
              <div className="flex flex-wrap justify-center gap-2">
                <Button
                  type="button"
                  variant={preview.attempt >= 1 ? 'primary' : 'outline'}
                  size="sm"
                  className="max-sm:min-h-11"
                  onClick={() => void download()}
                >
                  Download PDF
                </Button>
                {preview.attempt >= 1 ? (
                  <Button type="button" variant="outline" size="sm" className="max-sm:min-h-11" onClick={() => window.location.reload()}>
                    Reload page
                  </Button>
                ) : (
                  <Button type="button" variant="outline" size="sm" className="max-sm:min-h-11" onClick={() => {
                    const nextAttempt = preview.attempt + 1;
                    setPreview({ View: createPdfPreview(retryChunk(error, nextAttempt)), attempt: nextAttempt });
                  }}>Retry preview</Button>
                )}
              </div>
            </div>
          )}>
            <Suspense fallback={<p role="status" className="p-4 text-sm text-neutral-600">Loading PDF preview…</p>}>
              <preview.View blob={state.blob} className="flex-1" />
            </Suspense>
          </PdfPreviewBoundary>
        ) : (
          <SheetPreview data={state.data} className="flex-1" />
        )}
      </div>
    </aside>
  );
}
