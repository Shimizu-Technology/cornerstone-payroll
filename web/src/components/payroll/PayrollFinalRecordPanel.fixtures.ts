import type { PayrollFinalRecord } from '@/services/api';

export const payrollFinalRecordFixture: PayrollFinalRecord = {
  schema_version: 'v1', generated_at: '2026-08-20T12:00:00Z', record_fingerprint: 'a'.repeat(64),
  company: { id: 1, name: 'MoSa LLC' },
  pay_period: { id: 8, start_date: '2026-08-01', end_date: '2026-08-15', pay_date: '2026-08-20', status: 'committed', correction_status: null, cycle: 'regular', run_purpose: 'regular', committed_at: '2026-08-20T12:00:00Z', committed_by_name: 'Dana' },
  official_payroll: { status: 'official', paycheck_count: 1, gross_pay: '1000.0', non_taxable_pay: '0.0', employee_deductions: '250.0', net_pay: '750.0', employer_taxes: '76.5', employer_contributions: '40.0', total_payroll_cost: '1116.5', client_approval_required: true, approved_review_revision: 2, calculation_checksum: 'b'.repeat(64) },
  journal: { basis: 'Committed paycheck values.', lines: [
    { account_key: 'gross', account_label: 'Gross payroll expense', debit: '1000.0', credit: '0.0', source: 'Committed gross pay' },
    { account_key: 'net', account_label: 'Employee net payroll payable', debit: '0.0', credit: '750.0', source: 'Committed net pay' },
  ], debit_total: '1116.5', credit_total: '1116.5', difference: '0.0', balanced: true },
  employee_payments: { required_count: 1, direct_deposit_count: 0, assigned_count: 1, printed_count: 1, delivered_count: 1, reconciled_count: 0, outstanding_count: 1, total_amount: '750.0', by_status: { issued: 1 }, rows: [
    { payroll_item_id: 10, employee_id: 2, employee_name: 'Mo Shimizu', amount: '750.0', payment_delivery_method: 'paper_check', check_number: '8200', issuance_status: 'delivered', reconciliation_status: 'issued' },
  ] },
  liabilities: { posting_status: 'posted', payment_tracking_status: 'tracked_in_liability_center', calculated_amount: '316.5', prepared_amount: '0.0', paid_amount: '0.0', outstanding_amount: '316.5', unreserved_amount: '316.5', unclassified_components: [], obligations: [
    { key: '8:DRT', authority: 'Treasurer of Guam', liability_date: '2026-08-20', due_date: null, calculated_amount: '100.0', prepared_amount: '0.0', paid_amount: '0.0', outstanding_amount: '100.0', status: 'unpaid' },
  ] },
  ytd_reconciliation: { status: 'reconciled', basis: 'Pay date', through_pay_date: '2026-08-20', cornerstone_payroll_count: 4, cornerstone_paycheck_count: 4, quickbooks_paycheck_count: 8, historical_adjustment_count: 0, excluded_unlinked_paycheck_count: 0, historical_ytd_bridge: { applied: true, tax_years: [2026], through_pay_date: '2026-06-30', through_period_end: '2026-06-30' }, totals: { net_pay: '8200.0' } },
  evidence: { payroll_approval: { approved_at: '2026-08-19T13:00:00Z', approved_by_name: 'Dana' }, client_approval_required: true, review: { revision: 2, calculation_checksum: 'b'.repeat(64), approved_at: '2026-08-19T12:00:00Z', approved_by_name: 'Sarah', approval_method: 'email_attestation', approval_evidence_reference: 'Email thread' }, source_packages: [], time_tracking_imports: [] },
  completion: { status: 'in_progress', blockers: [], open_items: ['Reconcile 1 employee check', 'Settle $316.50 in payroll liabilities'] },
};

export const voidedFinalRecordFixture: PayrollFinalRecord = {
  ...payrollFinalRecordFixture,
  record_fingerprint: 'c'.repeat(64),
  pay_period: { ...payrollFinalRecordFixture.pay_period, correction_status: 'voided' },
  official_payroll: { ...payrollFinalRecordFixture.official_payroll, status: 'voided', paycheck_count: 0,
    gross_pay: '0.0', non_taxable_pay: '0.0', employee_deductions: '0.0', net_pay: '0.0',
    employer_taxes: '0.0', employer_contributions: '0.0', total_payroll_cost: '0.0' },
  journal: { ...payrollFinalRecordFixture.journal, lines: [], debit_total: '0.0', credit_total: '0.0', difference: '0.0' },
  employee_payments: { required_count: 0, direct_deposit_count: 0, assigned_count: 0, printed_count: 0,
    delivered_count: 0, reconciled_count: 0, outstanding_count: 0, total_amount: '0.0', by_status: {}, rows: [] },
  liabilities: { ...payrollFinalRecordFixture.liabilities, posting_status: 'reversed', calculated_amount: '0.0',
    prepared_amount: '0.0', paid_amount: '0.0', outstanding_amount: '0.0', unreserved_amount: '0.0', obligations: [] },
  completion: { status: 'attention_required', blockers: ['This payroll has been voided'], open_items: [] },
};
