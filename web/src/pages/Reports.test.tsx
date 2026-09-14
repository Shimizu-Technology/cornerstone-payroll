// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { YtdSummaryReport } from '@/services/api';
import { YtdSummaryPanel } from './Reports';

const apiMocks = vi.hoisted(() => ({
  ytdSummary: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  reportsApi: { ytdSummary: apiMocks.ytdSummary },
  payrollHistoryApi: {},
  employeesApi: {},
  ApiError: class ApiError extends Error {},
}));

const report = {
  type: 'ytd_summary',
  year: 2026,
  period: {
    label: '2026',
    start_date: '2026-01-01',
    end_date: '2026-12-31',
    period_basis: 'pay_date',
  },
  employees: [{
    employee_id: 1,
    first_name: 'Test',
    last_name: 'Employee',
    name: 'Test Employee',
    employment_type: 'hourly',
    status: 'active',
    total_hours: 82.5,
    total_overtime_hours: 2.25,
    gross_pay: 2_100,
    bonus: 100,
    straight_loan_deductions: 25,
    installment_loan_payments: 50,
    employer_contributions: 75,
    employer_payroll_cost: 2_325,
    withholding_tax: 200,
    social_security_tax: 130.2,
    medicare_tax: 30.45,
    retirement: 84,
    total_deductions: 489.65,
    net_pay: 1_610.35,
  }],
  company_totals: {
    year: 2026,
    total_hours: 82.5,
    total_overtime_hours: 2.25,
    gross_pay: 2_100,
    bonus: 100,
    straight_loan_deductions: 25,
    installment_loan_payments: 50,
    employer_contributions: 75,
    employer_payroll_cost: 2_325,
    withholding_tax: 200,
    social_security_tax: 130.2,
    medicare_tax: 30.45,
    retirement: 84,
    total_deductions: 489.65,
    net_pay: 1_610.35,
    payroll_count: 1,
  },
  payroll_fields: { totals: [] },
} as unknown as YtdSummaryReport['report'];

describe('YtdSummaryPanel', () => {
  afterEach(cleanup);

  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.ytdSummary.mockResolvedValue({ report });
  });

  it('renders the new company totals and employee-level report values', async () => {
    render(<YtdSummaryPanel />);

    fireEvent.click(screen.getByRole('button', { name: 'View Report' }));

    expect(await screen.findByText('Payroll Summary — 2026')).toBeTruthy();
    expect(screen.getByText('Total Hours').nextElementSibling?.textContent).toBe('82.50');
    expect(screen.getByText('Total OT Hours').nextElementSibling?.textContent).toBe('2.25');
    expect(screen.getByText('Straight Loans').nextElementSibling?.textContent).toBe('$25.00');
    expect(screen.getByText('Installment Loans').nextElementSibling?.textContent).toBe('$50.00');
    expect(screen.getByText('Employer Contributions').nextElementSibling?.textContent).toBe('$75.00');
    expect(screen.getByText('Employer Payroll Cost').nextElementSibling?.textContent).toBe('$2,325.00');

    const employeeRow = screen.getByText('Test Employee').closest('tr');
    expect(employeeRow?.textContent).toContain('82.50');
    expect(employeeRow?.textContent).toContain('2.25');
    expect(employeeRow?.textContent).toContain('$25.00');
    expect(employeeRow?.textContent).toContain('$50.00');
    expect(employeeRow?.textContent).toContain('$75.00');
    expect(employeeRow?.textContent).toContain('$2,325.00');
  });
});
