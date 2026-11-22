import { formatDate } from '@/lib/utils';
import type { EmployeeCompensationHistory } from '@/types';

// The explicit effective-date choice a pay change needs (M3-4).
export type PayChangeTiming = 'next_uncommitted_period' | 'today' | 'custom';

export interface PayChangeEffectiveDateValue {
  timing: PayChangeTiming | null;
  customDate: string;
  reason: string;
  historicalCorrection: boolean;
}

export const emptyPayChangeEffectiveDate = (): PayChangeEffectiveDateValue => ({
  timing: null,
  customDate: '',
  reason: '',
  historicalCorrection: false,
});

export type PayChangeEffectiveDates = EmployeeCompensationHistory['effective_dates'];

export function resolvePayChangeEffectiveOn(value: PayChangeEffectiveDateValue, dates: PayChangeEffectiveDates): string | null {
  if (value.timing === 'next_uncommitted_period') return dates.next_uncommitted_period;
  if (value.timing === 'today') return dates.today;
  if (value.timing === 'custom') return value.customDate || null;
  return null;
}

// Dates are ISO calendar dates, so string order is date order.
export function payChangeTouchesLockedPayroll(value: PayChangeEffectiveDateValue, dates: PayChangeEffectiveDates): boolean {
  const effectiveOn = resolvePayChangeEffectiveOn(value, dates);
  return Boolean(effectiveOn && dates.locked_through && effectiveOn <= dates.locked_through);
}

export function payChangeEffectiveDateErrors(
  value: PayChangeEffectiveDateValue,
  dates: PayChangeEffectiveDates,
  { basisChanged }: { basisChanged: boolean },
): Record<string, string[]> {
  const errors: Record<string, string[]> = {};
  const effectiveOn = resolvePayChangeEffectiveOn(value, dates);
  if (!value.timing) {
    errors.compensation_effective_on = ['Choose when this pay change takes effect.'];
  } else if (!effectiveOn) {
    errors.compensation_effective_on = ['Enter the date this pay change takes effect.'];
  } else if (basisChanged && effectiveOn > dates.today) {
    errors.compensation_effective_on = ['Pay type changes take effect immediately. Choose today or an earlier date.'];
  } else if (payChangeTouchesLockedPayroll(value, dates) && !value.historicalCorrection) {
    errors.compensation_effective_on = [
      `Payroll through ${formatDate(dates.locked_through as string)} is approved or committed. Choose a later date, or record this as a historical correction.`,
    ];
  }
  if (!value.reason.trim()) errors.compensation_change_reason = ['Explain why the pay is changing.'];
  return errors;
}
