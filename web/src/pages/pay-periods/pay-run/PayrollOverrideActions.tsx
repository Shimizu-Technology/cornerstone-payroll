import { useState, type FormEvent } from 'react';
import { Button } from '@/components/ui/button';
import { useOptionalStepUpRequest } from '@/lib/useOptionalStepUpRequest';
import { apiClient } from '@/services/api';
import { sendPayrollApprovalRequest } from '@/services/payroll-approval-api';

type Props = {
  companyId: number;
  periodId: number;
  reviewId?: string | null;
  canRetry?: boolean;
  onReviewComplete: () => void;
};

export function PayrollOverrideActions({ companyId, periodId, reviewId, canRetry, onReviewComplete }: Props) {
  const [action, setAction] = useState<'review' | 'retry' | null>(null);
  const [job, setJob] = useState('stub_posting');
  const [reason, setReason] = useState('');
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);
  const sendRetry = useOptionalStepUpRequest((token: string, body: object) =>
    sendPayrollApprovalRequest(token, companyId, '/admin/payroll_job_retry', 'POST', body));

  if (!reviewId && !canRetry && !message) return null;

  function open(next: typeof action) {
    setAction(next);
    setReason('');
    setError('');
    setMessage('');
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      if (action === 'review') {
        await apiClient.post(`/admin/pay_periods/${periodId}/complete_rollback_review`,
          { review_id: reviewId, reason: reason.trim() }, { companyId });
        onReviewComplete();
        setMessage('Rollback review marked complete.');
      } else {
        const response = await sendRetry({ job, reason: reason.trim() });
        if (!response.ok) {
          const body = await response.json().catch(() => ({}));
          throw new Error(body.error || 'The job retry could not be queued.');
        }
        setMessage('Job retry queued for this client.');
      }
      setAction(null);
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'The change could not be saved.');
    } finally {
      setBusy(false);
    }
  }

  return <section aria-label="Payroll recovery" className="space-y-3 px-4 py-3">
    <div className="flex flex-wrap gap-2">
      {reviewId && <Button variant="outline" disabled={busy} onClick={() => open('review')}>Mark rollback review complete</Button>}
      {canRetry && <Button variant="outline" disabled={busy} onClick={() => open('retry')}>Re-run a stuck job</Button>}
    </div>
    {action && <form onSubmit={submit} className="max-w-lg space-y-3">
      {action === 'retry' && <label className="block">Job
        <select value={job} onChange={event => setJob(event.target.value)} disabled={busy} className="ml-2 rounded border p-1">
          <option value="stub_posting">Pay stub posting</option>
          <option value="notification_dispatch">Notification dispatch</option>
        </select>
      </label>}
      <label className="block">Reason
        <textarea required minLength={10} maxLength={1000} value={reason} disabled={busy}
          onChange={event => setReason(event.target.value)} className="mt-1 block w-full rounded border p-2" rows={3} />
      </label>
      <div className="flex gap-2">
        <Button type="submit" disabled={busy || reason.trim().length < 10}>{action === 'retry' ? 'Queue retry' : 'Complete review'}</Button>
        <Button type="button" variant="outline" disabled={busy} onClick={() => open(null)}>Cancel</Button>
      </div>
      {error && <p role="alert">{error}</p>}
    </form>}
    {message && <p role="status">{message}</p>}
  </section>;
}
