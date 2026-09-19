// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { YtdSummaryReport } from '@/services/api';
import { PayrollRegisterPanel, YtdSummaryPanel } from './Reports';

const apiMocks = vi.hoisted(() => ({
  ytdSummary: vi.fn(),
  payrollHistoryList: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  reportsApi: { ytdSummary: apiMocks.ytdSummary },
  payrollHistoryApi: { list: apiMocks.payrollHistoryList },
  employeesApi: {},
  ApiError: class ApiError extends Error {},
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompanyId: 42 }),
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

  it('uses a year-to-date pay-date range by default and offers a rolling year preset', async () => {
    render(<YtdSummaryPanel />);
    fireEvent.click(screen.getByRole('button', { name: 'View Report' }));

    await screen.findByText('Payroll Summary — 2026');
    const firstParams = apiMocks.ytdSummary.mock.calls[0][0];
    expect(firstParams.start_date).toMatch(/^\d{4}-01-01$/);
    expect(firstParams.end_date).toMatch(/^\d{4}-\d{2}-\d{2}$/);

    fireEvent.change(screen.getByRole('combobox', { name: 'Payroll summary period type' }), { target: { value: 'rolling_year' } });
    fireEvent.click(screen.getByRole('button', { name: 'View Report' }));
    await screen.findByText('Payroll Summary — 2026');
    const rollingParams = apiMocks.ytdSummary.mock.calls.at(-1)?.[0];
    expect(rollingParams.start_date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(rollingParams.end_date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it('includes active $0-pay employees by default and sends the changed selection to the report', async () => {
    render(<YtdSummaryPanel />);
    const checkbox = screen.getByRole('checkbox', { name: 'Include active employees with $0 pay' }) as HTMLInputElement;
    expect(checkbox.checked).toBe(true);

    fireEvent.click(screen.getByRole('button', { name: 'View Report' }));
    await screen.findByText('Payroll Summary — 2026');
    expect(apiMocks.ytdSummary.mock.calls[0][0].include_zero_pay).toBe(true);

    fireEvent.click(checkbox);
    expect(checkbox.checked).toBe(false);
    expect(screen.queryByText('Payroll Summary — 2026')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'View Report' }));
    await screen.findByText('Payroll Summary — 2026');
    expect(apiMocks.ytdSummary.mock.calls.at(-1)?.[0].include_zero_pay).toBe(false);
  });

  it('labels rehearsal totals as test-only rather than paid payroll', async () => {
    apiMocks.ytdSummary.mockResolvedValue({
      report: { ...report, meta: { provisional: true, payroll_status_note: 'TEST ONLY — calculated rehearsal payroll, not committed or paid' } },
    });
    render(<YtdSummaryPanel />);
    fireEvent.click(screen.getByRole('button', { name: 'View Report' }));

    expect(await screen.findByText(/Test-only projection/)).toBeTruthy();
    expect(screen.getByText(/not committed or paid payroll/)).toBeTruthy();
  });

  it('adds decimal-string payroll fields numerically in totals and employee rows', async () => {
    apiMocks.ytdSummary.mockResolvedValue({ report: {
      ...report,
      company_totals: {
        ...report.company_totals,
        payroll_field_taxable_additions_total: '12.50',
        payroll_field_non_taxable_additions_total: '3.25',
        payroll_field_pre_tax_deductions_total: '4.00',
        payroll_field_post_tax_deductions_total: '1.75',
      },
      employees: [{
        ...report.employees[0],
        payroll_field_taxable_additions_total: '12.50',
        payroll_field_non_taxable_additions_total: '3.25',
        payroll_field_pre_tax_deductions_total: '4.00',
        payroll_field_post_tax_deductions_total: '1.75',
      }],
    } });
    render(<YtdSummaryPanel />);
    fireEvent.click(screen.getByRole('button', { name: 'View Report' }));

    expect(await screen.findByText('Payroll Summary — 2026')).toBeTruthy();
    expect(screen.getByText('Payroll Field Additions').nextElementSibling?.textContent).toBe('$15.75');
    expect(screen.getByText('Payroll Field Deductions').nextElementSibling?.textContent).toBe('$5.75');
    const employeeRow = screen.getByText('Test Employee').closest('tr');
    expect(employeeRow?.textContent).toContain('$15.75');
    expect(employeeRow?.textContent).toContain('$5.75');
    expect(employeeRow?.textContent).not.toContain('NaN');
  });
});

describe('PayrollRegisterPanel', () => {
  afterEach(cleanup);

  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.payrollHistoryList.mockImplementation(async ({ page }: { page: number }) => ({
      data: page === 1 ? [{
        key: 'imported:19', status: 'locked', source: { label: 'QuickBooks import' },
        start_date: '2026-08-01', end_date: '2026-08-14', pay_date: '2026-08-21',
      }] : [{
        key: 'native:27', status: 'approved', source: { label: 'Cornerstone' },
        start_date: '2026-08-24', end_date: '2026-09-06', pay_date: '2026-09-10',
      }],
      meta: { total_pages: 2 },
    }));
  });

  it('loads every reportable page and labels approved rehearsal runs as test-only', async () => {
    render(<PayrollRegisterPanel />);

    const select = await screen.findByRole('combobox', { name: 'Pay Period' });
    expect(await screen.findByRole('option', { name: /TEST ONLY · Cornerstone/ })).toBeTruthy();
    expect(apiMocks.payrollHistoryList).toHaveBeenCalledTimes(2);
    expect(apiMocks.payrollHistoryList).toHaveBeenCalledWith(expect.objectContaining({ register_eligible: true, page: 2 }), 42);
    expect(select.querySelectorAll('option')).toHaveLength(2);
  });
});
