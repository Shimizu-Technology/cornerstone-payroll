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
const sameHundredth = (left: number, right: number) => Math.round(left * 100) === Math.round(right * 100);

const exclusionLabel = (reason: string) => ({
  pending_approval: 'approval needed',
  approved_after_cutoff: 'approved after cutoff',
  created_after_cutoff: 'submitted after cutoff',
  open_clock: 'missing clock-out',
  pending_overtime: 'overtime approval needed',
  overtime_approved_after_cutoff: 'overtime approved after cutoff',
  denied_approval: 'time denied',
  denied_overtime: 'overtime denied',
  payment_attested_pending_evidence: 'payment reported; check evidence pending',
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
        setError(caught instanceof Error ? caught.message : 'Could not compare time tracking and Payroll hours');
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
      && sameHundredth(payrollRegular, Number(employee.regular_hours))
      && sameHundredth(payrollOvertime, Number(employee.overtime_hours));

    return { employee, payrollRegular, payrollOvertime, carryover, corrections, categories, matched };
  }), [payrollHours, review?.employees]);

  const matchedCount = rows.filter((row) => row.matched).length;
  const mismatchCount = rows.length - matchedCount;
  const attentionCount = Number(review?.summary.exclusion_count || 0)
    + Number(review?.issues.missing_category_count || 0)
    + Number(review?.issues.negative_adjustment_count || 0);
  const isCommitted = payPeriodStatus === 'committed';

  return (
    <Card className="overflow-hidden border-primary-200">
      <CardContent className="p-0">
        <div className="flex flex-col gap-4 border-b border-primary-100 bg-primary-50/60 px-6 py-6 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <h3 className="font-display text-lg font-bold text-neutral-950">Live time tracking readiness</h3>
              <Badge variant="info">Before cutoff</Badge>
            </div>
            <p className="mt-2 max-w-3xl text-sm leading-6 text-neutral-700">
              Review current hours, mappings, carryover, and held entries before cutoff. After time tracking locks the period, this area switches to the verified batch that can be added to payroll.
            </p>
          </div>
          <Button type="button" size="sm" variant="outline" onClick={() => void load()} disabled={loading}>
            {loading ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : <RefreshCw className="mr-2 h-4 w-4" />}
            Refresh check
          </Button>
        </div>

        {loading && !review ? (
          <div className="flex items-center justify-center gap-4 px-6 py-10 text-sm text-neutral-600">
            <Loader2 className="h-5 w-5 animate-spin text-primary-700" /> Comparing time tracking with the hours entered in Payroll…
          </div>
        ) : error ? (
          <div role="alert" className="flex items-start gap-4 px-6 py-6 text-sm text-danger-800">
            <AlertTriangle className="h-4 w-4 shrink-0" />
            <div><p className="font-semibold">The live time tracking preview could not load.</p><p className="mt-2 leading-5">{error} Refresh before using time tracking hours for payroll.</p></div>
          </div>
        ) : review && (
          <>
            <div className="grid gap-4 border-b border-neutral-200 bg-white p-4 sm:grid-cols-3 sm:p-6">
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Time tracking payable now</p>
                <p className="mt-2 font-display text-xl font-bold text-neutral-950">{hours(review.summary.total_hours)} hrs</p>
                <p className="mt-2 text-xs text-neutral-600">{hours(review.summary.regular_hours)} regular · {hours(review.summary.overtime_hours)} OT</p>
              </div>
              <div className={`rounded-xl border p-4 ${mismatchCount ? 'border-warning-200 bg-warning-50' : 'border-success-200 bg-success-50'}`}>
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Current payroll entries</p>
                <p className="mt-2 font-display text-xl font-bold text-neutral-950">{matchedCount}/{rows.length} employees</p>
                <p className="mt-2 text-xs text-neutral-600">{mismatchCount ? `${mismatchCount} differ from this live preview` : 'Regular and OT totals match'}</p>
              </div>
              <div className={`rounded-xl border p-4 ${attentionCount ? 'border-warning-200 bg-warning-50' : 'border-neutral-200 bg-neutral-50'}`}>
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Needs attention</p>
                <p className="mt-2 font-display text-xl font-bold text-neutral-950">{attentionCount}</p>
                <p className="mt-2 text-xs text-neutral-600">Review exclusions, categories, and negative corrections</p>
              </div>
            </div>

            <div className="divide-y divide-neutral-100 lg:hidden">
              {rows.map(({ employee, payrollRegular, payrollOvertime, carryover, corrections, categories, matched }) => (
                <article key={`compact-${employee.source_user_id}`} className={`px-6 py-6 ${matched ? 'bg-white' : 'bg-warning-50/40'}`}>
                  <div className="flex items-start justify-between gap-4">
                    <div>
                      <p className="font-semibold text-neutral-950">{employee.cornerstone.employee_name || employee.display_name}</p>
                      <div className="mt-2 flex flex-wrap gap-2">
                        {categories.map((category) => <Badge key={category} variant="default">{category}</Badge>)}
                        {employee.cornerstone.status !== 'mapped' && <Badge variant="danger">Not mapped</Badge>}
                      </div>
                    </div>
                    {matched ? <Badge variant="success"><CheckCircle2 className="mr-2 h-3.5 w-3.5" /> Matches</Badge> : <Badge variant="warning"><AlertTriangle className="mr-2 h-3.5 w-3.5" /> Update</Badge>}
                  </div>
                  <div className="mt-4 grid gap-4 sm:grid-cols-2">
                    <div className="rounded-lg border border-neutral-200 bg-white p-4">
                      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Time tracking currently shows</p>
                      <p className="mt-2 font-semibold text-neutral-950">{hours(employee.regular_hours)} regular · {hours(employee.overtime_hours)} OT</p>
                      {carryover !== 0 && <p className="mt-2 text-xs font-semibold text-primary-800">Includes {hours(carryover)} carryover</p>}
                      {corrections !== 0 && <p className="mt-2 text-xs text-neutral-600">Includes {corrections > 0 ? '+' : ''}{hours(corrections)} correction</p>}
                    </div>
                    <div className="rounded-lg border border-neutral-200 bg-white p-4">
                      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Entered in Payroll</p>
                      <p className="mt-2 font-semibold text-neutral-950">{hours(payrollRegular)} regular · {hours(payrollOvertime)} OT</p>
                      {!matched && employee.cornerstone.status === 'mapped' && <p className="mt-2 text-xs text-warning-900">The verified batch will replace manual entry after cutoff.</p>}
                    </div>
                  </div>
                </article>
              ))}
              {rows.length === 0 && <p className="px-6 py-8 text-center text-sm text-neutral-500">Time tracking has no payable time for {formatDateRange(review.start_date, review.end_date)}.</p>}
            </div>

            <div className="hidden overflow-x-auto lg:block">
              <table className="w-full min-w-[760px] text-left text-sm">
                <thead className="border-b border-neutral-200 bg-neutral-50 text-xs uppercase tracking-wide text-neutral-500">
                  <tr><th className="px-6 py-4 font-semibold">Employee</th><th className="px-4 py-4 font-semibold">Time tracking currently shows</th><th className="px-4 py-4 font-semibold">Entered in Payroll</th><th className="px-6 py-4 font-semibold">Result</th></tr>
                </thead>
                <tbody className="divide-y divide-neutral-100">
                  {rows.map(({ employee, payrollRegular, payrollOvertime, carryover, corrections, categories, matched }) => (
                    <tr key={employee.source_user_id} className={matched ? 'bg-white' : 'bg-warning-50/40'}>
                      <td className="px-6 py-4 align-top">
                        <p className="font-semibold text-neutral-950">{employee.cornerstone.employee_name || employee.display_name}</p>
                        <div className="mt-2 flex flex-wrap gap-2">
                          {categories.map((category) => <Badge key={category} variant="default">{category}</Badge>)}
                          {employee.cornerstone.status !== 'mapped' && <Badge variant="danger">Not mapped</Badge>}
                        </div>
                      </td>
                      <td className="px-4 py-4 align-top">
                        <p className="font-semibold text-neutral-950">{hours(employee.regular_hours)} regular · {hours(employee.overtime_hours)} OT</p>
                        {carryover !== 0 && <p className="mt-2 text-xs font-semibold text-primary-800">Includes {hours(carryover)} carryover</p>}
                        {corrections !== 0 && <p className="mt-2 text-xs text-neutral-600">Includes {corrections > 0 ? '+' : ''}{hours(corrections)} correction</p>}
                      </td>
                      <td className="px-4 py-4 align-top">
                        <p className="font-semibold text-neutral-950">{hours(payrollRegular)} regular · {hours(payrollOvertime)} OT</p>
                        {!matched && employee.cornerstone.status === 'mapped' && (
                          <p className="mt-2 text-xs text-warning-900">The verified batch will replace manual entry after cutoff.</p>
                        )}
                      </td>
                      <td className="px-6 py-4 align-top">
                        {matched ? <Badge variant="success"><CheckCircle2 className="mr-2 h-3.5 w-3.5" /> Matches</Badge> : <Badge variant="warning"><AlertTriangle className="mr-2 h-3.5 w-3.5" /> Update needed</Badge>}
                      </td>
                    </tr>
                  ))}
                  {rows.length === 0 && <tr><td colSpan={4} className="px-6 py-8 text-center text-neutral-500">Time tracking has no payable time for {formatDateRange(review.start_date, review.end_date)}.</td></tr>}
                </tbody>
              </table>
            </div>

            {(review.payment_attestations?.length || 0) > 0 && (
              <section className="border-t border-warning-200 bg-warning-50/60 px-6 py-6" aria-label="Payment evidence pending">
                <h4 className="font-semibold text-neutral-950">Payment reported; check evidence pending</h4>
                <p className="mt-2 text-sm text-neutral-600">These entries remain held while the historical payment is verified. They are excluded from payable hours and cannot be treated as issued payments.</p>
                {review.payment_attestations?.map((attestation) => (
                  <article key={attestation.id} className="mt-4 rounded-lg border border-warning-200 bg-white p-4 text-sm">
                    <p className="font-semibold">Source entry {attestation.source_time_entry_id} · {hours(attestation.hours)} hrs · {formatDate(attestation.original_work_date)}</p>
                    <p className="mt-2">{attestation.evidence_needed}</p>
                    {attestation.source_changed && <p className="mt-2 text-warning-900">The source changed after the payment was reported. Review the current evidence before reconciliation.</p>}
                  </article>
                ))}
              </section>
            )}
            {(review.cornerstone_manual_allocations?.length || 0) > 0 && (
              <section className="border-t border-neutral-200 px-6 py-6" aria-label="Historical payment reconciliation">
                <h4 className="font-semibold text-neutral-950">Historical payment reconciliation</h4>
                <p className="mt-2 text-sm text-neutral-600">These source entries are linked to existing payroll payments. Reconciliation records evidence and does not create another paycheck.</p>
                <div className="mt-4 grid gap-3 sm:grid-cols-2">
                  {review.cornerstone_manual_allocations?.map((allocation) => (
                    <article key={allocation.id} className="rounded-lg border border-neutral-200 p-4">
                      <p className="font-semibold">{allocation.employee_name} · {hours(allocation.regular_hours + allocation.overtime_hours)} hrs</p>
                      <p className="mt-2 text-sm">{formatDate(allocation.original_work_date)} · {allocation.status.replaceAll('_', ' ')}</p>
                      {allocation.last_sync_error && <p role="alert" className="mt-2 text-sm text-danger-800">{allocation.last_sync_error}</p>}
                    </article>
                  ))}
                </div>
              </section>
            )}
            {(review.historical_classification_reviews?.length || 0) > 0 && (
              <section className="border-t border-warning-200 bg-warning-50/60 px-6 py-6" aria-label="Historical classification reviews">
                <h4 className="font-semibold text-neutral-950">Historical regular and overtime differences</h4>
                <p className="mt-2 text-sm text-neutral-600">The issued check is preserved. A completed source reconciliation still requires review of any wage difference.</p>
                {review.historical_classification_reviews?.map((item) => (
                  <article key={item.id} className="mt-4 rounded-lg border border-warning-200 bg-white p-4 text-sm">
                    <p className="font-semibold">{item.employee_name} · check {item.check_number} · {item.source_entry_count} source entries</p>
                    <p className="mt-2">Time tracking: {hours(item.source_regular_hours)} regular · {hours(item.source_overtime_hours)} OT. Payroll: {hours(item.payroll_regular_hours)} regular · {hours(item.payroll_overtime_hours)} OT.</p>
                    <p className="mt-2">Gross wage difference: {item.gross_wage_difference < 0 ? '−' : '+'}${Math.abs(item.gross_wage_difference).toFixed(2)} ({item.gross_wage_difference < 0 ? 'issued check wages exceed time tracking estimate' : item.gross_wage_difference > 0 ? 'time tracking estimate exceeds issued check wages' : 'estimates match'}) · {item.status}</p>
                    <p className="mt-2 text-neutral-600">{item.note}</p>
                  </article>
                ))}
              </section>
            )}

            {review.exclusions.length > 0 && (
              <div className="border-t border-warning-200 bg-warning-50/60 px-6 py-6">
                <h4 className="font-semibold text-neutral-950">Held outside the current payable total</h4>
                <p className="mt-2 text-sm text-neutral-600">Resolve these in time tracking when appropriate. They stay tracked and will not be silently added to this payroll.</p>
                <div className="mt-4 grid gap-2 sm:grid-cols-2">
                  {review.exclusions.map((exclusion) => (
                    <div key={`${exclusion.source_time_entry_id}-${exclusion.reason}`} className="rounded-lg border border-warning-200 bg-white p-4 text-sm">
                      <p className="font-semibold text-neutral-950">{exclusion.cornerstone.employee_name || exclusion.display_name} · {hours(exclusion.held_total_hours)} hrs</p>
                      <p className="mt-2 text-xs text-neutral-600">{formatDate(exclusion.original_work_date)} · {exclusionLabel(exclusion.reason)}</p>
                    </div>
                  ))}
                </div>
              </div>
            )}

            <div className="border-t border-neutral-200 bg-neutral-950 px-6 py-6 text-sm text-neutral-200">
              <p className="font-semibold text-white">What happens at cutoff</p>
              <ol className="mt-2 grid gap-2 leading-5 md:grid-cols-4">
                <li><span className="font-semibold text-white">1.</span> Time tracking freezes eligible time.</li>
                <li><span className="font-semibold text-white">2.</span> Cornerstone verifies the batch.</li>
                <li><span className="font-semibold text-white">3.</span> Review and add the hours once.</li>
                <li><span className="font-semibold text-white">4.</span> Calculate the payroll.</li>
              </ol>
              <p className="mt-4 text-xs leading-5 text-neutral-300">
                {isCommitted
                  ? aireRecordLinked
                    ? 'Cornerstone reports check preparation and delivery back to time tracking automatically.'
                    : 'This run is committed. Link the verified time tracking record so both systems retain the same history.'
                  : 'After the verified batch is added, Cornerstone carries its exact entry links through calculation, checks, and payment status.'}
              </p>
            </div>
          </>
        )}
      </CardContent>
    </Card>
  );
}
