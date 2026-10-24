import type { ReactNode } from 'react';
import { Button } from '@/components/ui/button';
import { formatGuamDateTime } from '@/lib/utils';
import type { AirePayrollCalendarState, AirePayrollCockpitOverview, AirePayrollRecord, PayPeriodStatus } from '@/types';

type Props = {
  calendar: AirePayrollCalendarState;
  overview: AirePayrollCockpitOverview | null;
  aireRecord: AirePayrollRecord | null;
  payPeriodStatus: PayPeriodStatus;
  sourceCoverageRequired: boolean;
  sourceCoverageAction?: ReactNode;
  canReviewTimecards: boolean;
  loading: boolean;
  onReview: () => void;
  onReviewTimecards: () => void;
  onReviewSource: () => void;
};

const cutoffLabels: Record<AirePayrollCalendarState['cutoff_state'], string> = {
  unpublished: 'Cutoff not published',
  publishing: 'Publishing cutoff',
  publication_failed: 'Cutoff sync needs attention',
  schedule_changed: 'Cutoff schedule needs updating',
  scheduled: 'Locks',
  upcoming: 'Locks',
  due: 'Due — waiting for time tracking',
  cutoff_due: 'Due — waiting for time tracking',
  finalized: 'Locked — waiting for verification',
  batch_verifying: 'Locked — verifying batch',
  batch_verification_failed: 'Locked — verification retrying',
  batch_rejected: 'Locked — batch needs review',
  batch_verified: 'Locked',
};

const hours = (value: unknown) => value != null && Number.isFinite(Number(value)) ? Number(value).toFixed(2) : '—';

export function AireSourceCheckpointSummary({
  calendar, overview, aireRecord, payPeriodStatus, sourceCoverageRequired, sourceCoverageAction,
  canReviewTimecards, loading, onReview, onReviewTimecards, onReviewSource,
}: Props) {
  const batch = calendar.finalized_batch?.verification_status === 'verified' ? calendar.finalized_batch : null;
  const summary = batch?.summary;
  const corrections = Number(summary?.correction_count || 0) > 0 || Number(batch?.issues?.negative_adjustment_count || 0) > 0;
  const committed = payPeriodStatus === 'committed';
  const heldCount = batch ? summary?.exclusion_count : overview?.readiness.held_entries;
  const issues = batch?.issues;
  const readiness = overview?.readiness;
  const reasons = [
    [issues?.pending_approval_count ?? (!batch ? readiness?.pending_approvals : undefined), batch ? 'awaiting approval or submitted/approved after cutoff' : 'approval needed', batch ? 'awaiting approval or submitted/approved after cutoff' : 'approvals needed'],
    [issues?.pending_overtime_count ?? (!batch ? readiness?.pending_overtime : undefined), batch ? 'overtime pending or approved after cutoff' : 'overtime approval needed', batch ? 'overtime pending or approved after cutoff' : 'overtime approvals needed'],
    [issues?.open_clock_count ?? (!batch ? readiness?.missing_punches : undefined), 'missing punch', 'missing punches'],
    // Frozen missing-category counts describe earning adjustments, not exclusions.
    [!batch ? readiness?.missing_categories : undefined, 'missing category', 'missing categories'],
    [issues?.denied_approval_count ?? (!batch ? readiness?.denied_entries : undefined), 'denied entry', 'denied entries'],
    [issues?.denied_overtime_count, 'overtime denial', 'overtime denials'],
    [issues?.payment_attested_pending_evidence_count ?? (!batch ? readiness?.payment_attested_pending_evidence_entries : undefined), 'payment report awaiting evidence', 'payment reports awaiting evidence'],
  ] as const;
  const heldReasons = reasons.filter(([count]) => Number(count) > 0)
    .map(([count, singular, plural]) => `${count} ${count === 1 ? singular : plural}`).join(' · ');
  const lineStatus = aireRecord?.payable_line_status;
  const attention = Number(lineStatus?.needs_attention.line_count || 0) > 0;
  const paymentPending = committed && Number(lineStatus?.in_payroll.line_count || 0) + Number(lineStatus?.payment_pending.line_count || 0) > 0;
  const allPaid = committed && lineStatus && lineStatus.line_count > 0 && lineStatus.paid.line_count === lineStatus.line_count;
  const cutoffLabel = batch ? 'Locked' : cutoffLabels[calendar.cutoff_state];

  return (
    <section aria-label="Source checkpoint" className="space-y-3 p-4 sm:p-5">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h3 className="font-display text-base font-bold text-neutral-950">Source checkpoint</h3>
          <p className="mt-1 text-sm text-neutral-700">
            {cutoffLabel}{calendar.cutoff_at ? ` · ${formatGuamDateTime(calendar.cutoff_at, { second: undefined })}` : ' · cutoff time unavailable'}
          </p>
        </div>
        {batch && !aireRecord ? (
          <Button type="button" variant="outline" onClick={onReview} className="max-sm:w-full sm:shrink-0">
            {committed ? 'Review and link time tracking record' : corrections ? 'Review time tracking corrections' : 'Review and add time tracking hours'}
          </Button>
        ) : canReviewTimecards ? (
          <Button type="button" variant="outline" onClick={onReviewTimecards} className="max-sm:w-full sm:shrink-0">Review timecards</Button>
        ) : (
          <Button type="button" variant="outline" onClick={onReviewSource} className="max-sm:w-full sm:shrink-0">Review source details</Button>
        )}
      </div>
      <div className="grid gap-3 border-t border-neutral-200 pt-3 sm:grid-cols-2">
        <div>
          <p className="text-sm font-semibold tabular-nums text-neutral-950">
            {batch ? `${hours(summary?.total_hours)} h ${aireRecord ? 'added' : 'in locked batch'}` : aireRecord ? 'Source hours linked to payroll' : 'No locked batch added'}
          </p>
          <p className="mt-1 text-sm tabular-nums text-neutral-700">
            {batch ? `${hours(summary?.regular_hours)} regular + ${hours(summary?.overtime_hours)} OT · ${summary?.employee_count ?? '—'} people`
              : loading ? 'Checking source hours…' : 'Regular / OT / people available after batch verification.'}
          </p>
          {!batch && readiness && <p className="mt-1 text-xs tabular-nums text-neutral-600">{hours(readiness.eligible_hours)} h ready for cutoff · live estimate</p>}
          {corrections && <p className="mt-1 text-xs text-neutral-600">Signed batch totals include corrections. Review the exact hours before adding them.</p>}
        </div>
        <div>
          <p className={`text-sm font-semibold tabular-nums ${Number(heldCount) > 0 ? 'text-warning-900' : 'text-neutral-950'}`}>
            {heldCount == null ? 'Held entry count unavailable' : `${heldCount} held ${heldCount === 1 ? 'entry' : 'entries'} excluded`}
          </p>
          <p className="mt-1 text-xs leading-5 text-neutral-600">{heldReasons || (Number(heldCount) > 0 ? 'Outside this cutoff; review held time for the exact reasons.' : heldCount === 0 ? 'No held entries reported.' : 'Review source details for held time.')}</p>
        </div>
      </div>
      {sourceCoverageRequired && <div className="space-y-2"><p className="text-xs leading-5 text-neutral-600">Source hours have not been linked to this payroll. Calculating without linked source hours requires an acknowledgement and reason.</p>{sourceCoverageAction}</div>}
      {aireRecord && <p className={`text-sm ${attention || paymentPending ? 'text-warning-900' : 'text-neutral-700'}`}>
        {attention ? 'Time tracking payment needs attention. Review the payment history.'
          : allPaid ? 'Time tracking hours are paid; delivery or settlement is recorded.'
            : paymentPending ? 'Time tracking hours are linked; payment evidence is pending.'
              : 'Time tracking hours are linked. Adding hours does not mark anyone paid.'}
      </p>}
      {!calendar.eligible && calendar.eligibility_error && <p role="status" className="text-sm text-warning-900">{calendar.eligibility_error}</p>}
      {(calendar.finalized_batch?.last_error || calendar.publication?.last_error) && <p role="alert" className="break-words text-sm text-danger-800">{calendar.finalized_batch?.last_error || calendar.publication?.last_error}</p>}
    </section>
  );
}
