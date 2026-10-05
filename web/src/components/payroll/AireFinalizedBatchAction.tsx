import { AlertTriangle, ArrowRight, CheckCircle2, Clock3, ShieldCheck } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import type { AirePayrollCalendarState, AirePayrollRecord, PayPeriodStatus } from '@/types';

type Props = {
  batch: NonNullable<AirePayrollCalendarState['finalized_batch']>;
  payPeriodStatus: PayPeriodStatus;
  aireRecord?: AirePayrollRecord | null;
  onReview: () => void;
};

const hours = (value: unknown) => Number(value || 0).toFixed(2);

export function AireFinalizedBatchAction({ batch, payPeriodStatus, aireRecord, onReview }: Props) {
  const summary = batch.summary || {};
  const employeeCount = Number(summary.employee_count || 0);
  const exclusionCount = Number(summary.exclusion_count || 0);
  const committed = payPeriodStatus === 'committed';
  const aireRecordLinked = Boolean(aireRecord);
  const lineStatus = aireRecord?.payable_line_status;
  const attentionLines = lineStatus?.needs_attention.line_count || 0;
  const unpaidLines = (lineStatus?.in_payroll.line_count || 0) + (lineStatus?.payment_pending.line_count || 0);
  const allLinesPaid = Boolean(lineStatus && lineStatus.line_count > 0 && lineStatus.paid.line_count === lineStatus.line_count);
  const linkedTitle = attentionLines > 0
    ? 'time tracking payment needs attention'
    : committed && allLinesPaid
      ? 'Time tracking hours are paid'
      : committed && unpaidLines > 0
        ? 'Time tracking hours are linked; payment evidence is pending'
        : 'Time tracking hours are in this payroll';
  const linkedBadge = attentionLines > 0 ? 'Needs attention' : committed && allLinesPaid ? 'Paid' : committed && unpaidLines > 0 ? 'Payment pending' : 'Added';
  const linkedBadgeTone = attentionLines > 0 || (committed && unpaidLines > 0) ? 'warning' : 'success';
  const linkedNeedsReview = aireRecordLinked && (attentionLines > 0 || (committed && unpaidLines > 0));

  return (
    <Card className={`overflow-hidden ${linkedNeedsReview ? 'border-warning-200' : aireRecordLinked ? 'border-success-200' : 'border-primary-200'}`}>
      <CardContent className="p-0">
        <div className={`flex flex-col gap-5 px-5 py-5 sm:px-6 lg:flex-row lg:items-start lg:justify-between ${linkedNeedsReview ? 'bg-warning-50/70' : aireRecordLinked ? 'bg-success-50/70' : 'bg-primary-50/70'}`}>
          <div className="flex max-w-3xl items-start gap-4">
            <div className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-xl ${linkedNeedsReview ? 'bg-warning-100 text-warning-900' : aireRecordLinked ? 'bg-success-100 text-success-800' : 'bg-primary-100 text-primary-800'}`}>
              {attentionLines > 0
                ? <AlertTriangle className="h-5 w-5" aria-hidden="true" />
                : linkedNeedsReview
                  ? <Clock3 className="h-5 w-5" aria-hidden="true" />
                  : aireRecordLinked
                    ? <CheckCircle2 className="h-5 w-5" aria-hidden="true" />
                    : <ShieldCheck className="h-5 w-5" aria-hidden="true" />}
            </div>
            <div>
              <div className="flex flex-wrap items-center gap-2">
                <h3 className="font-display text-lg font-bold text-neutral-950">
                  {aireRecordLinked ? linkedTitle : 'Time tracking hours are ready to add'}
                </h3>
                <Badge variant={aireRecordLinked ? linkedBadgeTone : 'info'}>{aireRecordLinked ? linkedBadge : 'Verified batch'}</Badge>
              </div>
              <p className="mt-2 text-sm leading-6 text-neutral-700">
                {aireRecordLinked
                  ? attentionLines > 0
                    ? 'Cornerstone retained the exact affected time tracking lines. Review the check or payment history before deciding what to do next.'
                    : committed && allLinesPaid
                      ? 'Cornerstone has delivery or settlement evidence for every linked payable line in this time tracking batch.'
                      : committed && unpaidLines > 0
                        ? 'The exact time tracking lines are linked to this completed payroll. Prepared checks and committed payroll records remain unpaid until delivery or settlement is recorded.'
                        : 'Cornerstone saved the exact time tracking cutoff batch and its entry-level links. Review the payroll amounts, then continue with the normal payroll steps.'
                  : committed
                    ? 'Review the locked time tracking batch and link it to this completed payroll. Cornerstone will verify every mapped employee without changing the payroll.'
                    : 'Review the locked time tracking batch once, add its hours to this payroll, then select Calculate Payroll. No hours need to be typed again.'}
              </p>
            </div>
          </div>

          {!aireRecordLinked && (
            <Button type="button" onClick={onReview} className="shrink-0">
              {committed ? 'Review and link time tracking record' : 'Review and add time tracking hours'}
              <ArrowRight className="ml-2 h-4 w-4" aria-hidden="true" />
            </Button>
          )}
        </div>

        <div className="grid divide-y divide-neutral-200 bg-white sm:grid-cols-4 sm:divide-x sm:divide-y-0">
          <div className="px-5 py-4 sm:px-6">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Payable hours</p>
            <p className="mt-2 font-display text-xl font-bold text-neutral-950">{hours(summary.total_hours)} hrs</p>
          </div>
          <div className="px-5 py-4 sm:px-6">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Regular</p>
            <p className="mt-2 font-display text-xl font-bold text-neutral-950">{hours(summary.regular_hours)} hrs</p>
          </div>
          <div className="px-5 py-4 sm:px-6">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Overtime</p>
            <p className="mt-2 font-display text-xl font-bold text-neutral-950">{hours(summary.overtime_hours)} hrs</p>
          </div>
          <div className="px-5 py-4 sm:px-6">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">People and held time</p>
            <p className="mt-2 font-semibold text-neutral-950">{employeeCount} employee{employeeCount === 1 ? '' : 's'}</p>
            <p className="mt-1 text-xs text-neutral-500">{exclusionCount} held entr{exclusionCount === 1 ? 'y' : 'ies'} tracked for later</p>
          </div>
        </div>

        {aireRecordLinked && lineStatus && lineStatus.line_count > 0 && (
          <div className="grid divide-y divide-neutral-200 border-t border-neutral-200 bg-neutral-50 sm:grid-cols-4 sm:divide-x sm:divide-y-0">
            {([
              ['In payroll', lineStatus.in_payroll, 'Added to payroll; payment not yet recorded'],
              ['Prepared', lineStatus.payment_pending, 'Payment prepared; delivery pending'],
              ['Paid', lineStatus.paid, 'Delivery or settlement recorded'],
              ['Attention', lineStatus.needs_attention, 'Failed, voided, or missing evidence'],
            ] as const).map(([label, bucket, detail]) => (
              <div key={label} className="px-5 py-4 sm:px-6">
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{label}</p>
                <p className="mt-2 font-display text-lg font-bold text-neutral-950">{hours(bucket.total_hours)} hrs</p>
                <p className="mt-1 text-xs leading-5 text-neutral-500">{bucket.line_count} line{bucket.line_count === 1 ? '' : 's'} · {detail}</p>
              </div>
            ))}
          </div>
        )}

        <div className="flex items-start gap-3 border-t border-neutral-200 bg-neutral-50 px-5 py-4 text-xs leading-5 text-neutral-600 sm:px-6">
          <Clock3 className="mt-0.5 h-4 w-4 shrink-0 text-primary-700" aria-hidden="true" />
          <p>
            {aireRecordLinked
              ? committed
                ? attentionLines > 0
                  ? 'The payment history remains preserved. Failed and voided payments require an explicit follow-up; they are never turned back into new unpaid hours automatically.'
                  : allLinesPaid
                    ? 'Paid means Cornerstone recorded check delivery or deposit settlement and sent that exact status back to time tracking.'
                    : 'Check preparation and delivery are reported back to time tracking automatically. Delivery or settlement establishes paid status.'
                : 'Next: select Calculate Payroll. Adding the batch records hours in payroll; it does not mark anyone paid.'
              : 'Held entries stay visible in time tracking and Cornerstone and are not added to this payroll.'}
          </p>
        </div>
      </CardContent>
    </Card>
  );
}
