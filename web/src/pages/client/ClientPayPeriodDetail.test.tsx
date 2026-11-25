// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { ClientPayPeriodDetail } from './ClientPayPeriodDetail';

const apiMocks = vi.hoisted(() => ({ getPayPeriod: vi.fn(), getSubmission: vi.fn() }));

vi.mock('@/components/layout/Header', () => ({ Header: ({ title, description }: { title: string; description?: string }) => <header><h1>{title}</h1><p>{description}</p></header> }));
vi.mock('@/components/client-portal/ClientPayrollReview', () => ({ ClientPayrollReview: () => null }));
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
