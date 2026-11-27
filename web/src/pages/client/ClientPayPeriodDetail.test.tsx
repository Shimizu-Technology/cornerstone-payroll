// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { ClientPayPeriodDetail } from './ClientPayPeriodDetail';
import { getVisibleOptionalColumns } from './clientPayPeriodColumns';
import type { PayrollItem } from '@/types';

const apiMocks = vi.hoisted(() => ({ getPayPeriod: vi.fn(), getSubmission: vi.fn() }));

vi.mock('@/components/layout/Header', () => ({ Header: ({ title, description }: { title: string; description?: string }) => <header><h1>{title}</h1><p>{description}</p></header> }));
vi.mock('@/components/client-portal/ClientPayrollReview', () => ({
  ClientPayrollReview: () => <section data-testid="payroll-review-card">Review preview</section>,
}));
vi.mock('@/components/client-portal/ClientPayStubButton', () => ({ ClientPayStubButton: () => null }));
vi.mock('@/services/payrollSubmissions', () => ({ clientPayrollSubmissionsApi: { get: apiMocks.getSubmission } }));
vi.mock('@/services/api', () => ({
  clientPayPeriodsApi: { get: apiMocks.getPayPeriod },
}));

beforeEach(() => {
  vi.clearAllMocks();
  apiMocks.getSubmission.mockRejectedValue(new Error('not found'));
});
afterEach(cleanup);

function renderDetail() {
  return render(
    <MemoryRouter initialEntries={['/companies/2/pay-runs/9/overview']}>
      <Routes>
        <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<ClientPayPeriodDetail />} />
      </Routes>
    </MemoryRouter>,
  );
}

it('shows the pay-line message on desktop and mobile and keeps other rows readable', async () => {
  const detailsError = "Details for this pay line aren't available yet. Contact Cornerstone.";
  apiMocks.getPayPeriod.mockResolvedValue({
    pay_period: {
      id: 9,
      company_id: 2,
      start_date: '2026-08-01',
      end_date: '2026-08-14',
      pay_date: '2026-08-19',
      status: 'committed',
      payroll_items: [
        { id: 101, employee_name: 'Casey First', details_error: detailsError, net_pay: 180 },
        { id: 102, employee_name: 'Morgan Second', other_deductions: 25, net_pay: 260 },
      ],
    },
  });

  renderDetail();

  expect(await screen.findByRole('heading', { name: 'Pay period: Aug 1 – 14, 2026' })).toBeTruthy();
  const affectedRow = screen.getByRole('row', { name: /Casey First/ });
  expect(within(affectedRow).getByText(detailsError)).toBeTruthy();
  expect(within(screen.getByRole('row', { name: /Morgan Second/ })).getByText('$25.00')).toBeTruthy();
  const mobile = screen.getByLabelText('Employee payroll details');
  expect(within(mobile).getByText(detailsError)).toBeTruthy();
  expect(within(mobile).getByText('Morgan Second')).toBeTruthy();
});

it('renders Salary and /yr for salaried rows and includes Other deductions so row totals reconcile', async () => {
  apiMocks.getPayPeriod.mockResolvedValue({
    pay_period: {
      id: 9,
      company_id: 2,
      start_date: '2026-08-01',
      end_date: '2026-08-14',
      pay_date: '2026-08-19',
      status: 'committed',
      employee_count: 2,
      total_gross: 4215.38,
      total_net: 3255.31,
      payroll_items: [
        {
          id: 101,
          employee_id: 11,
          employee_name: 'Morgan Salary',
          employment_type: 'salary',
          salary_type: 'annual',
          pay_rate: 68000,
          total_hours: 0,
          hours_worked: 0,
          gross_pay: 2615.38,
          withholding_tax: 220,
          additional_withholding: 10,
          social_security_tax: 162.15,
          medicare_tax: 37.92,
          state_withheld: 0,
          retirement_payment: 100,
          roth_retirement_payment: 25,
          loan_payment: 50,
          insurance_payment: 40,
          other_deductions: 0,
          total_deductions: 645.07,
          net_pay: 1970.31,
        },
        {
          id: 102,
          employee_id: 12,
          employee_name: 'Casey Server',
          employment_type: 'hourly',
          pay_rate: 16,
          total_hours: 80,
          hours_worked: 80,
          gross_pay: 1600,
          withholding_tax: 120,
          additional_withholding: 0,
          social_security_tax: 99.2,
          medicare_tax: 23.2,
          state_withheld: 0,
          retirement_payment: 30,
          roth_retirement_payment: 0,
          loan_payment: 20,
          insurance_payment: 7.6,
          other_deductions: 15,
          total_deductions: 315,
          net_pay: 1285,
        },
      ],
    },
  });

  renderDetail();

  expect(await screen.findByRole('columnheader', { name: 'Other deductions' })).toBeTruthy();
  expect(screen.queryByRole('columnheader', { name: 'Non-taxable additions' })).toBeNull();

  const salaryRow = screen.getByRole('row', { name: /Morgan Salary/ });
  const salaryCells = within(salaryRow).getAllByRole('cell').map(cell => cell.textContent?.trim());
  expect(salaryCells[1]).toBe('Salary');
  expect(salaryCells[2]).toBe('$68,000/yr');
  expect(salaryCells[8]).toBe('$0.00');
  expect(salaryCells[9]).toBe('$645.07');

  const serverRow = screen.getByRole('row', { name: /Casey Server/ });
  const serverCells = within(serverRow).getAllByRole('cell').map(cell => cell.textContent?.trim());
  expect(serverCells[1]).toBe('80');
  expect(serverCells[2]).toBe('$16.00/hr');
  expect(serverCells[8]).toBe('$15.00');
  expect(serverCells[9]).toBe('$315.00');

  const parseDollars = (text: string | undefined) => Number((text ?? '0').replace(/[^0-9.-]/g, ''));
  const serverSum = serverCells.slice(4, 9).reduce((acc, cell) => acc + parseDollars(cell), 0);
  expect(Math.round(serverSum * 100) / 100).toBe(parseDollars(serverCells[9]));

  const salarySum = salaryCells.slice(4, 9).reduce((acc, cell) => acc + parseDollars(cell), 0);
  expect(Math.round(salarySum * 100) / 100).toBe(parseDollars(salaryCells[9]));
});

it('preserves negative Other deductions in fallback, omits unknown rate units, and shows non-taxable additions on desktop and mobile', async () => {
  apiMocks.getPayPeriod.mockResolvedValue({
    pay_period: {
      id: 9,
      company_id: 2,
      start_date: '2026-08-01',
      end_date: '2026-08-14',
      pay_date: '2026-08-19',
      status: 'committed',
      employee_count: 3,
      total_gross: 3715.38,
      total_net: 2995.44,
      payroll_items: [
        {
          id: 201,
          employee_id: 21,
          employee_name: 'Riley Refund',
          employment_type: 'hourly',
          pay_rate: 20,
          total_hours: 10,
          gross_pay: 200,
          withholding_tax: 41.49,
          additional_withholding: 0,
          social_security_tax: 12.4,
          medicare_tax: 2.9,
          state_withheld: 0,
          retirement_payment: 0,
          roth_retirement_payment: 0,
          loan_payment: 0,
          insurance_payment: 0,
          total_deductions: 46.79,
          net_pay: 153.21,
        },
        {
          id: 202,
          employee_id: 22,
          employee_name: 'Pat Historical',
          employment_type: 'salary',
          salary_type: null,
          pay_rate: 68000,
          total_hours: 0,
          gross_pay: 2615.38,
          withholding_tax: 500,
          additional_withholding: 0,
          social_security_tax: 0,
          medicare_tax: 0,
          state_withheld: 0,
          retirement_payment: 0,
          roth_retirement_payment: 0,
          loan_payment: 0,
          insurance_payment: 0,
          other_deductions: 0,
          total_deductions: 500,
          net_pay: 2115.38,
        },
        {
          id: 203,
          employee_id: 23,
          employee_name: 'Taylor Reimbursed',
          employment_type: 'contractor',
          contractor_pay_type: null,
          pay_rate: 900,
          total_hours: 0,
          gross_pay: 900,
          non_taxable_additions_total: 50,
          withholding_tax: 108.15,
          additional_withholding: 0,
          social_security_tax: 0,
          medicare_tax: 0,
          state_withheld: 0,
          retirement_payment: 45,
          roth_retirement_payment: 0,
          loan_payment: 0,
          insurance_payment: 25,
          other_deductions: 45,
          total_deductions: 223.15,
          net_pay: 726.85,
        },
      ],
    },
  });

  renderDetail();

  const refundRow = await screen.findByRole('row', { name: /Riley Refund/ });
  const refundCells = within(refundRow).getAllByRole('cell').map(cell => cell.textContent?.trim());
  expect(screen.queryByRole('columnheader', { name: 'Loans' })).toBeNull();
  expect(refundCells[8]).toBe('-$10.00');
  expect(refundCells[9]).toBe('$46.79');

  const legacyRow = screen.getByRole('row', { name: /Pat Historical/ });
  const legacyCells = within(legacyRow).getAllByRole('cell').map(cell => cell.textContent?.trim());
  expect(legacyCells[2]).toBe('$68,000.00');

  const reimbRow = screen.getByRole('row', { name: /Taylor Reimbursed/ });
  const reimbCells = within(reimbRow).getAllByRole('cell').map(cell => cell.textContent?.trim());
  expect(reimbCells[2]).toBe('$900.00');
  expect(reimbCells[3]).toBe('$900.00');
  expect(reimbCells[4]).toBe('$50.00');
  expect(reimbCells[9]).toBe('$223.15');
  expect(reimbCells[10]).toBe('$726.85');

  const mobileList = screen.getByLabelText('Employee payroll details');
  expect(within(mobileList).getAllByText('Non-taxable additions').length).toBe(3);
  expect(within(mobileList).getByText('$50.00')).toBeTruthy();
  expect(within(mobileList).getByText('-$10.00')).toBeTruthy();
});

it('hides all five optional columns when every row in the period is zero and shows each when non-zero', async () => {
  const zeroItem = {
    id: 301,
    employee_id: 31,
    employee_name: 'Jordan Zero',
    employment_type: 'hourly',
    pay_rate: 15,
    total_hours: 40,
    hours_worked: 40,
    gross_pay: 600,
    withholding_tax: 40,
    additional_withholding: 0,
    social_security_tax: 37.2,
    medicare_tax: 8.7,
    state_withheld: 0,
    retirement_payment: 0,
    roth_retirement_payment: 0,
    loan_payment: 0,
    insurance_payment: 0,
    other_deductions: 0,
    total_deductions: 85.9,
    net_pay: 514.1,
  } as unknown as PayrollItem;

  expect(getVisibleOptionalColumns([zeroItem])).toEqual({
    nonTaxableAdditions: false,
    retirement: false,
    loans: false,
    insurance: false,
    otherDeductions: false,
    count: 0,
  });

  expect(getVisibleOptionalColumns([
    zeroItem,
    { ...zeroItem, id: 302, loan_payment: 35, total_deductions: 120.9 } as unknown as PayrollItem,
  ])).toEqual({
    nonTaxableAdditions: false,
    retirement: false,
    loans: true,
    insurance: false,
    otherDeductions: false,
    count: 1,
  });

  apiMocks.getPayPeriod.mockResolvedValue({
    pay_period: {
      id: 9,
      company_id: 2,
      start_date: '2026-08-01',
      end_date: '2026-08-14',
      pay_date: '2026-08-19',
      status: 'committed',
      employee_count: 1,
      total_gross: 600,
      total_net: 514.1,
      payroll_items: [zeroItem],
    },
  });

  renderDetail();

  expect(await screen.findByRole('columnheader', { name: 'Net pay' })).toBeTruthy();
  expect(screen.getAllByRole('columnheader').map((th) => th.textContent?.trim())).toEqual([
    'Employee', 'Hours', 'Rate', 'Gross', 'Taxes', 'Total deductions', 'Net pay',
  ]);
});

it('renders the approval review card above the employee table when a review is active, and isolates the table scroll container', async () => {
  apiMocks.getPayPeriod.mockResolvedValue({
    pay_period: {
      id: 9,
      company_id: 2,
      start_date: '2026-11-08',
      end_date: '2026-11-21',
      pay_date: '2026-11-27',
      status: 'approved',
      employee_count: 1,
      total_gross: 1000,
      total_net: 850,
      payroll_review: { id: 1, revision: 1, status: 'pending', published_at: '2026-11-25T00:00:00Z' },
      payroll_items: [{ id: 101, employee_name: 'Casey First', net_pay: 850 }],
    },
  });

  renderDetail();

  const review = await screen.findByTestId('payroll-review-card');
  const tableHeading = screen.getByRole('heading', { name: 'Employee payroll' });
  expect(Boolean(review.compareDocumentPosition(tableHeading) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true);
  const tableScroll = screen.getByRole('table').parentElement;
  expect(tableScroll?.className).toContain('isolate');
});

it('shows an inline recovery card when a pay period cannot be loaded', async () => {
  apiMocks.getPayPeriod.mockRejectedValue(new Error('Pay period not found'));

  renderDetail();

  expect(await screen.findByRole('heading', { name: "This pay period isn't available yet" })).toBeTruthy();
  expect(screen.getByRole('alert').textContent).toContain('Pay period not found');
  expect(screen.getByRole('button', { name: 'Back to pay periods' })).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();
});
