import { useEffect } from 'react';
import { Download, FileText, Image as ImageIcon, Loader2, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import type { ClientDocument } from '@/services/api';
import type { DocumentPreviewPayload } from '@/lib/documentPreview';

export function DocumentPreviewModal({
  open,
  onOpenChange,
  document,
  payload,
  loading,
  onDownload,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  document: ClientDocument | null;
  payload: DocumentPreviewPayload | null;
  loading: boolean;
  onDownload: () => void;
}) {
  useEffect(() => {
    return () => {
      if (payload?.objectUrl) {
        URL.revokeObjectURL(payload.objectUrl);
      }
    };
  }, [payload]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="dialog-wide max-h-[90vh] overflow-y-auto p-0">
        <DialogHeader className="border-b border-neutral-200 px-6 py-5">
          <div className="flex items-start justify-between gap-4">
            <div>
              <DialogTitle>{document?.title || 'Document preview'}</DialogTitle>
              <DialogDescription>
                {document ? `${document.file_name} • ${document.content_type}` : 'Preview document'}
              </DialogDescription>
            </div>
            <div className="flex items-center gap-3">
              <Button variant="outline" size="sm" onClick={onDownload}>
                <Download className="mr-2 h-4 w-4" />
                Download file
              </Button>
              <Button size="sm" onClick={() => onOpenChange(false)}>
                Close
              </Button>
              <button
                type="button"
                onClick={() => onOpenChange(false)}
                className="rounded-lg p-2 text-neutral-400 transition-colors hover:bg-neutral-100 hover:text-neutral-700"
                aria-label="Close preview"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
          </div>
        </DialogHeader>

        <div className="px-6 py-5">
          {loading ? (
            <div className="flex min-h-[420px] items-center justify-center rounded-2xl border border-neutral-200 bg-neutral-50">
              <div className="text-center">
                <Loader2 className="mx-auto h-8 w-8 animate-spin text-primary-600" />
                <p className="mt-3 text-sm text-neutral-500">Preparing preview...</p>
              </div>
            </div>
          ) : payload?.kind === 'pdf' && payload.objectUrl ? (
            <div className="overflow-hidden rounded-2xl border border-neutral-200 bg-neutral-950/5">
              <iframe title={document?.title || 'Document preview'} src={payload.objectUrl} className="h-[70vh] w-full bg-white" />
            </div>
          ) : payload?.kind === 'image' && payload.objectUrl ? (
            <div className="flex min-h-[420px] items-center justify-center rounded-2xl border border-neutral-200 bg-neutral-50 p-6">
              <img src={payload.objectUrl} alt={document?.title || 'Document preview'} className="max-h-[70vh] rounded-xl shadow-sm" />
            </div>
          ) : payload?.kind === 'text' ? (
            <div className="min-h-[420px] overflow-auto rounded-2xl border border-neutral-200 bg-white p-5">
              {payload.message ? <p className="mb-4 text-sm text-neutral-500">{payload.message}</p> : null}
              <pre className="whitespace-pre-wrap break-words font-sans text-sm leading-6 text-neutral-800">
                {payload.textContent}
              </pre>
            </div>
          ) : payload?.kind === 'html' ? (
            <div className="min-h-[420px] overflow-auto rounded-2xl border border-neutral-200 bg-white p-5">
              {payload.message ? <p className="mb-4 text-sm text-neutral-500">{payload.message}</p> : null}
              <div
                className="document-preview-html prose prose-neutral max-w-none prose-table:my-0 prose-table:w-full prose-th:border prose-th:border-neutral-200 prose-th:bg-neutral-50 prose-th:px-3 prose-th:py-2 prose-td:border prose-td:border-neutral-200 prose-td:px-3 prose-td:py-2"
                dangerouslySetInnerHTML={{ __html: payload.htmlContent || '' }}
              />
            </div>
          ) : (
            <div className="flex min-h-[420px] items-center justify-center rounded-2xl border border-dashed border-neutral-300 bg-neutral-50 px-8 py-10">
              <div className="max-w-md text-center">
                <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-white text-primary-700 shadow-sm">
                  {document?.content_type.startsWith('image/') ? <ImageIcon className="h-7 w-7" /> : <FileText className="h-7 w-7" />}
                </div>
                <p className="mt-4 text-base font-medium text-neutral-900">Preview not available</p>
                <p className="mt-2 text-sm leading-6 text-neutral-500">
                  {payload?.message || 'This file uploaded successfully, but this file type cannot be previewed inside the app yet.'}
                </p>
              </div>
            </div>
          )}
        </div>

        <DialogFooter className="border-t border-neutral-200 px-6 py-4 sm:justify-between">
          <p className="text-sm text-neutral-500">Use preview for quick review, then download if you need the original file.</p>
          <div className="flex items-center gap-3">
            <Button variant="outline" onClick={() => onOpenChange(false)}>
              Close
            </Button>
            <Button onClick={onDownload}>
              <Download className="mr-2 h-4 w-4" />
              Download file
            </Button>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
