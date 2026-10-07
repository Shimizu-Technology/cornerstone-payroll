import { describe, expect, it } from 'vitest';
import { payrollFieldRequestedAmount } from './payroll-field-request';
import type { PayrollItemFieldEntry } from '@/types';

describe('requested versus applied payroll fields', () => {
  const entry = (metadata: Record<string, unknown>, amount = 93.04) => ({ amount, metadata }) as PayrollItemFieldEntry;
  it('retains the intended retirement amount after an annual cap', () => {
    expect(payrollFieldRequestedAmount(entry({ uncapped_amount: '1070.0' }))).toBe(1070);
  });
  it('uses the original loan request over an intermediate capped amount', () => {
    expect(payrollFieldRequestedAmount(entry({ loan_requested_amount: '120', uncapped_amount: '80' }))).toBe(120);
  });
  it('retains an explicit zero and safely rejects malformed metadata', () => {
    expect(payrollFieldRequestedAmount(entry({ uncapped_amount: '0' }))).toBe(0);
    expect(payrollFieldRequestedAmount(entry({ loan_requested_amount: true, uncapped_amount: 'Infinity' }))).toBe(93.04);
  });
});
