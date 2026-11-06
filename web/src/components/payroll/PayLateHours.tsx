import { useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { payPeriodsApi } from '@/services/api';
import { payRunPath } from '@/lib/routes';
import { formatDate, formatCurrency } from '@/lib/utils';

export type LateHoursRun = { id: number; pay_period_id: number; pay_date: string; applied: boolean; last_error: string | null;
  state?: string; closed?: boolean };
export type LateHoursReview = {
  period_version: number | null; source_error?: string; can_pay: boolean; runs: LateHoursRun[];
  cases: { id: string; version: number; employee: { name: string }; reason: string; total_hours: number; blocked_reason?: string | null;
    adjustments: { line_key: string; source_time_entry_id: string; original_work_date: string; category?: { name?: string };
      regular_hours: number; overtime_hours: number; payroll_rate: number | null }[] }[];
};

export function PayLateHours({ payPeriodId, canPay }: { payPeriodId: number; canPay: boolean }) {
  const navigate = useNavigate();
  const { companyId } = useParams();
  const adjustmentPath = (id: number) => companyId ? payRunPath(Number(companyId), id, 'work') : `/pay-periods/${id}`;
  const [open, setOpen] = useState(false);
  const [review, setReview] = useState<LateHoursReview | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const [payDate, setPayDate] = useState(() => new Date().toLocaleDateString('en-CA', { timeZone: 'Pacific/Guam' }));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [cancellation, setCancellation] = useState<{ runId: number; reason: string } | null>(null);
  const commandId = useRef<string | null>(null);
  const locked = useRef(false);

  async function load() {
    setBusy(true); setError(null);
    try { const result = await payPeriodsApi.lateHours(payPeriodId); setReview(result); setError(result.source_error || null); }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'Could not load late hours'); }
    finally { setBusy(false); }
  }

  async function submit(runId?: number) {
    if (locked.current || !review) return;
    locked.current = true; setBusy(true); setError(null);
    try {
      commandId.current ||= crypto.randomUUID();
      const result = runId
        ? await payPeriodsApi.retryLateHours(payPeriodId, runId)
        : await payPeriodsApi.payLateHours(payPeriodId, { command_id: commandId.current, expected_version: review.period_version ?? 0,
          pay_date: payDate, cases: review.cases.filter(row => selected.includes(row.id)).map(({ id, version }) => ({ id, version })) });
      if (result.late_hours_run.applied) navigate(adjustmentPath(result.late_hours_run.pay_period_id));
      else { commandId.current = null; setSelected([]); await load(); }
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : 'Could not create the adjustment';
      // Recover the durable destination even if the create response was lost.
      try { const result = await payPeriodsApi.lateHours(payPeriodId); setReview(result); setError(result.source_error || null); } catch { /* Keep the reviewed selection and original error. */ }
      setError(message);
      commandId.current = null;
    } finally { locked.current = false; setBusy(false); }
  }

  async function cancelClaim() {
    if (!cancellation || locked.current) return;
    locked.current = true; setBusy(true); setError(null);
    try {
      await payPeriodsApi.cancelLateHours(payPeriodId, cancellation.runId, cancellation.reason);
      setCancellation(null); setSelected([]); commandId.current = null;
      await load();
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Could not confirm cancellation. The hours stay reserved.'); }
    finally { locked.current = false; setBusy(false); }
  }

  const total = review?.cases.filter(row => selected.includes(row.id)).reduce((sum, row) => sum + row.total_hours, 0) || 0;
  return <>
    <Button type="button" variant="outline" disabled={!canPay} title={!canPay ? 'Client management access and an AIRE connection are required' : undefined}
      onClick={() => { setOpen(true); setSelected([]); setCancellation(null); commandId.current = null; void load(); }}>Pay late hours</Button>
    <Dialog open={open} onOpenChange={value => { if (!busy) setOpen(value); }}>
      <DialogContent className="max-w-2xl">
        <DialogHeader><DialogTitle>Pay late hours</DialogTitle><DialogDescription>
          Choose approved hours for a separate adjustment run. The locked payroll stays unchanged. Calculate, approve and commit the adjustment, then record its payment as usual.
        </DialogDescription></DialogHeader>
        {error && <p role="alert" className="rounded-lg bg-danger-50 p-3 text-sm text-danger-800">{error}</p>}
        {busy && !review && <p role="status">Checking approved unpaid hours…</p>}
        {review && <div className="space-y-4">
          {review.runs.map(run => <div key={run.id} className="rounded-lg border border-neutral-200 p-3 text-sm">
            {run.closed ? <><p className="font-semibold">Adjustment #{run.pay_period_id} closed — {run.state === 'cancelled' ? 'unpaid claim cancelled' : 'no source claim'}</p>
              <p className="mt-1 text-neutral-600">No hours were imported. Choose the current eligible hours for a new adjustment.</p></>
              : run.applied ? <Link to={adjustmentPath(run.pay_period_id)} className="font-semibold text-primary-700 underline">Open adjustment #{run.pay_period_id}</Link>
              : <><p className="font-semibold">Adjustment #{run.pay_period_id} needs to finish importing</p><p className="mt-1 text-neutral-600">{run.last_error || 'The source request is saved. Resume it to confirm the reserved hours.'}</p>
                <div className="mt-2 flex flex-wrap gap-2"><Button type="button" variant="outline" disabled={busy || !review.can_pay} onClick={() => void submit(run.id)}>Resume adjustment</Button>
                  <Button type="button" variant="outline" disabled={busy || !review.can_pay} onClick={() => setCancellation({ runId: run.id, reason: '' })}>Review cancellation</Button></div>
                {cancellation?.runId === run.id && <div className="mt-3 space-y-2 border-t border-neutral-200 pt-3">
                  <p>The source must confirm this claim has no imported or payment evidence. Cancellation keeps the saved record and releases the unpaid hours for a fresh selection.</p>
                  <label className="block font-semibold">Cancellation reason<textarea value={cancellation.reason} onChange={event => setCancellation({ runId: run.id, reason: event.target.value })}
                    disabled={busy} className="mt-1 block w-full rounded-lg border border-neutral-300 p-2 text-base" /></label>
                  <Button type="button" variant="outline" disabled={busy || cancellation.reason.trim().length < 10 || !review.can_pay} onClick={() => void cancelClaim()}>Cancel unpaid claim</Button>
                </div>}</>}
            <p className="mt-1 text-neutral-600">Pay date {formatDate(run.pay_date)}{!run.closed && ` · ${run.applied ? 'Hours imported; continue the payroll flow' : 'Uses the same saved source selection'}`}</p>
          </div>)}
          {!review.cases.length && !review.source_error && <p className="text-sm text-neutral-600">No approved late hours are waiting for an adjustment. Hours already paid, reserved, routed elsewhere or awaiting approval are excluded.</p>}
          {review.cases.map(row => <label key={row.id} className="flex items-start gap-3 rounded-lg border border-neutral-200 p-3 text-sm">
            <input type="checkbox" className="mt-1 h-5 w-5 shrink-0" aria-label={`${row.employee.name} · ${row.total_hours.toFixed(2)} hours`}
              checked={selected.includes(row.id)} disabled={busy || !!row.blocked_reason || !review.can_pay}
              onChange={event => { commandId.current = null; setSelected(event.target.checked ? [...selected, row.id] : selected.filter(id => id !== row.id)); }} />
            <span className="min-w-0 break-words"><span className="block font-semibold">{row.employee.name}</span>
              <span className="block text-neutral-600">{row.reason.replaceAll('_', ' ')} · {row.total_hours.toFixed(2)} hours</span>
              {row.adjustments.map(line => <span key={`${line.source_time_entry_id}:${line.line_key}`} className="mt-1 block text-neutral-700">
                {formatDate(line.original_work_date)} · {line.category?.name || 'Hours'} · {line.regular_hours.toFixed(2)} regular{line.overtime_hours > 0 ? ` + ${line.overtime_hours.toFixed(2)} overtime` : ''} · {line.payroll_rate == null ? 'Rate setup needed' : `${formatCurrency(line.payroll_rate)}/hr`}
              </span>)}
              {row.blocked_reason && <span className="mt-1 block text-danger-800">{row.blocked_reason}</span>}
            </span>
          </label>)}
          {!!review.cases.length && <><label className="block text-sm font-semibold">Pay date<input type="date" value={payDate} disabled={busy} onChange={event => { commandId.current = null; setPayDate(event.target.value); }} className="mt-1 block min-h-11 w-full rounded-lg border border-neutral-300 px-3 text-base" /></label>
            <p className="text-sm text-neutral-700">{total.toFixed(2)} hours selected. Payroll captures the displayed earning rates when the adjustment is created.</p></>}
        </div>}
        <DialogFooter><Button type="button" variant="outline" disabled={busy} onClick={() => setOpen(false)}>Close</Button>
          {!review && !busy && <Button type="button" onClick={() => void load()}>Try again</Button>}
          {!!review?.cases.length && <Button type="button" disabled={busy || !review.can_pay || !selected.length || !payDate} onClick={() => void submit()}>{busy ? 'Creating adjustment…' : 'Create adjustment run'}</Button>}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </>;
}
