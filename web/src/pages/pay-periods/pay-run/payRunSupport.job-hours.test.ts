import { expect, it } from 'vitest';
import type { Employee, PayrollItemWageRateHours } from '@/types';
import { preservesWorksheetJobHours } from './payRunSupport';

it('retains the selected nonprimary job through coverage acknowledgement and later full-roster calculations', () => {
  const employee = { wage_rates: [{ id: 1, active: true }, { id: 2, active: true }] } as Employee;
  const rows = [{ employee_wage_rate_id: 2, regular_hours: 16 }] as PayrollItemWageRateHours[];
  expect(preservesWorksheetJobHours(employee, rows)).toBe(true);
});
it('allows basic hours only when a single saved job is active', () => {
  const employee = { wage_rates: [{ id: 1, active: true }, { id: 2, active: false }] } as Employee;
  expect(preservesWorksheetJobHours(employee, [{ employee_wage_rate_id: 1 }] as PayrollItemWageRateHours[])).toBe(false);
});
