import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { payPeriodsApi } from '@/services/api';
import { formatDate } from '@/lib/utils';
import type { AirePaymentEvidenceHold, AirePaymentEvidenceReview } from '@/types';

export function AirePaymentEvidenceHolds({ payPeriodId, onChanged }: { payPeriodId: number; onChanged: () => void }) {
  const { hasCapability } = useAuth();
  const allowed = hasCapability('manage_historical_time_reconciliation');
  const [review, setReview] = useState<AirePaymentEvidenceReview | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [entryId, setEntryId] = useState('');
  const [retracting, setRetracting] = useState<AirePaymentEvidenceHold | null>(null);
  const [reason, setReason] = useState('');
  const generation = useRef(0);
  const command = useRef<{ key: string; id: string } | null>(null);
  const load = useCallback(async () => {
    const current = ++generation.current;
    setLoading(true); setError('');
    try {
      const result = await payPeriodsApi.airePaymentEvidence(payPeriodId);
      if (current === generation.current) setReview(result);
    } catch (caught) {
      if (current === generation.current) { setReview(null); setError(caught instanceof Error ? caught.message : 'Could not load payment evidence'); }
    } finally { if (current === generation.current) setLoading(false); }
  }, [payPeriodId]);
  useEffect(() => {
    if (allowed) void load();
    return () => { generation.current += 1; };
  }, [allowed, load]);
  if (!allowed) return null;

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const entry = review?.candidates.find(candidate => candidate.source_time_entry_id === entryId);
    if ((!entry && !retracting) || reason.trim().length < 20 || busy) return;
    const current = generation.current;
    const payload = { source_user_uuid: retracting?.source_user_uuid || entry!.source_user_uuid,
      expected_version: retracting?.version ?? entry!.source_time_entry_version, reason: reason.trim() };
    const key = JSON.stringify({ payPeriodId, entryId, holdId: retracting?.id, ...payload });
    if (command.current?.key !== key) command.current = { key, id: crypto.randomUUID() };
    setBusy(true); setError(''); setNotice('');
    try {
      if (retracting) await payPeriodsApi.retractAirePaymentHold(payPeriodId, retracting.id, { ...payload, command_id: command.current.id });
      else await payPeriodsApi.createAirePaymentHold(payPeriodId, { ...payload, source_time_entry_id: entry!.source_time_entry_id, command_id: command.current.id });
      if (current !== generation.current) return;
      setNotice(retracting ? 'Payment hold retracted. Review settlement routing in time tracking Time Cards. Frozen payroll batches remain unchanged.'
        : 'Reported-payment hold recorded. Check evidence is still required; no payroll payment was created.');
      setReason(''); setEntryId(''); setRetracting(null); command.current = null;
      await load(); onChanged();
    } catch (caught) {
      if (current === generation.current) setError(`${caught instanceof Error ? caught.message : 'Payment evidence command failed'} Refresh the evidence before retrying if the source version changed.`);
    } finally { setBusy(false); }
  };

  return <Card aria-label="Reported-payment holds"><CardContent className="space-y-4 py-5">
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div><h2 className="font-semibold text-neutral-900">Reported-payment holds</h2>
        <p className="mt-1 max-w-3xl text-sm text-neutral-600">Use this when an owner reports payment but check evidence is pending. A hold prevents repayment; it does not verify payment. Match the actual payroll item, check, amount, and delivery date through historical review.</p></div>
      <Button type="button" variant="outline" size="sm" disabled={loading || busy} onClick={() => void load()}>Refresh payment evidence</Button>
    </div>
    {loading && <p role="status" className="text-sm">Loading payment evidence…</p>}
    {error && <p role="alert" className="rounded-lg bg-red-50 p-3 text-sm text-red-800">{error}</p>}
    {notice && <p role="status" className="rounded-lg bg-blue-50 p-3 text-sm text-blue-900">{notice}</p>}
    {review && <>
      <ul className="space-y-2" aria-label="Pending reported-payment holds">
        {review.payment_attestations.map(hold => <li key={hold.id} className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm">
          <div className="flex flex-wrap items-center justify-between gap-3"><div>
            <p className="font-medium">{hold.employee_name} · {formatDate(hold.work_date)} · {hold.hours.toFixed(2)} hours</p>
            <p>Payment reported; evidence pending · source entry {hold.source_time_entry_id}</p>
            <p className="mt-1 whitespace-pre-wrap">{hold.reason}</p>
            {hold.source_changed && <p className="mt-1 font-medium">Source changed after this hold. Review identity, date, and hours before routing.</p>}
          </div><Button type="button" variant="outline" size="sm" disabled={busy || loading} onClick={() => { setRetracting(hold); setEntryId(''); setReason(''); setNotice(''); }}>Retract hold</Button></div>
        </li>)}
      </ul>
      {review.payment_attestations.length === 0 && <p className="text-sm text-neutral-600">No pending reported-payment holds for this work period.</p>}
      <form onSubmit={event => void submit(event)} className="space-y-3 border-t border-neutral-200 pt-4">
        <h3 className="text-sm font-semibold">{retracting ? `Retract hold for source entry ${retracting.source_time_entry_id}` : 'Record an owner-reported payment hold'}</h3>
        {retracting ? <p className="text-sm text-neutral-600">Explain why the report is withdrawn. This returns the source to review; choose an eligible future settlement destination when required.</p>
          : <Select label="Source hours to hold" value={entryId} disabled={busy || loading} onChange={event => setEntryId(event.target.value)}>
            <option value="">Choose approved, mapped source hours</option>
            {review.candidates.map(entry => <option key={entry.source_time_entry_id} value={entry.source_time_entry_id}>{entry.employee_name} · {formatDate(entry.original_work_date)} · {entry.total_hours.toFixed(2)} hours · entry {entry.source_time_entry_id}</option>)}
          </Select>}
        {!retracting && review.candidates.length === 0 && <p className="text-sm text-neutral-600">No available approved hours. Already batched or allocated hours cannot receive a new hold.</p>}
        <label className="block text-sm font-medium" htmlFor={`payment-evidence-reason-${payPeriodId}`}>{retracting ? 'Retraction reason' : 'Reporter and pending payment evidence'}</label>
        <Textarea id={`payment-evidence-reason-${payPeriodId}`} value={reason} onChange={event => setReason(event.target.value)} disabled={busy || loading} required minLength={20} rows={3} placeholder={retracting ? 'Explain why the payment report is being withdrawn (at least 20 characters)' : 'Who reported payment, what they reported, and which check or delivery evidence is still missing (at least 20 characters)'} />
        <div className="flex flex-wrap gap-2"><Button type="submit" disabled={busy || loading || reason.trim().length < 20 || (!entryId && !retracting)}>{busy ? 'Saving…' : retracting ? 'Confirm retraction' : 'Record reported-payment hold'}</Button>
          {retracting && <Button type="button" variant="outline" disabled={busy} onClick={() => { setRetracting(null); setReason(''); }}>Cancel retraction</Button>}</div>
      </form>
    </>}
  </CardContent></Card>;
}
