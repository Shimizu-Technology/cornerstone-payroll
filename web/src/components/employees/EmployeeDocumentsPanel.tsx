import { useCallback, useEffect, useRef, useState } from 'react';
import { AlertCircle, CheckCircle2, Download, Eye, FileText, ShieldCheck, UploadCloud, Trash2, X } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { DocumentPreviewModal } from '@/components/documents/DocumentPreviewModal';
import { prepareDocumentPreview } from '@/lib/documentPreview';
import {
  isCurrentEmployeeDocumentRequest,
  isCurrentEmployeeDocumentScope,
  readinessUploadError,
  reconcileEmployeeDocumentLoads,
  selectReadinessItem,
} from '@/lib/employee-document-upload';
import { cn } from '@/lib/utils';
import { useAuth } from '@/contexts/AuthContext';
import {
  adminClientDocumentsApi,
  adminEmployeeDocumentRequirementsApi,
  clientDocumentsApi,
  clientEmployeeDocumentRequirementsApi,
} from '@/services/api';
import type {
  ClientDocument,
  EmployeeDocumentReadinessResponse,
  EmployeeDocumentRequirement,
  EmployeeDocumentRequirementStatus,
} from '@/services/api';

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
  className?: string;
  headerAction?: React.ReactNode;
  onReadinessChange?: (readiness: EmployeeDocumentReadinessResponse['readiness'] | undefined) => void;
}

interface RequirementReviewDraft {
  status: Exclude<EmployeeDocumentRequirementStatus, 'missing'>;
  clientDocumentId: string;
  reviewNote: string;
}

type ReadinessLoadStatus = 'loading' | 'available' | 'unavailable';

function formatFileSize(bytes: number) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
}

function categoryLabel(value: string) {
  return documentCategories.find((category) => category.value === value)?.label || value;
}

function requirementStatusLabel(value: EmployeeDocumentRequirementStatus) {
  return {
    missing: 'Missing',
    received: 'Received — review needed',
    verified: 'Verified',
    rejected: 'Rejected — replacement needed',
    waived: 'Waived with reason',
  }[value];
}

export function EmployeeDocumentsPanel({ employeeId, employeeName, isClient, className, headerAction, onReadinessChange }: EmployeeDocumentsPanelProps) {
  const { user } = useAuth();
  const [documents, setDocuments] = useState<ClientDocument[]>([]);
  const [requirements, setRequirements] = useState<EmployeeDocumentRequirement[]>([]);
  const [readyForPayroll, setReadyForPayroll] = useState<boolean | null>(null);
  const [readinessLoadStatus, setReadinessLoadStatus] = useState<ReadinessLoadStatus>('loading');
  const [requirementDrafts, setRequirementDrafts] = useState<Record<number, RequirementReviewDraft>>({});
  const [savingRequirementId, setSavingRequirementId] = useState<number | null>(null);
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
    requirement_id: '',
    files: [] as File[],
  });
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const loadSequenceRef = useRef(0);
  const loadedEmployeeIdRef = useRef<number | null>(null);
  const activeEmployeeIdRef = useRef(employeeId);
  activeEmployeeIdRef.current = employeeId;

  const api = isClient ? clientDocumentsApi : adminClientDocumentsApi;

  const loadDocuments = useCallback(async () => {
    const requestEmployeeId = employeeId;
    if (!isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) return;

    const requestId = loadSequenceRef.current + 1;
    loadSequenceRef.current = requestId;
    if (loadedEmployeeIdRef.current !== employeeId) {
      loadedEmployeeIdRef.current = employeeId;
      setDocuments([]);
      setRequirements([]);
      setReadyForPayroll(null);
      setReadinessLoadStatus('loading');
      setRequirementDrafts({});
      setSavingRequirementId(null);
      setUploading(false);
      setError(null);
      setSuccess(null);
      setPreviewDocument(null);
      setPreviewOpen(false);
      setPreviewLoading(false);
      setPreviewPayload(null);
      setForm({ title: '', category: 'employee_onboarding', notes: '', visible_to_client: true, requirement_id: '', files: [] });
      if (fileInputRef.current) fileInputRef.current.value = '';
    }

    try {
      setLoading(true);
      setReadinessLoadStatus('loading');
      setError(null);
      const [documentsResult, requirementsResult] = await Promise.allSettled([
        api.list({ employee_id: employeeId }),
        isClient
          ? clientEmployeeDocumentRequirementsApi.list(employeeId)
          : adminEmployeeDocumentRequirementsApi.list(employeeId),
      ]);
      if (
        !isCurrentEmployeeDocumentRequest(requestId, loadSequenceRef.current)
        || !isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)
      ) return;

      const loaded = reconcileEmployeeDocumentLoads(documentsResult, requirementsResult);
      if (loaded.documents) {
        setDocuments(loaded.documents.data);
      }
      if (loaded.readiness) {
        const requirementsResponse = loaded.readiness;
        setRequirements(requirementsResponse.data);
        setReadyForPayroll(requirementsResponse.readiness.ready_for_payroll);
        setReadinessLoadStatus('available');
        onReadinessChange?.(requirementsResponse.readiness);
        setRequirementDrafts(Object.fromEntries(requirementsResponse.data.map((requirement) => [
          requirement.id,
          {
            status: requirement.status === 'missing' ? 'received' : requirement.status,
            clientDocumentId: requirement.client_document_id ? String(requirement.client_document_id) : '',
            reviewNote: requirement.review_note || '',
          },
        ])));
      } else {
        setReadyForPayroll(null);
        setReadinessLoadStatus('unavailable');
        onReadinessChange?.(undefined);
      }
      setError(loaded.error);
    } finally {
      if (
        isCurrentEmployeeDocumentRequest(requestId, loadSequenceRef.current)
        && isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)
      ) setLoading(false);
    }
  }, [api, employeeId, isClient, onReadinessChange]);

  useEffect(() => {
    void loadDocuments();
    return () => {
      loadSequenceRef.current += 1;
    };
  }, [loadDocuments]);

  const selectedFiles = form.files;
  const supportsSingleTitle = selectedFiles.length <= 1;

  const handleUpload = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const requestEmployeeId = employeeId;
    const uploadError = readinessUploadError(form.requirement_id, selectedFiles);
    if (uploadError) {
      setError(uploadError);
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
      if (form.requirement_id) payload.append('requirement_id', form.requirement_id);
      if (!isClient) payload.append('visible_to_client', String(form.visible_to_client));
      if (supportsSingleTitle && form.title.trim()) payload.append('title', form.title.trim());
      if (form.notes.trim()) payload.append('notes', form.notes.trim());

      const response = await api.upload(payload);
      if (!isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) return;

      setSuccess(response.message || 'Employee document uploaded');
      setForm({ title: '', category: 'employee_onboarding', notes: '', visible_to_client: true, requirement_id: '', files: [] });
      if (fileInputRef.current) fileInputRef.current.value = '';
      await loadDocuments();
    } catch (err) {
      if (isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) {
        setError(err instanceof Error ? err.message : 'Failed to upload employee document');
      }
    } finally {
      if (isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) setUploading(false);
    }
  };

  const saveRequirement = async (requirement: EmployeeDocumentRequirement) => {
    const requestEmployeeId = employeeId;
    const draft = requirementDrafts[requirement.id];
    if (!draft) return;

    try {
      setSavingRequirementId(requirement.id);
      setError(null);
      setSuccess(null);
      const response = await adminEmployeeDocumentRequirementsApi.update(employeeId, requirement.id, {
        status: draft.status,
        client_document_id: draft.clientDocumentId ? Number(draft.clientDocumentId) : undefined,
        review_note: draft.reviewNote.trim() || undefined,
        lock_version: requirement.lock_version,
      });
      if (!isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) return;

      setRequirements(response.data);
      setReadyForPayroll(response.readiness.ready_for_payroll);
      setSuccess(`${requirement.label} readiness updated`);
      await loadDocuments();
    } catch (err) {
      if (isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) {
        setError(err instanceof Error ? err.message : 'Failed to update employee document readiness');
      }
    } finally {
      if (isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) setSavingRequirementId(null);
    }
  };

  const handleDownload = async (document: ClientDocument) => {
    const requestEmployeeId = employeeId;
    try {
      setError(null);
      const file = await api.download(document.id);
      const url = URL.createObjectURL(file.blob);
      const link = window.document.createElement('a');
      link.href = url;
      link.download = file.filename || document.file_name;
      window.document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
    } catch (err) {
      if (isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) {
        setError(err instanceof Error ? err.message : 'Failed to download employee document');
      }
    }
  };

  const handlePreview = async (document: ClientDocument) => {
    const requestEmployeeId = employeeId;
    try {
      setError(null);
      setPreviewDocument(document);
      setPreviewOpen(true);
      setPreviewLoading(true);
      setPreviewPayload(null);
      const file = await api.preview(document.id);
      const payload = await prepareDocumentPreview(document, file.blob);
      if (!isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) return;

      setPreviewPayload(payload);
    } catch (err) {
      if (isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) {
        setError(err instanceof Error ? err.message : 'Failed to preview employee document');
        setPreviewOpen(false);
        setPreviewDocument(null);
      }
    } finally {
      if (isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) setPreviewLoading(false);
    }
  };

  const handleDelete = async (document: ClientDocument) => {
    if (!window.confirm(`Delete "${document.title}"?`)) return;
    const requestEmployeeId = employeeId;

    try {
      setError(null);
      await api.delete(document.id);
      if (!isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) return;

      setSuccess('Employee document deleted');
      await loadDocuments();
    } catch (err) {
      if (isCurrentEmployeeDocumentScope(requestEmployeeId, activeEmployeeIdRef.current)) {
        setError(err instanceof Error ? err.message : 'Failed to delete employee document');
      }
    }
  };

  return (
    <Card className={cn('mb-6 overflow-hidden border-neutral-200/80', className)}>
      <CardHeader className="border-b border-neutral-200/70 bg-gradient-to-r from-neutral-50 to-white">
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
          <div className="flex items-center gap-2">
            <div className="rounded-full border border-neutral-200 bg-white px-3 py-1 text-xs font-medium text-neutral-600 shadow-sm">
              {documents.length} file{documents.length === 1 ? '' : 's'}
            </div>
            {headerAction}
          </div>
        </div>
      </CardHeader>
      <CardContent className="space-y-5 p-4 sm:p-5">
        {error && <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{error}</div>}
        {success && <div className="rounded-lg border border-success-100 bg-success-50 px-4 py-3 text-sm text-success-700">{success}</div>}

        <section aria-labelledby="employee-document-readiness-heading" className="rounded-2xl border border-neutral-200 bg-white p-4">
          <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h3 id="employee-document-readiness-heading" className="flex items-center gap-2 font-semibold text-neutral-950">
                <ShieldCheck className="h-5 w-5 text-primary-700" aria-hidden="true" />
                New-hire payroll readiness
              </h3>
              <p className="mt-2 text-sm leading-6 text-neutral-600">
                Uploads count as received first. Cornerstone staff must verify them, or record a reasoned waiver, before this employee can be included in an approved payroll.
              </p>
            </div>
            {readinessLoadStatus === 'available' && requirements.length > 0 && readyForPayroll !== null && (
              <span className={cn(
                'inline-flex shrink-0 items-center gap-2 rounded-full px-4 py-2 text-xs font-semibold',
                readyForPayroll ? 'bg-success-50 text-success-800' : 'bg-warning-50 text-warning-900',
              )}>
                {readyForPayroll ? <CheckCircle2 className="h-4 w-4" /> : <AlertCircle className="h-4 w-4" />}
                {readyForPayroll ? 'Ready for payroll' : 'Payroll approval blocked'}
              </span>
            )}
          </div>

          {readinessLoadStatus === 'loading' ? (
            <p className="mt-4 rounded-xl border border-dashed border-neutral-200 bg-neutral-50 px-4 py-4 text-sm text-neutral-600">
              Loading payroll readiness…
            </p>
          ) : readinessLoadStatus === 'unavailable' ? (
            <p className="mt-4 rounded-xl border border-warning-200 bg-warning-50 px-4 py-4 text-sm text-warning-900">
              Payroll readiness is unavailable. Retry before approving or processing payroll for this employee.
            </p>
          ) : requirements.length === 0 ? (
            <p className="mt-4 rounded-xl border border-dashed border-neutral-200 bg-neutral-50 px-4 py-4 text-sm text-neutral-600">
              No new-hire document checklist is required for this existing employee.
            </p>
          ) : (
            <div className="mt-4 grid gap-4">
              {requirements.map((requirement) => {
                const draft = requirementDrafts[requirement.id];
                return (
                  <div key={requirement.id} className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                    <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                      <div>
                        <p className="font-semibold text-neutral-950">{requirement.label}</p>
                        <p className="mt-2 text-sm text-neutral-600">
                          {requirement.document_title || (requirement.document_attached ? 'A staff-only file is attached' : 'No document attached')}
                        </p>
                      </div>
                      <span className={cn(
                        'inline-flex w-fit rounded-full px-4 py-2 text-xs font-semibold',
                        requirement.status === 'verified' || requirement.status === 'waived'
                          ? 'bg-success-50 text-success-800'
                          : requirement.status === 'rejected'
                            ? 'bg-danger-50 text-danger-700'
                            : 'bg-warning-50 text-warning-900',
                      )}>
                        {requirementStatusLabel(requirement.status)}
                      </span>
                    </div>

                    {!isClient && draft && (
                      <>
                        <div className="mt-4 grid gap-4 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1fr)_minmax(0,1.4fr)_auto] lg:items-end">
                          <div>
                            <label htmlFor={`requirement-status-${requirement.id}`} className="mb-2 block text-xs font-semibold text-neutral-700">Readiness outcome</label>
                            <Select
                              id={`requirement-status-${requirement.id}`}
                              value={draft.status}
                              onChange={(event) => {
                                const status = event.target.value as RequirementReviewDraft['status'];
                                setRequirementDrafts((current) => ({
                                  ...current,
                                  [requirement.id]: {
                                    ...draft,
                                    status,
                                    reviewNote: status === 'received' ? '' : draft.reviewNote,
                                  },
                                }));
                              }}
                            >
                              <option value="received">Received — review needed</option>
                              <option value="verified">Verified</option>
                              <option value="rejected">Rejected — replacement needed</option>
                              <option value="waived">Waived with reason</option>
                            </Select>
                          </div>
                          <div>
                            <label htmlFor={`requirement-document-${requirement.id}`} className="mb-2 block text-xs font-semibold text-neutral-700">Attached document</label>
                            <Select
                              id={`requirement-document-${requirement.id}`}
                              value={draft.clientDocumentId}
                              disabled={draft.status === 'waived'}
                              onChange={(event) => setRequirementDrafts((current) => ({
                                ...current,
                                [requirement.id]: { ...draft, clientDocumentId: event.target.value },
                              }))}
                            >
                              <option value="">Choose a document</option>
                              {documents.map((document) => <option key={document.id} value={document.id}>{document.title}</option>)}
                            </Select>
                          </div>
                          <div>
                            <label htmlFor={`requirement-note-${requirement.id}`} className="mb-2 block text-xs font-semibold text-neutral-700">Review note</label>
                            <Input
                              id={`requirement-note-${requirement.id}`}
                              value={draft.reviewNote}
                              onChange={(event) => setRequirementDrafts((current) => ({
                                ...current,
                                [requirement.id]: { ...draft, reviewNote: event.target.value },
                              }))}
                              placeholder={draft.status === 'received' ? 'Optional until reviewed' : 'Required evidence or reason'}
                            />
                          </div>
                          <Button
                            type="button"
                            aria-label={`Save ${requirement.label} status`}
                            onClick={() => void saveRequirement(requirement)}
                            disabled={savingRequirementId === requirement.id}
                          >
                            {savingRequirementId === requirement.id ? 'Saving…' : 'Save status'}
                          </Button>
                        </div>
                        {(requirement.history || []).length > 0 && (
                          <details className="mt-4 border-t border-neutral-200 pt-4">
                            <summary className="cursor-pointer text-xs font-semibold text-neutral-700">View retained readiness history</summary>
                            <div className="mt-4 grid gap-2">
                              {(requirement.history || []).map((event) => (
                                <div key={event.id} className="rounded-lg bg-white px-4 py-2 text-xs leading-5 text-neutral-600">
                                  <span className="font-semibold text-neutral-800">{requirementStatusLabel(event.to_status)}</span>
                                  {event.actor_name ? ` by ${event.actor_name}` : ''} · {new Date(event.created_at).toLocaleString()}
                                  {event.document_title ? ` · ${event.document_title}` : ''}
                                  {event.note && <p className="mt-2 whitespace-pre-wrap">{event.note}</p>}
                                </div>
                              ))}
                            </div>
                          </details>
                        )}
                      </>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </section>

        <form onSubmit={handleUpload} className="rounded-2xl border border-neutral-200 bg-neutral-50/70 p-4">
          <div className="grid gap-4 md:grid-cols-2">
            {readinessLoadStatus === 'available' && requirements.length > 0 && (
              <div className="md:col-span-2">
                <label htmlFor={`employee-document-requirement-${employeeId}`} className="mb-2 block text-sm font-medium text-neutral-700">Readiness item</label>
                <Select
                  id={`employee-document-requirement-${employeeId}`}
                  value={form.requirement_id}
                  onChange={(event) => {
                    setForm((current) => selectReadinessItem(current, event.target.value));
                    if (fileInputRef.current) fileInputRef.current.value = '';
                  }}
                >
                  <option value="">General employee file</option>
                  {requirements.map((requirement) => (
                    <option key={requirement.id} value={requirement.id}>{requirement.label} · {requirementStatusLabel(requirement.status)}</option>
                  ))}
                </Select>
                <p className="mt-2 text-xs leading-5 text-neutral-500">Choose an item to mark the uploaded file as received and ready for staff review.</p>
              </div>
            )}
            <div>
              <label htmlFor={`employee-document-title-${employeeId}`} className="mb-1 block text-sm font-medium text-neutral-700">Title</label>
              <Input
                id={`employee-document-title-${employeeId}`}
                value={form.title}
                onChange={(event) => setForm((current) => ({ ...current, title: event.target.value }))}
                placeholder={supportsSingleTitle ? 'Optional document title' : 'Each file keeps its filename'}
                disabled={!supportsSingleTitle}
              />
            </div>
            <div>
              <label htmlFor={`employee-document-category-${employeeId}`} className="mb-1 block text-sm font-medium text-neutral-700">Document type</label>
              <Select id={`employee-document-category-${employeeId}`} value={form.category} onChange={(event) => setForm((current) => ({ ...current, category: event.target.value }))}>
                {documentCategories.map((category) => (
                  <option key={category.value} value={category.value}>{category.label}</option>
                ))}
              </Select>
            </div>
            {!isClient && (
              <label className="flex items-center gap-2 rounded-xl border border-neutral-200 bg-white px-3 py-2 text-sm text-neutral-700">
                <input
                  type="checkbox"
                  checked={form.visible_to_client}
                  onChange={(event) => setForm((current) => ({ ...current, visible_to_client: event.target.checked }))}
                  className="h-4 w-4 rounded border-neutral-300 text-primary-600 focus:ring-primary-500"
                />
                Visible in client portal
              </label>
            )}
            <div className={!isClient ? '' : 'md:col-span-2'}>
              <label htmlFor={`employee-document-files-${employeeId}`} className="mb-1 block text-sm font-medium text-neutral-700">Files</label>
              <input
                id={`employee-document-files-${employeeId}`}
                ref={fileInputRef}
                type="file"
                multiple={!form.requirement_id}
                accept={ACCEPTED_UPLOAD_TYPES}
                onChange={(event) => setForm((current) => ({ ...current, files: Array.from(event.target.files || []) }))}
                className="block w-full rounded-xl border border-neutral-300 bg-white px-3 py-2 text-sm"
              />
            </div>
            <div className="md:col-span-2">
              <label htmlFor={`employee-document-notes-${employeeId}`} className="mb-1 block text-sm font-medium text-neutral-700">Notes</label>
              <Textarea
                id={`employee-document-notes-${employeeId}`}
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
                <span key={`${file.name}-${file.size}-${file.lastModified}`} className="inline-flex items-center gap-2 rounded-full border border-neutral-200 bg-white px-3 py-1 text-xs text-neutral-700">
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
          <div className="rounded-xl border border-dashed border-neutral-200 py-8 text-center text-sm text-neutral-500">Loading employee documents...</div>
        ) : documents.length === 0 ? (
          <div className="rounded-xl border border-dashed border-neutral-300 bg-white py-8 text-center">
            <div className="mx-auto flex h-11 w-11 items-center justify-center rounded-2xl bg-neutral-50 text-neutral-500">
              <FileText className="h-5 w-5" />
            </div>
            <p className="mt-3 text-sm font-medium text-neutral-900">No employee documents saved yet</p>
            <p className="mt-1 text-xs text-neutral-500">Upload the W-4 or supporting documents once and they stay attached to this record.</p>
          </div>
        ) : (
          <div className="divide-y rounded-xl border border-neutral-200 bg-white">
            {documents.map((document) => (
              <div key={document.id} className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-neutral-900">{document.title}</p>
                  <p className="text-xs text-neutral-500">
                    {categoryLabel(document.category)} · {document.file_name} · {formatFileSize(document.file_size)}
                  </p>
                  <p className="text-xs text-neutral-500">
                    Uploaded {new Date(document.created_at).toLocaleString()} by {document.uploaded_by_name || '—'}
                    {!document.visible_to_client && !isClient ? ' · Staff only' : ''}
                  </p>
                  {document.notes && <p className="mt-1 whitespace-pre-wrap text-xs text-neutral-600">{document.notes}</p>}
                </div>
                <div className="flex shrink-0 gap-2">
                  <Button type="button" variant="outline" size="sm" onClick={() => void handlePreview(document)}>
                    <Eye className="mr-1.5 h-4 w-4" /> Preview
                  </Button>
                  <Button type="button" variant="outline" size="sm" onClick={() => void handleDownload(document)}>
                    <Download className="mr-1.5 h-4 w-4" /> Download
                  </Button>
                  {(!isClient || document.uploaded_by_id === user?.id) && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      className="text-red-600 hover:text-red-700"
                      aria-label={`Delete ${document.title}`}
                      onClick={() => void handleDelete(document)}
                    >
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
