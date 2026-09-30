import { ArrowRight, CheckCircle2, Clock3, ShieldCheck } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import type { AirePayrollCalendarState, PayPeriodStatus } from '@/types';

type Props = {
  batch: NonNullable<AirePayrollCalendarState['finalized_batch']>;
  payPeriodStatus: PayPeriodStatus;
  aireRecordLinked: boolean;
  onReview: () => void;
};

const hours = (value: unknown) => Number(value || 0).toFixed(2);

export function AireFinalizedBatchAction({ batch, payPeriodStatus, aireRecordLinked, onReview }: Props) {
  const summary = batch.summary || {};
  const employeeCount = Number(summary.employee_count || 0);
  const exclusionCount = Number(summary.exclusion_count || 0);
  const committed = payPeriodStatus === 'committed';

  return (
    <Card className={`overflow-hidden ${aireRecordLinked ? 'border-success-200' : 'border-primary-200'}`}>
      <CardContent className="p-0">
        <div className={`flex flex-col gap-5 px-5 py-5 sm:px-6 lg:flex-row lg:items-start lg:justify-between ${aireRecordLinked ? 'bg-success-50/70' : 'bg-primary-50/70'}`}>
          <div className="flex max-w-3xl items-start gap-4">
            <div className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-xl ${aireRecordLinked ? 'bg-success-100 text-success-800' : 'bg-primary-100 text-primary-800'}`}>
              {aireRecordLinked ? <CheckCircle2 className="h-5 w-5" aria-hidden="true" /> : <ShieldCheck className="h-5 w-5" aria-hidden="true" />}
            </div>
            <div>
              <div className="flex flex-wrap items-center gap-2">
                <h3 className="font-display text-lg font-bold text-neutral-950">
                  {aireRecordLinked ? 'AIRE hours are in this payroll' : 'AIRE hours are ready to add'}
                </h3>
                <Badge variant={aireRecordLinked ? 'success' : 'info'}>{aireRecordLinked ? 'Added' : 'Verified batch'}</Badge>
              </div>
              <p className="mt-2 text-sm leading-6 text-neutral-700">
                {aireRecordLinked
                  ? 'Cornerstone saved the exact AIRE cutoff batch and its entry-level links. Review the payroll amounts, then continue with the normal payroll steps.'
                  : committed
                    ? 'Review the locked AIRE batch and link it to this completed payroll. Cornerstone will verify every mapped employee without changing the payroll.'
                    : 'Review the locked AIRE batch once, add its hours to this payroll, then select Calculate Payroll. No hours need to be typed again.'}
              </p>
            </div>
          </div>

          {!aireRecordLinked && (
            <Button type="button" onClick={onReview} className="shrink-0">
              {committed ? 'Review and link AIRE record' : 'Review and add AIRE hours'}
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

        <div className="flex items-start gap-3 border-t border-neutral-200 bg-neutral-50 px-5 py-4 text-xs leading-5 text-neutral-600 sm:px-6">
          <Clock3 className="mt-0.5 h-4 w-4 shrink-0 text-primary-700" aria-hidden="true" />
          <p>
            {aireRecordLinked
              ? committed
                ? 'Check preparation and delivery are reported back to AIRE automatically. Delivery or settlement establishes paid status.'
                : 'Next: select Calculate Payroll. Adding the batch records hours in payroll; it does not mark anyone paid.'
              : 'Held entries stay visible in AIRE and Cornerstone and are not added to this payroll.'}
          </p>
        </div>
      </CardContent>
    </Card>
  );
}
