import { useCallback, useEffect, useRef, useState } from 'react';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { payPeriodsApi, type CorrectedHoursPreview } from '@/services/api';
import { useCompany } from '@/contexts/CompanyContext';
import type { PayPeriod } from '@/types';

/** Records ownership of existing corrected work; never calculates or pays it. */
export function FinancialCorrectionSourcePanel({ payPeriod, onConnectionConfirmed }: { payPeriod: PayPeriod; onConnectionConfirmed?: () => void | Promise<void> }) {
  const { activeCompanyId } = useCompany();
  const contextMatches = activeCompanyId === payPeriod.company_id;
  const [data, setData] = useState<CorrectedHoursPreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const generation = useRef(0);
  const invalidateRequests = useCallback(() => { generation.current++; }, []);

  useEffect(() => {
    const current = ++generation.current;
    setData(null); setError(null); setOpen(false); setBusy(false);
    if (!contextMatches || payPeriod.status !== 'committed') return invalidateRequests;
    setBusy(true);
    void payPeriodsApi.correctedHours(payPeriod.id).then(response => {
      if (generation.current === current) setData(response.corrected_hours);
    }).catch(reason => {
      if (generation.current === current) setError(reason instanceof Error ? reason.message : 'Corrected hours could not be checked.');
    }).finally(() => { if (generation.current === current) setBusy(false); });
    return invalidateRequests;
  }, [payPeriod.id, payPeriod.company_id, payPeriod.status, contextMatches, invalidateRequests]);

  const refresh = async () => {
    if (busy || !contextMatches) return;
    const current = generation.current;
    setBusy(true); setError(null);
    try {
      const response = await payPeriodsApi.correctedHours(payPeriod.id);
      if (current === generation.current) {
        setData(response.corrected_hours);
        if (response.corrected_hours.status === 'confirmed') await onConnectionConfirmed?.();
      }
    } catch (reason) {
      if (current === generation.current) setError(reason instanceof Error ? reason.message : 'Refresh failed.');
    } finally {
      if (current === generation.current) setBusy(false);
    }
  };
  const confirm = async () => {
    if (busy || !contextMatches || !data?.expected_digest) return;
    const current = generation.current;
    setBusy(true); setError(null);
    try {
      const response = await payPeriodsApi.connectCorrectedHours(payPeriod.id, data.expected_digest);
      if (current === generation.current) {
        setData(response.corrected_hours); setOpen(false);
        if (response.corrected_hours.status === 'confirmed') await onConnectionConfirmed?.();
      }
    } catch (reason) {
      if (current === generation.current) setError(reason instanceof Error ? reason.message : 'The corrected hours could not be connected.');
    } finally {
      if (current === generation.current) setBusy(false);
    }
  };

  if (!contextMatches || payPeriod.status !== 'committed') return null;
  return <section aria-label="Corrected Source hours" className="rounded-xl border border-slate-200 bg-white p-4">
    <h3 className="font-semibold">Corrected hours</h3>
    <p className="mt-2 text-sm">{data?.status === 'confirmed' ? 'The time source confirmed these corrected hours.' : data?.status === 'pending' ? 'Waiting for the time source to confirm. Payment stays on hold.' : data?.status === 'failed' ? 'The time source did not confirm this connection. Retry the saved connection; payment stays on hold.' : 'Connect this corrected payroll to its original time records before preparing payment.'}</p>
    {(error || data?.error) && <p role="alert" className="mt-2 text-sm text-red-700">{error || data?.error}</p>}
    <div className="mt-3 flex flex-wrap gap-2">
      {data?.required && (data.status === 'needs_connection' || data.status === 'failed') && data.expected_digest && <Button className="min-h-11" disabled={busy} onClick={() => setOpen(true)}>{data.status === 'failed' ? 'Retry connection' : 'Connect corrected hours'}</Button>}
      <Button variant="outline" className="min-h-11" disabled={busy} onClick={() => void refresh()}>Refresh connection</Button>
    </div>
    <Dialog open={open} dismissOnEscape={!busy} onOpenChange={value => { if (!busy) setOpen(value); }}>
      <DialogContent className="dialog-center-mobile">
        <DialogHeader><DialogTitle>Connect corrected hours</DialogTitle><DialogDescription>The amounts and check reference will not change. This records which corrected payroll covers the same work.</DialogDescription></DialogHeader>
        <ul className="my-4 space-y-3">{data?.items.map(item => <li key={item.payroll_item_id} className="rounded-lg border p-3 text-sm">
          <p className="font-semibold">{item.employee_name}</p><p>Original run {item.original_pay_period_id} → Corrected run {item.corrected_pay_period_id}</p>
          <p>Work {item.work_start} to {item.work_end} · REG {item.regular_hours}h · OT {item.overtime_hours}h</p>
        </li>)}</ul>
        {error && <p role="alert" className="mb-3 text-sm text-red-700">{error}</p>}
        <DialogFooter><Button variant="outline" className="min-h-11" disabled={busy} onClick={() => setOpen(false)}>Keep reviewing</Button><Button className="min-h-11" disabled={busy || !data?.expected_digest} onClick={() => void confirm()}>{busy ? 'Connecting…' : 'Confirm connection'}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  </section>;
}
