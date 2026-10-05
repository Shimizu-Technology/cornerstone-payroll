import type { ReactElement } from 'react';
import type { EmployeePayHistoryRecord } from '@/services/api';

export function SavedHours({ item }: { item: EmployeePayHistoryRecord }): ReactElement {
  const components = [item.hours_worked, item.overtime_hours, item.holiday_hours, item.pto_hours];
  const total = components.every((value) => value !== null && value !== undefined)
    ? components.reduce<number>((sum, value) => sum + Number(value), 0) : null;
  const hours = (value: number | null | undefined): string => value == null ? 'Unknown' : Number(value).toFixed(2);
  return <div className="space-y-1 text-xs tabular-nums text-neutral-600" aria-label="Saved payroll hours">
    <p className="font-semibold text-neutral-900">{total === null ? 'Total unavailable' : `${total.toFixed(2)} total hours`}</p>
    <p>REG {hours(item.hours_worked)} · OT {hours(item.overtime_hours)}</p>
    <p>Holiday {hours(item.holiday_hours)} · PTO {hours(item.pto_hours)}</p>
    {(item.record_type === 'adjustment' || item.hours_basis === 'signed_payroll_correction') && <p>Signed adjustment</p>}
  </div>;
}
