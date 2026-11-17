import { formatCurrency } from '@/lib/utils';

import type { AddBackAmount, AddBackResult } from '@/types';

export const addBackAmountText = (entry: AddBackAmount) => `${entry.label} ${formatCurrency(entry.amount)}`;

/** One line on who is back, what the import brought back, and the next step. */
export function addBackSummary(result: AddBackResult, hoursEntered = false): string {
  const restored = result.restored.length ? ` Restored from the import: ${result.restored.map(addBackAmountText).join(', ')}.` : '';
  if (hoursEntered) return `${result.employee_name} is back.${restored} Hours are entered.`;
  const next = result.restored.length || result.not_restored.length ? 'Enter hours, then calculate.' : 'Enter hours or import again.';
  return `${result.employee_name} is back.${restored} Hours aren't brought back. ${next}`;
}
