import { useEffect, useRef, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Textarea } from '@/components/ui/textarea';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { PdfPreview, type PdfArtifact } from '@/components/documents/PdfPreview';
import { clientPayPeriodsApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import { formatGuam } from '@/lib/payrollSubmissionFormat';
import type { PayPeriod } from '@/types';
import { ViewOnlyNotice } from './ViewOnlyNotice';
import { useClientViewOnly } from '@/hooks/useClientViewOnly';

export function ClientPayrollReview({ payPeriod, companyId, onDone }: {
  payPeriod: PayPeriod; companyId: number; onDone: () => Promise<void>;
}) {
  const viewOnly = useClientViewOnly();
  const active = useRef(true);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  const [note, setNote] = useState('');
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [artifact, setArtifact] = useState<PdfArtifact | null>(null);
  const review = payPeriod.payroll_review;
  const canReview = payPeriod.status === 'approved' && !!review?.published_at;
  // The server's flag is already false for a Client viewer; this keeps the
  // controls hidden even if a stale payload says otherwise.
  const canDecide = !viewOnly && canReview && review?.status === 'pending' && payPeriod.can_decide_payroll_review === true;

  const handleFailure = async (cause: unknown, fallback: string) => {
    if (!active.current) return;
    const stale = cause instanceof Error && 'data' in cause && !!cause.data && typeof cause.data === 'object' &&
      'code' in cause.data && cause.data.code === 'stale_payroll_review_revision';
    if (stale) {
      setConfirmed(false); setArtifact(null);
      setError('This payroll was updated. Review the latest preview.');
      try { await onDone(); } catch { /* Keep the recovery message if reload fails. */ }
    } else setError(cause instanceof Error ? cause.message : fallback);
  };
  useEffect(() => { setConfirmed(false); setArtifact(null); }, [review?.id]);

  const preview = async (view: boolean, allStubs = false) => {
    if (!review) return;
    setBusy(true); setError(null);
    try {
      const file = allStubs
        ? await clientPayPeriodsApi.previewPdf(payPeriod.id, companyId, review.id, 'all_stubs')
        : await clientPayPeriodsApi.previewPdf(payPeriod.id, companyId, review.id);
      const filename = file.filename || `Payroll_PREVIEW_rev${review.revision}.pdf`;
      if (view) setArtifact({ blob: file.blob, filename, title: `PREVIEW · revision ${review.revision}` });
      else {
        const url = URL.createObjectURL(file.blob);
        const anchor = document.createElement('a'); anchor.href = url; anchor.download = filename;
        document.body.appendChild(anchor); anchor.click(); anchor.remove();
        window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      }
    } catch (cause) { await handleFailure(cause, 'Could not open the preview. Try again.'); }
    finally { setBusy(false); }
  };
  const decide = async (approve: boolean) => {
    if (!review || !canDecide || (approve ? !confirmed : !note.trim())) return;
    setBusy(true); setError(null);
    try {
      if (approve) await clientPayPeriodsApi.approveReview(payPeriod.id, companyId, {
        revision_id: review.id, acknowledgement: review.acknowledgement, notes: note.trim() || undefined,
      });
      else await clientPayPeriodsApi.requestChanges(payPeriod.id, companyId, { revision_id: review.id, note: note.trim() });
      if (!active.current) return;
      setConfirmed(false); setNote(''); await onDone();
    } catch (cause) { await handleFailure(cause, 'Could not send your decision. Your note is still here.'); }
    finally { setBusy(false); }
  };
  if (payPeriod.client_payroll_approval_required === false || (!review?.published_at && !payPeriod.payroll_review_history?.length)) return null;
  return <Card className="border-primary-200">
    <CardContent className="space-y-4 pt-6 [&_button]:min-h-11">
      <div>
        <h2 className="text-xl font-semibold text-neutral-950">Review preview</h2>
        <p className="mt-1 text-sm text-neutral-700">{canReview ? `Revision ${review?.revision} · Review ID ${review?.checksum_short}${canDecide ? '. Review the preview checks and pay stubs, then approve or request changes.' : '.'}` : 'Payroll preview review is closed. See the revision history below.'}</p>
      </div>
      {canReview && <>
        <p className="text-sm font-medium">Gross pay {formatCurrency(payPeriod.total_gross ?? 0)} · Net pay {formatCurrency(payPeriod.total_net ?? 0)}</p>
        <div className="flex flex-wrap gap-3">
          <Button variant="outline" disabled={busy} onClick={() => void preview(true)}>View preview</Button>
          <Button variant="outline" disabled={busy} onClick={() => void preview(false)}>Download preview</Button>
        </div>
        <p className="text-sm text-neutral-600">The preview includes paper checks, plus separate stubs for direct deposit and statement-only employees.</p>
        <Button variant="outline" className="h-auto whitespace-normal text-left" disabled={busy} onClick={() => void preview(false, true)}>All pay stubs (including paper-check employees)</Button>
      </>}
      {review?.status === 'approved' && <p role="status" className="font-semibold text-success-800">Revision {review.revision} approved by {review.approved_by_name}. {review.notification_queued ? 'Your Cornerstone account team is queued to be emailed.' : 'Recorded. Cornerstone will see it in Client Inbox.'}</p>}
      {review?.change_request_note && <div role="status" className="space-y-1 rounded-lg bg-warning-50 p-4 text-warning-950">
        <p className="font-semibold">Changes requested by {review.changes_requested_by_name}</p>
        <p className="whitespace-pre-wrap break-words">{review.change_request_note}</p>
        <p>{review.notification_queued ? 'Your Cornerstone account team is queued to be emailed.' : 'Recorded. Cornerstone will see it in Client Inbox.'} You’ll receive a new revision to review after the changes.</p>
      </div>}
      {viewOnly && canReview && review?.status === 'pending' && <ViewOnlyNotice />}
      {canDecide && <div className="max-w-3xl space-y-4">
        <label className="block text-sm font-medium" htmlFor="review-note">Note for Cornerstone (required to request changes)</label>
        <Textarea id="review-note" value={note} onChange={event => setNote(event.target.value)} maxLength={2000} disabled={busy} />
        <label className="flex items-start gap-3 text-sm leading-6">
          <input type="checkbox" className="mt-1 h-5 w-5 shrink-0" checked={confirmed} onChange={event => setConfirmed(event.target.checked)} disabled={busy} />
          <span>I reviewed the preview. {review.acknowledgement}</span>
        </label>
        <div className="flex flex-col gap-3 sm:flex-row">
          <Button disabled={busy || !confirmed} onClick={() => void decide(true)}>Approve this revision</Button>
          <Button variant="outline" disabled={busy || !note.trim()} onClick={() => void decide(false)}>Request changes</Button>
        </div>
      </div>}
      {error && <ActionFeedback tone="error" message={error} />}
      {!!payPeriod.payroll_review_history?.length && <details>
        <summary className="min-h-11 cursor-pointer py-3 font-semibold">Revision and request history</summary>
        <ol className="space-y-4">
          {payPeriod.payroll_review_history.map(entry => <li key={entry.id} className="space-y-1 border-t border-neutral-200 pt-3 text-sm">
            <p className="font-semibold">Revision {entry.revision} · {entry.status.replace('_', ' ')}</p>
            {entry.published_at && <p>Published {formatGuam(entry.published_at)}</p>}
            {entry.approved_at && <p>Approved by {entry.approved_by_name} · {formatGuam(entry.approved_at)}</p>}
            {entry.approval_notes && <p className="whitespace-pre-wrap break-words">{entry.approval_notes}</p>}
            {entry.changes_requested_at && <p>Changes requested by {entry.changes_requested_by_name} · {formatGuam(entry.changes_requested_at)}</p>}
            {entry.change_request_note && <p className="whitespace-pre-wrap break-words">{entry.change_request_note}</p>}
            {entry.supersession_reason && <p>{entry.supersession_reason}</p>}
          </li>)}
        </ol>
      </details>}
      <PdfPreview artifact={artifact} onClose={() => setArtifact(null)} />
    </CardContent>
  </Card>;
}
