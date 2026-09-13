// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { PayrollFinalRecord } from '@/services/api';
import { PayrollFinalRecordPanel } from './PayrollFinalRecordPanel';

const apiMocks = vi.hoisted(() => ({
  payrollFinalRecord: vi.fn(),
  payrollFinalRecordXlsx: vi.fn(),
  payrollFinalRecordPdf: vi.fn(),
}));

vi.mock('@/services/api', () => ({ reportsApi: apiMocks }));

const record: PayrollFinalRecord = {
  schema_version: 'v1', generated_at: '2026-08-20T12:00:00Z', record_fingerprint: 'a'.repeat(64),
  company: { id: 1, name: 'MoSa LLC' },
  pay_period: { id: 8, start_date: '2026-08-01', end_date: '2026-08-15', pay_date: '2026-08-20', status: 'committed', correction_status: null, cycle: 'regular', run_purpose: 'regular', committed_at: '2026-08-20T12:00:00Z', committed_by_name: 'Dana' },
  official_payroll: { status: 'official', paycheck_count: 1, gross_pay: '1000.0', non_taxable_pay: '0.0', employee_deductions: '250.0', net_pay: '750.0', employer_taxes: '76.5', employer_contributions: '40.0', total_payroll_cost: '1116.5', client_approval_required: true, approved_review_revision: 2, calculation_checksum: 'b'.repeat(64) },
  journal: { basis: 'Committed paycheck values.', lines: [
    { account_key: 'gross', account_label: 'Gross payroll expense', debit: '1000.0', credit: '0.0', source: 'Committed gross pay' },
    { account_key: 'net', account_label: 'Employee net payroll payable', debit: '0.0', credit: '750.0', source: 'Committed net pay' },
  ], debit_total: '1116.5', credit_total: '1116.5', difference: '0.0', balanced: true },
  employee_payments: { required_count: 1, assigned_count: 1, printed_count: 1, delivered_count: 1, reconciled_count: 0, outstanding_count: 1, total_amount: '750.0', by_status: { issued: 1 }, rows: [
    { payroll_item_id: 10, employee_id: 2, employee_name: 'Mo Shimizu', amount: '750.0', check_number: '8200', issuance_status: 'delivered', reconciliation_status: 'issued' },
  ] },
  liabilities: { posting_status: 'posted', payment_tracking_status: 'tracked_in_liability_center', calculated_amount: '316.5', prepared_amount: '0.0', paid_amount: '0.0', outstanding_amount: '316.5', unreserved_amount: '316.5', unclassified_components: [], obligations: [
    { key: '8:DRT', authority: 'Treasurer of Guam', liability_date: '2026-08-20', due_date: null, calculated_amount: '100.0', prepared_amount: '0.0', paid_amount: '0.0', outstanding_amount: '100.0', status: 'unpaid' },
  ] },
  ytd_reconciliation: { status: 'reconciled', basis: 'Pay date', through_pay_date: '2026-08-20', cornerstone_payroll_count: 4, cornerstone_paycheck_count: 4, quickbooks_paycheck_count: 8, historical_adjustment_count: 0, excluded_unlinked_paycheck_count: 0, historical_ytd_bridge: { applied: true, tax_years: [2026], through_pay_date: '2026-06-30', through_period_end: '2026-06-30' }, totals: { net_pay: '8200.0' } },
  evidence: { payroll_approval: { approved_at: '2026-08-19T13:00:00Z', approved_by_name: 'Dana' }, client_approval_required: true, review: { revision: 2, calculation_checksum: 'b'.repeat(64), approved_at: '2026-08-19T12:00:00Z', approved_by_name: 'Sarah', approval_method: 'email_attestation', approval_evidence_reference: 'Email thread' }, source_packages: [], time_tracking_imports: [] },
  completion: { status: 'in_progress', blockers: [], open_items: ['Reconcile 1 employee check', 'Settle $316.50 in payroll liabilities'] },
};

describe('PayrollFinalRecordPanel', () => {
  afterEach(cleanup);

  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.payrollFinalRecord.mockResolvedValue({ final_record: record });
  });

  it('summarizes payroll truth and opens the supporting record', async () => {
    render(<PayrollFinalRecordPanel payPeriodId={8} />);

    expect(await screen.findByText('In Progress')).toBeTruthy();
    expect(screen.getByText('Balanced')).toBeTruthy();
    expect(screen.getByText('0 of 1 reconciled')).toBeTruthy();
    expect(screen.getByText('$316.50 outstanding')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'View record' }));
    expect(screen.getByRole('heading', { name: 'Balanced payroll journal' })).toBeTruthy();
    expect(screen.getByText('Reconcile 1 employee check')).toBeTruthy();
    expect(screen.getByText('Mo Shimizu')).toBeTruthy();
    expect(screen.getByText(/Approved review revision 2/)).toBeTruthy();
  });

  it('surfaces load failures as an accessible alert', async () => {
    apiMocks.payrollFinalRecord.mockRejectedValue(new Error('Record unavailable'));
    render(<PayrollFinalRecordPanel payPeriodId={8} />);

    await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('Record unavailable'));
    expect(screen.getByRole('button', { name: 'View record' }).hasAttribute('disabled')).toBe(true);
  });
});
