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
    if (record.net_pay === 0) return '$0 net · earnings statement only';
    if (record.payment_delivery_method === 'direct_deposit') return 'Direct deposit';
    return record.check_number ? 'Paper check' : 'Paper check · not assigned';
  }
  const source = record.payment_method?.trim();
  if (source && /^(direct[ _-]?deposit|dd|ach)$/i.test(source)) return 'Direct deposit';
  if (source && /^(paper[ _-]?check|check|cheque)$/i.test(source)) return 'Paper check';
  return source || (record.check_number ? 'Paper check' : 'Not recorded');
}
