import { describe, expect, it } from 'vitest';
import { payrollTaxSummary } from './payroll-tax-summary';

describe('saved employee tax totals', () => {
  it('includes extra withholding and counts threshold Medicare once', () => {
    expect(payrollTaxSummary({ withholding_tax: 100, additional_withholding: 25, social_security_tax: 0, medicare_tax: 19, additional_medicare_tax: 4.50 })).toEqual({ total: 144, baseMedicare: 14.5, additionalMedicare: 4.5, totalMedicare: 19 });
  });
  it('preserves signed correction amounts and rounds in cents', () => {
    expect(payrollTaxSummary({ withholding_tax: -0.1, additional_withholding: -0.2, medicare_tax: -19, additional_medicare_tax: -4.5 })).toEqual({ total: -19.3, baseMedicare: -14.5, additionalMedicare: -4.5, totalMedicare: -19 });
  });
  it('handles old snapshots without additional Medicare', () => {
    expect(payrollTaxSummary({ medicare_tax: 14.50 }).total).toBe(14.50);
  });
});
