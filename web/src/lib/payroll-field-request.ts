import type { PayrollItemFieldEntry } from '@/types';

export function payrollFieldRequestedAmount(entry: PayrollItemFieldEntry): number {
  for (const value of [entry.metadata?.loan_requested_amount, entry.metadata?.uncapped_amount]) {
    if (typeof value !== 'number' && typeof value !== 'string') continue;
    if (typeof value === 'string' && value.trim() === '') continue;
    const amount = Number(value);
    if (Number.isFinite(amount) && amount >= 0) return amount;
  }
  return Number(entry.amount) || 0;
}
