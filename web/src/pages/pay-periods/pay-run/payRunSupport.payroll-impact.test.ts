import { expect, it } from 'vitest';
import type { Employee, PayrollItem } from '@/types';
import { buildHoursMap, derivePayrollUiState } from './payRunSupport';

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
