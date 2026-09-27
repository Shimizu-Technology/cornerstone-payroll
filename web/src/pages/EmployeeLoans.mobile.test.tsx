// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import type { EmployeeLoan } from '@/types';
import EmployeeLoans from './EmployeeLoans';

const apiMocks = vi.hoisted(() => ({ listLoans: vi.fn(), getLoan: vi.fn(), listEmployees: vi.fn() }));

vi.mock('@/services/api', () => ({
  employeeLoansApi: { list: apiMocks.listLoans, get: apiMocks.getLoan },
  employeesApi: { list: apiMocks.listEmployees },
}));

afterEach(cleanup);

it('shows the full loan transaction record in a phone card', async () => {
  vi.clearAllMocks();
  const loan = {
    id: 8,
    employee_id: 23,
    employee_name: 'Ana Cruz',
    name: 'Equipment loan',
    status: 'active',
    tracking_mode: 'balance_tracked',
    original_amount: 200,
    opening_balance: 200,
    current_balance: 150,
    scheduled: false,
    transactions: [{
      id: 5,
      transaction_date: '2026-09-24',
      transaction_type: 'payment',
      amount: 50,
      balance_before: 200,
      balance_after: 150,
      notes: 'Payroll deduction',
      source: 'payroll',
      recorded_by_name: 'Payroll Admin',
    }],
  } as unknown as EmployeeLoan;
  apiMocks.listLoans.mockResolvedValue({ loans: [loan], loan_schedules: [], setup_gaps: [] });
  apiMocks.getLoan.mockResolvedValue({ loan });
  apiMocks.listEmployees.mockResolvedValue({ data: [], meta: { total_pages: 1 } });

  render(<EmployeeLoans />);
  fireEvent.click(await screen.findByRole('button', { name: /Ana Cruz/ }));

  const history = await screen.findByLabelText('Loan transaction history');
  const transaction = within(history).getByRole('region', { name: 'payment on 2026-09-24' });
  expect(within(transaction).getByText('Payroll deduction')).toBeTruthy();
  expect(within(transaction).getByText('$200.00')).toBeTruthy();
  expect(within(transaction).getByText('$150.00')).toBeTruthy();
  expect(within(transaction).getByText('-$50.00')).toBeTruthy();
  await waitFor(() => expect(apiMocks.getLoan).toHaveBeenCalledWith(8));
});
