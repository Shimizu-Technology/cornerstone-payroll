import { useEffect, useMemo, useRef, useState } from 'react';
import { Download, Eye, FileText, FileUp, ShieldCheck, Trash2, UploadCloud, Users, X } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { DocumentPreviewModal } from '@/components/documents/DocumentPreviewModal';
import { PortalMessagesPanel } from '@/components/client-portal/PortalMessagesPanel';
import { prepareDocumentPreview } from '@/lib/documentPreview';
import { clientDocumentsApi, clientEmployeesApi, clientPortalThreadsApi } from '@/services/api';
import type { ClientDocument } from '@/services/api';
import type { Employee } from '@/types';

const documentCategories = [
  { value: 'payroll_source', label: 'Payroll Source' },
  { value: 'employee_onboarding', label: 'Employee Onboarding' },
  { value: 'tax_notice', label: 'Tax Notice' },
  { value: 'direct_deposit', label: 'Direct Deposit' },
  { value: 'identity', label: 'Identity' },
  { value: 'insurance', label: 'Insurance' },
  { value: 'misc', label: 'Miscellaneous' },
];
const ACCEPTED_UPLOAD_TYPES = '.pdf,.png,.jpg,.jpeg,.webp,.txt,.csv,.doc,.docx,.xls,.xlsx';
const MAX_UPLOAD_NOTE = 'Accepted: PDF, Office docs, spreadsheets, text files, and common images up to 25 MB.';

function categoryLabel(value: string) {
  return documentCategories.find((category) => category.value === value)?.label || value;
}

function formatFileSize(bytes: number) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
}

function formatUploadSuccessMessage(count: number) {
  return count === 1 ? 'Document uploaded successfully' : `${count} documents uploaded successfully`;
}

export function ClientDocuments() {
  const [documents, setDocuments] = useState<ClientDocument[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [isDragActive, setIsDragActive] = useState(false);
  const [previewDocument, setPreviewDocument] = useState<ClientDocument | null>(null);
  const [previewOpen, setPreviewOpen] = useState(false);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewPayload, setPreviewPayload] = useState<Awaited<ReturnType<typeof prepareDocumentPreview>> | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [form, setForm] = useState({
    title: '',
    category: 'misc',
    employee_id: '',
    notes: '',
    files: [] as File[],
  });

  useEffect(() => {
    void load();
  }, []);

  const employeeOptions = useMemo(
    () => employees.map((employee) => ({ value: String(employee.id), label: `${employee.first_name} ${employee.last_name}` })),
    [employees]
  );

  const employeeScopedDocuments = useMemo(
    () => documents.filter((document) => document.employee_id).length,
    [documents]
  );
  const selectedFiles = form.files;
  const selectedFileCount = selectedFiles.length;
  const totalSelectedFileSize = selectedFiles.reduce((sum, file) => sum + file.size, 0);
  const supportsSingleTitle = selectedFileCount <= 1;

  const load = async () => {
    try {
      setLoading(true);
      setError(null);
      const [documentsResponse, employeesResponse] = await Promise.all([
        clientDocumentsApi.list(),
        clientEmployeesApi.list({ per_page: 500, sort_by: 'name', sort_direction: 'asc' }),
      ]);
      setDocuments(documentsResponse.data);
      setEmployees(employeesResponse.data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load documents');
    } finally {
      setLoading(false);
    }
  };

  const handleUpload = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (selectedFileCount === 0) {
      setError('Choose at least one file to upload');
      return;
    }

    try {
      setUploading(true);
      setError(null);
      setSuccess(null);
      const payload = new FormData();
      selectedFiles.forEach((file) => payload.append('files[]', file));
      if (supportsSingleTitle && form.title.trim()) {
        payload.append('title', form.title.trim());
      }
      payload.append('category', form.category);
      if (form.employee_id) payload.append('employee_id', form.employee_id);
      if (form.notes.trim()) payload.append('notes', form.notes.trim());
      const response = await clientDocumentsApi.upload(payload);
      setForm({ title: '', category: 'misc', employee_id: '', notes: '', files: [] });
      if (fileInputRef.current) fileInputRef.current.value = '';
      setSuccess(response.message || formatUploadSuccessMessage(selectedFileCount));
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to upload document');
    } finally {
      setUploading(false);
    }
  };

  const handleDownload = async (document: ClientDocument) => {
    const file = await clientDocumentsApi.download(document.id);
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
      const file = await clientDocumentsApi.preview(document.id);
      setPreviewPayload(await prepareDocumentPreview(document, file.blob));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to preview document');
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
      await clientDocumentsApi.delete(document.id);
      setSuccess('Document deleted');
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete document');
    }
  };

  const setSelectedFiles = (files: File[]) => {
    setForm((prev) => ({
      ...prev,
      files,
      title: files.length === 1 ? prev.title : '',
    }));
  };

  const removeSelectedFile = (targetName: string) => {
    const nextFiles = selectedFiles.filter((file) => `${file.name}-${file.size}` !== targetName);
    setSelectedFiles(nextFiles);
  };

  return (
    <div>
      <Header title="Documents" description="Securely upload and manage client documents." />

      <div className="p-6 lg:p-8 space-y-8">
        {error && <Banner tone="error" message={error} />}
        {success && <Banner tone="success" message={success} />}

        <div className="grid gap-4 md:grid-cols-3">
          <MiniStat
            title="Stored in portal"
            value={String(documents.length)}
            detail="Files available to your payroll team"
            icon={<ShieldCheck className="h-5 w-5" />}
          />
          <MiniStat
            title="Employee-linked"
            value={String(employeeScopedDocuments)}
            detail="Attached to a specific employee record"
            icon={<Users className="h-5 w-5" />}
          />
          <MiniStat
            title="Accepted formats"
            value="11"
            detail="PDF, Office docs, spreadsheets, text, and images"
            icon={<FileText className="h-5 w-5" />}
          />
        </div>

        <Card>
          <CardHeader>
            <CardTitle>Upload Document</CardTitle>
            <CardDescription>
              Share payroll source files, onboarding documents, tax notices, and supporting records in one secure place.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <form onSubmit={handleUpload} className="grid gap-5 md:grid-cols-2">
              <div>
                <label className="mb-1 block text-sm font-medium text-gray-700">Title</label>
                <Input
                  value={form.title}
                  onChange={(e) => setForm((prev) => ({ ...prev, title: e.target.value }))}
                  placeholder={supportsSingleTitle ? 'Optional document title' : 'Used for single-file uploads only'}
                  disabled={!supportsSingleTitle}
                  helperText={
                    supportsSingleTitle
                      ? undefined
                      : 'When you upload multiple files together, each file keeps its own original filename.'
                  }
                />
              </div>
              <div>
                <label className="mb-1 block text-sm font-medium text-gray-700">Category</label>
                <Select value={form.category} onChange={(e) => setForm((prev) => ({ ...prev, category: e.target.value }))}>
                  {documentCategories.map((category) => (
                    <option key={category.value} value={category.value}>
                      {category.label}
                    </option>
                  ))}
                </Select>
              </div>

              <div className="md:col-span-2 mx-auto w-full max-w-xl">
                <label className="mb-1 block text-sm font-medium text-gray-700">Employee</label>
                <Select value={form.employee_id} onChange={(e) => setForm((prev) => ({ ...prev, employee_id: e.target.value }))}>
                  <option value="">General company document</option>
                  {employeeOptions.map((employee) => (
                    <option key={employee.value} value={employee.value}>
                      {employee.label}
                    </option>
                  ))}
                </Select>
              </div>

              <div className="md:col-span-2">
                <label className="mb-2 block text-center text-sm font-medium text-gray-700">File</label>
                <input
                  ref={fileInputRef}
                  type="file"
                  accept={ACCEPTED_UPLOAD_TYPES}
                  multiple
                  className="hidden"
                  onChange={(e) => setSelectedFiles(Array.from(e.target.files || []))}
                />
                <button
                  type="button"
                  onClick={() => fileInputRef.current?.click()}
                  onDragEnter={() => setIsDragActive(true)}
                  onDragLeave={() => setIsDragActive(false)}
                  onDragOver={(e) => {
                    e.preventDefault();
                    setIsDragActive(true);
                  }}
                  onDrop={(e) => {
                    e.preventDefault();
                    setIsDragActive(false);
                    setSelectedFiles(Array.from(e.dataTransfer.files || []));
                  }}
                  className={`mx-auto flex w-full max-w-2xl flex-col items-center justify-center rounded-2xl border border-dashed px-5 py-9 text-center transition-all ${
                    isDragActive
                      ? 'border-primary-500 bg-primary-50 text-primary-800'
                      : 'border-neutral-300 bg-[radial-gradient(circle_at_top,rgba(59,130,246,0.08),transparent_55%),linear-gradient(to_bottom,#fafafa,#ffffff)] hover:border-primary-300 hover:bg-primary-50/60'
                  }`}
                >
                  <div className="rounded-2xl bg-white p-3 text-primary-700 shadow-sm">
                    <UploadCloud className="h-6 w-6" />
                  </div>
                  <p className="mt-3 text-sm font-medium text-neutral-900">
                    {selectedFileCount > 0
                      ? `${selectedFileCount} file${selectedFileCount === 1 ? '' : 's'} selected`
                      : 'Drag and drop files here, or click to browse'}
                  </p>
                  <p className="mt-1 text-xs text-neutral-500">
                    {selectedFileCount > 0
                      ? `${formatFileSize(totalSelectedFileSize)} total • You can upload mixed file types together`
                      : MAX_UPLOAD_NOTE}
                  </p>
                  {selectedFileCount > 0 && (
                    <div className="mt-4 inline-flex items-center rounded-full border border-primary-200 bg-white px-3 py-1 text-xs font-medium text-primary-700 shadow-sm">
                      Ready to upload
                    </div>
                  )}
                </button>
                {selectedFileCount > 0 ? (
                  <div className="mx-auto mt-4 grid w-full max-w-2xl gap-2">
                    {selectedFiles.map((file) => {
                      const fileKey = `${file.name}-${file.size}`;
                      return (
                        <div key={fileKey} className="flex items-center justify-between rounded-xl border border-neutral-200 bg-white px-4 py-3 shadow-sm">
                          <div>
                            <p className="text-sm font-medium text-neutral-900">{file.name}</p>
                            <p className="text-xs text-neutral-500">{formatFileSize(file.size)}</p>
                          </div>
                          <button
                            type="button"
                            onClick={() => removeSelectedFile(fileKey)}
                            className="rounded-lg p-2 text-neutral-400 transition-colors hover:bg-neutral-100 hover:text-neutral-700"
                            aria-label={`Remove ${file.name}`}
                          >
                            <X className="h-4 w-4" />
                          </button>
                        </div>
                      );
                    })}
                  </div>
                ) : null}
              </div>

              <div className="md:col-span-2">
                <label className="mb-1 block text-sm font-medium text-gray-700">Notes</label>
                <Textarea
                  value={form.notes}
                  onChange={(e) => setForm((prev) => ({ ...prev, notes: e.target.value }))}
                  rows={3}
                  placeholder="Optional notes for payroll team"
                />
              </div>

              <div className="md:col-span-2 flex flex-col gap-3 rounded-2xl border border-neutral-200 bg-neutral-50/70 px-4 py-4 sm:flex-row sm:items-center sm:justify-between">
                <p className="text-sm text-neutral-600">
                  Uploaded files stay with your company and can be previewed or downloaded again whenever needed.
                </p>
                <Button type="submit" disabled={uploading}>
                  <FileUp className="mr-2 h-4 w-4" />
                  {uploading ? `Uploading ${selectedFileCount || ''} file${selectedFileCount === 1 ? '' : 's'}...` : 'Upload Document'}
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>

        <PortalMessagesPanel
          api={clientPortalThreadsApi}
          documents={documents}
          audienceLabel="to your payroll team"
          description="Ask questions, send corrections, and tie follow-up notes to uploaded files."
        />

        <Card>
          <CardHeader>
            <CardTitle>Uploaded Documents</CardTitle>
            <CardDescription>
              Review everything shared with payroll, including company-wide files and employee-specific documents.
            </CardDescription>
          </CardHeader>
          <CardContent>
            {loading ? (
              <div className="py-12 text-center text-sm text-gray-500">Loading documents...</div>
            ) : documents.length === 0 ? (
              <div className="rounded-2xl border border-dashed border-neutral-300 bg-neutral-50/70 px-6 py-14 text-center">
                <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-2xl bg-white text-primary-700 shadow-sm">
                  <UploadCloud className="h-6 w-6" />
                </div>
                <p className="mt-4 text-sm font-medium text-neutral-900">No uploaded documents yet</p>
                <p className="mt-1 text-sm text-neutral-500">Your uploaded files will appear here after the first successful upload.</p>
              </div>
            ) : (
              <Table stickyHeader>
                <TableHeader>
                  <TableRow>
                    <TableHead>Title</TableHead>
                    <TableHead>Category</TableHead>
                    <TableHead>Employee</TableHead>
                    <TableHead>Uploaded By</TableHead>
                    <TableHead>Uploaded</TableHead>
                    <TableHead className="text-right">Actions</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody striped>
                  {documents.map((document) => (
                    <TableRow key={document.id}>
                      <TableCell>
                        <div>
                          <p className="font-medium text-gray-900">{document.title}</p>
                          <p className="text-xs text-gray-500">{document.file_name} · {formatFileSize(document.file_size)}</p>
                        </div>
                      </TableCell>
                      <TableCell>{categoryLabel(document.category)}</TableCell>
                      <TableCell>{document.employee_name || 'General company document'}</TableCell>
                      <TableCell>{document.uploaded_by_name || '—'}</TableCell>
                      <TableCell>{new Date(document.created_at).toLocaleString()}</TableCell>
                      <TableCell className="text-right">
                        <div className="flex justify-end gap-2">
                          <Button variant="outline" size="sm" onClick={() => void handlePreview(document)}>
                            <Eye className="mr-2 h-4 w-4" />
                            Preview
                          </Button>
                          <Button variant="outline" size="sm" onClick={() => void handleDownload(document)}>
                            <Download className="mr-2 h-4 w-4" />
                            Download
                          </Button>
                          <Button variant="ghost" size="sm" className="text-red-600 hover:text-red-700" onClick={() => void handleDelete(document)}>
                            <Trash2 className="mr-2 h-4 w-4" />
                            Delete
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>
      </div>

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
          if (previewDocument) {
            void handleDownload(previewDocument);
          }
        }}
      />
    </div>
  );
}

function Banner({ tone, message }: { tone: 'error' | 'success'; message: string }) {
  const classes =
    tone === 'error'
      ? 'border-danger-200 bg-danger-50 text-danger-700'
      : 'border-emerald-200 bg-emerald-50 text-emerald-700';

  return <div className={`rounded-lg border px-4 py-3 text-sm ${classes}`}>{message}</div>;
}

function MiniStat({
  title,
  value,
  detail,
  icon,
}: {
  title: string;
  value: string;
  detail: string;
  icon: React.ReactNode;
}) {
  return (
    <Card>
      <CardContent className="pt-6">
        <div className="flex items-start justify-between">
          <p className="text-sm font-medium text-neutral-500">{title}</p>
          <div className="rounded-xl bg-primary-50 p-2 text-primary-700">{icon}</div>
        </div>
        <p className="mt-3 text-3xl font-semibold tracking-tight text-neutral-900">{value}</p>
        <p className="mt-1.5 text-sm text-neutral-500">{detail}</p>
      </CardContent>
    </Card>
  );
}
