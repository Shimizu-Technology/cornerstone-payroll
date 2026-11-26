import { useId, useState, type FormEvent } from 'react';
import { isReverificationCancelledError } from '@clerk/react/errors';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { useOptionalStepUpRequest } from '@/lib/useOptionalStepUpRequest';
import { getApiBaseUrl } from '@/services/api';

const acknowledgement = 'I am approving this exact payroll revision for the client under Cornerstone authority.';

export function ClientApprovalOverride({ companyId, periodId, revisionId, onDone }: {
  companyId: number;
  periodId: number;
  revisionId: number;
  onDone: () => void;
}) {
  const reasonId = useId();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const reasonLength = Array.from(reason.trim()).length;
  const valid = reasonLength >= 10 && reasonLength <= 500;
  const request = useOptionalStepUpRequest((token: string) => fetch(
    `${getApiBaseUrl()}/admin/pay_periods/${periodId}/override_client_approval`,
    {
      method: 'POST',
      redirect: 'error',
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        'X-Company-Id': String(companyId),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ revision_id: revisionId, acknowledgement, override_reason: reason.trim() }),
    },
  ));

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (busy || !valid || !confirmed) return;
    setBusy(true);
    setError('');
    try {
      const response = await request();
      if (!response.ok) {
        const data = await response.json().catch(() => null);
        throw new Error(data?.error || 'Could not approve for the client.');
      }
      onDone();
      setOpen(false);
      setReason('');
      setConfirmed(false);
    } catch (cause) {
      if (!isReverificationCancelledError(cause)) {
        setError(cause instanceof Error ? cause.message : 'Could not approve for the client.');
      }
    } finally {
      setBusy(false);
    }
  };

  if (!open) return <Button variant="outline" onClick={() => setOpen(true)}>Approve for client</Button>;

  return <form onSubmit={submit} className="space-y-3">
    <label htmlFor={reasonId} className="block text-sm font-medium">Override reason (10–500 characters)</label>
    <Textarea id={reasonId} required value={reason} onChange={event => setReason(event.target.value)} disabled={busy} />
    <p className="text-sm">The client will see this reason in their portal.</p>
    <label className="flex items-start gap-2 text-sm">
      <input type="checkbox" checked={confirmed} onChange={event => setConfirmed(event.target.checked)} disabled={busy} />
      {acknowledgement}
    </label>
    {error && <p role="alert">{error}</p>}
    <div className="flex flex-wrap gap-2">
      <Button type="submit" disabled={busy || !valid || !confirmed}>{busy ? 'Approving…' : 'Confirm approval'}</Button>
      <Button type="button" variant="outline" disabled={busy} onClick={() => {
        setOpen(false);
        setReason('');
        setConfirmed(false);
        setError('');
      }}>Cancel</Button>
    </div>
  </form>;
}
