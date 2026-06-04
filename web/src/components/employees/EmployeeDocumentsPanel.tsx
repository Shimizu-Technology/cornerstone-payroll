import { useCallback, useEffect, useRef, useState } from 'react';
import { Download, Eye, FileText, UploadCloud, Trash2, X } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { DocumentPreviewModal } from '@/components/documents/DocumentPreviewModal';
import { prepareDocumentPreview } from '@/lib/documentPreview';
import { useAuth } from '@/contexts/AuthContext';
import { adminClientDocumentsApi, clientDocumentsApi } from '@/services/api';
import type { ClientDocument } from '@/services/api';

const documentCategories = [
  { value: 'employee_onboarding', label: 'W-4 / W-9 / Onboarding' },
  { value: 'identity', label: 'Identity / I-9 Support' },
  { value: 'direct_deposit', label: 'Direct Deposit' },
  { value: 'insurance', label: 'Insurance / Benefits' },
  { value: 'tax_notice', label: 'Tax Notice' },
  { value: 'payroll_source', label: 'Payroll Source' },
  { value: 'misc', label: 'Miscellaneous' },
];

const ACCEPTED_UPLOAD_TYPES = '.pdf,.png,.jpg,.jpeg,.webp,.txt,.csv,.doc,.docx,.xls,.xlsx';

interface EmployeeDocumentsPanelProps {
  employeeId: number;
  employeeName: string;
  isClient: boolean;
}

function formatFileSize(bytes: number) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
}

function categoryLabel(value: string) {
  return documentCategories.find((category) => category.value === value)?.label || value;
}

export function EmployeeDocumentsPanel({ employeeId, employeeName, isClient }: EmployeeDocumentsPanelProps) {
  const { user } = useAuth();
  const [documents, setDocuments] = useState<ClientDocument[]>([]);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [previewDocument, setPreviewDocument] = useState<ClientDocument | null>(null);
  const [previewOpen, setPreviewOpen] = useState(false);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewPayload, setPreviewPayload] = useState<Awaited<ReturnType<typeof prepareDocumentPreview>> | null>(null);
  const [form, setForm] = useState({
    title: '',
    category: 'employee_onboarding',
    notes: '',
    visible_to_client: true,
    files: [] as File[],
  });
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const api = isClient ? clientDocumentsApi : adminClientDocumentsApi;

  const loadDocuments = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await api.list({ employee_id: employeeId });
      setDocuments(response.data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load employee documents');
    } finally {
      setLoading(false);
    }
  }, [api, employeeId]);

  useEffect(() => {
    void loadDocuments();
  }, [loadDocuments]);

  const selectedFiles = form.files;
  const supportsSingleTitle = selectedFiles.length <= 1;

  const handleUpload = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (selectedFiles.length === 0) {
      setError('Choose at least one employee document to upload');
      return;
    }

    try {
      setUploading(true);
      setError(null);
      setSuccess(null);
      const payload = new FormData();
      selectedFiles.forEach((file) => payload.append('files[]', file));
      payload.append('employee_id', String(employeeId));
      payload.append('category', form.category);
      if (!isClient) payload.append('visible_to_client', String(form.visible_to_client));
      if (supportsSingleTitle && form.title.trim()) payload.append('title', form.title.trim());
      if (form.notes.trim()) payload.append('notes', form.notes.trim());

      const response = await api.upload(payload);
      setSuccess(response.message || 'Employee document uploaded');
      setForm({ title: '', category: 'employee_onboarding', notes: '', visible_to_client: true, files: [] });
      if (fileInputRef.current) fileInputRef.current.value = '';
      await loadDocuments();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to upload employee document');
    } finally {
      setUploading(false);
    }
  };

  const handleDownload = async (document: ClientDocument) => {
    const file = await api.download(document.id);
    const url = URL.createObjectURL(file.blob);
    const link = window.document.createElement('a');
    link.href = url;
    link.download = file.filename || document.file_name;
    window.document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  };

  const handlePreview = async (document: ClientDocument) => {
    try {
      setError(null);
      setPreviewDocument(document);
      setPreviewOpen(true);
      setPreviewLoading(true);
      setPreviewPayload(null);
      const file = await api.preview(document.id);
      setPreviewPayload(await prepareDocumentPreview(document, file.blob));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to preview employee document');
      setPreviewOpen(false);
      setPreviewDocument(null);
    } finally {
      setPreviewLoading(false);
    }
  };

  const handleDelete = async (document: ClientDocument) => {
    if (!window.confirm(`Delete "${document.title}"?`)) return;

    try {
      setError(null);
      await api.delete(document.id);
      setSuccess('Employee document deleted');
      await loadDocuments();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete employee document');
    }
  };

  return (
    <Card className="mb-6 overflow-hidden border-slate-200">
      <CardHeader className="border-b bg-gradient-to-r from-slate-50 to-white">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <CardTitle className="flex items-center gap-2">
              <FileText className="h-5 w-5 text-primary-700" />
              Employee Documents
            </CardTitle>
            <CardDescription>
              Store W-4s, W-9s, direct deposit forms, IDs, and supporting files directly on {employeeName || 'this employee'}.
            </CardDescription>
          </div>
          <div className="rounded-full border border-slate-200 bg-white px-3 py-1 text-xs font-medium text-slate-600 shadow-sm">
            {documents.length} file{documents.length === 1 ? '' : 's'}
          </div>
        </div>
      </CardHeader>
      <CardContent className="space-y-5 p-4 sm:p-5">
        {error && <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{error}</div>}
        {success && <div className="rounded-lg border border-success-100 bg-success-50 px-4 py-3 text-sm text-success-700">{success}</div>}

        <form onSubmit={handleUpload} className="rounded-2xl border border-slate-200 bg-slate-50/70 p-4">
          <div className="grid gap-4 md:grid-cols-2">
            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">Title</label>
              <Input
                value={form.title}
                onChange={(event) => setForm((current) => ({ ...current, title: event.target.value }))}
                placeholder={supportsSingleTitle ? 'Optional document title' : 'Each file keeps its filename'}
                disabled={!supportsSingleTitle}
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">Document type</label>
              <Select value={form.category} onChange={(event) => setForm((current) => ({ ...current, category: event.target.value }))}>
                {documentCategories.map((category) => (
                  <option key={category.value} value={category.value}>{category.label}</option>
                ))}
              </Select>
            </div>
            {!isClient && (
              <label className="flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-700">
                <input
                  type="checkbox"
                  checked={form.visible_to_client}
                  onChange={(event) => setForm((current) => ({ ...current, visible_to_client: event.target.checked }))}
                  className="h-4 w-4 rounded border-slate-300 text-primary-600 focus:ring-primary-500"
                />
                Visible in client portal
              </label>
            )}
            <div className={!isClient ? '' : 'md:col-span-2'}>
              <label className="mb-1 block text-sm font-medium text-slate-700">Files</label>
              <input
                ref={fileInputRef}
                type="file"
                multiple
                accept={ACCEPTED_UPLOAD_TYPES}
                onChange={(event) => setForm((current) => ({ ...current, files: Array.from(event.target.files || []) }))}
                className="block w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"
              />
            </div>
            <div className="md:col-span-2">
              <label className="mb-1 block text-sm font-medium text-slate-700">Notes</label>
              <Textarea
                value={form.notes}
                onChange={(event) => setForm((current) => ({ ...current, notes: event.target.value }))}
                rows={2}
                placeholder="Optional internal/client note about this document"
              />
            </div>
          </div>

          {selectedFiles.length > 0 && (
            <div className="mt-3 flex flex-wrap gap-2">
              {selectedFiles.map((file) => (
                <span key={`${file.name}-${file.size}-${file.lastModified}`} className="inline-flex items-center gap-2 rounded-full border border-slate-200 bg-white px-3 py-1 text-xs text-slate-700">
                  {file.name}
                  <button
                    type="button"
                    onClick={() => setForm((current) => ({ ...current, files: current.files.filter((candidate) => candidate !== file) }))}
                    aria-label={`Remove ${file.name}`}
                  >
                    <X className="h-3.5 w-3.5" />
                  </button>
                </span>
              ))}
            </div>
          )}

          <div className="mt-4 flex justify-end">
            <Button type="submit" disabled={uploading}>
              <UploadCloud className="mr-2 h-4 w-4" />
              {uploading ? 'Uploading...' : 'Upload Employee Document'}
            </Button>
          </div>
        </form>

        {loading ? (
          <div className="rounded-xl border border-dashed border-slate-200 py-8 text-center text-sm text-slate-500">Loading employee documents...</div>
        ) : documents.length === 0 ? (
          <div className="rounded-xl border border-dashed border-slate-300 bg-white py-8 text-center">
            <div className="mx-auto flex h-11 w-11 items-center justify-center rounded-2xl bg-slate-50 text-slate-500">
              <FileText className="h-5 w-5" />
            </div>
            <p className="mt-3 text-sm font-medium text-slate-900">No employee documents saved yet</p>
            <p className="mt-1 text-xs text-slate-500">Upload the W-4 or supporting documents once and they stay attached to this record.</p>
          </div>
        ) : (
          <div className="divide-y rounded-xl border border-slate-200 bg-white">
            {documents.map((document) => (
              <div key={document.id} className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-slate-900">{document.title}</p>
                  <p className="text-xs text-slate-500">
                    {categoryLabel(document.category)} · {document.file_name} · {formatFileSize(document.file_size)}
                  </p>
                  <p className="text-xs text-slate-500">
                    Uploaded {new Date(document.created_at).toLocaleString()} by {document.uploaded_by_name || '—'}
                    {!document.visible_to_client && !isClient ? ' · Staff only' : ''}
                  </p>
                  {document.notes && <p className="mt-1 whitespace-pre-wrap text-xs text-slate-600">{document.notes}</p>}
                </div>
                <div className="flex shrink-0 gap-2">
                  <Button type="button" variant="outline" size="sm" onClick={() => void handlePreview(document)}>
                    <Eye className="mr-1.5 h-4 w-4" /> Preview
                  </Button>
                  <Button type="button" variant="outline" size="sm" onClick={() => void handleDownload(document)}>
                    <Download className="mr-1.5 h-4 w-4" /> Download
                  </Button>
                  {(!isClient || document.uploaded_by_id === user?.id) && (
                    <Button type="button" variant="ghost" size="sm" className="text-red-600 hover:text-red-700" onClick={() => void handleDelete(document)}>
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </CardContent>

      <DocumentPreviewModal
        open={previewOpen}
        onOpenChange={(open) => {
          setPreviewOpen(open);
          if (!open) {
            setPreviewDocument(null);
            setPreviewPayload(null);
          }
        }}
        document={previewDocument}
        payload={previewPayload}
        loading={previewLoading}
        onDownload={() => {
          if (previewDocument) void handleDownload(previewDocument);
        }}
      />
    </Card>
  );
}
