import { useState, type ReactElement } from 'react';
import { Download, Eye, FileText } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { DocumentPreviewModal } from '@/components/documents/DocumentPreviewModal';
import { prepareDocumentPreview, type DocumentPreviewPayload } from '@/lib/documentPreview';
import type { ClientDocument } from '@/services/api';
import { fileTypeLabel, formatFileSize, saveDocument, type PortalDocumentsApi } from './portalFiles';

export function MessageAttachments({ documents, api }: { documents: ClientDocument[]; api: PortalDocumentsApi }): ReactElement | null {
  if (!documents.length) return null;
  return (
    <ul className="mt-3 space-y-2" aria-label={`${documents.length} attached ${documents.length === 1 ? 'file' : 'files'}`}>
      {documents.map(document => <AttachmentRow key={document.id} document={document} api={api} />)}
    </ul>
  );
}

function AttachmentRow({ document, api }: { document: ClientDocument; api: PortalDocumentsApi }): ReactElement {
  const [previewOpen, setPreviewOpen] = useState(false);
  const [payload, setPayload] = useState<DocumentPreviewPayload | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const archived = Boolean(document.archived_at);
  const checking = document.scan_status === 'pending';

  const download = async (): Promise<void> => {
    try {
      setError(null);
      await saveDocument(api, document);
    } catch (err) {
      setPreviewOpen(false);
      setPayload(null);
      setError(err instanceof Error ? err.message : 'Download failed. Check your connection and try again.');
    }
  };
  const preview = async (): Promise<void> => {
    try {
      setError(null); setPreviewOpen(true); setLoading(true); setPayload(null);
      const file = await api.preview(document.id);
      setPayload(await prepareDocumentPreview(document, file.blob));
    } catch (err) {
      setPreviewOpen(false);
      setError(err instanceof Error ? err.message : 'Preview failed. Check your connection and try again.');
    } finally { setLoading(false); }
  };

  return (
    <li className="rounded-md border border-primary-100 bg-primary-50/70 px-3 py-2 text-sm text-primary-900">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <span className="flex min-w-0 items-start gap-2">
          <FileText className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
          <span className="min-w-0">
            <span className="block break-words font-medium [overflow-wrap:anywhere]">{archived ? `File archived: ${document.title} (${document.file_name})` : document.title}</span>
            <span className="block break-words text-xs text-primary-800 [overflow-wrap:anywhere]">
              {[!archived && document.file_name !== document.title ? document.file_name : null, fileTypeLabel(document.file_name), formatFileSize(document.file_size)].filter(Boolean).join(' · ')}
            </span>
            {archived && <span className="block text-xs text-neutral-700">Kept with this message as a record. Ask Cornerstone if you need it.</span>}
            {checking && <span className="block text-xs text-neutral-700">Safety check in progress</span>}
            {error && <span role="alert" className="block text-xs text-danger-700">{error}</span>}
          </span>
        </span>
        {!archived && !checking && (
          <span className="flex shrink-0 gap-2">
            {document.preview_available && (
              <Button type="button" size="sm" variant="outline" onClick={() => void preview()} aria-label={`Preview ${document.file_name}`}>
                <Eye className="mr-1 h-4 w-4" aria-hidden />Preview
              </Button>
            )}
            <Button type="button" size="sm" variant="outline" onClick={() => void download()} aria-label={`Download ${document.file_name}`}>
              <Download className="mr-1 h-4 w-4" aria-hidden />Download
            </Button>
          </span>
        )}
      </div>
      <DocumentPreviewModal open={previewOpen} onOpenChange={(open) => { setPreviewOpen(open); if (!open) setPayload(null); }}
        document={previewOpen ? document : null} payload={payload} loading={loading} onDownload={() => void download()} activityApi={api} />
    </li>
  );
}
