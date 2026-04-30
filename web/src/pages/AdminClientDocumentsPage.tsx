import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Download, Eye, FileText, FolderOpen, Send, ShieldCheck, Trash2, Users, X } from 'lucide-react';
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
import { adminClientDocumentsApi, adminPortalThreadsApi, employeesApi } from '@/services/api';
import type { ClientDocument } from '@/services/api';
import type { Employee } from '@/types';

const documentCategories = [
  { value: '', label: 'All categories' },
  { value: 'payroll_source', label: 'Payroll Source' },
  { value: 'employee_onboarding', label: 'Employee Onboarding' },
  { value: 'tax_notice', label: 'Tax Notice' },
  { value: 'direct_deposit', label: 'Direct Deposit' },
  { value: 'identity', label: 'Identity' },
  { value: 'insurance', label: 'Insurance' },
  { value: 'misc', label: 'Miscellaneous' },
];
const ACCEPTED_UPLOAD_TYPES = '.pdf,.png,.jpg,.jpeg,.webp,.txt,.csv,.doc,.docx,.xls,.xlsx';

function categoryLabel(value: string) {
  return documentCategories.find((option) => option.value === value)?.label || value;
}

function formatFileSize(bytes: number) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
}

async function loadAllEmployees() {
  const employees: Employee[] = [];
  let page = 1;
  let totalPages = 1;

  do {
    const response = await employeesApi.list({ per_page: 100, page, sort_by: 'name', sort_direction: 'asc' });
    employees.push(...response.data);
    totalPages = response.meta.total_pages;
    page += 1;
  } while (page <= totalPages);

  return employees.sort((a, b) => {
    const lastName = (a.last_name || '').localeCompare(b.last_name || '');
    if (lastName !== 0) return lastName;
    return (a.first_name || '').localeCompare(b.first_name || '');
  });
}

export function AdminClientDocumentsPage() {
  const [documents, setDocuments] = useState<ClientDocument[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [category, setCategory] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [previewDocument, setPreviewDocument] = useState<ClientDocument | null>(null);
  const [previewOpen, setPreviewOpen] = useState(false);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewPayload, setPreviewPayload] = useState<Awaited<ReturnType<typeof prepareDocumentPreview>> | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const fileKeysRef = useRef(new WeakMap<File, string>());
  const [uploadForm, setUploadForm] = useState({
    title: '',
    category: 'misc',
    employee_id: '',
    notes: '',
    visible_to_client: true,
    files: [] as File[],
  });

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const [documentsResponse, employeesResponse] = await Promise.all([
        adminClientDocumentsApi.list({ category: category || undefined }),
        loadAllEmployees(),
      ]);
      setDocuments(documentsResponse.data);
      setEmployees(employeesResponse);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load client documents');
    } finally {
      setLoading(false);
    }
  }, [category]);

  useEffect(() => {
    void load();
  }, [load]);

  const totalFiles = useMemo(() => documents.length, [documents]);
  const employeeLinkedFiles = useMemo(
    () => documents.filter((document) => document.employee_id).length,
    [documents]
  );
  const uniqueUploaders = useMemo(
    () => new Set(documents.map((document) => document.uploaded_by_id)).size,
    [documents]
  );
  const selectedFiles = uploadForm.files;
  const supportsSingleTitle = selectedFiles.length <= 1;
  const fileKey = (file: File) => {
    const existingKey = fileKeysRef.current.get(file);
    if (existingKey) return existingKey;

    const nextKey = `${file.name}-${file.size}-${file.lastModified}-${crypto.randomUUID()}`;
    fileKeysRef.current.set(file, nextKey);
    return nextKey;
  };
  const employeeOptions = useMemo(
    () => employees.map((employee) => ({ value: String(employee.id), label: `${employee.first_name} ${employee.last_name}` })),
    [employees]
  );

  const handleUpload = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (selectedFiles.length === 0) {
      setError('Choose at least one file to share');
      return;
    }

    try {
      setUploading(true);
      setError(null);
      setSuccess(null);
      const payload = new FormData();
      selectedFiles.forEach((file) => payload.append('files[]', file));
      if (supportsSingleTitle && uploadForm.title.trim()) payload.append('title', uploadForm.title.trim());
      payload.append('category', uploadForm.category);
      payload.append('visible_to_client', String(uploadForm.visible_to_client));
      if (uploadForm.employee_id) payload.append('employee_id', uploadForm.employee_id);
      if (uploadForm.notes.trim()) payload.append('notes', uploadForm.notes.trim());
      const response = await adminClientDocumentsApi.upload(payload);
      setSuccess(response.message || 'Document shared successfully');
      setUploadForm({ title: '', category: 'misc', employee_id: '', notes: '', visible_to_client: true, files: [] });
      if (fileInputRef.current) fileInputRef.current.value = '';
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to share document');
    } finally {
      setUploading(false);
    }
  };

  const downloadDocument = async (document: ClientDocument) => {
    const file = await adminClientDocumentsApi.download(document.id);
    const url = URL.createObjectURL(file.blob);
    const link = window.document.createElement('a');
    link.href = url;
    link.download = file.filename || document.file_name;
    window.document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  };

  const previewDocumentFile = async (document: ClientDocument) => {
    try {
      setError(null);
      setPreviewDocument(document);
      setPreviewOpen(true);
      setPreviewLoading(true);
      setPreviewPayload(null);
      const file = await adminClientDocumentsApi.preview(document.id);
      setPreviewPayload(await prepareDocumentPreview(document, file.blob));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to preview client document');
      setPreviewOpen(false);
      setPreviewDocument(null);
    } finally {
      setPreviewLoading(false);
    }
  };

  const deleteDocument = async (document: ClientDocument) => {
    if (!window.confirm(`Delete "${document.title}"?`)) return;

    try {
      await adminClientDocumentsApi.delete(document.id);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete document');
    }
  };

  return (
    <div>
      <Header title="Client Documents" description="Review files uploaded through the client portal." />

      <div className="p-6 lg:p-8 space-y-6">
        {error && <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{error}</div>}
        {success && <div className="rounded-lg border border-success-100 bg-success-50 px-4 py-3 text-sm text-success-600">{success}</div>}

        <div className="grid gap-4 md:grid-cols-4">
          <MiniStat title="Visible uploads" value={String(totalFiles)} detail="Current files in this company view" icon={<FolderOpen className="h-5 w-5" />} />
          <MiniStat title="Employee-linked" value={String(employeeLinkedFiles)} detail="Attached to employee records" icon={<Users className="h-5 w-5" />} />
          <MiniStat title="Portal contributors" value={String(uniqueUploaders)} detail="Distinct client and staff uploaders" icon={<ShieldCheck className="h-5 w-5" />} />
          <MiniStat title="Categories" value={String(documentCategories.length - 1)} detail="Available filing buckets" icon={<FileText className="h-5 w-5" />} />
        </div>

        <div className="max-w-xs">
          <Select value={category} onChange={(e) => setCategory(e.target.value)}>
            {documentCategories.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </Select>
        </div>

        <Card>
          <CardHeader>
            <CardTitle>Share Document With Client</CardTitle>
            <CardDescription>Upload files from the payroll team into the client portal, with optional staff-only visibility.</CardDescription>
          </CardHeader>
          <CardContent>
            <form onSubmit={handleUpload} className="grid gap-4 md:grid-cols-2">
              <div>
                <label className="mb-1 block text-sm font-medium text-neutral-700">Title</label>
                <Input
                  value={uploadForm.title}
                  onChange={(event) => setUploadForm((current) => ({ ...current, title: event.target.value }))}
                  placeholder={supportsSingleTitle ? 'Optional document title' : 'Used for single-file uploads only'}
                  disabled={!supportsSingleTitle}
                />
              </div>
              <div>
                <label className="mb-1 block text-sm font-medium text-neutral-700">Category</label>
                <Select value={uploadForm.category} onChange={(event) => setUploadForm((current) => ({ ...current, category: event.target.value }))}>
                  {documentCategories.filter((option) => option.value).map((option) => (
                    <option key={option.value} value={option.value}>{option.label}</option>
                  ))}
                </Select>
              </div>
              <div>
                <label className="mb-1 block text-sm font-medium text-neutral-700">Employee</label>
                <Select value={uploadForm.employee_id} onChange={(event) => setUploadForm((current) => ({ ...current, employee_id: event.target.value }))}>
                  <option value="">General company document</option>
                  {employeeOptions.map((employee) => (
                    <option key={employee.value} value={employee.value}>{employee.label}</option>
                  ))}
                </Select>
              </div>
              <label className="flex items-center gap-2 rounded-lg border border-neutral-200 px-3 py-2 text-sm text-neutral-700">
                <input
                  type="checkbox"
                  checked={uploadForm.visible_to_client}
                  onChange={(event) => setUploadForm((current) => ({ ...current, visible_to_client: event.target.checked }))}
                />
                Visible to client
              </label>
              <div className="md:col-span-2">
                <label className="mb-1 block text-sm font-medium text-neutral-700">Notes</label>
                <Textarea
                  value={uploadForm.notes}
                  onChange={(event) => setUploadForm((current) => ({ ...current, notes: event.target.value }))}
                  rows={3}
                  placeholder="Optional note shown with the document"
                />
              </div>
              <div className="md:col-span-2">
                <input
                  ref={fileInputRef}
                  type="file"
                  multiple
                  accept={ACCEPTED_UPLOAD_TYPES}
                  onChange={(event) => setUploadForm((current) => ({ ...current, files: Array.from(event.target.files || []) }))}
                  className="block w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm"
                />
                {selectedFiles.length > 0 && (
                  <div className="mt-3 flex flex-wrap gap-2">
                    {selectedFiles.map((file) => (
                      <span key={fileKey(file)} className="inline-flex items-center gap-2 rounded-full bg-neutral-100 px-3 py-1 text-xs text-neutral-700">
                        {file.name}
                        <button
                          type="button"
                          onClick={() => setUploadForm((current) => ({ ...current, files: current.files.filter((candidate) => candidate !== file) }))}
                          aria-label={`Remove ${file.name}`}
                        >
                          <X className="h-3.5 w-3.5" />
                        </button>
                      </span>
                    ))}
                  </div>
                )}
              </div>
              <div className="md:col-span-2">
                <Button type="submit" disabled={uploading}>
                  <Send className="mr-2 h-4 w-4" />
                  {uploading ? 'Sharing...' : 'Share Document'}
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>

        <PortalMessagesPanel
          api={adminPortalThreadsApi}
          documents={documents.filter((document) => document.visible_to_client)}
          audienceLabel="to the client"
          description="Coordinate corrections, follow-up notes, and updated payroll source files with the client."
          canResolve
        />

        <Card>
          <CardHeader>
            <CardTitle>Uploaded Files</CardTitle>
            <CardDescription>
              Intake view for files shared through the client portal, including supporting notes and employee associations.
            </CardDescription>
          </CardHeader>
          <CardContent>
            {loading ? (
              <div className="py-12 text-center text-sm text-gray-500">Loading client documents...</div>
            ) : documents.length === 0 ? (
              <div className="rounded-2xl border border-dashed border-neutral-300 bg-neutral-50/70 px-6 py-14 text-center">
                <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-2xl bg-white text-primary-700 shadow-sm">
                  <FolderOpen className="h-6 w-6" />
                </div>
                <p className="mt-4 text-sm font-medium text-neutral-900">No client uploads found</p>
                <p className="mt-1 text-sm text-neutral-500">Files shared through the portal will appear here as they come in.</p>
              </div>
            ) : (
              <Table stickyHeader>
                <TableHeader>
                  <TableRow>
                    <TableHead>Title</TableHead>
                    <TableHead>Category</TableHead>
                    <TableHead>Employee</TableHead>
                    <TableHead>Uploaded By</TableHead>
                    <TableHead>Notes</TableHead>
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
                      <TableCell className="max-w-xs whitespace-pre-wrap text-sm text-neutral-600">{document.notes || '—'}</TableCell>
                      <TableCell>{new Date(document.created_at).toLocaleString()}</TableCell>
                      <TableCell className="text-right">
                        <div className="flex justify-end gap-2">
                          <Button variant="outline" size="sm" onClick={() => void previewDocumentFile(document)}>
                            <Eye className="mr-2 h-4 w-4" />
                            Preview
                          </Button>
                          <Button variant="outline" size="sm" onClick={() => void downloadDocument(document)}>
                            <Download className="mr-2 h-4 w-4" />
                            Download
                          </Button>
                          <Button variant="ghost" size="sm" className="text-red-600 hover:text-red-700" onClick={() => void deleteDocument(document)}>
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
            void downloadDocument(previewDocument);
          }
        }}
      />
    </div>
  );
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
