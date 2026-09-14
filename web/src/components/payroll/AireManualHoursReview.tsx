import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AlertTriangle, CheckCircle2, Loader2, RefreshCw } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { formatDate, formatDateRange } from '@/lib/utils';
import { payPeriodsApi } from '@/services/api';
import type { AirePayrollManualReview, PayPeriodStatus } from '@/types';

type PayrollHours = Record<string, { regular: number; overtime: number }>;

type Props = {
  payPeriodId: number;
  payPeriodStatus: PayPeriodStatus;
  payrollHours: PayrollHours;
  aireRecordLinked: boolean;
};

const hours = (value: number) => Number(value || 0).toFixed(2);
const closeEnough = (left: number, right: number) => Math.abs(left - right) < 0.05;

const exclusionLabel = (reason: string) => ({
  pending_approval: 'approval needed',
  approved_after_cutoff: 'approved after cutoff',
  created_after_cutoff: 'submitted after cutoff',
  open_clock: 'missing clock-out',
  pending_overtime: 'overtime approval needed',
  overtime_approved_after_cutoff: 'overtime approved after cutoff',
  denied_approval: 'time denied',
  denied_overtime: 'overtime denied',
}[reason] || reason.replaceAll('_', ' '));

export function AireManualHoursReview({ payPeriodId, payPeriodStatus, payrollHours, aireRecordLinked }: Props) {
  const [review, setReview] = useState<AirePayrollManualReview | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const requestGeneration = useRef(0);

  const load = useCallback(async () => {
    const generation = ++requestGeneration.current;
    setLoading(true);
    setError(null);
    try {
      const result = await payPeriodsApi.airePayrollManualReview(payPeriodId);
      if (generation === requestGeneration.current) setReview(result);
    } catch (caught) {
      if (generation === requestGeneration.current) {
        setError(caught instanceof Error ? caught.message : 'Could not compare AIRE and Payroll hours');
      }
    } finally {
      if (generation === requestGeneration.current) setLoading(false);
    }
  }, [payPeriodId]);

  useEffect(() => {
    setReview(null);
    void load();
    return () => { requestGeneration.current += 1; };
  }, [load]);

  const rows = useMemo(() => (review?.employees || []).map((employee) => {
    const employeeId = employee.cornerstone.employee_id;
    const entered = employeeId ? payrollHours[String(employeeId)] : undefined;
    const payrollRegular = Number(entered?.regular || 0);
    const payrollOvertime = Number(entered?.overtime || 0);
    const carryover = employee.adjustments
      .filter((adjustment) => adjustment.source_kind === 'carryover')
      .reduce((sum, adjustment) => sum + Number(adjustment.total_hours), 0);
    const corrections = employee.adjustments
      .filter((adjustment) => adjustment.source_kind === 'correction')
      .reduce((sum, adjustment) => sum + Number(adjustment.total_hours), 0);
    const categories = [...new Set(employee.adjustments.map((adjustment) => adjustment.category?.name).filter(Boolean))] as string[];
    const matched = employee.cornerstone.status === 'mapped'
      && closeEnough(payrollRegular, Number(employee.regular_hours))
      && closeEnough(payrollOvertime, Number(employee.overtime_hours));

    return { employee, payrollRegular, payrollOvertime, carryover, corrections, categories, matched };
  }), [payrollHours, review?.employees]);

  const matchedCount = rows.filter((row) => row.matched).length;
  const mismatchCount = rows.length - matchedCount;
  const blockers = Number(review?.summary.exclusion_count || 0) + Number(review?.issues.missing_category_count || 0);
  const isCommitted = payPeriodStatus === 'committed';

  return (
    <Card className="overflow-hidden border-primary-200">
      <CardContent className="p-0">
        <div className="flex flex-col gap-4 border-b border-primary-100 bg-primary-50/60 px-5 py-5 sm:px-6 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <h3 className="font-display text-lg font-bold text-neutral-950">Manual AIRE hours check</h3>
              <Badge variant="info">Live from AIRE</Badge>
            </div>
            <p className="mt-1 max-w-3xl text-sm leading-6 text-neutral-700">
              Use this before Calculate Payroll when you type hours into Payroll yourself. It includes payable carryover and shows the exact regular and overtime totals to enter.
            </p>
          </div>
          <Button type="button" size="sm" variant="outline" onClick={() => void load()} disabled={loading}>
            {loading ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : <RefreshCw className="mr-2 h-4 w-4" />}
            Refresh check
          </Button>
        </div>

        {loading && !review ? (
          <div className="flex items-center justify-center gap-3 px-6 py-10 text-sm text-neutral-600">
            <Loader2 className="h-5 w-5 animate-spin text-primary-700" /> Comparing AIRE with the hours entered in Payroll…
          </div>
        ) : error ? (
          <div role="alert" className="flex items-start gap-3 px-5 py-5 text-sm text-danger-800 sm:px-6">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
            <div><p className="font-semibold">The manual check could not load.</p><p className="mt-1 leading-5">{error} You can still process payroll manually; verify the hours in AIRE before approving.</p></div>
          </div>
        ) : review && (
          <>
            <div className="grid gap-3 border-b border-neutral-200 bg-white p-4 sm:grid-cols-3 sm:p-6">
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">AIRE payable</p>
                <p className="mt-2 font-display text-xl font-bold text-neutral-950">{hours(review.summary.total_hours)} hrs</p>
                <p className="mt-1 text-xs text-neutral-600">{hours(review.summary.regular_hours)} regular · {hours(review.summary.overtime_hours)} OT</p>
              </div>
              <div className={`rounded-xl border p-4 ${mismatchCount ? 'border-warning-200 bg-warning-50' : 'border-success-200 bg-success-50'}`}>
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Payroll match</p>
                <p className="mt-2 font-display text-xl font-bold text-neutral-950">{matchedCount}/{rows.length} employees</p>
                <p className="mt-1 text-xs text-neutral-600">{mismatchCount ? `${mismatchCount} need an hours update below` : 'Regular and OT totals match'}</p>
              </div>
              <div className={`rounded-xl border p-4 ${blockers ? 'border-warning-200 bg-warning-50' : 'border-neutral-200 bg-neutral-50'}`}>
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Not payable yet</p>
                <p className="mt-2 font-display text-xl font-bold text-neutral-950">{blockers}</p>
                <p className="mt-1 text-xs text-neutral-600">Resolve in AIRE, then refresh before approval</p>
              </div>
            </div>

            <div className="divide-y divide-neutral-100 lg:hidden">
              {rows.map(({ employee, payrollRegular, payrollOvertime, carryover, corrections, categories, matched }) => (
                <article key={`compact-${employee.source_user_id}`} className={`px-5 py-5 sm:px-6 ${matched ? 'bg-white' : 'bg-warning-50/40'}`}>
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <p className="font-semibold text-neutral-950">{employee.cornerstone.employee_name || employee.display_name}</p>
                      <div className="mt-1 flex flex-wrap gap-1.5">
                        {categories.map((category) => <Badge key={category} variant="default">{category}</Badge>)}
                        {employee.cornerstone.status !== 'mapped' && <Badge variant="danger">Not mapped</Badge>}
                      </div>
                    </div>
                    {matched ? <Badge variant="success"><CheckCircle2 className="mr-1 h-3.5 w-3.5" /> Matches</Badge> : <Badge variant="warning"><AlertTriangle className="mr-1 h-3.5 w-3.5" /> Update</Badge>}
                  </div>
                  <div className="mt-4 grid gap-3 sm:grid-cols-2">
                    <div className="rounded-lg border border-neutral-200 bg-white p-3">
                      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">AIRE says to pay</p>
                      <p className="mt-1 font-semibold text-neutral-950">{hours(employee.regular_hours)} regular · {hours(employee.overtime_hours)} OT</p>
                      {carryover !== 0 && <p className="mt-1 text-xs font-semibold text-primary-800">Includes {hours(carryover)} carryover</p>}
                      {corrections !== 0 && <p className="mt-1 text-xs text-neutral-600">Includes {corrections > 0 ? '+' : ''}{hours(corrections)} correction</p>}
                    </div>
                    <div className="rounded-lg border border-neutral-200 bg-white p-3">
                      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Entered in Payroll</p>
                      <p className="mt-1 font-semibold text-neutral-950">{hours(payrollRegular)} regular · {hours(payrollOvertime)} OT</p>
                      {!matched && employee.cornerstone.status === 'mapped' && <p className="mt-1 text-xs text-warning-900">Change to {hours(employee.regular_hours)} regular and {hours(employee.overtime_hours)} OT below.</p>}
                    </div>
                  </div>
                </article>
              ))}
              {rows.length === 0 && <p className="px-6 py-8 text-center text-sm text-neutral-500">AIRE has no payable time for {formatDateRange(review.start_date, review.end_date)}.</p>}
            </div>

            <div className="hidden overflow-x-auto lg:block">
              <table className="w-full min-w-[760px] text-left text-sm">
                <thead className="border-b border-neutral-200 bg-neutral-50 text-xs uppercase tracking-wide text-neutral-500">
                  <tr><th className="px-5 py-3 font-semibold sm:px-6">Employee</th><th className="px-4 py-3 font-semibold">AIRE says to pay</th><th className="px-4 py-3 font-semibold">Entered in Payroll</th><th className="px-5 py-3 font-semibold sm:px-6">Result</th></tr>
                </thead>
                <tbody className="divide-y divide-neutral-100">
                  {rows.map(({ employee, payrollRegular, payrollOvertime, carryover, corrections, categories, matched }) => (
                    <tr key={employee.source_user_id} className={matched ? 'bg-white' : 'bg-warning-50/40'}>
                      <td className="px-5 py-4 align-top sm:px-6">
                        <p className="font-semibold text-neutral-950">{employee.cornerstone.employee_name || employee.display_name}</p>
                        <div className="mt-1 flex flex-wrap gap-1.5">
                          {categories.map((category) => <Badge key={category} variant="default">{category}</Badge>)}
                          {employee.cornerstone.status !== 'mapped' && <Badge variant="danger">Not mapped</Badge>}
                        </div>
                      </td>
                      <td className="px-4 py-4 align-top">
                        <p className="font-semibold text-neutral-950">{hours(employee.regular_hours)} regular · {hours(employee.overtime_hours)} OT</p>
                        {carryover !== 0 && <p className="mt-1 text-xs font-semibold text-primary-800">Includes {hours(carryover)} carryover</p>}
                        {corrections !== 0 && <p className="mt-1 text-xs text-neutral-600">Includes {corrections > 0 ? '+' : ''}{hours(corrections)} correction</p>}
                      </td>
                      <td className="px-4 py-4 align-top">
                        <p className="font-semibold text-neutral-950">{hours(payrollRegular)} regular · {hours(payrollOvertime)} OT</p>
                        {!matched && employee.cornerstone.status === 'mapped' && (
                          <p className="mt-1 text-xs text-warning-900">Enter {hours(employee.regular_hours)} regular and {hours(employee.overtime_hours)} OT in the payroll table.</p>
                        )}
                      </td>
                      <td className="px-5 py-4 align-top sm:px-6">
                        {matched ? <Badge variant="success"><CheckCircle2 className="mr-1 h-3.5 w-3.5" /> Matches</Badge> : <Badge variant="warning"><AlertTriangle className="mr-1 h-3.5 w-3.5" /> Update needed</Badge>}
                      </td>
                    </tr>
                  ))}
                  {rows.length === 0 && <tr><td colSpan={4} className="px-6 py-8 text-center text-neutral-500">AIRE has no payable time for {formatDateRange(review.start_date, review.end_date)}.</td></tr>}
                </tbody>
              </table>
            </div>

            {review.exclusions.length > 0 && (
              <div className="border-t border-warning-200 bg-warning-50/60 px-5 py-5 sm:px-6">
                <h4 className="font-semibold text-neutral-950">Do not enter these hours yet</h4>
                <p className="mt-1 text-sm text-neutral-600">They are excluded from the payable totals above. Fix them in AIRE, then select Refresh check.</p>
                <div className="mt-3 grid gap-2 sm:grid-cols-2">
                  {review.exclusions.map((exclusion) => (
                    <div key={`${exclusion.source_time_entry_id}-${exclusion.reason}`} className="rounded-lg border border-warning-200 bg-white p-3 text-sm">
                      <p className="font-semibold text-neutral-950">{exclusion.cornerstone.employee_name || exclusion.display_name} · {hours(exclusion.held_total_hours)} hrs</p>
                      <p className="mt-1 text-xs text-neutral-600">{formatDate(exclusion.original_work_date)} · {exclusionLabel(exclusion.reason)}</p>
                    </div>
                  ))}
                </div>
              </div>
            )}

            <div className="border-t border-neutral-200 bg-neutral-950 px-5 py-5 text-sm text-neutral-200 sm:px-6">
              <p className="font-semibold text-white">Finish the manual workflow</p>
              <ol className="mt-2 grid gap-2 leading-5 md:grid-cols-4">
                <li><span className="font-semibold text-white">1.</span> Make every employee match.</li>
                <li><span className="font-semibold text-white">2.</span> Calculate, approve, then commit.</li>
                <li><span className="font-semibold text-white">3.</span> Link the finalized AIRE record.</li>
                <li><span className="font-semibold text-white">4.</span> Print checks, then Record Issued.</li>
              </ol>
              <p className="mt-3 text-xs leading-5 text-neutral-300">
                {isCommitted
                  ? aireRecordLinked
                    ? 'AIRE is linked. Recording each check as issued automatically marks its linked hours paid in AIRE.'
                    : 'This run is committed. Use Link AIRE Record in Payroll actions before recording the checks as issued.'
                  : 'After the AIRE record is linked, Payroll automatically updates AIRE when a check is recorded as issued—there is no separate “mark paid” step in AIRE.'}
              </p>
            </div>
          </>
        )}
      </CardContent>
    </Card>
  );
}
