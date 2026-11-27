import type { PayrollItem } from '@/types';

interface PayrollPaymentRecord {
  payment_method_label?: string;
}

/**
 * The server's wording (PayrollPaymentLabel), from each record's saved
 * delivery method rather than today's employee setup. Every pay history row
 * carries it; nothing here rewords a payment.
 */
export function payrollPaymentLabel(record: PayrollPaymentRecord): string {
  return record.payment_method_label || 'Not recorded';
}

interface PaymentEvidenceRecord {
  payment_delivery_method?: string | null;
  payment_evidence?: { status: string; label: string } | null;
}

/**
 * The server can't tell a transfer Cornerstone still has to confirm from one
 * handled outside the app, so an unconfirmed direct deposit stays an open item
 * that staff can confirm from the pay run's Checks tab.
 */
export function paymentEvidenceLabel(record: PaymentEvidenceRecord): string {
  const evidence = record.payment_evidence;
  if (!evidence) return 'Payment evidence not available';
  if (needsBankPaymentConfirmation(record)) return 'Bank payment not confirmed yet';
  return evidence.label;
}

export function needsBankPaymentConfirmation(record: PaymentEvidenceRecord): boolean {
  return record.payment_delivery_method === 'direct_deposit' && record.payment_evidence?.status === 'unissued';
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
