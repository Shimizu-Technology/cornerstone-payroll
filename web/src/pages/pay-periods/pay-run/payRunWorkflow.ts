import type { PayPeriod } from '@/types';

// Disclosure state is deliberately separate from progress. Only saved payroll
// state advances the workflow; committed results remain open for review.
export function payRunSteps(period: PayPeriod) {
  const current = period.status === 'draft' ? 'hours' : period.status === 'approved' ? 'commit' : 'results';
  return {
    current,
    committed: period.status === 'committed',
    hoursReason: period.late_hours_origin_pay_period_id
      ? 'Selected late hours only; the original payroll is unchanged.'
      : period.run_purpose !== 'regular'
        ? 'Hours and pay for selected employees only; regular-period hours are not added automatically.'
        : period.time_tracking?.aire_calendar?.enabled ? 'Review source hours and any held entries before calculating.' : 'Enter hours and pay, then calculate payroll.',
    commitReason: period.parallel_run ? 'Parallel comparison · cannot commit.' : period.status === 'draft' ? 'Calculate payroll and review the results first.' : period.status === 'calculated' ? 'Approve the reviewed results before commitment.' : '',
  };
}
