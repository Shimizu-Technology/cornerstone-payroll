import { expect, it } from 'vitest';
import type { Employee, PayrollItem } from '@/types';
import { buildHoursMap, derivePayrollUiState, unavailableSavedWageRateLabels } from './payRunSupport';

it('rehydrates the retained loan request after a zero-pay cap instead of resubmitting zero', () => {
  const item = { employee_id: 7, loan_deduction: 0, requested_loan_deduction: 89 } as PayrollItem;
  expect(derivePayrollUiState([item]).loans).toEqual({ '7': 89 });
});

it('keeps legacy loan inputs and an explicit cleared request', () => {
  expect(derivePayrollUiState([{ employee_id: 7, loan_deduction: 25 } as PayrollItem]).loans).toEqual({ '7': 25 });
  expect(derivePayrollUiState([{ employee_id: 7, loan_deduction: 25, requested_loan_deduction: 0 } as PayrollItem]).loans).toEqual({});
});

it('preserves imported hours when several configured jobs share the same rate', () => {
  const employee = { id: 7, employment_type: 'hourly', wage_rates: [
    { id: 11, label: 'Hourly rate', rate: 12.5, is_primary: true, active: true },
    { id: 12, label: 'Kitchen', rate: 12.5, is_primary: false, active: true },
  ] } as Employee;
  const item = { employee_id: 7, import_source: 'mosa_revel', pay_rate: 12.5, hours_worked: 72.95, overtime_hours: 1.94 } as PayrollItem;
  const rates = buildHoursMap([item], [employee])['7'].wage_rates!;
  expect(rates.map(rate => rate.regular_hours)).toEqual([72.95, 0]);
  expect(rates.map(rate => rate.overtime_hours)).toEqual([1.94, 0]);
});

it('does not move saved hours onto an equal-rate profile whose rate changed', () => {
  const employee = { id: 7, employment_type: 'hourly', wage_rates: [
    { id: 11, label: 'Hourly rate', rate: 16.5, is_primary: true, active: true },
    { id: 12, label: 'Kitchen', rate: 16.5, is_primary: false, active: true },
  ] } as Employee;
  const item = { employee_id: 7, pay_rate: 15.5, hours_worked: 68.84 } as PayrollItem;
  expect(buildHoursMap([item], [employee])['7'].wage_rates!.map(rate => rate.regular_hours)).toEqual([0, 0]);
});

it('does not assign ambiguous differently-priced jobs without a saved allocation', () => {
  const employee = { id: 7, employment_type: 'hourly', wage_rates: [
    { id: 11, label: 'Hourly rate', rate: 15.5, is_primary: true, active: true },
    { id: 12, label: 'Kitchen', rate: 16.5, is_primary: false, active: true },
  ] } as Employee;
  const item = { employee_id: 7, hours_worked: 68.84 } as PayrollItem;
  expect(buildHoursMap([item], [employee])['7'].wage_rates!.map(rate => rate.regular_hours)).toEqual([0, 0]);
});

it('does not duplicate saved secondary hours when a same-rate primary job is added', () => {
  const employee = { id: 7, employment_type: 'hourly', wage_rates: [
    { id: 13, label: 'New primary', rate: 12.5, is_primary: true, active: true },
    { id: 12, label: 'Kitchen', rate: 12.5, is_primary: false, active: true },
  ] } as Employee;
  const item = { employee_id: 7, pay_rate: 12.5, hours_worked: 72.95, overtime_hours: 1.94,
    holiday_hours: 2, pto_hours: 3, wage_rate_hours: [
      { employee_wage_rate_id: 12, label: 'Kitchen', rate: 12.5, regular_hours: 72.95,
        overtime_hours: 1.94, holiday_hours: 2, pto_hours: 3 },
    ] } as PayrollItem;
  const rates = buildHoursMap([item], [employee])['7'].wage_rates!;
  expect(rates.map(rate => rate.regular_hours)).toEqual([0, 72.95]);
  expect(rates.map(rate => rate.overtime_hours)).toEqual([0, 1.94]);
  expect(rates.map(rate => rate.holiday_hours)).toEqual([0, 2]);
  expect(rates.map(rate => rate.pto_hours)).toEqual([0, 3]);
});

it('detects saved nonzero hours on inactive and removed jobs before calculation', () => {
  const employee = { wage_rates: [
    { id: 1, label: 'Active', rate: 15, active: true },
    { id: 2, label: 'Retired', rate: 10, active: false },
  ] } as Employee;
  const item = { id: 1, employee_id: 7, employment_type: 'hourly', pay_rate: 15, wage_rate_hours: [
    { employee_wage_rate_id: 2, label: 'Retired', regular_hours: 4 },
    { employee_wage_rate_id: 3, label: 'Deleted', overtime_hours: 2 },
    { employee_wage_rate_id: 4, label: 'Empty', regular_hours: 0 },
    { label: 'Legacy', rate: 12, regular_hours: 3, active: true },
  ].map(entry => ({ rate: 10, regular_hours: 0, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, ...entry })) } as PayrollItem;
  expect(unavailableSavedWageRateLabels(employee, item)).toEqual(['Retired', 'Deleted']);
  expect(unavailableSavedWageRateLabels(employee, { ...item, timekeeping_source: 'correction_reference' })).toEqual([]);
  expect(unavailableSavedWageRateLabels(employee, { ...item, import_source: 'time_tracking:aire' })).toEqual([]);
});

it.each([true, false])('retains a saved legacy job bucket alongside configured jobs (active=%s)', active => {
  const employee = { id: 7, employment_type: 'hourly', wage_rates: [
    { id: 1, label: 'New primary', rate: 15, is_primary: true, active: true },
    { id: 2, label: 'Server', rate: 15, is_primary: false, active: true },
  ] } as Employee;
  const legacy = { label: 'Legacy kitchen', rate: 12, regular_hours: 3,
    overtime_hours: 1, holiday_hours: 2, pto_hours: 4, is_primary: false, active };
  const item = { id: 1, employee_id: 7, employment_type: 'hourly', hours_worked: 3, overtime_hours: 1, holiday_hours: 2, pto_hours: 4,
    pay_rate: 12, wage_rate_hours: [legacy] } as PayrollItem;
  const rates = buildHoursMap([item], [employee])['7'].wage_rates!;
  expect(rates).toContainEqual(legacy);
  expect(rates.reduce((sum, r) => sum + r.regular_hours, 0)).toBe(3);
  expect(rates.reduce((sum, r) => sum + r.overtime_hours, 0)).toBe(1);
  expect(rates.reduce((sum, r) => sum + (r.holiday_hours || 0), 0)).toBe(2);
  expect(rates.reduce((sum, r) => sum + (r.pto_hours || 0), 0)).toBe(4);
});

it('does not block the run for an employee missing from the eligible list or for a legacy job without an ID', () => {
  const item = { id: 1, employee_id: 7, employment_type: 'hourly', hours_worked: 10, pay_rate: 15, wage_rate_hours: [
    { employee_wage_rate_id: 1, label: 'Kitchen', rate: 15, regular_hours: 10, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, is_primary: true, active: true },
  ] } as PayrollItem;
  // Inactive or terminated employees are not in the eligible list; the server skips them.
  expect(unavailableSavedWageRateLabels(undefined, item)).toEqual([]);
  const employee = { id: 7, employment_type: 'hourly', wage_rates: [{ id: 2, label: 'Server', rate: 15, is_primary: true, active: true }] } as Employee;
  const legacy = { ...item, wage_rate_hours: [{ label: 'Old job', rate: 12, regular_hours: 4, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, is_primary: false, active: false }] } as PayrollItem;
  expect(unavailableSavedWageRateLabels(employee, legacy)).toEqual([]);
});
