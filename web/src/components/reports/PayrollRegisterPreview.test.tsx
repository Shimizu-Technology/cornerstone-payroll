// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import type { PayrollRegisterReport } from '@/services/api';
import { PayrollRegisterPreviewContent } from './PayrollRegisterPreview';

const report = {
  type: 'payroll_register',
  simple_payroll_register_enabled: false,
  meta: { company_name: "MoSa's Migration Test" },
  source: {
    system: 'cornerstone',
    label: 'Cornerstone',
    locked: false,
    statement: 'Migration rehearsal',
  },
  pay_period: {
    id: 7,
    start_date: '2026-09-01',
    end_date: '2026-09-14',
    pay_date: '2026-09-18',
    status: 'calculated',
  },
  lifecycle: {},
  summary: {
    employee_count: 1,
    contractor_count: 0,
    total_hours: 80,
    total_overtime_hours: 5,
    total_gross: 2_100,
    total_bonus: 100,
    total_straight_loan_deductions: 25,
    total_installment_loan_payments: 50,
    total_employer_contributions: 75,
    total_employer_payroll_cost: 2_325,
    total_withholding: 200,
    total_social_security: 130.2,
    total_medicare: 30.45,
    total_retirement: 84,
    total_deductions: 489.65,
    total_net: 1_610.35,
  },
  employees: [{
    employee_id: 1,
    employee_name: 'Test Employee',
    employment_type: 'hourly',
    hours_worked: 80,
    overtime_hours: 5,
    reported_tips: 0,
    tips_paid_out: 0,
    bonus: 100,
    gross_pay: 2_100,
    withholding_tax: 200,
    additional_withholding: 0,
    social_security_tax: 130.2,
    medicare_tax: 30.45,
    straight_loan_deduction: 25,
    installment_loan_payment: 50,
    total_deductions: 489.65,
    net_pay: 1_610.35,
    employer_contributions_total: 75,
    employer_payroll_cost: 2_325,
    check_number: '1001',
    payroll_adjustments: [],
    payroll_field_entries: [],
  }],
  contractors: [],
} as unknown as PayrollRegisterReport['report'];

describe('PayrollRegisterPreviewContent', () => {
  afterEach(cleanup);

  it("shows Mark's requested totals and separates straight from installment loans", () => {
    render(<PayrollRegisterPreviewContent report={report} />);

    expect(screen.getByText('Total hours').nextElementSibling?.textContent).toBe('80.00');
    expect(screen.getByText('Total OT hours').nextElementSibling?.textContent).toBe('5.00');
    expect(screen.getAllByText('Bonus')[0].nextElementSibling?.textContent).toBe('$100.00');
    expect(screen.getByText('Straight loans').nextElementSibling?.textContent).toBe('$25.00');
    expect(screen.getByText('Installment loans').nextElementSibling?.textContent).toBe('$50.00');
    expect(screen.getByText('Employer contributions').nextElementSibling?.textContent).toBe('$75.00');
    expect(screen.getByText('Employer cost').nextElementSibling?.textContent).toBe('$2,325.00');
    expect(screen.getAllByText('Straight Loan').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Installment Loan').length).toBeGreaterThan(0);
  });

  it('makes rehearsal registers visibly test-only without labeling locked imports that way', () => {
    render(<PayrollRegisterPreviewContent report={{
      ...report,
      meta: { ...report.meta, provisional: true, payroll_status_note: 'TEST ONLY — calculated rehearsal payroll, not committed or paid' },
    }} />);

    expect(screen.getByRole('status').textContent).toContain('not committed or paid');
    expect(screen.getByText('Test-only payroll register')).toBeTruthy();
  });
});
