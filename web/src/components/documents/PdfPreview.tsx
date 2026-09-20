/* eslint-disable react-refresh/only-export-components */
import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { Download, Printer, Search, X } from 'lucide-react';
import { getDocument, GlobalWorkerOptions, type PDFDocumentLoadingTask, type PDFDocumentProxy, type RenderTask } from 'pdfjs-dist';
import pdfWorkerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';

GlobalWorkerOptions.workerSrc = pdfWorkerUrl;

export type PdfArtifact = { blob: Blob; filename: string; title?: string; note?: string };

function downloadPdf(artifact: PdfArtifact, url: string) {
  const link = document.createElement('a');
  link.href = url;
  link.download = artifact.filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
}

export function PdfPreview({ artifact, onClose }: { artifact: PdfArtifact | null; onClose: () => void }) {
  const [urlState, setUrlState] = useState<{ artifact: PdfArtifact; url: string } | null>(null);
  const url = urlState?.artifact === artifact ? urlState.url : null;
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const printFrameRef = useRef<HTMLIFrameElement>(null);
  const [pdfDocument, setPdfDocument] = useState<PDFDocumentProxy | null>(null);
  const [pageNumber, setPageNumber] = useState(1);
  const [loading, setLoading] = useState(false);
  const [rendering, setRendering] = useState(false);
  const [zoomed, setZoomed] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!artifact) {
      setUrlState(null);
      return;
    }
    const objectUrl = URL.createObjectURL(artifact.blob);
    setUrlState({ artifact, url: objectUrl });
    return () => URL.revokeObjectURL(objectUrl);
  }, [artifact]);

  useEffect(() => {
    if (!artifact) {
      setPdfDocument(null);
      return;
    }

    let cancelled = false;
    let loadingTask: PDFDocumentLoadingTask | null = null;
    setPdfDocument(null);
    setPageNumber(1);
    setZoomed(false);
    setError(null);
    setLoading(true);
    void artifact.blob.arrayBuffer().then((data) => {
      if (cancelled) return;
      loadingTask = getDocument({ data: new Uint8Array(data) });
      return loadingTask.promise;
    }).then((pdf) => {
      if (!pdf) return;
      if (cancelled) return;
      setPdfDocument(pdf);
    }).catch(() => {
      if (!cancelled) setError('This PDF could not be displayed. You can still download and open it in a PDF viewer.');
    }).finally(() => {
      if (!cancelled) setLoading(false);
    });
    return () => {
      cancelled = true;
      if (loadingTask) void loadingTask.destroy();
    };
  }, [artifact]);

  useEffect(() => {
    if (!pdfDocument || !canvasRef.current) return;
    let cancelled = false;
    let task: RenderTask | null = null;
    setRendering(true);
    setError(null);
    void pdfDocument.getPage(pageNumber).then((page) => {
      if (cancelled || !canvasRef.current) return;
      const viewport = page.getViewport({ scale: 1.75 });
      const canvas = canvasRef.current;
      canvas.width = Math.ceil(viewport.width);
      canvas.height = Math.ceil(viewport.height);
      task = page.render({ canvas, viewport });
      return task.promise;
    }).then(() => {
      if (!cancelled) setRendering(false);
    }).catch(() => {
      if (!cancelled) {
        setRendering(false);
        setError('This page could not be displayed. Download the PDF to view it in another viewer.');
      }
    });
    return () => {
      cancelled = true;
      task?.cancel();
    };
  }, [pdfDocument, pageNumber]);

  return (
    <Dialog open={Boolean(artifact)} onOpenChange={(open) => { if (!open) onClose(); }}>
      <DialogContent className="dialog-wide flex h-[min(88vh,1000px)] w-full flex-col overflow-hidden p-0">
        <DialogHeader className="shrink-0 border-b px-5 py-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <DialogTitle>{artifact?.title || 'PDF preview'}</DialogTitle>
              <DialogDescription>{artifact?.note || 'Review the PDF here, then print or download a copy if needed.'}</DialogDescription>
            </div>
            <div className="flex gap-2">
              <Button variant="outline" disabled={!url} onClick={() => printFrameRef.current?.contentWindow?.print()}><Printer className="mr-2 h-4 w-4" />Print</Button>
              <Button variant="outline" disabled={!url || !artifact} onClick={() => {
                if (url && artifact) downloadPdf(artifact, url);
              }}><Download className="mr-2 h-4 w-4" />Download</Button>
              <Button variant="ghost" size="sm" onClick={onClose} aria-label="Close PDF preview"><X className="h-4 w-4" /></Button>
            </div>
          </div>
        </DialogHeader>
        <div className="flex min-h-0 flex-1 flex-col bg-slate-100">
          <div className="flex min-h-11 shrink-0 flex-wrap items-center justify-center gap-3 border-b border-slate-200 bg-white px-3 py-1 text-sm text-slate-700">
            <Button variant="ghost" size="sm" disabled={!pdfDocument || pageNumber <= 1} onClick={() => setPageNumber((page) => page - 1)}>Previous</Button>
            <span role="status">{pdfDocument ? `Page ${pageNumber} of ${pdfDocument.numPages}` : loading ? 'Loading PDF…' : 'PDF preview'}</span>
            <Button variant="ghost" size="sm" disabled={!pdfDocument || pageNumber >= pdfDocument.numPages} onClick={() => setPageNumber((page) => page + 1)}>Next</Button>
            <Button variant="ghost" size="sm" disabled={!pdfDocument} onClick={() => setZoomed((value) => !value)}>
              <Search className="mr-1.5 h-4 w-4" />{zoomed ? 'Fit page' : 'Zoom in'}
            </Button>
          </div>
          {error && <p role="alert" className="px-4 py-3 text-center text-sm text-red-700">{error}</p>}
          <div className="min-h-0 flex-1 overflow-auto p-3 text-center sm:p-6">
            {loading && <p className="py-12 text-sm text-slate-600">Rendering PDF preview…</p>}
            {pdfDocument && <canvas ref={canvasRef} aria-label={`Page ${pageNumber} preview`} className={`mx-auto h-auto bg-white shadow-lg ${zoomed ? 'max-w-none' : 'max-w-full'} ${rendering ? 'opacity-50' : ''}`} />}
          </div>
        </div>
        {url && <iframe ref={printFrameRef} title="PDF print source" src={url} className="absolute h-0 w-0 border-0" aria-hidden="true" tabIndex={-1} />}
      </DialogContent>
    </Dialog>
  );
}

const PdfPreviewContext = createContext<((artifact: PdfArtifact) => void) | null>(null);

export function PdfPreviewProvider({ children }: { children: ReactNode }) {
  const [artifact, setArtifact] = useState<PdfArtifact | null>(null);
  const show = useCallback((next: PdfArtifact) => setArtifact(next), []);
  return <PdfPreviewContext.Provider value={show}>{children}<PdfPreview artifact={artifact} onClose={() => setArtifact(null)} /></PdfPreviewContext.Provider>;
}

export function usePdfPreview() {
  const show = useContext(PdfPreviewContext);
  if (!show) throw new Error('PDF preview requires a PdfPreviewProvider');
  return show;
}
