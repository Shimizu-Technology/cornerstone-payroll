import type { PayrollItem } from '@/types';

export interface VisibleOptionalColumns {
  nonTaxableAdditions: boolean;
  retirement: boolean;
  loans: boolean;
  insurance: boolean;
  otherDeductions: boolean;
  count: number;
}

export function numericAmount(value: number | string | null | undefined): number {
  const parsed = Number(value);
  return value == null || !Number.isFinite(parsed) ? 0 : parsed;
}

export function itemNonTaxableAdditions(item: PayrollItem): number {
  if (item.non_taxable_additions_total != null && Number.isFinite(Number(item.non_taxable_additions_total))) {
    return numericAmount(item.non_taxable_additions_total);
  }
  return numericAmount(item.non_taxable_pay);
}

export function itemTaxes(item: PayrollItem): number {
  return numericAmount(item.withholding_tax) + numericAmount(item.additional_withholding)
    + numericAmount(item.social_security_tax) + numericAmount(item.medicare_tax)
    + numericAmount(item.state_withheld);
}

export function itemRetirement(item: PayrollItem): number {
  return numericAmount(item.retirement_payment) + numericAmount(item.roth_retirement_payment);
}

export function itemLoans(item: PayrollItem): number {
  if (item.loan_payment != null && Number.isFinite(Number(item.loan_payment))) {
    return numericAmount(item.loan_payment);
  }
  return numericAmount(item.loan_deduction);
}

export function itemInsurance(item: PayrollItem): number {
  return numericAmount(item.insurance_payment);
}

export function itemOtherDeductions(item: PayrollItem): number {
  if (item.other_deductions != null && Number.isFinite(Number(item.other_deductions))) {
    const value = numericAmount(item.other_deductions);
    return value === 0 ? 0 : value;
  }
  const total = numericAmount(item.total_deductions);
  const diff = Math.round((total - (itemTaxes(item) + itemRetirement(item) + itemLoans(item) + itemInsurance(item))) * 100) / 100;
  return diff === 0 ? 0 : diff;
}

export function getVisibleOptionalColumns(items: PayrollItem[]): VisibleOptionalColumns {
  const validItems = items.filter((item) => !item.details_error);
  const nonTaxableAdditions = validItems.some((item) => itemNonTaxableAdditions(item) !== 0);
  const retirement = validItems.some((item) => itemRetirement(item) !== 0);
  const loans = validItems.some((item) => itemLoans(item) !== 0);
  const insurance = validItems.some((item) => itemInsurance(item) !== 0);
  const otherDeductions = validItems.some((item) => itemOtherDeductions(item) !== 0);
  const count = [nonTaxableAdditions, retirement, loans, insurance, otherDeductions].filter(Boolean).length;
  return { nonTaxableAdditions, retirement, loans, insurance, otherDeductions, count };
}
