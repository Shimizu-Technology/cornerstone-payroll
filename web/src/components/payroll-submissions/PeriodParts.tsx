import { useState, type ReactElement } from 'react';
import { CheckCircle2, Circle, Download, Eye, FileText } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { DocumentPreviewModal } from '@/components/documents/DocumentPreviewModal';
import { prepareDocumentPreview, type DocumentPreviewPayload } from '@/lib/documentPreview';
import type { ClientDocument } from '@/services/api';
import { changeSummary, formatGuam } from '@/lib/payrollSubmissionFormat';
import { STATUS_STEPS, type PayrollSubmissionsApi, type SubmissionRevision, type SubmissionStatus } from '@/services/payrollSubmissions';

// The shared status line. Text carries the state; color only reinforces it.
export function StatusLine({ status }: { status: SubmissionStatus }): ReactElement {
  const current = ({ waiting_for_files: 0, submitted: 1, received: 1, in_review: 2, draft_ready: 3, changes_requested: 4, approved: 4, paid: 5 } as const)[status];
  return (
    <ol className="flex flex-wrap gap-x-4 gap-y-2 text-sm" aria-label="Payroll status">
      {STATUS_STEPS.map((step, index) => {
        const done = index < current || (index === current && status !== 'submitted' && status !== 'changes_requested' && index > 0) || status === 'paid';
        const here = index === current;
        let label = step.label;
        if (index === 1 && status === 'submitted') label = 'Sent, waiting for Cornerstone to confirm';
        if (index === 4 && status === 'changes_requested') label = 'Changes requested';
        return (
          <li key={step.status} className={`flex items-center gap-1.5 ${here ? 'font-semibold text-neutral-950' : done ? 'text-neutral-700' : 'text-neutral-500'}`} aria-current={here ? 'step' : undefined}>
            {done ? <CheckCircle2 className="h-4 w-4 text-success-600" aria-hidden /> : <Circle className="h-4 w-4" aria-hidden />}
            <span>{label}</span>
            <span className="sr-only">{done ? '(done)' : here ? '(current)' : ''}</span>
          </li>
        );
      })}
    </ol>
  );
}

const ROLE_LABELS = { revel_payroll: 'Revel payroll PDF', changes_workbook: 'Changes workbook', attachment: 'Attachment' } as const;

type Audience = 'client' | 'staff';

export function FileRow({ label, document, fallbackName, api, audience }: { label: string; document?: ClientDocument | null; fallbackName?: string; api: PayrollSubmissionsApi; audience?: Audience }): ReactElement {
  const [previewOpen, setPreviewOpen] = useState(false);
  const [payload, setPayload] = useState<DocumentPreviewPayload | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const download = async (): Promise<void> => {
    if (!document) return;
    try {
      setError(null);
      const file = await api.documents.download(document.id);
      const url = URL.createObjectURL(file.blob);
      const link = window.document.createElement('a');
      link.href = url;
      link.download = file.filename || document.file_name;
      window.document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
    } catch (err) {
      // Close an open preview so the failure is visible beside the file.
      setPreviewOpen(false);
      setPayload(null);
      setError(err instanceof Error ? err.message : 'Download failed');
    }
  };
  const preview = async (): Promise<void> => {
    if (!document) return;
    try {
      setError(null); setPreviewOpen(true); setLoading(true); setPayload(null);
      const file = await api.documents.preview(document.id);
      setPayload(await prepareDocumentPreview(document, file.blob));
    } catch (err) { setError(err instanceof Error ? err.message : 'Preview failed'); setPreviewOpen(false); } finally { setLoading(false); }
  };
  // The client API refuses archived files, so a client sees the record, not a button that fails.
  const recordOnly = audience === 'client' && Boolean(document?.archived_at);
  return (
    <li className="flex flex-col gap-2 py-2 sm:flex-row sm:items-center sm:justify-between">
      <span className="flex min-w-0 items-start gap-2">
        <FileText className="mt-0.5 h-4 w-4 shrink-0 text-neutral-500" aria-hidden />
        <span className="min-w-0">
          <span className="block text-xs font-semibold text-neutral-600">{label}</span>
          <span className="block break-words text-sm text-neutral-900 [overflow-wrap:anywhere]">{document?.file_name || fallbackName}</span>
          {document?.archived_at && <span className="block text-xs text-neutral-600">{recordOnly ? 'Kept with this period as a record. Ask Cornerstone if you need it.' : 'Archived, kept as a record'}</span>}
          {document && document.scan_status === 'pending' && <span className="block text-xs text-neutral-600">Safety check in progress</span>}
          {error && <span role="alert" className="block text-xs text-danger-700">{error}</span>}
        </span>
      </span>
      {document && !recordOnly && <span className="flex shrink-0 gap-2">
        {document.preview_available && <Button type="button" size="sm" variant="outline" onClick={() => void preview()} aria-label={`Preview ${document.file_name}`}><Eye className="mr-1 h-4 w-4" aria-hidden />Preview</Button>}
        <Button type="button" size="sm" variant="outline" onClick={() => void download()} aria-label={`Download ${document.file_name}`}><Download className="mr-1 h-4 w-4" aria-hidden />Download</Button>
      </span>}
      <DocumentPreviewModal open={previewOpen} onOpenChange={(open) => { setPreviewOpen(open); if (!open) setPayload(null); }}
        document={document || null} payload={payload} loading={loading} onDownload={() => void download()} />
    </li>
  );
}


export function RevisionCard({ revision, api, companyId, audience }: { revision: SubmissionRevision; api: PayrollSubmissionsApi; companyId?: number | null; audience?: Audience }): ReactElement {
  const body = (
    <div className="space-y-3">
      <p className="text-sm text-neutral-700">
        Sent by {revision.submitted_by_name || 'Former portal user'} · {formatGuam(revision.submitted_at)}
        {revision.acknowledged_at ? <> · Received by {revision.acknowledged_by_name} · {formatGuam(revision.acknowledged_at)}</> : revision.current ? <> · Not yet confirmed by Cornerstone</> : null}
      </p>
      {revision.imported_at && <p className="text-sm font-semibold text-success-800">Imported · {formatGuam(revision.imported_at)}</p>}
      {revision.imports?.map(record => <p key={record.id} className="text-sm"><a className="text-primary-800 underline" href={companyId ? `/companies/${companyId}/pay-runs/${record.pay_period_id}` : `/pay-periods/${record.pay_period_id}`}>Import #{record.id} · {record.status}</a></p>)}
      <ul className="divide-y divide-neutral-100">
        {revision.documents.map(file => <FileRow key={`${file.role}-${file.document?.id || file.file_name}`} label={ROLE_LABELS[file.role]} document={file.document} fallbackName={file.file_name} api={api} audience={audience} />)}
      </ul>
      <div>
        <h4 className="text-sm font-semibold text-neutral-900">Changes this period</h4>
        {revision.no_changes ? <p className="text-sm text-neutral-700">No changes this period.</p>
          : revision.changes.length ? <ul className="mt-1 list-disc space-y-1 pl-5 text-sm text-neutral-800">{revision.changes.map((row, index) => <li key={index} className="break-words"><span className="font-medium">{row.label}:</span> {changeSummary(row)}{row.note ? ` — ${row.note}` : ''}</li>)}</ul>
          : <p className="text-sm text-neutral-600">No changes listed{revision.documents.some(d => d.role === 'changes_workbook') || revision.changes_link_url ? '; see the workbook or link.' : '.'}</p>}
        {revision.changes_link_url && <p className="mt-1 break-words text-sm"><a className="font-medium text-primary-800 underline" href={revision.changes_link_url} target="_blank" rel="noreferrer noopener">Payroll template link</a></p>}
      </div>
      {revision.notes && <div><h4 className="text-sm font-semibold text-neutral-900">Notes</h4><p className="whitespace-pre-wrap break-words text-sm text-neutral-800">{revision.notes}</p></div>}
    </div>
  );
  if (revision.current) {
    return <section aria-labelledby={`revision-${revision.id}`} className="rounded-xl border border-primary-200 bg-white p-4">
      <div className="mb-2 flex flex-wrap items-center gap-2"><h3 id={`revision-${revision.id}`} className="font-semibold text-neutral-950">Revision {revision.revision}</h3><Badge variant="info">Current</Badge></div>
      {body}
    </section>;
  }
  return <details className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
    <summary className="cursor-pointer font-semibold text-neutral-800">Revision {revision.revision} <Badge variant="outline" className="ml-2">Superseded</Badge> <span className="ml-1 text-sm font-normal text-neutral-600">{formatGuam(revision.submitted_at)}</span></summary>
    <div className="mt-3">{body}</div>
  </details>;
}
