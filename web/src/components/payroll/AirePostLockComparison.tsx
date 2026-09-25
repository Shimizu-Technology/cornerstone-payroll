import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { RefreshCw } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { formatDate, formatGuamDateTime } from '@/lib/utils';
import { payPeriodsApi } from '@/services/api';
import { summarizeEmployees, sumHours } from './airePaymentSummary';
import type { AirePostLockComparison as Comparison, AirePostLockStatus } from '@/types';

const labels: Record<AirePostLockStatus, string> = {
  paid: 'Paid',
  awaiting_payment: 'Payment pending',
  owed: 'Unpaid at cutoff',
  held: 'Held',
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

  const employees = useMemo(() => summarizeEmployees(comparison?.rows || []), [comparison]);
  const totals = employees.reduce((result, employee) => ({
    owed: result.owed + sumHours(employee.owed), awaiting: result.awaiting + sumHours(employee.awaiting),
    paid: result.paid + sumHours(employee.paid), held: result.held + sumHours(employee.held),
  }), { owed: 0, awaiting: 0, paid: 0, held: 0 });

  return <Card className="overflow-hidden border-neutral-200">
    <CardContent className="p-0">
      <div className="flex flex-wrap items-start justify-between gap-4 px-5 py-5 sm:px-6">
        <div>
          <h3 className="font-display text-lg font-bold text-neutral-950">AIRE hours and payments</h3>
          <p className="mt-1 text-sm text-neutral-600">Who still needs payment, what is held, and what has been paid.</p>
        </div>
        <Button type="button" size="sm" variant="outline" disabled={loading} onClick={() => void load()}>
          <RefreshCw className={`mr-2 h-4 w-4 ${loading ? 'animate-spin' : ''}`} aria-hidden="true" />Refresh AIRE status
        </Button>
      </div>
      {loading && !comparison && <p className="border-t border-neutral-200 px-6 py-6 text-sm text-neutral-600">Checking AIRE hours and payment evidence…</p>}
      {error && <p role="alert" className="border-t border-danger-200 bg-danger-50 px-6 py-5 text-sm text-danger-800">{error} Current AIRE payment status is unavailable.</p>}
      {comparison && !error && <>
        <div className="grid border-y border-neutral-200 bg-neutral-50/70 sm:grid-cols-3 sm:divide-x sm:divide-neutral-200" aria-live="polite">
          {([
            ['Still to pay', totals.owed, 'Approved hours not linked to a paycheck'],
            ['Payment pending', totals.awaiting, 'Linked to payroll; payment not confirmed'],
            ['Paid', totals.paid, 'Check issued or bank payment confirmed'],
          ] as const).map(([label, value, detail]) => <div key={label} className="px-5 py-4 sm:px-6">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{label}</p>
            <p className="mt-1 font-display text-2xl font-bold tabular-nums text-neutral-950">{hours(value)} hrs</p>
            <p className="mt-1 text-xs text-neutral-600">{detail}</p>
          </div>)}
        </div>
        {totals.held > 0 && <p className="border-b border-warning-200 bg-warning-50 px-5 py-3 text-sm text-warning-950 sm:px-6"><strong>{hours(totals.held)} hrs held.</strong> These hours are excluded from payment until the issue shown below is resolved in AIRE.</p>}
        <div className="divide-y divide-neutral-200">
          {employees.map((employee) => <div key={employee.key} className="px-5 py-5 sm:px-6">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div><h4 className="font-semibold text-neutral-950">{employee.name}</h4><p className="mt-1 text-sm text-neutral-600">{sumHours(employee.owed) > 0 ? `${hours(sumHours(employee.owed))} hrs to pay` : sumHours(employee.awaiting) > 0 ? `${hours(sumHours(employee.awaiting))} hrs awaiting payment` : sumHours(employee.paid) > 0 ? 'Payable hours paid' : 'No payable hours'}{sumHours(employee.held) > 0 && ` · ${hours(sumHours(employee.held))} hrs held`}</p></div>
              {sumHours(employee.paid) > 0 && <Badge variant="success">{hours(sumHours(employee.paid))} hrs paid</Badge>}
            </div>
            <div className="mt-4 grid gap-2 text-sm sm:grid-cols-2">
              {employee.remaining.map(({ row, regular, overtime }, index) => <div key={`owed-${row.source_time_entry_id}-${index}`} className="rounded-xl border border-warning-200 bg-warning-50/60 px-4 py-3"><p className="font-semibold text-neutral-950">Pay {hours(regular + overtime)} hrs · {formatDate(row.work_date)}</p><p className="mt-1 text-xs text-neutral-600">{hours(regular)} regular · {hours(overtime)} OT · {row.category_name || row.source_kind.replaceAll('_', ' ')}</p>{row.mapping_status && row.mapping_status !== 'mapped' && <p className="mt-1 text-xs text-warning-900">Check this employee’s AIRE match before paying.</p>}</div>)}
              {employee.payments.map((row, index) => <div key={`payment-${row.source_time_entry_id}-${index}`} className={`rounded-xl border px-4 py-3 ${row.status === 'paid' ? 'border-success-200 bg-success-50/60' : 'border-neutral-200 bg-neutral-50'}`}><p className="font-semibold text-neutral-950">{row.status === 'paid' ? 'Paid' : 'Payment pending'} · {hours(row.regular_hours + row.overtime_hours)} hrs</p><p className="mt-1 text-xs text-neutral-600">Worked {formatDate(row.work_date)} · {hours(row.regular_hours)} regular · {hours(row.overtime_hours)} OT{row.payment_reference ? ` · check/payment ${row.payment_reference}` : ''}{row.payment_date ? ` · paid ${formatDate(row.payment_date)}` : ''}</p>{row.reason && <p className="mt-1 text-xs text-warning-900">{row.reason}</p>}</div>)}
              {employee.heldRows.map((row, index) => <div key={`held-${row.source_time_entry_id}-${index}`} className="rounded-xl border border-warning-200 bg-white px-4 py-3"><p className="font-semibold text-neutral-950">Held · {hours(row.regular_hours + row.overtime_hours)} hrs</p><p className="mt-1 text-xs text-neutral-600">Worked {formatDate(row.work_date)} · {row.reason?.replaceAll('_', ' ') || 'Review in AIRE'}. Excluded from payable hours.</p></div>)}
              {employee.reviewRows.map((row, index) => <div key={`review-${row.source_time_entry_id}-${index}`} className="rounded-xl border border-danger-200 bg-danger-50/50 px-4 py-3"><p className="font-semibold text-neutral-950">{labels[row.status]} · {formatDate(row.work_date)}</p><p className="mt-1 text-xs text-neutral-600">{row.reason?.replaceAll('_', ' ') || 'Review the source line before payment.'}</p></div>)}
            </div>
          </div>)}
          {employees.length === 0 && <p className="px-6 py-6 text-sm text-neutral-600">No payable, held, or paid AIRE hours in this period.</p>}
        </div>
        <details className="border-t border-neutral-200 px-5 py-4 sm:px-6">
          <summary className="cursor-pointer text-sm font-semibold text-primary-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary-600">Cutoff and source details</summary>
          <p className="mt-4 text-sm text-neutral-600">AIRE’s verified cutoff was {formatGuamDateTime(comparison.cutoff_at)}. Its unallocated lines are a historical snapshot. Later payment links reduce the hours still to pay above; the original lines remain below for audit.</p>
          <p className="mt-1 text-xs text-neutral-500">Batch {comparison.batch_id}</p>
          <div className="mt-4 max-h-96 overflow-auto rounded-xl border border-neutral-200">
            <table className="w-full min-w-[760px] text-left text-sm">
              <thead className="sticky top-0 bg-neutral-100 text-xs uppercase tracking-wide text-neutral-600"><tr><th className="px-4 py-3">Employee</th><th className="px-4 py-3">Work date / source</th><th className="px-4 py-3">Cutoff or payment status</th><th className="px-4 py-3">Regular</th><th className="px-4 py-3">OT</th></tr></thead>
              <tbody className="divide-y divide-neutral-100">
                {comparison.rows.map((row, index) => <tr key={`${row.status}-${row.source_time_entry_id}-${row.payroll_item_id || index}`}>
                  <td className="px-4 py-3 font-medium text-neutral-950">{row.employee_name}{row.mapping_status === 'unmapped' && <span className="block text-xs text-warning-800">Employee match needed</span>}{row.mapping_status === 'needs_verification' && <span className="block text-xs text-warning-800">Permanent AIRE link needs verification</span>}</td>
                  <td className="px-4 py-3 text-neutral-700">{formatDate(row.work_date)}<span className="block text-xs text-neutral-500">AIRE entry {row.source_time_entry_id} · {row.category_name || row.source_kind.replaceAll('_', ' ')}{row.payment_reference ? ` · payment ${row.payment_reference}` : ''}</span></td>
                  <td className="px-4 py-3"><Badge variant={tones[row.status]}>{labels[row.status]}</Badge>{row.reason && <span className="mt-1 block text-xs text-neutral-500">{row.reason.replaceAll('_', ' ')}</span>}</td>
                  <td className="px-4 py-3 tabular-nums">{hours(row.regular_hours)}</td><td className="px-4 py-3 tabular-nums">{hours(row.overtime_hours)}</td>
                </tr>)}
                {comparison.rows.length === 0 && <tr><td colSpan={5} className="px-4 py-8 text-center text-neutral-600">No payable, held, or linked hours in this verified cutoff.</td></tr>}
              </tbody>
            </table>
          </div>
        </details>
      </>}
    </CardContent>
  </Card>;
}
