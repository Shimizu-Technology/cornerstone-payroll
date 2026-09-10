import type { PayrollItem } from '../types';

// medicare_tax is the saved employee total, including Additional Medicare.
// Keep signed correction amounts: clamping would hide historical reversals.
export function payrollTaxSummary(item: Pick<PayrollItem, 'withholding_tax' | 'additional_withholding' | 'social_security_tax' | 'medicare_tax' | 'additional_medicare_tax'>): {
  total: number;
  baseMedicare: number;
  additionalMedicare: number;
  totalMedicare: number;
} {
  const cents = (value: number | null | undefined): number => Math.round(Number(value || 0) * 100);
  const medicare = cents(item.medicare_tax);
  const additional = cents(item.additional_medicare_tax);
  return {
    total: (cents(item.withholding_tax) + cents(item.additional_withholding) + cents(item.social_security_tax) + medicare) / 100,
    baseMedicare: (medicare - additional) / 100,
    additionalMedicare: additional / 100,
    totalMedicare: medicare / 100,
  };
}

export interface PayrollComponentLine {
  label: string;
  amount: number;
  source?: string | null;
  treatment?: string;
}

export interface PayrollComponentDisclosure {
  earnings: PayrollComponentLine[];
  other_pay: PayrollComponentLine[];
  taxes: PayrollComponentLine[];
  deductions: PayrollComponentLine[];
  employer_contributions: PayrollComponentLine[];
  reconciliation: { gross_pay: number; other_pay: number; employee_taxes: number; other_deductions: number; net_pay: number };
}

export function payrollComponentSource(source?: string | null): string | undefined {
  switch (source) {
    case 'employee_default': return 'Recurring setup';
    case 'manual': return 'This payroll';
    case 'one_time': return 'One-time bonus';
    case 'legacy_snapshot': return 'Saved adjustment';
    default: return undefined;
  }
}
