// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { NamedLoanInputs } from './NamedLoanInputs';
import type { NamedLoanOption } from '@/types';

afterEach(cleanup);
const option: NamedLoanOption = { employee_id: 1, loan_id: 2, name: 'Employee Loan', tracking_mode: 'balance_tracked', current_balance: 3259.97, scheduled_amount: 300, current_amount: 0, eligible: true, mode: 'default' };

it('offers the saved loan on a special run without enabling unrelated recurring setup', () => {
  const onChange = vi.fn();
  render(<NamedLoanInputs options={[option]} drafts={{}} includesRecurring={false} onChange={onChange} />);
  expect(screen.getByText(/Balance \$3,259.97/)).toBeTruthy();
  expect(screen.getByRole('option', { name: 'No repayment — recurring setup excluded' })).toBeTruthy();
  fireEvent.change(screen.getByLabelText('Employee Loan repayment choice'), { target: { value: 'override' } });
  expect(onChange).toHaveBeenCalledWith(2, { mode: 'override', amount: 300 });
});

it('supports an explicit zero without pausing the future loan schedule', () => {
  const onChange = vi.fn();
  render(<NamedLoanInputs options={[option]} drafts={{ '2': { mode: 'override', amount: 300 } }} includesRecurring onChange={onChange} />);
  const input = screen.getByLabelText('Employee Loan repayment amount');
  fireEvent.change(input, { target: { value: '0' } });
  fireEvent.blur(input);
  expect(onChange).toHaveBeenCalledWith(2, { mode: 'override', amount: 0 });
});

it('shows the reason an unavailable loan cannot be selected', () => {
  render(<NamedLoanInputs options={[{ ...option, eligible: false, unavailable_reason: 'First repayment is after this payday.' }]} drafts={{}} includesRecurring onChange={vi.fn()} />);
  expect(screen.getByText('First repayment is after this payday.')).toBeTruthy();
  expect((screen.getByLabelText('Employee Loan repayment choice') as HTMLSelectElement).disabled).toBe(true);
});

it('requires an intentional amount when a per-run repayment input is cleared', () => {
  const onChange = vi.fn();
  render(<NamedLoanInputs options={[option]} drafts={{ '2': { mode: 'override', amount: 300 } }} includesRecurring onChange={onChange} />);
  fireEvent.change(screen.getByLabelText('Employee Loan repayment amount'), { target: { value: '' } });
  expect(onChange).toHaveBeenCalledWith(2, { mode: 'override', amount: null });
});
