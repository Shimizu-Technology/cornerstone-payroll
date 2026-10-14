import type { PayrollItem, PayrollItemWageRateHours } from '@/types';
import { formatDate } from '@/lib/utils';

interface WorksheetHours {
  regular: number;
  overtime: number;
  wage_rates?: PayrollItemWageRateHours[];
}

export function capturedSourceHoursLocked(item?: PayrollItem): boolean {
  return Boolean(item?.import_source?.startsWith('time_tracking:')
    || item?.wage_rate_hours?.some(rate => rate.source_bucket_key));
}

function comparableRate(rate: PayrollItemWageRateHours) {
  return {
    source_bucket_key: rate.source_bucket_key,
    source_lines: rate.source_lines,
    employee_wage_rate_id: rate.employee_wage_rate_id,
    label: rate.label,
    rate: Number(rate.rate),
    regular_hours: Number(rate.regular_hours),
    overtime_hours: Number(rate.overtime_hours),
    holiday_hours: Number(rate.holiday_hours),
    pto_hours: Number(rate.pto_hours),
    is_primary: rate.is_primary ?? false,
    active: rate.active ?? true,
  };
}

export function worksheetHoursInvalid(entry: WorksheetHours, item: PayrollItem | undefined, limit: number): boolean {
  const savedRates = item?.wage_rate_hours;
  // A signed exception belongs only to the unchanged captured import. The server
  // still verifies its allocation, line versions, rates and final earnings.
  const unchangedCapture = Boolean(item?.import_source?.startsWith('time_tracking:')
    && savedRates?.length && entry.wage_rates?.length === savedRates.length
    && Number(item.hours_worked) === Number(entry.regular)
    && Number(item.overtime_hours) === Number(entry.overtime)
    && savedRates.every((rate, index) => rate.source_bucket_key && rate.source_lines?.length
      && JSON.stringify(comparableRate(rate)) === JSON.stringify(comparableRate(entry.wage_rates![index]))));
  const validTotal = (value: number) => Number.isFinite(Number(value)) && Number(value) >= 0 && Number(value) <= limit;
  if (!validTotal(entry.regular) || !validTotal(entry.overtime)) return true;
  return (entry.wage_rates || []).some(rate => [rate.regular_hours, rate.overtime_hours].some(value => (
    !Number.isFinite(Number(value)) || Number(value) > limit || Number(value) < (unchangedCapture ? -limit : 0)
  )));
}

export function capturedSourceContext(rate: PayrollItemWageRateHours): string | null {
  if (!rate.source_lines?.length) return null;
  const labels: Record<string, string> = { current: 'Current work', carryover: 'Carryover', correction: 'Correction' };
  const parts = rate.source_lines.map(line => `${labels[line.source_kind] || line.source_kind} · ${formatDate(line.original_work_date)}`);
  return [...new Set(parts)].join('; ');
}
