import { expect, it } from 'vitest';
import type { PayrollItem } from '@/types';
import { derivePayrollUiState } from './payRunSupport';

it('rehydrates the retained loan request after a zero-pay cap instead of resubmitting zero', () => {
  const item = { employee_id: 7, loan_deduction: 0, requested_loan_deduction: 89 } as PayrollItem;
  expect(derivePayrollUiState([item]).loans).toEqual({ '7': 89 });
});

it('keeps legacy loan inputs and an explicit cleared request', () => {
  expect(derivePayrollUiState([{ employee_id: 7, loan_deduction: 25 } as PayrollItem]).loans).toEqual({ '7': 25 });
  expect(derivePayrollUiState([{ employee_id: 7, loan_deduction: 25, requested_loan_deduction: 0 } as PayrollItem]).loans).toEqual({});
});
