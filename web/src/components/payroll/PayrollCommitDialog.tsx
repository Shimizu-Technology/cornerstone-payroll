import { formatDate, formatDateRange } from '@/lib/display-date';
import { useEffect, useRef, useState } from 'react';
import { ApiError, payPeriodsApi, type PayrollCommitSnapshot } from '@/services/api';
import { payrollClientCommitReason } from '@/lib/payrollClientCommitReason';
import { Button } from '@/components/ui/button';
import { FicaHistoryReviewNotice } from './FicaHistoryReviewNotice';
import { BusyStatus } from '@/components/ui/busy-status';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { formatCurrency } from '@/lib/utils';
import type { PayPeriod } from '@/types';

type Props = {
  open: boolean;
  payPeriod: Pick<PayPeriod, 'id' | 'company_id' | 'status' | 'start_date' | 'end_date' | 'pay_date' | 'compliance_warnings' | 'annual_fica_review' | 'annual_fica_review_note' | 'correction_status' | 'payroll_review' | 'client_payroll_approval_required' | 'check_number_summary' | 'payroll_items' | 'outstanding_file_requests' | 'client_file_link_error'>;
  companyName: string;
  processing: boolean;
  onCancel: () => void;
  onConfirm: (payPeriodId: number, snapshot: PayrollCommitSnapshot) => Promise<void>;
};
type Conflict = { kind: 'counter'; previous: number; current: number } | { kind: 'requests'; added: number[]; resolved: string[] };
const warningStyle = 'rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm leading-6 text-warning-950';

export function PayrollCommitDialog({ open, payPeriod: initialPeriod, companyName, processing, onCancel, onConfirm }: Props) {
  const [loaded, setLoaded] = useState<{ id: number; companyId?: number; period: PayPeriod } | null>(null);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [conflict, setConflict] = useState<Conflict | null>(null);
  const generation = useRef(0);
  const conflictAlert = useRef<HTMLDivElement>(null);
  const payPeriod = loaded?.id === initialPeriod.id && loaded.companyId === initialPeriod.company_id ? loaded.period : initialPeriod;
  const ready = loaded?.id === initialPeriod.id && loaded.companyId === initialPeriod.company_id && !loading;
  useEffect(() => {
    if (ready && conflict) {
      conflictAlert.current?.focus({ preventScroll: true });
      conflictAlert.current?.scrollIntoView?.({ block: 'nearest' });
    }
  }, [ready, conflict]);
  const busy = processing || submitting;
  const requests = payPeriod.outstanding_file_requests ?? [];
  const items = payPeriod.payroll_items?.filter(item => item.payroll_included !== false) ?? [];
  const warnings = payPeriod.compliance_warnings?.filter(warning => warning !== payPeriod.annual_fica_review_note) ?? [];
  const totalNet = items.reduce((sum, item) => sum + Number(item.net_pay || 0), 0);

  useEffect(() => {
    const current = ++generation.current;
    setLoaded(null);
    setError(null);
    setConflict(null);
    setLoading(true);
    setSubmitting(false);
    if (open) {
      payPeriodsApi.get(initialPeriod.id, initialPeriod.company_id).then(({ pay_period }) => {
        if (current === generation.current) setLoaded({ id: initialPeriod.id, companyId: initialPeriod.company_id, period: pay_period });
      }).catch(err => {
        if (current === generation.current) setError(err instanceof Error ? err.message : 'Could not load the commit details. Close this dialog and try again.');
      }).finally(() => { if (current === generation.current) setLoading(false); });
    }
    return () => { generation.current += 1; };
  }, [open, initialPeriod.id, initialPeriod.company_id]);
  const requestKey = `${payPeriod.id}:${open}:${requests.map(request => `${request.id}:${request.status}`).join(',')}`;
  const [acknowledgedKey, setAcknowledgedKey] = useState<string | null>(null);
  useEffect(() => { setAcknowledgedKey(null); }, [open, payPeriod.id]);
  const acknowledged = acknowledgedKey === requestKey;
  const clientCommitReason = payPeriod.client_file_link_error || payrollClientCommitReason(payPeriod);
  const hasPaperChecks = items.some(item => (item.effective_payment_delivery_method ?? item.payment_delivery_method ?? 'paper_check') === 'paper_check');
  const numbering = payPeriod.check_number_summary;
  const canConfirm = ready && (!requests.length || acknowledged) && !clientCommitReason && !busy && payPeriod.status === 'approved' &&
    payPeriod.correction_status !== 'voided' && (!hasPaperChecks || !!numbering);
  const confirm = async () => {
    if (!canConfirm) return;
    const current = generation.current;
    setSubmitting(true);
    setError(null);
    try {
      await onConfirm(payPeriod.id, {
        acknowledged_outstanding_file_request_ids: requests.map(request => request.id),
        ...(hasPaperChecks && numbering ? { expected_next_check_number: numbering.next_check_number } : {}),
      });
    } catch (err) {
      if (current !== generation.current) return;
      const code = err instanceof ApiError ? (err.data as { code?: string } | undefined)?.code : undefined;
      if (code === 'outstanding_file_requests_changed' || code === 'check_number_changed') {
        setAcknowledgedKey(null);
        setLoaded(null);
        setConflict(null);
        setLoading(true);
        try {
          const { pay_period } = await payPeriodsApi.get(initialPeriod.id, initialPeriod.company_id);
          if (current === generation.current) {
            setLoaded({ id: initialPeriod.id, companyId: initialPeriod.company_id, period: pay_period });
            if (code === 'check_number_changed' && numbering && pay_period.check_number_summary) {
              setConflict({ kind: 'counter', previous: numbering.next_check_number, current: pay_period.check_number_summary.next_check_number });
            } else if (code === 'outstanding_file_requests_changed') {
              const updated = pay_period.outstanding_file_requests ?? [];
              setConflict({ kind: 'requests', added: updated.filter(request => !requests.some(old => old.id === request.id)).map(request => request.id),
                resolved: requests.filter(old => !updated.some(request => request.id === old.id)).map(request => request.title) });
            } else {
              // Nothing to show beside the numbering (no paper checks or no summary): say why Confirm stopped.
              setError(err instanceof Error ? err.message : 'This payroll changed. Review it and confirm again.');
            }
          }
        } catch {
          if (current === generation.current) setError('Could not reload the commit details. Close this dialog and try again.');
        } finally {
          if (current === generation.current) setLoading(false);
        }
      } else {
        setError(err instanceof Error ? err.message : 'Could not commit payroll. Try again.');
      }
    } finally {
      if (current === generation.current) setSubmitting(false);
    }
  };
  return <Dialog open={open} onOpenChange={value => { if (!value && !busy) onCancel(); }} dismissOnEscape={!busy}>
    <DialogContent className="max-h-[calc(100dvh-2rem)] overflow-y-auto">
      <DialogHeader>
        <DialogTitle>Commit and finalize payroll?</DialogTitle>
        <DialogDescription>This locks the calculated payroll and updates year-to-date totals. Checks and bank payments require separate issuance or settlement confirmation.</DialogDescription>
      </DialogHeader>
      {loading && <p role="status" className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-700">Loading current requests and check numbering…</p>}
      {error && <p role="alert" className={warningStyle}>{error}</p>}
      {ready && <div className="space-y-4">
        <dl className="grid gap-3 rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm sm:grid-cols-2">
          <div><dt className="text-neutral-600">Company</dt><dd className="font-semibold text-neutral-950">{companyName}</dd></div>
          <div><dt className="text-neutral-600">Pay run</dt><dd className="font-semibold text-neutral-950">#{payPeriod.id}</dd></div>
          <div><dt className="text-neutral-600">Work dates</dt><dd>{formatDateRange(payPeriod.start_date, payPeriod.end_date)}</dd></div>
          <div><dt className="text-neutral-600">Scheduled pay date</dt><dd>{formatDate(payPeriod.pay_date)}</dd></div>
          <div><dt className="text-neutral-600">Payroll items</dt><dd>{items.length}</dd></div>
          <div><dt className="text-neutral-600">Total net pay</dt><dd className="font-semibold">{formatCurrency(totalNet)}</dd></div>
        </dl>
        {hasPaperChecks && numbering && <section aria-label="Check numbering" className="space-y-2 text-sm leading-6 text-neutral-700">
          {conflict?.kind === 'counter' && <div role="alert" ref={conflictAlert} tabIndex={-1} className={warningStyle}>The next check number changed to {conflict.current} (it was {conflict.previous}). Check your stock, then confirm again.</div>}
          <p>Paper checks will be numbered from {numbering.next_check_number} (last used: {numbering.last_used_check_number ?? 'none'})</p>
          {numbering.last_used_check_number !== null && numbering.next_check_number <= numbering.last_used_check_number && <p role="alert" className="font-semibold text-warning-900">The next check number ({numbering.next_check_number}) is at or below the last one used ({numbering.last_used_check_number}). Check the stock before committing.</p>}
          {numbering.can_change && <a className="font-medium text-primary-700 underline" href="/check-settings">Review check settings</a>}
        </section>}
        <FicaHistoryReviewNotice payPeriod={payPeriod} />
        {warnings.length > 0 && <div className={warningStyle}>
          <p className="font-semibold">Review these warnings before committing</p>
          <ul className="mt-2 list-disc space-y-1 pl-5">{warnings.map((warning, index) => <li key={index}>{warning}</li>)}</ul>
        </div>}
        {(!!requests.length || conflict?.kind === 'requests') && <section aria-label="Outstanding client file requests" className="space-y-3 text-sm">
          {conflict?.kind === 'requests' && <div role="alert" ref={conflictAlert} tabIndex={-1} className={warningStyle}>
            <p>{requests.length ? 'A file request was added or resolved. Review the list and tick the box again.' : 'A file request was added or resolved. No requests remain outstanding. Review the updated details, then confirm again.'}</p>
            {!!conflict.resolved.length && <p className="mt-2 break-words">Resolved: {conflict.resolved.join('; ')}</p>}
          </div>}
          <div className={warningStyle}>
            <p className="font-semibold">Outstanding client file requests</p>
            {requests.length ? <>
              <ul className="mt-2 list-disc space-y-2 pl-5">{requests.map(request => <li key={request.id} className="break-words">{request.title} — {request.status_label}{conflict?.kind === 'requests' && conflict.added.includes(request.id) && <span className="font-semibold"> — Added</span>}</li>)}</ul>
              <label className="mt-3 flex min-h-11 cursor-pointer items-start gap-3 leading-6">
                <input type="checkbox" className="mt-1 h-5 w-5 shrink-0" checked={acknowledged} disabled={busy}
                  onChange={event => setAcknowledgedKey(event.target.checked ? requestKey : null)} />
                <span>I reviewed these outstanding requests and will finalize payroll without the requested files being accepted.</span>
              </label>
            </> : <p className="mt-2">None outstanding.</p>}
          </div>
        </section>}
        {clientCommitReason && <p role="alert" className={`${warningStyle} whitespace-pre-wrap break-words`}>{clientCommitReason}</p>}
        <p className="text-sm leading-6 text-neutral-600">Review this run before confirming. Later payroll changes must use the corrections workflow.</p>
      </div>}
      <BusyStatus className="mt-3" busy={busy}>Committing payroll… This can take a few seconds.</BusyStatus>
      <DialogFooter className="gap-2 sm:gap-0">
        <Button className="max-sm:min-h-[44px]" type="button" variant="outline" disabled={busy} onClick={onCancel}>Keep reviewing</Button>
        <Button className="max-sm:min-h-[44px]" type="button" loading={busy} loadingLabel="Committing…" disabled={!canConfirm} onClick={() => void confirm()}>Confirm commit</Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>;
}
