import { useCallback, useEffect, useMemo, useState } from 'react';
import { Download, Eye, FileText, FolderOpen, ShieldCheck, Trash2, Users } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { DocumentPreviewModal } from '@/components/documents/DocumentPreviewModal';
import { prepareDocumentPreview } from '@/lib/documentPreview';
import { adminClientDocumentsApi } from '@/services/api';
import type { ClientDocument } from '@/services/api';

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

function categoryLabel(value: string) {
  return documentCategories.find((option) => option.value === value)?.label || value;
}

function formatFileSize(bytes: number) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
}

export function AdminClientDocumentsPage() {
  const [documents, setDocuments] = useState<ClientDocument[]>([]);
  const [loading, setLoading] = useState(true);
  const [category, setCategory] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [previewDocument, setPreviewDocument] = useState<ClientDocument | null>(null);
  const [previewOpen, setPreviewOpen] = useState(false);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewPayload, setPreviewPayload] = useState<Awaited<ReturnType<typeof prepareDocumentPreview>> | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await adminClientDocumentsApi.list({ category: category || undefined });
      setDocuments(response.data);
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
