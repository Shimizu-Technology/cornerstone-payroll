import type { CheckItem } from '@/types';

export function canEditPayrollCheckNumber(
  item: Pick<CheckItem, 'check_number' | 'reconciliation_status' | 'voided'>,
) {
  if (item.voided || !item.check_number) return false;

  return item.reconciliation_status === 'unprepared' || item.reconciliation_status === 'prepared';
}
