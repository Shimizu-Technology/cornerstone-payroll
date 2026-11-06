import type { PayPeriod } from '@/types';

// An available/verified batch is still outside payroll until explicitly added.
export function needsSourceCoverageAcknowledgement(period: PayPeriod): boolean {
  const calendar = period.time_tracking?.aire_calendar;
  return ['draft', 'calculated', 'approved'].includes(period.status) && period.run_purpose === 'regular'
    && Boolean(calendar?.enabled && (calendar.cutoff_at || calendar.publication || calendar.external_pay_period_id))
    && !period.time_tracking?.linked_aire_records?.length;
}
