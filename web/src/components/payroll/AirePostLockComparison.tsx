import { useCallback, useEffect, useRef, useState } from 'react';
import { RefreshCw } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { formatDate, formatGuamDateTime } from '@/lib/utils';
import { payPeriodsApi } from '@/services/api';
import type { AirePostLockComparison as Comparison, AirePostLockStatus } from '@/types';

const labels: Record<AirePostLockStatus, string> = {
  paid: 'Paid · confirmed',
  awaiting_payment: 'Linked · payment not confirmed',
  owed: 'AIRE unallocated at cutoff',
  held: 'Held · not payable yet',
  correction: 'Correction to review',
  mismatch: 'Identity mismatch · review',
};

const tones: Record<AirePostLockStatus, 'success' | 'warning' | 'danger'> = {
  paid: 'success',
  awaiting_payment: 'warning',
  owed: 'warning',
  held: 'warning',
  correction: 'danger',
  mismatch: 'danger',
};

const hours = (value: number) => Number(value || 0).toFixed(2);

export function AirePostLockComparison({ payPeriodId }: { payPeriodId: number }) {
  const [comparison, setComparison] = useState<Comparison | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const requestGeneration = useRef(0);

  const load = useCallback(async () => {
    const generation = ++requestGeneration.current;
    setLoading(true);
    setError(null);
    try {
      const response = await payPeriodsApi.airePostLockComparison(payPeriodId);
      if (generation === requestGeneration.current) setComparison(response.comparison);
    } catch (caught) {
      if (generation === requestGeneration.current) {
        setError(caught instanceof Error ? caught.message : 'Could not compare the final AIRE cutoff');
      }
    } finally {
      if (generation === requestGeneration.current) setLoading(false);
    }
  }, [payPeriodId]);

  useEffect(() => {
    void load();
    return () => { requestGeneration.current += 1; };
  }, [load]);

  return <Card className="overflow-hidden border-primary-200">
    <CardContent className="p-0">
      <div className="flex flex-wrap items-start justify-between gap-4 border-b border-neutral-200 bg-neutral-950 px-6 py-5 text-white">
        <div>
          <h3 className="font-display text-lg font-bold">Final AIRE cutoff vs. payroll payments</h3>
          <p className="mt-1 max-w-3xl text-sm text-neutral-300">AIRE’s final batch already excludes hours linked to payroll at cutoff. Its unallocated lines are an as-of-cutoff snapshot; confirmed payments are shown separately and may have changed since then. Review later allocations before deciding what remains owed now.</p>
        </div>
        <Button type="button" size="sm" variant="outline" disabled={loading} onClick={() => void load()}>
          <RefreshCw className={`mr-2 h-4 w-4 ${loading ? 'animate-spin' : ''}`} />Refresh comparison
        </Button>
      </div>
      {loading && !comparison && <p className="px-6 py-6 text-sm text-neutral-600">Comparing verified AIRE hours with payroll payment evidence…</p>}
      {error && <p role="alert" className="px-6 py-5 text-sm text-danger-800">{error} No final comparison is being shown until the verified source can be checked.</p>}
      {comparison && !error && <>
        <p className="px-6 pt-5 text-xs text-neutral-500">Verified cutoff {formatGuamDateTime(comparison.cutoff_at)} · batch {comparison.batch_id}</p>
        <div className="grid gap-3 px-6 py-5 sm:grid-cols-2 xl:grid-cols-3">
          {(['paid', 'awaiting_payment', 'owed', 'held', 'correction', 'mismatch'] as const).map((status) => {
            const total = comparison.summary[status];
            return <div key={status} className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
              <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{labels[status]}</p>
              <p className="mt-2 font-display text-xl font-bold text-neutral-950">{hours(total.regular_hours + total.overtime_hours)} hrs</p>
              <p className="mt-1 text-xs text-neutral-600">{hours(total.regular_hours)} regular · {hours(total.overtime_hours)} OT · {total.entry_count} lines</p>
            </div>;
          })}
        </div>
        {comparison.summary.unmapped_count > 0 && <p className="mx-6 mb-4 rounded-lg border border-warning-200 bg-warning-50 px-4 py-3 text-sm text-warning-900">{comparison.summary.unmapped_count} final AIRE lines have no active Cornerstone employee match. Review the employee identity before processing them.</p>}
        {Boolean(comparison.summary.needs_verification_count) && <p className="mx-6 mb-4 rounded-lg border border-warning-200 bg-warning-50 px-4 py-3 text-sm text-warning-900">{comparison.summary.needs_verification_count} final AIRE lines have older numeric-only employee links. Verify their permanent identity in the Team tab before importing future hours.</p>}
        <div className="border-t border-neutral-200 px-6 py-5">
          <h4 className="font-semibold text-neutral-950">Exact source lines</h4>
          <p className="mt-1 text-sm text-neutral-600">Unallocated and held lines are not new checks by themselves. AIRE subtracts linked payroll hours before creating the final batch, so these categories are not additive. Resolve approvals, later payment evidence, and corrections before routing hours into another run.</p>
          <div className="mt-4 max-h-96 overflow-auto rounded-xl border border-neutral-200">
            <table className="w-full min-w-[760px] text-left text-sm">
              <thead className="sticky top-0 bg-neutral-100 text-xs uppercase tracking-wide text-neutral-600"><tr><th className="px-4 py-3">Employee</th><th className="px-4 py-3">Work date / source</th><th className="px-4 py-3">Status</th><th className="px-4 py-3">Regular</th><th className="px-4 py-3">OT</th></tr></thead>
              <tbody className="divide-y divide-neutral-100">
                {comparison.rows.map((row, index) => <tr key={`${row.status}-${row.source_time_entry_id}-${row.payroll_item_id || index}`}>
                  <td className="px-4 py-3 font-medium text-neutral-950">{row.employee_name}{row.mapping_status === 'unmapped' && <span className="block text-xs text-warning-800">Employee match needed</span>}{row.mapping_status === 'needs_verification' && <span className="block text-xs text-warning-800">Permanent AIRE link needs verification</span>}</td>
                  <td className="px-4 py-3 text-neutral-700">{formatDate(row.work_date)}<span className="block text-xs text-neutral-500">AIRE entry {row.source_time_entry_id} · {row.source_kind.replaceAll('_', ' ')}{row.payment_reference ? ` · payment ${row.payment_reference}` : ''}</span></td>
                  <td className="px-4 py-3"><Badge variant={tones[row.status]}>{labels[row.status]}</Badge>{row.reason && <span className="mt-1 block text-xs text-neutral-500">{row.reason.replaceAll('_', ' ')}</span>}</td>
                  <td className="px-4 py-3 tabular-nums">{hours(row.regular_hours)}</td><td className="px-4 py-3 tabular-nums">{hours(row.overtime_hours)}</td>
                </tr>)}
                {comparison.rows.length === 0 && <tr><td colSpan={5} className="px-4 py-8 text-center text-neutral-600">No payable, held, or linked hours in this verified cutoff.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      </>}
    </CardContent>
  </Card>;
}
