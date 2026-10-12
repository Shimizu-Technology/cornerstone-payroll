import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { payPeriodsApi } from '@/services/api';
import { formatDate } from '@/lib/utils';
import type { AirePaymentEvidenceHold, AirePaymentEvidenceReview } from '@/types';

export function AirePaymentEvidenceHolds({ payPeriodId, onChanged, refreshToken = 0 }: { payPeriodId: number; onChanged: () => void; refreshToken?: number }) {
  const { hasCapability } = useAuth();
  const allowed = hasCapability('manage_historical_time_reconciliation');
  const [review, setReview] = useState<AirePaymentEvidenceReview | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [entryId, setEntryId] = useState('');
  const [retracting, setRetracting] = useState<AirePaymentEvidenceHold | null>(null);
  const [matching, setMatching] = useState<AirePaymentEvidenceHold | null>(null);
  const [itemId, setItemId] = useState('');
  const [reason, setReason] = useState('');
  const generation = useRef(0);
  const actionGeneration = useRef(0);
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
    setReview(null); setNotice(''); setReason(''); setEntryId(''); setRetracting(null); setMatching(null); setItemId(''); setBusy(false);
    command.current = null;
    return () => { generation.current += 1; actionGeneration.current += 1; };
  }, [allowed, payPeriodId]);
  useEffect(() => {
    if (allowed) void load();
    return () => { generation.current += 1; };
  }, [allowed, load, refreshToken]);
  if (!allowed) return null;

  const currentHold = retracting ? review?.payment_attestations.find(hold => hold.id === retracting.id) : undefined;
  const pendingMatches = review?.payment_resolutions?.filter(match => match.status === 'pending') || [];
  const pendingReportIds = new Set(pendingMatches.map(match => match.source_payment_attestation_id));
  const currentMatch = matching ? review?.payment_attestations.find(hold => hold.id === matching.id && hold.status === 'pending_evidence' && !pendingReportIds.has(hold.id)) : undefined;
  const selectedPayment = currentMatch?.payment_options?.find(item => item.payroll_item_id.toString() === itemId);
  const exactCapacity = !!(selectedPayment && currentMatch?.resolution_context?.available &&
    selectedPayment.regular_hours_available >= Number(currentMatch.resolution_context.regular_hours) &&
    selectedPayment.overtime_hours_available >= Number(currentMatch.resolution_context.overtime_hours));
  const selectedEntry = review?.candidates.find(candidate => candidate.source_time_entry_id === entryId);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (matching) {
      if (!currentMatch || !selectedPayment || !exactCapacity || reason.trim().length < 20 || busy || loading) return;
      const current = ++actionGeneration.current;
      setBusy(true); setError(''); setNotice('');
      try {
        const result = await payPeriodsApi.resolveAirePaymentHold(payPeriodId, currentMatch.id, {
          source_user_uuid: currentMatch.source_user_uuid, payroll_item_id: selectedPayment.payroll_item_id,
          expected_version: currentMatch.version, reason: reason.trim(),
        });
        if (current !== actionGeneration.current) return;
        setNotice(result.payment_resolution.status === 'matched'
          ? 'Existing payment matched. The original report and payment evidence are retained; no new payment was created.'
          : 'Match saved; receipt reconciliation is pending. Hours remain reserved. Retry the saved match below.');
        setMatching(null); setItemId(''); setReason('');
        await load();
        if (current === actionGeneration.current) onChanged();
      } catch (caught) {
        if (current === actionGeneration.current) { const message = caught instanceof Error ? caught.message : 'Could not match the existing payment'; await load(); if (current === actionGeneration.current) setError(message); }
      } finally { if (current === actionGeneration.current) setBusy(false); }
      return;
    }
    const entry = selectedEntry;
    if ((retracting ? !currentHold : !entry) || reason.trim().length < 20 || busy || loading) return;
    const current = ++actionGeneration.current;
    const payload = { source_user_uuid: currentHold?.source_user_uuid || entry!.source_user_uuid,
      expected_version: currentHold?.version ?? entry!.source_time_entry_version, reason: reason.trim() };
    const key = JSON.stringify({ payPeriodId, entryId, holdId: retracting?.id, ...payload });
    if (command.current?.key !== key) command.current = { key, id: crypto.randomUUID() };
    setBusy(true); setError(''); setNotice('');
    try {
      if (retracting) await payPeriodsApi.retractAirePaymentHold(payPeriodId, retracting.id, { ...payload, command_id: command.current.id });
      else await payPeriodsApi.createAirePaymentHold(payPeriodId, { ...payload, source_time_entry_id: entry!.source_time_entry_id, command_id: command.current.id });
      if (current !== actionGeneration.current) return;
      setNotice(retracting ? 'Payment hold retracted. Review settlement routing in time tracking Time Cards. Frozen payroll batches remain unchanged.'
        : 'Reported-payment hold recorded. Check evidence is still required; no payroll payment was created.');
      setReason(''); setEntryId(''); setRetracting(null); command.current = null;
      await load();
      if (current === actionGeneration.current) onChanged();
    } catch (caught) {
      if (current === actionGeneration.current) setError(`${caught instanceof Error ? caught.message : 'Payment evidence command failed'} Refresh the evidence before retrying if the source version changed.`);
    } finally { if (current === actionGeneration.current) setBusy(false); }
  };

  const retryMatch = async (id: number) => {
    const current = ++actionGeneration.current;
    setBusy(true); setError(''); setNotice('');
    try {
      const result = await payPeriodsApi.retryAirePaymentResolution(payPeriodId, id);
      if (current !== actionGeneration.current) return;
      setNotice(result.payment_resolution.status === 'matched' ? 'Saved match reconciled. Existing payment evidence is retained.'
        : 'The saved receipt is still pending. Hours remain reserved; payment changes remain blocked.');
      await load();
      if (current === actionGeneration.current) onChanged();
    } catch (caught) {
      if (current === actionGeneration.current) {
        const message = caught instanceof Error ? caught.message : 'Could not reconcile the saved match';
        await load();
        if (current === actionGeneration.current) setError(message);
      }
    }
    finally { if (current === actionGeneration.current) setBusy(false); }
  };

  return <Card aria-label="Reported-payment holds"><CardContent className="space-y-4 py-5">
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div><h2 className="font-semibold text-neutral-900">Reported-payment holds</h2>
        <p className="mt-1 max-w-3xl text-sm text-neutral-600">Use this when an owner reports payment but check evidence is pending. A hold prevents repayment; it does not verify payment. Match an unchanged report to an existing delivered check or confirmed bank payment. Review its employee, separate REG/OT hours, reference, amount, and actual payment date.</p></div>
      <Button className="max-sm:min-h-[44px]" type="button" variant="outline" size="sm" disabled={loading || busy} onClick={() => void load()}>Refresh payment evidence</Button>
    </div>
    {loading && <p role="status" className="text-sm">Loading payment evidence…</p>}
    {error && <p role="alert" className="rounded-lg bg-red-50 p-3 text-sm text-red-800">{error}</p>}
    {notice && <p role="status" className="rounded-lg bg-blue-50 p-3 text-sm text-blue-900">{notice}</p>}
    {review && <>
      {review.source_available === false && <p role="alert" className="rounded-lg bg-amber-50 p-3 text-sm">Source review is unavailable: {review.source_error}. Saved matches remain below; refresh when the source is available.</p>}
      <ul className="space-y-2" aria-label="Pending reported-payment holds">
        {review.payment_attestations.filter(hold => hold.status === 'pending_evidence').map(hold => <li key={hold.id} className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm">
          <div className="flex flex-wrap items-center justify-between gap-3"><div>
            <p className="font-medium">{hold.employee_name} · {formatDate(hold.work_date)} · {hold.hours.toFixed(2)} hours</p>
            <p>Payment reported; evidence pending · source entry {hold.source_time_entry_id}</p>
            <p className="mt-1 whitespace-pre-wrap">{hold.reason}</p>
            {hold.source_changed && <p className="mt-1 font-medium">Source changed after this hold. Review identity, date, and hours before routing.</p>}
          </div><div className="flex flex-wrap gap-2">
            <Button className="max-sm:min-h-[44px]" type="button" variant="outline" size="sm" disabled={busy || loading || !review.resolution_access || !hold.resolution_context?.available || pendingReportIds.has(hold.id)} onClick={() => { setMatching(hold); setItemId(''); setRetracting(null); setReason(''); setNotice(''); }}>Match existing payment</Button>
            <Button className="max-sm:min-h-[44px]" type="button" variant="outline" size="sm" disabled={busy || loading || pendingReportIds.has(hold.id)} onClick={() => { setMatching(null); setRetracting(hold); setEntryId(''); setReason(''); setNotice(''); }}>Retract hold</Button></div></div>
          {!hold.resolution_context?.available && hold.resolution_context?.reason && <p className="mt-2">{hold.resolution_context.reason}</p>}
          {!review.resolution_access && <p className="mt-2">Matching requires a verified Source capability and permitted connected account.</p>}
        </li>)}
      </ul>
      {review.payment_attestations.filter(hold => hold.status === 'pending_evidence').length === 0 && <p className="text-sm text-neutral-600">No pending reported-payment holds for this work period.</p>}
      {(review.payment_resolutions?.length ?? 0) > 0 && <ul className="space-y-2" aria-label="Saved reported-payment matches">
        {review.payment_resolutions!.map(match => <li key={match.id} className="rounded-lg border border-neutral-200 p-3 text-sm">
          <p className="font-semibold">{match.employee_name} · {formatDate(match.original_work_date)} · {match.status === 'pending' ? 'Match receipt pending' : 'Matched existing payment'}</p>
          <p>{match.regular_hours.toFixed(2)} REG + {match.overtime_hours.toFixed(2)} OT · {match.payment_method === 'paper_check' ? 'Check' : 'Bank reference'} {match.payment_reference} · paid {formatDate(match.payment_effective_on)}</p>
          <p>Payroll item {match.payroll_item_id} · pay run {match.pay_period_id} · current source allocation: {match.allocation_status}</p>
          <p className="whitespace-pre-wrap">Match reason: {match.note}</p>
          {match.original_report && <details className="mt-2"><summary className="min-h-11 cursor-pointer py-2 font-medium">Original reported-payment evidence</summary>
            <p>Reported {formatDate(match.original_report.attested_at)} · {match.original_report.hours.toFixed(2)} hours</p>
            <p className="whitespace-pre-wrap">{match.original_report.reason}</p>
            <p>This records the historical match. Current payment coverage follows the source allocation status above.</p>
          </details>}
          {match.status === 'pending' && <><p>Hours remain reserved. Reconcile this original command before changing the payment or report.</p>
            {match.last_sync_error && <p className="mt-1 text-red-800">{match.last_sync_error}</p>}
            <Button type="button" className="mt-2 max-sm:min-h-[44px]" disabled={busy || loading || !match.can_retry} onClick={() => void retryMatch(match.id)}>Retry saved match</Button>
            {!match.can_retry && <p>The original payroll operator must retry this saved match.</p>}</>}
        </li>)}
      </ul>}
      {review.payment_attestations.filter(hold => hold.status === 'resolved' && !review.payment_resolutions?.some(match => match.source_payment_attestation_id === hold.id)).map(hold => <details key={hold.id} className="rounded-lg bg-green-50 p-3 text-sm">
        <summary className="min-h-11 cursor-pointer py-2">{hold.employee_name} · {formatDate(hold.work_date)} · reported payment matched to source allocation {hold.resolved_manual_allocation_id}. Original report retained.</summary>
        <p className="whitespace-pre-wrap">{hold.reason}</p><p>Historical report match · resolved {hold.resolved_at ? formatDate(hold.resolved_at) : 'previously'}. Review the current source allocation payment status.</p>
      </details>)}
      <form onSubmit={event => void submit(event)} className="space-y-3 border-t border-neutral-200 pt-4">
        <h3 className="text-sm font-semibold">{matching ? `Match existing payment for source entry ${matching.source_time_entry_id}` : retracting ? `Retract hold for source entry ${retracting.source_time_entry_id}` : 'Record an owner-reported payment hold'}</h3>
        {matching ? <>
          <p className="text-sm text-neutral-600">Match the entire unchanged report. This records existing payment evidence and creates no new paycheck or bank transfer.</p>
          <p className="text-sm font-medium">{currentMatch?.resolution_context?.regular_hours} REG + {currentMatch?.resolution_context?.overtime_hours} OT · {currentMatch?.employee_name}</p>
          <Select label="Existing issued payroll payment" value={itemId} disabled={busy || loading} onChange={event => setItemId(event.target.value)}>
            <option value="">Choose the exact delivered check or confirmed bank payment</option>
            {currentMatch?.payment_options?.map(item => <option key={item.payroll_item_id} value={item.payroll_item_id}>{item.payment_method === 'paper_check' ? 'Check' : 'Bank'} {item.payment_reference} · ${item.net_pay.toFixed(2)} · paid {formatDate(item.payment_effective_on)} · run {item.pay_period_id} / item {item.payroll_item_id} · available {item.regular_hours_available.toFixed(2)} REG + {item.overtime_hours_available.toFixed(2)} OT</option>)}
          </Select>
          {selectedPayment && <div className="rounded-lg bg-neutral-50 p-3 text-sm">
            <p>Original payroll: {selectedPayment.regular_hours.toFixed(2)} REG + {selectedPayment.overtime_hours.toFixed(2)} OT · gross ${selectedPayment.gross_pay.toFixed(2)} · net ${selectedPayment.net_pay.toFixed(2)}</p>
            <p>Scheduled pay date {formatDate(selectedPayment.pay_date)} · payment date {formatDate(selectedPayment.payment_effective_on)} · evidence recorded {formatDate(selectedPayment.payment_recorded_at)}</p>
          </div>}
          {!currentMatch && <p role="alert" className="text-sm">This report has changed or already has a saved match. Review the current evidence and retry its saved command when pending.</p>}
          {currentMatch && !currentMatch.payment_options?.length && <p>No existing issued payroll item is available for this employee. Verify native delivery or bank evidence first.</p>}
          {selectedPayment && !exactCapacity && <p role="alert" className="text-sm text-red-800">This payment cannot cover the entire separate REG and OT portion. Preserve the report for historical review.</p>}
        </> : retracting ? <p className="text-sm text-neutral-600">Explain why the report is withdrawn. This returns the source to review; choose an eligible future settlement destination when required.</p>
          : <Select label="Source hours to hold" value={entryId} disabled={busy || loading} onChange={event => setEntryId(event.target.value)}>
            <option value="">Choose approved, mapped source hours</option>
            {review.candidates.map(entry => <option key={entry.source_time_entry_id} value={entry.source_time_entry_id}>{entry.employee_name} · {formatDate(entry.original_work_date)} · {entry.total_hours.toFixed(2)} hours · entry {entry.source_time_entry_id}</option>)}
          </Select>}
        {!matching && !retracting && review.candidates.length === 0 && <p className="text-sm text-neutral-600">No available approved hours. Already batched or allocated hours cannot receive a new hold.</p>}
        {retracting && !currentHold && <p role="alert" className="text-sm text-warning-900">This hold is no longer available. Cancel retraction and review the current evidence.</p>}
        <label className="block text-sm font-medium" htmlFor={`payment-evidence-reason-${payPeriodId}`}>{matching ? 'Existing payment match reason' : retracting ? 'Retraction reason' : 'Reporter and pending payment evidence'}</label>
        <Textarea id={`payment-evidence-reason-${payPeriodId}`} value={reason} onChange={event => setReason(event.target.value)} disabled={busy || loading} required minLength={20} rows={3} placeholder={matching ? 'Explain the exact unchanged hours and native issued payment evidence (at least 20 characters)' : retracting ? 'Explain why the payment report is being withdrawn (at least 20 characters)' : 'Who reported payment, what they reported, and which check or delivery evidence is still missing (at least 20 characters)'} />
        <div className="flex flex-wrap gap-2"><Button className="max-sm:min-h-[44px]" type="submit" disabled={busy || loading || reason.trim().length < 20 || (matching ? !currentMatch || !exactCapacity : retracting ? !currentHold : !selectedEntry)}>{busy ? 'Saving…' : matching ? 'Confirm existing payment match' : retracting ? 'Confirm retraction' : 'Record reported-payment hold'}</Button>
          {matching && <Button className="max-sm:min-h-[44px]" type="button" variant="outline" disabled={busy} onClick={() => { setMatching(null); setItemId(''); setReason(''); }}>Cancel match review</Button>}
          {retracting && <Button className="max-sm:min-h-[44px]" type="button" variant="outline" disabled={busy} onClick={() => { setRetracting(null); setReason(''); }}>Cancel retraction</Button>}</div>
      </form>
    </>}
  </CardContent></Card>;
}
