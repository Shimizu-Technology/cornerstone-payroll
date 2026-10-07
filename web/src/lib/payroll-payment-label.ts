import type { PayrollItem } from '@/types';

interface PayrollPaymentRecord {
  payment_method_label?: string;
  payment_delivery_method?: string | null;
  payment_method?: string | null;
  check_number?: string | number | null;
  record_type?: string;
  net_pay?: number;
}

/** Uses each record's saved delivery method, rather than today's employee setup. */
export function payrollPaymentLabel(record: PayrollPaymentRecord): string {
  if (record.payment_method_label) return record.payment_method_label;
  if (record.record_type === 'adjustment') return 'Adjustment — no payment issued';
  if (record.record_type === 'native') {
    if (record.net_pay !== undefined && record.net_pay < 0) return 'Adjustment — no payment issued';
    if (record.net_pay === 0) return '$0 net · earnings statement only';
    if (record.payment_delivery_method === 'direct_deposit') return 'Direct deposit';
    return record.check_number ? 'Paper check' : 'Paper check · not assigned';
  }
  const source = record.payment_method?.trim();
  if (source && /^(direct[ _-]?deposit|dd|ach)$/i.test(source)) return 'Direct deposit';
  if (source && /^(paper[ _-]?check|check|cheque)$/i.test(source)) return 'Paper check';
  return source || (record.check_number ? 'Paper check' : 'Not recorded');
}

interface PayRunPaymentDisplay {
  method: string;
  description: string;
  check: string;
  status: string;
  tone: 'danger' | 'default' | 'info' | 'warning' | 'success';
  canChange: boolean;
}

export function payRunPaymentDisplay(item: PayrollItem, options: { committed: boolean; rehearsal: boolean; canPreview: boolean }): PayRunPaymentDisplay {
  const deposit = item.effective_payment_delivery_method === 'direct_deposit';
  const method = deposit ? 'Direct deposit' : 'Paper check';
  const check = deposit ? 'Earnings stub' : options.rehearsal ? 'Rehearsal preview - no check number' : item.check_number || 'Not assigned';
  if (item.voided) return { method, description: `${method} · voided`, check, status: 'Voided', tone: 'danger', canChange: false };
  const net = Number(item.net_pay || 0);
  if (net <= 0) {
    const statement = item.earnings_statement_eligible ?? (Number(item.gross_pay || 0) !== 0 || Number(item.total_deductions || 0) !== 0);
    return { method: statement ? 'Earnings statement only' : 'No pay activity', description: statement ? net < 0 ? 'Adjustment · earnings statement only' : '$0 net · earnings statement only' : 'No pay activity', check: 'No payment issued', status: statement ? 'No payment issued' : 'No pay activity', tone: 'default', canChange: false };
  }
  const status = deposit ? options.committed ? 'Stub ready' : 'Not ready' : options.rehearsal ? options.canPreview ? 'Preview ready' : 'Not ready' : item.check_status === 'delivered' ? 'Issued' : item.check_status === 'printed' ? 'Printed' : item.check_status === 'prepared' ? 'Prepared' : item.check_number ? 'Assigned' : 'Pending';
  return { method, description: deposit ? 'Direct deposit · earnings stub' : options.rehearsal ? 'Rehearsal preview · no check number' : `Paper check · ${item.check_number || 'number not assigned'}`, check, status, tone: deposit ? 'info' : options.rehearsal ? 'warning' : ['prepared', 'printed', 'delivered'].includes(item.check_status || '') ? 'success' : 'default', canChange: !options.rehearsal };
}
