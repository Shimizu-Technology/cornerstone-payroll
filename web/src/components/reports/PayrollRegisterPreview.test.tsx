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

describe('register reconciliation columns', () => {
  afterEach(cleanup);

  it('renders saved Roth, payroll-field retirement, reimbursements and employee net without employer money', () => {
    const cases = [
      { name: 'Roth rate', traditional: 0, roth: 28.8, additions: 0, employer: 0 },
      { name: 'Roth catch-up', traditional: 0, roth: 1216.35, additions: 0, employer: 0 },
      { name: 'Field retirement', traditional: 927.91, roth: 0, additions: 0, employer: 100 },
      { name: 'Reimbursement', traditional: 0, roth: 0, additions: 20, employer: 0 },
      { name: 'Ordinary', traditional: 0, roth: 0, additions: 0, employer: 0 },
    ];
    const workers = cases.map((fixture, index) => ({
      ...report.employees[0], employee_id: index + 1, employee_name: fixture.name,
      gross_pay: 2000, non_taxable_additions_total: fixture.additions,
      retirement_payment: 0, roth_retirement_payment: fixture.roth,
      traditional_retirement_total: fixture.traditional, roth_retirement_total: fixture.roth,
      total_deductions: 253 + fixture.traditional + fixture.roth,
      net_pay: 2000 + fixture.additions - 253 - fixture.traditional - fixture.roth,
      employer_contributions_total: fixture.employer,
    }));
    render(<PayrollRegisterPreviewContent report={{ ...report, employees: workers }} />);
    const table = screen.getByRole('columnheader', { name: 'Non-Taxable Additions' }).closest('table')!;
    const headings = Array.from(table.querySelectorAll('thead th')).map((cell) => cell.textContent);
    for (const fixture of cases) {
      const row = Array.from(table.querySelectorAll('tbody tr')).find((candidate) => candidate.querySelector('td')?.textContent === fixture.name)!;
      const cells = Array.from(row.querySelectorAll('td')).map((cell) => Number(cell.textContent?.replace(/[$,]/g, '') || 0));
      const value = (label: string) => cells[headings.indexOf(label)];
      expect(value('Pre-Tax Retirement')).toBe(fixture.traditional);
      expect(value('Roth Retirement')).toBe(fixture.roth);
      expect(value('Employer Contributions')).toBe(fixture.employer);
      expect(Math.round((value('Gross Pay') + value('Non-Taxable Additions') - value('Deductions')) * 100)).toBe(Math.round(value('Net Pay') * 100));
    }
  });

  it('displays a backend reconciliation failure prominently', () => {
    render(<PayrollRegisterPreviewContent report={{ ...report, register_review: [{ severity: 'Review', employee: 'Test Employee', issue: 'Payroll row does not reconcile', detail: 'Difference $0.01' }] }} />);
    expect(screen.getByRole('alert').textContent).toContain('Payroll row does not reconcile');
  });
});

// Provider registers verify the loan total without identifying a native loan subtype.
it('shows verified previous-provider loans in a separate column and total', () => {
  const historical = structuredClone(report);
  historical.employees[0].historical_loan_deductions_unclassified = 10;
  render(<PayrollRegisterPreviewContent report={historical} />);
  expect(screen.getAllByText('Previous provider loans (type not recorded)')).toHaveLength(2);
  expect(screen.getAllByText('$10.00')).toHaveLength(3);
});
